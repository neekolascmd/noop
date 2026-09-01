package com.noop.garmin

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class GarminProtocolTest {
    @Test fun uuidAndServiceFacts() {
        assertEquals("6A4E2800-667B-11E3-949A-0800200C9A66", GarminMultiLinkUuid.SERVICE)
        assertEquals(5, GarminMultiLinkUuid.READ_CHARACTERISTICS.size)
        assertEquals("6A4E2824-667B-11E3-949A-0800200C9A66", GarminMultiLinkUuid.WRITE_CHARACTERISTICS.last())
        assertEquals(listOf(1, 6, 7, 12, 16, 19, 20, 21), GarminMultiLinkService.entries.map { it.code })
    }

    @Test fun handleBuildersAndRegistrationResponses() {
        val client = GarminClientId(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8))
        assertArrayEquals(
            byteArrayOf(0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 0, 0),
            GarminHandleManagement.register(GarminMultiLinkService.REALTIME_HRV, client),
        )
        assertArrayEquals(
            byteArrayOf(0, 2, 1, 2, 3, 4, 5, 6, 7, 8, 6, 0, 0x35),
            GarminHandleManagement.close(GarminMultiLinkService.REALTIME_HEART_RATE, 0x35, client),
        )
        assertArrayEquals(byteArrayOf(0x34, 0x12), GarminHandleManagement.closeAll(client, 0x1234).takeLast(2).toByteArray())

        val success = byteArrayOf(0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 1, 0, 1)
        val parsed = GarminHandleManagement.parseRegistrationResponse(success)!!
        assertTrue(parsed.succeeded)
        assertEquals(4, parsed.serviceCode)
        assertEquals(1, parsed.handle)
        assertEquals(false, parsed.reliable)
        assertEquals(true, parsed.usesMultiLinkCharacteristic)

        val nonzero = byteArrayOf(0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 6, 0, 3, 0x12, 0x28)
        val denied = GarminHandleManagement.parseRegistrationResponse(nonzero)!!
        assertFalse(denied.succeeded)
        assertEquals(3, denied.statusRaw)
        assertNull(denied.handle)

        assertTrue(GarminHandleManagement.isCloseAllResponse(byteArrayOf(0, 6, 2, 0, 0, 0, 0, 0, 0, 0)))
        assertFalse(GarminHandleManagement.isCloseAllResponse(byteArrayOf(0, 6, 3, 0, 0, 0, 0, 0, 0, 0)))
    }

    @Test fun multiLinkFragmentationRepeatsHandleAndRespectsMtu() {
        val payload = ByteArray(50) { it.toByte() }
        val packets = GarminMultiLinkFraming.fragment(handle = 7, encodedPayload = payload, attMtu = 23)
        assertEquals(listOf(20, 20, 13), packets.map { it.size })
        assertTrue(packets.all { (it[0].toInt() and 0xff) == 7 })
        assertArrayEquals(payload, packets.flatMap { it.drop(1) }.toByteArray())
    }

    @Test fun realtimeMappingPersistsOnlyQualifiedMeanings() {
        val now = 1_800_000_000L
        val hr = GarminRealtimeValue.HeartRate(byteArrayOf(2, 72, 55), 2, 72, 72, 55)
        val mappedHr = GarminRealtimeMapping.map(hr, now)
        assertEquals(72, mappedHr.liveHeartRate)
        assertEquals(72, mappedHr.batch.hr.single().bpm)

        val rr = GarminRealtimeValue.Hrv(byteArrayOf(), 800, 800, 0)
        val mappedRr = GarminRealtimeMapping.map(rr, now)
        assertEquals(800, mappedRr.liveRrMilliseconds)
        assertEquals(800, mappedRr.batch.rr.single().rrMs)

        val validGarminTs = now - GarminEpoch.UNIX_OFFSET_SECONDS
        val spo2 = GarminRealtimeValue.Spo2(byteArrayOf(), 97, 97, validGarminTs, now)
        val mappedSpo2 = GarminRealtimeMapping.map(spo2, receiptUnixSeconds = now, nowUnixSeconds = now)
        assertEquals("tenths_percent", mappedSpo2.batch.spo2.single().unit)
        assertEquals(970, mappedSpo2.batch.spo2.single().red)

        val stale = spo2.copy(garminTimestamp = 1, unixSeconds = GarminEpoch.unixSeconds(1))
        assertTrue(GarminRealtimeMapping.map(stale, now, now).batch.isEmpty)

        val respiration = GarminRealtimeValue.Respiration(byteArrayOf(18), 18, 18)
        val event = GarminRealtimeMapping.map(respiration, now).batch.events.single()
        assertEquals("GARMIN_REALTIME_RESPIRATION", event.kind)
        assertEquals("{\"breaths_per_minute\":18}", event.payloadJSON)

        val opaque = GarminRealtimeValue.Opaque(GarminMultiLinkService.REALTIME_BODY_BATTERY, byteArrayOf(99))
        assertTrue(GarminRealtimeMapping.map(opaque, now).batch.isEmpty)
    }

    @Test fun cobsRoundTripAndStreamingBoundaries() {
        val payloads = listOf(
            byteArrayOf(), byteArrayOf(0), byteArrayOf(1, 2, 3), byteArrayOf(1, 0, 2, 0, 3),
            ByteArray(254) { 7 },
        )
        payloads.forEach { payload -> assertArrayEquals(payload, GarminCobs.decode(GarminCobs.encode(payload))) }
        assertThrows(GarminCobsException::class.java) { GarminCobs.decode(byteArrayOf(1, 2, 0)) }
        assertThrows(GarminCobsException::class.java) { GarminCobs.decode(byteArrayOf(0, 4, 1, 0)) }

        val first = GarminCobs.encode(byteArrayOf(1, 0, 2))
        val second = GarminCobs.encode(byteArrayOf(9, 8))
        val stream = GarminCobsStreamDecoder(100)
        assertTrue(stream.feed(first.copyOfRange(0, 2)).isEmpty())
        val completed = stream.feed(first.copyOfRange(2, first.size) + second)
        assertEquals(2, completed.size)
        assertArrayEquals(byteArrayOf(1, 0, 2), (completed[0] as GarminFrameResult.Frame).bytes)
        assertArrayEquals(byteArrayOf(9, 8), (completed[1] as GarminFrameResult.Frame).bytes)
    }

    @Test fun cobsBoundsAndRecovers() {
        val stream = GarminCobsStreamDecoder(3)
        val results = stream.feed(byteArrayOf(0, 1, 2, 3, 4, 0) + GarminCobs.encode(byteArrayOf(7)))
        assertEquals(GarminCobsError.FRAME_TOO_LARGE, (results[0] as GarminFrameResult.Failure).error)
        assertArrayEquals(byteArrayOf(7), (results[1] as GarminFrameResult.Frame).bytes)
    }

    @Test fun gfdiGoldenVectorAndValidation() {
        val golden = byteArrayOf(0x09, 0x00, 0x08, 0x98.toByte(), 0x28, 0x01, 0x10, 0xd7.toByte(), 0xf5.toByte())
        assertEquals(0xf5d7, GarminGfdi.crc16(golden.copyOfRange(0, golden.size - 2)))
        val decoded = GarminGfdi.decode(golden)
        assertEquals(5008, decoded.messageId)
        assertEquals(24, decoded.sequence)
        assertArrayEquals(byteArrayOf(0x28, 0x01, 0x10), decoded.payload)
        assertArrayEquals(golden, GarminGfdi.encode(5008, 24, byteArrayOf(0x28, 0x01, 0x10)))

        val wrongLength = golden.copyOf().also { it[0] = 8 }
        assertEquals(
            GarminGfdiError.INVALID_LENGTH,
            assertThrows(GarminGfdiException::class.java) { GarminGfdi.decode(wrongLength) }.reason,
        )
        val wrongCrc = golden.copyOf().also { it[4] = (it[4].toInt() xor 1).toByte() }
        assertEquals(
            GarminGfdiError.INVALID_CRC,
            assertThrows(GarminGfdiException::class.java) { GarminGfdi.decode(wrongCrc) }.reason,
        )
    }

    @Test fun gfdiResponseStatus() {
        val response = GarminGfdi.decode(GarminGfdi.encode(5000, payload = byteArrayOf(0x90.toByte(), 0x13, 4, 0xaa.toByte())))
        assertEquals(5008, response.responseToMessageId)
        assertEquals(4, response.statusRaw)
        assertEquals(GarminGfdiStatus.CRC_ERROR, response.status)
    }

    @Test fun realtimeValuesStayRawAndOnlyQualifiedFieldsSurface() {
        val hr = GarminRealtimeDecoder.decode(
            GarminMultiLinkService.REALTIME_HEART_RATE,
            byteArrayOf(2, 72, 55, 0xff.toByte(), 0xff.toByte()),
        ) as GarminRealtimeValue.HeartRate
        assertEquals(72, hr.heartRateBpm)
        assertNull(GarminRealtimeDecoder.decode(GarminMultiLinkService.REALTIME_HEART_RATE, byteArrayOf(2, 72)))

        val steps = GarminRealtimeDecoder.decode(
            GarminMultiLinkService.REALTIME_STEPS,
            byteArrayOf(0x39, 0x30, 0, 0, 0x10, 0x27, 0, 0),
        ) as GarminRealtimeValue.Steps
        assertEquals(12_345, steps.steps)
        assertEquals(10_000, steps.goal)

        val hrv = GarminRealtimeDecoder.decode(
            GarminMultiLinkService.REALTIME_HRV,
            byteArrayOf(0x20, 0x03, 1, 2, 3, 4),
        ) as GarminRealtimeValue.Hrv
        assertEquals(800, hrv.rrMilliseconds)
        assertEquals(0x04030201, hrv.unknown)
        val rawOnly = GarminRealtimeDecoder.decode(
            GarminMultiLinkService.REALTIME_HRV,
            byteArrayOf(100, 0, 0, 0, 0, 0),
        ) as GarminRealtimeValue.Hrv
        assertNull(rawOnly.rrMilliseconds)
    }

    @Test fun spo2RespirationOpaqueAndEpoch() {
        val spo2 = GarminRealtimeDecoder.decode(
            GarminMultiLinkService.REALTIME_SPO2,
            byteArrayOf(97, 1, 0, 0, 0),
        ) as GarminRealtimeValue.Spo2
        assertEquals(97, spo2.percent)
        assertEquals(GarminEpoch.UNIX_OFFSET_SECONDS + 1, spo2.unixSeconds)
        val unavailable = GarminRealtimeDecoder.decode(
            GarminMultiLinkService.REALTIME_SPO2,
            byteArrayOf(0xff.toByte(), 1, 0, 0, 0),
        ) as GarminRealtimeValue.Spo2
        assertEquals(-1, unavailable.rawValue)
        assertNull(unavailable.percent)

        val respiration = GarminRealtimeDecoder.decode(
            GarminMultiLinkService.REALTIME_RESPIRATION,
            byteArrayOf(18),
        ) as GarminRealtimeValue.Respiration
        assertEquals(18, respiration.breathsPerMinute)
        val missingResp = GarminRealtimeDecoder.decode(
            GarminMultiLinkService.REALTIME_RESPIRATION,
            byteArrayOf(0xfe.toByte()),
        ) as GarminRealtimeValue.Respiration
        assertNull(missingResp.breathsPerMinute)

        assertNotNull(GarminRealtimeDecoder.decode(GarminMultiLinkService.REALTIME_ACCELEROMETER, byteArrayOf(1)))
        assertNull(GarminRealtimeDecoder.decode(GarminMultiLinkService.REALTIME_BODY_BATTERY, byteArrayOf()))
        assertEquals(0L, GarminEpoch.garminSeconds(GarminEpoch.UNIX_OFFSET_SECONDS))
        assertNull(GarminEpoch.garminSeconds(0))
    }

    @Test fun sessionHandshakeAdvertisesOnlyExplicitCapabilities() {
        val incoming = GarminGfdi.decode(
            GarminGfdi.encode(
                GarminGfdiMessageId.CONFIGURATION.code,
                payload = byteArrayOf(4, 0xfb.toByte(), 0xff.toByte(), 0x3f, 0xa6.toByte()),
            ),
        )
        val reply = GarminSessionResponder.reply(
            incoming,
            nowUnixSeconds = 1_800_000_000,
            timeZoneOffsetSeconds = -18_000,
            supportedCapabilities = byteArrayOf(),
        )!!
        assertTrue(reply.configurationCompleted)
        assertEquals(2, reply.outgoing.size)
        val config = GarminGfdi.decode(reply.outgoing[0])
        assertEquals(GarminGfdiMessageId.CONFIGURATION.code, config.messageId)
        assertArrayEquals(byteArrayOf(0), config.payload)
        val ready = GarminGfdi.decode(reply.outgoing[1])
        assertEquals(GarminGfdiMessageId.SYSTEM_EVENT.code, ready.messageId)
        assertArrayEquals(byteArrayOf(GarminSessionResponder.SYNC_READY_EVENT.toByte()), ready.payload)
    }

    @Test fun sessionDeviceInfoTimeAndUnsupportedReplies() {
        val info = GarminGfdi.decode(
            GarminGfdi.encode(
                GarminGfdiMessageId.DEVICE_INFORMATION.code,
                payload = byteArrayOf(150.toByte(), 0) + ByteArray(10),
            ),
        )
        val infoResponse = GarminGfdi.decode(
            GarminSessionResponder.reply(info, 1_800_000_000, 0)!!.outgoing.first(),
        )
        assertEquals(GarminGfdiMessageId.DEVICE_INFORMATION.code, infoResponse.responseToMessageId)
        assertEquals(GarminGfdiStatus.ACKNOWLEDGEMENT, infoResponse.status)

        val reference = byteArrayOf(0x78, 0x56, 0x34, 0x12)
        val time = GarminGfdi.decode(
            GarminGfdi.encode(GarminGfdiMessageId.CURRENT_TIME_REQUEST.code, payload = reference),
        )
        val timeResponse = GarminGfdi.decode(
            GarminSessionResponder.reply(time, 1_800_000_000, -18_000)!!.outgoing.first(),
        )
        assertArrayEquals(reference, timeResponse.payload.copyOfRange(3, 7))

        val protobuf = GarminGfdi.decode(
            GarminGfdi.encode(GarminGfdiMessageId.PROTOBUF_REQUEST.code, payload = byteArrayOf(5)),
        )
        val unsupported = GarminGfdi.decode(
            GarminSessionResponder.reply(protobuf, 1_800_000_000, 0)!!.outgoing.first(),
        )
        assertEquals(GarminGfdiStatus.UNSUPPORTED, unsupported.status)
    }
}
