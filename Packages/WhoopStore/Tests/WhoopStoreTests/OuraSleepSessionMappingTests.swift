import OuraProtocol
import XCTest
@testable import WhoopStore

final class OuraSleepSessionMappingTests: XCTestCase {
    func testEmptyAndInvalidEpochsDoNotCreateNight() {
        XCTAssertNil(OuraSleepSessionMapping.session(from: []))
        XCTAssertNil(
            OuraSleepSessionMapping.session(
                from: [OuraHypnogramEpoch(stage: .deep, ts: 100)],
                secondsPerEpoch: 0
            )
        )
    }

    func testBuildsMergedStageTimelineAndEfficiency() throws {
        let session = try XCTUnwrap(
            OuraSleepSessionMapping.session(from: [
                OuraHypnogramEpoch(stage: .deep, ts: 1_000),
                OuraHypnogramEpoch(stage: .deep, ts: 1_030),
                OuraHypnogramEpoch(stage: .light, ts: 1_060),
                OuraHypnogramEpoch(stage: .rem, ts: 1_090),
                OuraHypnogramEpoch(stage: .awake, ts: 1_120),
                OuraHypnogramEpoch(stage: .awake, ts: 1_150),
            ])
        )

        XCTAssertEqual(session.startTs, 1_000)
        XCTAssertEqual(session.endTs, 1_180)
        XCTAssertEqual(try XCTUnwrap(session.efficiency), 4.0 / 6.0, accuracy: 0.000_001)
        XCTAssertNil(session.restingHr)
        XCTAssertNil(session.avgHrv)
        XCTAssertEqual(
            session.stagesJSON,
            "[{\"start\":1000,\"end\":1060,\"stage\":\"deep\"}," +
                "{\"start\":1060,\"end\":1090,\"stage\":\"light\"}," +
                "{\"start\":1090,\"end\":1120,\"stage\":\"rem\"}," +
                "{\"start\":1120,\"end\":1180,\"stage\":\"wake\"}]"
        )
    }

    func testGapDoesNotMergeEqualStages() throws {
        let session = try XCTUnwrap(
            OuraSleepSessionMapping.session(from: [
                OuraHypnogramEpoch(stage: .light, ts: 1_000),
                OuraHypnogramEpoch(stage: .light, ts: 1_090),
            ])
        )
        XCTAssertEqual(
            session.stagesJSON,
            "[{\"start\":1000,\"end\":1030,\"stage\":\"light\"}," +
                "{\"start\":1090,\"end\":1120,\"stage\":\"light\"}]"
        )
    }

    func testValidatedWindowOverridesSparseStageBounds() throws {
        let session = try XCTUnwrap(
            OuraSleepSessionMapping.session(
                from: [
                    OuraHypnogramEpoch(stage: .light, ts: 1_030),
                    OuraHypnogramEpoch(stage: .rem, ts: 1_060),
                ],
                sessionStartUnixSeconds: 1_000,
                sessionEndUnixSeconds: 1_120
            )
        )
        XCTAssertEqual(session.startTs, 1_000)
        XCTAssertEqual(session.endTs, 1_120)
        XCTAssertNil(
            OuraSleepSessionMapping.session(
                from: [OuraHypnogramEpoch(stage: .light, ts: 1_030)],
                sessionStartUnixSeconds: 1_120,
                sessionEndUnixSeconds: 1_000
            )
        )
    }

    func testStructuralCompletenessIsSeparateFromObservedCoverage() throws {
        XCTAssertEqual(OuraSleepNetPersistencePolicy.stableStartUnixSeconds(1_000), 1_020)

        let nineteenEpochs = (0 ..< 19).map {
            OuraHypnogramEpoch(stage: .light, ts: 1_020 + $0 * 30)
        }
        XCTAssertFalse(
            OuraSleepNetPersistencePolicy.structurallySpansWindow(
                totalCodeSlots: 19,
                startUnixSeconds: 1_020,
                endUnixSeconds: 1_620
            ),
            "95% written coverage cannot prove that the final archive record arrived"
        )
        XCTAssertTrue(
            OuraSleepNetPersistencePolicy.structurallySpansWindow(
                totalCodeSlots: 20,
                startUnixSeconds: 1_020,
                endUnixSeconds: 1_620
            )
        )
        XCTAssertTrue(
            OuraSleepNetPersistencePolicy.hasCompleteObservedCoverage(
                epochs: nineteenEpochs,
                startUnixSeconds: 1_020,
                endUnixSeconds: 1_620
            )
        )
        XCTAssertFalse(
            OuraSleepNetPersistencePolicy.hasCompleteObservedCoverage(
                epochs: Array(nineteenEpochs.dropLast()),
                startUnixSeconds: 1_020,
                endUnixSeconds: 1_620
            )
        )
        XCTAssertEqual(
            OuraSleepNetPersistencePolicy.coveredSeconds(
                by: nineteenEpochs + [nineteenEpochs[0]]
            ),
            19 * 30,
            "duplicate archive rows must not inflate coverage"
        )

        let gapped = try XCTUnwrap(
            OuraSleepSessionMapping.session(
                from: Array(nineteenEpochs.dropLast()),
                sessionStartUnixSeconds: 1_020,
                sessionEndUnixSeconds: 1_620,
                includeEfficiency: false
            )
        )
        XCTAssertNil(gapped.efficiency, "sparse stage observations must not become a complete metric")
    }

    func testSleepNetReplayPreservesEditsVitalsAndAuxiliarySeries() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "oura-ring"
        let start = 1_000
        try await store.upsertSleepSessions([
            CachedSleepSession(
                startTs: start,
                endTs: 4_000,
                efficiency: 0.91,
                restingHr: 48,
                avgHrv: 72,
                stagesJSON: "[\"original\"]"
            ),
        ], deviceId: deviceId)
        _ = try await store.applySleepEdit(
            deviceId: deviceId,
            detectedStartTs: start,
            newStartTs: 1_120,
            newEndTs: 3_900,
            stagesJSON: "[\"edited\"]"
        )
        _ = try await store.persistSessionMotion(
            deviceId: deviceId,
            sessionStart: start,
            motionEpochs: [1.0, 2.0]
        )
        _ = try await store.persistSessionSleepState(
            deviceId: deviceId,
            sessionStart: start,
            states: [1, 2]
        )

        _ = try await store.upsertOuraSleepNetSessions([
            CachedSleepSession(
                startTs: start,
                endTs: 4_200,
                efficiency: nil,
                restingHr: nil,
                avgHrv: nil,
                stagesJSON: "[\"sleepnet\"]"
            ),
        ], deviceId: deviceId)

        let sessions = try await store.sleepSessions(
            deviceId: deviceId,
            from: 0,
            to: 10_000,
            limit: 10
        )
        let session = try XCTUnwrap(sessions.first)
        XCTAssertTrue(session.userEdited)
        XCTAssertEqual(session.startTsAdjusted, 1_120)
        XCTAssertEqual(session.endTs, 3_900)
        XCTAssertEqual(session.stagesJSON, "[\"edited\"]")
        XCTAssertEqual(session.efficiency, 0.91)
        XCTAssertEqual(session.restingHr, 48)
        XCTAssertEqual(session.avgHrv, 72)
        let motion = try await store.sessionMotion(deviceId: deviceId, sessionStart: start)
        let sleepState = try await store.sessionSleepState(deviceId: deviceId, sessionStart: start)
        XCTAssertEqual(motion, [1.0, 2.0])
        XCTAssertEqual(sleepState, [1, 2])
    }
}
