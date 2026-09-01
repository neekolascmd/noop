package com.noop.garmin

/** Errors from Garmin's COBS payload wrapper. */
enum class GarminCobsError { MISSING_BOUNDARY, MALFORMED, FRAME_TOO_LARGE }

class GarminCobsException(val reason: GarminCobsError) : IllegalArgumentException(reason.name)

/**
 * Garmin GFDI v2 wraps standard COBS content in both a leading and trailing zero delimiter.
 * This implementation is platform-pure so captured notifications can be replayed on the JVM.
 */
object GarminCobs {
    fun encode(payload: ByteArray): ByteArray {
        val out = ArrayList<Byte>(payload.size + payload.size / 254 + 3)
        out.add(0)
        var codeIndex = out.size
        out.add(0)
        var code = 1

        for (byte in payload) {
            if (byte.toInt() == 0) {
                out[codeIndex] = code.toByte()
                codeIndex = out.size
                out.add(0)
                code = 1
            } else {
                out.add(byte)
                code += 1
                if (code == 0xff) {
                    out[codeIndex] = 0xff.toByte()
                    codeIndex = out.size
                    out.add(0)
                    code = 1
                }
            }
        }
        out[codeIndex] = code.toByte()
        out.add(0)
        return out.toByteArray()
    }

    fun decode(framed: ByteArray, maximumDecodedSize: Int = 65_535): ByteArray {
        if (framed.size < 3 || framed.first().toInt() != 0 || framed.last().toInt() != 0) {
            throw GarminCobsException(GarminCobsError.MISSING_BOUNDARY)
        }
        val out = ArrayList<Byte>(framed.size)
        var index = 1
        val end = framed.lastIndex
        while (index < end) {
            val code = framed[index].toInt() and 0xff
            if (code == 0) throw GarminCobsException(GarminCobsError.MALFORMED)
            index += 1
            val count = code - 1
            if (index + count > end) throw GarminCobsException(GarminCobsError.MALFORMED)
            repeat(count) { out.add(framed[index++]) }
            if (code != 0xff && index < end) out.add(0)
            if (out.size > maximumDecodedSize) {
                throw GarminCobsException(GarminCobsError.FRAME_TOO_LARGE)
            }
        }
        return out.toByteArray()
    }
}

sealed interface GarminFrameResult {
    data class Frame(val bytes: ByteArray) : GarminFrameResult
    data class Failure(val error: GarminCobsError) : GarminFrameResult
}

/** Bounded reassembly for frames split or coalesced across BLE notifications. */
class GarminCobsStreamDecoder(val maximumEncodedSize: Int = 65_536) {
    init { require(maximumEncodedSize > 0) }

    private val encoded = ArrayList<Byte>()
    private var insideFrame = false
    private var droppingOversize = false

    fun feed(bytes: ByteArray): List<GarminFrameResult> {
        val results = ArrayList<GarminFrameResult>()
        for (byte in bytes) {
            if (byte.toInt() == 0) {
                when {
                    droppingOversize -> {
                        droppingOversize = false
                        encoded.clear()
                        insideFrame = true
                    }
                    insideFrame && encoded.isNotEmpty() -> {
                        val framed = ByteArray(encoded.size + 2)
                        encoded.forEachIndexed { i, value -> framed[i + 1] = value }
                        results += try {
                            GarminFrameResult.Frame(
                                GarminCobs.decode(framed, maximumDecodedSize = maximumEncodedSize),
                            )
                        } catch (error: GarminCobsException) {
                            GarminFrameResult.Failure(error.reason)
                        }
                        encoded.clear()
                        insideFrame = true
                    }
                    else -> insideFrame = true
                }
            } else if (insideFrame && !droppingOversize) {
                encoded.add(byte)
                if (encoded.size > maximumEncodedSize) {
                    encoded.clear()
                    droppingOversize = true
                    results += GarminFrameResult.Failure(GarminCobsError.FRAME_TOO_LARGE)
                }
            }
        }
        return results
    }
}
