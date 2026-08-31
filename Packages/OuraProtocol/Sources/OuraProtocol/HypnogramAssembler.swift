import Foundation

// SleepNet writes a completed night's phase codes to history in a compact burst after the night ends.
// The records' envelope ring timestamps therefore describe the write/finalization burst, not each
// sleep epoch. This platform-pure accumulator preserves the wire arrival order and reconstructs the
// sequence backward from a caller-supplied sleep-window end at the observed 30-second epoch cadence.

/// One reconstructed SleepNet epoch. `ts` is the Unix-second start of the 30-second stage interval.
public struct OuraHypnogramEpoch: Equatable, Sendable, Codable {
    public let stage: OuraSleepStage
    public let ts: Int

    public init(stage: OuraSleepStage, ts: Int) {
        self.stage = stage
        self.ts = ts
    }
}

/// One atomic sleep-phase record as fed to the burst assembler.
public struct OuraHypnogramRecord: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let stages: [OuraSleepStage]
    /// One flag per stage. Unwritten slots keep their position in the time axis but are not emitted.
    public let unwritten: [Bool]
    /// Optional resolved Unix time of the record envelope. It is observability/anchoring evidence only;
    /// phase order always follows arrival order rather than sorting these near-identical write times.
    public let envelopeUnixSeconds: Int?

    public init(ringTimestamp: UInt32, stages: [OuraSleepStage], unwritten: [Bool]? = nil,
                envelopeUnixSeconds: Int? = nil) {
        if let unwritten {
            precondition(unwritten.count == stages.count,
                         "Oura hypnogram unwritten flags must match the stage count")
        }
        self.ringTimestamp = ringTimestamp
        self.stages = stages
        self.unwritten = unwritten ?? Array(repeating: false, count: stages.count)
        self.envelopeUnixSeconds = envelopeUnixSeconds
    }
}

/// One completed burst of consecutive sleep-phase records, usually one whole-night hypnogram.
public struct OuraHypnogramBurst: Equatable, Sendable, Codable {
    /// Records remain in arrival/log order. Never sort them by their finalization timestamps.
    public let records: [OuraHypnogramRecord]

    public init(records: [OuraHypnogramRecord]) {
        self.records = records
    }

    public var totalCodes: Int { records.reduce(0) { $0 + $1.stages.count } }
    public var lastRingTimestamp: UInt32 { records.last?.ringTimestamp ?? 0 }

    /// The most recent usable envelope anchor in arrival order, if the caller resolved one.
    public var lastEnvelopeUnixSeconds: Int? {
        records.lazy.reversed().compactMap(\.envelopeUnixSeconds).first
    }

    /// Surfaces out-of-order envelope clocks without reordering the authoritative phase sequence.
    public var hasNonMonotonicRingTimes: Bool {
        zip(records, records.dropFirst()).contains { $1.ringTimestamp < $0.ringTimestamp }
    }

    /// Lay all stages backward from `endUnixSeconds`. For N stages, stage j starts at
    /// `end - (N - j) * secondsPerCode`, so the final interval ends exactly at `end`.
    ///
    /// If a 0x49 onset is supplied, leading epochs before it are clipped. A clamp that would remove
    /// every epoch is ignored so a stale or mismatched window cannot erase an otherwise valid burst.
    public func codesWithTimes(endUnixSeconds: Int,
                               sleepStartUnixSeconds: Int? = nil,
                               secondsPerCode: Int = 30) -> [OuraHypnogramEpoch] {
        guard secondsPerCode > 0, totalCodes > 0 else { return [] }
        let (duration, durationOverflow) = totalCodes.multipliedReportingOverflow(by: secondsPerCode)
        guard !durationOverflow else { return [] }
        let (firstTimestamp, timestampOverflow) = endUnixSeconds.subtractingReportingOverflow(duration)
        guard !timestampOverflow else { return [] }

        var output: [OuraHypnogramEpoch] = []
        output.reserveCapacity(totalCodes)
        var index = 0
        for record in records {
            for (recordIndex, stage) in record.stages.enumerated() {
                let (offset, offsetOverflow) = index.multipliedReportingOverflow(by: secondsPerCode)
                guard !offsetOverflow else { return [] }
                let (timestamp, additionOverflow) = firstTimestamp.addingReportingOverflow(offset)
                guard !additionOverflow else { return [] }
                if !record.unwritten[recordIndex] {
                    output.append(OuraHypnogramEpoch(stage: stage, ts: timestamp))
                }
                index += 1
            }
        }

        guard let sleepStartUnixSeconds else { return output }
        let clipped = output.filter { $0.ts >= sleepStartUnixSeconds }
        return clipped.isEmpty ? output : clipped
    }
}

