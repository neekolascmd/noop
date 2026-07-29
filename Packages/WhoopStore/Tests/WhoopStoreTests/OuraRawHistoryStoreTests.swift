import Foundation
import OuraProtocol
import XCTest
@testable import WhoopStore

final class OuraRawHistoryStoreTests: XCTestCase {
    private func record(
        tag: UInt8 = 0x6F,
        ringTimestamp: UInt32,
        payload: [UInt8]
    ) -> OuraRecord {
        OuraRecord(type: tag, ringTimestamp: ringTimestamp, payload: payload)
    }

    func testMigrationCreatesArchiveAndExactIndexes() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("ouraRawHistory"))
        let indexes = try await store.indexNamesForTest(table: "ouraRawHistory")
        XCTAssertTrue(indexes.contains("idx_ouraRawHistory_exact"))
        XCTAssertTrue(indexes.contains("idx_ouraRawHistory_device_seen"))
    }

    func testExactRefetchIsIdempotentAndReplayable() async throws {
        let store = try await WhoopStore.inMemory()
        let first = record(ringTimestamp: 10, payload: [1, 2, 3])
        let second = record(tag: 0x59, ringTimestamp: 10, payload: [1, 2, 3])

        let firstInsert = try await store.insertOuraRawHistoryRecords(
            [first, second],
            deviceId: "oura-a",
            firstSeenAtUnixMs: 100
        )
        let duplicateInsert = try await store.insertOuraRawHistoryRecords(
            [first],
            deviceId: "oura-a",
            firstSeenAtUnixMs: 200
        )
        XCTAssertEqual(firstInsert, 2)
        XCTAssertEqual(duplicateInsert, 0)

        let rows = try await store.ouraRawHistoryRecords(deviceId: "oura-a")
        XCTAssertEqual(rows.map(\.record), [first, second])
        XCTAssertEqual(rows.map(\.firstSeenAtUnixMs), [100, 100])
        let bytes = try await store.ouraRawHistoryWireBytes(deviceId: "oura-a")
        XCTAssertEqual(bytes, 18)

        let secondPage = try await store.ouraRawHistoryRecords(
            deviceId: "oura-a",
            afterArchiveId: rows[0].archiveId,
            limit: 1
        )
        XCTAssertEqual(secondPage.map(\.record), [second])
    }

    func testByteRetentionDropsOldestWholeRecordsPerDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let limits = OuraRawHistoryRetentionLimits(maxWireBytesPerDevice: 14)
        let records = [
            record(ringTimestamp: 1, payload: [1]),
            record(ringTimestamp: 2, payload: [2]),
            record(ringTimestamp: 3, payload: [3]),
        ]
        for (index, value) in records.enumerated() {
            _ = try await store.insertOuraRawHistoryRecords(
                [value],
                deviceId: "oura-a",
                firstSeenAtUnixMs: Int64(index + 1),
                limits: limits
            )
        }
        _ = try await store.insertOuraRawHistoryRecords(
            [records[0]],
            deviceId: "oura-b",
            firstSeenAtUnixMs: 1,
            limits: limits
        )

        let rows = try await store.ouraRawHistoryRecords(deviceId: "oura-a")
        let bytesA = try await store.ouraRawHistoryWireBytes(deviceId: "oura-a")
        let bytesB = try await store.ouraRawHistoryWireBytes(deviceId: "oura-b")
        XCTAssertEqual(rows.map(\.ringTimestamp), [2, 3])
        XCTAssertEqual(bytesA, 14)
        XCTAssertEqual(bytesB, 7)
    }

    func testInvalidBatchWritesNothing() async throws {
        let store = try await WhoopStore.inMemory()
        let invalid = record(tag: 0x2F, ringTimestamp: 1, payload: [])
        do {
            _ = try await store.insertOuraRawHistoryRecords([invalid], deviceId: "oura")
            XCTFail("Expected an invalid-tag error")
        } catch {
            // Expected.
        }
        let bytes = try await store.ouraRawHistoryWireBytes(deviceId: "oura")
        XCTAssertEqual(bytes, 0)
    }

    func testDeleteDeviceDataIncludesRawArchive() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insertOuraRawHistoryRecords(
            [record(ringTimestamp: 1, payload: [1])],
            deviceId: "oura"
        )
        try await store.deleteAllData(deviceId: "oura")
        let bytes = try await store.ouraRawHistoryWireBytes(deviceId: "oura")
        XCTAssertEqual(bytes, 0)
    }
}
