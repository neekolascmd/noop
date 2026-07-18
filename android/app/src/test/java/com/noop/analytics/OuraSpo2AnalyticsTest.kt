package com.noop.analytics

import com.noop.data.Spo2Sample
import org.junit.Assert.assertEquals
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
    }
}
