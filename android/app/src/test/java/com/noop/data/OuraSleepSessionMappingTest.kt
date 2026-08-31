package com.noop.data

import com.noop.oura.OuraHypnogramEpoch
import com.noop.oura.OuraSleepStage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OuraSleepSessionMappingTest {
    @Test
    fun emptyOrInvalidEpochsDoNotCreateNight() {
        assertNull(OuraSleepSessionMapping.session(emptyList(), "ring"))
        assertNull(
            OuraSleepSessionMapping.session(
                listOf(OuraHypnogramEpoch(OuraSleepStage.DEEP, 100)),
                "ring",
                secondsPerEpoch = 0,
            ),
        )
    }

    @Test
    fun buildsByteStableMergedTimelineAndEfficiency() {
        val session = requireNotNull(
            OuraSleepSessionMapping.session(
                listOf(
                    OuraHypnogramEpoch(OuraSleepStage.DEEP, 1_000),
                    OuraHypnogramEpoch(OuraSleepStage.DEEP, 1_030),
                    OuraHypnogramEpoch(OuraSleepStage.LIGHT, 1_060),
                    OuraHypnogramEpoch(OuraSleepStage.REM, 1_090),
                    OuraHypnogramEpoch(OuraSleepStage.AWAKE, 1_120),
                    OuraHypnogramEpoch(OuraSleepStage.AWAKE, 1_150),
                ),
                "ring",
            ),
        )
        assertEquals(1_000, session.startTs)
        assertEquals(1_180, session.endTs)
        assertEquals(4.0 / 6.0, requireNotNull(session.efficiency), 0.000_001)
        assertEquals(
            "[{\"start\":1000,\"end\":1060,\"stage\":\"deep\"}," +
                "{\"start\":1060,\"end\":1090,\"stage\":\"light\"}," +
                "{\"start\":1090,\"end\":1120,\"stage\":\"rem\"}," +
                "{\"start\":1120,\"end\":1180,\"stage\":\"wake\"}]",
            session.stagesJSON,
        )
        assertEquals("ring", session.deviceId)
    }

    @Test
    fun pairingUsesClosestCandidateWithinTenMinutes() {
        val candidates = listOf(
            OuraSleepNetWindowCandidate(1_000, 10_000, 10, 20),
            OuraSleepNetWindowCandidate(1_500, 20_000, 30, 40),
        )
        assertEquals(
            candidates[1],
            OuraSleepNetWindowPairing.closest(1_450, 20_100, candidates),
        )
        assertNull(OuraSleepNetWindowPairing.closest(10_000, 20_100, candidates))
        // A ring-clock reset can reuse the same raw tick. Wall time prevents cross-session pairing.
        assertNull(OuraSleepNetWindowPairing.closest(1_500, 100_000, candidates))
        assertTrue(OuraSleepNetWindowPairing.TOLERANCE_TICKS == 6_000L)
        assertTrue(OuraSleepNetWindowPairing.TOLERANCE_SECONDS == 600L)
    }

    @Test
    fun validatedWindowOverridesSparseStageBounds() {
        val session = requireNotNull(
            OuraSleepSessionMapping.session(
                epochs = listOf(
                    OuraHypnogramEpoch(OuraSleepStage.LIGHT, 1_030),
                    OuraHypnogramEpoch(OuraSleepStage.REM, 1_060),
                ),
                deviceId = "ring",
                sessionStartUnixSeconds = 1_000,
                sessionEndUnixSeconds = 1_120,
            ),
        )
        assertEquals(1_000, session.startTs)
        assertEquals(1_120, session.endTs)
        assertNull(
            OuraSleepSessionMapping.session(
                epochs = listOf(OuraHypnogramEpoch(OuraSleepStage.LIGHT, 1_030)),
                deviceId = "ring",
                sessionStartUnixSeconds = 1_120,
                sessionEndUnixSeconds = 1_000,
            ),
        )
    }

    @Test
    fun structuralCompletenessIsSeparateFromObservedCoverage() {
        assertEquals(1_020, OuraSleepNetPersistencePolicy.stableStartUnixSeconds(1_000))
        val nineteenEpochs = (0 until 19).map {
            OuraHypnogramEpoch(OuraSleepStage.LIGHT, 1_020 + it * 30L)
        }
        assertTrue(
            OuraSleepNetPersistencePolicy.hasCompleteObservedCoverage(
                epochs = nineteenEpochs,
                startUnixSeconds = 1_020,
                endUnixSeconds = 1_620,
            ),
        )
        assertTrue(
            !OuraSleepNetPersistencePolicy.structurallySpansWindow(
                totalCodeSlots = 19,
                startUnixSeconds = 1_020,
                endUnixSeconds = 1_620,
            ),
        )
        assertTrue(
            OuraSleepNetPersistencePolicy.structurallySpansWindow(
                totalCodeSlots = 20,
                startUnixSeconds = 1_020,
                endUnixSeconds = 1_620,
            ),
        )
        assertEquals(
            19L * 30L,
            OuraSleepNetPersistencePolicy.coveredSeconds(nineteenEpochs + nineteenEpochs.first()),
        )
    }

    @Test
    fun incompleteObservedCoveragePersistsHonestGapsWithoutEfficiency() {
        val sparseEpochs = listOf(
            OuraHypnogramEpoch(OuraSleepStage.DEEP, 1_020),
            OuraHypnogramEpoch(OuraSleepStage.REM, 1_320),
        )
        assertTrue(
            !OuraSleepNetPersistencePolicy.hasCompleteObservedCoverage(
                epochs = sparseEpochs,
                startUnixSeconds = 1_020,
                endUnixSeconds = 1_620,
            ),
        )
        val session = requireNotNull(
            OuraSleepSessionMapping.session(
                epochs = sparseEpochs,
                deviceId = "ring",
                sessionStartUnixSeconds = 1_020,
                sessionEndUnixSeconds = 1_620,
                includeEfficiency = false,
            ),
        )
        assertEquals(1_020, session.startTs)
        assertEquals(1_620, session.endTs)
        assertNull(session.efficiency)
        assertEquals(
            "[{\"start\":1020,\"end\":1050,\"stage\":\"deep\"}," +
                "{\"start\":1320,\"end\":1350,\"stage\":\"rem\"}]",
            session.stagesJSON,
        )
    }
}
