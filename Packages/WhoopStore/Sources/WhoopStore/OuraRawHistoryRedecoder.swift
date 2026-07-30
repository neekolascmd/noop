import Foundation
import OuraProtocol
import WhoopProtocol

/// Increment this only when a clean-room Oura decoder or durable mapping changes in a way that can
/// recover new information from already-retained TLVs. It is intentionally independent of app version.
public enum OuraRawHistoryDecoderRevision {
    public static let current = 4
}

public struct OuraRawHistoryRedecodeReport: Equatable, Sendable {
    public var decodedRecords = 0
    public var insertedRows = 0
    public var sleepSessions = 0
    public var withheldEvents = 0
    public var anchorRowsBackfilled = 0

    public init() {}
}

struct OuraRawHistoryPageDecode {
    var streams = Streams()
    var sleepWindows: [(start: Int, end: Int)] = []
    var withheldEvents = 0
}

enum OuraRawHistoryPageDecoder {
    static func decode(
        _ rows: [StoredOuraRawHistoryRecord],
        ringGen: OuraRingGen
    ) -> OuraRawHistoryPageDecode {
        let driver = OuraDriver(ringGen: ringGen, authKey: nil, allowTierB: false)
        var output = OuraRawHistoryPageDecode()
        for row in rows {
            let events = driver.ingest(record: row.record)
            for event in events {
                if case .bedtimePeriod(let period) = event {
                    guard let anchor = row.timeAnchor,
                          let rawStart = OuraTimeAnchorMapping.unixSeconds(
                            forRingTimestamp: period.startRingTimestamp,
                            using: anchor
                          ),
                          let rawEnd = OuraTimeAnchorMapping.unixSeconds(
                            forRingTimestamp: period.endRingTimestamp,
                            using: anchor
                          ),
                          let start = Int(exactly: rawStart),
                          let end = Int(exactly: rawEnd),
                          (15 * 60 ... 16 * 60 * 60).contains(end - start) else {
                        output.withheldEvents += 1
                        continue
                    }
                    output.sleepWindows.append((start, end))
                    continue
                }

                guard eventRequiresDurableTimestamp(event) else { continue }
                guard physiologicallyPlausible(event),
                      let anchor = row.timeAnchor,
                      let rawTimestamp = OuraTimeAnchorMapping.unixSeconds(
                        forRingTimestamp: event.ringTimestampForArchiveReplay,
                        using: anchor
                      ),
                      let timestamp = Int(exactly: rawTimestamp) else {
                    output.withheldEvents += 1
                    continue
                }
                append(
                    OuraStreamMapping.streams(from: [event], at: timestamp),
                    to: &output.streams
                )
            }
        }
        return output
    }

    private static func physiologicallyPlausible(_ event: OuraEvent) -> Bool {
        switch event {
        case .hr(let value): return (30...220).contains(value.bpm)
        case .temp(let value): return (20...45).contains(value.celsius)
        default: return true
        }
    }

    private static func eventRequiresDurableTimestamp(_ event: OuraEvent) -> Bool {
        switch event {
        case .hr, .ibi, .hrv, .spo2, .spo2Ratio, .temp, .sleepPhase, .sleepPeriod,
             .motionSummary, .sleepAcmPeriod:
            return true
        case .bedtimePeriod, .battery, .motion, .state, .timeSync, .rtcBeacon, .debugText,
             .tierB, .activityInfo:
            return false
        }
    }

    private static func append(_ source: Streams, to destination: inout Streams) {
        destination.hr.append(contentsOf: source.hr)
        destination.rr.append(contentsOf: source.rr)
        destination.spo2.append(contentsOf: source.spo2)
        destination.skinTemp.append(contentsOf: source.skinTemp)
        destination.resp.append(contentsOf: source.resp)
        destination.gravity.append(contentsOf: source.gravity)
        destination.steps.append(contentsOf: source.steps)
        destination.sleepState.append(contentsOf: source.sleepState)
        destination.ppgHr.append(contentsOf: source.ppgHr)
        destination.events.append(contentsOf: source.events)
        destination.battery.append(contentsOf: source.battery)
    }
}

private extension OuraEvent {
    var ringTimestampForArchiveReplay: UInt32 {
        switch self {
        case .hr(let value): return value.ringTimestamp
        case .ibi(let value): return value.ringTimestamp
        case .hrv(let value): return value.ringTimestamp
        case .spo2(let value): return value.ringTimestamp
        case .spo2Ratio(let value, _): return value.ringTimestamp
        case .temp(let value): return value.ringTimestamp
        case .sleepPhase(let value): return value.ringTimestamp
        case .sleepPeriod(let value): return value.ringTimestamp
        case .bedtimePeriod(let value): return value.ringTimestamp
        case .motion(let value): return value.ringTimestamp
        case .motionSummary(let value): return value.ringTimestamp
        case .sleepAcmPeriod(let value): return value.ringTimestamp
        case .state(let value): return value.ringTimestamp
        case .timeSync(let value): return value.ringTimestamp
        case .rtcBeacon(let value): return value.ringTimestamp
        case .debugText(let ringTimestamp, _): return ringTimestamp
        case .tierB(let value): return value.ringTimestamp
        case .activityInfo(let value): return value.ringTimestamp
        case .battery: return 0
        }
    }
}

