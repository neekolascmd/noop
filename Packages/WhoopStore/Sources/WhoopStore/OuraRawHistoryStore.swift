import Foundation
import GRDB
import OuraProtocol

/// One complete Oura history TLV retained before typed decoding.
///
/// `archiveId` is a local insertion-order cursor, not a ring or cloud identifier. Replayers can page
/// through the archive without assuming that Oura's 32-bit ring clock is globally monotonic.
public struct StoredOuraRawHistoryRecord: Equatable, Sendable {
    public let archiveId: Int64
    public let tag: UInt8
    public let ringTimestamp: UInt32
    public let payload: Data
    public let firstSeenAtUnixMs: Int64
    public let timeAnchor: OuraTimeAnchor?
    public let decodedRevision: Int

    public init(
        archiveId: Int64,
        tag: UInt8,
        ringTimestamp: UInt32,
        payload: Data,
        firstSeenAtUnixMs: Int64,
        timeAnchor: OuraTimeAnchor? = nil,
        decodedRevision: Int = 0
    ) {
        self.archiveId = archiveId
        self.tag = tag
        self.ringTimestamp = ringTimestamp
        self.payload = payload
        self.firstSeenAtUnixMs = firstSeenAtUnixMs
        self.timeAnchor = timeAnchor
        self.decodedRevision = decodedRevision
    }

    public var record: OuraRecord {
        OuraRecord(type: tag, ringTimestamp: ringTimestamp, payload: Array(payload))
    }
}

/// The archive keeps a generous local research window, but remains finite.
/// The limit counts original TLV wire bytes (including the six-byte header/timestamp), so even empty
/// payload records consume space and cannot create an unbounded zero-byte-row archive.
public struct OuraRawHistoryRetentionLimits: Equatable, Sendable {
    public static let production = OuraRawHistoryRetentionLimits(
        maxWireBytesPerDevice: 128 * 1_024 * 1_024
    )

    public let maxWireBytesPerDevice: Int64

    public init(maxWireBytesPerDevice: Int64) {
        self.maxWireBytesPerDevice = maxWireBytesPerDevice
    }
}

