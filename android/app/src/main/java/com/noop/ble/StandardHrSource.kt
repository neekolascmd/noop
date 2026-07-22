package com.noop.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import com.noop.data.HrRow
import com.noop.data.RrRow
import com.noop.data.StreamBatch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * An ISOLATED standard-Bluetooth Heart-Rate source for generic HR straps (Polar / Wahoo / Coospo /
 * Garmin HRM / Amazfit Helio broadcast) that expose the standard BLE Heart Rate Service (0x180D)
 * with the Heart Rate Measurement characteristic (0x2A37).
 *
 * Faithful Kotlin twin of Strand/BLE/StandardHRSource.swift.
 *
 * WHOOP-FIRST ISOLATION: this class runs its OWN scan + [BluetoothGatt] and never imports, calls, or
 * shares state with [WhoopBleClient]. The WHOOP path cannot regress because of anything here — the two
 * BLE flows are fully independent. The only shared surfaces are injected closures:
 *   - [liveSink]  pushes the strap's live HR/R-R into whatever the UI observes (the [SourceCoordinator]
 *                 wires it to the WHOOP client's published state, so live HR shows in the same place).
 *   - [persist]   wired by the app to `repository.insert(StreamBatch, deviceId)` for the active strap.
 *
 * The pure HR parse lives in [StandardHeartRate]; the HR→rows mapping (HrRow + RrRow only) is inline
 * here, mirroring the Swift `StandardHRMapping`.
 *
 * Android runtime-permission notes (same contract as [WhoopBleClient]): the caller must hold
 * BLUETOOTH_SCAN + BLUETOOTH_CONNECT before [scan]/[connect]. Every android.bluetooth call is
 * @SuppressLint("MissingPermission") — the caller owns the grant.
 */