extension WhoopStore {
    /// Re-run the current clean-room decoder against retained Oura TLVs without BLE, the Oura app, or a
    /// network account. Work is page-bounded; typed writes use natural keys; a page's revision advances
    /// only after all stream and sleep writes complete, so process death simply retries idempotently.
    public func redecodeOuraRawHistory(
        deviceId: String,
        ringGen: OuraRingGen,
        decoderRevision: Int = OuraRawHistoryDecoderRevision.current,
        pageSize: Int = 2_000
    ) async throws -> OuraRawHistoryRedecodeReport {
        guard !deviceId.isEmpty, decoderRevision > 0 else {
            throw OuraRawHistoryStoreError.invalid("offline decoder request")
        }
        let boundedPageSize = min(max(pageSize, 1), 10_000)
        var report = OuraRawHistoryRedecodeReport()
        var attemptedAnchorBackfill = false

        while true {
            try Task.checkCancellation()
            var rows = try await ouraRawHistoryRecordsNeedingDecode(
                deviceId: deviceId,
                decoderRevision: decoderRevision,
                limit: boundedPageSize
            )
            guard !rows.isEmpty else { return report }

            if !attemptedAnchorBackfill, rows.contains(where: { $0.timeAnchor == nil }) {
                report.anchorRowsBackfilled += try await backfillOuraRawHistoryTimeAnchors(
                    deviceId: deviceId,
                    ringGen: ringGen,
                    pageSize: max(boundedPageSize, 5_000)
                )
                attemptedAnchorBackfill = true
                rows = try await ouraRawHistoryRecordsNeedingDecode(
                    deviceId: deviceId,
                    decoderRevision: decoderRevision,
                    limit: boundedPageSize
                )
                guard !rows.isEmpty else { return report }
            }

            let decoded = OuraRawHistoryPageDecoder.decode(rows, ringGen: ringGen)
            if !decoded.streams.isEmpty {
                let counts = try await insert(decoded.streams, deviceId: deviceId)
                report.insertedRows += counts.hr + counts.rr + counts.events + counts.battery
                    + counts.spo2 + counts.skinTemp + counts.resp + counts.gravity
            }
            if !decoded.sleepWindows.isEmpty {
                let sessions = decoded.sleepWindows.map {
                    CachedSleepSession(
                        startTs: $0.start,
                        endTs: $0.end,
                        efficiency: nil,
                        restingHr: nil,
                        avgHrv: nil,
                        stagesJSON: nil
                    )
                }
                _ = try await upsertSleepSessions(sessions, deviceId: deviceId + "-noop")
                report.sleepSessions += sessions.count
            }

            // This is deliberately last. A throw above leaves every row on the older revision, so the
            // next run repeats the idempotent typed writes rather than silently skipping partial work.
            try await markOuraRawHistoryDecoded(
                archiveIds: rows.map(\.archiveId),
                decoderRevision: decoderRevision
            )
            report.decodedRecords += rows.count
            report.withheldEvents += decoded.withheldEvents
        }
    }

    /// Populate anchor metadata for pre-v26 rows from their own verified 0x42/0x85 records. The scan is
    /// insertion-ordered and page-bounded. A regressing ring-start opens a new segment so an anchor is
    /// never carried across a proven ring-clock reset.
    private func backfillOuraRawHistoryTimeAnchors(
        deviceId: String,
        ringGen: OuraRingGen,
        pageSize: Int
    ) async throws -> Int {
        var afterArchiveId: Int64 = 0
        var previousRingTimestamp: UInt32 = 0
        var previousArchiveId: Int64 = 0
        var unassignedStart: Int64?
        var currentAnchor: OuraTimeAnchor?
        var changed = 0

        while true {
            try Task.checkCancellation()
            let rows = try await ouraRawHistoryRecords(
                deviceId: deviceId,
                afterArchiveId: afterArchiveId,
                limit: pageSize
            )
            guard !rows.isEmpty else { return changed }
            var assignments: [(OuraTimeAnchor, Int64, Int64)] = []

            for row in rows {
                if unassignedStart == nil { unassignedStart = row.archiveId }
                if row.tag == OuraEventTag.ringStart.rawValue,
                   previousRingTimestamp != 0,
                   row.ringTimestamp < previousRingTimestamp {
                    if let currentAnchor, let start = unassignedStart, start <= previousArchiveId {
                        assignments.append((currentAnchor, start, previousArchiveId))
                    }
                    currentAnchor = nil
                    unassignedStart = row.archiveId
                }

                if let stored = row.timeAnchor {
                    currentAnchor = stored
                    if let start = unassignedStart, start < row.archiveId {
                        assignments.append((stored, start, row.archiveId - 1))
                    }
                    unassignedStart = row.archiveId + 1
                } else if let discovered = Self.archiveAnchor(from: row.record, ringGen: ringGen) {
                    currentAnchor = discovered
                    if let start = unassignedStart, start <= row.archiveId {
                        assignments.append((discovered, start, row.archiveId))
                    }
                    unassignedStart = row.archiveId + 1
                }

                previousRingTimestamp = row.ringTimestamp
                previousArchiveId = row.archiveId
            }

            if let currentAnchor, let start = unassignedStart, start <= previousArchiveId {
                assignments.append((currentAnchor, start, previousArchiveId))
                unassignedStart = previousArchiveId + 1
            }
            for (anchor, start, end) in assignments where start <= end {
                changed += try await setOuraRawHistoryTimeAnchor(
                    anchor,
                    deviceId: deviceId,
                    fromArchiveId: start,
                    throughArchiveId: end
                )
            }
            afterArchiveId = rows.last!.archiveId
        }
    }

    private static func archiveAnchor(
        from record: OuraRecord,
        ringGen: OuraRingGen
    ) -> OuraTimeAnchor? {
        switch record.type {
        case OuraEventTag.timeSync.rawValue:
            return OuraDecoders.decodeTimeSync(record, ringGen: ringGen)
                .flatMap(OuraTimeAnchorMapping.anchor(from:))
        case OuraEventTag.rtcBeacon.rawValue:
            return OuraDecoders.decodeRtcBeacon(record)
                .flatMap(OuraTimeAnchorMapping.anchor(from:))
        default:
            return nil
        }
    }
}
