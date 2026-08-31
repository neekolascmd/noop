package com.noop.ble

import com.noop.data.OuraRawHistoryRedecodeReport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OuraArchiveReplayRefreshTest {
    @Test
    fun decodedSignalsWithoutSleepDoNotScheduleAReadModelRefresh() {
        val logs = mutableListOf<String>()
        val changed = mutableListOf<String>()

        publishOuraArchiveReplayReport(
            report = OuraRawHistoryRedecodeReport(
                decodedRecords = 3,
                insertedRows = 7,
                withheldEvents = 1,
            ),
            deviceId = "oura-ring",
            log = logs::add,
            onSleepChanged = changed::add,
        )

        assertEquals(1, logs.size)
        assertTrue(changed.isEmpty())
    }

    @Test
    fun materializedSleepSchedulesTheOwningDeviceExactlyOnce() {
        val logs = mutableListOf<String>()
        val changed = mutableListOf<String>()

        publishOuraArchiveReplayReport(
            // A staged archive reconstruction can succeed even when snapshot-CAS leaves every raw row
            // revision-old for a retry, so the sleep count—not decodedRecords—is the invalidation gate.
            report = OuraRawHistoryRedecodeReport(sleepSessions = 2),
            deviceId = "oura-ring",
            log = logs::add,
            onSleepChanged = changed::add,
        )

        assertTrue(logs.isEmpty())
        assertEquals(listOf("oura-ring"), changed)
    }

    @Test
    fun historyAnalysisCoalescesPerDeviceWithoutDroppingAnotherWearable() {
        val gate = PerDeviceHistoryAnalysisGate()

        assertTrue(gate.begin("my-whoop"))
        assertTrue(!gate.begin("my-whoop"))
        assertTrue(gate.begin("oura-ring"))

        gate.finish("my-whoop")
        assertTrue(gate.begin("my-whoop"))
    }
}
