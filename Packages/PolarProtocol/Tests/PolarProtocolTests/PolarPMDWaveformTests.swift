import XCTest
@testable import PolarProtocol

final class PolarPMDWaveformTests: XCTestCase {
    func testECGChunksUseSignedInt32LittleEndian() throws {
        var buffer = PolarPMDWaveformBuffer()
        let emitted = try buffer.append(
            ecg: [
                PolarPMDECGSample(sensorTimestampNs: 10, microVolts: 1),
                PolarPMDECGSample(sensorTimestampNs: 20, microVolts: -2),
            ],
            unixTimestampsNs: [1_000_000_000, 1_010_000_000],
            sampleRateHz: 100
        )
        XCTAssertTrue(emitted.isEmpty)

        let chunk = try XCTUnwrap(buffer.flush().single)
        XCTAssertEqual(chunk.kind, .ecg)
        XCTAssertEqual(chunk.startUnixNs, 1_000_000_000)
        XCTAssertEqual(chunk.endUnixNs, 1_010_000_000)
        XCTAssertEqual(chunk.sampleRateHz, 100)
        XCTAssertEqual(chunk.channels, 1)
        XCTAssertEqual(chunk.sampleCount, 2)
        XCTAssertEqual(chunk.payload, [
            0x01, 0x00, 0x00, 0x00,
            0xFE, 0xFF, 0xFF, 0xFF,
        ])
    }

    func testPPGChunksInterleaveThreeChannelsAndAmbient() throws {
        var buffer = PolarPMDWaveformBuffer()
        _ = try buffer.append(
            ppg: [
                PolarPMDPPGSample(
                    sensorTimestampNs: 10,
                    channels: [1, 2, 3],
                    ambient: 4
                ),
            ],
            unixTimestampsNs: [2_000_000_000],
            sampleRateHz: 135
        )

        let chunk = try XCTUnwrap(buffer.flush().single)
        XCTAssertEqual(chunk.kind, .ppg)
        XCTAssertEqual(chunk.channels, 4)
        XCTAssertEqual(chunk.sampleCount, 1)
        XCTAssertEqual(chunk.payload, [
            0x01, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00,
            0x04, 0x00, 0x00, 0x00,
        ])
    }

    func testFiveSecondBoundaryEmitsPriorChunk() throws {
        var buffer = PolarPMDWaveformBuffer()
        let emitted = try buffer.append(
            ecg: [
                PolarPMDECGSample(sensorTimestampNs: 1, microVolts: 10),
                PolarPMDECGSample(sensorTimestampNs: 2, microVolts: 20),
            ],
            unixTimestampsNs: [
                1_000_000_000,
                1_000_000_000 + PolarPMDWaveformBuffer.targetDurationNs,
            ],
            sampleRateHz: 130
        )

        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0].sampleCount, 1)
        XCTAssertEqual(buffer.flush().single?.sampleCount, 1)
    }

    func testNonIncreasingTimestampsAreRejected() throws {
        var buffer = PolarPMDWaveformBuffer()
        XCTAssertThrowsError(try buffer.append(
            ecg: [
                PolarPMDECGSample(sensorTimestampNs: 1, microVolts: 10),
                PolarPMDECGSample(sensorTimestampNs: 2, microVolts: 20),
            ],
            unixTimestampsNs: [1_000_000_000, 1_000_000_000],
            sampleRateHz: 130
        ))
    }
}

private extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}
