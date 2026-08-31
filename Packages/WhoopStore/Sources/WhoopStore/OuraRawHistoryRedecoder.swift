import Foundation
import OuraProtocol
import WhoopProtocol

/// Increment this only when a clean-room Oura decoder or durable mapping changes in a way that can
/// recover new information from already-retained TLVs. It is intentionally independent of app version.
public enum OuraRawHistoryDecoderRevision {
    public static let current = 8
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
             .motionSummary, .sleepAcmPeriod, .activityInfo, .exerciseHRIntensity,
             .realStepsFeatures, .alwaysOnHR:
            return true
        case .sleepWindow, .bedtimePeriod, .battery, .motion, .state, .timeSync, .rtcBeacon, .debugText,
             .tierB:
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
        case .sleepWindow(let value): return value.ringTimestamp
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
        case .exerciseHRIntensity(let value): return value.ringTimestamp
        case .realStepsFeatures(let value): return value.ringTimestamp
        case .alwaysOnHR(let value): return value.ringTimestamp
        case .battery: return 0
        }
    }
}

extension WhoopStore {
    private static let ouraAnchorBackfillCohortToleranceMilliseconds: Int64 = 10 * 60 * 1_000

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
        let throughArchiveId = try await ouraRawHistoryHighWaterArchiveId(deviceId: deviceId)
        guard throughArchiveId > 0 else { return report }

        // A fresh anchor can make older, previously withheld SleepNet rows decodable even when the new
        // row itself is not a sleep tag. Repair that relationship before evaluating the SleepNet gate.
        let sleepNetWasPending = try await hasOuraRawSleepNetRecordsNeedingDecode(
            deviceId: deviceId,
            decoderRevision: decoderRevision,
            throughArchiveId: throughArchiveId
        )
        let anchorEvidenceWasPending = try await hasOuraRawAnchorEvidenceNeedingDecode(
            deviceId: deviceId,
            decoderRevision: decoderRevision,
            throughArchiveId: throughArchiveId
        )
        if sleepNetWasPending || anchorEvidenceWasPending,
           try await hasOuraRawHistoryRowsWithoutTimeAnchor(
                deviceId: deviceId,
                throughArchiveId: throughArchiveId
           ) {
            report.anchorRowsBackfilled += try await backfillOuraRawHistoryTimeAnchors(
                deviceId: deviceId,
                ringGen: ringGen,
                throughArchiveId: throughArchiveId,
                pageSize: max(boundedPageSize, 5_000)
            )
            attemptedAnchorBackfill = true
        }

        // SleepNet bursts may cross page boundaries, so reconstruct them once from this run's complete
        // high-water snapshot before advancing any contained row's decoder revision.
        if try await hasOuraRawSleepNetRecordsNeedingDecode(
            deviceId: deviceId,
            decoderRevision: decoderRevision,
            throughArchiveId: throughArchiveId
        ) {
            let stagedSessions = try await rebuildOuraSleepNetSessions(
                deviceId: deviceId,
                throughArchiveId: throughArchiveId,
                pageSize: boundedPageSize
            )
            if !stagedSessions.isEmpty {
                _ = try await upsertOuraSleepNetSessions(stagedSessions, deviceId: deviceId)
                report.sleepSessions += stagedSessions.count
            }
        }

        while true {
            try Task.checkCancellation()
            var rows = try await ouraRawHistoryRecordsNeedingDecode(
                deviceId: deviceId,
                decoderRevision: decoderRevision,
                throughArchiveId: throughArchiveId,
                limit: boundedPageSize
            )
            guard !rows.isEmpty else { return report }

            if !attemptedAnchorBackfill, rows.contains(where: { $0.timeAnchor == nil }) {
                report.anchorRowsBackfilled += try await backfillOuraRawHistoryTimeAnchors(
                    deviceId: deviceId,
                    ringGen: ringGen,
                    throughArchiveId: throughArchiveId,
                    pageSize: max(boundedPageSize, 5_000)
                )
                attemptedAnchorBackfill = true
                rows = try await ouraRawHistoryRecordsNeedingDecode(
                    deviceId: deviceId,
                    decoderRevision: decoderRevision,
                    throughArchiveId: throughArchiveId,
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
                records: rows,
                decoderRevision: decoderRevision
            )
            report.decodedRecords += rows.count
            report.withheldEvents += decoded.withheldEvents
        }
    }

