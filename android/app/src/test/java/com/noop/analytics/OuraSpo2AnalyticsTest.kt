package com.noop.analytics

import com.noop.data.Spo2Sample
import com.noop.data.OuraStreamMapping
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OuraSpo2AnalyticsTest {
    @Test
    fun qualifiedPercentagesUseVerifiedBedtimeWindowAndRawRowsStayOut() {
        val start = 1_623_700_000L
        val result = AnalyticsEngine.analyzeDay(
            day = "2021-06-15",
            spo2 = listOf(
                Spo2Sample("ring", start + 60, 970, 0, "tenths_percent"),
                Spo2Sample("ring", start + 120, 950, 0, "tenths_percent"),
                Spo2Sample("ring", start + 180, 12_000, 8_000, "raw_adc"),
            ),
            knownSleepWindows = listOf(start to start + 3600),
            profile = UserProfile(age = 30.0),
        )
        assertEquals(96.0, result.daily.spo2Pct ?: Double.NaN, 0.0001)
        assertNull(result.daily.spo2Method)
    }

    @Test
    fun qualifiedOuraSimpleEstimateIsLabelledAndNativePercentageWins() {
        val start = 1_623_700_000L
        val estimates = (0..60).map {
            Spo2Sample(
                "ring",
                start + it * 30,
                if (it % 2 == 0) 970 else 960,
                0,
                OuraStreamMapping.ESTIMATED_SPO2_UNIT,
            )
        }
        val estimated = AnalyticsEngine.analyzeDay(
            day = "2021-06-15",
            spo2 = estimates,
            knownSleepWindows = listOf(start to start + 3600),
            profile = UserProfile(age = 30.0),
        )
        assertEquals(96.50819672131148, estimated.daily.spo2Pct ?: Double.NaN, 0.0001)
        assertEquals("oura_simple_gen4", estimated.daily.spo2Method)

        val native = AnalyticsEngine.analyzeDay(
            day = "2021-06-15",
            spo2 = estimates + Spo2Sample("ring", start + 120, 980, 0, "tenths_percent"),
            knownSleepWindows = listOf(start to start + 3600),
            profile = UserProfile(age = 30.0),
        )
        assertEquals(98.0, native.daily.spo2Pct ?: Double.NaN, 0.0001)
        assertNull(native.daily.spo2Method)
    }

    @Test
    fun ouraSimpleEstimateRejectsSparseOrShortFragments() {
        val start = 1_623_700_000L
        val short = (0 until 60).map {
            Spo2Sample("ring", start + it * 20, 970, 0, OuraStreamMapping.ESTIMATED_SPO2_UNIT)
        }
        val sparse = (0 until 60).map {
            Spo2Sample("ring", start + it * 31, 970, 0, OuraStreamMapping.ESTIMATED_SPO2_UNIT)
        }
        listOf(short, sparse).forEach { samples ->
            val result = AnalyticsEngine.analyzeDay(
                day = "2021-06-15",
                spo2 = samples,
                knownSleepWindows = listOf(start to start + 3600),
                profile = UserProfile(age = 30.0),
            )
            assertNull(result.daily.spo2Pct)
            assertNull(result.daily.spo2Method)
        }
    }
}
