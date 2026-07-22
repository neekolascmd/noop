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
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.noop.data.HrRow
import com.noop.data.StreamBatch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * EXPERIMENTAL, ISOLATED live-BLE source for the Huami family — Amazfit / Zepp (incl. Helio ring/band)
 * and Xiaomi Mi Band.
 *
 * Faithful Kotlin twin of Strand/BLE/HuamiHRSource.swift.
 *
 * "EXPERIMENTAL, HELP US TEST": best-effort, clean-room driver built from PUBLICLY DOCUMENTED protocol
 * FACTS (open projects document the Huami GATT layout; we reuse only the facts and wrote our own code —
 * no GPL/AGPL code copied). Shipped behind the experimental add-device tier because it can't be
 * hardware-verified here. It NEVER fabricates data: if it can't read a real HR it stays at "—".
 *
 * WHOOP-FIRST ISOLATION (identical to [StandardHrSource]): own scan + [BluetoothGatt], never touches
 * [WhoopBleClient]. Shared surfaces are injected closures: [liveSink], [persist], [log], [onBattery].
 *
 * HR strategy, honest at each step:
 *   1. Prefer the STANDARD SIG Heart Rate Service (0x180D / 0x2A37) — newer bands expose it; identical to
 *      [StandardHrSource]. Decoded via [StandardHeartRate].
 *   2. Else the documented Huami custom HR-measurement characteristic (on the Huami 0xFEE0 service). Many
 *      bands expose live HR here with NO auth handshake. Decoded via [HuamiHeartRate].
 *   3. If NEITHER is readable (the band needs the Huami auth pairing we don't implement), publish an
 *      HONEST message via [needsPairing] and stay disconnected from data — never fake a reading.
 *
 * Android runtime-permission notes (same contract as [WhoopBleClient]/[StandardHrSource]): the caller
 * must hold BLUETOOTH_SCAN + BLUETOOTH_CONNECT before [scan]/[connect].
 */
@SuppressLint("MissingPermission")
class HuamiHrSource(
    context: Context,
    /** Datastore device id every sample is stamped with (the active Huami device's registry id). */
    private val deviceId: String,
    /** Push live HR (bpm) into whatever the UI observes. Called on the main looper. */
    private val liveSink: (hr: Int) -> Unit,
    /** Persist a batch under [deviceId] — wired to `repository.insert`. */
    private val persist: (StreamBatch, String) -> Unit = { _, _ -> },
    /** Diagnostic sink for the connect lifecycle — the SAME exportable strap log (issue #421). Every line
     *  is prefixed "Huami: " so it's distinguishable in the shared log. Default no-op keeps tests silent. */
    private val log: (String) -> Unit = {},
    /** Fired with the band's battery percent (0–100) when read off 0x2A19. */
    private val onBattery: (Int) -> Unit = {},
) {

    /** A Huami-family device seen during a scan (UI affordance). */
    data class DiscoveredDevice(val address: String, val name: String, val rssi: Int)

    private val _discovered = MutableStateFlow<List<DiscoveredDevice>>(emptyList())
    val discovered: StateFlow<List<DiscoveredDevice>> = _discovered.asStateFlow()

    private val _scanning = MutableStateFlow(false)
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val _batteryPct = MutableStateFlow<Int?>(null)
    val batteryPct: StateFlow<Int?> = _batteryPct.asStateFlow()

    private val _needsPairing = MutableStateFlow<String?>(null)
    /** Set to an HONEST explanation when the band needed the Huami auth pairing we can't do (no standard
     *  HR service AND no readable Huami HR characteristic). null otherwise; cleared on stop/disconnect. */
    val needsPairing: StateFlow<String?> = _needsPairing.asStateFlow()

    // MARK: - Android Bluetooth handles (OWN scanner + GATT, separate from WHOOP)

    private val appContext = context.applicationContext
    private val bluetoothManager: BluetoothManager? =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager?.adapter
    private val scanner: BluetoothLeScanner? get() = adapter?.bluetoothLeScanner

    private var gatt: BluetoothGatt? = null
    private val seen = ConcurrentHashMap<String, BluetoothDevice>()
    private var pendingConnectAddress: String? = null
    private var retried133 = false
    private var loggedFirstHr = false

    private var reconnectAddress: String? = null
    private var intentionalDisconnect = false
    private var failedReconnectAttempts = 0
    private var reconnectRunnable: Runnable? = null

    private val handler = Handler(Looper.getMainLooper())

    private val setupQueue = GattOperationQueue<AndroidGattSetupOperation>(maxStartRetries = 3)
    private var hrSubscriptionCandidate = false
    private var hrSubscriptionEnabled = false
    private var hrSetupTransportFailure = false
    private var setupFinalized = false
    private val setupRetryRunnable = Runnable { gatt?.let(::drainGattSetupQueue) }
    private val serviceDiscoveryTimeoutRunnable = Runnable {
        val g = gatt ?: return@Runnable
        log("Huami: service discovery timed out — reconnecting")
        abortGattSetupAndReconnect(g)
    }
    private val setupTimeoutRunnable = Runnable {
        val g = gatt ?: return@Runnable
        val timedOut = setupQueue.timeoutCurrent() ?: return@Runnable
        if (timedOut is AndroidGattSetupOperation.EnableNotifications) {
            if (loggedFirstHr) {
                hrSubscriptionEnabled = true
                log("Huami: ${timedOut.label} callback timed out, but live HR already proves the stream")
            } else {
                hrSetupTransportFailure = true
            }
        }
        if (!hrSubscriptionEnabled) log("Huami: ${timedOut.label} timed out — continuing queued setup")
        drainGattSetupQueue(g)
    }

    // MARK: - Sample buffer

    private data class Sample(val hr: Int, val ts: Long)
    private val bufferLock = Any()
    private val buffer = ArrayList<Sample>()
    private var lastFlushMs = System.currentTimeMillis()
    private val flushCount = 30
    private val flushIntervalMs = 30_000L

    // MARK: - Scanning

    /**
     * Scan for Huami-family devices. We can't filter by one service (some advertise 0x180D, some the Huami
     * 0xFEE0, some neither), so scan broadly and keep only the ones whose advertised name reads as an
     * Amazfit / Zepp / Mi Band ([ExperimentalBrand]).
     */
    fun scan() {
        seen.clear()
        _discovered.value = emptyList()
        _scanning.value = true
        _needsPairing.value = null
        log("Huami: scanning for Amazfit / Zepp / Mi Band devices…")
        val sc = scanner ?: run {
            _scanning.value = false
            log("Huami: no BLE scanner available — Bluetooth may be off or unsupported")
            return
        }
        if (adapter?.isEnabled != true) {
            _scanning.value = false
            log("Huami: Bluetooth adapter is off — cannot scan")
            return
        }
        // No ScanFilter (broad scan); the callback filters by recognised name.
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        sc.startScan(null, settings, scanCallback)
    }

    fun stopScan() {
        _scanning.value = false
        if (adapter?.isEnabled == true) runCatching { scanner?.stopScan(scanCallback) }
    }

    // MARK: - Connecting

    fun connect(address: String) {
        cancelScheduledReconnect()
        pendingConnectAddress = null
        reconnectAddress = address
        intentionalDisconnect = false
        failedReconnectAttempts = 0
        retried133 = false
        _needsPairing.value = null
        connectToAddress(address)
    }

    private fun connectToAddress(address: String) {
        if (!PeripheralReconnectPolicy.shouldReconnect(intentionalDisconnect, reconnectAddress != null) ||
            reconnectAddress != address
        ) return
        stopScan()
        val device = seen[address] ?: runCatching { adapter?.getRemoteDevice(address) }.getOrNull()
        if (device == null) {
            pendingConnectAddress = address
            log("Huami: saved device isn't cached — scanning to find it")
            scan()
            return
        }
        connectToDevice(device)
    }

    private fun connectToDevice(device: BluetoothDevice) {
        if (!PeripheralReconnectPolicy.shouldReconnect(intentionalDisconnect, reconnectAddress != null) ||
            reconnectAddress != device.address
        ) return
        log("Huami: connecting to ${device.address}")
        resetGattSetupQueue()
        gatt?.let(::disconnectAndClose)
        gatt = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                device.connectGatt(appContext, false, gattCallback)
            }
        }.getOrElse {
            log("Huami: connectGatt failed (${it.javaClass.simpleName}: ${it.message})")
            scheduleReconnect()
            null
        }
    }

    private fun cancelScheduledReconnect() {
        reconnectRunnable?.let(handler::removeCallbacks)
        reconnectRunnable = null
    }

    private fun scheduleReconnect(fast133Retry: Boolean = false) {
        val address = reconnectAddress
        if (!PeripheralReconnectPolicy.shouldReconnect(intentionalDisconnect, address != null) || address == null) return
        cancelScheduledReconnect()
        val delayMs = if (fast133Retry) 1_000L else {
            failedReconnectAttempts += 1
            PeripheralReconnectPolicy.delayMs(failedReconnectAttempts)
        }
        val label = if (fast133Retry) "connect error 133 — retrying once" else "reconnecting"
        log("Huami: $label in ${delayMs / 1_000}s" +
            if (fast133Retry) "" else " (attempt $failedReconnectAttempts)")
        val task = Runnable {
            if (!PeripheralReconnectPolicy.shouldReconnect(intentionalDisconnect, reconnectAddress != null) ||
                reconnectAddress != address
            ) return@Runnable
            reconnectRunnable = null
            connectToAddress(address)
        }
        reconnectRunnable = task
        handler.postDelayed(task, delayMs)
    }

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
        loggedFirstHr = false
        _batteryPct.value = null
        _needsPairing.value = null
        flush()
    }

    // MARK: - Buffer / persistence

    private fun enqueue(hr: Int) {
        val shouldFlush = synchronized(bufferLock) {
            buffer.add(Sample(hr, System.currentTimeMillis() / 1000L))
            buffer.size >= flushCount || System.currentTimeMillis() - lastFlushMs >= flushIntervalMs
        }
        if (shouldFlush) flush()
    }

    private fun flush() {
        val snapshot = synchronized(bufferLock) {
            lastFlushMs = System.currentTimeMillis()
            if (buffer.isEmpty()) return
            val s = ArrayList(buffer); buffer.clear(); s
        }
        // HR-only (no R-R on the Huami custom char). Same range gate the standard path uses.
        val hrRows = ArrayList<HrRow>()
        for (s in snapshot) if (s.hr in 30..220) hrRows.add(HrRow(s.ts, s.hr))
        if (hrRows.isNotEmpty()) persist(StreamBatch(hr = hrRows, rr = emptyList()), deviceId)
    }

    private fun ingest(hr: Int) {
        if (hr !in 30..220) return   // out of range → dropped, never shown / persisted
        if (!loggedFirstHr) {
            loggedFirstHr = true
            log("Huami: receiving data — first sample $hr bpm")
        }
        guarded("live-sink") { liveSink(hr) }
        enqueue(hr)
    }

    // MARK: - Scan callback

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device ?: return
            val address = device.address ?: return
            val name = result.scanRecord?.deviceName ?: runCatching { device.name }.getOrNull() ?: ""
            // Keep only recognised Amazfit / Zepp / Mi Band devices — a broad scan sees everything nearby.
            val brand = ExperimentalBrand.recognise(name)
            if (brand != ExperimentalBrand.AMAZFIT && brand != ExperimentalBrand.MI_BAND) return
            val firstSight = seen.put(address, device) == null
            if (firstSight) log("Huami: found $name ($address) rssi ${result.rssi}")
            val dev = DiscoveredDevice(
                address = address,
                name = name.ifBlank { brand.displayBrand },
                rssi = result.rssi,
            )
            val list = _discovered.value.toMutableList()
            val i = list.indexOfFirst { it.address == address }
            if (i >= 0) list[i] = dev else list.add(dev)
            _discovered.value = list
            if (pendingConnectAddress == address) {
                pendingConnectAddress = null
                handler.post {
                    if (PeripheralReconnectPolicy.shouldReconnect(intentionalDisconnect, reconnectAddress != null) &&
                        reconnectAddress == address
                    ) connectToDevice(device)
                }
            }
        }
    }

    // MARK: - GATT callback

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            handler.post { handleConnectionStateChange(g, status, newState) }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            handler.post { configureDiscoveredServices(g, status) }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (descriptor.uuid != GATT_CLIENT_CHARACTERISTIC_CONFIG_UUID) return
            handler.post {
                guarded("descriptor-write") {
                    val characteristicUuid = descriptor.characteristic.uuid
                    completeGattSetupOperation(g, status) {
                        it is AndroidGattSetupOperation.EnableNotifications &&
                            it.characteristic.uuid == characteristicUuid
                    }
                }
            }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray) {
            val snapshot = value.copyOf()
            handler.post {
                if (gatt !== g) return@post
                handleHr(ch.uuid, snapshot)
            }
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            val snapshot = ch.value?.copyOf() ?: return
            handler.post {
                if (gatt !== g) return@post
                handleHr(ch.uuid, snapshot)
            }
        }

        override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
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

    private fun handleConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) =
        guarded("connection-state") {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    if (gatt !== g) {
                        log("Huami: ignoring stale connection callback")
                        disconnectAndClose(g)
                        return@guarded
                    }
                    cancelScheduledReconnect()
                    log("Huami: connected (status=$status) — discovering services")
                    beginServiceDiscovery(g)
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    if (gatt !== g) {
                        runCatching { g.close() }
                        return@guarded
                    }
                    log("Huami: disconnected (status=$status)")
                    resetGattSetupQueue()
                    loggedFirstHr = false
                    _batteryPct.value = null
                    // A classified pairing refusal clears its reconnect target and keeps the guidance
                    // visible. Ordinary transport drops still clear any stale message before retrying.
                    if (reconnectAddress != null) _needsPairing.value = null
                    flush()
                    if (gatt === g) { runCatching { g.close() }; gatt = null }
                    if (status == GATT_ERROR_133) {
                        if (!retried133) {
                            retried133 = true
                            scheduleReconnect(fast133Retry = true)
                        } else {
                            log("Huami: still failing (133) — try forgetting the band in Android " +
                                "Settings → Bluetooth, then re-pair.")
                            scheduleReconnect()
                        }
                    } else {
                        scheduleReconnect()
                    }
                }
            }
        }

    private fun beginServiceDiscovery(g: BluetoothGatt) = guarded("service-discovery start") {
        if (gatt !== g) return@guarded
        val started = runCatching { g.discoverServices() }.getOrElse {
            log("Huami: service discovery start error (${it.javaClass.simpleName}: ${it.message})")
            false
        }
        if (!started) {
            log("Huami: service discovery request rejected — reconnecting")
            abortGattSetupAndReconnect(g)
            return@guarded
        }
        handler.removeCallbacks(serviceDiscoveryTimeoutRunnable)
        handler.postDelayed(serviceDiscoveryTimeoutRunnable, GATT_SETUP_TIMEOUT_MS)
    }

    private fun configureDiscoveredServices(g: BluetoothGatt, status: Int) = guarded("services-discovered") {
        if (gatt !== g) return@guarded
        handler.removeCallbacks(serviceDiscoveryTimeoutRunnable)
        if (status != BluetoothGatt.GATT_SUCCESS) {
            log("Huami: WARNING service discovery failed (status=$status) — reconnecting")
            abortGattSetupAndReconnect(g)
            return@guarded
        }
        resetGattSetupQueue()
        val standard = g.getService(STD_HEART_RATE_SERVICE)?.getCharacteristic(STD_HEART_RATE_CHAR)
        val custom = g.getService(HUAMI_SERVICE)?.getCharacteristic(HUAMI_HEART_RATE_CHAR)
        fun isUsable(characteristic: BluetoothGattCharacteristic?): Boolean =
            characteristic != null && characteristic.canNotify() &&
                characteristic.getDescriptor(GATT_CLIENT_CHARACTERISTIC_CONFIG_UUID) != null
        val hrCharacteristic = when {
            isUsable(standard) -> {
                log("Huami: standard 0x180D heart-rate service FOUND — using it (preferred)")
                standard
            }
            isUsable(custom) -> {
                log("Huami: standard HR unavailable — trying the documented Huami custom HR characteristic")
                custom
            }
            else -> standard ?: custom?.takeIf { it.canNotify() }
        }
        if (hrCharacteristic != null) {
            hrSubscriptionCandidate = true
            if (!hrCharacteristic.canNotify() ||
                hrCharacteristic.getDescriptor(GATT_CLIENT_CHARACTERISTIC_CONFIG_UUID) == null
            ) {
                log("Huami: WARNING HR characteristic isn't subscribable — pairing may be required")
            } else {
                val kind = if (hrCharacteristic.uuid == STD_HEART_RATE_CHAR) "standard" else "Huami"
                log("Huami: queueing notifications on $kind HR characteristic")
                setupQueue.enqueue(AndroidGattSetupOperation.EnableNotifications(
                    characteristic = hrCharacteristic,
                    label = "$kind HR notification setup",
                    requiredForPrimaryStream = true,
                ))
            }
        }
        g.getService(BATTERY_SERVICE)?.getCharacteristic(BATTERY_CHAR)?.let { battery ->
            log("Huami: 0x180F battery service found — queueing level read")
            setupQueue.enqueue(AndroidGattSetupOperation.Read(battery, "battery read"))
        }
        drainGattSetupQueue(g)
    }

    private fun drainGattSetupQueue(g: BluetoothGatt): Unit = guarded("GATT setup") {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { drainGattSetupQueue(g) }
            return@guarded
        }
        if (gatt !== g || setupFinalized) return@guarded
        val operation = setupQueue.beginNext()
        if (operation == null) {
            if (setupQueue.isIdle) finalizeGattSetup(g)
            return@guarded
        }
        val started = runCatching { startAndroidGattSetupOperation(g, operation) }.getOrElse {
            log("Huami: ${operation.label} start error (${it.javaClass.simpleName}: ${it.message})")
            false
        }
        if (started) {
            log("Huami: ${operation.label} requested")
            handler.removeCallbacks(setupTimeoutRunnable)
            handler.postDelayed(setupTimeoutRunnable, GATT_SETUP_TIMEOUT_MS)
            return@guarded
        }
        val rejection = setupQueue.rejectCurrentStart() ?: return@guarded
        if (rejection.willRetry) {
            log("Huami: ${operation.label} busy — retrying start " +
                "${rejection.rejectionNumber}/$MAX_GATT_START_RETRIES")
            handler.removeCallbacks(setupRetryRunnable)
            handler.postDelayed(setupRetryRunnable, GATT_START_RETRY_DELAY_MS)
        } else {
            if (operation is AndroidGattSetupOperation.EnableNotifications) hrSetupTransportFailure = true
            log("Huami: ${operation.label} could not start — continuing queued setup")
            drainGattSetupQueue(g)
        }
    }

    private fun BluetoothGattCharacteristic.canNotify(): Boolean =
        properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0 ||
            properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0

    private fun completeGattSetupOperation(
        g: BluetoothGatt,
        status: Int,
        matches: (AndroidGattSetupOperation) -> Boolean,
    ) = guarded("GATT setup callback") {
        if (gatt !== g) return@guarded
        val completed = setupQueue.completeIf(matches) ?: return@guarded
        handler.removeCallbacks(setupTimeoutRunnable)
        if (status == BluetoothGatt.GATT_SUCCESS) {
            if (completed is AndroidGattSetupOperation.EnableNotifications) hrSubscriptionEnabled = true
            log("Huami: ${completed.label} completed")
        } else if (completed is AndroidGattSetupOperation.EnableNotifications && loggedFirstHr) {
            hrSubscriptionEnabled = true
            log("Huami: ${completed.label} callback failed (status=$status), but live HR is flowing")
        } else {
            if (completed is AndroidGattSetupOperation.EnableNotifications &&
                !isGattAuthenticationFailure(status)
            ) {
                hrSetupTransportFailure = true
            }
            log("Huami: WARNING ${completed.label} failed (status=$status)")
        }
        drainGattSetupQueue(g)
    }

    private fun handleGattCharacteristicRead(
        g: BluetoothGatt,
        characteristicUuid: UUID,
        value: ByteArray,
        status: Int,
    ) = guarded("characteristic-read") {
        if (gatt !== g) return@guarded
        if (characteristicUuid == BATTERY_CHAR && status == BluetoothGatt.GATT_SUCCESS) {
            handleBattery(value)
        }
        completeGattSetupOperation(g, status) {
            it is AndroidGattSetupOperation.Read && it.characteristic.uuid == characteristicUuid
        }
    }

    private fun finalizeGattSetup(g: BluetoothGatt) {
        if (setupFinalized || gatt !== g) return
        setupFinalized = true
        when (singleSubscriptionSetupOutcome(
            candidateFound = hrSubscriptionCandidate,
            enabled = hrSubscriptionEnabled,
            transportFailure = hrSetupTransportFailure,
        )) {
            SingleSubscriptionSetupOutcome.READY -> {
                failedReconnectAttempts = 0
                retried133 = false
                loggedFirstHr = false
                _needsPairing.value = null
                log("Huami: GATT setup complete — live HR notifications enabled")
            }
            SingleSubscriptionSetupOutcome.RETRY -> {
                log("Huami: HR setup did not complete at the transport layer — reconnecting")
                abortGattSetupAndReconnect(g)
            }
            SingleSubscriptionSetupOutcome.UNAVAILABLE -> {
                failedReconnectAttempts = 0
                reconnectAddress = null
                if (!hrSubscriptionCandidate) {
                    log("Huami: no readable standard or custom HR characteristic found")
                }
                announceNeedsPairing()
            }
        }
    }

    private fun resetGattSetupQueue() {
        handler.removeCallbacks(serviceDiscoveryTimeoutRunnable)
        handler.removeCallbacks(setupRetryRunnable)
        handler.removeCallbacks(setupTimeoutRunnable)
        setupQueue.clear()
        hrSubscriptionCandidate = false
        hrSubscriptionEnabled = false
        hrSetupTransportFailure = false
        setupFinalized = false
    }

    private fun abortGattSetupAndReconnect(g: BluetoothGatt) {
        if (gatt !== g) return
        resetGattSetupQueue()
        loggedFirstHr = false
        _batteryPct.value = null
        flush()
        disconnectAndClose(g)
        gatt = null
        scheduleReconnect()
    }

    private fun disconnectAndClose(g: BluetoothGatt) {
        runCatching { g.disconnect() }
        runCatching { g.close() }
    }

    /** Run a GATT-callback body so a throw on the binder thread can never crash the app (mirrors
     *  [StandardHrSource.guardedCallback]). */
    private fun guarded(label: String, block: () -> Unit) {
        runCatching(block).onFailure { log("Huami: $label error (${it.javaClass.simpleName}: ${it.message})") }
    }

    private fun handleBattery(data: ByteArray) = guarded("battery-parse") {
        val pct = StandardBattery.parse(data) ?: return@guarded
        log("Huami: battery $pct%")
        _batteryPct.value = pct
        guarded("battery-sink") { onBattery(pct) }
    }

    private fun handleHr(uuid: UUID, data: ByteArray) = guarded("hr-parse") {
        val hr = when (uuid) {
            STD_HEART_RATE_CHAR -> StandardHeartRate.parse(data)?.hr   // standard 0x2A37 layout
            HUAMI_HEART_RATE_CHAR -> HuamiHeartRate.parse(data)        // Huami custom layout
            else -> return@guarded
        } ?: return@guarded                                            // no usable reading → "—", never faked
        ingest(hr)
    }

    private fun announceNeedsPairing() {
        if (_needsPairing.value != null) return
        val msg = "This band needs a pairing handshake NOOP can't do yet. Live data isn't available - try " +
            "exporting from the Zepp app and importing the file instead."
        _needsPairing.value = msg
        log("Huami: $msg")
    }

    companion object {
        /** Standard SIG Heart Rate service / measurement (preferred when present). */
        val STD_HEART_RATE_SERVICE: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        val STD_HEART_RATE_CHAR: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")

        /** Documented Huami custom HR service + measurement characteristic (128-bit). FACTS only. */
        val HUAMI_SERVICE: UUID = UUID.fromString("0000fee0-0000-1000-8000-00805f9b34fb")
        val HUAMI_HEART_RATE_CHAR: UUID = UUID.fromString("00002a37-0000-3512-2118-0009af100700")

        private val BATTERY_SERVICE: UUID = UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb")
        private val BATTERY_CHAR: UUID = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")

        private const val GATT_ERROR_133 = 133
        private const val MAX_GATT_START_RETRIES = 3
        private const val GATT_START_RETRY_DELAY_MS = 250L
        private const val GATT_SETUP_TIMEOUT_MS = 8_000L
    }
}
