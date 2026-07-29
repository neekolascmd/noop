import Foundation

/// Overflow-safe conversion between Oura's ring clock and UTC.
///
/// The protocol decoders intentionally preserve the raw `0x42` epoch in `OuraTimeSync.epochMs`
/// for source compatibility. Despite that historical property name, the verified Gen 3 and Ring 4
/// layouts both carry unix seconds. Keeping validation and arithmetic here gives the live transport
/// and future offline archive passes one byte-for-byte timestamp contract.
public enum OuraTimeAnchorMapping {
    /// 2020-01-01 through 2035-01-01. Values outside this window have appeared in malformed history
    /// records and must never be multiplied or trusted as real UTC.
    public static let minimumPlausibleEpochSeconds: Int64 = 1_577_836_800
    public static let maximumPlausibleEpochSeconds: Int64 = 2_051_222_400

    /// Build a validated anchor from a decoded `0x42` indication.
    public static func anchor(from sync: OuraTimeSync) -> OuraTimeAnchor? {
        anchor(
            ringTimestamp: sync.ringTimestamp,
            unixSeconds: sync.epochMs,
            factorMillisecondsPerTick: Int64(sync.factorMsPerTick)
        )
    }

    /// Build a validated 100-ms/tick anchor from a decoded `0x85` RTC beacon.
    public static func anchor(from beacon: OuraRtcBeacon) -> OuraTimeAnchor? {
        anchor(
            ringTimestamp: beacon.ringTimestamp,
            unixSeconds: Int64(beacon.unixSeconds),
            factorMillisecondsPerTick: 100
        )
    }

    /// Resolve one ring timestamp with a validated anchor. Arithmetic is checked before use, and the
    /// result is plausibility-gated so corrupt timestamps never become 1970/far-future health rows.
    public static func unixSeconds(
        forRingTimestamp ringTimestamp: UInt32,
        using anchor: OuraTimeAnchor
    ) -> Int64? {
        guard isValid(anchor) else { return nil }
        let deltaTicks = Int64(ringTimestamp) - Int64(anchor.ringTimestamp)
        let (offsetMs, offsetOverflow) = deltaTicks.multipliedReportingOverflow(
            by: anchor.factorMillisecondsPerTick
        )
        guard !offsetOverflow else { return nil }
        let (utcMs, additionOverflow) = anchor.utcMilliseconds.addingReportingOverflow(offsetMs)
        guard !additionOverflow else { return nil }
        let seconds = utcMs / 1_000
        guard isPlausible(unixSeconds: seconds) else { return nil }
        return seconds
    }

    public static func isValid(_ anchor: OuraTimeAnchor) -> Bool {
        guard anchor.ringTimestamp > 0,
              anchor.factorMillisecondsPerTick == 1
                || anchor.factorMillisecondsPerTick == 100 else {
            return false
        }
        return isPlausible(unixSeconds: anchor.utcMilliseconds / 1_000)
    }

    public static func isPlausible(unixSeconds: Int64) -> Bool {
        unixSeconds >= minimumPlausibleEpochSeconds
            && unixSeconds <= maximumPlausibleEpochSeconds
    }

    private static func anchor(
        ringTimestamp: UInt32,
        unixSeconds: Int64,
        factorMillisecondsPerTick: Int64
    ) -> OuraTimeAnchor? {
        guard ringTimestamp > 0,
              factorMillisecondsPerTick == 1 || factorMillisecondsPerTick == 100,
              isPlausible(unixSeconds: unixSeconds) else {
            return nil
        }
        let (utcMilliseconds, overflow) = unixSeconds.multipliedReportingOverflow(by: 1_000)
        guard !overflow else { return nil }
        return OuraTimeAnchor(
            ringTimestamp: ringTimestamp,
            utcMilliseconds: utcMilliseconds,
            factorMillisecondsPerTick: factorMillisecondsPerTick
        )
    }
}
