import XCTest
@testable import GarminProtocol

final class GarminProtocolTests: XCTestCase {
    func testUUIDAndServiceFacts() {
        XCTAssertEqual(GarminMultiLinkUUID.service, "6A4E2800-667B-11E3-949A-0800200C9A66")
        XCTAssertEqual(GarminMultiLinkUUID.readCharacteristics.count, 5)
        XCTAssertEqual(GarminMultiLinkUUID.writeCharacteristics.last,
                       "6A4E2824-667B-11E3-949A-0800200C9A66")
        XCTAssertEqual(GarminMultiLinkService.allCases.map(\.rawValue), [1, 6, 7, 12, 16, 19, 20, 21])
    }

    func testHandleBuildersUseConfigurableClientAndLittleEndianService() {
        let client = GarminClientID([1,2,3,4,5,6,7,8])
        XCTAssertEqual(GarminHandleManagement.register(service: .realtimeHRV, clientID: client),
                       [0,0,1,2,3,4,5,6,7,8,12,0,0])
        XCTAssertEqual(GarminHandleManagement.register(service: .gfdi, clientID: client,
                                                       reliability: .reliable).last, 2)
        XCTAssertEqual(GarminHandleManagement.close(service: .realtimeHeartRate, handle: 0x35,
                                                    clientID: client),
                       [0,2,1,2,3,4,5,6,7,8,6,0,0x35])
        XCTAssertEqual(GarminHandleManagement.closeAll(clientID: client, flags: 0x1234).suffix(2),
                       [0x34, 0x12])
        XCTAssertTrue(GarminHandleManagement.isCloseAllResponse([0,6,2,0,0,0,0,0,0,0]))
        XCTAssertFalse(GarminHandleManagement.isCloseAllResponse([0,6,3,0,0,0,0,0,0,0]))
    }

    func testMultiLinkFragmentationRepeatsHandleAndRespectsMTU() {
        let payload = (0..<50).map(UInt8.init)
        let packets = GarminMultiLinkFraming.fragment(handle: 7, encodedPayload: payload, attMTU: 23)
        XCTAssertEqual(packets.map(\.count), [20, 20, 13])
        XCTAssertTrue(packets.allSatisfy { $0.first == 7 })
        XCTAssertEqual(packets.flatMap { $0.dropFirst() }, payload)
    }

    func testHandleRegistrationResponseGoldenVectors() throws {
        let success: [UInt8] = [0,1, 1,0,0,0,0,0,0,0, 4,0, 0, 1,0,1]
        let parsed = try XCTUnwrap(GarminHandleManagement.parseRegistrationResponse(success))
        XCTAssertEqual(parsed.service, 4)
        XCTAssertEqual(parsed.status, .success)
        XCTAssertEqual(parsed.handle, 1)
        XCTAssertEqual(parsed.reliable, false)
        XCTAssertEqual(parsed.usesMultiLinkCharacteristic, true)

        let occupied: [UInt8] = [0,1, 1,0,0,0,0,0,0,0, 6,0, 3, 0x12,0x28]
        let denied = try XCTUnwrap(GarminHandleManagement.parseRegistrationResponse(occupied))
        XCTAssertEqual(denied.statusRaw, 3)
        XCTAssertNil(denied.status)
        XCTAssertNil(denied.handle)
        XCTAssertNil(GarminHandleManagement.parseRegistrationResponse([0,1]))
    }

    func testCOBSRoundTripsZerosAndLongBlocks() throws {
        let payloads: [[UInt8]] = [[], [0], [1,2,3], [1,0,2,0,3], Array(repeating: 7, count: 254)]
        for payload in payloads {
            let framed = GarminCOBS.encode(payload)
            XCTAssertEqual(framed.first, 0)
            XCTAssertEqual(framed.last, 0)
            XCTAssertEqual(try GarminCOBS.decode(framed), payload)
        }
    }

    func testCOBSRejectsMalformedAndMissingBoundaries() {
        XCTAssertThrowsError(try GarminCOBS.decode([1,2,0]))
        XCTAssertThrowsError(try GarminCOBS.decode([0,4,1,0]))
    }

    func testStreamingCOBSHandlesSplitAndCoalescedFrames() throws {
        let first = GarminCOBS.encode([1,0,2])
        let second = GarminCOBS.encode([9,8])
        var decoder = GarminCOBSStreamDecoder(maximumEncodedSize: 100)
        XCTAssertTrue(decoder.feed(Array(first.prefix(2))).isEmpty)
        let completed = decoder.feed(Array(first.dropFirst(2)) + second)
        XCTAssertEqual(completed.count, 2)
        XCTAssertEqual(try completed[0].get(), [1,0,2])
        XCTAssertEqual(try completed[1].get(), [9,8])
    }

