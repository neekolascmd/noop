package com.noop.polar

/** The dense PMD streams NOOP retains in its bounded rolling waveform store. */
enum class PolarPmdWaveformKind(val wire: String) {
    ECG("polar_ecg"),
    PPG("polar_ppg"),
}

/**
 * Compact platform-neutral block of interleaved signed-32-bit samples.
 *
 * [payload] is row-major `int32_le_v1`: one ECG value per sample, or PPG channel 0/1/2/ambient
 * per sample. Exact sample instants are reconstructed linearly from [startUnixNs], [endUnixNs],
 * and [sampleCount].
 */
data class PolarPmdWaveformChunk(
    val kind: PolarPmdWaveformKind,
    val startUnixNs: Long,
    val endUnixNs: Long,
    val sampleRateHz: Int,
    val channels: Int,
    val sampleCount: Int,
    val payload: ByteArray,
) {
    companion object {
        const val ENCODING = "int32_le_v1"
    }

    override fun equals(other: Any?): Boolean =
        other is PolarPmdWaveformChunk &&
            kind == other.kind &&
            startUnixNs == other.startUnixNs &&
            endUnixNs == other.endUnixNs &&
            sampleRateHz == other.sampleRateHz &&
            channels == other.channels &&
            sampleCount == other.sampleCount &&
            payload.contentEquals(other.payload)

    override fun hashCode(): Int {
        var result = kind.hashCode()
        result = 31 * result + startUnixNs.hashCode()
        result = 31 * result + endUnixNs.hashCode()
        result = 31 * result + sampleRateHz
        result = 31 * result + channels
        result = 31 * result + sampleCount
        return 31 * result + payload.contentHashCode()
    }
}

/**
 * Coalesces high-rate notification frames into bounded chunks before they reach SQLite.
 *
 * Five-second chunks keep row overhead small, while the hard sample cap prevents one malformed
 * frame or clock from growing an in-memory block without bound.
 */
class PolarPmdWaveformBuffer {
    private data class Pending(
        val kind: PolarPmdWaveformKind,
        val startUnixNs: Long,
        var endUnixNs: Long,
        val sampleRateHz: Int,
        val channels: Int,
        var sampleCount: Int = 0,
        val payload: MutableList<Byte> = mutableListOf(),
    ) {
        fun chunk(): PolarPmdWaveformChunk = PolarPmdWaveformChunk(
            kind = kind,
            startUnixNs = startUnixNs,
            endUnixNs = endUnixNs,
            sampleRateHz = sampleRateHz,
            channels = channels,
            sampleCount = sampleCount,
            payload = payload.toByteArray(),
        )
    }

    private val pending = mutableMapOf<PolarPmdWaveformKind, Pending>()

    fun reset() {
        pending.clear()
    }

    fun appendEcg(
        samples: List<PolarPmdEcgSample>,
        unixTimestampsNs: List<Long>,
        sampleRateHz: Int,
    ): List<PolarPmdWaveformChunk> {
        if (samples.size != unixTimestampsNs.size) {
            throw PolarPmdException("malformed ECG waveform timestamp count")
        }
        return append(
            kind = PolarPmdWaveformKind.ECG,
            unixTimestampsNs = unixTimestampsNs,
            sampleRateHz = sampleRateHz,
            channels = 1,
            values = samples.map { listOf(it.microVolts) },
        )
    }

    fun appendPpg(
        samples: List<PolarPmdPpgSample>,
        unixTimestampsNs: List<Long>,
        sampleRateHz: Int,
    ): List<PolarPmdWaveformChunk> {
        if (samples.size != unixTimestampsNs.size) {
            throw PolarPmdException("malformed PPG waveform timestamp count")
        }
        return append(
            kind = PolarPmdWaveformKind.PPG,
            unixTimestampsNs = unixTimestampsNs,
            sampleRateHz = sampleRateHz,
            channels = 4,
            values = samples.map {
                if (it.channels.size != 3) throw PolarPmdException("malformed PPG waveform channel count")
                it.channels + it.ambient
            },
        )
    }

    /** Emit every partial chunk, used on disconnect/stop so the final seconds are durable. */
    fun flush(): List<PolarPmdWaveformChunk> {
        val chunks = pending.values.map { it.chunk() }
            .sortedWith(compareBy<PolarPmdWaveformChunk> { it.startUnixNs }.thenBy { it.kind.wire })
        pending.clear()
        return chunks
    }

    private fun append(
        kind: PolarPmdWaveformKind,
        unixTimestampsNs: List<Long>,
        sampleRateHz: Int,
        channels: Int,
        values: List<List<Int>>,
    ): List<PolarPmdWaveformChunk> {
        if (values.isEmpty()) return emptyList()
        if (values.size != unixTimestampsNs.size) {
            throw PolarPmdException("malformed ${kind.wire} waveform timestamp count")
        }
        if (sampleRateHz !in 1..10_000) {
            throw PolarPmdException("malformed ${kind.wire} waveform sample rate")
        }
        if (channels !in 1..16) {
            throw PolarPmdException("limit exceeded ${kind.wire} waveform channels")
        }

        val emitted = mutableListOf<PolarPmdWaveformChunk>()
        for (index in values.indices) {
            val timestamp = unixTimestampsNs[index]
            val row = values[index]
            if (row.size != channels) {
                throw PolarPmdException("malformed ${kind.wire} waveform row width")
            }

            pending[kind]?.let { current ->
                if (timestamp <= current.endUnixNs) {
                    throw PolarPmdException("malformed ${kind.wire} waveform timestamps are not increasing")
                }
                if (current.sampleRateHz != sampleRateHz ||
                    current.channels != channels ||
                    timestamp - current.startUnixNs >= TARGET_DURATION_NS ||
                    current.sampleCount >= MAXIMUM_SAMPLES_PER_CHUNK
                ) {
                    emitted += current.chunk()
                    pending.remove(kind)
                }
            }

            val current = pending.getOrPut(kind) {
                Pending(
                    kind = kind,
                    startUnixNs = timestamp,
                    endUnixNs = timestamp,
                    sampleRateHz = sampleRateHz,
                    channels = channels,
                )
            }
            for (value in row) {
                current.payload += value.toByte()
                current.payload += (value ushr 8).toByte()
                current.payload += (value ushr 16).toByte()
                current.payload += (value ushr 24).toByte()
            }
            current.endUnixNs = timestamp
            current.sampleCount += 1
        }
        return emitted
    }

    companion object {
        const val TARGET_DURATION_NS = 5_000_000_000L
        const val MAXIMUM_SAMPLES_PER_CHUNK = 4_096
    }
}
