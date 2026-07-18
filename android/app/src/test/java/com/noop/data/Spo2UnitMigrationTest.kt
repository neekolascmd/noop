package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Test

class Spo2UnitMigrationTest {
    @Test
    fun migrationAddsNonNullUnitWithLegacyRawDefault() {
        assertEquals(
            "ALTER TABLE `spo2Sample` ADD COLUMN `unit` TEXT NOT NULL DEFAULT 'raw_adc'",
            WhoopDatabase.SPO2_UNIT_MIGRATION_SQL,
        )
        assertEquals(16, WhoopDatabase.MIGRATION_16_17.startVersion)
        assertEquals(17, WhoopDatabase.MIGRATION_16_17.endVersion)
    }
}