    func testStreamingCOBSBoundsAndRecoversAtDelimiter() throws {
        var decoder = GarminCOBSStreamDecoder(maximumEncodedSize: 3)
        let results = decoder.feed([0,1,2,3,4,0] + GarminCOBS.encode([7]))
        XCTAssertEqual(results.count, 2)
        XCTAssertThrowsError(try results[0].get())
        XCTAssertEqual(try results[1].get(), [7])
    }

    func testCRCAndGFDIGoldenVector() throws {
        let golden: [UInt8] = [0x09,0x00,0x08,0x98,0x28,0x01,0x10,0xD7,0xF5]
        XCTAssertEqual(GarminGFDI.crc16(Array(golden.dropLast(2))), 0xF5D7)
        let decoded = try GarminGFDI.decode(golden)
        XCTAssertEqual(decoded.messageID, 5008)
        XCTAssertEqual(decoded.sequence, 24)
        XCTAssertEqual(decoded.payload, [0x28,0x01,0x10])
        XCTAssertEqual(try GarminGFDI.encode(messageID: 5008, sequence: 24,
                                             payload: [0x28,0x01,0x10]), golden)
    }

    func testGFDILengthCRCAndSequenceValidation() throws {
        let valid = try GarminGFDI.encode(messageID: 5044, payload: [1,2,3])
        XCTAssertEqual(try GarminGFDI.decode(valid).messageID, 5044)
        var wrongLength = valid; wrongLength[0] &-= 1
        XCTAssertThrowsError(try GarminGFDI.decode(wrongLength)) { XCTAssertEqual($0 as? GarminGFDIError, .invalidLength) }
        var wrongCRC = valid; wrongCRC[4] ^= 1
        XCTAssertThrowsError(try GarminGFDI.decode(wrongCRC)) { XCTAssertEqual($0 as? GarminGFDIError, .invalidCRC) }
        XCTAssertThrowsError(try GarminGFDI.encode(messageID: 4999, sequence: 1))
        XCTAssertThrowsError(try GarminGFDI.encode(messageID: 5000, sequence: 32))
    }

    func testGFDIResponseExposesRawAndTypedStatus() throws {
        let bytes = try GarminGFDI.encode(messageID: 5000, payload: [0x90,0x13,0x04,0xAA])
        let response = try GarminGFDI.decode(bytes)
        XCTAssertEqual(response.responseToMessageID, 5008)
        XCTAssertEqual(response.statusRaw, 4)
        XCTAssertEqual(response.status, .crcError)
    }

    func testHeartRateStrictShapesAndQualification() throws {
        guard case .heartRate(let hr) = GarminRealtimeDecoder.decode(service: .realtimeHeartRate,
                                                                      payload: [2,72,55]) else {
            return XCTFail("expected HR")
        }
        XCTAssertEqual(hr.type, 2); XCTAssertEqual(hr.heartRateBPM, 72); XCTAssertEqual(hr.restingHeartRate, 55)
        XCTAssertNotNil(GarminRealtimeDecoder.decode(service: .realtimeHeartRate,
                                                     payload: [2,72,55,0xFF,0xFF]))
        XCTAssertNil(GarminRealtimeDecoder.decode(service: .realtimeHeartRate, payload: [2,72]))
        XCTAssertNil(GarminRealtimeDecoder.decode(service: .realtimeHeartRate,
                                                  payload: [2,72,55,0,0]))
        guard case .heartRate(let unavailable) = GarminRealtimeDecoder.decode(
            service: .realtimeHeartRate, payload: [2,0,55]) else { return XCTFail() }
        XCTAssertNil(unavailable.heartRateBPM); XCTAssertEqual(unavailable.rawHeartRate, 0)
    }

    func testStepsAndHRVKeepRawButGateMeaning() throws {
        guard case .steps(let steps) = GarminRealtimeDecoder.decode(
            service: .realtimeSteps, payload: [0x39,0x30,0,0, 0x10,0x27,0,0]) else { return XCTFail() }
        XCTAssertEqual(steps.steps, 12_345); XCTAssertEqual(steps.goal, 10_000)
        XCTAssertNil(GarminRealtimeDecoder.decode(service: .realtimeSteps,
                                                  payload: [0xFF,0xFF,0xFF,0xFF, 0,0,0,0]))
        guard case .hrv(let hrv) = GarminRealtimeDecoder.decode(
            service: .realtimeHRV, payload: [0x20,0x03, 1,2,3,4]) else { return XCTFail() }
        XCTAssertEqual(hrv.rrMilliseconds, 800); XCTAssertEqual(hrv.unknown, 0x04030201)
        guard case .hrv(let rawOnly) = GarminRealtimeDecoder.decode(
            service: .realtimeHRV, payload: [100,0, 0,0,0,0]) else { return XCTFail() }
        XCTAssertEqual(rawOnly.rawRRMilliseconds, 100); XCTAssertNil(rawOnly.rrMilliseconds)
    }