extension WhoopStore {
    /// Atomically archive complete history records, ignore exact refetch duplicates, then evict the oldest
    /// whole records until the per-device ceiling is satisfied.
    ///
    /// Only callers at the reassembled history-TLV boundary should use this API. The existing registry
    /// device id partitions rows; authentication frames, install keys, identifiers extracted from traffic,
    /// outgoing commands, and secure live traffic do not belong in the record payload.
    @discardableResult
    public func insertOuraRawHistoryRecords(
        _ records: [OuraRecord],
        deviceId: String,
        firstSeenAtUnixMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        timeAnchor: OuraTimeAnchor? = nil,
        limits: OuraRawHistoryRetentionLimits = .production
    ) async throws -> Int {
        guard !records.isEmpty else { return 0 }
        guard !deviceId.isEmpty else {
            throw OuraRawHistoryStoreError.invalid("device id is empty")
        }
        guard firstSeenAtUnixMs >= 0 else {
            throw OuraRawHistoryStoreError.invalid("first-seen timestamp")
        }
        guard limits.maxWireBytesPerDevice > 0 else {
            throw OuraRawHistoryStoreError.invalid("retention limit")
        }
        if let timeAnchor, !OuraTimeAnchorMapping.isValid(timeAnchor) {
            throw OuraRawHistoryStoreError.invalid("time anchor")
        }
        for record in records { try Self.validateOuraRawHistoryRecord(record) }

        return try syncWrite { db in
            let insert = try db.cachedStatement(sql: """
                INSERT INTO ouraRawHistory
                    (deviceId, ringTimestamp, tag, payload, wireByteSize, firstSeenAtUnixMs,
                     anchorUtcMilliseconds, anchorRingTimestamp, anchorFactorMillisecondsPerTick,
                     decodedRevision)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(deviceId, ringTimestamp, tag, payload) DO NOTHING
                """)
            let enrich = try db.cachedStatement(sql: """
                UPDATE ouraRawHistory
                SET anchorUtcMilliseconds = ?,
                    anchorRingTimestamp = ?,
                    anchorFactorMillisecondsPerTick = ?,
                    decodedRevision = 0
                WHERE deviceId = ? AND ringTimestamp = ? AND tag = ? AND payload = ?
                  AND anchorUtcMilliseconds IS NULL
                """)
            var inserted = 0
            for record in records {
                let payload = Data(record.payload)
                try insert.execute(arguments: [
                    deviceId,
                    Int64(record.ringTimestamp),
                    Int(record.type),
                    payload,
                    record.totalLength,
                    firstSeenAtUnixMs,
                    timeAnchor?.utcMilliseconds,
                    timeAnchor.map { Int64($0.ringTimestamp) },
                    timeAnchor?.factorMillisecondsPerTick,
                ])
                let wasInserted = db.changesCount
                inserted += wasInserted
                if wasInserted == 0, let timeAnchor {
                    try enrich.execute(arguments: [
                        timeAnchor.utcMilliseconds,
                        Int64(timeAnchor.ringTimestamp),
                        timeAnchor.factorMillisecondsPerTick,
                        deviceId,
                        Int64(record.ringTimestamp),
                        Int(record.type),
                        payload,
                    ])
                }
            }

            var total = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(wireByteSize), 0) FROM ouraRawHistory WHERE deviceId = ?",
                arguments: [deviceId]
            ) ?? 0
            if total > limits.maxWireBytesPerDevice {
                let oldest = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT archiveId, wireByteSize
                        FROM ouraRawHistory
                        WHERE deviceId = ?
                        ORDER BY firstSeenAtUnixMs ASC, archiveId ASC
                        """,
                    arguments: [deviceId]
                )
                let delete = try db.cachedStatement(
                    sql: "DELETE FROM ouraRawHistory WHERE archiveId = ?"
                )
                for row in oldest where total > limits.maxWireBytesPerDevice {
                    let archiveId: Int64 = row["archiveId"]
                    let wireByteSize: Int64 = row["wireByteSize"]
                    try delete.execute(arguments: [archiveId])
                    total = max(0, total - wireByteSize)
                }
            }
            return inserted
        }
    }

    /// Page archived records in original first-seen order for future clean-room decoder passes.
    public func ouraRawHistoryRecords(
        deviceId: String,
        afterArchiveId: Int64 = 0,
        throughArchiveId: Int64 = .max,
        limit: Int = 20_000
    ) async throws -> [StoredOuraRawHistoryRecord] {
        let boundedLimit = min(max(limit, 0), 50_000)
        guard !deviceId.isEmpty, afterArchiveId >= 0,
              throughArchiveId > afterArchiveId, boundedLimit > 0 else { return [] }
        return try syncRead { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT archiveId, tag, ringTimestamp, payload, firstSeenAtUnixMs,
                           anchorUtcMilliseconds, anchorRingTimestamp,
                           anchorFactorMillisecondsPerTick, decodedRevision
                    FROM ouraRawHistory
                    WHERE deviceId = ? AND archiveId > ? AND archiveId <= ?
                    ORDER BY archiveId ASC
                    LIMIT ?
                    """,
                arguments: [deviceId, afterArchiveId, throughArchiveId, boundedLimit]
            ).compactMap(Self.decodeOuraRawHistoryRow)
        }
    }

    /// Snapshot boundary for one decoder pass. Rows inserted after this value remain revision-old and
    /// are therefore guaranteed to trigger the coalesced/future pass instead of being marked without
    /// participating in the corresponding whole-archive reconstruction.
    public func ouraRawHistoryHighWaterArchiveId(deviceId: String) async throws -> Int64 {
        guard !deviceId.isEmpty else { return 0 }
        return try syncRead { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(archiveId), 0) FROM ouraRawHistory WHERE deviceId = ?",
                arguments: [deviceId]
            ) ?? 0
        }
    }

    /// Page rows not yet processed by the current clean-room decoder revision.
    public func ouraRawHistoryRecordsNeedingDecode(
        deviceId: String,
        decoderRevision: Int,
        throughArchiveId: Int64 = .max,
        limit: Int = 2_000
    ) async throws -> [StoredOuraRawHistoryRecord] {
        let boundedLimit = min(max(limit, 0), 10_000)
        guard !deviceId.isEmpty, decoderRevision > 0,
              throughArchiveId > 0, boundedLimit > 0 else { return [] }
        return try syncRead { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT archiveId, tag, ringTimestamp, payload, firstSeenAtUnixMs,
                           anchorUtcMilliseconds, anchorRingTimestamp,
                           anchorFactorMillisecondsPerTick, decodedRevision
                    FROM ouraRawHistory
                    WHERE deviceId = ? AND decodedRevision < ? AND archiveId <= ?
                    ORDER BY archiveId ASC
                    LIMIT ?
                    """,
                arguments: [deviceId, decoderRevision, throughArchiveId, boundedLimit]
            ).compactMap(Self.decodeOuraRawHistoryRow)
        }
    }

    /// Cheap gate for the whole-archive SleepNet pass. Ordinary HR/temperature history revisions must
    /// not rescan a potentially large raw archive every periodic fetch; only a newly-decodable 0x49
    /// window or 0x4B/0x4E/0x5A phase record can change a staged night.
    public func hasOuraRawSleepNetRecordsNeedingDecode(
        deviceId: String,
        decoderRevision: Int,
        throughArchiveId: Int64 = .max
    ) async throws -> Bool {
        guard !deviceId.isEmpty, decoderRevision > 0, throughArchiveId > 0 else { return false }
        return try syncRead { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM ouraRawHistory
                        WHERE deviceId = ? AND decodedRevision < ? AND archiveId <= ?
                          AND tag IN (?, ?, ?, ?)
                    )
                    """,
                arguments: [
                    deviceId,
                    decoderRevision,
                    throughArchiveId,
                    Int(OuraEventTag.sleepSummary1.rawValue),
                    Int(OuraEventTag.sleepPhaseInfo.rawValue),
                    Int(OuraEventTag.sleepPhase.rawValue),
                    Int(OuraEventTag.sleepPhaseAlt.rawValue),
                ]
            ) ?? false
        }
    }

    /// A newly decodable row that can supply UTC to older unresolved rows. Stored anchor metadata is
    /// sufficient even on an ordinary tag; raw 0x42/0x85 records can also reveal an anchor themselves.
    /// This re-opens previously withheld SleepNet rows without rescanning on every activation forever.
    public func hasOuraRawAnchorEvidenceNeedingDecode(
        deviceId: String,
        decoderRevision: Int,
        throughArchiveId: Int64 = .max
    ) async throws -> Bool {
        guard !deviceId.isEmpty, decoderRevision > 0, throughArchiveId > 0 else { return false }
        return try syncRead { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM ouraRawHistory
                        WHERE deviceId = ? AND decodedRevision < ? AND archiveId <= ?
                          AND (anchorUtcMilliseconds IS NOT NULL OR tag IN (?, ?))
                    )
                    """,
                arguments: [
                    deviceId,
                    decoderRevision,
                    throughArchiveId,
                    Int(OuraEventTag.timeSync.rawValue),
                    Int(OuraEventTag.rtcBeacon.rawValue),
                ]
            ) ?? false
        }
    }

    /// Lets a new decoder decide whether the insertion-ordered anchor repair is necessary without first
    /// loading every retained row into memory.
    public func hasOuraRawHistoryRowsWithoutTimeAnchor(
        deviceId: String,
        throughArchiveId: Int64 = .max
    ) async throws -> Bool {
        guard !deviceId.isEmpty, throughArchiveId > 0 else { return false }
        return try syncRead { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM ouraRawHistory
                        WHERE deviceId = ? AND archiveId <= ? AND anchorUtcMilliseconds IS NULL
                    )
                    """,
                arguments: [deviceId, throughArchiveId]
            ) ?? false
        }
    }

    /// Attach a validated anchor to still-unresolved rows in an insertion-order segment. Resetting their
    /// revision makes a later pass reconsider rows that were previously withheld for lack of UTC.
    @discardableResult
    public func setOuraRawHistoryTimeAnchor(
        _ anchor: OuraTimeAnchor,
        deviceId: String,
        fromArchiveId: Int64,
        throughArchiveId: Int64
    ) async throws -> Int {
        guard !deviceId.isEmpty,
              fromArchiveId > 0,
              throughArchiveId >= fromArchiveId,
              OuraTimeAnchorMapping.isValid(anchor) else {
            throw OuraRawHistoryStoreError.invalid("anchor backfill range")
        }
        return try syncWrite { db in
            try db.execute(
                sql: """
                    UPDATE ouraRawHistory
                    SET anchorUtcMilliseconds = ?,
                        anchorRingTimestamp = ?,
                        anchorFactorMillisecondsPerTick = ?,
                        decodedRevision = 0
                    WHERE deviceId = ?
                      AND archiveId >= ? AND archiveId <= ?
                      AND anchorUtcMilliseconds IS NULL
                    """,
                arguments: [
                    anchor.utcMilliseconds,
                    Int64(anchor.ringTimestamp),
                    anchor.factorMillisecondsPerTick,
                    deviceId,
                    fromArchiveId,
                    throughArchiveId,
                ]
            )
            return db.changesCount
        }
    }

    /// Advance only rows whose typed writes completed *and* whose anchor/revision metadata still matches
    /// the snapshot that was decoded. An exact refetch may enrich an existing row in place and reset its
    /// revision while replay is running; this compare-and-set leaves that changed row pending instead of
    /// letting stale work mark the new anchor current. Per-row updates avoid SQLite variable limits.
    public func markOuraRawHistoryDecoded(
        records: [StoredOuraRawHistoryRecord],
        decoderRevision: Int
    ) async throws {
        guard decoderRevision > 0, records.allSatisfy({ $0.archiveId > 0 }) else {
            throw OuraRawHistoryStoreError.invalid("decoder revision")
        }
        guard !records.isEmpty else { return }
        try syncWrite { db in
            let update = try db.cachedStatement(sql: """
                UPDATE ouraRawHistory
                SET decodedRevision = ?
                WHERE archiveId = ?
                  AND decodedRevision = ? AND decodedRevision < ?
                  AND anchorUtcMilliseconds IS ?
                  AND anchorRingTimestamp IS ?
                  AND anchorFactorMillisecondsPerTick IS ?
                """)
            for record in records {
                try update.execute(arguments: [
                    decoderRevision,
                    record.archiveId,
                    record.decodedRevision,
                    decoderRevision,
                    record.timeAnchor?.utcMilliseconds,
                    record.timeAnchor.map { Int64($0.ringTimestamp) },
                    record.timeAnchor?.factorMillisecondsPerTick,
                ])
            }
        }
    }

    public func ouraRawHistoryWireBytes(deviceId: String) async throws -> Int64 {
        try syncRead { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(wireByteSize), 0) FROM ouraRawHistory WHERE deviceId = ?",
                arguments: [deviceId]
            ) ?? 0
        }
    }

    private static func validateOuraRawHistoryRecord(_ record: OuraRecord) throws {
        guard record.type >= 0x41 else {
            throw OuraRawHistoryStoreError.invalid("tag is not a history event")
        }
        // The TLV len byte includes four timestamp bytes, so a legal payload is at most 255 - 4.
        guard record.payload.count <= 251 else {
            throw OuraRawHistoryStoreError.invalid("payload exceeds TLV length")
        }
    }

    private static func decodeOuraRawHistoryRow(_ row: Row) -> StoredOuraRawHistoryRecord? {
        let rawTag: Int = row["tag"]
        let rawTimestamp: Int64 = row["ringTimestamp"]
        guard let tag = UInt8(exactly: rawTag),
              let ringTimestamp = UInt32(exactly: rawTimestamp) else { return nil }
        let anchor: OuraTimeAnchor?
        if let utcMilliseconds: Int64 = row["anchorUtcMilliseconds"],
           let rawAnchorTimestamp: Int64 = row["anchorRingTimestamp"],
           let anchorRingTimestamp = UInt32(exactly: rawAnchorTimestamp),
           let factor: Int64 = row["anchorFactorMillisecondsPerTick"] {
            let candidate = OuraTimeAnchor(
                ringTimestamp: anchorRingTimestamp,
                utcMilliseconds: utcMilliseconds,
                factorMillisecondsPerTick: factor
            )
            anchor = OuraTimeAnchorMapping.isValid(candidate) ? candidate : nil
        } else {
            anchor = nil
        }
        return StoredOuraRawHistoryRecord(
            archiveId: row["archiveId"],
            tag: tag,
            ringTimestamp: ringTimestamp,
            payload: row["payload"],
            firstSeenAtUnixMs: row["firstSeenAtUnixMs"],
            timeAnchor: anchor,
            decodedRevision: row["decodedRevision"]
        )
    }
}

public enum OuraRawHistoryStoreError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let reason): return "invalid Oura raw-history record: \(reason)"
        }
    }
}
