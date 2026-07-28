import Foundation
import GRDB

/// Dense waveform lanes currently persisted by NOOP.
public enum WaveformStream: String, Codable, CaseIterable, Sendable {
    case polarECG = "polar_ecg"
    case polarPPG = "polar_ppg"
}

/// One bounded block of interleaved signed-32-bit waveform samples.
public struct StoredWaveformChunk: Equatable, Sendable {
    public static let encoding = "int32_le_v1"

    public let stream: WaveformStream
    public let startUnixNs: Int64
    public let endUnixNs: Int64
    public let sampleRateHz: Int
    public let channels: Int
    public let sampleCount: Int
    public let payload: Data

    public init(stream: WaveformStream,
                startUnixNs: Int64,
                endUnixNs: Int64,
                sampleRateHz: Int,
                channels: Int,
                sampleCount: Int,
                payload: Data) {
        self.stream = stream
        self.startUnixNs = startUnixNs
        self.endUnixNs = endUnixNs
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.sampleCount = sampleCount
        self.payload = payload
    }
}

/// Rolling-store ceilings. The production byte limit holds roughly an eight-hour, four-channel
/// 135 Hz PPG night (or more than a day of single-channel ECG) without allowing indefinite growth.
public struct WaveformRetentionLimits: Equatable, Sendable {
    public static let production = WaveformRetentionLimits(
        maxAgeNs: 24 * 60 * 60 * 1_000_000_000,
        maxPayloadBytesPerDevice: 64 * 1_024 * 1_024
    )

    public let maxAgeNs: Int64
    public let maxPayloadBytesPerDevice: Int64

    public init(maxAgeNs: Int64, maxPayloadBytesPerDevice: Int64) {
        self.maxAgeNs = maxAgeNs
        self.maxPayloadBytesPerDevice = maxPayloadBytesPerDevice
    }
}

