package com.noop.data

import com.noop.oura.OuraEventTag
import com.noop.oura.OuraRingGen
import com.noop.oura.OuraTimeAnchor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OuraRawHistoryRedecoderTest {
    @Test
    fun anchorBackfillDoesNotCrossMissingResetReceiptCohortButKeepsLateRecovery() {
        val oldSeenAtUnixMs = 1_800_000_000_000L
        val carrierSeenAtUnixMs = oldSeenAtUnixMs + 24 * 60 * 60 * 1_000L
        val anchor = OuraTimeAnchor(
            ringTimestamp = 40_000,
            utcMilliseconds = 1_800_086_400_000L,
            factorMillisecondsPerTick = 100,
        )
        val oldClockSession = StoredOuraRawHistoryRecord(
            archiveId = 1,
            tag = OuraEventTag.TEMP.raw,
            ringTimestamp = 39_950,
            payload = byteArrayOf(0x42, 0x0E),
            firstSeenAtUnixMs = oldSeenAtUnixMs,
        )
        val sameCohort = oldClockSession.copy(
            archiveId = 2,
            firstSeenAtUnixMs = carrierSeenAtUnixMs - 1_000,
        )

        assertFalse(
            OuraRawHistoryAnchorBackfillPolicy.canBackfill(
                oldClockSession,
                anchor,
                carrierSeenAtUnixMs,
            ),
        )
        assertTrue(
            OuraRawHistoryAnchorBackfillPolicy.canBackfill(
                sameCohort,
                anchor,
                carrierSeenAtUnixMs,
            ),
        )
        val backwardRange = OuraRawAnchorAdjacentRangeAccumulator(
            fromArchiveId = 1,
            throughArchiveId = 2,
            carrierArchiveId = 3,
            anchor = anchor,
            anchorCarrierFirstSeenAtUnixMs = carrierSeenAtUnixMs,
        )
        backwardRange.consume(listOf(oldClockSession, sameCohort))
        assertEquals(
            OuraRawAnchorRange(2, 2),
            backwardRange.result(),
        )
    }

    @Test
    fun anchorBackfillRejectsProjectionAfterReceiptTolerance() {
        val receiptSeconds = 1_800_000_000L
        val receiptMilliseconds = receiptSeconds * 1_000
        val anchor = OuraTimeAnchor(
            ringTimestamp = 40_000,
            utcMilliseconds = receiptMilliseconds,
            factorMillisecondsPerTick = 100,
        )
        val atTolerance = StoredOuraRawHistoryRecord(
            archiveId = 1,
            tag = OuraEventTag.TEMP.raw,
            ringTimestamp = 46_000,
            payload = byteArrayOf(0x42, 0x0E),
            firstSeenAtUnixMs = receiptMilliseconds,
        )
        val tooFarFuture = atTolerance.copy(archiveId = 2, ringTimestamp = 50_000)

        assertTrue(
            OuraRawHistoryAnchorBackfillPolicy.canBackfill(
                atTolerance,
                anchor,
                receiptMilliseconds,
            ),
        )
        assertFalse(
            OuraRawHistoryAnchorBackfillPolicy.canBackfill(
                tooFarFuture,
                anchor,
                receiptMilliseconds,
            ),
        )
    }

    @Test
    fun forwardAssignmentKeepsEligiblePrefixBeforeOutOfCohortRowInSamePage() {
        val carrierSeenAtUnixMs = 1_800_000_000_000L
        val anchor = OuraTimeAnchor(
            ringTimestamp = 40_000,
            utcMilliseconds = carrierSeenAtUnixMs,
            factorMillisecondsPerTick = 100,
        )
        val separatelyInsertedLater = StoredOuraRawHistoryRecord(
            archiveId = 2,
            tag = OuraEventTag.TEMP.raw,
            ringTimestamp = 40_010,
            payload = byteArrayOf(0x42, 0x0E),
            firstSeenAtUnixMs = carrierSeenAtUnixMs + 2_000,
        )
        val outOfCohort = separatelyInsertedLater.copy(
            archiveId = 3,
            firstSeenAtUnixMs = carrierSeenAtUnixMs + 24 * 60 * 60 * 1_000L,
        )

        assertTrue(
            OuraRawHistoryAnchorBackfillPolicy.canBackfill(
                separatelyInsertedLater,
                anchor,
                carrierSeenAtUnixMs,
            ),
        )
        val forwardRange = OuraRawAnchorAdjacentRangeAccumulator(
            fromArchiveId = 2,
            throughArchiveId = 3,
            carrierArchiveId = 1,
            anchor = anchor,
            anchorCarrierFirstSeenAtUnixMs = carrierSeenAtUnixMs,
        )
        // Both rows are consumed together, matching one proposed assignment/page with pageSize >= 3.
        forwardRange.consume(listOf(separatelyInsertedLater, outOfCohort))
        assertEquals(
            OuraRawAnchorRange(2, 2),
            forwardRange.result(),
        )
        assertTrue(forwardRange.forwardPropagationBlocked)
        assertEquals(3L, forwardRange.forwardBarrierArchiveId)

        assertFalse(
            OuraRawHistoryAnchorBackfillPolicy.canBackfill(
                separatelyInsertedLater.copy(firstSeenAtUnixMs = Long.MIN_VALUE),
                anchor,
                Long.MAX_VALUE,
            ),
        )
    }

    @Test
    fun pageDecoderMapsTemperatureWithStoredAnchor() {
        val anchor = OuraTimeAnchor(
            ringTimestamp = 1_000L,
            utcMilliseconds = 1_700_000_000_000L,
            factorMillisecondsPerTick = 100L,
        )
        val row = StoredOuraRawHistoryRecord(
            archiveId = 1,
            tag = OuraEventTag.TEMP.raw,
            ringTimestamp = 900L,
            payload = byteArrayOf(0x42, 0x0E),
            firstSeenAtUnixMs = 1,
            timeAnchor = anchor,
        )

        val decoded = OuraRawHistoryPageDecoder.decode(listOf(row), OuraRingGen.GEN3)
        assertEquals(1, decoded.batch.skinTemp.size)
        assertEquals(1_699_999_990L, decoded.batch.skinTemp.single().ts)
        assertEquals(3_650, decoded.batch.skinTemp.single().raw)
        assertEquals(0, decoded.withheldEvents)
    }

    @Test
    fun pageDecoderMapsBedtimeBoundsAndWithholdsUnanchoredData() {
        val anchor = OuraTimeAnchor(
            ringTimestamp = 10_000L,
            utcMilliseconds = 1_700_000_000_000L,
            factorMillisecondsPerTick = 100L,
        )
        val bedtime = StoredOuraRawHistoryRecord(
            archiveId = 1,
            tag = OuraEventTag.BEDTIME_PERIOD.raw,
            ringTimestamp = 10_000L,
            payload = byteArrayOf(
                0xE8.toByte(), 0x03, 0x00, 0x00,
                0x10, 0x27, 0x00, 0x00,
            ),
            firstSeenAtUnixMs = 1,
            timeAnchor = anchor,
        )
        val temperatureWithoutAnchor = StoredOuraRawHistoryRecord(
            archiveId = 2,
            tag = OuraEventTag.TEMP.raw,
            ringTimestamp = 10_000L,
            payload = byteArrayOf(0x42, 0x0E),
            firstSeenAtUnixMs = 1,
        )

        val decoded = OuraRawHistoryPageDecoder.decode(
            listOf(bedtime, temperatureWithoutAnchor),
            OuraRingGen.GEN3,
        )
        assertEquals(1, decoded.sleepWindows.size)
        assertEquals(15L * 60L, decoded.sleepWindows.single().second - decoded.sleepWindows.single().first)
        assertEquals(1, decoded.withheldEvents)
        assertTrue(decoded.batch.isEmpty)
    }

    @Test
    fun pageDecoderReplaysCompleteSleepPhaseSeriesAtomically() {
        val anchor = OuraTimeAnchor(
            ringTimestamp = 1_000L,
            utcMilliseconds = 1_700_000_000_000L,
            factorMillisecondsPerTick = 100L,
        )
        val row = StoredOuraRawHistoryRecord(
            archiveId = 1,
            tag = OuraEventTag.SLEEP_PHASE.raw,
            ringTimestamp = 900L,
            payload = byteArrayOf(0x07, 0x1B),
            firstSeenAtUnixMs = 1,
            timeAnchor = anchor,
        )

        val decoded = OuraRawHistoryPageDecoder.decode(listOf(row), OuraRingGen.GEN3)
        assertEquals(0, decoded.withheldEvents)
        assertEquals(1, decoded.batch.events.size)
        val event = decoded.batch.events.single()
        assertEquals("OURA_SLEEP_PHASE_SERIES", event.kind)
        assertEquals(1_699_999_990L, event.ts)
        assertTrue(event.payloadJSON.contains("\"source_tag\":78"))
        assertTrue(event.payloadJSON.contains("\"header\":7"))
        assertTrue(event.payloadJSON.contains("\"phase_codes\":[0,1,2,3]"))
        assertTrue(!event.payloadJSON.contains("cadence_seconds"))
    }

    @Test
    fun pageDecoderRevisionEightRecoversMotionSpO2ActivityAndAlwaysOnHRDiagnostics() {
        assertEquals(8, OuraRawHistoryDecoderRevision.CURRENT)
        val anchor = OuraTimeAnchor(
            ringTimestamp = 1_000L,
            utcMilliseconds = 1_700_000_000_000L,
            factorMillisecondsPerTick = 100L,
        )
        val motion = StoredOuraRawHistoryRecord(
            archiveId = 1,
            tag = OuraEventTag.MOTION.raw,
            ringTimestamp = 900L,
            payload = byteArrayOf(
                0xB1.toByte(), 0x01, 0xFE.toByte(), 0x7F, 0x85.toByte(), 0x06,
            ),
            firstSeenAtUnixMs = 1,
            timeAnchor = anchor,
        )
        val sleepAcm = StoredOuraRawHistoryRecord(
            archiveId = 2,
            tag = OuraEventTag.SLEEP_ACM_PERIOD.raw,
            ringTimestamp = 700L,
            payload = byteArrayOf(
                0x80.toByte(), 0x02, 0x00, 0x03, 0xFF.toByte(), 0x04,
                0x00, 0x50, 0xFF.toByte(), 0x0F, 0x00, 0xA8.toByte(),
            ),
            firstSeenAtUnixMs = 1,
            timeAnchor = anchor,
        )
        val spo2 = StoredOuraRawHistoryRecord(
            archiveId = 3,
            tag = OuraEventTag.SPO2_RATIO_PI.raw,
            ringTimestamp = 800L,
            payload = byteArrayOf(0x00, 0x30, 0x00, 0x80.toByte(), 0x33, 0x33, 0x40),
            firstSeenAtUnixMs = 1,
            timeAnchor = anchor,
        )
        val activity = StoredOuraRawHistoryRecord(
            archiveId = 4,
            tag = OuraEventTag.ACTIVITY_INFO.raw,
            ringTimestamp = 600L,
            payload = byteArrayOf(0x41, 0x12, 0x13, 0x4A),
            firstSeenAtUnixMs = 1,
            timeAnchor = anchor,
        )
        val exerciseIntensity = StoredOuraRawHistoryRecord(
            archiveId = 5,
            tag = OuraEventTag.EXERCISE_HR_INTENSITY.raw,
            ringTimestamp = 500L,
            payload = byteArrayOf(0x34, 0x12, 0xFF.toByte(), 0x00),
            firstSeenAtUnixMs = 1,
            timeAnchor = anchor,
        )
        val realSteps = StoredOuraRawHistoryRecord(
            archiveId = 6,
            tag = OuraEventTag.REAL_STEPS_1.raw,
            ringTimestamp = 400L,
            payload = byteArrayOf(
                0x01, 0x02, 0x03, 0x84.toByte(), 0x05, 0x06, 0x07, 0x08,
                0x09, 0x0A, 0x0B, 0x8C.toByte(), 0x0D, 0x0E,
            ),
            firstSeenAtUnixMs = 1,
            timeAnchor = anchor,
        )
        val alwaysOnHR = StoredOuraRawHistoryRecord(
            archiveId = 7,
            tag = OuraEventTag.ALWAYS_ON_HR.raw,
            ringTimestamp = 300L,
            payload = byteArrayOf(0x81.toByte(), 0x05, 0x03, 60, 1, 61, 2, 62, 3),
            firstSeenAtUnixMs = 1,
            timeAnchor = anchor,
        )

        val decoded = OuraRawHistoryPageDecoder.decode(
            listOf(motion, sleepAcm, spo2, activity, exerciseIntensity, realSteps, alwaysOnHR), OuraRingGen.GEN4,
        )
        assertEquals(0, decoded.withheldEvents)
        assertEquals(
            listOf(
                OuraStreamMapping.EVENT_MOTION_SUMMARY,
                OuraStreamMapping.EVENT_SLEEP_ACM_PERIOD,
                OuraStreamMapping.EVENT_SPO2_RATIO_PI,
                OuraStreamMapping.EVENT_ACTIVITY_MET_SERIES,
                OuraStreamMapping.EVENT_EXERCISE_HR_INTENSITY,
                OuraStreamMapping.EVENT_REAL_STEPS_FEATURES,
                OuraStreamMapping.EVENT_ALWAYS_ON_HR_SERIES,
            ),
            decoded.batch.events.map { it.kind },
        )
        assertEquals(1_699_999_990L, decoded.batch.events[0].ts)
        assertEquals(1_699_999_970L, decoded.batch.events[1].ts)
        assertEquals(1_699_999_980L, decoded.batch.events[2].ts)
        assertEquals(1_699_999_960L, decoded.batch.events[3].ts)
        assertTrue(decoded.batch.events[3].payloadJSON.contains("\"met_x10\":[18,19,74]"))
        assertEquals(1_699_999_950L, decoded.batch.events[4].ts)
        assertTrue(decoded.batch.events[4].payloadJSON.contains("\"intensity_u16\":[4660,255]"))
        assertEquals(1_699_999_940L, decoded.batch.events[5].ts)
        assertTrue(decoded.batch.events[5].payloadJSON.contains(
            "\"feature_fields_u16\":[3,4,6,4,5,6,7,8,19,20,22,12,13,14]",
        ))
        assertEquals(1_699_999_930L, decoded.batch.events[6].ts)
        assertTrue(decoded.batch.events[6].payloadJSON.contains("\"bpm_u8\":[60,61,62]"))
        assertTrue(decoded.batch.events[6].payloadJSON.contains("\"quality_u8\":[1,2,3]"))
        assertEquals(1, decoded.batch.spo2.size)
        assertEquals(1_699_999_980L, decoded.batch.spo2.single().ts)
        assertEquals(932, decoded.batch.spo2.single().red)
        assertEquals(0, decoded.batch.spo2.single().ir)
        assertEquals(OuraStreamMapping.ESTIMATED_SPO2_UNIT, decoded.batch.spo2.single().unit)
    }
}
