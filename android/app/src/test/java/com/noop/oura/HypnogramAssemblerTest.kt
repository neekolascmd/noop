package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HypnogramAssemblerTest {
    private val fourStages = listOf(
        OuraSleepStage.AWAKE,
        OuraSleepStage.LIGHT,
        OuraSleepStage.DEEP,
        OuraSleepStage.REM,
    )

    private fun fourCodeBurst(): OuraHypnogramBurst {
        val assembler = OuraHypnogramAssembler()
        assembler.feed(ringTimestamp = 1_000, stages = fourStages)
        return assembler.flush()!!
    }

    @Test
    fun codesLayBackwardAtThirtySecondEpochs() {
        val epochs = fourCodeBurst().codesWithTimes(endUnixSeconds = 10_000)
        assertEquals(listOf(9_880L, 9_910L, 9_940L, 9_970L), epochs.map { it.startUnixSeconds })
        assertEquals(fourStages, epochs.map { it.stage })
        assertEquals(10_000L, epochs.last().startUnixSeconds + OURA_SLEEPNET_EPOCH_SECONDS)
    }

    @Test
    fun unwrittenMiddleSlotsAreOmittedWithoutCollapsingTheTimeAxis() {
        val burst = OuraHypnogramBurst(
            records = listOf(
                OuraHypnogramRecord(
                    ringTimestamp = 1_000,
                    stages = fourStages,
                ),
                OuraHypnogramRecord(
                    ringTimestamp = 1_001,
                    stages = List(4) { OuraSleepStage.AWAKE },
                    unwritten = List(4) { true },
                ),
                OuraHypnogramRecord(
                    ringTimestamp = 1_002,
                    stages = listOf(
                        OuraSleepStage.LIGHT,
                        OuraSleepStage.DEEP,
                        OuraSleepStage.REM,
                        OuraSleepStage.LIGHT,
                    ),
                ),
            ),
        )

        val epochs = burst.codesWithTimes(endUnixSeconds = 10_000)
        assertEquals(12, burst.totalCodes)
        assertEquals(8, epochs.size)
        assertEquals(
            listOf(9_640L, 9_670L, 9_700L, 9_730L),
            epochs.take(4).map { it.startUnixSeconds },
        )
        assertEquals(
            listOf(9_880L, 9_910L, 9_940L, 9_970L),
            epochs.takeLast(4).map { it.startUnixSeconds },
        )
    }

    @Test
    fun allUnwrittenBurstProducesNoHypnogram() {
        val burst = OuraHypnogramBurst(
            records = listOf(
                OuraHypnogramRecord(
                    ringTimestamp = 1_000,
                    stages = List(8) { OuraSleepStage.AWAKE },
                    unwritten = List(8) { true },
                ),
            ),
        )
        assertEquals(8, burst.totalCodes)
        assertTrue(burst.codesWithTimes(endUnixSeconds = 10_000).isEmpty())
        assertTrue(
            burst.codesWithTimes(
                endUnixSeconds = 10_000,
                sleepStartUnixSeconds = 9_000,
            ).isEmpty(),
        )
    }

    @Test
    fun startClampDropsOnlyLeadingEpochsAndNeverEmptiesNight() {
        val burst = fourCodeBurst()
        val clipped = burst.codesWithTimes(
            endUnixSeconds = 10_000,
            sleepStartUnixSeconds = 9_910,
        )
        assertEquals(listOf(9_910L, 9_940L, 9_970L), clipped.map { it.startUnixSeconds })
        assertEquals(
            listOf(OuraSleepStage.LIGHT, OuraSleepStage.DEEP, OuraSleepStage.REM),
            clipped.map { it.stage },
        )

        val impossibleClamp = burst.codesWithTimes(
            endUnixSeconds = 10_000,
            sleepStartUnixSeconds = 99_999,
        )
        assertEquals(4, impossibleClamp.size)
        assertEquals(9_880L, impossibleClamp.first().startUnixSeconds)
    }

    @Test
    fun recordsWithinSixHundredTicksRemainOneArrivalOrderedBurst() {
        val assembler = OuraHypnogramAssembler()
        assertNull(
            assembler.feed(
                ringTimestamp = 5_010,
                stages = listOf(OuraSleepStage.LIGHT, OuraSleepStage.DEEP),
                envelopeUnixSeconds = 100_001,
            ),
        )
        assertNull(
            assembler.feed(
                ringTimestamp = 5_000,
                stages = listOf(OuraSleepStage.REM, OuraSleepStage.AWAKE),
                envelopeUnixSeconds = 100_002,
            ),
        )
        val burst = assembler.flush()!!
        assertEquals(4, burst.totalCodes)
        assertEquals(5_000L, burst.lastRingTimestamp)
        assertEquals(100_002L, burst.lastEnvelopeUnixSeconds)
        assertTrue(burst.hasNonMonotonicRingTimes)
        assertEquals(
            listOf(
                OuraSleepStage.LIGHT,
                OuraSleepStage.DEEP,
                OuraSleepStage.REM,
                OuraSleepStage.AWAKE,
            ),
            burst.codesWithTimes(endUnixSeconds = 1_000).map { it.stage },
        )
    }

    @Test
    fun aGapOverSixHundredTicksSplitsBurstsButBoundaryDoesNot() {
        val assembler = OuraHypnogramAssembler()
        assertNull(assembler.feed(1_000, listOf(OuraSleepStage.LIGHT)))
        assertNull(assembler.feed(1_600, listOf(OuraSleepStage.REM)))
        val first = assembler.feed(2_201, listOf(OuraSleepStage.DEEP))
        assertNotNull(first)
        assertEquals(2, first!!.totalCodes)
        assertFalse(first.hasNonMonotonicRingTimes)
        assertEquals(listOf(OuraSleepStage.DEEP), assembler.flush()!!.records.single().stages)
    }

    @Test
    fun sameRingTickFromDifferentWallClockNightsSplitsBursts() {
        val assembler = OuraHypnogramAssembler()
        assertNull(
            assembler.feed(
                ringTimestamp = 5_000,
                stages = listOf(OuraSleepStage.LIGHT),
                envelopeUnixSeconds = 100_000,
            ),
        )
        val first = assembler.feed(
            ringTimestamp = 5_000,
            stages = listOf(OuraSleepStage.REM),
            envelopeUnixSeconds = 200_000,
        )
        assertEquals(listOf(OuraSleepStage.LIGHT), first!!.records.single().stages)
        assertEquals(listOf(OuraSleepStage.REM), assembler.flush()!!.records.single().stages)
    }

    @Test
    fun changingEnvelopeAnchorAvailabilitySplitsInBothDirections() {
        val assembler = OuraHypnogramAssembler()
        assertNull(assembler.feed(1_000, listOf(OuraSleepStage.LIGHT), 100_000))

        val anchored = assembler.feed(1_001, listOf(OuraSleepStage.DEEP), null)
        assertEquals(listOf(OuraSleepStage.LIGHT), anchored!!.records.single().stages)

        val unanchored = assembler.feed(1_002, listOf(OuraSleepStage.REM), 100_001)
        assertEquals(listOf(OuraSleepStage.DEEP), unanchored!!.records.single().stages)
        assertEquals(listOf(OuraSleepStage.REM), assembler.flush()!!.records.single().stages)
    }

    @Test
    fun seriesFeedCarriesOptionalEnvelopeAnchorAndResetDropsPartialState() {
        val assembler = OuraHypnogramAssembler()
        val series = OuraSleepPhaseSeries(
            ringTimestamp = 42,
            sourceTag = OuraEventTag.SLEEP_PHASE.raw,
            header = 0,
            stages = listOf(OuraSleepStage.REM),
        )
        assertNull(assembler.feed(series, envelopeUnixSeconds = 1_700_000_000))
        assertEquals(1, assembler.pendingRecordCount)
        assertEquals(1_700_000_000L, assembler.flush()!!.lastEnvelopeUnixSeconds)
        assertNull(assembler.flush())

        assembler.feed(series)
        assembler.reset()
        assertEquals(0, assembler.pendingRecordCount)
        assertNull(assembler.flush())
    }

    @Test
    fun fullNightScaleProducesUniqueThirtySecondSlots() {
        val assembler = OuraHypnogramAssembler()
        repeat(23) { index ->
            assembler.feed(
                ringTimestamp = 3_970_000L + index,
                stages = List(52) { OuraSleepStage.LIGHT },
            )
        }
        val burst = assembler.flush()!!
        assertEquals(1_196, burst.totalCodes)
        val end = 1_760_000_000L
        val epochs = burst.codesWithTimes(endUnixSeconds = end)
        assertEquals(end - 1_196 * 30L, epochs.first().startUnixSeconds)
        assertEquals(1_196, epochs.size)
        assertTrue(
            epochs.zipWithNext().all { (first, second) ->
                second.startUnixSeconds - first.startUnixSeconds == OURA_SLEEPNET_EPOCH_SECONDS
            },
        )
    }
}
