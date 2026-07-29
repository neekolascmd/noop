package com.noop.data

import com.noop.oura.OuraEventTag
import com.noop.oura.OuraRingGen
import com.noop.oura.OuraTimeAnchor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OuraRawHistoryRedecoderTest {
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
}