    /// Populate anchor metadata for pre-v26 rows from their own verified 0x42/0x85 records. The scan is
    /// insertion-ordered and page-bounded. A regressing ring-start opens a new segment. Backward and
    /// forward propagation are additionally limited to a ten-minute local receipt cohort, and projected
    /// UTC may not land materially after receipt; ambiguous gaps remain unanchored instead of crossing a
    /// missing clock-reset marker.
    private func backfillOuraRawHistoryTimeAnchors(
        deviceId: String,
        ringGen: OuraRingGen,
        throughArchiveId: Int64,
        pageSize: Int
    ) async throws -> Int {
        var afterArchiveId: Int64 = 0
        var previousRingTimestamp: UInt32 = 0
        var previousArchiveId: Int64 = 0
        var unassignedStart: Int64?
        var currentAnchor: OuraTimeAnchor?
        var currentAnchorArchiveId: Int64?
        var currentAnchorFirstSeenAtUnixMs: Int64?
        var changed = 0

        while true {
            try Task.checkCancellation()
            let rows = try await ouraRawHistoryRecords(
                deviceId: deviceId,
                afterArchiveId: afterArchiveId,
                throughArchiveId: throughArchiveId,
                limit: pageSize
            )
            guard !rows.isEmpty else { return changed }
            var assignments: [(anchor: OuraTimeAnchor, start: Int64, end: Int64,
                               carrierArchiveId: Int64, carrierFirstSeenAtUnixMs: Int64)] = []

            for row in rows {
                if unassignedStart == nil { unassignedStart = row.archiveId }
                if row.tag == OuraEventTag.ringStart.rawValue,
                   previousRingTimestamp != 0,
                   row.ringTimestamp < previousRingTimestamp {
                    if let currentAnchor,
                       let carrierArchiveId = currentAnchorArchiveId,
                       let carrierFirstSeen = currentAnchorFirstSeenAtUnixMs,
                       let start = unassignedStart,
                       start <= previousArchiveId {
                        assignments.append((currentAnchor, start, previousArchiveId,
                                            carrierArchiveId, carrierFirstSeen))
                    }
                    currentAnchor = nil
                    currentAnchorArchiveId = nil
                    currentAnchorFirstSeenAtUnixMs = nil
                    unassignedStart = row.archiveId
                }

                if let stored = row.timeAnchor {
                    currentAnchor = stored
                    currentAnchorArchiveId = row.archiveId
                    currentAnchorFirstSeenAtUnixMs = row.firstSeenAtUnixMs
                    if let start = unassignedStart, start < row.archiveId {
                        assignments.append((stored, start, row.archiveId - 1,
                                            row.archiveId, row.firstSeenAtUnixMs))
                    }
                    unassignedStart = row.archiveId + 1
                } else if let discovered = Self.archiveAnchor(from: row.record, ringGen: ringGen) {
                    currentAnchor = discovered
                    currentAnchorArchiveId = row.archiveId
                    currentAnchorFirstSeenAtUnixMs = row.firstSeenAtUnixMs
                    if let start = unassignedStart, start <= row.archiveId {
                        assignments.append((discovered, start, row.archiveId,
                                            row.archiveId, row.firstSeenAtUnixMs))
                    }
                    unassignedStart = row.archiveId + 1
                }

                previousRingTimestamp = row.ringTimestamp
                previousArchiveId = row.archiveId
            }

            if let currentAnchor,
               let carrierArchiveId = currentAnchorArchiveId,
               let carrierFirstSeen = currentAnchorFirstSeenAtUnixMs,
               let start = unassignedStart,
               start <= previousArchiveId {
                assignments.append((currentAnchor, start, previousArchiveId,
                                    carrierArchiveId, carrierFirstSeen))
                unassignedStart = previousArchiveId + 1
            }
            for assignment in assignments where assignment.start <= assignment.end {
                let selection = try await eligibleOuraRawAnchorRangeAdjacentToCarrier(
                    deviceId: deviceId,
                    fromArchiveId: assignment.start,
                    throughArchiveId: assignment.end,
                    anchor: assignment.anchor,
                    anchorCarrierArchiveId: assignment.carrierArchiveId,
                    anchorCarrierFirstSeenAtUnixMs: assignment.carrierFirstSeenAtUnixMs,
                    pageSize: pageSize
                )
                if let eligibleRange = selection.range {
                    changed += try await setOuraRawHistoryTimeAnchor(
                        assignment.anchor,
                        deviceId: deviceId,
                        fromArchiveId: eligibleRange.start,
                        throughArchiveId: eligibleRange.end
                    )
                }
                if selection.forwardPropagationBlocked,
                   currentAnchorArchiveId == assignment.carrierArchiveId {
                    currentAnchor = nil
                    currentAnchorArchiveId = nil
                    currentAnchorFirstSeenAtUnixMs = nil
                    unassignedStart = selection.forwardBarrierArchiveId
                }
            }
            afterArchiveId = rows.last!.archiveId
        }
    }