extension WhoopStore {
    /// Insert dense waveform chunks atomically, then enforce both the age and byte ceilings.
    ///
    /// Natural-key conflicts are ignored, making a repeated flush idempotent. Retention uses the
    /// newest timestamp already stored for the device, so a delayed old chunk cannot move the rolling
    /// horizon backward.
    @discardableResult
    public func insertWaveformChunks(
        _ chunks: [StoredWaveformChunk],
        deviceId: String,
        limits: WaveformRetentionLimits = .production
    ) async throws -> Int {
        guard !chunks.isEmpty else { return 0 }
        guard !deviceId.isEmpty else {
            throw WaveformStoreError.invalid("device id is empty")
        }
        guard limits.maxAgeNs > 0, limits.maxPayloadBytesPerDevice > 0 else {
            throw WaveformStoreError.invalid("retention limits")
        }
        for chunk in chunks { try Self.validateWaveformChunk(chunk) }

        return try syncWrite { db in
            let statement = try db.cachedStatement(sql: """
                INSERT INTO waveformChunk
                    (deviceId, stream, startUnixNs, endUnixNs, sampleRateHz, channels,
                     sampleCount, encoding, byteSize, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, stream, startUnixNs) DO NOTHING
                """)
            var inserted = 0
            for chunk in chunks {
                try statement.execute(arguments: [
                    deviceId,
                    chunk.stream.rawValue,
                    chunk.startUnixNs,
                    chunk.endUnixNs,
                    chunk.sampleRateHz,
                    chunk.channels,
                    chunk.sampleCount,
                    StoredWaveformChunk.encoding,
                    chunk.payload.count,
                    chunk.payload,
                ])
                inserted += db.changesCount
            }

            let newestEnd = try Int64.fetchOne(
                db,
                sql: "SELECT MAX(endUnixNs) FROM waveformChunk WHERE deviceId = ?",
                arguments: [deviceId]
            ) ?? chunks.map(\.endUnixNs).max()!
            let cutoffResult = newestEnd.subtractingReportingOverflow(limits.maxAgeNs)
            let cutoff = cutoffResult.overflow ? Int64.min : cutoffResult.partialValue
            try db.execute(
                sql: "DELETE FROM waveformChunk WHERE deviceId = ? AND endUnixNs < ?",
                arguments: [deviceId, cutoff]
            )

            var total = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(byteSize), 0) FROM waveformChunk WHERE deviceId = ?",
                arguments: [deviceId]
            ) ?? 0
            if total > limits.maxPayloadBytesPerDevice {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT rowid, byteSize
                        FROM waveformChunk
                        WHERE deviceId = ?
                        ORDER BY endUnixNs ASC, startUnixNs ASC, stream ASC
                        """,
                    arguments: [deviceId]
                )
                let delete = try db.cachedStatement(
                    sql: "DELETE FROM waveformChunk WHERE rowid = ?"
                )
                for row in rows where total > limits.maxPayloadBytesPerDevice {
                    let rowID: Int64 = row["rowid"]
                    let byteSize: Int64 = row["byteSize"]
                    try delete.execute(arguments: [rowID])
                    total = max(0, total - byteSize)
                }
            }
            return inserted
        }
    }

    /// Read chunks that overlap `[fromUnixNs, toUnixNs]`, oldest first.
    public func waveformChunks(
        deviceId: String,
        stream: WaveformStream? = nil,
        fromUnixNs: Int64,
        toUnixNs: Int64,
        limit: Int = 20_000
    ) async throws -> [StoredWaveformChunk] {
        guard fromUnixNs <= toUnixNs else { return [] }
        let boundedLimit = min(max(limit, 0), 50_000)
        guard boundedLimit > 0 else { return [] }
        return try syncRead { db in
            let sql: String
            let arguments: StatementArguments
            if let stream {
                sql = """
                    SELECT stream, startUnixNs, endUnixNs, sampleRateHz, channels, sampleCount, payload
                    FROM waveformChunk
                    WHERE deviceId = ? AND stream = ? AND endUnixNs >= ? AND startUnixNs <= ?
                    ORDER BY startUnixNs ASC LIMIT ?
                    """
                arguments = [deviceId, stream.rawValue, fromUnixNs, toUnixNs, boundedLimit]
            } else {
                sql = """
                    SELECT stream, startUnixNs, endUnixNs, sampleRateHz, channels, sampleCount, payload
                    FROM waveformChunk
                    WHERE deviceId = ? AND endUnixNs >= ? AND startUnixNs <= ?
                    ORDER BY startUnixNs ASC, stream ASC LIMIT ?
                    """
                arguments = [deviceId, fromUnixNs, toUnixNs, boundedLimit]
            }
            return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap(Self.decodeWaveformRow)
        }
    }

    public func waveformPayloadBytes(deviceId: String) async throws -> Int64 {
        try syncRead { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(byteSize), 0) FROM waveformChunk WHERE deviceId = ?",
                arguments: [deviceId]
            ) ?? 0
        }
    }

    private static func validateWaveformChunk(_ chunk: StoredWaveformChunk) throws {
        guard chunk.startUnixNs >= 0, chunk.endUnixNs >= chunk.startUnixNs else {
            throw WaveformStoreError.invalid("timestamp range")
        }
        guard (1...10_000).contains(chunk.sampleRateHz),
              (1...16).contains(chunk.channels),
              (1...4_096).contains(chunk.sampleCount) else {
            throw WaveformStoreError.invalid("shape")
        }
        let elementCount = chunk.sampleCount.multipliedReportingOverflow(by: chunk.channels)
        let byteCount = elementCount.partialValue.multipliedReportingOverflow(by: 4)
        guard !elementCount.overflow,
              !byteCount.overflow,
              byteCount.partialValue == chunk.payload.count else {
            throw WaveformStoreError.invalid("payload length")
        }
    }

    private static func decodeWaveformRow(_ row: Row) -> StoredWaveformChunk? {
        guard let stream = WaveformStream(rawValue: row["stream"]) else { return nil }
        return StoredWaveformChunk(
            stream: stream,
            startUnixNs: row["startUnixNs"],
            endUnixNs: row["endUnixNs"],
            sampleRateHz: row["sampleRateHz"],
            channels: row["channels"],
            sampleCount: row["sampleCount"],
            payload: row["payload"]
        )
    }
}

public enum WaveformStoreError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let reason): return "invalid waveform chunk: \(reason)"
        }
    }
}