@SuppressLint("MissingPermission")
class StandardHrSource(
    context: Context,
    /** Datastore device id every sample is stamped with (the active strap's registry id). */
    private val deviceId: String,
    /** Push live HR (bpm) + R-R (ms) into whatever the UI observes. Called on the main looper. */
    private val liveSink: (hr: Int, rr: List<Int>) -> Unit,
    /** Persist a batch under [deviceId] — wired to `repository.insert`. Called off the main looper is
     *  fine; the implementation hops to its own IO scope (see [SourceCoordinator]). */
    private val persist: (StreamBatch, String) -> Unit,
    /** Diagnostic sink for the connect lifecycle. Wired (via [SourceCoordinator]) to the SAME in-app strap
     *  log the user exports, so the generic-HR path is no longer invisible in a bug report (issue #421).
     *  Every line is prefixed "HR-strap: " so it's distinguishable from WHOOP lines in the shared log.
     *  Default no-op keeps existing call sites compiling and tests silent. */
    private val log: (String) -> Unit = {},
    /** Optional hook fired with the strap's battery percent (0–100) whenever it's read off 0x2A19. Wired
     *  (via [SourceCoordinator]) into the WHOOP client's live battery field so a generic strap surfaces
     *  its charge the same place the WHOOP strap does. Default no-op keeps existing call sites compiling. */
    private val onBattery: (Int) -> Unit = {},
    /** Optional hook fired with the latest instantaneous speed/cadence/power from a connected standard
     *  fitness sensor (RSC/CSC/CPS), read ADDITIVELY alongside HR. This is a PURE ADDITIVE surface for the
     *  in-exercise readout — it never touches HR/R-R/persistence/scoring. Called on the main looper.
     *  Mirrors [FtmsSource.readingSink]. Default no-op keeps existing call sites compiling. */
    private val sensorSink: (SensorMetrics) -> Unit = {},
) {

    /** Live instantaneous fitness-sensor metrics surfaced via [sensorSink]. Any field is null when it
     *  isn't available yet (no such sensor, or a first CSC/CPS packet — derived values need two). */
    data class SensorMetrics(
        /** Instantaneous speed in km/h (RSC direct, or CSC/CPS derived from successive packets). */
        val speedKmh: Double? = null,
        /** Instantaneous cadence — running steps/min (RSC) or crank rpm (CSC/CPS). */
        val cadence: Double? = null,
        /** Instantaneous power in watts (CPS). */
        val powerWatts: Int? = null,
    )

    /** A generic HR strap seen during a scan (UI affordance). */
    data class DiscoveredStrap(val address: String, val name: String, val rssi: Int)

    private val _discovered = MutableStateFlow<List<DiscoveredStrap>>(emptyList())
    /** Straps discovered during the current scan, keyed by address (newest RSSI wins). */
    val discovered: StateFlow<List<DiscoveredStrap>> = _discovered.asStateFlow()

    private val _scanning = MutableStateFlow(false)
    /** True while a scan is running. */
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val _batteryPct = MutableStateFlow<Int?>(null)
    /** The connected strap's standard Battery Service (0x180F) level, 0–100, once read; null until then,
     *  for a strap without the battery service, or after disconnect (a stale value must not outlive the
     *  link). Surfaced on the device card the same way the WHOOP strap battery is. */
    val batteryPct: StateFlow<Int?> = _batteryPct.asStateFlow()

    // MARK: - Android Bluetooth handles (OWN scanner + GATT, separate from WHOOP)

    private val appContext = context.applicationContext
    private val bluetoothManager: BluetoothManager? =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager?.adapter
    private val scanner: BluetoothLeScanner? get() = adapter?.bluetoothLeScanner

    private var gatt: BluetoothGatt? = null
    /** Peripherals seen in the current scan, retained by address so a chosen one survives to connect. */
    private val seen = ConcurrentHashMap<String, BluetoothDevice>()
    /** A device asked to connect before a scan result for it landed (connect-by-address path). */
    private var pendingConnectAddress: String? = null

    /** Guards the single status-133 (Android GATT_ERROR) auto-retry; reset on a successful connect. */
    private var retried133 = false
    /** Address this source should keep reaching after an involuntary drop. Cleared by `stop()`. */
    private var reconnectAddress: String? = null
    /** Explicit user/coordinator teardown gate. Prevents a stale GATT callback from reviving the source. */
    private var intentionalDisconnect = false
    /** Consecutive ordinary reconnect attempts; drives the shared capped-exponential schedule. */
    private var failedReconnectAttempts = 0
    /** Named/cancellable deferred retry. Both the fast 133 retry and ordinary retry use this slot. */
    private var reconnectRunnable: Runnable? = null
    /** Logs the FIRST HR sample of a connection only (not every notification); reset on stop/disconnect. */
    private var loggedFirstHr = false

    /** Derives instantaneous speed/cadence from successive CSC/CPS cumulative counters. Per-source so a
     *  reconnect starts fresh (reset on stop/disconnect). Pure value type. */
    private val rateComputer = FitnessRateComputer()
    /** The last surfaced sensor metrics — a derived field we can't compute yet keeps its prior value
     *  rather than being zeroed, so the panel never shows a fabricated 0. */
    private var lastSensorMetrics = SensorMetrics()
    /** Logs the first fitness-sensor sample of a connection only; reset on stop/disconnect. */
    private var loggedFirstSensor = false

    /** All BLE work hops onto the main looper, matching the WHOOP client + CBCentralManager(queue:.main). */
    private val handler = Handler(Looper.getMainLooper())

    /** Setup operations are serialized because Android exposes only one asynchronous GATT slot. */
    private sealed interface SetupGattOperation {
        val characteristic: BluetoothGattCharacteristic
        val label: String
        val requiredForHr: Boolean

        data class EnableNotifications(
            override val characteristic: BluetoothGattCharacteristic,
            override val label: String,
            override val requiredForHr: Boolean,
        ) : SetupGattOperation

        data class Read(
            override val characteristic: BluetoothGattCharacteristic,
            override val label: String,
            override val requiredForHr: Boolean = false,
        ) : SetupGattOperation
    }

    private val setupQueue = GattOperationQueue<SetupGattOperation>(maxStartRetries = 3)
    /** A rejected start usually means Android's prior GATT slot has not quite cleared yet. */
    private val setupRetryRunnable = Runnable { gatt?.let(::drainGattSetupQueue) }
    /** Service discovery is asynchronous too; a missing callback must not leave a false connected state. */
    private val serviceDiscoveryTimeoutRunnable = Runnable {
        val g = gatt ?: return@Runnable
        log("HR-strap: service discovery timed out — reconnecting to recover the GATT session")
        abortGattSetupAndReconnect(g)
    }
    /** A missing required-HR callback reconnects; a missing optional callback is skipped to preserve HR. */
    private val setupTimeoutRunnable = Runnable {
        val g = gatt ?: return@Runnable
        val timedOut = setupQueue.timeoutCurrent() ?: return@Runnable
        when (gattOperationFailureAction(timedOut.requiredForHr)) {
            GattOperationFailureAction.RECONNECT -> {
                log("HR-strap: ${timedOut.label} timed out — reconnecting to recover the GATT session")
                abortGattSetupAndReconnect(g)
            }
            GattOperationFailureAction.SKIP_OPTIONAL -> {
                log("HR-strap: ${timedOut.label} timed out — skipping optional operation to preserve live HR")
                drainGattSetupQueue(g)
            }
        }
    }

    // MARK: - Sample buffer (flushed in batches off the per-notification hot loop)

    private data class Sample(val hr: Int, val rr: List<Int>, val ts: Long)
    private val bufferLock = Any()
    private val buffer = ArrayList<Sample>()
    private var lastFlushMs = System.currentTimeMillis()
    private val flushCount = 30
    private val flushIntervalMs = 30_000L

    // MARK: - Scanning

    /** Begin scanning for generic HR straps advertising the 0x180D service. */
    fun scan() {
        synchronized(bufferLock) { /* keep buffer across a rescan */ }
        seen.clear()
        _discovered.value = emptyList()
        _scanning.value = true
        log("HR-strap: scanning for standard heart-rate straps (0x180D)…")
        val sc = scanner ?: run {
            _scanning.value = false
            log("HR-strap: no BLE scanner available — Bluetooth may be off or unsupported")
            return
        }
        if (adapter?.isEnabled != true) {
            _scanning.value = false
            log("HR-strap: Bluetooth adapter is off — cannot scan")
            return
        }
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(HEART_RATE_SERVICE))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        sc.startScan(listOf(filter), settings, scanCallback)
    }

    /** Stop an in-progress scan. Idempotent. */
    fun stopScan() {
        _scanning.value = false
        if (adapter?.isEnabled == true) runCatching { scanner?.stopScan(scanCallback) }
    }

    // MARK: - Connecting

    /** Connect to the chosen discovered strap (by address) and start streaming its HR. */
    fun connect(address: String) {
        cancelScheduledReconnect()
        pendingConnectAddress = null
        reconnectAddress = address
        intentionalDisconnect = false
        failedReconnectAttempts = 0
        retried133 = false
        connectToAddress(address)
    }

    /** Execute one attempt without resetting user intent or the reconnect streak. */
    private fun connectToAddress(address: String) {
        if (!PeripheralReconnectPolicy.shouldReconnect(intentionalDisconnect, reconnectAddress != null) ||
            reconnectAddress != address
        ) return
        stopScan()
        val device = seen[address] ?: runCatching { adapter?.getRemoteDevice(address) }.getOrNull()
        if (device == null) {
            pendingConnectAddress = address
            log("HR-strap: saved strap is not cached — scanning to find it")
            scan()
            return
        }
        connectToDevice(device)
    }

    private fun connectToDevice(device: BluetoothDevice) {
        if (!PeripheralReconnectPolicy.shouldReconnect(
                intentionalDisconnect,
                reconnectAddress != null,
            ) || reconnectAddress != device.address
        ) return
        log("HR-strap: connecting to ${device.address}")
        resetGattSetupQueue()
        // Tear down any prior link first so we never run two GATTs for this source.
        gatt?.let(::disconnectAndClose)
        // connectGatt can throw (SecurityException if BLUETOOTH_CONNECT was revoked mid-session,
        // IllegalArgumentException on a stale device) — never let that crash the app; the caller (and
        // the SourceCoordinator reconcile guard) treat a failed start as "stay on the previous source".
        gatt = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                device.connectGatt(appContext, false, gattCallback)
            }
        }.getOrElse {
            log("HR-strap: connectGatt failed (${it.javaClass.simpleName}: ${it.message})")
            scheduleReconnect()
            null
        }
    }

    private fun cancelScheduledReconnect() {
        reconnectRunnable?.let(handler::removeCallbacks)
        reconnectRunnable = null
    }

    /** Schedule a normal capped-backoff attempt, or the one-shot 1s Android status-133 recovery. */
    private fun scheduleReconnect(fast133Retry: Boolean = false) {
        val address = reconnectAddress
        if (!PeripheralReconnectPolicy.shouldReconnect(intentionalDisconnect, address != null) || address == null) return

        cancelScheduledReconnect()
        val delayMs = if (fast133Retry) {
            1_000L
        } else {
            failedReconnectAttempts += 1
            PeripheralReconnectPolicy.delayMs(failedReconnectAttempts)
        }
        val label = if (fast133Retry) "connect error 133 — retrying once" else "reconnecting"
        log("HR-strap: $label in ${delayMs / 1_000}s" +
            if (fast133Retry) "" else " (attempt $failedReconnectAttempts)")
        val task = Runnable {
            if (!PeripheralReconnectPolicy.shouldReconnect(intentionalDisconnect, reconnectAddress != null) ||
                reconnectAddress != address) return@Runnable
            reconnectRunnable = null
            connectToAddress(address)
        }
        reconnectRunnable = task
        handler.postDelayed(task, delayMs)
    }

    /** Tear down: cancel the connection and stop scanning, persisting anything still buffered. Idempotent. */
    fun stop() {
        intentionalDisconnect = true
        reconnectAddress = null
        failedReconnectAttempts = 0
        retried133 = false
        cancelScheduledReconnect()
        resetGattSetupQueue()
        stopScan()
        pendingConnectAddress = null
        gatt?.let(::disconnectAndClose)
        gatt = null
        loggedFirstHr = false   // a later reconnect should log its first sample again
        loggedFirstSensor = false
        _batteryPct.value = null // a stale charge must not outlive the link
        flush()
        clearSensorState()       // a stale speed/cadence/power panel must not outlive the link
    }

    /** Reset the additive fitness-sensor state (rate-computer baselines + last metrics) so a reconnect /
     *  new session starts fresh and the next CSC/CPS packet is treated as a first packet. */
    private fun clearSensorState() {
        rateComputer.reset()
        lastSensorMetrics = SensorMetrics()
        handler.post { guardedCallback("sensor-clear") { sensorSink(SensorMetrics()) } }
    }

    // MARK: - Buffer / persistence

    private fun enqueue(hr: Int, rr: List<Int>) {
        val shouldFlush = synchronized(bufferLock) {
            buffer.add(Sample(hr, rr, System.currentTimeMillis() / 1000L))
            buffer.size >= flushCount ||
                System.currentTimeMillis() - lastFlushMs >= flushIntervalMs
        }
        if (shouldFlush) flush()
    }

    private fun flush() {
        val snapshot = synchronized(bufferLock) {
            lastFlushMs = System.currentTimeMillis()
            if (buffer.isEmpty()) return
            val s = ArrayList(buffer); buffer.clear(); s
        }
        // Mirror StandardHRMapping: HrRow + RrRow only. HR is range-gated (off-wrist 0/garbage dropped);
        // R-R is gated to physiologically plausible beat-to-beat ms, matching ingestStandardHr.
        val hrRows = ArrayList<HrRow>()
        val rrRows = ArrayList<RrRow>()
        for (s in snapshot) {
            if (s.hr in 30..220) hrRows.add(HrRow(s.ts, s.hr))
            for (r in s.rr) if (r in 250..3000) rrRows.add(RrRow(s.ts, r))
        }
        if (hrRows.isNotEmpty() || rrRows.isNotEmpty()) {
            persist(StreamBatch(hr = hrRows, rr = rrRows), deviceId)
        }
    }

    // MARK: - Scan callback

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device ?: return
            val address = device.address ?: return
            val firstSight = seen.put(address, device) == null   // null → not seen before this scan
            val name = result.scanRecord?.deviceName ?: runCatching { device.name }.getOrNull()
                ?: "Heart Rate Strap"
            if (firstSight) log("HR-strap: found $name ($address) rssi ${result.rssi}")
            val strap = DiscoveredStrap(address = address, name = name, rssi = result.rssi)
            val list = _discovered.value.toMutableList()
            val i = list.indexOfFirst { it.address == address }
            if (i >= 0) list[i] = strap else list.add(strap)
            _discovered.value = list
            // Replay a connect intent that arrived before the device was discovered.
            if (pendingConnectAddress == address) {
                pendingConnectAddress = null
                handler.post {
                    if (PeripheralReconnectPolicy.shouldReconnect(
                            intentionalDisconnect,
                            reconnectAddress != null,
                        ) && reconnectAddress == address
                    ) connectToDevice(device)
                }
            }
        }
    }

    // MARK: - GATT callback

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) = guardedCallback("connection-state") {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    if (gatt !== g) {
                        log("HR-strap: ignoring stale connection callback")
                        disconnectAndClose(g)
                        return@guardedCallback
                    }
                    if (status != BluetoothGatt.GATT_SUCCESS) {
                        // CONNECTED reported but with a non-success status — unusual; surface it loudly.
                        log("HR-strap: WARNING connected with non-success status=$status")
                    }
                    retried133 = false   // a real connection clears the one-shot 133 retry guard
                    cancelScheduledReconnect()
                    log("HR-strap: connected (status=$status) — discovering services")
                    handler.post { beginServiceDiscovery(g) }
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    if (gatt !== g) {
                        runCatching { g.close() }
                        return@guardedCallback
                    }
                    log("HR-strap: disconnected (status=$status)")
                    resetGattSetupQueue()
                    loggedFirstHr = false   // a reconnect should log its first sample again
                    loggedFirstSensor = false
                    _batteryPct.value = null // a stale charge must not outlive the link
                    flush()
                    clearSensorState()
                    if (gatt === g) { runCatching { g.close() }; gatt = null }
                    // Status 133 gets one fast recovery attempt; a repeat joins the normal bounded loop.
                    if (status == GATT_ERROR_133) {
                        if (!retried133) {
                            retried133 = true
                            scheduleReconnect(fast133Retry = true)
                        } else {
                            log("HR-strap: still failing (133) — try forgetting the strap in " +
                                "Android Settings → Bluetooth, then re-pair.")
                            scheduleReconnect()
                        }
                    } else {
                        scheduleReconnect()
                    }
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            handler.post { configureDiscoveredServices(g, status) }
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            if (descriptor.uuid != CCCD) return
            handler.post {
                guardedCallback("descriptor-write") {
                    val characteristicUuid = descriptor.characteristic.uuid
                    completeGattSetupOperation(g, status) {
                        it is SetupGattOperation.EnableNotifications &&
                            it.characteristic.uuid == characteristicUuid
                    }
                }
            }
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            if (gatt !== g) return
            when (ch.uuid) {
                HEART_RATE_CHAR -> handleHr(value)
                in FITNESS_SENSOR_UUID16.keys -> handleFitnessSensor(ch.uuid, value)
            }
        }

        // Legacy (< API 33) characteristic-changed callback: read the value off the characteristic.
        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            if (gatt !== g) return
            when (ch.uuid) {
                HEART_RATE_CHAR -> handleHr(ch.value ?: return)
                in FITNESS_SENSOR_UUID16.keys -> handleFitnessSensor(ch.uuid, ch.value ?: return)
            }
        }

        // API 33+ read result — the battery level read requested in onServicesDiscovered.
        override fun onCharacteristicRead(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            val snapshot = value.copyOf()
            handler.post { handleGattCharacteristicRead(g, ch.uuid, snapshot, status) }
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            val value = ch.value?.copyOf() ?: byteArrayOf()
            handler.post { handleGattCharacteristicRead(g, ch.uuid, value, status) }
        }
    }

    private fun beginServiceDiscovery(g: BluetoothGatt) = guardedCallback("service-discovery start") {
        if (gatt !== g) return@guardedCallback
        val started = runCatching { g.discoverServices() }.getOrElse {
            log("HR-strap: service discovery start error (${it.javaClass.simpleName}: ${it.message})")
            false
        }
        if (!started) {
            log("HR-strap: service discovery request was rejected — reconnecting")
            abortGattSetupAndReconnect(g)
            return@guardedCallback
        }
        handler.removeCallbacks(serviceDiscoveryTimeoutRunnable)
        handler.postDelayed(serviceDiscoveryTimeoutRunnable, GATT_SETUP_TIMEOUT_MS)
    }

    private fun configureDiscoveredServices(g: BluetoothGatt, status: Int): Unit = guardedCallback("services-discovered") {
        if (gatt !== g) {
            log("HR-strap: ignoring stale services-discovered callback")
            return@guardedCallback
        }
        handler.removeCallbacks(serviceDiscoveryTimeoutRunnable)
        log("HR-strap: services discovered (status=$status)")
        if (status != BluetoothGatt.GATT_SUCCESS) {
            log("HR-strap: WARNING service discovery failed (status=$status) — reconnecting")
            abortGattSetupAndReconnect(g)
            return@guardedCallback
        }
        val svc = g.getService(HEART_RATE_SERVICE)
        if (svc == null) {
            log("HR-strap: 0x180D heart-rate service NOT FOUND after filtered scan — reconnecting")
            abortGattSetupAndReconnect(g)
            return@guardedCallback
        }
        log("HR-strap: 0x180D heart-rate service FOUND")
        val hr = svc.getCharacteristic(HEART_RATE_CHAR)
        if (hr == null) {
            log("HR-strap: 0x2A37 measurement characteristic NOT FOUND — reconnecting")
            abortGattSetupAndReconnect(g)
            return@guardedCallback
        }
        log("HR-strap: 0x2A37 measurement characteristic found")
        if (hr.getDescriptor(CCCD) == null) {
            log("HR-strap: WARNING 0x2A37 has no CCCD (0x2902) — reconnecting")
            abortGattSetupAndReconnect(g)
            return@guardedCallback
        }

        resetGattSetupQueue()
        setupQueue.enqueue(SetupGattOperation.EnableNotifications(
            characteristic = hr,
            label = "heart-rate notification setup",
            requiredForHr = true,
        ))

        // Read Battery Level only after the HR CCCD callback releases Android's single GATT slot.
        g.getService(BATTERY_SERVICE)?.getCharacteristic(BATTERY_CHAR)?.let { battery ->
            log("HR-strap: 0x180F battery service found — queueing level read")
            setupQueue.enqueue(SetupGattOperation.Read(
                characteristic = battery,
                label = "battery read",
            ))
        }

        // Additive RSC/CSC/CPS subscriptions follow in the same queue. A missing optional CCCD is skipped
        // without affecting the required HR subscription or any later operation.
        for ((svcUuid, charUuid) in FITNESS_SENSOR_CHARS) {
            val sensor = g.getService(svcUuid)?.getCharacteristic(charUuid) ?: continue
            if (sensor.getDescriptor(CCCD) == null) {
                log("HR-strap: WARNING $charUuid has no CCCD (0x2902) — skipping optional notifications")
                continue
            }
            log("HR-strap: fitness-sensor characteristic $charUuid found — queueing notifications")
            setupQueue.enqueue(SetupGattOperation.EnableNotifications(
                characteristic = sensor,
                label = "fitness-sensor $charUuid notification setup",
                requiredForHr = false,
            ))
        }
        drainGattSetupQueue(g)
    }

    /** Start exactly one queued read/CCCD write. The matching callback is the only path to the next item. */
    private fun drainGattSetupQueue(g: BluetoothGatt): Unit = guardedCallback("GATT setup") {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { drainGattSetupQueue(g) }
            return@guardedCallback
        }
        if (gatt !== g) return@guardedCallback
        val operation = setupQueue.beginNext()
        if (operation == null) {
            if (setupQueue.isIdle) {
                failedReconnectAttempts = 0
                log("HR-strap: GATT setup complete — all queued operations finished")
            }
            return@guardedCallback
        }

        val started = runCatching {
            when (operation) {
                is SetupGattOperation.EnableNotifications -> startNotificationSetup(g, operation.characteristic)
                is SetupGattOperation.Read -> g.readCharacteristic(operation.characteristic)
            }
        }.getOrElse {
            log("HR-strap: ${operation.label} start error (${it.javaClass.simpleName}: ${it.message})")
            false
        }

        if (started) {
            log("HR-strap: ${operation.label} requested")
            handler.removeCallbacks(setupTimeoutRunnable)
            handler.postDelayed(setupTimeoutRunnable, GATT_SETUP_TIMEOUT_MS)
            return@guardedCallback
        }

        val rejection = setupQueue.rejectCurrentStart() ?: return@guardedCallback
        if (rejection.willRetry) {
            log("HR-strap: ${operation.label} busy — retrying start " +
                "${rejection.rejectionNumber}/$MAX_GATT_START_RETRIES")
            handler.removeCallbacks(setupRetryRunnable)
            handler.postDelayed(setupRetryRunnable, GATT_START_RETRY_DELAY_MS)
        } else {
            when (gattOperationFailureAction(operation.requiredForHr)) {
                GattOperationFailureAction.RECONNECT -> {
                    log("HR-strap: ${operation.label} could not start — reconnecting")
                    abortGattSetupAndReconnect(g)
                }
                GattOperationFailureAction.SKIP_OPTIONAL -> {
                    log("HR-strap: ${operation.label} could not start — skipping optional operation")
                    drainGattSetupQueue(g)
                }
            }
        }
    }

    private fun startNotificationSetup(g: BluetoothGatt, ch: BluetoothGattCharacteristic): Boolean {
        if (!g.setCharacteristicNotification(ch, true)) return false
        val cccd = ch.getDescriptor(CCCD) ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ==
                BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                g.writeDescriptor(cccd)
            }
        }
    }

    private fun completeGattSetupOperation(
        g: BluetoothGatt,
        status: Int,
        matches: (SetupGattOperation) -> Boolean,
    ): Unit = guardedCallback("GATT setup callback") {
        if (gatt !== g) return@guardedCallback
        val completed = setupQueue.completeIf(matches) ?: return@guardedCallback
        handler.removeCallbacks(setupTimeoutRunnable)
        if (status == BluetoothGatt.GATT_SUCCESS) {
            log("HR-strap: ${completed.label} completed")
            drainGattSetupQueue(g)
        } else {
            when (gattOperationFailureAction(completed.requiredForHr)) {
                GattOperationFailureAction.RECONNECT -> {
                    log("HR-strap: WARNING ${completed.label} failed (status=$status) — reconnecting")
                    abortGattSetupAndReconnect(g)
                }
                GattOperationFailureAction.SKIP_OPTIONAL -> {
                    log("HR-strap: WARNING ${completed.label} failed (status=$status) — continuing")
                    drainGattSetupQueue(g)
                }
            }
        }
    }

    private fun handleGattCharacteristicRead(
        g: BluetoothGatt,
        characteristicUuid: UUID,
        value: ByteArray,
        status: Int,
    ): Unit = guardedCallback("characteristic-read") {
        if (gatt !== g) return@guardedCallback
        if (characteristicUuid == BATTERY_CHAR && status == BluetoothGatt.GATT_SUCCESS) {
            handleBattery(value)
        }
        completeGattSetupOperation(g, status) {
            it is SetupGattOperation.Read && it.characteristic.uuid == characteristicUuid
        }
    }

    private fun resetGattSetupQueue() {
        handler.removeCallbacks(serviceDiscoveryTimeoutRunnable)
        handler.removeCallbacks(setupRetryRunnable)
        handler.removeCallbacks(setupTimeoutRunnable)
        setupQueue.clear()
    }

    /** Close a wedged setup session and enter the same bounded reconnect loop as a real disconnect. */
    private fun abortGattSetupAndReconnect(g: BluetoothGatt) {
        if (gatt !== g) return
        resetGattSetupQueue()
        loggedFirstHr = false
        loggedFirstSensor = false
        _batteryPct.value = null
        flush()
        clearSensorState()
        disconnectAndClose(g)
        gatt = null
        scheduleReconnect()
    }

    /** Always attempt close even when disconnect throws because the Android binder is already dead. */
    private fun disconnectAndClose(g: BluetoothGatt) {
        runCatching { g.disconnect() }
        runCatching { g.close() }
    }

    /**
     * Run a GATT-callback body so a throw on the binder thread (or the posted main-thread block) can
     * never crash the app. BLE callbacks run outside any of our try/catch and outside the
     * SourceCoordinator reconcile guard, so before this an exception in service-discovery, the HR
     * parse, or the live-HR sink would crash the process — and because the strap is the persisted
     * active source, it crash-LOOPED on every launch (#421 regression). A misbehaving strap must
     * degrade to "no data", never take the app down. The message lands in the exportable strap log.
     */
    private fun guardedCallback(label: String, block: () -> Unit) {
        runCatching(block).onFailure {
            log("HR-strap: $label error (${it.javaClass.simpleName}: ${it.message})")
        }
    }

    private fun handleBattery(data: ByteArray) = guardedCallback("battery-parse") {
        val pct = StandardBattery.parse(data) ?: return@guardedCallback
        log("HR-strap: battery $pct%")
        _batteryPct.value = pct
        handler.post { guardedCallback("battery-sink") { onBattery(pct) } }
    }

    /**
     * Decode one RSC/CSC/CPS measurement and surface instantaneous speed/cadence/power on [sensorSink].
     * RSC carries speed + cadence directly; CSC/CPS carry cumulative counters the rate computer turns into
     * instantaneous values; CPS carries power directly. A field we can't derive yet (a first CSC/CPS
     * packet) keeps its prior value rather than being zeroed. Nothing here writes HR/R-R/persistence/scoring.
     */
    private fun handleFitnessSensor(charUuid: UUID, data: ByteArray) = guardedCallback("sensor-parse") {
        val uuid16 = FITNESS_SENSOR_UUID16[charUuid] ?: return@guardedCallback
        val reading = FitnessSensor.decode(uuid16, data) ?: return@guardedCallback
        if (!loggedFirstSensor) {
            loggedFirstSensor = true
            log("HR-strap: receiving ${reading.kind.displayName} data — first reading")
        }
        var metrics = lastSensorMetrics
        // RSC: direct instantaneous speed + cadence.
        reading.speedKmh?.let { metrics = metrics.copy(speedKmh = it) }
        reading.runningCadenceSpm?.let { metrics = metrics.copy(cadence = it.toDouble()) }
        // CPS: direct instantaneous power.
        reading.instantaneousPowerWatts?.let { metrics = metrics.copy(powerWatts = it) }
        // CSC / CPS: derive instantaneous speed/cadence from successive cumulative counters.
        val rates = rateComputer.update(reading)
        rates.speedKmh?.let { metrics = metrics.copy(speedKmh = it) }
        rates.crankRpm?.let { metrics = metrics.copy(cadence = it) }
        lastSensorMetrics = metrics
        handler.post { guardedCallback("sensor-sink") { sensorSink(metrics) } }
    }

    private fun handleHr(data: ByteArray) = guardedCallback("hr-parse") {
        val parsed = StandardHeartRate.parse(data) ?: return@guardedCallback
        // Log the FIRST sample of a connection only — proof that data is flowing — never every sample.
        if (!loggedFirstHr) {
            loggedFirstHr = true
            log("HR-strap: receiving data — first sample ${parsed.hr} bpm (rr beats: ${parsed.rr.size})")
        }
        // Surface live HR on the main looper (the UI's StateFlow expects main-thread updates).
        handler.post { guardedCallback("live-sink") { liveSink(parsed.hr, parsed.rr) } }
        enqueue(parsed.hr, parsed.rr)
    }

    companion object {
        private const val MAX_GATT_START_RETRIES = 3
        private const val GATT_START_RETRY_DELAY_MS = 250L
        private const val GATT_SETUP_TIMEOUT_MS = 8_000L
        /** Standard BLE Heart Rate service + measurement characteristic + the CCCD. */
        val HEART_RATE_SERVICE: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        val HEART_RATE_CHAR: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** Standard BLE Battery Service + Battery Level characteristic (a generic strap usually has these). */
        private val BATTERY_SERVICE: UUID = UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb")
        private val BATTERY_CHAR: UUID = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")

        /** Standard fitness-sensor services + measurement characteristics, read ADDITIVELY alongside HR. */
        private val RSC_SERVICE: UUID = UUID.fromString("00001814-0000-1000-8000-00805f9b34fb")
        private val RSC_CHAR: UUID = UUID.fromString("00002a53-0000-1000-8000-00805f9b34fb")
        private val CSC_SERVICE: UUID = UUID.fromString("00001816-0000-1000-8000-00805f9b34fb")
        private val CSC_CHAR: UUID = UUID.fromString("00002a5b-0000-1000-8000-00805f9b34fb")
        private val CPS_SERVICE: UUID = UUID.fromString("00001818-0000-1000-8000-00805f9b34fb")
        private val CPS_CHAR: UUID = UUID.fromString("00002a63-0000-1000-8000-00805f9b34fb")

        /** (service, measurement) pairs to discover + subscribe additively. */
        private val FITNESS_SENSOR_CHARS: List<Pair<UUID, UUID>> = listOf(
            RSC_SERVICE to RSC_CHAR, CSC_SERVICE to CSC_CHAR, CPS_SERVICE to CPS_CHAR,
        )

        /** Measurement-characteristic UUID → its 16-bit short form, for the decode dispatch. */
        private val FITNESS_SENSOR_UUID16: Map<UUID, String> = mapOf(
            RSC_CHAR to "2A53", CSC_CHAR to "2A5B", CPS_CHAR to "2A63",
        )

        /** Android's infamous generic GATT connect failure (`BluetoothGatt.GATT_ERROR`, not a public
         *  constant) — almost always a transient stack/race issue. We auto-retry it once. */
        private const val GATT_ERROR_133 = 133

        // MARK: - Honest display formatters for the additive in-workout sensor readout
        //
        // Pure functions (no Android, no I/O) so the Live screen and a JVM test both call them; faithful
        // twin of Swift `LiveState.formatSensor*`. Each returns null when the field is absent / nonsensical
        // (the UI then hides that tile rather than show a fabricated value). Units are the sensor's native
        // ones — no unit-conversion guessing: speed km/h (the decode/derivation unit), cadence per-minute
        // (steps/min for a footpod, crank rpm for a bike sensor — both "/min"; the metric doesn't carry the
        // kind, so the neutral honest label is used), power watts.

        /** Speed in km/h as one decimal, or null when absent / negative / non-finite. */
        fun formatSpeedKmh(kmh: Double?): String? {
            if (kmh == null || !kmh.isFinite() || kmh < 0.0) return null
            return String.format("%.1f", kmh)
        }

        /** Cadence (per-minute) rounded to a whole number, or null when absent / negative / non-finite. */
        fun formatCadence(perMin: Double?): String? {
            if (perMin == null || !perMin.isFinite() || perMin < 0.0) return null
            return Math.round(perMin).toString()
        }

        /** Power in whole watts, or null when absent / negative. */
        fun formatPowerWatts(watts: Int?): String? {
            if (watts == null || watts < 0) return null
            return watts.toString()
        }
    }
}
