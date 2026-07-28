package com.noop.data

import androidx.room.Entity
import androidx.room.Index

enum class WaveformStream(val wire: String) {
    POLAR_ECG("polar_ecg"),
    POLAR_PPG("polar_ppg");

    companion object {
        fun fromWire(value: String): WaveformStream? = entries.firstOrNull { it.wire == value }
    }
}

/** Device-agnostic dense waveform block; [deviceId] is attached at repository insertion. */
data class StoredWaveformChunk(
    val stream: WaveformStream,
    val startUnixNs: Long,
    val endUnixNs: Long,
    val sampleRateHz: Int,
    val channels: Int,
    val sampleCount: Int,
    val payload: ByteArray,
) {
    override fun equals(other: Any?): Boolean =
        other is StoredWaveformChunk &&
            stream == other.stream &&
            startUnixNs == other.startUnixNs &&
            endUnixNs == other.endUnixNs &&
            sampleRateHz == other.sampleRateHz &&
            channels == other.channels &&
            sampleCount == other.sampleCount &&
            payload.contentEquals(other.payload)

    override fun hashCode(): Int {
        var result = stream.hashCode()
        result = 31 * result + startUnixNs.hashCode()
        result = 31 * result + endUnixNs.hashCode()
        result = 31 * result + sampleRateHz
        result = 31 * result + channels
        result = 31 * result + sampleCount
        return 31 * result + payload.contentHashCode()
    }

    companion object {
        const val ENCODING = "int32_le_v1"
    }
}

/** Room twin of Swift `waveformChunk` migration v24. */
@Entity(
    tableName = "waveformChunk",
    primaryKeys = ["deviceId", "stream", "startUnixNs"],
    indices = [Index(
        value = ["deviceId", "endUnixNs"],
        name = "idx_waveformChunk_device_end",
    )],
)
data class WaveformChunkEntity(
    val deviceId: String,
    val stream: String,
    val startUnixNs: Long,
    val endUnixNs: Long,
    val sampleRateHz: Int,
    val channels: Int,
    val sampleCount: Int,
    val encoding: String,
    val byteSize: Long,
    val payload: ByteArray,
)

/** Lightweight row used only while evicting oldest chunks to the byte ceiling. */
data class WaveformPruneRow(val rowId: Long, val byteSize: Long)

data class WaveformRetentionLimits(
    val maxAgeNs: Long,
    val maxPayloadBytesPerDevice: Long,
) {
    companion object {
        val PRODUCTION = WaveformRetentionLimits(
            maxAgeNs = 24L * 60 * 60 * 1_000_000_000,
            maxPayloadBytesPerDevice = 64L * 1_024 * 1_024,
        )
    }
}

object WaveformStoreContract {
    fun validate(chunk: StoredWaveformChunk) {
        require(chunk.startUnixNs >= 0 && chunk.endUnixNs >= chunk.startUnixNs) {
            "invalid waveform timestamp range"
        }
        require(chunk.sampleRateHz in 1..10_000) { "invalid waveform sample rate" }
        require(chunk.channels in 1..16) { "invalid waveform channel count" }
        require(chunk.sampleCount in 1..4_096) { "invalid waveform sample count" }
        val expected = Math.multiplyExact(
            Math.multiplyExact(chunk.sampleCount, chunk.channels),
            Int.SIZE_BYTES,
        )
        require(expected == chunk.payload.size) { "invalid waveform payload length" }
    }

    /**
     * Return the oldest row ids that must go to reach [maxPayloadBytes]. Pure so the exact
     * whole-chunk retention behavior is JVM-testable without Room.
     */
    fun rowIdsToEvict(
        oldestFirst: List<WaveformPruneRow>,
        totalPayloadBytes: Long,
        maxPayloadBytes: Long,
    ): List<Long> {
        require(maxPayloadBytes > 0)
        var total = totalPayloadBytes.coerceAtLeast(0)
        val evict = mutableListOf<Long>()
        for (row in oldestFirst) {
            if (total <= maxPayloadBytes) break
            evict += row.rowId
            total = (total - row.byteSize.coerceAtLeast(0)).coerceAtLeast(0)
        }
        return evict
    }
}
