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
            firstSeenAtUnixMs: 1_700_000_000_000
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

    func testPageDecoderRevisionEightRecoversMotionSpO2ActivityAndAlwaysOnHRDiagnostics() {
        XCTAssertEqual(OuraRawHistoryDecoderRevision.current, 8)
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
        let exerciseIntensity = StoredOuraRawHistoryRecord(
            archiveId: 5,
            tag: OuraEventTag.exerciseHRIntensity.rawValue,
            ringTimestamp: 500,
            payload: Data([0x34, 0x12, 0xFF, 0x00]),
            firstSeenAtUnixMs: 1,
            timeAnchor: anchor
        )
        let realSteps = StoredOuraRawHistoryRecord(
            archiveId: 6,
            tag: OuraEventTag.realSteps1.rawValue,
            ringTimestamp: 400,
            payload: Data([0x01, 0x02, 0x03, 0x84, 0x05, 0x06, 0x07, 0x08,
                           0x09, 0x0A, 0x0B, 0x8C, 0x0D, 0x0E]),
            firstSeenAtUnixMs: 1,
            timeAnchor: anchor
        )
        let alwaysOnHR = StoredOuraRawHistoryRecord(
            archiveId: 7,
            tag: OuraEventTag.alwaysOnHR.rawValue,
            ringTimestamp: 300,
            payload: Data([0x81, 0x05, 0x03, 60, 1, 61, 2, 62, 3]),
            firstSeenAtUnixMs: 1,
            timeAnchor: anchor
        )

        let decoded = OuraRawHistoryPageDecoder.decode(
            [motion, sleepAcm, spo2, activity, exerciseIntensity, realSteps, alwaysOnHR], ringGen: .gen4
        )
        XCTAssertEqual(decoded.withheldEvents, 0)
        XCTAssertEqual(decoded.streams.events.map(\.kind), [
            OuraStreamMapping.motionSummaryEventKind,
            OuraStreamMapping.sleepAcmPeriodEventKind,
            OuraStreamMapping.spo2RatioEventKind,
            OuraStreamMapping.activityMetSeriesEventKind,
            OuraStreamMapping.exerciseHRIntensityEventKind,
            OuraStreamMapping.realStepsFeaturesEventKind,
            OuraStreamMapping.alwaysOnHRSeriesEventKind,
        ])
        XCTAssertEqual(decoded.streams.events[0].ts, 1_699_999_990)
        XCTAssertEqual(decoded.streams.events[1].ts, 1_699_999_970)
        XCTAssertEqual(decoded.streams.events[2].ts, 1_699_999_980)
        XCTAssertEqual(decoded.streams.events[3].ts, 1_699_999_960)
        XCTAssertEqual(decoded.streams.events[3].payload["met_x10"], .intArray([18, 19, 74]))
        XCTAssertEqual(decoded.streams.events[4].ts, 1_699_999_950)
        XCTAssertEqual(decoded.streams.events[4].payload["intensity_u16"], .intArray([0x1234, 0x00FF]))
        XCTAssertEqual(decoded.streams.events[5].ts, 1_699_999_940)
        XCTAssertEqual(decoded.streams.events[5].payload["feature_fields_u16"],
                       .intArray([3, 4, 6, 4, 5, 6, 7, 8, 19, 20, 22, 12, 13, 14]))
        XCTAssertEqual(decoded.streams.events[6].ts, 1_699_999_930)
        XCTAssertEqual(decoded.streams.events[6].payload["bpm_u8"], .intArray([60, 61, 62]))
        XCTAssertEqual(decoded.streams.events[6].payload["quality_u8"], .intArray([1, 2, 3]))
        XCTAssertEqual(decoded.streams.spo2, [
            SpO2Sample(
                ts: 1_699_999_980,
                red: 932,
                ir: 0,
                unit: OuraStreamMapping.estimatedSpO2Unit
            ),
        ])
    }

    func testRevisionEightPersistsSleepNetNightAcrossReplayPages() async throws {
        let store = try await WhoopStore.inMemory()
        let eventTime = 1_700_000_000
        let anchor = OuraTimeAnchor(
            ringTimestamp: 10_000,
            utcMilliseconds: Int64(eventTime) * 1_000,
            factorMillisecondsPerTick: 100
        )
        let sleepWindow = OuraRecord(
            type: OuraEventTag.sleepSummary1.rawValue,
            ringTimestamp: 10_000,
            payload: [0xE0, 0x01, 0x00, 0x00] // event-480 min through event-0 min
        )
        // 2 x 480 codes = 960 30-second epochs = exactly eight hours. With pageSize=1 the phase
        // burst necessarily crosses two database pages and must still become one session.
        let phasePayload = [UInt8(0x07)] + Array(repeating: UInt8(0x1B), count: 120)
        let firstPhase = OuraRecord(
            type: OuraEventTag.sleepPhaseInfo.rawValue,
            ringTimestamp: 9_950,
            payload: phasePayload
        )
        let secondPhase = OuraRecord(
            type: OuraEventTag.sleepPhase.rawValue,
            ringTimestamp: 9_951,
            payload: phasePayload
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [sleepWindow, firstPhase, secondPhase],
            deviceId: "ring-4",
            firstSeenAtUnixMs: 1,
            timeAnchor: anchor
        )

        let report = try await store.redecodeOuraRawHistory(
            deviceId: "ring-4",
            ringGen: .gen4,
            pageSize: 1
        )
        XCTAssertEqual(report.decodedRecords, 3)
        XCTAssertEqual(report.sleepSessions, 1)

        let sessions = try await store.sleepSessions(
            deviceId: "ring-4",
            from: eventTime - 24 * 60 * 60,
            to: eventTime + 1,
            limit: 10
        )
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(
            session.startTs,
            OuraSleepNetPersistencePolicy.stableStartUnixSeconds(eventTime - 8 * 60 * 60)
        )
        XCTAssertEqual(session.endTs, eventTime)
        XCTAssertEqual(try XCTUnwrap(session.efficiency), 0.75, accuracy: 0.000_001)
        XCTAssertTrue(session.stagesJSON?.hasPrefix("[{\"start\":") == true)
        XCTAssertTrue(session.stagesJSON?.contains("\"stage\":\"wake\"") == true)

        let computed = try await store.sleepSessions(
            deviceId: "ring-4-noop",
            from: eventTime - 24 * 60 * 60,
            to: eventTime + 1,
            limit: 10
        )
        XCTAssertTrue(computed.isEmpty, "ring-provided SleepNet staging belongs to the ring namespace")
        let secondReport = try await store.redecodeOuraRawHistory(
            deviceId: "ring-4",
            ringGen: .gen4
        )
        XCTAssertEqual(secondReport, OuraRawHistoryRedecodeReport())
    }

    func testPartialSleepNetDrainWaitsForLaterArchivedTail() async throws {
        let store = try await WhoopStore.inMemory()
        let eventTime = 1_700_100_000
        let anchor = OuraTimeAnchor(
            ringTimestamp: 20_000,
            utcMilliseconds: Int64(eventTime) * 1_000,
            factorMillisecondsPerTick: 100
        )
        let sleepWindow = OuraRecord(
            type: OuraEventTag.sleepSummary1.rawValue,
            ringTimestamp: 20_000,
            payload: [0xE0, 0x01, 0x00, 0x00]
        )
        let phasePayload = [UInt8(0x07)] + Array(repeating: UInt8(0x1B), count: 120)
        let firstHalf = OuraRecord(
            type: OuraEventTag.sleepPhaseInfo.rawValue,
            ringTimestamp: 19_950,
            payload: phasePayload
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [sleepWindow, firstHalf],
            deviceId: "ring-tail",
            firstSeenAtUnixMs: 1,
            timeAnchor: anchor
        )

        let partialReport = try await store.redecodeOuraRawHistory(
            deviceId: "ring-tail",
            ringGen: .gen4,
            pageSize: 1
        )
        XCTAssertEqual(partialReport.sleepSessions, 0)
        let partialSessions = try await store.sleepSessions(
            deviceId: "ring-tail",
            from: eventTime - 24 * 60 * 60,
            to: eventTime + 1,
            limit: 10
        )
        XCTAssertTrue(partialSessions.isEmpty)

        let secondHalf = OuraRecord(
            type: OuraEventTag.sleepPhase.rawValue,
            ringTimestamp: 19_951,
            payload: phasePayload
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [secondHalf],
            deviceId: "ring-tail",
            firstSeenAtUnixMs: 2,
            timeAnchor: anchor
        )
        let completedReport = try await store.redecodeOuraRawHistory(
            deviceId: "ring-tail",
            ringGen: .gen4,
            pageSize: 1
        )
        XCTAssertEqual(completedReport.sleepSessions, 1)
        let sessions = try await store.sleepSessions(
            deviceId: "ring-tail",
            from: eventTime - 24 * 60 * 60,
            to: eventTime + 1,
            limit: 10
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertNotNil(sessions.first?.stagesJSON)
    }

    func testCompleteBurstWithErasedSlotsPersistsGapsWithoutEfficiency() async throws {
        let store = try await WhoopStore.inMemory()
        let eventTime = 1_700_200_000
        let anchor = OuraTimeAnchor(
            ringTimestamp: 30_000,
            utcMilliseconds: Int64(eventTime) * 1_000,
            factorMillisecondsPerTick: 100
        )
        let sleepWindow = OuraRecord(
            type: OuraEventTag.sleepSummary1.rawValue,
            ringTimestamp: 30_000,
            payload: [0xE0, 0x01, 0x00, 0x00]
        )
        let writtenPage = OuraRecord(
            type: OuraEventTag.sleepPhaseInfo.rawValue,
            ringTimestamp: 29_950,
            payload: [0x07] + Array(repeating: UInt8(0x1B), count: 120)
        )
        let erasedPage = OuraRecord(
            type: OuraEventTag.sleepPhase.rawValue,
            ringTimestamp: 29_951,
            payload: [0x07] + Array(repeating: UInt8(0xFF), count: 120)
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [sleepWindow, writtenPage, erasedPage],
            deviceId: "ring-gaps",
            timeAnchor: anchor
        )

        let report = try await store.redecodeOuraRawHistory(
            deviceId: "ring-gaps",
            ringGen: .gen4,
            pageSize: 1
        )
        XCTAssertEqual(report.sleepSessions, 1)
        let sessions = try await store.sleepSessions(
            deviceId: "ring-gaps",
            from: eventTime - 24 * 60 * 60,
            to: eventTime + 1,
            limit: 10
        )
        let session = try XCTUnwrap(sessions.first)
        XCTAssertNotNil(session.stagesJSON)
        XCTAssertNil(session.efficiency, "large honest flash gaps must not become a complete metric")
    }

    func testLaterNonSleepAnchorReopensPreviouslyWithheldSleepNetRows() async throws {
        let store = try await WhoopStore.inMemory()
        let eventTime = 1_700_300_000
        let captureSeenAtUnixMs: Int64 = 1_800_000_000_000
        let sleepWindow = OuraRecord(
            type: OuraEventTag.sleepSummary1.rawValue,
            ringTimestamp: 40_000,
            payload: [0xE0, 0x01, 0x00, 0x00]
        )
        let phasePayload = [UInt8(0x07)] + Array(repeating: UInt8(0x1B), count: 120)
        let firstPhase = OuraRecord(
            type: OuraEventTag.sleepPhaseInfo.rawValue,
            ringTimestamp: 39_950,
            payload: phasePayload
        )
        let secondPhase = OuraRecord(
            type: OuraEventTag.sleepPhase.rawValue,
            ringTimestamp: 39_951,
            payload: phasePayload
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [sleepWindow, firstPhase, secondPhase],
            deviceId: "ring-late-anchor",
            firstSeenAtUnixMs: captureSeenAtUnixMs
        )
        let withheld = try await store.redecodeOuraRawHistory(
            deviceId: "ring-late-anchor",
            ringGen: .gen4,
            pageSize: 1
        )
        XCTAssertEqual(withheld.sleepSessions, 0)

        let anchor = OuraTimeAnchor(
            ringTimestamp: 40_000,
            utcMilliseconds: Int64(eventTime) * 1_000,
            factorMillisecondsPerTick: 100
        )
        let anchorCarrier = OuraRecord(
            type: OuraEventTag.stateChange.rawValue,
            ringTimestamp: 40_001,
            payload: [50]
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [anchorCarrier],
            deviceId: "ring-late-anchor",
            firstSeenAtUnixMs: captureSeenAtUnixMs + 1_000,
            timeAnchor: anchor
        )
        let recovered = try await store.redecodeOuraRawHistory(
            deviceId: "ring-late-anchor",
            ringGen: .gen4,
            pageSize: 1
        )
        XCTAssertEqual(recovered.sleepSessions, 1)
        let sessions = try await store.sleepSessions(
            deviceId: "ring-late-anchor",
            from: eventTime - 24 * 60 * 60,
            to: eventTime + 1,
            limit: 10
        )
        XCTAssertEqual(sessions.count, 1)
    }

    func testLateAnchorDoesNotCrossADifferentReceiptCohortWithoutResetMarker() async throws {
        let store = try await WhoopStore.inMemory()
        let oldSeenAtUnixMs: Int64 = 1_800_000_000_000
        let currentEventTime = 1_800_086_400
        let sleepWindow = OuraRecord(
            type: OuraEventTag.sleepSummary1.rawValue,
            ringTimestamp: 40_000,
            payload: [0xE0, 0x01, 0x00, 0x00]
        )
        let phasePayload = [UInt8(0x07)] + Array(repeating: UInt8(0x1B), count: 120)
        let firstPhase = OuraRecord(
            type: OuraEventTag.sleepPhaseInfo.rawValue,
            ringTimestamp: 39_950,
            payload: phasePayload
        )
        let secondPhase = OuraRecord(
            type: OuraEventTag.sleepPhase.rawValue,
            ringTimestamp: 39_951,
            payload: phasePayload
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [sleepWindow, firstPhase, secondPhase],
            deviceId: "ring-missing-reset",
            firstSeenAtUnixMs: oldSeenAtUnixMs
        )

        // The new clock session reused similar raw ticks, but the reset marker was not retained.
        let currentAnchor = OuraTimeAnchor(
            ringTimestamp: 40_000,
            utcMilliseconds: Int64(currentEventTime) * 1_000,
            factorMillisecondsPerTick: 100
        )
        let carrier = OuraRecord(
            type: OuraEventTag.stateChange.rawValue,
            ringTimestamp: 40_001,
            payload: [50]
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [carrier],
            deviceId: "ring-missing-reset",
            firstSeenAtUnixMs: oldSeenAtUnixMs + 24 * 60 * 60 * 1_000,
            timeAnchor: currentAnchor
        )

        let report = try await store.redecodeOuraRawHistory(
            deviceId: "ring-missing-reset",
            ringGen: .gen4,
            pageSize: 1
        )
        XCTAssertEqual(report.sleepSessions, 0)
        let rows = try await store.ouraRawHistoryRecords(deviceId: "ring-missing-reset")
        XCTAssertTrue(rows.prefix(3).allSatisfy { $0.timeAnchor == nil })
    }

    func testAnchorBackfillRejectsProjectionTooFarAfterReceipt() async throws {
        let store = try await WhoopStore.inMemory()
        let receiptSeconds: Int64 = 1_800_000_000
        let receiptMilliseconds = receiptSeconds * 1_000
        let futureTemperature = OuraRecord(
            type: OuraEventTag.temp.rawValue,
            ringTimestamp: 50_000,
            payload: [0x42, 0x0E]
        )
        let sync = OuraRecord(
            type: OuraEventTag.timeSync.rawValue,
            ringTimestamp: 40_000,
            payload: le8(receiptSeconds) + [0]
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [futureTemperature, sync],
            deviceId: "ring-future-projection",
            firstSeenAtUnixMs: receiptMilliseconds
        )

        let report = try await store.redecodeOuraRawHistory(
            deviceId: "ring-future-projection",
            ringGen: .gen3,
            pageSize: 1
        )
        XCTAssertEqual(report.anchorRowsBackfilled, 1, "only the anchor carrier is safe")
        let rows = try await store.ouraRawHistoryRecords(deviceId: "ring-future-projection")
        XCTAssertNil(rows.first?.timeAnchor)
        XCTAssertNotNil(rows.last?.timeAnchor)
        XCTAssertEqual(report.insertedRows, 0)
        XCTAssertEqual(report.withheldEvents, 1)
    }

    func testAnchorBackfillPropagatesForwardAcrossSeparateInsertsInSameReceiptCohort() async throws {
        let store = try await WhoopStore.inMemory()
        let receiptSeconds: Int64 = 1_800_000_000
        let receiptMilliseconds = receiptSeconds * 1_000
        let sync = OuraRecord(
            type: OuraEventTag.timeSync.rawValue,
            ringTimestamp: 40_000,
            payload: le8(receiptSeconds - 3_600) + [0]
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [sync],
            deviceId: "ring-forward-anchor",
            firstSeenAtUnixMs: receiptMilliseconds
        )

        let laterTemperature = OuraRecord(
            type: OuraEventTag.temp.rawValue,
            ringTimestamp: 40_001,
            payload: [0x42, 0x0E]
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [laterTemperature],
            deviceId: "ring-forward-anchor",
            firstSeenAtUnixMs: receiptMilliseconds + 1_000
        )

        let report = try await store.redecodeOuraRawHistory(
            deviceId: "ring-forward-anchor",
            ringGen: .gen3,
            pageSize: 1
        )
        XCTAssertEqual(report.anchorRowsBackfilled, 2)
        XCTAssertEqual(report.insertedRows, 1)
        let rows = try await store.ouraRawHistoryRecords(deviceId: "ring-forward-anchor")
        XCTAssertNotNil(rows[0].timeAnchor)
        XCTAssertNotNil(rows[1].timeAnchor)
    }

    func testForwardAnchorBackfillKeepsEligiblePrefixBeforeOutOfCohortTail() async throws {
        let store = try await WhoopStore.inMemory()
        let receiptSeconds: Int64 = 1_800_000_000
        let receiptMilliseconds = receiptSeconds * 1_000
        let sync = OuraRecord(
            type: OuraEventTag.timeSync.rawValue,
            ringTimestamp: 40_000,
            payload: le8(receiptSeconds - 3_600) + [0]
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [sync], deviceId: "ring-forward-boundary", firstSeenAtUnixMs: receiptMilliseconds
        )
        let eligible = OuraRecord(
            type: OuraEventTag.temp.rawValue,
            ringTimestamp: 40_001,
            payload: [0x42, 0x0E]
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [eligible],
            deviceId: "ring-forward-boundary",
            firstSeenAtUnixMs: receiptMilliseconds + 1_000
        )
        let outOfCohort = OuraRecord(
            type: OuraEventTag.temp.rawValue,
            ringTimestamp: 40_002,
            payload: [0x43, 0x0E]
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [outOfCohort],
            deviceId: "ring-forward-boundary",
            firstSeenAtUnixMs: receiptMilliseconds + 11 * 60 * 1_000
        )
        let afterBoundary = OuraRecord(
            type: OuraEventTag.temp.rawValue,
            ringTimestamp: 40_003,
            payload: [0x44, 0x0E]
        )
        _ = try await store.insertOuraRawHistoryRecords(
            [afterBoundary],
            deviceId: "ring-forward-boundary",
            // A local-clock correction cannot make a row beyond the ambiguous boundary safe again.
            firstSeenAtUnixMs: receiptMilliseconds + 2_000
        )

        let report = try await store.redecodeOuraRawHistory(
            deviceId: "ring-forward-boundary", ringGen: .gen3, pageSize: 3
        )
        XCTAssertEqual(report.anchorRowsBackfilled, 2, "carrier and eligible prefix only")
        let rows = try await store.ouraRawHistoryRecords(deviceId: "ring-forward-boundary")
        XCTAssertNotNil(rows[0].timeAnchor)
        XCTAssertNotNil(rows[1].timeAnchor)
        XCTAssertNil(rows[2].timeAnchor)
        XCTAssertNil(rows[3].timeAnchor)
    }

    func testSleepNetWindowPairingUsesClosestCandidateWithinTenMinutes() {
        let candidates = [
            OuraSleepNetWindowCandidate(
                ringTimestamp: 1_000,
                eventUnixSeconds: 100_000,
                startUnixSeconds: 10,
                endUnixSeconds: 20
            ),
            OuraSleepNetWindowCandidate(
                ringTimestamp: 1_500,
                eventUnixSeconds: 200_000,
                startUnixSeconds: 30,
                endUnixSeconds: 40
            ),
        ]
        XCTAssertEqual(
            OuraSleepNetWindowPairing.closest(
                to: 1_450,
                envelopeUnixSeconds: 200_010,
                in: candidates
            ),
            candidates[1]
        )
        XCTAssertNil(
            OuraSleepNetWindowPairing.closest(
                to: 1_000,
                envelopeUnixSeconds: 200_000,
                in: [candidates[0]]
            ),
            "similar ring ticks from a different clock session must not pair"
        )
        XCTAssertNil(
            OuraSleepNetWindowPairing.closest(
                to: 10_000,
                envelopeUnixSeconds: 200_000,
                in: candidates
            )
        )
    }
}
