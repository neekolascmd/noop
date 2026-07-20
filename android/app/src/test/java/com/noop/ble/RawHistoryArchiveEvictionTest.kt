package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #344: per-version retention floor for the reject archive. Before this fix a full archive simply
 * stopped accepting frames, so a rare never-seen layout version (WHOOP 4 v19, WHOOP 5 v20/v21)
 * arriving when the archive was full of the common version was lost — the exact frames the archive
 * exists to study. The fix gives every distinct hist_version a retention FLOOR: when over cap we evict
 * oldest surplus from the most-populous versions first, never below `perVersionFloor` newest lines of
 * any version, so the rare version always survives. These exercise the PURE [RawHistoryArchive.evictLines]
 * core (no Context, JVM-runnable) and mirror the macOS RawHistoryArchiveEvictionTests.
 */
class RawHistoryArchiveEvictionTest {

    /** A JSONL line whose stored frame has type@4 = 0x2F (47) and hist_version@5 = [version]. */
    private fun jsonl(version: Int, family: String = "whoop4", filler: String = "00"): String {
        val hex = "aa0100002f" + "%02x".format(version) + filler
        return """{"capturedAtMs":1,"trim":1,"family":"$family","frameHex":"$hex"}""" + "\n"
    }

    @Test fun keepsRareVersionUnderAFloodOfCommonFrames() {
        // Two rare v19 lines land FIRST (oldest), then a flood of the common v18 version.
        val lines = ArrayList<String>()
        lines.add(jsonl(19, filler = "a1"))
        lines.add(jsonl(19, filler = "b2"))
        for (i in 0 until 400) lines.add(jsonl(18, filler = "%02x".format(i and 0xFF)))

        val kept = RawHistoryArchive.evictLines(lines, maxBytes = 4_096, floor = 2)

        val bytes = kept.sumOf { it.toByteArray(Charsets.UTF_8).size }
        assertTrue("eviction must bring the archive within the cap", bytes <= 4_096)
        assertTrue("rare v19 #1 must survive", kept.any { it.contains("2f13a1") })  // 0x13 = 19
        assertTrue("rare v19 #2 must survive", kept.any { it.contains("2f13b2") })
        assertTrue("common v18 still represented", kept.any { it.contains("2f12") })  // 0x12 = 18
    }

    @Test fun eachDistinctVersionGetsItsOwnFloor() {
        val lines = ArrayList<String>()
        lines.add(jsonl(19))   // rare
        lines.add(jsonl(21))   // rare
        for (i in 0 until 400) lines.add(jsonl(18, filler = "%02x".format(i and 0xFF)))

        val kept = RawHistoryArchive.evictLines(lines, maxBytes = 6_144, floor = 2)
        assertTrue("v19 must keep its floor", kept.any { it.contains("2f13") })  // 0x13 = 19
        assertTrue("v21 must keep its floor", kept.any { it.contains("2f15") })  // 0x15 = 21
    }

    @Test fun noOpUnderCap() {
        val lines = (0 until 10).map { jsonl(18, filler = "%02x".format(it)) }
        assertEquals(lines, RawHistoryArchive.evictLines(lines, maxBytes = 1_000_000, floor = 2))
    }

    @Test fun versionByteReadsTheRightIndexPerFamily() {
        // WHOOP 4 = frame[5]; WHOOP 5 = frame[9] (puffin envelope 4 B longer).
        val w4 = byteArrayOf(0xAA.toByte(), 1, 0, 0, 47, 19, 0, 0)
        assertEquals(19, RawHistoryArchive.versionByte(w4, com.noop.protocol.DeviceFamily.WHOOP4))
        val w5 = byteArrayOf(0xAA.toByte(), 1, 0, 0, 0, 0, 0, 0, 47, 20, 0)
        assertEquals(20, RawHistoryArchive.versionByte(w5, com.noop.protocol.DeviceFamily.WHOOP5))
        // Too short → sentinel bucket, never crashes.
        assertEquals(-1, RawHistoryArchive.versionByte(byteArrayOf(0xAA.toByte(), 1), com.noop.protocol.DeviceFamily.WHOOP4))
    }
}
