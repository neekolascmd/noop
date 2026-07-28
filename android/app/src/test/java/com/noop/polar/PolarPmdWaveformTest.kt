package com.noop.polar

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PolarPmdWaveformTest {
    @Test
    fun ecgChunksUseSignedInt32LittleEndian() {
        val buffer = PolarPmdWaveformBuffer()
        val emitted = buffer.appendEcg(
            samples = listOf(
                PolarPmdEcgSample(10, 1),
                PolarPmdEcgSample(20, -2),
            ),
            unixTimestampsNs = listOf(1_000_000_000, 1_010_000_000),
            sampleRateHz = 100,
        )
        assertTrue(emitted.isEmpty())

        val chunk = buffer.flush().single()
        assertEquals(PolarPmdWaveformKind.ECG, chunk.kind)
        assertEquals(1_000_000_000, chunk.startUnixNs)
        assertEquals(1_010_000_000, chunk.endUnixNs)
        assertEquals(100, chunk.sampleRateHz)
        assertEquals(1, chunk.channels)
        assertEquals(2, chunk.sampleCount)
        assertArrayEquals(
            byteArrayOf(
                0x01, 0x00, 0x00, 0x00,
                0xFE.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
            ),
            chunk.payload,
        )
    }

    @Test
    fun ppgChunksInterleaveThreeChannelsAndAmbient() {
        val buffer = PolarPmdWaveformBuffer()
        buffer.appendPpg(
            samples = listOf(PolarPmdPpgSample(10, listOf(1, 2, 3), 4)),
            unixTimestampsNs = listOf(2_000_000_000),
            sampleRateHz = 135,
        )

        val chunk = buffer.flush().single()
        assertEquals(PolarPmdWaveformKind.PPG, chunk.kind)
        assertEquals(4, chunk.channels)
        assertEquals(1, chunk.sampleCount)
        assertArrayEquals(
            byteArrayOf(
                0x01, 0x00, 0x00, 0x00,
                0x02, 0x00, 0x00, 0x00,
                0x03, 0x00, 0x00, 0x00,
                0x04, 0x00, 0x00, 0x00,
            ),
            chunk.payload,
        )
    }

    @Test
    fun fiveSecondBoundaryEmitsPriorChunk() {
        val buffer = PolarPmdWaveformBuffer()
        val emitted = buffer.appendEcg(
            samples = listOf(PolarPmdEcgSample(1, 10), PolarPmdEcgSample(2, 20)),
            unixTimestampsNs = listOf(
                1_000_000_000,
                1_000_000_000 + PolarPmdWaveformBuffer.TARGET_DURATION_NS,
            ),
            sampleRateHz = 130,
        )

        assertEquals(1, emitted.size)
        assertEquals(1, emitted.single().sampleCount)
        assertEquals(1, buffer.flush().single().sampleCount)
    }

    @Test
    fun nonIncreasingTimestampsAreRejected() {
        val buffer = PolarPmdWaveformBuffer()
        assertThrows(PolarPmdException::class.java) {
            buffer.appendEcg(
                samples = listOf(PolarPmdEcgSample(1, 10), PolarPmdEcgSample(2, 20)),
                unixTimestampsNs = listOf(1_000_000_000, 1_000_000_000),
                sampleRateHz = 130,
            )
        }
    }
}
