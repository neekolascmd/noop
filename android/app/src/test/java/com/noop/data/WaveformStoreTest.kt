package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WaveformStoreTest {
    @Test
    fun migrationMatchesRoomEntityShape() {
        assertEquals(17, WhoopDatabase.MIGRATION_17_18.startVersion)
        assertEquals(18, WhoopDatabase.MIGRATION_17_18.endVersion)
        assertEquals(
            listOf(
                "CREATE TABLE IF NOT EXISTS `waveformChunk` (`deviceId` TEXT NOT NULL, " +
                    "`stream` TEXT NOT NULL, `startUnixNs` INTEGER NOT NULL, " +
                    "`endUnixNs` INTEGER NOT NULL, `sampleRateHz` INTEGER NOT NULL, " +
                    "`channels` INTEGER NOT NULL, `sampleCount` INTEGER NOT NULL, " +
                    "`encoding` TEXT NOT NULL, `byteSize` INTEGER NOT NULL, `payload` BLOB NOT NULL, " +
                    "PRIMARY KEY(`deviceId`, `stream`, `startUnixNs`))",
                "CREATE INDEX IF NOT EXISTS `idx_waveformChunk_device_end` " +
                    "ON `waveformChunk` (`deviceId`, `endUnixNs`)",
            ),
            WhoopDatabase.WAVEFORM_CHUNK_MIGRATION_SQL,
        )
    }

    @Test
    fun contractAcceptsExactInterleavedPayload() {
        WaveformStoreContract.validate(
            StoredWaveformChunk(
                stream = WaveformStream.POLAR_PPG,
                startUnixNs = 1,
                endUnixNs = 2,
                sampleRateHz = 135,
                channels = 4,
                sampleCount = 2,
                payload = ByteArray(2 * 4 * Int.SIZE_BYTES),
            ),
        )
    }

    @Test
    fun contractRejectsPayloadShapeMismatch() {
        assertThrows(IllegalArgumentException::class.java) {
            WaveformStoreContract.validate(
                StoredWaveformChunk(
                    stream = WaveformStream.POLAR_ECG,
                    startUnixNs = 1,
                    endUnixNs = 2,
                    sampleRateHz = 130,
                    channels = 1,
                    sampleCount = 2,
                    payload = ByteArray(4),
                ),
            )
        }
    }

    @Test
    fun byteRetentionEvictsOldestWholeChunks() {
        assertEquals(
            listOf(10L, 20L),
            WaveformStoreContract.rowIdsToEvict(
                oldestFirst = listOf(
                    WaveformPruneRow(10, 4),
                    WaveformPruneRow(20, 4),
                    WaveformPruneRow(30, 4),
                ),
                totalPayloadBytes = 12,
                maxPayloadBytes = 4,
            ),
        )
    }

    @Test
    fun productionLimitsAreFiniteAndCoverAnOvernightPpgBuffer() {
        val limits = WaveformRetentionLimits.PRODUCTION
        assertEquals(24L * 60 * 60 * 1_000_000_000, limits.maxAgeNs)
        assertEquals(64L * 1_024 * 1_024, limits.maxPayloadBytesPerDevice)
        val eightHoursPpgBytes = 8L * 60 * 60 * 135 * 4 * Int.SIZE_BYTES
        assertTrue(limits.maxPayloadBytesPerDevice > eightHoursPpgBytes)
    }
}
