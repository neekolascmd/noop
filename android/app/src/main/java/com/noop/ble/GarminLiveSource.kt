package com.noop.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.noop.data.StreamBatch
import com.noop.garmin.GarminClientId
import com.noop.garmin.GarminCobs
import com.noop.garmin.GarminCobsStreamDecoder
import com.noop.garmin.GarminFrameResult
import com.noop.garmin.GarminGfdi
import com.noop.garmin.GarminGfdiException
import com.noop.garmin.GarminHandleManagement
import com.noop.garmin.GarminMultiLinkService
import com.noop.garmin.GarminMultiLinkFraming
import com.noop.garmin.GarminMultiLinkUuid
import com.noop.garmin.GarminRealtimeDecoder
import com.noop.garmin.GarminRealtimeMapping
import com.noop.garmin.GarminSessionException
import com.noop.garmin.GarminSessionResponder
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.ArrayDeque
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Experimental, offline Garmin Multi-Link v2 source.
 *
 * This owns its scanner, bond and GATT. It does not use Garmin Connect, Garmin's cloud, the WHOOP BLE
 * client, or Garmin's commercially licensed Health SDK. Existing Garmin Broadcast HR devices continue
 * to use [StandardHrSource]; this source is selected only by the separate Garmin local-sync wizard row.
 *
 * Hardware qualification is intentionally separate from implementation. Until an owned watch confirms
 * pairing, characteristic selection, handle registration and each stream, the UI and docs label this
 * path experimental/unverified and no opaque field is promoted to a metric.
 */
