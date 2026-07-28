import Foundation
import XCTest
@testable import WhoopStore

final class WaveformStoreTests: XCTestCase {
    private func chunk(
        stream: WaveformStream = .polarECG,
        start: Int64,
        end: Int64,
        values: [Int32]
    ) -> StoredWaveformChunk {
        var payload = Data()
        for value in values {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { payload.append(contentsOf: $0) }
        }
        return StoredWaveformChunk(
            stream: stream,
            startUnixNs: start,
            endUnixNs: end,
            sampleRateHz: 130,
            channels: 1,
            sampleCount: values.count,
            payload: payload
        )
    }

    func testMigrationCreatesChunkTableAndIndex() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        let primaryKey = try await store.primaryKeyColumns("waveformChunk")
        let indexes = try await store.indexNamesForTest(table: "waveformChunk")
        XCTAssertTrue(tables.contains("waveformChunk"))
        XCTAssertEqual(primaryKey, ["deviceId", "stream", "startUnixNs"])
        XCTAssertTrue(indexes.contains("idx_waveformChunk_device_end"))
    }

    func testInsertIsIdempotentAndReadIsDeviceScoped() async throws {
        let store = try await WhoopStore.inMemory()
        let first = chunk(start: 1_000, end: 2_000, values: [1, -2])
        let firstInsert = try await store.insertWaveformChunks([first], deviceId: "polar-a")
        let duplicateInsert = try await store.insertWaveformChunks([first], deviceId: "polar-a")
        XCTAssertEqual(firstInsert, 1)
        XCTAssertEqual(duplicateInsert, 0)
        _ = try await store.insertWaveformChunks(
            [chunk(stream: .polarPPG, start: 1_500, end: 2_500, values: [3])],
            deviceId: "polar-b"
        )

        let mine = try await store.waveformChunks(
            deviceId: "polar-a",
            fromUnixNs: 0,
            toUnixNs: 3_000
        )
        XCTAssertEqual(mine, [first])
        let bytes = try await store.waveformPayloadBytes(deviceId: "polar-a")
        XCTAssertEqual(bytes, 8)
    }

    func testAgeRetentionUsesNewestStoredTimestamp() async throws {
        let store = try await WhoopStore.inMemory()
        let limits = WaveformRetentionLimits(
            maxAgeNs: 100,
            maxPayloadBytesPerDevice: 1_000
        )
        _ = try await store.insertWaveformChunks(
            [chunk(start: 0, end: 10, values: [1])],
            deviceId: "polar",
            limits: limits
        )
        _ = try await store.insertWaveformChunks(
            [chunk(start: 190, end: 200, values: [2])],
            deviceId: "polar",
            limits: limits
        )

        let rows = try await store.waveformChunks(
            deviceId: "polar",
            fromUnixNs: 0,
            toUnixNs: 1_000
        )
        XCTAssertEqual(rows.map(\.startUnixNs), [190])
    }

    func testByteRetentionDropsOldestWholeChunks() async throws {
        let store = try await WhoopStore.inMemory()
        let limits = WaveformRetentionLimits(
            maxAgeNs: 1_000,
            maxPayloadBytesPerDevice: 8
        )
        _ = try await store.insertWaveformChunks(
            [
                chunk(start: 10, end: 20, values: [1]),
                chunk(start: 30, end: 40, values: [2]),
                chunk(start: 50, end: 60, values: [3]),
            ],
            deviceId: "polar",
            limits: limits
        )

        let rows = try await store.waveformChunks(
            deviceId: "polar",
            fromUnixNs: 0,
            toUnixNs: 100
        )
        XCTAssertEqual(rows.map(\.startUnixNs), [30, 50])
        let bytes = try await store.waveformPayloadBytes(deviceId: "polar")
        XCTAssertEqual(bytes, 8)
    }

    func testInvalidPayloadLengthRejectsEntireBatch() async throws {
        let store = try await WhoopStore.inMemory()
        let invalid = StoredWaveformChunk(
            stream: .polarECG,
            startUnixNs: 1,
            endUnixNs: 2,
            sampleRateHz: 130,
            channels: 1,
            sampleCount: 2,
            payload: Data([0, 0, 0, 0])
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await store.insertWaveformChunks([invalid], deviceId: "polar")
        }
        let bytes = try await store.waveformPayloadBytes(deviceId: "polar")
        XCTAssertEqual(bytes, 0)
    }

    func testDeleteDeviceDataIncludesWaveforms() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insertWaveformChunks(
            [chunk(start: 1, end: 2, values: [1])],
            deviceId: "polar"
        )
        try await store.deleteAllData(deviceId: "polar")
        let bytes = try await store.waveformPayloadBytes(deviceId: "polar")
        XCTAssertEqual(bytes, 0)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}
