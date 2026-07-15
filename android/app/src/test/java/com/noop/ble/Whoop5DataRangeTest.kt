package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Test

class Whoop5DataRangeTest {
    private fun bytes(hex: String): ByteArray =
        hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun realPuffinResponseKeepsTimestampWordsAligned() {
        // Token-free real GET_DATA_RANGE fixture, shared with the Swift protocol tests. The command
        // byte moves to frame[10], while the timestamp words begin at payload +3 = frame[14].
        val frame = bytes(
            "aa014c00010032d124982207010180b901005ab7010048b901005ab701001000000000000200da1b00000ee31d00" +
                "b0e1ff69d7430000a3ab266a3d4a0000a3ab266a3d4a00007cc7266a5c4f00000000623977f5",
        )
        assertEquals(1_778_377_136L, WhoopBleClient.dataRangeOldestUnix(frame, com.noop.protocol.DeviceFamily.WHOOP5))
        assertEquals(1_780_926_332L, WhoopBleClient.dataRangeNewestUnix(frame, com.noop.protocol.DeviceFamily.WHOOP5))

        val corrupted = frame.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 0x01).toByte() }
        assertEquals(null, WhoopBleClient.dataRangeOldestUnix(corrupted, com.noop.protocol.DeviceFamily.WHOOP5))
        assertEquals(null, WhoopBleClient.dataRangeNewestUnix(corrupted, com.noop.protocol.DeviceFamily.WHOOP5))
    }
}
