package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordInventoryTest {
    @Test
    fun countsMetadataWithoutRetainingPayloadValues() {
        val inventory = OuraRecordInventory()
        val temp = OuraRecord(
            type = OuraEventTag.TEMP.raw,
            ringTimestamp = 0x12345678,
            payload = intArrayOf(0xE4, 0x0C),
        )
        val unknown = OuraRecord(
            type = 0x90,
            ringTimestamp = 0x87654321,
            payload = intArrayOf(0xAA, 0xBB, 0xCC),
        )

        inventory.observe(temp, emittedEventCount = 1)
        inventory.observe(unknown, emittedEventCount = 0)
        inventory.observe(unknown, emittedEventCount = 0)

        assertEquals(3, inventory.totalRecordCount)
        assertEquals(temp.totalLength + 2 * unknown.totalLength, inventory.totalWireByteCount)
        assertEquals(1, inventory.emittedEventCount)
        assertEquals(2, inventory.unknownRecordCount)
        assertEquals(
            listOf(
                OuraRecordInventory.Entry(0x46, 1, 8, 1, 1),
                OuraRecordInventory.Entry(0x90, 2, 18, 0, 0),
            ),
            inventory.entries,
        )
        assertEquals(OuraEventTag.TEMP, inventory.entries[0].knownTag)
        assertNull(inventory.entries[1].knownTag)
        assertEquals(2, inventory.entries[1].silentRecordCount)

        val summary = inventory.summary()
        assertTrue(summary.contains("records=3 bytes=26 events=1 unknown=2"))
        assertTrue(summary.contains("0x46(TEMP)=1r/1e/8b"))
        assertTrue(summary.contains("0x90(UNKNOWN)=2r/0e/18b"))
        assertFalse(summary.contains("12345678"))
        assertFalse(summary.contains("AABBCC"))
    }

    @Test
    fun knownSilentRecordIsNotReportedAsUnknown() {
        val inventory = OuraRecordInventory()
        inventory.observe(
            OuraRecord(
                type = OuraEventTag.RING_START.raw,
                ringTimestamp = 1,
                payload = intArrayOf(1, 2, 3, 4),
            ),
            emittedEventCount = 0,
        )

        assertEquals(0, inventory.unknownRecordCount)
        assertEquals(OuraEventTag.RING_START, inventory.entries.single().knownTag)
        assertEquals(1, inventory.entries.single().silentRecordCount)
    }

    @Test
    fun summaryTagLimitIsBoundedAndDeterministic() {
        val inventory = OuraRecordInventory()
        inventory.observe(OuraRecord(0x90, 1, intArrayOf()), emittedEventCount = 0)
        inventory.observe(OuraRecord(0x46, 2, intArrayOf(0, 0)), emittedEventCount = 1)
        inventory.observe(OuraRecord(0x85, 3, intArrayOf(0, 0, 0, 0)), emittedEventCount = 1)

        assertEquals(
            "records=3 bytes=24 events=2 unknown=1 " +
                "tags=[0x46(TEMP)=1r/1e/8b,0x85(RTC_BEACON)=1r/1e/10b +1 tag(s)]",
            inventory.summary(maximumTags = 2),
        )
        assertEquals(
            "records=3 bytes=24 events=2 unknown=1 tags=[none +3 tag(s)]",
            inventory.summary(maximumTags = 0),
        )
    }
}
