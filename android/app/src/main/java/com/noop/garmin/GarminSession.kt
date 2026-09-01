package com.noop.garmin

enum class GarminGfdiMessageId(val code: Int) {
    RESPONSE(5000),
    DEVICE_INFORMATION(5024),
    DEVICE_SETTINGS(5026),
    SYSTEM_EVENT(5030),
    SUPPORTED_FILE_TYPES(5031),
    NOTIFICATION_SUBSCRIPTION(5036),
    PROTOBUF_REQUEST(5043),
    CONFIGURATION(5050),
    CURRENT_TIME_REQUEST(5052),
    AUTH_NEGOTIATION(5101);

    companion object { fun fromCode(code: Int): GarminGfdiMessageId? = entries.firstOrNull { it.code == code } }
}

data class GarminHostIdentity(
    val protocolVersion: Int = 150,
    val productNumber: Int = 0xffff,
    val unitNumber: Long = 0xffff_ffffL,
    val softwareVersion: Int = 8300,
    val maximumPacketSize: Int = 0xffff,
    val bluetoothName: String = "NOOP",
    val manufacturer: String = "NOOP",
    val model: String = "Offline companion",
)

enum class GarminSessionError { MALFORMED_REQUEST, INVALID_TIME, FIELD_TOO_LONG, TOO_MANY_CAPABILITIES }
class GarminSessionException(val reason: GarminSessionError) : IllegalArgumentException(reason.name)

data class GarminSessionReply(val outgoing: List<ByteArray>, val configurationCompleted: Boolean = false)

/** Minimal handshake that never claims an unimplemented phone feature. */
object GarminSessionResponder {
    const val SYNC_READY_EVENT = 8

    fun reply(
        message: GarminGfdiMessage,
        nowUnixSeconds: Long,
        timeZoneOffsetSeconds: Int,
        identity: GarminHostIdentity = GarminHostIdentity(),
        supportedCapabilities: ByteArray = byteArrayOf(),
    ): GarminSessionReply? {
        val kind = GarminGfdiMessageId.fromCode(message.messageId) ?: return null
        return when (kind) {
            GarminGfdiMessageId.DEVICE_INFORMATION -> {
                if (message.payload.size < 2) throw GarminSessionException(GarminSessionError.MALFORMED_REQUEST)
                val incomingProtocol = u16(message.payload, 0)
                val body = ArrayList<Byte>()
                responsePrefix(kind, GarminGfdiStatus.ACKNOWLEDGEMENT).forEach(body::add)
                le16(identity.protocolVersion).forEach(body::add)
                le16(identity.productNumber).forEach(body::add)
                le32(identity.unitNumber).forEach(body::add)
                le16(identity.softwareVersion).forEach(body::add)
                le16(identity.maximumPacketSize).forEach(body::add)
                wireString(identity.bluetoothName).forEach(body::add)
                wireString(identity.manufacturer).forEach(body::add)
                wireString(identity.model).forEach(body::add)
                body.add(if (incomingProtocol / 100 == 1) 1 else 0)
                GarminSessionReply(listOf(GarminGfdi.encode(GarminGfdiMessageId.RESPONSE.code, payload = body.toByteArray())))
            }
            GarminGfdiMessageId.CONFIGURATION -> {
                if (supportedCapabilities.size > 255) {
                    throw GarminSessionException(GarminSessionError.TOO_MANY_CAPABILITIES)
                }
                // Mirroring the watch bitset would falsely advertise every feature the watch supports.
                val config = GarminGfdi.encode(
                    kind.code,
                    payload = byteArrayOf(supportedCapabilities.size.toByte()) + supportedCapabilities,
                )
                val ready = GarminGfdi.encode(
                    GarminGfdiMessageId.SYSTEM_EVENT.code,
                    payload = byteArrayOf(SYNC_READY_EVENT.toByte()),
                )
                GarminSessionReply(listOf(config, ready), configurationCompleted = true)
            }
            GarminGfdiMessageId.AUTH_NEGOTIATION -> GarminSessionReply(
                listOf(
                    GarminGfdi.encode(
                        GarminGfdiMessageId.RESPONSE.code,
                        payload = responsePrefix(kind, GarminGfdiStatus.ACKNOWLEDGEMENT) + byteArrayOf(0, 0, 0, 0, 0),
                    ),
                ),
            )
            GarminGfdiMessageId.CURRENT_TIME_REQUEST -> {
                if (message.payload.size < 4) throw GarminSessionException(GarminSessionError.MALFORMED_REQUEST)
                val garminTime = GarminEpoch.garminSeconds(nowUnixSeconds)
                    ?: throw GarminSessionException(GarminSessionError.INVALID_TIME)
                val payload = responsePrefix(kind, GarminGfdiStatus.ACKNOWLEDGEMENT) +
                    message.payload.copyOfRange(0, 4) + le32(garminTime) +
                    le32(timeZoneOffsetSeconds.toLong() and 0xffff_ffffL) + ByteArray(8)
                GarminSessionReply(listOf(GarminGfdi.encode(GarminGfdiMessageId.RESPONSE.code, payload = payload)))
            }
            GarminGfdiMessageId.NOTIFICATION_SUBSCRIPTION,
            GarminGfdiMessageId.PROTOBUF_REQUEST -> GarminSessionReply(
                listOf(
                    GarminGfdi.encode(
                        GarminGfdiMessageId.RESPONSE.code,
                        payload = responsePrefix(kind, GarminGfdiStatus.UNSUPPORTED),
                    ),
                ),
            )
            GarminGfdiMessageId.RESPONSE,
            GarminGfdiMessageId.DEVICE_SETTINGS,
            GarminGfdiMessageId.SYSTEM_EVENT,
            GarminGfdiMessageId.SUPPORTED_FILE_TYPES -> null
        }
    }

    private fun responsePrefix(id: GarminGfdiMessageId, status: GarminGfdiStatus): ByteArray =
        le16(id.code) + status.code.toByte()

    private fun wireString(value: String): ByteArray {
        val bytes = value.toByteArray(Charsets.UTF_8)
        if (bytes.size > 255) throw GarminSessionException(GarminSessionError.FIELD_TOO_LONG)
        return byteArrayOf(bytes.size.toByte()) + bytes
    }

    private fun le16(value: Int): ByteArray = byteArrayOf(value.toByte(), (value ushr 8).toByte())
    private fun le32(value: Long): ByteArray = byteArrayOf(
        value.toByte(), (value ushr 8).toByte(), (value ushr 16).toByte(), (value ushr 24).toByte(),
    )
    private fun u16(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xff) or ((bytes[offset + 1].toInt() and 0xff) shl 8)
}
