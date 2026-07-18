package com.noop.ble

import com.noop.oura.OuraTimeAnchor
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OuraSyncStateStoreTest {
    private val now = 1_800_000_000_000L

    private class MemoryBackend : OuraSyncStateBackend {
        val values = mutableMapOf<String, Any>()
        var commits = 0
        var failCommit = false

        override fun string(key: String): String? = values[key] as? String
        override fun long(key: String): Long? = values[key] as? Long
        override fun commit(values: Map<String, Any?>): Boolean {
            commits += 1
            if (failCommit) return false
            val next = this.values.toMutableMap()
            for ((key, value) in values) {
                if (value == null) next.remove(key) else next[key] = value
            }
            this.values.clear()
            this.values.putAll(next)
            return true
        }
    }

    @Test
    fun legacyCursorMigratesAtomicallyWithoutInventingAnchor() {
        val backend = MemoryBackend()
        val device = "ring-a"
        backend.values[OuraSyncStateStore.legacyCursorKey(device)] = 42L

        val state = OuraSyncStateStore.read(backend, device, now)

        assertEquals(42L, state.cursor)
        assertNull(state.primaryAnchor)
        assertEquals(now, state.savedAtMilliseconds)
        assertEquals(1, backend.commits)
        assertFalse(backend.values.containsKey(OuraSyncStateStore.legacyCursorKey(device)))
        val encoded = backend.values[OuraSyncStateStore.stateKey(device)] as String
        assertFalse(JSONObject(encoded).has("primaryAnchor"))
    }

    @Test
    fun stateRoundTripsCursorAnchorFactorAndSavedAt() {
        val backend = MemoryBackend()
        val anchor = OuraTimeAnchor(123L, 1_700_000_000_000L, 1L)
        assertTrue(
            OuraSyncStateStore.save(
                backend,
                "ring-a",
                OuraSyncState(cursor = 456L, primaryAnchor = anchor),
                now,
            ),
        )

        assertEquals(
            OuraSyncState(cursor = 456L, primaryAnchor = anchor, savedAtMilliseconds = now),
            OuraSyncStateStore.read(backend, "ring-a", now),
        )
        assertEquals(1, backend.commits)
    }

    @Test
    fun stateIsIsolatedPerDevice() {
        val backend = MemoryBackend()
        val a = OuraTimeAnchor(100L, 1_700_000_000_000L, 100L)
        val b = OuraTimeAnchor(200L, 1_700_000_100_000L, 1L)
        assertTrue(OuraSyncStateStore.save(backend, "ring-a", OuraSyncState(101L, a), now))
        assertTrue(OuraSyncStateStore.save(backend, "ring-b", OuraSyncState(202L, b), now))

        assertEquals(a, OuraSyncStateStore.read(backend, "ring-a", now).primaryAnchor)
        assertEquals(101L, OuraSyncStateStore.read(backend, "ring-a", now).cursor)
        assertEquals(b, OuraSyncStateStore.read(backend, "ring-b", now).primaryAnchor)
        assertEquals(202L, OuraSyncStateStore.read(backend, "ring-b", now).cursor)
    }

    @Test
    fun corruptPartialOrUnreasonableStateIsRejectedAsAbsent() {
        val backend = MemoryBackend()
        val key = OuraSyncStateStore.stateKey("ring-a")
        val invalidPayloads = listOf(
            "not-json",
            JSONObject().put("version", 99).put("cursor", 1).put("savedAtMilliseconds", now).toString(),
            JSONObject().put("version", 1).put("cursor", -1).put("savedAtMilliseconds", now).toString(),
            JSONObject().put("version", 1).put("cursor", 1).put("savedAtMilliseconds", now)
                .put("primaryAnchor", JSONObject().put("ringTimestamp", 1)).toString(),
            JSONObject().put("version", 1).put("cursor", 1).put("savedAtMilliseconds", now)
                .put(
                    "primaryAnchor",
                    JSONObject().put("ringTimestamp", 1).put("utcMilliseconds", 1_700_000_000_000L)
                        .put("factorMillisecondsPerTick", 10),
                ).toString(),
        )

        for (payload in invalidPayloads) {
            backend.values[key] = payload
            assertEquals(payload, OuraSyncState(), OuraSyncStateStore.read(backend, "ring-a", now))
        }

        val futureSavedAt = now + 25L * 60L * 60L * 1_000L
        backend.values[key] = JSONObject().put("version", 1).put("cursor", 7)
            .put("savedAtMilliseconds", futureSavedAt)
            .put(
                "primaryAnchor",
                JSONObject().put("ringTimestamp", 1).put("utcMilliseconds", 1_700_000_000_000L)
                    .put("factorMillisecondsPerTick", 100),
            ).toString()
        assertEquals(
            "an unreasonable savedAt drops only the UTC mapping, not the opaque cursor",
            OuraSyncState(cursor = 7L, primaryAnchor = null, savedAtMilliseconds = futureSavedAt),
            OuraSyncStateStore.read(backend, "ring-a", now),
        )
    }

    @Test
    fun failedCommitDoesNotPartiallyReplaceExistingState() {
        val backend = MemoryBackend()
        val original = OuraSyncState(10L, OuraTimeAnchor(5L, 1_700_000_000_000L, 100L))
        assertTrue(OuraSyncStateStore.save(backend, "ring-a", original, now))
        val rawBefore = backend.values[OuraSyncStateStore.stateKey("ring-a")]
        backend.failCommit = true

        assertFalse(OuraSyncStateStore.save(backend, "ring-a", OuraSyncState(20L, original.primaryAnchor), now + 1))
        assertEquals(rawBefore, backend.values[OuraSyncStateStore.stateKey("ring-a")])
    }
}