    func testSpO2RespirationOpaqueAndEpoch() throws {
        guard case .spo2(let spo2) = GarminRealtimeDecoder.decode(
            service: .realtimeSpO2, payload: [97,1,0,0,0]) else { return XCTFail() }
        XCTAssertEqual(spo2.percent, 97)
        XCTAssertEqual(spo2.unixSeconds, GarminEpoch.unixOffsetSeconds + 1)
        guard case .spo2(let unavailable) = GarminRealtimeDecoder.decode(
            service: .realtimeSpO2, payload: [0xFF,1,0,0,0]) else { return XCTFail() }
        XCTAssertEqual(unavailable.rawValue, -1); XCTAssertNil(unavailable.percent)
        guard case .respiration(let respiration) = GarminRealtimeDecoder.decode(
            service: .realtimeRespiration, payload: [18]) else { return XCTFail() }
        XCTAssertEqual(respiration.breathsPerMinute, 18)
        guard case .respiration(let noRespiration) = GarminRealtimeDecoder.decode(
            service: .realtimeRespiration, payload: [0xFE]) else { return XCTFail() }
        XCTAssertNil(noRespiration.breathsPerMinute)
        guard case .accelerometer(let accel) = GarminRealtimeDecoder.decode(
            service: .realtimeAccelerometer, payload: [1,2,3]) else { return XCTFail() }
        XCTAssertEqual(accel.raw, [1,2,3])
        guard case .bodyBattery(let battery) = GarminRealtimeDecoder.decode(
            service: .realtimeBodyBattery, payload: [99,42]) else { return XCTFail() }
        XCTAssertEqual(battery.raw, [99,42])
        XCTAssertNil(GarminRealtimeDecoder.decode(service: .realtimeBodyBattery, payload: []))
        XCTAssertEqual(GarminEpoch.garminSeconds(fromUnixSeconds: GarminEpoch.unixOffsetSeconds), 0)
        XCTAssertNil(GarminEpoch.garminSeconds(fromUnixSeconds: 0))
    }

    func testSessionHandshakeAdvertisesOnlyExplicitCapabilities() throws {
        let incoming = try GarminGFDI.decode(try GarminGFDI.encode(
            messageID: GarminGFDIMessageID.configuration.rawValue,
            payload: [4, 0xFB, 0xFF, 0x3F, 0xA6]
        ))
        let reply = try XCTUnwrap(GarminSessionResponder.reply(
            to: incoming,
            nowUnixSeconds: 1_800_000_000,
            timeZoneOffsetSeconds: -18_000,
            supportedCapabilities: []
        ))
        XCTAssertTrue(reply.configurationCompleted)
        XCTAssertEqual(reply.outgoing.count, 2)
        let config = try GarminGFDI.decode(reply.outgoing[0])
        XCTAssertEqual(config.messageID, GarminGFDIMessageID.configuration.rawValue)
        XCTAssertEqual(config.payload, [0])
        let ready = try GarminGFDI.decode(reply.outgoing[1])
        XCTAssertEqual(ready.messageID, GarminGFDIMessageID.systemEvent.rawValue)
        XCTAssertEqual(ready.payload, [GarminSessionResponder.syncReadyEvent])
    }

    func testSessionDeviceInfoTimeAndUnsupportedReplies() throws {
        let info = try GarminGFDI.decode(try GarminGFDI.encode(
            messageID: GarminGFDIMessageID.deviceInformation.rawValue,
            payload: [150, 0] + [UInt8](repeating: 0, count: 10)
        ))
        let infoReply = try XCTUnwrap(GarminSessionResponder.reply(
            to: info, nowUnixSeconds: 1_800_000_000, timeZoneOffsetSeconds: 0
        ))
        let infoResponse = try GarminGFDI.decode(try XCTUnwrap(infoReply.outgoing.first))
        XCTAssertEqual(infoResponse.responseToMessageID, GarminGFDIMessageID.deviceInformation.rawValue)
        XCTAssertEqual(infoResponse.status, .acknowledgement)

        let reference: [UInt8] = [0x78, 0x56, 0x34, 0x12]
        let time = try GarminGFDI.decode(try GarminGFDI.encode(
            messageID: GarminGFDIMessageID.currentTimeRequest.rawValue,
            payload: reference
        ))
        let timeReply = try XCTUnwrap(GarminSessionResponder.reply(
            to: time, nowUnixSeconds: 1_800_000_000, timeZoneOffsetSeconds: -18_000
        ))
        let timeResponse = try GarminGFDI.decode(try XCTUnwrap(timeReply.outgoing.first))
        XCTAssertEqual(Array(timeResponse.payload.dropFirst(3).prefix(4)), reference)

        let protobuf = try GarminGFDI.decode(try GarminGFDI.encode(
            messageID: GarminGFDIMessageID.protobufRequest.rawValue,
            payload: [5]
        ))
        let unsupported = try GarminGFDI.decode(try XCTUnwrap(
            GarminSessionResponder.reply(to: protobuf, nowUnixSeconds: 1_800_000_000,
                                         timeZoneOffsetSeconds: 0)?.outgoing.first
        ))
        XCTAssertEqual(unsupported.status, .unsupported)
    }
}
