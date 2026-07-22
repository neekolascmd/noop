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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * An ISOLATED standard-Bluetooth source for FTMS gym equipment — a treadmill, indoor bike, rower, or
 * cross-trainer exposing the Fitness Machine Service (0x1826) with one of the machine-data
 * characteristics (Treadmill 0x2ACD, Indoor Bike 0x2AD2, Rower 0x2AD1, Cross Trainer 0x2ACE).
 *
 * Faithful Kotlin twin of Strand/BLE/FTMSSource.swift. WHOOP-FIRST ISOLATION (identical to
 * [StandardHrSource]): own scan + [BluetoothGatt], never touches [WhoopBleClient]. The shared surfaces
 * are injected closures: [liveSink] (machine HR → the live UI + the existing live-workout recorder),
 * [onBattery] (the machine's 0x180F battery), [log] (the exportable strap log). The pure FTMS field
 * decode lives in [FitnessMachine] so it's JVM-unit-tested away from android.bluetooth.
 *
 * RECORDING: no new scoring loop. HR (when the machine reports it) rides [liveSink] exactly like
 * [StandardHrSource], so a machine session is recorded by the EXISTING manual live-workout flow
 * ([AppViewModel.startWorkout]/[endWorkout] → StrainScorer → Effort). The machine metrics (speed,
 * cadence, power, distance, energy) are surfaced live via [latest] and logged.
 *
 * Android runtime-permission notes (same contract as [WhoopBleClient]/[StandardHrSource]): the caller
 * must hold BLUETOOTH_SCAN + BLUETOOTH_CONNECT before [scan]/[connect].
 */
@SuppressLint("MissingPermission")
class FtmsSource(
    context: Context,
    /** Push the machine's live HR (bpm) into whatever the UI / recorder observe. Called on the main looper. */
    private val liveSink: (hr: Int) -> Unit,
    /** Push the machine's latest decoded reading into the in-exercise UI. Called on the main looper. */
    private val readingSink: (FitnessMachine.Reading) -> Unit = {},
    /** Fired with the machine's battery percent (0–100) when read off 0x2A19. */
    private val onBattery: (Int) -> Unit = {},
    /** Diagnostic sink for the connect lifecycle — the SAME exportable strap log (issue #421). Every line
     *  is prefixed "FTMS: " so it's distinguishable in the shared log. Default no-op keeps tests silent. */
    private val log: (String) -> Unit = {},
) {

    /** An FTMS machine seen during a scan (UI affordance). */
    data class DiscoveredMachine(val address: String, val name: String, val rssi: Int)

    private val _discovered = MutableStateFlow<List<DiscoveredMachine>>(emptyList())
    val discovered: StateFlow<List<DiscoveredMachine>> = _discovered.asStateFlow()

    private val _scanning = MutableStateFlow(false)
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val _latest = MutableStateFlow<FitnessMachine.Reading?>(null)
    /** The most recently decoded machine-data reading, for the live in-exercise readout; null until the
     *  first notification and after disconnect (a stale panel must not outlive the link). */
    val latest: StateFlow<FitnessMachine.Reading?> = _latest.asStateFlow()

    private val _batteryPct = MutableStateFlow<Int?>(null)
    /** The connected machine's 0x180F battery level, 0–100, if exposed; null otherwise / after disconnect. */
    val batteryPct: StateFlow<Int?> = _batteryPct.asStateFlow()

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
    private var loggedFirstReading = false

    private var reconnectAddress: String? = null
    private var intentionalDisconnect = false
    private var failedReconnectAttempts = 0
    private var reconnectRunnable: Runnable? = null

    private val handler = Handler(Looper.getMainLooper())

    private val setupQueue = GattOperationQueue<AndroidGattSetupOperation>(maxStartRetries = 3)
    private var machineSubscriptionCandidates = 0
    private var machineSubscriptionsEnabled = 0
    private var setupFinalized = false
    private val setupRetryRunnable = Runnable { gatt?.let(::drainGattSetupQueue) }
    private val serviceDiscoveryTimeoutRunnable = Runnable {
        val g = gatt ?: return@Runnable
        log("FTMS: service discovery timed out — reconnecting")
        abortGattSetupAndReconnect(g)
    }
    private val setupTimeoutRunnable = Runnable {
        val g = gatt ?: return@Runnable
        val timedOut = setupQueue.timeoutCurrent() ?: return@Runnable
        if (timedOut is AndroidGattSetupOperation.EnableNotifications && loggedFirstReading) {
            machineSubscriptionsEnabled = maxOf(1, machineSubscriptionsEnabled)
            log("FTMS: ${timedOut.label} callback timed out, but live machine data already proves the stream")
        } else {
            log("FTMS: ${timedOut.label} timed out — skipping it and finishing queued setup")
        }
        drainGattSetupQueue(g)
    }

    // MARK: - Scanning

    /** Begin scanning for FTMS machines advertising the 0x1826 service. */
    fun scan() {
        seen.clear()
        _discovered.value = emptyList()
        _scanning.value = true
        log("FTMS: scanning for gym equipment (0x1826)…")
        val sc = scanner ?: run {
            _scanning.value = false
            log("FTMS: no BLE scanner available — Bluetooth may be off or unsupported")
            return
        }
        if (adapter?.isEnabled != true) {
            _scanning.value = false
            log("FTMS: Bluetooth adapter is off — cannot scan")
            return
        }
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(FITNESS_MACHINE_SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        sc.startScan(listOf(filter), settings, scanCallback)
    }

    /** Stop an in-progress scan. Idempotent. */
    fun stopScan() {
        _scanning.value = false
        if (adapter?.isEnabled == true) runCatching { scanner?.stopScan(scanCallback) }
    }

    // MARK: - Connecting

    /** Connect to the chosen machine (by address) and start streaming its machine data. */
    fun connect(address: String) {
        cancelScheduledReconnect()
        pendingConnectAddress = null
        reconnectAddress = address
        intentionalDisconnect = false
        failedReconnectAttempts = 0
        retried133 = false
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
            log("FTMS: saved machine isn't cached — scanning to find it")
            scan()
            return
        }
        connectToDevice(device)
    }

    private fun connectToDevice(device: BluetoothDevice) {
        if (!PeripheralReconnectPolicy.shouldReconnect(intentionalDisconnect, reconnectAddress != null) ||
            reconnectAddress != device.address
        ) return
        log("FTMS: connecting to ${device.address}")
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
            log("FTMS: connectGatt failed (${it.javaClass.simpleName}: ${it.message})")
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
        log("FTMS: $label in ${delayMs / 1_000}s" +
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

    /** Tear down: cancel the connection and stop scanning. Idempotent. */
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
        loggedFirstReading = false
        _latest.value = null
        _batteryPct.value = null
    }

    // MARK: - Scan callback

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device ?: return
            val address = device.address ?: return
            val firstSight = seen.put(address, device) == null
            val name = result.scanRecord?.deviceName ?: runCatching { device.name }.getOrNull()
                ?: "Gym Equipment"
            if (firstSight) log("FTMS: found $name ($address) rssi ${result.rssi}")
            val machine = DiscoveredMachine(address = address, name = name, rssi = result.rssi)
            val list = _discovered.value.toMutableList()
            val i = list.indexOfFirst { it.address == address }
            if (i >= 0) list[i] = machine else list.add(machine)
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

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            val snapshot = value.copyOf()
            handler.post {
                if (gatt !== g) return@post
                handleMachine(ch.uuid, snapshot)
            }
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            val snapshot = ch.value?.copyOf() ?: return
            handler.post {
                if (gatt !== g) return@post
                handleMachine(ch.uuid, snapshot)
            }
        }

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

    private fun handleConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) =
        guarded("connection-state") {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    if (gatt !== g) {
                        log("FTMS: ignoring stale connection callback")
                        disconnectAndClose(g)
                        return@guarded
                    }
                    cancelScheduledReconnect()
                    log("FTMS: connected (status=$status) — discovering services")
                    beginServiceDiscovery(g)
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    if (gatt !== g) {
                        runCatching { g.close() }
                        return@guarded
                    }
                    log("FTMS: disconnected (status=$status)")
                    resetGattSetupQueue()
                    loggedFirstReading = false
                    _latest.value = null
                    _batteryPct.value = null
                    if (gatt === g) { runCatching { g.close() }; gatt = null }
                    if (status == GATT_ERROR_133) {
                        if (!retried133) {
                            retried133 = true
                            scheduleReconnect(fast133Retry = true)
                        } else {
                            log("FTMS: still failing (133) — try forgetting the machine in Android " +
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
            log("FTMS: service discovery start error (${it.javaClass.simpleName}: ${it.message})")
            false
        }
        if (!started) {
            log("FTMS: service discovery request rejected — reconnecting")
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
            log("FTMS: WARNING service discovery failed (status=$status) — reconnecting")
            abortGattSetupAndReconnect(g)
            return@guarded
        }
        val svc = g.getService(FITNESS_MACHINE_SERVICE)
        if (svc == null) {
            log("FTMS: 0x1826 service NOT FOUND after filtered scan — reconnecting")
            abortGattSetupAndReconnect(g)
            return@guarded
        }
        log("FTMS: 0x1826 fitness machine service FOUND — queueing machine-data notifications")
        resetGattSetupQueue()
        for ((uuid, kind) in MACHINE_CHARS) {
            val characteristic = svc.getCharacteristic(uuid) ?: continue
            if (characteristic.getDescriptor(GATT_CLIENT_CHARACTERISTIC_CONFIG_UUID) == null ||
                gattCccdWriteKind(characteristic.properties) == GattCccdWriteKind.UNSUPPORTED
            ) {
                log("FTMS: WARNING ${kind.displayName} data isn't subscribable — skipping it")
                continue
            }
            machineSubscriptionCandidates += 1
            log("FTMS: ${kind.displayName} data characteristic found — queueing notifications")
            setupQueue.enqueue(AndroidGattSetupOperation.EnableNotifications(
                characteristic = characteristic,
                label = "${kind.displayName} notification setup",
                requiredForPrimaryStream = false,
            ))
        }
        g.getService(BATTERY_SERVICE)?.getCharacteristic(BATTERY_CHAR)?.let { battery ->
            log("FTMS: 0x180F battery service found — queueing level read")
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
            log("FTMS: ${operation.label} start error (${it.javaClass.simpleName}: ${it.message})")
            false
        }
        if (started) {
            log("FTMS: ${operation.label} requested")
            handler.removeCallbacks(setupTimeoutRunnable)
            handler.postDelayed(setupTimeoutRunnable, GATT_SETUP_TIMEOUT_MS)
            return@guarded
        }
        val rejection = setupQueue.rejectCurrentStart() ?: return@guarded
        if (rejection.willRetry) {
            log("FTMS: ${operation.label} busy — retrying start " +
                "${rejection.rejectionNumber}/$MAX_GATT_START_RETRIES")
            handler.removeCallbacks(setupRetryRunnable)
            handler.postDelayed(setupRetryRunnable, GATT_START_RETRY_DELAY_MS)
        } else {
            log("FTMS: ${operation.label} could not start — continuing queued setup")
            drainGattSetupQueue(g)
        }
    }

    private fun completeGattSetupOperation(
        g: BluetoothGatt,
        status: Int,
        matches: (AndroidGattSetupOperation) -> Boolean,
    ) = guarded("GATT setup callback") {
        if (gatt !== g) return@guarded
        val completed = setupQueue.completeIf(matches) ?: return@guarded
        handler.removeCallbacks(setupTimeoutRunnable)
        if (status == BluetoothGatt.GATT_SUCCESS) {
            if (completed is AndroidGattSetupOperation.EnableNotifications) {
                machineSubscriptionsEnabled += 1
            }
            log("FTMS: ${completed.label} completed")
        } else if (completed is AndroidGattSetupOperation.EnableNotifications && loggedFirstReading) {
            machineSubscriptionsEnabled = maxOf(1, machineSubscriptionsEnabled)
            log("FTMS: ${completed.label} callback failed (status=$status), but live data is flowing")
        } else {
            log("FTMS: WARNING ${completed.label} failed (status=$status) — continuing queued setup")
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
        when (primarySubscriptionSetupOutcome(machineSubscriptionCandidates, machineSubscriptionsEnabled)) {
            PrimarySubscriptionSetupOutcome.READY -> {
                failedReconnectAttempts = 0
                retried133 = false
                log("FTMS: GATT setup complete — $machineSubscriptionsEnabled machine stream(s) enabled")
            }
            PrimarySubscriptionSetupOutcome.RETRY -> {
                log("FTMS: no machine-data subscription succeeded — reconnecting")
                abortGattSetupAndReconnect(g)
            }
            PrimarySubscriptionSetupOutcome.UNSUPPORTED -> {
                reconnectAddress = null
                log("FTMS: no supported treadmill, bike, rower, or cross-trainer data characteristic found")
            }
        }
    }

    private fun resetGattSetupQueue() {
        handler.removeCallbacks(serviceDiscoveryTimeoutRunnable)
        handler.removeCallbacks(setupRetryRunnable)
        handler.removeCallbacks(setupTimeoutRunnable)
        setupQueue.clear()
        machineSubscriptionCandidates = 0
        machineSubscriptionsEnabled = 0
        setupFinalized = false
    }

    private fun abortGattSetupAndReconnect(g: BluetoothGatt) {
        if (gatt !== g) return
        resetGattSetupQueue()
        loggedFirstReading = false
        _latest.value = null
        _batteryPct.value = null
        disconnectAndClose(g)
        gatt = null
        scheduleReconnect()
    }

    private fun disconnectAndClose(g: BluetoothGatt) {
        runCatching { g.disconnect() }
        runCatching { g.close() }
    }

    /**
     * Run a GATT-callback body so a throw on the binder thread can never crash the app — mirrors
     * [StandardHrSource.guardedCallback]. A misbehaving machine must degrade to "no data", never take
     * the app down; the message lands in the exportable strap log.
     */
    private fun guarded(label: String, block: () -> Unit) {
        runCatching(block).onFailure { log("FTMS: $label error (${it.javaClass.simpleName}: ${it.message})") }
    }

    private fun handleBattery(data: ByteArray) = guarded("battery-parse") {
        val pct = StandardBattery.parse(data) ?: return@guarded
        log("FTMS: battery $pct%")
        _batteryPct.value = pct
        guarded("battery-sink") { onBattery(pct) }
    }

    private fun handleMachine(uuid: UUID, data: ByteArray) = guarded("machine-parse") {
        val kind = MACHINE_CHARS.firstOrNull { it.first == uuid }?.second ?: return@guarded
        val reading = FitnessMachine.decode(kind.uuid16, data) ?: return@guarded
        if (!loggedFirstReading) {
            loggedFirstReading = true
            log("FTMS: receiving ${reading.kind.displayName} data — first reading" +
                (reading.heartRate?.let { " HR $it bpm" } ?: ""))
        }
        guarded("reading-sink") {
            _latest.value = reading
            readingSink(reading)
            reading.heartRate?.takeIf { it in 30..220 }?.let { liveSink(it) }
        }
    }

    companion object {
        val FITNESS_MACHINE_SERVICE: UUID = UUID.fromString("00001826-0000-1000-8000-00805f9b34fb")
        private val BATTERY_SERVICE: UUID = UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb")
        private val BATTERY_CHAR: UUID = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")

        /** The four machine-data characteristics → their FTMS kind. */
        private val MACHINE_CHARS: List<Pair<UUID, FitnessMachine.MachineKind>> = listOf(
            UUID.fromString("00002acd-0000-1000-8000-00805f9b34fb") to FitnessMachine.MachineKind.TREADMILL,
            UUID.fromString("00002ad2-0000-1000-8000-00805f9b34fb") to FitnessMachine.MachineKind.INDOOR_BIKE,
            UUID.fromString("00002ad1-0000-1000-8000-00805f9b34fb") to FitnessMachine.MachineKind.ROWER,
            UUID.fromString("00002ace-0000-1000-8000-00805f9b34fb") to FitnessMachine.MachineKind.CROSS_TRAINER,
        )

        private const val GATT_ERROR_133 = 133
        private const val MAX_GATT_START_RETRIES = 3
        private const val GATT_START_RETRY_DELAY_MS = 250L
        private const val GATT_SETUP_TIMEOUT_MS = 8_000L
    }
}
