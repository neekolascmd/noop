import XCTest
@testable import WhoopProtocol

final class PolarPMDTests: XCTestCase {
    private func le64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }

    private func frame(_ type: PolarPMDMeasurement,
                       timestamp: UInt64,
                       frameType: UInt8,
                       compressed: Bool = false,
                       payload: [UInt8]) -> [UInt8] {
        [type.rawValue] + le64(timestamp) + [frameType | (compressed ? 0x80 : 0)] + payload
    }

    func testFeatureAndCommandContract() throws {
        let features = try XCTUnwrap(PolarPMDFeatures(bytes: [0x0F, 0x0F, 0x00]))
        XCTAssertEqual(features.measurements, [.ecg, .ppg, .accelerometer, .ppi])
        XCTAssertEqual(PolarPMDCommand.querySettings(.ecg), [0x01, 0x00])
        XCTAssertEqual(PolarPMDCommand.stop(.ppi), [0x03, 0x03])
        XCTAssertEqual(
            try PolarPMDCommand.start(.accelerometer, selection: [
                .sampleRate: 200,
                .resolution: 16,
                .range: 8,
            ]),
            [
                0x02, 0x02,
                0x00, 0x01, 0xC8, 0x00,
                0x01, 0x01, 0x10, 0x00,
                0x02, 0x01, 0x08, 0x00,
            ]
        )
    }

    func testSettingsAndMultipartResponse() throws {
        let params: [UInt8] = [
            0x00, 0x02, 0x82, 0x00, 0xC8, 0x00, // rates: 130, 200
            0x01, 0x01, 0x10, 0x00,             // resolution: 16
            0x04, 0x01, 0x03,                   // channels: 3
            0x05, 0x01, 0x00, 0x00, 0x80, 0x3F,// factor: 1.0f
        ]
        let settings = try PolarPMDSettings(parameters: params)
        XCTAssertEqual(settings.numericOptions(.sampleRate), [130, 200])
        XCTAssertEqual(settings.maximumSelection[.sampleRate], 200)
        XCTAssertEqual(settings.factor, 1, accuracy: 0.000_001)

        var assembler = PolarPMDControlResponseAssembler()
        XCTAssertNil(try assembler.append([0xF0, 0x01, 0x02, 0x00, 0x01] + Array(params.prefix(8))))
        let complete = try XCTUnwrap(
            assembler.append([0xF0, 0x01, 0x02, 0x00, 0x00] + Array(params.dropFirst(8)))
        )
        XCTAssertEqual(complete.parameters, params)
        XCTAssertTrue(complete.succeeded)
        XCTAssertEqual(complete.measurement, .accelerometer)
    }

    func testSessionPlannerSerializesStartsAndSkipsRejectedStream() throws {
        let features = try XCTUnwrap(PolarPMDFeatures(bytes: [0x0F, 0x0F, 0x00]))
        var planner = PolarPMDSessionPlanner()
        var update = planner.begin(
            features: features,
            requested: [.ppi, .ecg, .gyroscope, .accelerometer]
        )
        XCTAssertEqual(update.command, [0x01, 0x03])

        // PPI advertises no settings and starts with the bare [2,3] command.
        update = planner.handle(try PolarPMDControlResponse(
            bytes: [0xF0, 0x01, 0x03, 0x00, 0x00]
        ))
        XCTAssertEqual(update.command, [0x02, 0x03])
        update = planner.handle(try PolarPMDControlResponse(
            bytes: [0xF0, 0x02, 0x03, 0x00, 0x00]
        ))
        XCTAssertEqual(update.started?.measurement, .ppi)
        XCTAssertEqual(update.command, [0x01, 0x00])

        // ECG settings query is rejected; the planner continues to ACC (gyro wasn't advertised).
        update = planner.handle(try PolarPMDControlResponse(
            bytes: [0xF0, 0x01, 0x00, 0x03]
        ))
        XCTAssertEqual(update.skipped, .ecg)
        XCTAssertEqual(update.command, [0x01, 0x02])

        let settings: [UInt8] = [0x00, 0x01, 0xC8, 0x00, 0x01, 0x01, 0x10, 0x00]
        update = planner.handle(try PolarPMDControlResponse(
            bytes: [0xF0, 0x01, 0x02, 0x00, 0x00] + settings
        ))
        XCTAssertEqual(update.command, [
            0x02, 0x02,
            0x00, 0x01, 0xC8, 0x00,
            0x01, 0x01, 0x10, 0x00,
        ])
        update = planner.handle(try PolarPMDControlResponse(
            bytes: [0xF0, 0x02, 0x02, 0x00, 0x00,
                    0x05, 0x01, 0x00, 0x00, 0x80, 0x3F]
        ))
        XCTAssertEqual(update.started?.measurement, .accelerometer)
        XCTAssertEqual(update.started?.startResponse?.factor, 1)
        XCTAssertTrue(update.finished)
    }

    func testSessionPlannerRejectsMalformedStartSettings() throws {
        let features = try XCTUnwrap(PolarPMDFeatures(bytes: [0x0F, 0x04, 0x00]))
        var planner = PolarPMDSessionPlanner()
        var update = planner.begin(features: features, requested: [.accelerometer])
        XCTAssertEqual(update.command, [0x01, 0x02])

        update = planner.handle(try PolarPMDControlResponse(
            bytes: [0xF0, 0x01, 0x02, 0x00, 0x00,
                    0x00, 0x01, 0xC8, 0x00]
        ))
        XCTAssertNotNil(update.command)

        update = planner.handle(try PolarPMDControlResponse(
            bytes: [0xF0, 0x02, 0x02, 0x00, 0x00,
                    0x05, 0x01, 0x00]
        ))
        XCTAssertNil(update.started)
        XCTAssertEqual(update.skipped, .accelerometer)
        XCTAssertTrue(update.finished)
    }

    func testECGType0Signed24AndTimestamps() throws {
        var decoder = PolarPMDDecoder()
        decoder.configure(.ecg, sampleRateHz: 2)
        let packet = frame(
            .ecg,
            timestamp: 2_000_000_000,
            frameType: 0,
            payload: [
                0xFE, 0xFF, 0xFF, // -2 µV
                0x02, 0x00, 0x00, // +2 µV
            ]
        )
        let decoded = try decoder.decode(packet)
        XCTAssertEqual(decoded.ecg.map(\.microVolts), [-2, 2])
        XCTAssertEqual(decoded.ecg.map(\.sensorTimestampNs), [1_500_000_000, 2_000_000_000])
    }

    func testRawPPGType0() throws {
        var decoder = PolarPMDDecoder()
        // The PMD start-response factor applies only to compressed PPG, not raw type-0.
        decoder.configure(.ppg, sampleRateHz: 1, factor: 2)
        let packet = frame(
            .ppg,
            timestamp: 3_000_000_000,
            frameType: 0,
            payload: [
                0x01, 0x00, 0x00,
                0xFE, 0xFF, 0xFF,
                0xFF, 0xFF, 0x7F,
                0x00, 0x00, 0x80,
            ]
        )
        let decoded = try decoder.decode(packet)
        XCTAssertEqual(decoded.ppg.count, 1)
        XCTAssertEqual(decoded.ppg[0].channels, [1, -2, 8_388_607])
        XCTAssertEqual(decoded.ppg[0].ambient, -8_388_608)
    }

    func testCompressedPPGType0AppliesFactor() throws {
        var decoder = PolarPMDDecoder()
        decoder.configure(.ppg, sampleRateHz: 1, factor: 2)
        let packet = frame(
            .ppg,
            timestamp: 3_000_000_000,
            frameType: 0,
            compressed: true,
            payload: [
                0x01, 0x00, 0x00,
                0xFE, 0xFF, 0xFF,
                0x03, 0x00, 0x00,
                0x04, 0x00, 0x00,
            ]
        )
        let decoded = try decoder.decode(packet)
        XCTAssertEqual(decoded.ppg[0].channels, [2, -4, 6])
        XCTAssertEqual(decoded.ppg[0].ambient, 8)
    }

    func testRawAccelerationWidths() throws {
        var decoder = PolarPMDDecoder()
        decoder.configure(.accelerometer, sampleRateHz: 2)
        let packet = frame(
            .accelerometer,
            timestamp: 1_000_000_000,
            frameType: 1,
            payload: [
                0x9C, 0xFF, // -100
                0x00, 0x00, // 0
                0xE8, 0x03, // 1000
            ]
        )
        let decoded = try decoder.decode(packet)
        XCTAssertEqual(decoded.acceleration, [
            PolarPMDAccelerationSample(
                sensorTimestampNs: 1_000_000_000,
                xMilliG: -100,
                yMilliG: 0,
                zMilliG: 1000
            )
        ])
    }

    func testPPIFieldsAndBackfilledTimestamps() throws {
        var decoder = PolarPMDDecoder()
        let packet = frame(
            .ppi,
            timestamp: 5_000_000_000,
            frameType: 0,
            payload: [
                60, 0xE8, 0x03, 10, 0, 0x06, // 1000 ms, contact supported+present
                75, 0x20, 0x03, 20, 0, 0x01, // 800 ms, blocked, contact unsupported
            ]
        )
        let decoded = try decoder.decode(packet)
        XCTAssertEqual(decoded.ppi.map(\.heartRate), [60, 75])
        XCTAssertEqual(decoded.ppi.map(\.intervalMs), [1000, 800])
        XCTAssertEqual(decoded.ppi.map(\.sensorTimestampNs), [4_200_000_000, 5_000_000_000])
        XCTAssertEqual(decoded.ppi[0].skinContact, true)
        XCTAssertNil(decoded.ppi[1].skinContact)
        XCTAssertTrue(decoded.ppi[1].blocker)
    }

    func testDeltaDecompressionLSBFirstAndAccumulation() throws {
        // Reference [100, -100] as signed 16-bit LE.
        // Two samples of 4-bit deltas:
        //   [+1, -2] => [101, -102] packed nibbles 0xE1
        //   [-1, +3] => [100,  -99] packed nibbles 0x3F
        let decoded = try PolarPMDDecoder.deltaSamples(
            [0x64, 0x00, 0x9C, 0xFF, 0x04, 0x02, 0xE1, 0x3F],
            channels: 2,
            resolution: 16
        )
        XCTAssertEqual(decoded, [[100, -100], [101, -102], [100, -99]])
    }

    func testCompressedAccelerationType1() throws {
        var decoder = PolarPMDDecoder()
        decoder.configure(.accelerometer, sampleRateHz: 10, factor: 1)
        // Reference [10,20,30], then one 4-bit delta vector [+1,-1,+2].
        let packet = frame(
            .accelerometer,
            timestamp: 1_000_000_000,
            frameType: 1,
            compressed: true,
            payload: [
                10, 0, 20, 0, 30, 0,
                4, 1, 0xF1, 0x02,
            ]
        )
        let decoded = try decoder.decode(packet)
        XCTAssertEqual(decoded.acceleration.map { [$0.xMilliG, $0.yMilliG, $0.zMilliG] },
                       [[10, 20, 30], [11, 19, 32]])
        XCTAssertEqual(decoded.acceleration.map(\.sensorTimestampNs),
                       [900_000_000, 1_000_000_000])
    }

    func testMalformedPacketsAreRejected() throws {
        XCTAssertThrowsError(try PolarPMDDataFrame(bytes: [0x00]))
        XCTAssertThrowsError(try PolarPMDSettings(parameters: [0x00, 0x02, 0x82]))
        XCTAssertThrowsError(
            try PolarPMDDecoder.deltaSamples([0, 0], channels: 3, resolution: 16)
        )

        var decoder = PolarPMDDecoder()
        decoder.configure(.ecg, sampleRateHz: 130)
        XCTAssertThrowsError(try decoder.decode(
            frame(.ecg, timestamp: 1, frameType: 0, payload: [1, 2])
        ))
    }

    func testClockUsesEpochOrStableReceiveAnchor() {
        var clock = PolarPMDClock()
        let receive = UInt64(1_800_000_000_000_000_000)
        let plausibleSensor = receive - PolarPMDClock.polarToUnixEpochNs
        XCTAssertEqual(
            clock.unixNanoseconds(sensorTimestampNs: plausibleSensor, receivedAtUnixNs: receive),
            receive
        )

        clock.reset()
        let first = clock.unixNanoseconds(sensorTimestampNs: 10, receivedAtUnixNs: receive)
        let second = clock.unixNanoseconds(sensorTimestampNs: 1_000_000_010,
                                           receivedAtUnixNs: receive + 2_000_000_000)
        XCTAssertEqual(first, receive)
        XCTAssertEqual(second, receive + 1_000_000_000)

        clock.reset()
        let staleSensor = plausibleSensor - 24 * 60 * 60 * 1_000_000_000
        XCTAssertEqual(
            clock.unixNanoseconds(sensorTimestampNs: staleSensor, receivedAtUnixNs: receive),
            receive
        )
    }

    func testClockBackfillsZeroTimestampPPIFromReceiveTime() {
        var clock = PolarPMDClock()
        let receive = UInt64(1_800_000_000_000_000_000)
        let samples = [
            PolarPMDPPISample(sensorTimestampNs: 0, heartRate: 60, intervalMs: 1_000,
                              errorEstimateMs: 0, blocker: false, skinContact: nil),
            PolarPMDPPISample(sensorTimestampNs: 0, heartRate: 75, intervalMs: 800,
                              errorEstimateMs: 0, blocker: false, skinContact: nil),
        ]
        XCTAssertEqual(
            clock.unixNanoseconds(ppiSamples: samples, receivedAtUnixNs: receive),
            [receive - 800_000_000, receive]
        )
        XCTAssertEqual(
            clock.unixNanoseconds(ppiSamples: samples, receivedAtUnixNs: receive + 2_000_000_000),
            [receive + 1_200_000_000, receive + 2_000_000_000]
        )
    }
}