    /// Return only the eligible component adjacent to the anchor carrier. For a backward range this is
    /// the suffix after the last incompatible row; for a forward range it is the prefix before the first.
    /// Thus an eligible island beyond an ambiguous reset boundary can never inherit the anchor.
    private func eligibleOuraRawAnchorRangeAdjacentToCarrier(
        deviceId: String,
        fromArchiveId: Int64,
        throughArchiveId: Int64,
        anchor: OuraTimeAnchor,
        anchorCarrierArchiveId: Int64,
        anchorCarrierFirstSeenAtUnixMs: Int64,
        pageSize: Int
    ) async throws -> (range: (start: Int64, end: Int64)?,
                       forwardPropagationBlocked: Bool,
                       forwardBarrierArchiveId: Int64?) {
        var afterArchiveId = fromArchiveId - 1
        let isForwardRange = anchorCarrierArchiveId < fromArchiveId
        var eligibleStart = fromArchiveId
        var eligibleEnd: Int64?
        var forwardBoundaryReached = false
        var forwardBarrierArchiveId: Int64?
        while afterArchiveId < throughArchiveId {
            let rows = try await ouraRawHistoryRecords(
                deviceId: deviceId,
                afterArchiveId: afterArchiveId,
                throughArchiveId: throughArchiveId,
                limit: pageSize
            )
            guard !rows.isEmpty else { break }
            for row in rows {
                let eligible = Self.canBackfillOuraRawAnchor(
                    row: row,
                    anchor: anchor,
                    anchorCarrierFirstSeenAtUnixMs: anchorCarrierFirstSeenAtUnixMs
                )
                if isForwardRange {
                    if !forwardBoundaryReached && eligible {
                        eligibleEnd = row.archiveId
                    } else if !eligible {
                        forwardBoundaryReached = true
                        if forwardBarrierArchiveId == nil {
                            forwardBarrierArchiveId = row.archiveId
                        }
                    }
                } else if !eligible {
                    eligibleStart = row.archiveId + 1
                }
            }
            afterArchiveId = rows.last!.archiveId
        }
        if isForwardRange {
            let range = eligibleEnd.map { (start: fromArchiveId, end: $0) }
            return (range, forwardBoundaryReached, forwardBarrierArchiveId)
        }
        let range = eligibleStart <= throughArchiveId
            ? (start: eligibleStart, end: throughArchiveId)
            : nil
        return (range, false, nil)
    }

    private static func canBackfillOuraRawAnchor(
        row: StoredOuraRawHistoryRecord,
        anchor: OuraTimeAnchor,
        anchorCarrierFirstSeenAtUnixMs: Int64
    ) -> Bool {
        let (receiptDelta, receiptDeltaOverflow) = anchorCarrierFirstSeenAtUnixMs >= row.firstSeenAtUnixMs
            ? anchorCarrierFirstSeenAtUnixMs.subtractingReportingOverflow(row.firstSeenAtUnixMs)
            : row.firstSeenAtUnixMs.subtractingReportingOverflow(anchorCarrierFirstSeenAtUnixMs)
        guard !receiptDeltaOverflow,
              receiptDelta <= ouraAnchorBackfillCohortToleranceMilliseconds,
              let projectedSeconds = OuraTimeAnchorMapping.unixSeconds(
                forRingTimestamp: row.ringTimestamp,
                using: anchor
              ) else { return false }
        let (projectedMilliseconds, projectionOverflow) = projectedSeconds.multipliedReportingOverflow(by: 1_000)
        let (latestPermittedMilliseconds, receiptOverflow) = row.firstSeenAtUnixMs.addingReportingOverflow(
            ouraAnchorBackfillCohortToleranceMilliseconds
        )
        return !projectionOverflow && !receiptOverflow
            && projectedMilliseconds <= latestPermittedMilliseconds
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
