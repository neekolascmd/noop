package com.noop.polar

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PolarPmdTest {
    private fun le64(value: Long): ByteArray =
        ByteArray(8) { index -> (value ushr (index * 8)).toByte() }

    private fun frame(
        type: PolarPmdMeasurement,
        timestamp: Long,
        frameType: Int,
        compressed: Boolean = false,
        payload: ByteArray,
    ): ByteArray = byteArrayOf(type.wire.toByte()) + le64(timestamp) +
        byteArrayOf((frameType or if (compressed) 0x80 else 0).toByte()) + payload

    @Test
    fun featureAndCommandContract() {
        val features = requireNotNull(PolarPmdFeatures.parse(byteArrayOf(0x0F, 0x0F, 0x00)))
        assertEquals(
            setOf(
                PolarPmdMeasurement.ECG,
                PolarPmdMeasurement.PPG,
                PolarPmdMeasurement.ACCELEROMETER,
                PolarPmdMeasurement.PPI,
            ),
            features.measurements,
        )
        assertArrayEquals(byteArrayOf(1, 0), PolarPmdCommand.querySettings(PolarPmdMeasurement.ECG))
        assertArrayEquals(byteArrayOf(3, 3), PolarPmdCommand.stop(PolarPmdMeasurement.PPI))
        assertArrayEquals(
            byteArrayOf(
                2, 2,
                0, 1, 0xC8.toByte(), 0,
                1, 1, 0x10, 0,
                2, 1, 8, 0,
            ),
            PolarPmdCommand.start(
                PolarPmdMeasurement.ACCELEROMETER,
                mapOf(
                    PolarPmdSettingType.SAMPLE_RATE to 200,
                    PolarPmdSettingType.RESOLUTION to 16,
                    PolarPmdSettingType.RANGE to 8,
                ),
            ),
        )
    }

    @Test
    fun settingsAndMultipartResponse() {
        val params = byteArrayOf(
            0, 2, 0x82.toByte(), 0, 0xC8.toByte(), 0,
            1, 1, 0x10, 0,
            4, 1, 3,
            5, 1, 0, 0, 0x80.toByte(), 0x3F,
        )
        val settings = PolarPmdSettings.parse(params)
        assertEquals(listOf(130L, 200L), settings.numericOptions(PolarPmdSettingType.SAMPLE_RATE))
        assertEquals(200L, settings.maximumSelection[PolarPmdSettingType.SAMPLE_RATE])
        assertEquals(1.0, settings.factor, 0.000_001)

        val assembler = PolarPmdControlResponseAssembler()
        assertNull(assembler.append(byteArrayOf(0xF0.toByte(), 1, 2, 0, 1) + params.copyOfRange(0, 8)))
        val response = requireNotNull(
            assembler.append(byteArrayOf(0xF0.toByte(), 1, 2, 0, 0) + params.copyOfRange(8, params.size)),
        )
        assertArrayEquals(params, response.parameters)
        assertTrue(response.succeeded)
        assertEquals(PolarPmdMeasurement.ACCELEROMETER, response.measurement)
    }

    @Test
    fun sessionPlannerSerializesStartsAndSkipsRejectedStream() {
        val features = requireNotNull(PolarPmdFeatures.parse(byteArrayOf(0x0F, 0x0F, 0)))
        val planner = PolarPmdSessionPlanner()
        var update = planner.begin(
            features,
            listOf(
                PolarPmdMeasurement.PPI,
                PolarPmdMeasurement.ECG,
                PolarPmdMeasurement.GYROSCOPE,
                PolarPmdMeasurement.ACCELEROMETER,
            ),
        )
        assertArrayEquals(byteArrayOf(1, 3), update.command)

        update = planner.handle(PolarPmdControlResponse.parse(byteArrayOf(0xF0.toByte(), 1, 3, 0, 0)))
        assertArrayEquals(byteArrayOf(2, 3), update.command)
        update = planner.handle(PolarPmdControlResponse.parse(byteArrayOf(0xF0.toByte(), 2, 3, 0, 0)))
        assertEquals(PolarPmdMeasurement.PPI, update.started?.measurement)
        assertArrayEquals(byteArrayOf(1, 0), update.command)

        update = planner.handle(PolarPmdControlResponse.parse(byteArrayOf(0xF0.toByte(), 1, 0, 3)))
        assertEquals(PolarPmdMeasurement.ECG, update.skipped)
        assertArrayEquals(byteArrayOf(1, 2), update.command)

        val settings = byteArrayOf(0, 1, 0xC8.toByte(), 0, 1, 1, 0x10, 0)
        update = planner.handle(
            PolarPmdControlResponse.parse(byteArrayOf(0xF0.toByte(), 1, 2, 0, 0) + settings),
        )
        assertArrayEquals(
            byteArrayOf(2, 2, 0, 1, 0xC8.toByte(), 0, 1, 1, 0x10, 0),
            update.command,
        )
        update = planner.handle(
            PolarPmdControlResponse.parse(
                byteArrayOf(0xF0.toByte(), 2, 2, 0, 0, 5, 1, 0, 0, 0x80.toByte(), 0x3F),
            ),
        )
        assertEquals(PolarPmdMeasurement.ACCELEROMETER, update.started?.measurement)
        assertEquals(1.0, update.started?.startResponse?.factor ?: 0.0, 0.000_001)
        assertTrue(update.finished)
    }

    @Test
    fun sessionPlannerRejectsMalformedStartSettings() {
        val features = requireNotNull(PolarPmdFeatures.parse(byteArrayOf(0x0F, 0x04, 0)))
        val planner = PolarPmdSessionPlanner()
        var update = planner.begin(features, listOf(PolarPmdMeasurement.ACCELEROMETER))
        assertArrayEquals(byteArrayOf(1, 2), update.command)

        update = planner.handle(
            PolarPmdControlResponse.parse(
                byteArrayOf(0xF0.toByte(), 1, 2, 0, 0, 0, 1, 0xC8.toByte(), 0),
            ),
        )
        assertTrue(update.command != null)

        update = planner.handle(
            PolarPmdControlResponse.parse(
                byteArrayOf(0xF0.toByte(), 2, 2, 0, 0, 5, 1, 0),
            ),
        )
        assertNull(update.started)
        assertEquals(PolarPmdMeasurement.ACCELEROMETER, update.skipped)
        assertTrue(update.finished)
    }

    @Test
    fun ecgType0Signed24AndTimestamps() {
        val decoder = PolarPmdDecoder()
        decoder.configure(PolarPmdMeasurement.ECG, 2)
        val decoded = decoder.decode(
            frame(
                PolarPmdMeasurement.ECG,
                2_000_000_000,
                0,
                payload = byteArrayOf(
                    0xFE.toByte(), 0xFF.toByte(), 0xFF.toByte(),
                    2, 0, 0,
                ),
            ),
        )
        assertEquals(listOf(-2, 2), decoded.ecg.map { it.microVolts })
        assertEquals(listOf(1_500_000_000L, 2_000_000_000L), decoded.ecg.map { it.sensorTimestampNs })
    }

    @Test
    fun rawPpgType0() {
        val decoder = PolarPmdDecoder()
        // The PMD start-response factor applies only to compressed PPG, not raw type-0.
        decoder.configure(PolarPmdMeasurement.PPG, 1, 2.0)
        val decoded = decoder.decode(
            frame(
                PolarPmdMeasurement.PPG,
                3_000_000_000,
                0,
                payload = byteArrayOf(
                    1, 0, 0,
                    0xFE.toByte(), 0xFF.toByte(), 0xFF.toByte(),
                    0xFF.toByte(), 0xFF.toByte(), 0x7F,
                    0, 0, 0x80.toByte(),
                ),
            ),
        )
        assertEquals(listOf(1, -2, 8_388_607), decoded.ppg.single().channels)
        assertEquals(-8_388_608, decoded.ppg.single().ambient)
    }

    @Test
    fun compressedPpgType0AppliesFactor() {
        val decoder = PolarPmdDecoder()
        decoder.configure(PolarPmdMeasurement.PPG, 1, 2.0)
        val decoded = decoder.decode(
            frame(
                PolarPmdMeasurement.PPG,
                3_000_000_000,
                0,
                compressed = true,
                payload = byteArrayOf(
                    1, 0, 0,
                    0xFE.toByte(), 0xFF.toByte(), 0xFF.toByte(),
                    3, 0, 0,
                    4, 0, 0,
                ),
            ),
        )
        assertEquals(listOf(2, -4, 6), decoded.ppg.single().channels)
        assertEquals(8, decoded.ppg.single().ambient)
    }

    @Test
    fun rawAccelerationWidths() {
        val decoder = PolarPmdDecoder()
        decoder.configure(PolarPmdMeasurement.ACCELEROMETER, 2)
        val decoded = decoder.decode(
            frame(
                PolarPmdMeasurement.ACCELEROMETER,
                1_000_000_000,
                1,
                payload = byteArrayOf(0x9C.toByte(), 0xFF.toByte(), 0, 0, 0xE8.toByte(), 3),
            ),
        )
        assertEquals(
            PolarPmdAccelerationSample(1_000_000_000, -100, 0, 1000),
            decoded.acceleration.single(),
        )
    }

    @Test
    fun ppiFieldsAndBackfilledTimestamps() {
        val decoder = PolarPmdDecoder()
        val decoded = decoder.decode(
            frame(
                PolarPmdMeasurement.PPI,
                5_000_000_000,
                0,
                payload = byteArrayOf(
                    60, 0xE8.toByte(), 3, 10, 0, 6,
                    75, 0x20, 3, 20, 0, 1,
                ),
            ),
        )
        assertEquals(listOf(60, 75), decoded.ppi.map { it.heartRate })
        assertEquals(listOf(1000, 800), decoded.ppi.map { it.intervalMs })
        assertEquals(listOf(4_200_000_000L, 5_000_000_000L), decoded.ppi.map { it.sensorTimestampNs })
        assertEquals(true, decoded.ppi[0].skinContact)
        assertNull(decoded.ppi[1].skinContact)
        assertTrue(decoded.ppi[1].blocker)
    }

    @Test
    fun deltaDecompressionLsbFirstAndAccumulation() {
        val decoded = PolarPmdDecoder.deltaSamples(
            byteArrayOf(0x64, 0, 0x9C.toByte(), 0xFF.toByte(), 4, 2, 0xE1.toByte(), 0x3F),
            channels = 2,
            resolution = 16,
        )
        assertEquals(listOf(listOf(100, -100), listOf(101, -102), listOf(100, -99)), decoded)
    }

    @Test
    fun compressedAccelerationType1() {
        val decoder = PolarPmdDecoder()
        decoder.configure(PolarPmdMeasurement.ACCELEROMETER, 10, 1.0)
        val decoded = decoder.decode(
            frame(
                PolarPmdMeasurement.ACCELEROMETER,
                1_000_000_000,
                1,
                compressed = true,
                payload = byteArrayOf(
                    10, 0, 20, 0, 30, 0,
                    4, 1, 0xF1.toByte(), 2,
                ),
            ),
        )
        assertEquals(
            listOf(listOf(10, 20, 30), listOf(11, 19, 32)),
            decoded.acceleration.map { listOf(it.xMilliG, it.yMilliG, it.zMilliG) },
        )
        assertEquals(listOf(900_000_000L, 1_000_000_000L), decoded.acceleration.map { it.sensorTimestampNs })
    }

    @Test
    fun malformedPacketsAreRejected() {
        assertThrows(PolarPmdException::class.java) { PolarPmdDataFrame.parse(byteArrayOf(0)) }
        assertThrows(PolarPmdException::class.java) {
            PolarPmdSettings.parse(byteArrayOf(0, 2, 0x82.toByte()))
        }
        assertThrows(PolarPmdException::class.java) {
            PolarPmdDecoder.deltaSamples(byteArrayOf(0, 0), channels = 3, resolution = 16)
        }
        val decoder = PolarPmdDecoder()
        decoder.configure(PolarPmdMeasurement.ECG, 130)
        assertThrows(PolarPmdException::class.java) {
            decoder.decode(frame(PolarPmdMeasurement.ECG, 1, 0, payload = byteArrayOf(1, 2)))
        }
    }

    @Test
    fun clockUsesEpochOrStableReceiveAnchor() {
        val clock = PolarPmdClock()
        val receive = 1_800_000_000_000_000_000L
        val plausibleSensor = receive - PolarPmdClock.POLAR_TO_UNIX_EPOCH_NS
        assertEquals(receive, clock.unixNanoseconds(plausibleSensor, receive))

        clock.reset()
        val first = clock.unixNanoseconds(10, receive)
        val second = clock.unixNanoseconds(1_000_000_010, receive + 2_000_000_000)
        assertEquals(receive, first)
        assertEquals(receive + 1_000_000_000, second)
        assertFalse(second == receive + 2_000_000_000)

        clock.reset()
        val staleSensor = plausibleSensor - 24L * 60 * 60 * 1_000_000_000
        assertEquals(receive, clock.unixNanoseconds(staleSensor, receive))
    }

    @Test
    fun clockBackfillsZeroTimestampPpiFromReceiveTime() {
        val clock = PolarPmdClock()
        val receive = 1_800_000_000_000_000_000L
        val samples = listOf(
            PolarPmdPpiSample(0, 60, 1_000, 0, false, null),
            PolarPmdPpiSample(0, 75, 800, 0, false, null),
        )
        assertEquals(
            listOf(receive - 800_000_000, receive),
            clock.unixNanoseconds(samples, receive),
        )
        assertEquals(
            listOf(receive + 1_200_000_000, receive + 2_000_000_000),
            clock.unixNanoseconds(samples, receive + 2_000_000_000),
        )
    }
}
