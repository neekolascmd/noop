import OuraProtocol

struct OuraSleepNetWindowCandidate: Equatable, Sendable {
    let ringTimestamp: UInt32
    let eventUnixSeconds: Int
    let startUnixSeconds: Int
    let endUnixSeconds: Int
}

enum OuraSleepNetWindowPairing {
    static let toleranceTicks: UInt32 = 6_000 // 10 minutes at 100 ms/tick
    static let toleranceSeconds = 10 * 60

    static func closest(
        to ringTimestamp: UInt32,
        envelopeUnixSeconds: Int,
        in candidates: [OuraSleepNetWindowCandidate],
        toleranceTicks: UInt32 = toleranceTicks,
        toleranceSeconds: Int = toleranceSeconds
    ) -> OuraSleepNetWindowCandidate? {
        candidates
            .compactMap { candidate -> (OuraSleepNetWindowCandidate, UInt32, Int)? in
                let tickGap = candidate.ringTimestamp >= ringTimestamp
                    ? candidate.ringTimestamp - ringTimestamp
                    : ringTimestamp - candidate.ringTimestamp
                let timeGap = candidate.eventUnixSeconds >= envelopeUnixSeconds
                    ? candidate.eventUnixSeconds - envelopeUnixSeconds
                    : envelopeUnixSeconds - candidate.eventUnixSeconds
                guard tickGap <= toleranceTicks, timeGap <= toleranceSeconds else { return nil }
                return (candidate, tickGap, timeGap)
            }
            .min { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
                return lhs.0.ringTimestamp < rhs.0.ringTimestamp
            }?
            .0
    }
}

enum OuraSleepNetPersistencePolicy {
    static let secondsPerEpoch = 30
    static let minimumObservedCoverageForEfficiency = 0.95

    /// The ring may re-serve the same 0x49 window with a few seconds of anchor jitter. A nearest-minute
    /// onset is stable across those observations and therefore safe to use as the session primary key.
    static func stableStartUnixSeconds(_ rawStartUnixSeconds: Int) -> Int {
        ((rawStartUnixSeconds + 30) / 60) * 60
    }

    static func epochsWithinStableWindow(
        _ epochs: [OuraHypnogramEpoch],
        startUnixSeconds: Int,
        endUnixSeconds: Int
    ) -> [OuraHypnogramEpoch] {
        epochs.filter { $0.ts >= startUnixSeconds && $0.ts < endUnixSeconds }
    }

    static func coveredSeconds(
        by epochs: [OuraHypnogramEpoch],
        secondsPerEpoch: Int = secondsPerEpoch
    ) -> Int {
        guard secondsPerEpoch > 0 else { return 0 }
        return Set(epochs.map(\.ts)).count * secondsPerEpoch
    }

    /// Slot count includes erased/unwritten positions. A burst is terminal only when its complete time
    /// axis spans the anchored window; written-stage coverage is a separate quality measurement.
    static func structurallySpansWindow(
        totalCodeSlots: Int,
        startUnixSeconds: Int,
        endUnixSeconds: Int,
        secondsPerEpoch: Int = secondsPerEpoch
    ) -> Bool {
        let duration = endUnixSeconds - startUnixSeconds
        guard totalCodeSlots > 0, duration > 0, secondsPerEpoch > 0 else { return false }
        let (slotSeconds, overflow) = totalCodeSlots.multipliedReportingOverflow(by: secondsPerEpoch)
        return !overflow && slotSeconds >= duration
    }

    static func observedCoverage(
        epochs: [OuraHypnogramEpoch],
        startUnixSeconds: Int,
        endUnixSeconds: Int
    ) -> Double {
        let duration = endUnixSeconds - startUnixSeconds
        guard duration > 0 else { return 0 }
        let covered = min(duration, coveredSeconds(by: epochs))
        return Double(covered) / Double(duration)
    }

    static func hasCompleteObservedCoverage(
        epochs: [OuraHypnogramEpoch],
        startUnixSeconds: Int,
        endUnixSeconds: Int,
        minimumCoverage: Double = minimumObservedCoverageForEfficiency
    ) -> Bool {
        guard minimumCoverage > 0, minimumCoverage <= 1 else { return false }
        return observedCoverage(
            epochs: epochs,
            startUnixSeconds: startUnixSeconds,
            endUnixSeconds: endUnixSeconds
        ) >= minimumCoverage
    }
}

private struct OuraSleepNetPersistableCandidate {
    let session: CachedSleepSession
    let coveredSeconds: Int
}

