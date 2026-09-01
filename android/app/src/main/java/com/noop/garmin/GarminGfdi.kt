package com.noop.garmin

enum class GarminGfdiStatus(val code: Int) {
    ACKNOWLEDGEMENT(0),
    NEGATIVE_ACKNOWLEDGEMENT(1),
    UNSUPPORTED(2),
    DECODE_ERROR(3),
    CRC_ERROR(4),
    LENGTH_ERROR(5);

    companion object {
        fun fromCode(code: Int): GarminGfdiStatus? = entries.firstOrNull { it.code == code }
    }
}

data class GarminGfdiMessage(
    val messageId: Int,
    val sequence: Int?,
    val payload: ByteArray,
    val responseToMessageId: Int?,
    val statusRaw: Int?,
    val status: GarminGfdiStatus?,
)

enum class GarminGfdiError { TOO_SHORT, INVALID_LENGTH, INVALID_CRC, INVALID_SEQUENCE, INVALID_MESSAGE_ID }

class GarminGfdiException(val reason: GarminGfdiError) : IllegalArgumentException(reason.name)

/** Length/CRC envelope inside the Garmin COBS frame. */
object GarminGfdi {
    fun crc16(bytes: ByteArray): Int {
        var crc = 0
        for (byte in bytes) {
            crc = crc xor (byte.toInt() and 0xff)
            repeat(8) {
                crc = if ((crc and 1) != 0) (crc ushr 1) xor 0xa001 else crc ushr 1
            }
        }
        return crc and 0xffff
    }

    fun encode(messageId: Int, sequence: Int? = null, payload: ByteArray = byteArrayOf()): ByteArray {
        val body = ArrayList<Byte>(payload.size + 2)
        if (sequence != null) {
            if (sequence !in 0..31) throw GarminGfdiException(GarminGfdiError.INVALID_SEQUENCE)
            if (messageId !in 5000..5255) throw GarminGfdiException(GarminGfdiError.INVALID_MESSAGE_ID)
            body.add((messageId - 5000).toByte())
            body.add((0x80 or sequence).toByte())
        } else {
            body.add((messageId and 0xff).toByte())
            body.add(((messageId ushr 8) and 0xff).toByte())
        }
        payload.forEach(body::add)
        val total = body.size + 4
        if (total > 0xffff) throw GarminGfdiException(GarminGfdiError.INVALID_LENGTH)
        val envelope = ByteArray(total)
        envelope[0] = (total and 0xff).toByte()
        envelope[1] = ((total ushr 8) and 0xff).toByte()
        body.forEachIndexed { index, byte -> envelope[index + 2] = byte }
        val crc = crc16(envelope.copyOfRange(0, total - 2))
        envelope[total - 2] = (crc and 0xff).toByte()
        envelope[total - 1] = ((crc ushr 8) and 0xff).toByte()
        return envelope
    }

    fun decode(bytes: ByteArray): GarminGfdiMessage {
        if (bytes.size < 6) throw GarminGfdiException(GarminGfdiError.TOO_SHORT)
        if (u16(bytes, 0) != bytes.size) throw GarminGfdiException(GarminGfdiError.INVALID_LENGTH)
        if (crc16(bytes.copyOfRange(0, bytes.size - 2)) != u16(bytes, bytes.size - 2)) {
            throw GarminGfdiException(GarminGfdiError.INVALID_CRC)
        }
        val compact = (bytes[3].toInt() and 0x80) != 0
        val messageId = if (compact) 5000 + (bytes[2].toInt() and 0xff) else u16(bytes, 2)
        val sequence = if (compact) bytes[3].toInt() and 0x1f else null
        val payload = bytes.copyOfRange(4, bytes.size - 2)
        val responseTo = if (messageId == 5000 && payload.size >= 3) u16(payload, 0) else null
        val statusRaw = if (responseTo != null) payload[2].toInt() and 0xff else null
        return GarminGfdiMessage(
            messageId = messageId,
            sequence = sequence,
            payload = payload,
            responseToMessageId = responseTo,
            statusRaw = statusRaw,
            status = statusRaw?.let(GarminGfdiStatus::fromCode),
        )
    }

    private fun u16(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xff) or ((bytes[offset + 1].toInt() and 0xff) shl 8)
}
