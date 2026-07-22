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
            gattOperationFailureAction(requiredForHr = true),
        )
        assertEquals(
            GattOperationFailureAction.SKIP_OPTIONAL,
            gattOperationFailureAction(requiredForHr = false),
        )
    }
}
