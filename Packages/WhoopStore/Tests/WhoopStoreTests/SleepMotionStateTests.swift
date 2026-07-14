import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// v18 migration + read/write round-trip: per-epoch `motionJSON` (H8) and `sleepStateJSON` (H2) banked
/// on the existing sleepSession row beside `stagesJSON`. Twin of Android's MigrationRoundTripTest cases.
final class SleepMotionStateTests: XCTestCase {
    private let dev = "my-whoop"
    private let start = 1_780_000_000

    private func storeWithSession() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: start, endTs: start + 8 * 3_600, efficiency: 0.9,
                               restingHr: 52, avgHrv: 70, stagesJSON: "[]")
        ], deviceId: dev)
        return store
    }

    func testV18AddsMotionAndStateColumns() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("motionJSON"))
        XCTAssertTrue(cols.contains("sleepStateJSON"))
    }

    func testSchemaVersionIncludesV18AndLaterMigrations() {
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 23)
    }

    // MARK: motionJSON

    func testMotionRoundTrip() async throws {
        let store = try await storeWithSession()
        let motion = [0.0, 1.5, 12.25, 3.0, 0.5]
        let n = try await store.persistSessionMotion(deviceId: dev, sessionStart: start, motionEpochs: motion)
        XCTAssertEqual(n, 1)
        let read = try await store.sessionMotion(deviceId: dev, sessionStart: start)
        XCTAssertEqual(read, motion)
    }

    /// Absent stays absent — a never-written column reads back nil, NOT [] or a fabricated zero series.
    func testMotionAbsentReadsNil() async throws {
        let store = try await storeWithSession()
        let read = try await store.sessionMotion(deviceId: dev, sessionStart: start)
        XCTAssertNil(read)
    }

    /// Persisting an EMPTY array clears the column to NULL (nil on read), never an empty `[]` as data.
    func testMotionEmptyClearsToNil() async throws {
        let store = try await storeWithSession()
        _ = try await store.persistSessionMotion(deviceId: dev, sessionStart: start, motionEpochs: [9.0])
        let present = try await store.sessionMotion(deviceId: dev, sessionStart: start)
        XCTAssertNotNil(present)
        _ = try await store.persistSessionMotion(deviceId: dev, sessionStart: start, motionEpochs: [])
        let cleared = try await store.sessionMotion(deviceId: dev, sessionStart: start)
        XCTAssertNil(cleared)
    }

    /// Writing motion to a non-existent session changes nothing and reads back nil.
    func testMotionNoSuchSessionNoOp() async throws {
        let store = try await storeWithSession()
        let n = try await store.persistSessionMotion(deviceId: dev, sessionStart: start + 999, motionEpochs: [1.0])
        XCTAssertEqual(n, 0)
        let none = try await store.sessionMotion(deviceId: dev, sessionStart: start + 999)
        XCTAssertNil(none)
    }

    // MARK: sleepStateJSON

    func testSleepStateRoundTrip() async throws {
        let store = try await storeWithSession()
        let states = [0, 1, 2, 3, 1, 0]   // decoded v18 band (sb>>4)&3
        let n = try await store.persistSessionSleepState(deviceId: dev, sessionStart: start, states: states)
        XCTAssertEqual(n, 1)
        let read = try await store.sessionSleepState(deviceId: dev, sessionStart: start)
        XCTAssertEqual(read, states)
    }

    func testSleepStateAbsentReadsNil() async throws {
        let store = try await storeWithSession()
        let read = try await store.sessionSleepState(deviceId: dev, sessionStart: start)
        XCTAssertNil(read)
    }

    func testSleepStateEmptyClearsToNil() async throws {
        let store = try await storeWithSession()
        _ = try await store.persistSessionSleepState(deviceId: dev, sessionStart: start, states: [2, 2])
        let present = try await store.sessionSleepState(deviceId: dev, sessionStart: start)
        XCTAssertNotNil(present)
        _ = try await store.persistSessionSleepState(deviceId: dev, sessionStart: start, states: [])
        let cleared = try await store.sessionSleepState(deviceId: dev, sessionStart: start)
        XCTAssertNil(cleared)
    }

    /// A later recompute/import upsert of the SAME session (which never names the two aux columns) must
    /// PRESERVE the banked motion/state — they are not in its column list, so ON CONFLICT leaves them.
    func testUpsertPreservesMotionAndState() async throws {
        let store = try await storeWithSession()
        _ = try await store.persistSessionMotion(deviceId: dev, sessionStart: start, motionEpochs: [1.0, 2.0])
        _ = try await store.persistSessionSleepState(deviceId: dev, sessionStart: start, states: [1, 2])
        // Re-upsert the session with fresh vitals (simulating a post-sync recompute).
        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: start, endTs: start + 8 * 3_600, efficiency: 0.95,
                               restingHr: 50, avgHrv: 72, stagesJSON: "[]")
        ], deviceId: dev)
        let motion = try await store.sessionMotion(deviceId: dev, sessionStart: start)
        XCTAssertEqual(motion, [1.0, 2.0])
        let states = try await store.sessionSleepState(deviceId: dev, sessionStart: start)
        XCTAssertEqual(states, [1, 2])
    }
}
