import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class MigrationTests: XCTestCase {
    private func temporaryDatabasePath() -> String {
        NSTemporaryDirectory() + "whoopstore-migration-\(UUID().uuidString).sqlite"
    }

    private func removeDatabaseFiles(at path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    func testInMemoryRunsMigrations() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch"] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
    }

    func testFileInitRunsMigrations() async throws {
        let path = NSTemporaryDirectory() + "whoopstore-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try await WhoopStore(path: path)
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("hrSample"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testHrSamplePrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("hrSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    func testRrIntervalPrimaryKeyIncludesRrMs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(cols, ["deviceId", "ts", "rrMs"])
    }

    /// v5 adds a `synced` column to all 8 decoded tables.
    func testV5AddsSyncedColumnToDecodedTables() async throws {
        let store = try await WhoopStore.inMemory()
        for table in ["hrSample", "rrInterval", "event", "battery",
                      "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
            let cols = try await store.columnNamesForTest(table: table)
            XCTAssertTrue(cols.contains("synced"), "\(table) missing synced column")
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 23)
    }

    /// v13 adds the `userEdited` flag to sleepSession (user-corrected wake times survive re-sync).
    func testV13AddsUserEditedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("userEdited"), "sleepSession missing v13 userEdited column")
    }

    /// v14 adds `startTsAdjusted` (the user-corrected sleep onset; detected startTs stays the key).
    func testV14AddsStartTsAdjustedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("startTsAdjusted"), "sleepSession missing v14 startTsAdjusted column")
    }

    /// v16 adds `peripheralId` to pairedDevice (stable per-strap BLE identity for multi-WHOOP support).
    func testV16AddsPeripheralIdColumnToPairedDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "pairedDevice")
        XCTAssertTrue(cols.contains("peripheralId"), "pairedDevice missing v16 peripheralId column")
    }

    func testSchemaVersionMatchesRegisteredMigrationHistory() {
        let identifiers = WhoopStoreInfo.migrationIdentifiers
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, identifiers.count)
        XCTAssertEqual(identifiers.first, "v1")
        XCTAssertEqual(identifiers.last, "v23-spo2-unit")
        XCTAssertEqual(Set(identifiers).count, identifiers.count, "migration identifiers must be unique")
    }

    func testSequentialMigrationFromV1PreservesCoreRows() async throws {
        let path = temporaryDatabasePath()
        defer { removeDatabaseFiles(at: path) }

        do {
            let queue = try DatabaseQueue(path: path)
            try WhoopStore.makeMigrator().migrate(queue, upTo: "v1")
            try await queue.write { db in
                try db.execute(
                    sql: "INSERT INTO device (id, mac, name, firstSeen, lastSeen) VALUES (?, ?, ?, ?, ?)",
                    arguments: ["legacy", "AA:BB", "Legacy strap", 10, 20])
                try db.execute(
                    sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)",
                    arguments: ["legacy", 1_700_000_000, 63])
            }
        }

        let store = try await WhoopStore(path: path)
        let samples = try await store.hrSamples(
            deviceId: "legacy", from: 1_699_999_000, to: 1_700_001_000, limit: 10)
        XCTAssertEqual(samples, [HRSample(ts: 1_700_000_000, bpm: 63)])

        let applied = try await store.registryWriter.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        XCTAssertEqual(applied, WhoopStoreInfo.migrationIdentifiers,
                       "opening a v1 store must apply every later migration exactly once")
    }

    func testSequentialMigrationFromV18PreservesRowsAddedBeforeV19() async throws {
        let path = temporaryDatabasePath()
        defer { removeDatabaseFiles(at: path) }

        do {
            let queue = try DatabaseQueue(path: path)
            try WhoopStore.makeMigrator().migrate(queue, upTo: "v18-sleep-motion-state")
            try await queue.write { db in
                try db.execute(
                    sql: "INSERT INTO stepSample (deviceId, ts, counter) VALUES (?, ?, ?)",
                    arguments: ["legacy", 1_700_000_100, 42])
                try db.execute(
                    sql: "INSERT INTO journal (deviceId, day, question, answeredYes, notes) VALUES (?, ?, ?, ?, ?)",
                    arguments: ["legacy", "2026-01-02", "caffeine", 1, "before-v20"])
            }
        }

        let store = try await WhoopStore(path: path)
        let stepColumns = try await store.columnNamesForTest(table: "stepSample")
        let journalColumns = try await store.columnNamesForTest(table: "journal")
        let tables = try await store.tableNames()
        XCTAssertTrue(stepColumns.contains("activityClass"), "v19 must add activityClass")
        XCTAssertTrue(journalColumns.contains("numericValue"), "v20 must add numericValue")
        XCTAssertTrue(tables.contains("sleepStateSample"), "v21 table missing")
        XCTAssertTrue(tables.contains("liveSession"), "v22 table missing")

        let preserved = try await store.registryWriter.read { db -> (counter: Int?, note: String?, numeric: Double?) in
            let counter = try Int.fetchOne(db, sql: "SELECT counter FROM stepSample WHERE deviceId = 'legacy'")
            let row = try Row.fetchOne(db, sql: "SELECT notes, numericValue FROM journal WHERE deviceId = 'legacy'")
            let note: String? = row?["notes"]
            let numeric: Double? = row?["numericValue"]
            return (counter, note, numeric)
        }
        XCTAssertEqual(preserved.counter, 42)
        XCTAssertEqual(preserved.note, "before-v20")
        XCTAssertNil(preserved.numeric, "the new nullable column must not fabricate historical data")
    }
}
