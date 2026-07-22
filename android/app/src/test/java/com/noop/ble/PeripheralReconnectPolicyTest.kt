package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PeripheralReconnectPolicyTest {
    @Test
    fun reconnectRequiresUnintentionalDropAndRememberedTarget() {
        assertTrue(PeripheralReconnectPolicy.shouldReconnect(false, true))
        assertFalse(PeripheralReconnectPolicy.shouldReconnect(true, true))
        assertFalse(PeripheralReconnectPolicy.shouldReconnect(false, false))
        assertFalse(PeripheralReconnectPolicy.shouldReconnect(true, false))
    }

    @Test
    fun delayUsesCappedExponentialSchedule() {
        assertEquals(
            listOf(3_000L, 6_000L, 12_000L, 24_000L, 48_000L, 60_000L, 60_000L, 60_000L),
            (1..8).map(PeripheralReconnectPolicy::delayMs),
        )
        assertEquals(3_000L, PeripheralReconnectPolicy.delayMs(0))
        assertEquals(60_000L, PeripheralReconnectPolicy.delayMs(Int.MAX_VALUE))
    }
}