/// Accumulates phase records whose finalization envelopes are within one burst gap. Oura ring ticks
/// are 100 ms, so the default 600-tick threshold allows a 60-second write burst while separating
/// distinct nights or analysis passes.
public final class OuraHypnogramAssembler {
    public let burstGapTicks: UInt32
    private var current: [OuraHypnogramRecord] = []

    /// Ring timestamps use 100 ms ticks. Keep the independently anchored wall-clock boundary in step
    /// with the configured raw-tick boundary, rounding a partial second upward.
    private var burstGapSeconds: Int {
        Int(burstGapTicks / 10 + (burstGapTicks % 10 == 0 ? 0 : 1))
    }

    public init(burstGapTicks: UInt32 = 600) {
        self.burstGapTicks = burstGapTicks
    }

    /// Feed a decoded atomic phase series. Returns the previous burst when this record starts a new
    /// one; otherwise returns nil while the current burst grows.
    public func feed(_ series: OuraSleepPhaseSeries,
                     envelopeUnixSeconds: Int? = nil) -> OuraHypnogramBurst? {
        feed(record: OuraHypnogramRecord(ringTimestamp: series.ringTimestamp,
                                         stages: series.stages,
                                         unwritten: series.unwritten,
                                         envelopeUnixSeconds: envelopeUnixSeconds))
    }

    /// Convenience for replay paths that already hold the record fields separately.
    public func feed(ringTimestamp: UInt32, stages: [OuraSleepStage], unwritten: [Bool]? = nil,
                     envelopeUnixSeconds: Int? = nil) -> OuraHypnogramBurst? {
        feed(record: OuraHypnogramRecord(ringTimestamp: ringTimestamp,
                                         stages: stages,
                                         unwritten: unwritten,
                                         envelopeUnixSeconds: envelopeUnixSeconds))
    }

    /// Feed one value record. Empty records are ignored and never open a burst.
    public func feed(record: OuraHypnogramRecord) -> OuraHypnogramBurst? {
        guard !record.stages.isEmpty else { return nil }
        if let previous = current.last {
            let gap = record.ringTimestamp >= previous.ringTimestamp
                ? record.ringTimestamp - previous.ringTimestamp
                : previous.ringTimestamp - record.ringTimestamp
            let crossesEnvelopeBoundary: Bool
            switch (previous.envelopeUnixSeconds, record.envelopeUnixSeconds) {
            case let (previousUnix?, currentUnix?):
                let wallGap = currentUnix >= previousUnix
                    ? currentUnix - previousUnix
                    : previousUnix - currentUnix
                crossesEnvelopeBoundary = wallGap > burstGapSeconds
            case (nil, nil):
                crossesEnvelopeBoundary = false
            default:
                // Mixed anchor availability is ambiguous at an archive/clock boundary. Splitting may
                // withhold a partial burst, but can never let unanchored stale slots complete a new night.
                crossesEnvelopeBoundary = true
            }
            if gap > burstGapTicks || crossesEnvelopeBoundary {
                let completed = OuraHypnogramBurst(records: current)
                current = [record]
                return completed
            }
        }
        current.append(record)
        return nil
    }

    /// Close and return the in-progress burst at history-drain end, or nil if no records are pending.
    public func finish() -> OuraHypnogramBurst? {
        guard !current.isEmpty else { return nil }
        let completed = OuraHypnogramBurst(records: current)
        current.removeAll(keepingCapacity: true)
        return completed
    }

    /// Compatibility spelling for callers that treat drain completion as a flush.
    public func flush() -> OuraHypnogramBurst? { finish() }

    public func reset() {
        current.removeAll(keepingCapacity: true)
    }

    public var pendingRecordCount: Int { current.count }
}
