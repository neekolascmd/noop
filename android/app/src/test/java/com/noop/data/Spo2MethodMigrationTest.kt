package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Test

class Spo2MethodMigrationTest {
    @Test
    fun migrationAddsNullableEstimateProvenance() {
        assertEquals(
            "ALTER TABLE `dailyMetric` ADD COLUMN `spo2Method` TEXT",
            WhoopDatabase.SPO2_METHOD_MIGRATION_SQL,
        )
        assertEquals(20, WhoopDatabase.MIGRATION_20_21.startVersion)
        assertEquals(21, WhoopDatabase.MIGRATION_20_21.endVersion)
    }
}
