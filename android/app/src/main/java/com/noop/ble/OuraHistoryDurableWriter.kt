package com.noop.ble

import com.noop.data.StreamBatch

/** Resolved, timestamp-safe history writes. No BLE command or cursor mutation lives in this layer. */
internal sealed interface OuraHistoryWrite {
    data class Streams(val batch: StreamBatch) : OuraHistoryWrite
    data class SleepSession(val start: Long, val end: Long) : OuraHistoryWrite
}

/**
 * Sequentially awaits every Room-facing write. A false/throw stops the batch immediately; callers must
 * leave the cursor unchanged and send no max=0 ACK. Earlier successful writes are safe to replay because
 * Oura stream rows and sleep sessions use the repository's natural-key/idempotent insertion paths.
 */
internal class OuraHistoryDurableWriter(
    private val persistStreams: suspend (StreamBatch, String) -> Boolean,
    private val persistSleepSession: suspend (Long, Long) -> Boolean,
) {
    suspend fun persist(writes: List<OuraHistoryWrite>, deviceId: String): Boolean {
        for (write in writes) {
            val succeeded = runCatching {
                when (write) {
                    is OuraHistoryWrite.Streams -> persistStreams(write.batch, deviceId)
                    is OuraHistoryWrite.SleepSession -> persistSleepSession(write.start, write.end)
                }
            }.getOrDefault(false)
            if (!succeeded) return false
        }
        return true
    }
}
