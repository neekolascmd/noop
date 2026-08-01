import OuraProtocol
import XCTest
import WhoopProtocol
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

    func testPageDecoderReplaysCompleteSleepPhaseSeriesAtomically() {
        let anchor = OuraTimeAnchor(
            ringTimestamp: 1_000,
            utcMilliseconds: 1_700_000_000_000,
            factorMillisecondsPerTick: 100
        )
        let row = StoredOuraRawHistoryRecord(
            archiveId: 1,
            tag: OuraEventTag.sleepPhase.rawValue,
            ringTimestamp: 900,
            payload: Data([0x07, 0x1B]),
            firstSeenAtUnixMs: 1,
            timeAnchor: anchor
        )

        let decoded = OuraRawHistoryPageDecoder.decode([row], ringGen: .gen3)
        XCTAssertEqual(decoded.withheldEvents, 0)
        XCTAssertEqual(decoded.streams.events.count, 1)
        let event = decoded.streams.events[0]
        XCTAssertEqual(event.kind, "OURA_SLEEP_PHASE_SERIES")
        XCTAssertEqual(event.ts, 1_699_999_990)
        XCTAssertEqual(event.payload["source_tag"], .int(0x4E))
        XCTAssertEqual(event.payload["header"], .int(7))
        XCTAssertEqual(event.payload["phase_codes"], .intArray([0, 1, 2, 3]))
        XCTAssertNil(event.payload["cadence_seconds"])
    }

    func testPageDecoderRevisionFiveRecoversMotionSpO2AndActivityDiagnostics() {
        XCTAssertEqual(OuraRawHistoryDecoderRevision.current, 5)
        let anchor = OuraTimeAnchor(
            ringTimestamp: 1_000,
            utcMilliseconds: 1_700_000_000_000,
            factorMillisecondsPerTick: 100
        )
        let motion = StoredOuraRawHistoryRecord(
            archiveId: 1,
            tag: OuraEventTag.motion.rawValue,
            ringTimestamp: 900,
            payload: Data([0xB1, 0x01, 0xFE, 0x7F, 0x85, 0x06]),
            firstSeenAtUnixMs: 1,
            timeAnchor: anchor
        )
        let sleepAcm = StoredOuraRawHistoryRecord(
            archiveId: 2,
            tag: OuraEventTag.sleepAcmPeriod.rawValue,
            ringTimestamp: 700,
            payload: Data([0x80, 0x02, 0x00, 0x03, 0xFF, 0x04,
                           0x00, 0x50, 0xFF, 0x0F, 0x00, 0xA8]),
            firstSeenAtUnixMs: 1,
            timeAnchor: anchor
        )
        let spo2 = StoredOuraRawHistoryRecord(
            archiveId: 3,
            tag: OuraEventTag.spo2RatioPI.rawValue,
            ringTimestamp: 800,
            payload: Data([0x00, 0x30, 0x00, 0x80, 0x33, 0x33, 0x40]),
            firstSeenAtUnixMs: 1,
            timeAnchor: anchor
        )
        let activity = StoredOuraRawHistoryRecord(
            archiveId: 4,
            tag: OuraEventTag.activityInfo.rawValue,
            ringTimestamp: 600,
            payload: Data([0x41, 0x12, 0x13, 0x4A]),
            firstSeenAtUnixMs: 1,
            timeAnchor: anchor
        )

        let decoded = OuraRawHistoryPageDecoder.decode(
            [motion, sleepAcm, spo2, activity], ringGen: .gen4
        )
        XCTAssertEqual(decoded.withheldEvents, 0)
        XCTAssertEqual(decoded.streams.events.map(\.kind), [
            OuraStreamMapping.motionSummaryEventKind,
            OuraStreamMapping.sleepAcmPeriodEventKind,
            OuraStreamMapping.spo2RatioEventKind,
            OuraStreamMapping.activityMetSeriesEventKind,
        ])
        XCTAssertEqual(decoded.streams.events[0].ts, 1_699_999_990)
        XCTAssertEqual(decoded.streams.events[1].ts, 1_699_999_970)
        XCTAssertEqual(decoded.streams.events[2].ts, 1_699_999_980)
        XCTAssertEqual(decoded.streams.events[3].ts, 1_699_999_960)
        XCTAssertEqual(decoded.streams.events[3].payload["met_x10"], .intArray([18, 19, 74]))
        XCTAssertEqual(decoded.streams.spo2, [
            SpO2Sample(
                ts: 1_699_999_980,
                red: 932,
                ir: 0,
                unit: OuraStreamMapping.estimatedSpO2Unit
            ),
        ])
    }
}
