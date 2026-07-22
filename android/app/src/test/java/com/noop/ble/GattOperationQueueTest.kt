package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GattOperationQueueTest {
    @Test
    fun `operations wait for the preceding callback and preserve order`() {
        val queue = GattOperationQueue<String>(maxStartRetries = 2)
        queue.enqueue("heart-rate notify")
        queue.enqueue("battery read")
        queue.enqueue("cadence notify")

        assertEquals("heart-rate notify", queue.beginNext())
        assertNull("a second operation must not start while one is active", queue.beginNext())
        assertEquals("heart-rate notify", queue.completeIf { it == "heart-rate notify" })
        assertEquals("battery read", queue.beginNext())
        assertEquals("battery read", queue.completeIf { it == "battery read" })
        assertEquals("cadence notify", queue.beginNext())
        assertEquals("cadence notify", queue.completeIf { it == "cadence notify" })
        assertTrue(queue.isIdle)
    }

    @Test
    fun `mismatched late callback cannot advance the active operation`() {
        val queue = GattOperationQueue<String>(maxStartRetries = 1)
        queue.enqueue("battery read")
        queue.enqueue("power notify")

        assertEquals("battery read", queue.beginNext())
        assertNull(queue.completeIf { it == "heart-rate notify" })
        assertEquals("battery read", queue.current)
        assertNull(queue.beginNext())
        assertEquals("battery read", queue.completeIf { it == "battery read" })
        assertEquals("power notify", queue.beginNext())
    }

    @Test
    fun `rejected start retries the same operation before later work`() {
        val queue = GattOperationQueue<String>(maxStartRetries = 2)
        queue.enqueue("heart-rate notify")
        queue.enqueue("battery read")

        assertEquals("heart-rate notify", queue.beginNext())
        val first = queue.rejectCurrentStart()!!
        assertEquals("heart-rate notify", first.operation)
        assertEquals(1, first.rejectionNumber)
        assertTrue(first.willRetry)
        assertEquals("heart-rate notify", queue.beginNext())

        val second = queue.rejectCurrentStart()!!
        assertEquals(2, second.rejectionNumber)
        assertTrue(second.willRetry)
        assertEquals("heart-rate notify", queue.beginNext())

        val exhausted = queue.rejectCurrentStart()!!
        assertEquals(3, exhausted.rejectionNumber)
        assertFalse(exhausted.willRetry)
        assertEquals("battery read", queue.beginNext())
    }

    @Test
    fun `timeout and clear release all queue state`() {
        val queue = GattOperationQueue<String>(maxStartRetries = 1)
        queue.enqueue("heart-rate notify")
        queue.enqueue("battery read")
        assertEquals("heart-rate notify", queue.beginNext())

        assertEquals("heart-rate notify", queue.timeoutCurrent())
        assertEquals("battery read", queue.beginNext())
        queue.clear()

        assertNull(queue.current)
        assertEquals(0, queue.pendingCount)
        assertTrue(queue.isIdle)
        assertNull(queue.beginNext())
    }

    @Test
    fun `required failure reconnects while optional telemetry preserves live heart rate`() {
        assertEquals(
            GattOperationFailureAction.RECONNECT,
            gattOperationFailureAction(requiredForPrimaryStream = true),
        )
        assertEquals(
            GattOperationFailureAction.SKIP_OPTIONAL,
            gattOperationFailureAction(requiredForPrimaryStream = false),
        )
    }

    @Test
    fun `any-of subscription setup needs one successful primary stream`() {
        assertEquals(
            PrimarySubscriptionSetupOutcome.UNSUPPORTED,
            primarySubscriptionSetupOutcome(candidateCount = 0, enabledCount = 0),
        )
        assertEquals(
            PrimarySubscriptionSetupOutcome.RETRY,
            primarySubscriptionSetupOutcome(candidateCount = 2, enabledCount = 0),
        )
        assertEquals(
            PrimarySubscriptionSetupOutcome.READY,
            primarySubscriptionSetupOutcome(candidateCount = 2, enabledCount = 1),
        )
    }

    @Test
    fun `single-stream setup separates transport retry from an unavailable characteristic`() {
        assertEquals(
            SingleSubscriptionSetupOutcome.READY,
            singleSubscriptionSetupOutcome(candidateFound = true, enabled = true, transportFailure = false),
        )
        assertEquals(
            SingleSubscriptionSetupOutcome.RETRY,
            singleSubscriptionSetupOutcome(candidateFound = true, enabled = false, transportFailure = true),
        )
        assertEquals(
            SingleSubscriptionSetupOutcome.UNAVAILABLE,
            singleSubscriptionSetupOutcome(candidateFound = false, enabled = false, transportFailure = false),
        )
        assertEquals(
            SingleSubscriptionSetupOutcome.UNAVAILABLE,
            singleSubscriptionSetupOutcome(candidateFound = true, enabled = false, transportFailure = false),
        )
    }

    @Test
    fun `CCCD mode prefers notifications and supports indication-only devices`() {
        assertEquals(GattCccdWriteKind.NOTIFY, gattCccdWriteKind(0x10))
        assertEquals(GattCccdWriteKind.INDICATE, gattCccdWriteKind(0x20))
        assertEquals(GattCccdWriteKind.NOTIFY, gattCccdWriteKind(0x10 or 0x20))
        assertEquals(GattCccdWriteKind.UNSUPPORTED, gattCccdWriteKind(0x02))
    }

    @Test
    fun `only authentication and encryption GATT failures require pairing`() {
        assertTrue(isGattAuthenticationFailure(0x05))
        assertTrue(isGattAuthenticationFailure(0x08))
        assertTrue(isGattAuthenticationFailure(0x0c))
        assertTrue(isGattAuthenticationFailure(0x0f))
        assertFalse(isGattAuthenticationFailure(0))
        assertFalse(isGattAuthenticationFailure(133))
    }
}
