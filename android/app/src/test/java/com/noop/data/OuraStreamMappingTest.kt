package com.noop.data

import com.noop.oura.OuraEvent
import com.noop.oura.OuraHR
import com.noop.oura.OuraHRV
import com.noop.oura.OuraIBI
import com.noop.oura.OuraMotionSummary
import com.noop.oura.OuraSleepAcmPeriod
import com.noop.oura.OuraSleepPhaseSeries
import com.noop.oura.OuraSleepStage
import com.noop.oura.OuraSpO2
import com.noop.oura.OuraSpO2CalibrationProfile
import com.noop.oura.OuraSpO2RatioRecord
import com.noop.oura.OuraSpO2RatioSample
import com.noop.oura.OuraTemp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM tests for [OuraStreamMapping], the pure fold of decoded Oura events onto the protocol Streams
 * shape (section-4 of the Oura local-BLE architecture plan). These pin the exact event kinds and
 * payload keys the Swift twin must match, the honest-data invariants (no fabricated channels, no
 * faked timestamps), and the SpO2/skinTemp widening onto the store.
 *
 * The anchor maps a ring-clock value to wall-clock unix seconds; tests use a trivial linear anchor so
 * the mapping logic (not a clock model) is what is under test.
 */
class OuraStreamMappingTest {

    /** Ring-clock 0 -> a fixed wall-clock base; +1 ring tick == +1 second. */
    private val base = 1_750_000_000
    private val anchor: (Long) -> Int? = { rt -> base + rt.toInt() }

