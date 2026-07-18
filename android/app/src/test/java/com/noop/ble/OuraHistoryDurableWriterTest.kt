package com.noop.ble

import com.noop.data.HrRow
import com.noop.data.StreamBatch
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OuraHistoryDurableWriterTest {
    @Test
    fun qualifiedLargeRing4PageFitsTheParkedBatchPolicy() {
        assertTrue(OuraHistoryBatchPolicy.canPersist(eventCount = 74_000, overflowed = false))
        assertTrue(
            OuraHistoryBatchPolicy.canPersist(
                eventCount = OuraHistoryBatchPolicy.MAX_PARKED_EVENTS,
                overflowed = false,
            ),
        )
        assertFalse(
            OuraHistoryBatchPolicy.canPersist(
                eventCount = OuraHistoryBatchPolicy.MAX_PARKED_EVENTS + 1,
                overflowed = false,
            ),
        )
        assertFalse(OuraHistoryBatchPolicy.canPersist(eventCount = 74_000, overflowed = true))
    }

    @Test
    fun writerAwaitsStreamsBeforeContinuingToSleepAndSuccess() = runTest {
        val releaseStreams = CompletableDeferred<Unit>()
        val calls = mutableListOf<String>()
        val writer = OuraHistoryDurableWriter(
            persistStreams = { _, deviceId ->
                calls.add("streams-start:$deviceId")
                releaseStreams.await()
                calls.add("streams-durable")
                true
            },
            persistSleepSession = { start, end ->
                calls.add("sleep:$start-$end")
                true
            },
        )
        val result = async {
            writer.persist(
                listOf(
                    OuraHistoryWrite.Streams(StreamBatch(hr = listOf(HrRow(1L, 60)))),
                    OuraHistoryWrite.SleepSession(10L, 20L),
                ),
                "ring-a",
            )
        }

        yield()
        assertFalse(result.isCompleted)
        assertEquals(listOf("streams-start:ring-a"), calls)
        releaseStreams.complete(Unit)
        assertTrue(result.await())
        assertEquals(listOf("streams-start:ring-a", "streams-durable", "sleep:10-20"), calls)
    }

    @Test
    fun failedOrThrowingWriteStopsBatchAndReturnsFalse() = runTest {
        var sleepCalls = 0
        val failed = OuraHistoryDurableWriter(
            persistStreams = { _, _ -> false },
            persistSleepSession = { _, _ -> sleepCalls += 1; true },
        )
        assertFalse(
            failed.persist(
                listOf(
                    OuraHistoryWrite.Streams(StreamBatch(hr = listOf(HrRow(1L, 60)))),
                    OuraHistoryWrite.SleepSession(10L, 20L),
                ),
                "ring-a",
            ),
        )
        assertEquals(0, sleepCalls)

        val throwing = OuraHistoryDurableWriter(
            persistStreams = { _, _ -> error("insert failed") },
            persistSleepSession = { _, _ -> true },
        )
        assertFalse(
            throwing.persist(
                listOf(OuraHistoryWrite.Streams(StreamBatch(hr = listOf(HrRow(1L, 60))))),
                "ring-a",
            ),
        )
    }
}