extension WhoopStore {
    /// Reconstruct every complete Oura SleepNet burst from the bounded raw archive. This deliberately
    /// scans across storage pages: a whole-night burst commonly contains dozens of TLVs and a page-local
    /// decoder could split one night into several false sessions. The phase code accumulator is bounded
    /// by one burst; only compact, validated 0x49 window candidates and completed nights are retained.
    func rebuildOuraSleepNetSessions(
        deviceId: String,
        throughArchiveId: Int64,
        pageSize: Int
    ) async throws -> [CachedSleepSession] {
        let boundedPageSize = min(max(pageSize, 1), 10_000)
        var windows: [OuraSleepNetWindowCandidate] = []
        var afterArchiveId: Int64 = 0

        // Pass 1: establish true onset/wake bounds. SleepNet's phase envelopes describe the later write
        // burst, so they cannot provide the night's wall-clock end on their own.
        while true {
            try Task.checkCancellation()
            let rows = try await ouraRawHistoryRecords(
                deviceId: deviceId,
                afterArchiveId: afterArchiveId,
                throughArchiveId: throughArchiveId,
                limit: boundedPageSize
            )
            guard !rows.isEmpty else { break }
            for row in rows where row.tag == OuraEventTag.sleepSummary1.rawValue {
                guard let window = OuraDecoders.decodeSleepWindow(row.record),
                      let anchor = row.timeAnchor,
                      let rawEventTime = OuraTimeAnchorMapping.unixSeconds(
                        forRingTimestamp: window.ringTimestamp,
                        using: anchor
                      ),
                      let eventTime = Int(exactly: rawEventTime),
                      window.startOffsetMinutes > window.endOffsetMinutes else { continue }
                let start = eventTime - window.startOffsetMinutes * 60
                let end = eventTime - window.endOffsetMinutes * 60
                guard (15 * 60 ... 16 * 60 * 60).contains(end - start) else { continue }
                windows.append(
                    OuraSleepNetWindowCandidate(
                        ringTimestamp: window.ringTimestamp,
                        eventUnixSeconds: eventTime,
                        startUnixSeconds: start,
                        endUnixSeconds: end
                    )
                )
            }
            afterArchiveId = rows.last!.archiveId
        }
        guard !windows.isEmpty else { return [] }

        // Oura hardware has existed for far fewer than 8,192 nights. Bounding stale/corrupt archives here
        // keeps an adversarial tag-only archive finite without discarding any plausible retained history.
        if windows.count > 8_192 { windows.removeFirst(windows.count - 8_192) }

        // Pass 2: preserve log/arrival order across page boundaries and close bursts only on their ring-
        // time gap. Pairing happens after a burst closes, against all validated windows from pass 1.
        let assembler = OuraHypnogramAssembler()
        var sessionsByStart: [Int: OuraSleepNetPersistableCandidate] = [:]
        afterArchiveId = 0

        func appendSession(from burst: OuraHypnogramBurst) {
            guard let envelopeUnixSeconds = burst.lastEnvelopeUnixSeconds else { return }
            guard let window = OuraSleepNetWindowPairing.closest(
                to: burst.lastRingTimestamp,
                envelopeUnixSeconds: envelopeUnixSeconds,
                in: windows
            ),
                  OuraSleepNetPersistencePolicy.structurallySpansWindow(
                    totalCodeSlots: burst.totalCodes,
                    startUnixSeconds: window.startUnixSeconds,
                    endUnixSeconds: window.endUnixSeconds
                  ) else { return }
            let laidOutEpochs = burst.codesWithTimes(
                endUnixSeconds: window.endUnixSeconds,
                sleepStartUnixSeconds: window.startUnixSeconds
            )
            let stableStart = OuraSleepNetPersistencePolicy.stableStartUnixSeconds(
                window.startUnixSeconds
            )
            let epochs = OuraSleepNetPersistencePolicy.epochsWithinStableWindow(
                laidOutEpochs,
                startUnixSeconds: stableStart,
                endUnixSeconds: window.endUnixSeconds
            )
            let hasCompleteObservedCoverage =
                OuraSleepNetPersistencePolicy.hasCompleteObservedCoverage(
                    epochs: epochs,
                    startUnixSeconds: stableStart,
                    endUnixSeconds: window.endUnixSeconds
                )
            guard let session = OuraSleepSessionMapping.session(
                    from: epochs,
                    sessionStartUnixSeconds: stableStart,
                    sessionEndUnixSeconds: window.endUnixSeconds,
                    includeEfficiency: hasCompleteObservedCoverage
                  ),
                  (15 * 60 ... 16 * 60 * 60).contains(session.endTs - session.startTs) else { return }
            let candidate = OuraSleepNetPersistableCandidate(
                session: session,
                coveredSeconds: OuraSleepNetPersistencePolicy.coveredSeconds(by: epochs)
            )
            if let existing = sessionsByStart[stableStart],
               existing.coveredSeconds > candidate.coveredSeconds
                || (existing.coveredSeconds == candidate.coveredSeconds
                    && existing.session.endTs >= candidate.session.endTs) {
                return
            }
            sessionsByStart[stableStart] = candidate
        }

        while true {
            try Task.checkCancellation()
            let rows = try await ouraRawHistoryRecords(
                deviceId: deviceId,
                afterArchiveId: afterArchiveId,
                throughArchiveId: throughArchiveId,
                limit: boundedPageSize
            )
            guard !rows.isEmpty else { break }
            for row in rows where row.tag == OuraEventTag.sleepPhaseInfo.rawValue
                || row.tag == OuraEventTag.sleepPhase.rawValue
                || row.tag == OuraEventTag.sleepPhaseAlt.rawValue {
                guard let series = OuraDecoders.decodeSleepPhase(row.record) else { continue }
                let envelopeUnixSeconds = row.timeAnchor.flatMap {
                    OuraTimeAnchorMapping.unixSeconds(
                        forRingTimestamp: series.ringTimestamp,
                        using: $0
                    ).flatMap(Int.init(exactly:))
                }
                if let closed = assembler.feed(
                    series,
                    envelopeUnixSeconds: envelopeUnixSeconds
                ) {
                    appendSession(from: closed)
                }
            }
            afterArchiveId = rows.last!.archiveId
        }
        if let final = assembler.finish() { appendSession(from: final) }
        return sessionsByStart.values.map(\.session).sorted { $0.startTs < $1.startTs }
    }
}
