package com.noop.garmin

object GarminMultiLinkUuid {
    const val SERVICE = "6A4E2800-667B-11E3-949A-0800200C9A66"
    val READ_CHARACTERISTICS: List<String> = (0..4).map {
        "6A4E281${it.toString(16).uppercase()}-667B-11E3-949A-0800200C9A66"
    }
    val WRITE_CHARACTERISTICS: List<String> = (0..4).map {
        "6A4E282${it.toString(16).uppercase()}-667B-11E3-949A-0800200C9A66"
    }
}

/** Pure ATT fragmentation: every write repeats the logical service handle, then carries MTU-4 bytes. */
object GarminMultiLinkFraming {
    fun fragment(handle: Int, encodedPayload: ByteArray, attMtu: Int): List<ByteArray> {
        require(handle in 1..255)
        require(attMtu >= 5)
        val contentPerWrite = attMtu - 4 // ATT header (3) + logical handle (1)
        if (encodedPayload.isEmpty()) return listOf(byteArrayOf(handle.toByte()))
        val packets = ArrayList<ByteArray>((encodedPayload.size + contentPerWrite - 1) / contentPerWrite)
        var offset = 0
        while (offset < encodedPayload.size) {
            val end = minOf(offset + contentPerWrite, encodedPayload.size)
            packets += byteArrayOf(handle.toByte()) + encodedPayload.copyOfRange(offset, end)
            offset = end
        }
        return packets
    }
}

enum class GarminMultiLinkService(val code: Int) {
    GFDI(1),
    REALTIME_HEART_RATE(6),
    REALTIME_STEPS(7),
    REALTIME_HRV(12),
    REALTIME_ACCELEROMETER(16),
    REALTIME_SPO2(19),
    REALTIME_BODY_BATTERY(20),
    REALTIME_RESPIRATION(21);

    companion object {
        fun fromCode(code: Int): GarminMultiLinkService? = entries.firstOrNull { it.code == code }
    }
}

class GarminClientId(bytes: ByteArray = byteArrayOf(2, 0, 0, 0, 0, 0, 0, 0)) {
    val bytes: ByteArray = bytes.copyOf()
    init { require(this.bytes.size == 8) }
    override fun equals(other: Any?): Boolean = other is GarminClientId && bytes.contentEquals(other.bytes)
    override fun hashCode(): Int = bytes.contentHashCode()
}

enum class GarminHandleReliability(val code: Int) { MULTI_LINK(0), RELIABLE(2) }

data class GarminHandleRegistration(
    val clientId: GarminClientId,
    val serviceCode: Int,
    val statusRaw: Int,
    val succeeded: Boolean,
    val handle: Int?,
    val reliable: Boolean?,
    val usesMultiLinkCharacteristic: Boolean?,
)

object GarminHandleManagement {
    fun register(
        service: GarminMultiLinkService,
        clientId: GarminClientId = GarminClientId(),
        reliability: GarminHandleReliability = GarminHandleReliability.MULTI_LINK,
    ): ByteArray = byteArrayOf(0, 0) + clientId.bytes + le(service.code) + reliability.code.toByte()

    fun close(
        service: GarminMultiLinkService,
        handle: Int,
        clientId: GarminClientId = GarminClientId(),
    ): ByteArray {
        require(handle in 0..255)
        return byteArrayOf(0, 2) + clientId.bytes + le(service.code) + handle.toByte()
    }

    fun closeAll(clientId: GarminClientId = GarminClientId(), flags: Int = 0): ByteArray {
        require(flags in 0..0xffff)
        return byteArrayOf(0, 5) + clientId.bytes + le(flags)
    }

    /** A close-all response carries only handle 0, response type 6 and this client's 64-bit id. */
    fun isCloseAllResponse(bytes: ByteArray, clientId: GarminClientId = GarminClientId()): Boolean =
        bytes.size >= 10 && bytes[0].toInt() == 0 && bytes[1].toInt() == 6 &&
            bytes.copyOfRange(2, 10).contentEquals(clientId.bytes)

    /** Parses a complete characteristic notification, including its leading handle byte. */
    fun parseRegistrationResponse(bytes: ByteArray): GarminHandleRegistration? {
        if (bytes.size < 13 || bytes[0].toInt() != 0 || bytes[1].toInt() != 1) return null
        val client = GarminClientId(bytes.copyOfRange(2, 10))
        val service = u16(bytes, 10)
        val status = bytes[12].toInt() and 0xff
        if (status != 0) {
            return GarminHandleRegistration(client, service, status, false, null, null, null)
        }
        if (bytes.size != 15 && bytes.size != 16) return null
        return GarminHandleRegistration(
            clientId = client,
            serviceCode = service,
            statusRaw = status,
            succeeded = true,
            handle = bytes[13].toInt() and 0xff,
            reliable = bytes[14].toInt() != 0,
            usesMultiLinkCharacteristic = bytes.getOrNull(15)?.let { (it.toInt() and 1) != 0 },
        )
    }

    private fun le(value: Int): ByteArray = byteArrayOf(value.toByte(), (value ushr 8).toByte())
    private fun u16(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xff) or ((bytes[offset + 1].toInt() and 0xff) shl 8)
}
