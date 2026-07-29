import OuraProtocol
import XCTest
@testable import WhoopStore

final class OuraRawHistoryRedecoderTests: XCTestCase {
    private func le8(_ value: Int64) -> [UInt8] {
        (0..<8).map {
            UInt8((UInt64(bitPattern: value) >> (8 * UInt64($0))) & 0xFF)
        }
    }

    func testMigratedRowsBackfillAnchorAndReplayOfflineIdempotently() async throws {
        let store = try await WhoopStore.inMemory()
        let temperature = OuraRecord(
            type: OuraEventTag.temp.rawValue,
            ringTimestamp: 900,
            payload: [0x42, 0x0E] // 3650 / 100 = 36.5 C
        )
        let sync = OuraRecord(
            type: OuraEventTag.timeSync.rawValue,
            ringTimestamp: 1_000,
            payload: le8(1_700_000_000) + [0]
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [temperature, sync],
            deviceId: "ring-3",
            firstSeenAtUnixMs: 1
        )

        let first = try await store.redecodeOuraRawHistory(
            deviceId: "ring-3",
            ringGen: .gen3,
            pageSize: 1
        )
        XCTAssertEqual(first.decodedRecords, 2)
        XCTAssertEqual(first.insertedRows, 1)
        XCTAssertEqual(first.anchorRowsBackfilled, 2)
        XCTAssertEqual(first.withheldEvents, 0)
        let counts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.skinTemp, 1)

        let rows = try await store.ouraRawHistoryRecords(deviceId: "ring-3")
        XCTAssertTrue(rows.allSatisfy { $0.timeAnchor != nil })
        XCTAssertTrue(
            rows.allSatisfy {
                $0.decodedRevision == OuraRawHistoryDecoderRevision.current
            }
        )

        let second = try await store.redecodeOuraRawHistory(
            deviceId: "ring-3",
            ringGen: .gen3
        )
        XCTAssertEqual(second, OuraRawHistoryRedecodeReport())
    }

    func testPageDecoderMapsBedtimeBoundsAndWithholdsUnanchoredData() {
        let anchor = OuraTimeAnchor(
            ringTimestamp: 10_000,
            utcMilliseconds: 1_700_000_000_000,
            factorMillisecondsPerTick: 100
        )
        let bedtime = StoredOuraRawHistoryRecord(
            archiveId: 1,
            tag: OuraEventTag.bedtimePeriod.rawValue,
            ringTimestamp: 10_000,
            payload: Data([
                0xE8, 0x03, 0x00, 0x00, // start rt 1,000
                0x10, 0x27, 0x00, 0x00, // end rt 10,000 (15 minutes)
            ]),
            firstSeenAtUnixMs: 1,
            timeAnchor: anchor
        )
        let temperatureWithoutAnchor = StoredOuraRawHistoryRecord(
            archiveId: 2,
            tag: OuraEventTag.temp.rawValue,
            ringTimestamp: 10_000,
            payload: Data([0x42, 0x0E]),
            firstSeenAtUnixMs: 1
        )
        let decoded = OuraRawHistoryPageDecoder.decode(
            [bedtime, temperatureWithoutAnchor],
            ringGen: .gen3
        )
        XCTAssertEqual(decoded.sleepWindows.count, 1)
        XCTAssertEqual(decoded.sleepWindows[0].end - decoded.sleepWindows[0].start, 15 * 60)
        XCTAssertEqual(decoded.withheldEvents, 1)
        XCTAssertTrue(decoded.streams.isEmpty)
    }
}