@SuppressLint("MissingPermission")
class GarminLiveSource(
    context: Context,
    private val deviceId: String,
    private val liveSink: (heartRate: Int, rrMilliseconds: List<Int>) -> Unit,
    private val persist: (StreamBatch, String) -> Unit,
    private val log: (String) -> Unit = {},
) {
    data class DiscoveredDevice(val address: String, val name: String, val rssi: Int)

    private val _discovered = MutableStateFlow<List<DiscoveredDevice>>(emptyList())
    val discovered: StateFlow<List<DiscoveredDevice>> = _discovered.asStateFlow()

    private val _scanning = MutableStateFlow(false)
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val appContext = context.applicationContext
    private val manager = appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter get() = manager?.adapter
    private val scanner get() = adapter?.bluetoothLeScanner
    private val handler = Handler(Looper.getMainLooper())
    private val seen = ConcurrentHashMap<String, BluetoothDevice>()

    private var gatt: BluetoothGatt? = null
    private var receiveCharacteristic: BluetoothGattCharacteristic? = null
    private var sendCharacteristic: BluetoothGattCharacteristic? = null
    private var negotiatedMtu = 23
    private var intentionalDisconnect = false
    private var reconnectAddress: String? = null
    private var reconnectAttempts = 0
    private var reconnectRunnable: Runnable? = null
    private var discoveryStarted = false
    private var bondReceiverRegistered = false
    private var pendingBondAddress: String? = null

    private val clientId = GarminClientId()
    private val serviceByHandle = HashMap<Int, GarminMultiLinkService>()
    private var cobsDecoder = GarminCobsStreamDecoder(MAX_ENCODED_FRAME)
    private val firstSampleLogged = HashSet<GarminMultiLinkService>()
    private val diagnosticOnce = HashSet<String>()
    private var latestHeartRate: Int? = null
    private var latestHeartRateAt = 0L

    private data class PendingWrite(val id: Long, val bytes: ByteArray, val label: String)
    private val writeQueue = ArrayDeque<PendingWrite>()
    private var writeInFlight: PendingWrite? = null
    /** True only for WRITE_TYPE_DEFAULT. Some stacks still emit a late callback for NO_RESPONSE; that
     *  callback must never complete the following queued write. */
    private var writeExpectsCallback = false
    private var nextWriteId = 1L

    private val mtuFallback = Runnable { gatt?.let(::discoverServicesOnce) }
    private val serviceDiscoveryTimeout = Runnable {
        val g = gatt ?: return@Runnable
        log("Garmin local sync: service discovery timed out; reconnecting")
        abortAndReconnect(g)
    }
    private val notificationSetupTimeout = Runnable {
        val g = gatt ?: return@Runnable
        log("Garmin local sync: notification setup timed out; reconnecting")
        abortAndReconnect(g)
    }
    private val writeTimeout = Runnable {
        val current = writeInFlight ?: return@Runnable
        log("Garmin local sync: ${current.label} write timed out; reconnecting")
        gatt?.let(::abortAndReconnect)
    }

    fun scan() {
        stopScan()
        seen.clear()
        _discovered.value = emptyList()
        if (adapter?.isEnabled != true || scanner == null) {
            log("Garmin local sync: Bluetooth is off or no BLE scanner is available")
            return
        }
        _scanning.value = true
        log("Garmin local sync: scanning for Garmin Multi-Link devices")
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        // Some firmware does not place the proprietary service in its advertisement. Scan broadly but
        // surface only a service match or a Garmin-family name; never list every nearby BLE device.
        scanner?.startScan(emptyList(), settings, scanCallback)
    }

    fun stopScan() {
        _scanning.value = false
        if (adapter?.isEnabled == true) runCatching { scanner?.stopScan(scanCallback) }
    }

    /** User-initiated from the Add Device flow. Android owns the visible bond confirmation. */
    fun connect(address: String) {
        handler.post {
            intentionalDisconnect = false
            reconnectAddress = address
            reconnectAttempts = 0
            cancelReconnect()
            stopScan()
            val device = seen[address] ?: runCatching { adapter?.getRemoteDevice(address) }.getOrNull()
            if (device == null) {
                log("Garmin local sync: saved device address is unavailable; scan and select it again")
                return@post
            }
            beginBondOrConnect(device)
        }
    }

    fun stop() {
        handler.post {
            intentionalDisconnect = true
            reconnectAddress = null
            reconnectAttempts = 0
            cancelReconnect()
            handler.removeCallbacks(mtuFallback)
            handler.removeCallbacks(serviceDiscoveryTimeout)
            handler.removeCallbacks(notificationSetupTimeout)
            handler.removeCallbacks(writeTimeout)
            stopScan()
            unregisterBondReceiver()
            pendingBondAddress = null
            resetSession()
            gatt?.let(::disconnectAndClose)
            gatt = null
        }
    }

    private fun beginBondOrConnect(device: BluetoothDevice) {
        if (intentionalDisconnect || reconnectAddress != device.address) return
        when (device.bondState) {
            BluetoothDevice.BOND_BONDED -> connectGatt(device)
            BluetoothDevice.BOND_BONDING -> {
                pendingBondAddress = device.address
                registerBondReceiver()
                log("Garmin local sync: waiting for Android to finish secure pairing")
            }
            else -> {
                pendingBondAddress = device.address
                registerBondReceiver()
                log("Garmin local sync: requesting Android pairing; confirm the system prompt on this phone")
                if (!runCatching { device.createBond() }.getOrDefault(false)) {
                    log("Garmin local sync: Android could not start pairing; put the watch in Pair Phone mode and retry")
                    unregisterBondReceiver()
                }
            }
        }
    }

    private fun registerBondReceiver() {
        if (bondReceiverRegistered) return
        ContextCompat.registerReceiver(
            appContext,
            bondReceiver,
            IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED),
            // ACTION_BOND_STATE_CHANGED is a protected framework broadcast delivered by Bluetooth's
            // privileged process rather than this app's UID, so AndroidX requires EXPORTED here. The
            // narrow action filter and platform sender protection keep arbitrary apps from driving it.
            ContextCompat.RECEIVER_EXPORTED,
        )
        bondReceiverRegistered = true
    }

    private fun unregisterBondReceiver() {
        if (!bondReceiverRegistered) return
        runCatching { appContext.unregisterReceiver(bondReceiver) }
        bondReceiverRegistered = false
    }

    @Suppress("DEPRECATION")
    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
            val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE) ?: return
            if (device.address != pendingBondAddress) return
            val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
            val previous = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.ERROR)
            when (state) {
                BluetoothDevice.BOND_BONDED -> handler.post {
                    pendingBondAddress = null
                    unregisterBondReceiver()
                    log("Garmin local sync: Android pairing completed")
                    connectGatt(device)
                }
                BluetoothDevice.BOND_NONE -> if (previous == BluetoothDevice.BOND_BONDING) handler.post {
                    pendingBondAddress = null
                    unregisterBondReceiver()
                    log("Garmin local sync: pairing was cancelled or rejected; no data was read")
                }
            }
        }
    }

    private fun connectGatt(device: BluetoothDevice) {
        if (intentionalDisconnect || reconnectAddress != device.address) return
        resetSession()
        gatt?.let(::disconnectAndClose)
        log("Garmin local sync: connecting to paired watch")
        gatt = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(appContext, false, callback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                device.connectGatt(appContext, false, callback)
            }
        }.getOrElse {
            log("Garmin local sync: connection could not start (${it.javaClass.simpleName})")
            scheduleReconnect()
            null
        }
    }

    private fun scheduleReconnect() {
        val address = reconnectAddress ?: return
        if (intentionalDisconnect) return
        cancelReconnect()
        reconnectAttempts += 1
        val delay = PeripheralReconnectPolicy.delayMs(reconnectAttempts)
        val task = Runnable {
            reconnectRunnable = null
            if (intentionalDisconnect || reconnectAddress != address) return@Runnable
            val device = runCatching { adapter?.getRemoteDevice(address) }.getOrNull() ?: return@Runnable
            beginBondOrConnect(device)
        }
        reconnectRunnable = task
        log("Garmin local sync: reconnecting in ${delay / 1_000}s (attempt $reconnectAttempts)")
        handler.postDelayed(task, delay)
    }

    private fun cancelReconnect() {
        reconnectRunnable?.let(handler::removeCallbacks)
        reconnectRunnable = null
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) = acceptScan(result)
        override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach(::acceptScan)
        override fun onScanFailed(errorCode: Int) {
            _scanning.value = false
            log("Garmin local sync: scan failed ($errorCode)")
        }
    }

    private fun acceptScan(result: ScanResult) {
        val device = result.device ?: return
        val address = device.address ?: return
        val name = result.scanRecord?.deviceName ?: runCatching { device.name }.getOrNull() ?: ""
        val hasService = result.scanRecord?.serviceUuids?.any {
            it.uuid == UUID.fromString(GarminMultiLinkUuid.SERVICE)
        } == true
        if (!hasService && !looksGarmin(name)) return
        val displayName = name.ifBlank { "Garmin device" }
        seen[address] = device
        val item = DiscoveredDevice(address, displayName, result.rssi)
        val updated = _discovered.value.toMutableList()
        val index = updated.indexOfFirst { it.address == address }
        if (index >= 0) updated[index] = item else updated += item
        _discovered.value = updated
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            handler.post {
                if (gatt !== g) { disconnectAndClose(g); return@post }
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> {
                        reconnectAttempts = 0
                        discoveryStarted = false
                        log("Garmin local sync: connected; discovering private services")
                        handler.removeCallbacks(mtuFallback)
                        handler.removeCallbacks(serviceDiscoveryTimeout)
                        handler.removeCallbacks(notificationSetupTimeout)
                        if (!g.requestMtu(REQUESTED_MTU)) discoverServicesOnce(g)
                        else handler.postDelayed(mtuFallback, MTU_FALLBACK_MS)
                    }
                    BluetoothProfile.STATE_DISCONNECTED -> {
                        handler.removeCallbacks(mtuFallback)
                        handler.removeCallbacks(writeTimeout)
                        resetSession()
                        g.close()
                        if (gatt === g) gatt = null
                        if (!intentionalDisconnect) {
                            log("Garmin local sync: disconnected (status $status)")
                            scheduleReconnect()
                        }
                    }
                }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            handler.post {
                if (gatt !== g) return@post
                handler.removeCallbacks(mtuFallback)
                if (status == BluetoothGatt.GATT_SUCCESS) negotiatedMtu = mtu.coerceAtLeast(23)
                discoverServicesOnce(g)
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            handler.post {
                if (gatt !== g) return@post
                handler.removeCallbacks(serviceDiscoveryTimeout)
                if (status != BluetoothGatt.GATT_SUCCESS || !configureMultiLink(g)) {
                    log("Garmin local sync: Multi-Link v2 service/characteristic pair was not available")
                    abortAndReconnect(g)
                }
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            handler.post {
                if (gatt !== g || descriptor.uuid != CCCD) return@post
                handler.removeCallbacks(notificationSetupTimeout)
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    log("Garmin local sync: notification setup failed ($status)")
                    abortAndReconnect(g)
                    return@post
                }
                log("Garmin local sync: notifications enabled; resetting stale service handles")
                enqueueWrite(GarminHandleManagement.closeAll(clientId = clientId), "close-all")
            }
        }

        @Deprecated("Deprecated in API 33")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            val bytes = characteristic.value?.copyOf() ?: return
            handler.post { if (gatt === g) receive(bytes) }
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            handler.post { if (gatt === g) receive(value.copyOf()) }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            handler.post {
                if (gatt !== g || characteristic.uuid != sendCharacteristic?.uuid) return@post
                if (writeExpectsCallback) completeWrite(status == BluetoothGatt.GATT_SUCCESS)
            }
        }
    }

    private fun discoverServicesOnce(g: BluetoothGatt) {
        if (gatt !== g || discoveryStarted) return
        discoveryStarted = true
        if (!g.discoverServices()) {
            log("Garmin local sync: Android rejected service discovery")
            abortAndReconnect(g)
        } else {
            handler.removeCallbacks(serviceDiscoveryTimeout)
            handler.postDelayed(serviceDiscoveryTimeout, SERVICE_DISCOVERY_TIMEOUT_MS)
        }
    }

    private fun configureMultiLink(g: BluetoothGatt): Boolean {
        val service = g.getService(UUID.fromString(GarminMultiLinkUuid.SERVICE)) ?: return false
        var receive: BluetoothGattCharacteristic? = null
        var send: BluetoothGattCharacteristic? = null
        for (index in GarminMultiLinkUuid.READ_CHARACTERISTICS.indices) {
            val candidateReceive = service.getCharacteristic(UUID.fromString(GarminMultiLinkUuid.READ_CHARACTERISTICS[index]))
            val candidateSend = service.getCharacteristic(UUID.fromString(GarminMultiLinkUuid.WRITE_CHARACTERISTICS[index]))
            if (candidateReceive != null && candidateSend != null) {
                receive = candidateReceive
                send = candidateSend
                break
            }
        }
        if (receive == null || send == null) return false
        receiveCharacteristic = receive
        sendCharacteristic = send
        if (!g.setCharacteristicNotification(receive, true)) return false
        val cccd = receive.getDescriptor(CCCD) ?: return false
        val accepted = writeDescriptor(g, cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
        if (accepted) {
            handler.removeCallbacks(notificationSetupTimeout)
            handler.postDelayed(notificationSetupTimeout, NOTIFICATION_SETUP_TIMEOUT_MS)
        }
        return accepted
    }

    private fun writeDescriptor(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, value: ByteArray): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                descriptor.value = value
                g.writeDescriptor(descriptor)
            }
        }

    private fun receive(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        val handle = bytes[0].toInt() and 0xff
        if (handle == 0) {
            receiveManagement(bytes)
            return
        }
        val service = serviceByHandle[handle]
        if (service == null) {
            logOnce("unknown-handle-$handle", "Garmin local sync: ignored data on an unregistered handle")
            return
        }
        val payload = bytes.copyOfRange(1, bytes.size)
        if (service == GarminMultiLinkService.GFDI) receiveGfdi(payload, handle)
        else receiveRealtime(service, payload)
    }

    private fun receiveManagement(bytes: ByteArray) {
        if (GarminHandleManagement.isCloseAllResponse(bytes, clientId)) {
            serviceByHandle.clear()
            cobsDecoder = GarminCobsStreamDecoder(MAX_ENCODED_FRAME)
            REGISTERED_SERVICES.forEach { service ->
                enqueueWrite(GarminHandleManagement.register(service, clientId), "register-${service.code}")
            }
            return
        }
        val registration = GarminHandleManagement.parseRegistrationResponse(bytes) ?: run {
            logOnce("unknown-management", "Garmin local sync: ignored an unknown handle-management response")
            return
        }
        if (registration.clientId != clientId) return
        val service = GarminMultiLinkService.fromCode(registration.serviceCode) ?: return
        if (!registration.succeeded || registration.handle == null) {
            log("Garmin local sync: service ${service.code} registration failed (status ${registration.statusRaw})")
            return
        }
        serviceByHandle[registration.handle] = service
        log("Garmin local sync: registered ${serviceLabel(service)}")
    }

    private fun receiveGfdi(payload: ByteArray, handle: Int) {
        for (result in cobsDecoder.feed(payload)) {
            when (result) {
                is GarminFrameResult.Failure -> logOnce(
                    "cobs-${result.error}",
                    "Garmin local sync: dropped a malformed or oversized framed message (${result.error})",
                )
                is GarminFrameResult.Frame -> {
                    val message = try {
                        GarminGfdi.decode(result.bytes)
                    } catch (error: GarminGfdiException) {
                        logOnce("gfdi-${error.reason}", "Garmin local sync: dropped an invalid GFDI message (${error.reason})")
                        continue
                    }
                    val nowMillis = System.currentTimeMillis()
                    val reply = try {
                        GarminSessionResponder.reply(
                            message = message,
                            nowUnixSeconds = nowMillis / 1_000L,
                            timeZoneOffsetSeconds = TimeZone.getDefault().getOffset(nowMillis) / 1_000,
                        )
                    } catch (error: GarminSessionException) {
                        logOnce("session-${error.reason}", "Garmin local sync: could not answer a malformed handshake request")
                        null
                    }
                    if (reply == null) {
                        logOnce("gfdi-message-${message.messageId}", "Garmin local sync: preserved but did not act on GFDI message ${message.messageId}")
                    } else {
                        reply.outgoing.forEach { sendGfdi(handle, it) }
                        if (reply.configurationCompleted) log("Garmin local sync: minimal offline handshake completed")
                    }
                }
            }
        }
    }

    private fun sendGfdi(handle: Int, envelope: ByteArray) {
        val encoded = GarminCobs.encode(envelope)
        GarminMultiLinkFraming.fragment(handle, encoded, negotiatedMtu).forEach {
            enqueueWrite(it, "GFDI")
        }
    }

    private fun receiveRealtime(service: GarminMultiLinkService, payload: ByteArray) {
        val value = GarminRealtimeDecoder.decode(service, payload) ?: run {
            logOnce("invalid-${service.code}", "Garmin local sync: ignored an invalid ${serviceLabel(service)} packet")
            return
        }
        val now = System.currentTimeMillis() / 1_000L
        val mapped = GarminRealtimeMapping.map(value, receiptUnixSeconds = now, nowUnixSeconds = now)
        if (!mapped.batch.isEmpty) persist(mapped.batch, deviceId)
        mapped.liveHeartRate?.let { hr ->
            latestHeartRate = hr
            latestHeartRateAt = now
            safeLiveSink(hr, emptyList())
        }
        mapped.liveRrMilliseconds?.let { rr ->
            val hr = latestHeartRate
            if (hr != null && now - latestHeartRateAt <= LIVE_HR_MAX_AGE_SECONDS) safeLiveSink(hr, listOf(rr))
        }
        if (firstSampleLogged.add(service)) log("Garmin local sync: received first qualified ${serviceLabel(service)} packet")
    }

    private fun safeLiveSink(hr: Int, rr: List<Int>) {
        runCatching { liveSink(hr, rr) }.onFailure {
            logOnce("live-sink", "Garmin local sync: live display rejected a sample; persistence continues")
        }
    }

    private fun enqueueWrite(bytes: ByteArray, label: String) {
        writeQueue += PendingWrite(nextWriteId++, bytes.copyOf(), label)
        drainWrites()
    }

    private fun drainWrites() {
        if (writeInFlight != null) return
        val g = gatt ?: return
        val characteristic = sendCharacteristic ?: return
        val next = writeQueue.pollFirst() ?: return
        writeInFlight = next
        val supportsResponse = characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0
        val writeType = if (supportsResponse) BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        val accepted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeCharacteristic(characteristic, next.bytes, writeType) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                characteristic.writeType = writeType
                characteristic.value = next.bytes
                g.writeCharacteristic(characteristic)
            }
        }
        if (!accepted) {
            writeInFlight = null
            writeExpectsCallback = false
            writeQueue.addFirst(next)
            log("Garmin local sync: Android rejected ${next.label} write; reconnecting")
            abortAndReconnect(g)
            return
        }
        writeExpectsCallback = supportsResponse
        handler.removeCallbacks(writeTimeout)
        handler.postDelayed(writeTimeout, WRITE_TIMEOUT_MS)
        if (!supportsResponse) {
            val id = next.id
            handler.postDelayed({ if (writeInFlight?.id == id) completeWrite(true) }, NO_RESPONSE_SETTLE_MS)
        }
    }

    private fun completeWrite(success: Boolean) {
        val current = writeInFlight ?: return
        handler.removeCallbacks(writeTimeout)
        writeInFlight = null
        writeExpectsCallback = false
        if (!success) {
            log("Garmin local sync: ${current.label} write failed; reconnecting")
            gatt?.let(::abortAndReconnect)
            return
        }
        drainWrites()
    }

    private fun abortAndReconnect(g: BluetoothGatt) {
        if (gatt !== g) return
        resetSession()
        disconnectAndClose(g)
        gatt = null
        if (!intentionalDisconnect) scheduleReconnect()
    }

    private fun resetSession() {
        handler.removeCallbacks(writeTimeout)
        handler.removeCallbacks(serviceDiscoveryTimeout)
        handler.removeCallbacks(notificationSetupTimeout)
        writeQueue.clear()
        writeInFlight = null
        writeExpectsCallback = false
        receiveCharacteristic = null
        sendCharacteristic = null
        serviceByHandle.clear()
        cobsDecoder = GarminCobsStreamDecoder(MAX_ENCODED_FRAME)
        firstSampleLogged.clear()
        diagnosticOnce.clear()
        latestHeartRate = null
        latestHeartRateAt = 0
        negotiatedMtu = 23
        discoveryStarted = false
    }

    private fun disconnectAndClose(g: BluetoothGatt) {
        runCatching { g.disconnect() }
        runCatching { g.close() }
    }

    private fun logOnce(key: String, message: String) {
        if (diagnosticOnce.add(key)) log(message)
    }

    companion object {
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val REQUESTED_MTU = 247
        private const val MTU_FALLBACK_MS = 2_000L
        private const val SERVICE_DISCOVERY_TIMEOUT_MS = 10_000L
        private const val NOTIFICATION_SETUP_TIMEOUT_MS = 5_000L
        private const val WRITE_TIMEOUT_MS = 5_000L
        private const val NO_RESPONSE_SETTLE_MS = 35L
        private const val LIVE_HR_MAX_AGE_SECONDS = 10L
        private const val MAX_ENCODED_FRAME = 65_536
        private val REGISTERED_SERVICES = listOf(
            GarminMultiLinkService.GFDI,
            GarminMultiLinkService.REALTIME_HEART_RATE,
            GarminMultiLinkService.REALTIME_STEPS,
            GarminMultiLinkService.REALTIME_HRV,
            GarminMultiLinkService.REALTIME_SPO2,
            GarminMultiLinkService.REALTIME_RESPIRATION,
        )
        private val GARMIN_NAMES = listOf(
            "garmin", "fenix", "forerunner", "vivoactive", "venu", "epix", "instinct",
            "descent", "approach", "enduro", "marq", "edge",
        )

        internal fun looksGarmin(name: String): Boolean =
            GARMIN_NAMES.any { token -> name.contains(token, ignoreCase = true) }

        internal fun serviceLabel(service: GarminMultiLinkService): String = when (service) {
            GarminMultiLinkService.GFDI -> "GFDI"
            GarminMultiLinkService.REALTIME_HEART_RATE -> "heart-rate"
            GarminMultiLinkService.REALTIME_STEPS -> "steps"
            GarminMultiLinkService.REALTIME_HRV -> "HRV"
            GarminMultiLinkService.REALTIME_ACCELEROMETER -> "accelerometer"
            GarminMultiLinkService.REALTIME_SPO2 -> "SpO2"
            GarminMultiLinkService.REALTIME_BODY_BATTERY -> "Body Battery"
            GarminMultiLinkService.REALTIME_RESPIRATION -> "respiration"
        }
    }
}
