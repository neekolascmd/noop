package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OuraTimeAnchorMappingTest {
    @Test
    fun gen3SecondsBecomeMillisecondsExactlyOnce() {
        val anchor = OuraTimeAnchorMapping.anchor(
            OuraTimeSync(
                ringTimestamp = 10_000L,
                epochMs = 1_719_662_400L,
                tzOffsetSeconds = 3_600,
            ),
        )
        assertEquals(
            OuraTimeAnchor(
                ringTimestamp = 10_000L,
                utcMilliseconds = 1_719_662_400_000L,
                factorMillisecondsPerTick = 100L,
            ),
            anchor,
        )
        assertEquals(
            1_719_662_390L,
            anchor?.let { OuraTimeAnchorMapping.unixSeconds(9_900L, it) },
        )
    }

    @Test
    fun ring4BurstFactorIsPreserved() {
        val anchor = OuraTimeAnchorMapping.anchor(
            OuraTimeSync(
                ringTimestamp = 20_000L,
                epochMs = 1_700_000_000L,
                tzOffsetSeconds = 0,
                factorMsPerTick = 1,
                token = 0xFD,
            ),
        )
        assertEquals(1L, anchor?.factorMillisecondsPerTick)
        assertEquals(
            1_700_000_001L,
            anchor?.let { OuraTimeAnchorMapping.unixSeconds(21_000L, it) },
        )
    }

    @Test
    fun rtcBeaconBuildsNormalClockAnchor() {
        val anchor = OuraTimeAnchorMapping.anchor(
            OuraRtcBeacon(ringTimestamp = 1_000L, unixSeconds = 1_700_000_000L),
        )
        assertEquals(100L, anchor?.factorMillisecondsPerTick)
        assertEquals(1_700_000_000_000L, anchor?.utcMilliseconds)
    }

    @Test
    fun implausibleAndOverflowingMappingsAreRejected() {
        assertNull(
            OuraTimeAnchorMapping.anchor(
                OuraTimeSync(
                    ringTimestamp = 1L,
                    epochMs = Long.MAX_VALUE,
                    tzOffsetSeconds = 0,
                ),
            ),
        )
        assertNull(
            OuraTimeAnchorMapping.unixSeconds(
                0xFFFF_FFFFL,
                OuraTimeAnchor(
                    ringTimestamp = 1L,
                    utcMilliseconds = Long.MAX_VALUE,
                    factorMillisecondsPerTick = 100L,
                ),
            ),
        )
    }
}