    @Test
    fun hrAndIbiMapToHrAndRr() {
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.Hr(OuraHR(ringTimestamp = 10, bpm = 72, ibiMs = 833)),
                OuraEvent.Ibi(OuraIBI(ringTimestamp = 10, ibiMs = 833)),
                OuraEvent.Ibi(OuraIBI(ringTimestamp = 11, ibiMs = 820)),
            ),
            anchor,
        )
        assertEquals(listOf(72), s.hr.map { it.bpm })
        assertEquals(listOf(base + 10), s.hr.map { it.ts })
        assertEquals(listOf(833, 820), s.rr.map { it.rrMs })
        assertEquals(listOf(base + 10, base + 11), s.rr.map { it.ts })
    }

    @Test
    fun hrvBecomesOuraHrvEventWithRawFieldsNotRmssd() {
        val s = OuraStreamMapping.streams(
            listOf(OuraEvent.Hrv(OuraHRV(ringTimestamp = 5, timeMs = 1000, b1 = 7, b2 = -3))),
            anchor,
        )
        assertEquals(1, s.events.size)
        val ev = s.events.first()
        assertEquals(OuraStreamMapping.EVENT_HRV, ev.kind)
        assertEquals("OURA_HRV", ev.kind)
        assertEquals(base + 5, ev.ts)
        // HONEST: the ring's OWN raw tag fields only; NEVER a fabricated rmssd_ms.
        assertEquals(1000, ev.payload["time_ms"])
        assertEquals(7, ev.payload["b1"])
        assertEquals(-3, ev.payload["b2"])
        assertTrue("must not fabricate rmssd_ms", !ev.payload.containsKey("rmssd_ms"))
    }

    @Test
    fun sleepPhaseBecomesOneAtomicSeriesWithoutInventingCadence() {
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.SleepPhaseEvent(
                    OuraSleepPhaseSeries(
                        ringTimestamp = 2,
                        sourceTag = 0x4E,
                        header = 7,
                        stages = listOf(
                            OuraSleepStage.DEEP,
                            OuraSleepStage.LIGHT,
                            OuraSleepStage.REM,
                            OuraSleepStage.AWAKE,
                        ),
                    ),
                ),
            ),
            anchor,
        )
        assertEquals(1, s.events.size)
        val series = s.events.single()
        assertEquals(OuraStreamMapping.EVENT_SLEEP_PHASE, series.kind)
        assertEquals("OURA_SLEEP_PHASE_SERIES", series.kind)
        assertEquals(0x4E, series.payload["source_tag"])
        assertEquals(7, series.payload["header"])
        assertEquals(2L, series.payload["ring_timestamp"])
        assertEquals(listOf(0, 1, 2, 3), series.payload["phase_codes"])
        assertEquals("0=deep,1=light,2=rem,3=awake", series.payload["codebook"])
        assertNull(series.payload["cadence_seconds"])
    }

    @Test
    fun spo2UsesQualifiedPercentageAndDropsRawDc() {
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.Spo2(
                    OuraSpO2(ringTimestamp = 1, value = 97, unit = "percent", sampleOffsetSeconds = -1),
                ),
                OuraEvent.Spo2(OuraSpO2(ringTimestamp = 1, value = 12345, unit = "dc_raw")),
            ),
            anchor,
        )
        assertEquals(1, s.spo2.size)
        assertEquals(970, s.spo2.first().red)
        assertEquals(0, s.spo2.first().ir) // unread channel, never a fabricated second reading
        assertEquals("tenths_percent", s.spo2.first().unit)
        assertEquals(base, s.spo2.first().ts)
    }

    @Test
    fun spo2RatioPreservesRawRecordAndLabelsDerivedEstimate() {
        val raw = OuraSpO2RatioRecord(5, 0xA5, listOf(
            OuraSpO2RatioSample(0x3000, 128), OuraSpO2RatioSample(0x3333, 64),
        ))
        val s = OuraStreamMapping.streams(
            listOf(OuraEvent.Spo2Ratio(raw, OuraSpO2CalibrationProfile.GEN4_OREO)), anchor,
        )
        assertEquals(1, s.spo2.size)
        assertEquals(base + 5, s.spo2.single().ts)
        assertEquals(932, s.spo2.single().red)
        assertEquals(0, s.spo2.single().ir)
        assertEquals(OuraStreamMapping.ESTIMATED_SPO2_UNIT, s.spo2.single().unit)
        assertEquals(OuraStreamMapping.EVENT_SPO2_RATIO_PI, s.events.single().kind)
        assertEquals(listOf(0x3000, 0x3333), s.events.single().payload["ratio_q14"])
        assertEquals(listOf(128, 64), s.events.single().payload["perfusion_u8"])
        assertEquals("gen4_oreo", s.events.single().payload["calibration_profile"])
        assertEquals(listOf(0, 1), s.events.single().payload["calibrated_sample_indices"])
        assertEquals(listOf(938, 925), s.events.single().payload["calibrated_tenths_percent_samples"])

        val uncalibrated = OuraStreamMapping.streams(listOf(OuraEvent.Spo2Ratio(raw, null)), anchor)
        assertTrue(uncalibrated.spo2.isEmpty())
        assertEquals("none", uncalibrated.events.single().payload["calibration_profile"])
    }

    @Test
    fun tempPersistsAsHundredthsOfDegree() {
        val s = OuraStreamMapping.streams(
            listOf(OuraEvent.Temp(OuraTemp(ringTimestamp = 4, celsius = 33.27))),
            anchor,
        )
        assertEquals(1, s.skinTemp.size)
        assertEquals(3327, s.skinTemp.first().raw)
        assertEquals(base + 4, s.skinTemp.first().ts)
    }

    @Test
    fun motionDiagnosticsPersistExactUnitsNeutralFields() {
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.MotionSummaryEvent(
                    OuraMotionSummary(
                        10, 5, 17, 8, -16, 1016,
                        lowIntensity = 5, lowIntensityFlag = true,
                        highIntensity = 6, highIntensityFlag = false,
                    ),
                ),
                OuraEvent.SleepAcmPeriodEvent(
                    OuraSleepAcmPeriod(11, listOf(2.5, 3.0, 5.0, 5.0, 1.0, 10.5)),
                ),
            ),
            anchor,
        )
        assertEquals(
            listOf(OuraStreamMapping.EVENT_MOTION_SUMMARY, OuraStreamMapping.EVENT_SLEEP_ACM_PERIOD),
            s.events.map { it.kind },
        )
        assertEquals(5, s.events[0].payload["orientation"])
        assertEquals(17, s.events[0].payload["motion_seconds"])
        assertEquals(-16, s.events[0].payload["average_y_x8"])
        assertEquals("raw_x8", s.events[0].payload["axis_unit"])
        assertEquals(true, s.events[0].payload["low_intensity_flag"])
        assertEquals(2.5, s.events[1].payload["mad_0"])
        assertEquals(10.5, s.events[1].payload["mad_5"])
        assertEquals("fixed_point_raw", s.events[1].payload["unit"])
        assertTrue(s.hr.isEmpty())
        assertTrue(s.rr.isEmpty())
    }

    @Test
    fun unanchoredSamplesAreDroppedNotFaked() {
        // anchor returns null for ring time 99 -> that sample must be dropped, others kept.
        val partial: (Long) -> Int? = { rt -> if (rt == 99L) null else base + rt.toInt() }
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.Hr(OuraHR(ringTimestamp = 99, bpm = 60, ibiMs = 1000)),
                OuraEvent.Hr(OuraHR(ringTimestamp = 1, bpm = 61, ibiMs = 980)),
            ),
            partial,
        )
        assertEquals(listOf(61), s.hr.map { it.bpm })
    }

    @Test
    fun batteryIsNotPersistedAsAStreamRow() {
        // Battery has no ring timestamp; it flows via the live onBattery path, never a faked-ts row.
        val s = OuraStreamMapping.streams(
            listOf(OuraEvent.Battery(com.noop.oura.OuraBattery(percent = 88))),
            anchor,
        )
        assertTrue(s.battery.isEmpty())
        assertTrue(s.hr.isEmpty())
    }

    @Test
    fun tierBNeverMapsToAStream() {
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.TierB(
                    com.noop.oura.OuraTierBSummary(
                        tag = 0x7E, ringTimestamp = 100, rawPayload = intArrayOf(1, 2, 3),
                        kind = "real_steps",
                    ),
                ),
            ),
            anchor,
        )
        assertTrue(s.hr.isEmpty())
        assertTrue(s.rr.isEmpty())
        assertTrue(s.events.isEmpty())
        assertTrue(s.battery.isEmpty())
        assertTrue(s.spo2.isEmpty())
        assertTrue(s.skinTemp.isEmpty())
    }

    @Test
    fun activityMetSeriesIsRetainedAtomicallyWithoutInventingActivityMetrics() {
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.ActivityInfo(
                    com.noop.oura.OuraActivityInfo(
                        ringTimestamp = 100,
                        state = 0x41,
                        met = listOf(1.8, 1.9, 7.4),
                    ),
                ),
            ),
            anchor,
        )
        assertEquals(1, s.events.size)
        val event = s.events.single()
        assertEquals(OuraStreamMapping.EVENT_ACTIVITY_MET_SERIES, event.kind)
        assertEquals(base + 100, event.ts)
        assertEquals(100L, event.payload["ring_timestamp"])
        assertEquals(0x41, event.payload["state_raw"])
        assertEquals(listOf(18, 19, 74), event.payload["met_x10"])
        assertEquals(60, event.payload["sample_interval_seconds"])
        assertEquals("wire_order", event.payload["sequence_order"])
        assertEquals("record_anchor_only", event.payload["timestamp_semantics"])
        assertEquals("tenths_met", event.payload["unit"])
        assertTrue(s.hr.isEmpty())
        assertTrue(s.rr.isEmpty())
        assertTrue(s.battery.isEmpty())
        assertTrue(s.spo2.isEmpty())
        assertTrue(s.skinTemp.isEmpty())
    }

    @Test
    fun activityFeatureDiagnosticsAreRetainedWithoutMintingBiometricStreams() {
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.ExerciseHRIntensity(
                    com.noop.oura.OuraExerciseHRIntensity(101, listOf(0x1234, 0x00FF)),
                ),
                OuraEvent.AlwaysOnHR(
                    com.noop.oura.OuraAlwaysOnHRSeries(
                        102, 1, 5, bpm = listOf(60, 61, 62), quality = listOf(1, 2, 3),
                    ),
                ),
                OuraEvent.RealStepsFeatures(
                    com.noop.oura.OuraRealStepsFeatures(
                        103, 0x7E, listOf(3, 4, 6, 4, 5, 6, 7, 8, 19, 20, 22, 12, 13, 14),
                    ),
                ),
            ),
            anchor,
        )
        assertEquals(
            listOf(
                OuraStreamMapping.EVENT_EXERCISE_HR_INTENSITY,
                OuraStreamMapping.EVENT_ALWAYS_ON_HR_SERIES,
                OuraStreamMapping.EVENT_REAL_STEPS_FEATURES,
            ),
            s.events.map { it.kind },
        )
        assertEquals(listOf(0x1234, 0x00FF), s.events[0].payload["intensity_u16"])
        assertEquals("unvalidated", s.events[0].payload["field_semantics"])
        assertEquals(listOf(60, 61, 62), s.events[1].payload["bpm_u8"])
        assertEquals(listOf(1, 2, 3), s.events[1].payload["quality_u8"])
        assertEquals(1_920, s.events[1].payload["interval_ms"])
        assertEquals("unvalidated", s.events[1].payload["field_semantics"])
        assertEquals(0x7E, s.events[2].payload["source_tag"])
        assertEquals(
            listOf(3, 4, 6, 4, 5, 6, 7, 8, 19, 20, 22, 12, 13, 14),
            s.events[2].payload["feature_fields_u16"],
        )
        assertEquals("stateful_unknown", s.events[2].payload["part_relationship"])
        assertTrue(s.hr.isEmpty())
        assertTrue(s.rr.isEmpty())
    }
}
