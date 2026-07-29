package com.noop.data

import com.noop.oura.OuraRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class OuraRawHistoryStoreTest {
    @Test
    fun migrationMatchesRoomEntityShape() {
        assertEquals(18, WhoopDatabase.MIGRATION_18_19.startVersion)
        assertEquals(19, WhoopDatabase.MIGRATION_18_19.endVersion)
        assertEquals(
            listOf(
                "CREATE TABLE IF NOT EXISTS `ouraRawHistory` (`archiveId` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, " +
                    "`deviceId` TEXT NOT NULL, `ringTimestamp` INTEGER NOT NULL, `tag` INTEGER NOT NULL, " +
                    "`payload` BLOB NOT NULL, `wireByteSize` INTEGER NOT NULL, " +
                    "`firstSeenAtUnixMs` INTEGER NOT NULL)",
                "CREATE UNIQUE INDEX IF NOT EXISTS `idx_ouraRawHistory_exact` " +
                    "ON `ouraRawHistory` (`deviceId`, `ringTimestamp`, `tag`, `payload`)",
                "CREATE INDEX IF NOT EXISTS `idx_ouraRawHistory_device_seen` " +
                    "ON `ouraRawHistory` (`deviceId`, `firstSeenAtUnixMs`, `archiveId`)",
            ),
            WhoopDatabase.OURA_RAW_HISTORY_MIGRATION_SQL,
        )
        assertEquals(19, WhoopDatabase.MIGRATION_19_20.startVersion)
        assertEquals(20, WhoopDatabase.MIGRATION_19_20.endVersion)
        assertEquals(
            listOf(
                "ALTER TABLE `ouraRawHistory` ADD COLUMN `anchorUtcMilliseconds` INTEGER",
                "ALTER TABLE `ouraRawHistory` ADD COLUMN `anchorRingTimestamp` INTEGER",
                "ALTER TABLE `ouraRawHistory` ADD COLUMN `anchorFactorMillisecondsPerTick` INTEGER",
                "ALTER TABLE `ouraRawHistory` ADD COLUMN `decodedRevision` INTEGER NOT NULL DEFAULT 0",
                "CREATE INDEX IF NOT EXISTS `idx_ouraRawHistory_device_revision` " +
                    "ON `ouraRawHistory` (`deviceId`, `decodedRevision`, `archiveId`)",
            ),
            WhoopDatabase.OURA_RAW_REDECODE_MIGRATION_SQL,
        )
    }

    @Test
    fun contractAcceptsFullLegalTlv() {
        OuraRawHistoryStoreContract.validate(
            OuraRecord(
                type = 0xFF,
                ringTimestamp = 0xFFFF_FFFFL,
                payload = IntArray(251) { it and 0xFF },
            ),
        )
    }

    @Test
    fun contractRejectsOuterOrOversizedFrames() {
        assertThrows(IllegalArgumentException::class.java) {
            OuraRawHistoryStoreContract.validate(OuraRecord(0x2F, 1, intArrayOf()))
        }
        assertThrows(IllegalArgumentException::class.java) {
            OuraRawHistoryStoreContract.validate(OuraRecord(0x41, 1, IntArray(252)))
        }
    }

    @Test
    fun byteRetentionEvictsOldestWholeRecords() {
        assertEquals(
            listOf(10L, 20L),
            OuraRawHistoryStoreContract.rowIdsToEvict(
                oldestFirst = listOf(
                    OuraRawHistoryPruneRow(10, 7),
                    OuraRawHistoryPruneRow(20, 7),
                    OuraRawHistoryPruneRow(30, 7),
                ),
                totalWireBytes = 21,
                maxWireBytes = 7,
            ),
        )
    }

    @Test
    fun productionLimitIsFiniteAndSubstantial() {
        val limit = OuraRawHistoryRetentionLimits.PRODUCTION.maxWireBytesPerDevice
        assertEquals(128L * 1_024 * 1_024, limit)
        assertTrue(limit > 0)
    }
}
