import Foundation

// OuraDriver: the transport-agnostic protocol state machine (architecture plan s1). It holds NO BLE
// handle: the app's OuraLiveSource owns the CBCentralManager / BluetoothGatt and feeds the driver
// only bytes + transition events. This is what makes the protocol headless-testable (no CoreBluetooth,
// no android.bluetooth anywhere in this package).
//
// Two entry points:
//   - nextStep(after:) -> [OuraCommand]   : given the last transition, return the commands to write.
//   - ingest(record:) -> [OuraEvent]      : given a parsed TLV record, return decoded events.
//   - ingestLiveHRPush(body:) -> [OuraEvent] : given a 0x2F sub-op 0x28 push body, return live HR.
//
// The flow mirrors OURA_PROTOCOL.md s3 (auth) + s5 (live HR / fetch): scan -> connect -> notify ->
// auth (nonce, proof) -> enable live HR (gen-appropriate triplet) -> stream. RingGen swaps the
// command set, not the code path.
//
// Tier discipline: Tier-B decoders are present but gated behind `allowTierB` (default false). When
// false, a Tier-B tag decodes to nothing (the event is dropped), so Tier-B values can never feed
// scoring silently. Per the brief's TIER DISCIPLINE and OURA_PROTOCOL.md s7.3.

/// A transport-level transition the app reports to the driver to advance the flow. The driver answers
/// with the next batch of commands. This keeps all BLE specifics (CBPeripheral, GATT callbacks) in
/// the app and all protocol specifics here.
public enum OuraTransition: Equatable, Sendable {
    /// Service + characteristics discovered and notifications enabled on ...0003. Begin auth.
    case ready
    /// A 15-byte nonce arrived (from the GetAuthNonce response). Compute + submit the proof.
    case nonceReceived([UInt8])
    /// The auth handshake completed with this status. On success, begin enabling live HR.
    case authCompleted(OuraAuthStatus)
    /// A live-HR enable/subscribe ACK arrived; advance the triplet (or, when done, mark streaming).
    case enableAckReceived
    /// The app wants to sync the ring clock, then fetch buffered history from this cursor.
    case startHistoryFetch(cursor: UInt32, unixSeconds: Int)
    /// Ring 4 acknowledged the active SyncTime request. Only now flush/fetch, so the freshly-created
    /// 0x42 anchor record is included in the history stream instead of racing later control writes.
    case timeSyncAcknowledged(cursor: UInt32)
    /// Some Ring 4 firmware returns a well-formed 0x13 whose echo does not correlate. After a short,
    /// transport-owned timeout, release the fetch once; a correlated 0x42 or qualified recent 0x85
    /// remains the mandatory commit authority, so this cannot persist stale or misdated history.
    case timeSyncReleaseTimedOut(cursor: UInt32)
    /// Read the next provisional Ring 4 history page from a record high-water without ACKing, flushing,
    /// or resetting the active SyncTime correlation. The transport bounds this anchor search.
    case continueProvisionalHistory(cursor: UInt32)
    /// A bounded bootstrap scan found a trustworthy historical 0x42 after skipping earlier pages.
    /// Re-read from the durable cursor with that anchor; the skipped records were never ACKed.
    case restartHistoryFromBootstrap(cursor: UInt32)
    /// The last GetEvents response advanced the cursor to this value; continue or stop.
    case historyCursorAdvanced(cursor: UInt32, moreData: Bool)
}

/// The driver's coarse phase, exposed for the app and tests to assert on.
public enum OuraDriverPhase: Equatable, Sendable {
    case idle
    case authenticating
    case enablingLiveHR
    case streaming
    case fetchingHistory
    case needsKeyInstall      // ring is in factory reset; honest pairing path (s3.5 status 0x02)
    case installingKey        // post-factory-reset key install in flight (s3.2); awaiting the 0x25 ack
    case authFailed(OuraAuthStatus)
    case stopped
}

public final class OuraDriver {
    public let ringGen: OuraRingGen
    /// The 16-byte application auth key (injected, never hardcoded). nil drives the honest
    /// needs-pairing path (the app surfaces "needsPairing" instead of faking data, Huami precedent).
    private let authKey: [UInt8]?
    /// When false (default), Tier-B (UNVERIFIED) tags decode to nothing so they can never feed scoring.
    public let allowTierB: Bool
    /// When false (default), the driver MUST NOT sequence a post-factory-reset key install: it stays at
    /// needsKeyInstall and writes nothing dangerous. Only an explicit opt-in adopt flow sets this true.
    /// Per OURA_PROTOCOL.md s3.2 (the 0x24 SetAuthKey is a DANGEROUS, one-time provisioning write).
    public let allowKeyInstall: Bool
    /// Deterministic token injection for replay/tests. Passing 0xFD explicitly selects the qualified
    /// burst-clock fixture; production leaves this nil and must never choose that reserved token randomly.
    private let fixedTimeSyncToken: UInt8?
    /// Ring 4 interprets 0xFD as a 1 ms/tick burst-clock marker rather than the normal 100 ms/tick scale.
    /// Keep production history syncs in the normal range so a random token can never rescale a batch 100x.
    static let normalTimeSyncTokenRange: ClosedRange<UInt8> = UInt8.min ... 0xFC

    public private(set) var phase: OuraDriverPhase = .idle
    /// Tracks how many of the live-HR enable triplet ACKs have been seen.
    private var liveHREnableStep = 0
    /// The most recent ring time seen on any record, used to stamp live-HR pushes (which are not TLV
    /// records and carry no timestamp of their own).
    private var lastRingTimestamp: UInt32 = 0
    /// Ring-time -> UTC anchor (OURA_PROTOCOL.md s5.5): the ring's clock ticks at 100 ms/tick by default
    /// and 1 ms/tick when Ring 4's 0x42 token is 0xFD. Set from the ring's own 0x42 time-sync event
    /// (primary) or, only while no 0x42 has arrived yet THIS session, the coarser 1s-granularity 0x85 RTC
    /// beacon (secondary). A validated persisted primary anchor may restore this mapping after reconnect,
    /// but it cannot authorize a history commit until the active stream proves monotonic continuity beyond
    /// the saved cursor and anchor. Without either source, `unixSeconds(forRingTimestamp:)` returns nil.
    private var anchorUtcMs: Int64?
    private var anchorRingTime: UInt32?
    /// Generation/token-specific ring-clock scale selected by the primary 0x42 anchor.
    private var anchorFactorMs: Int64 = 100
    /// The durable mapping safe to persist alongside the cursor. A correlated 0x42 is preferred; tested
    /// Ring 4 firmware may omit 0x42 entirely, so a recent 0x85 observed during the active sync fetch can
    /// establish the same mapping at the beacon's documented 100 ms/tick scale.
    private var primaryTimeAnchor: OuraTimeAnchor?
    /// A durable primary anchor is useful for timestamp translation immediately after reconnect, but it
    /// does not authorize a history ACK until the active stream proves its ring clock continued beyond
    /// both the saved cursor and saved anchor.
    private var persistedAnchorNeedsContinuity = false
    /// One-shot signal for the transport to clear the coherent durable cursor + anchor after a ring-start
    /// record proves the ring clock regressed.
    private var persistentTimeStateInvalidated = false
    private var activeFetchStartCursor: UInt32 = 0
    /// Ring 4 counter sent by the active SyncTime request. A fetched 0x42 may replace the session anchor
    /// only when its coarse epoch matches this counter, so a plausible-but-stale backlog anchor cannot win.
    private var pendingSyncCounter: UInt32?
    /// The random request token must match the fetched 0x42 as well as the coarse counter.
    private var pendingSyncToken: UInt8?
    /// A cursor commit needs an anchor qualified for THIS fetch, not merely an older session anchor.
    private var activeFetchHasFreshAnchor = false
    /// Makes a duplicate/late 0x13 acknowledgement unable to enqueue a second flush/fetch pair.
    private var timeSyncReleaseIssued = false
    /// Enabled only after the transport crosses its bounded in-memory event cap. In this mode a
    /// plausible historical 0x42 may bootstrap the clock; skipped pages are refetched before commit.
    private var historicalAnchorBootstrapEnabled = false
    /// Ring 4's event-category masks are session configuration, not per-poll commands. A new driver is
    /// created for every BLE connection, so this naturally resets on reconnect.
    private var ring4HistoryCategoriesConfigured = false
    /// True cursor for the active batch: max ringTimestamp across every structurally-valid inner record.
    public private(set) var activeHistoryHighWater: UInt32?
    /// The freshly-provisioned key the transport generated during an adopt flow (s3.2). Once set by
    /// beginKeyInstall it becomes the effective key for the post-install re-auth. nil otherwise.
    private var installedKey: [UInt8]?

    /// The key the auth handshake should use: the freshly-installed key takes precedence over the
    /// injected one (so re-auth after a key install uses the new key). Per OURA_PROTOCOL.md s3.2.
    private var effectiveKey: [UInt8]? { installedKey ?? authKey }

    public init(ringGen: OuraRingGen, authKey: [UInt8]?, allowTierB: Bool = false,
                allowKeyInstall: Bool = false, timeSyncToken: UInt8? = nil,
                persistedTimeAnchor: OuraTimeAnchor? = nil) {
        self.ringGen = ringGen
        self.authKey = authKey
        self.allowTierB = allowTierB
        self.allowKeyInstall = allowKeyInstall
        self.fixedTimeSyncToken = timeSyncToken
        if ringGen == .gen4,
           let persistedTimeAnchor,
           Self.isValidTimeAnchor(persistedTimeAnchor) {
            anchorUtcMs = persistedTimeAnchor.utcMilliseconds
            anchorRingTime = persistedTimeAnchor.ringTimestamp
            anchorFactorMs = persistedTimeAnchor.factorMillisecondsPerTick
            primaryTimeAnchor = persistedTimeAnchor
            persistedAnchorNeedsContinuity = true
        }
    }

    // MARK: - Command flow

    /// Given the last transport transition, return the commands the app should write next. Pure: it
    /// only mutates the driver's own phase, never touches BLE. Per OURA_PROTOCOL.md s3 / s5.
    public func nextStep(after transition: OuraTransition) -> [OuraCommand] {
        switch transition {
        case .ready:
            // Capture the exact firmware/hardware tuple on every connection. These reads are safe before
            // auth and omit the serial page, so a redacted strap log can qualify real hardware without
            // exposing a persistent identifier (OURA_PROTOCOL.md s3.6/s4.3).
            let identity = [OuraCommands.getFirmwareVersion(), OuraCommands.getProductHardware()]
            // No app key -> we cannot authenticate; surface the honest pairing path (no faked data).
            guard effectiveKey != nil else {
                phase = .needsKeyInstall
                return identity
            }
            phase = .authenticating
            // Ring 4's official sequence performs its serial-free identity read and two read-only
            // session probes before requesting the nonce. Keep Gen 3's already-qualified ordering.
            if ringGen == .gen4 {
                return identity + OuraCommands.ring4PreAuthSessionReads()
                    + [OuraCommand(label: "get_nonce", bytes: OuraAuth.getAuthNonceCommand())]
            }
            return [OuraCommand(label: "get_nonce", bytes: OuraAuth.getAuthNonceCommand())] + identity

        case .nonceReceived(let nonce):
            guard let key = effectiveKey else {
                phase = .needsKeyInstall
                return []
            }
            // Compute the proof and submit it. On any crypto error, fail honestly (no proof sent).
            guard let cmd = try? OuraAuth.authenticateCommand(nonce: nonce, key: key) else {
                phase = .authFailed(.authError)
                return []
            }
            return [OuraCommand(label: "submit_proof", bytes: cmd)]

        case .authCompleted(let status):
            switch status {
            case .success:
                phase = .enablingLiveHR
                liveHREnableStep = 0
                // The transport already enabled the inbound CCCDs; begin live HR directly. Ring 4
                // firmware 2.12.3 stalls the following control write when `notify_all` is sent here.
                return [OuraCommands.liveHREnableSequence()[0]]
            case .inFactoryReset:
                // Ring needs a key install first; this is an explicit, named provisioning step the app
                // drives, not the normal flow. Surface honestly.
                phase = .needsKeyInstall
                return []
            case .authError, .notOriginalDevice:
                phase = .authFailed(status)
                return []
            }

        case .enableAckReceived:
            guard phase == .enablingLiveHR else { return [] }
            liveHREnableStep += 1
            let seq = OuraCommands.liveHREnableSequence()
            if liveHREnableStep < seq.count {
                return [seq[liveHREnableStep]]
            }
            // All three ACKed: HR/IBI now streams as 0x2F sub-op 0x28 pushes.
            phase = .streaming
            return []

        case .startHistoryFetch(let cursor, let unixSeconds):
            phase = .fetchingHistory
            activeHistoryHighWater = nil
            activeFetchHasFreshAnchor = false
            activeFetchStartCursor = cursor
            persistedAnchorNeedsContinuity = ringGen == .gen4 && primaryTimeAnchor != nil
            timeSyncReleaseIssued = false
            if ringGen == .gen4, unixSeconds >= 0 {
                let token = fixedTimeSyncToken ?? UInt8.random(in: Self.normalTimeSyncTokenRange)
                let sync = OuraCommands.syncTime(unixSeconds: unixSeconds, token: token)
                pendingSyncCounter = UInt32(unixSeconds / 256) & 0x00FF_FFFF
                pendingSyncToken = sync.bytes[2]
                // Ring 4's official sequence enables the event stream before SyncTime and gates the
                // data-plane writes on the 0x13 response. Sending
                // SyncTime, Flush and GetEvents back-to-back can make real hardware return history before
                // it has emitted the correlated 0x13/0x42 pair. Keep the batch provisional by issuing only
                // stream-enable + SyncTime here; acknowledgement (or the guarded timeout) releases
                // Flush + GetEvents.
                var commands = [OuraCommands.enableEventStream(), sync]
                if !ring4HistoryCategoriesConfigured {
                    commands.append(OuraCommands.ring4PostSyncStatePulse())
                    commands.append(contentsOf: OuraCommands.ring4EventCategorySubscriptions())
                    commands.append(OuraCommands.getBattery())
                    let parameterReads = OuraCommands.ring4HistoryParameterReads()
                    commands.append(contentsOf: parameterReads.prefix(2))
                    commands.append(OuraCommands.ring4HistorySessionMode())
                    commands.append(contentsOf: parameterReads.dropFirst(2))
                    ring4HistoryCategoriesConfigured = true
                }
                return commands
            }
            // Gen 3 retains its legacy sequence until its generation-specific 0x13 layout is qualified.
            return [OuraCommands.syncTime(unixSeconds: unixSeconds),
                    OuraCommands.flushBuffer(),
                    OuraCommands.getEvents(cursor: cursor, maxEvents: 255)]

        case .timeSyncAcknowledged(let cursor), .timeSyncReleaseTimedOut(let cursor):
            guard ringGen == .gen4, phase == .fetchingHistory, pendingSyncCounter != nil,
                  !timeSyncReleaseIssued else { return [] }
            timeSyncReleaseIssued = true
            return [OuraCommands.flushBuffer(),
                    OuraCommands.getEvents(cursor: cursor, maxEvents: 255)]

        case .continueProvisionalHistory(let cursor):
            guard ringGen == .gen4, phase == .fetchingHistory,
                  !hasFreshAnchorForActiveFetch else { return [] }
            // Deliberately no max=0 ACK and no flush: this is a read-only look-ahead for the correlated
            // 0x42 while the transport keeps decoded events parked and the durable cursor unchanged.
            return [OuraCommands.getEvents(cursor: cursor, maxEvents: 255)]

        case .restartHistoryFromBootstrap(let cursor):
            guard ringGen == .gen4, phase == .fetchingHistory, hasUtcAnchor else { return [] }
            historicalAnchorBootstrapEnabled = false
            activeHistoryHighWater = nil
            activeFetchHasFreshAnchor = true
            pendingSyncCounter = nil
            pendingSyncToken = nil
            timeSyncReleaseIssued = true
            return [OuraCommands.flushBuffer(),
                    OuraCommands.getEvents(cursor: cursor, maxEvents: 255)]

        case .historyCursorAdvanced(let cursor, let moreData):
            guard moreData else {
                phase = .streaming
                pendingSyncCounter = nil
                pendingSyncToken = nil
                activeFetchHasFreshAnchor = false
                persistedAnchorNeedsContinuity = false
                timeSyncReleaseIssued = false
                activeHistoryHighWater = nil
                return []
            }
            // Ack-fetch (max=0) at the new cursor advances without re-pulling data (s5.3 step 4).
            return [OuraCommands.getEvents(cursor: cursor, maxEvents: 0)]
        }
    }

    /// Re-engage live HR (daytime-HR auto-reverts after ~20 s; the app calls this every ~15 s while a
    /// live session is open). Per OURA_PROTOCOL.md s5.7. Returns the enable+subscribe commands.
    public func reengageLiveHRCommands() -> [OuraCommand] {
        [OuraCommands.liveHREnable(), OuraCommands.liveHRSubscribe()]
    }

    // MARK: - Post-factory-reset key install (adopt flow, s3.2)

    /// Begin the one-time post-factory-reset key install (OURA_PROTOCOL.md s3.2). The transport in the
    /// adopt flow generates a fresh 16-byte key, persists it, and calls this to obtain the dangerous
    /// `24 10 <key>` write; once the ring replies `25 01 00` the transport calls keyInstallAcknowledged
    /// to drive re-auth.
    ///
    /// SAFETY GATE: this only sequences an install when phase == needsKeyInstall AND allowKeyInstall is
    /// true. When allowKeyInstall is false it stays at needsKeyInstall and returns no commands, so the
    /// dangerous 0x24 write is never emitted outside an explicit opt-in adopt flow. Returns nil (and
    /// leaves phase unchanged) when not gated on, the key length is wrong, or the command cannot build.
    public func beginKeyInstall(key: [UInt8]) -> OuraCommand? {
        guard allowKeyInstall, phase == .needsKeyInstall else { return nil }
        guard let cmd = try? OuraDangerousCommands.installKey(key) else { return nil }
        installedKey = key                 // re-auth after the ack must use the freshly-provisioned key
        phase = .installingKey
        return cmd
    }

    /// Handle the ring's 0x25 SetAuthKey ack (`25 01 00`, s3.2) by driving re-auth with the freshly
    /// installed key: transition installingKey -> authenticating and return the same enable+nonce
    /// commands the ready path uses. Returns [] (phase unchanged) when not in installingKey or when no
    /// installed key is present, so a stray ack cannot advance the flow.
    public func keyInstallAcknowledged() -> [OuraCommand] {
        guard phase == .installingKey, installedKey != nil else { return [] }
        phase = .authenticating
        return [OuraCommand(label: "get_nonce", bytes: OuraAuth.getAuthNonceCommand())]
    }

    /// Stop: reset the flow so a fresh session re-runs auth (the app key is session-scoped, s3.1).
    public func stop() {
        phase = .stopped
        liveHREnableStep = 0
        lastRingTimestamp = 0
        installedKey = nil
        anchorUtcMs = nil
        anchorRingTime = nil
        anchorFactorMs = 100
        primaryTimeAnchor = nil
        persistedAnchorNeedsContinuity = false
        persistentTimeStateInvalidated = false
        activeFetchStartCursor = 0
        pendingSyncCounter = nil
        pendingSyncToken = nil
        activeFetchHasFreshAnchor = false
        timeSyncReleaseIssued = false
        historicalAnchorBootstrapEnabled = false
        activeHistoryHighWater = nil
    }

    // MARK: - Ring-time -> UTC anchor (s5.5)

    /// Accept a well-formed Ring 4 `0x13` while a SyncTime request is active. Tested firmware returns
    /// nonstandard status/echo fields and the official transport treats this as one-way liveness. This
    /// never anchors or commits by itself; an independently-qualified 0x42/0x85 remains mandatory.
    @discardableResult
    public func handleSyncTimeAcknowledgement(body: [UInt8]) -> Bool {
        guard ringGen == .gen4,
              OuraFraming.parseSyncTimeResponse(body) != nil,
              pendingSyncCounter != nil else { return false }
        return true
    }

    /// Permit one bounded scan to use a plausible backlog 0x42 as a bootstrap anchor. The transport
    /// must refetch every skipped page from its durable cursor before committing anything.
    public func enableHistoricalAnchorBootstrap() {
        guard ringGen == .gen4, phase == .fetchingHistory else { return }
        historicalAnchorBootstrapEnabled = true
    }

    /// True only when this session has a complete UTC/ring-time pair. Transports use this to keep a
    /// fetched cursor provisional until its samples can be dated and durably flushed.
    public var hasUtcAnchor: Bool { anchorUtcMs != nil && anchorRingTime != nil }

    /// The validated durable anchor suitable for atomic persistence with the history cursor. This is a
    /// correlated 0x42 when available, otherwise a recent active-fetch 0x85 fallback on Ring 4.
    public var currentPrimaryTimeAnchor: OuraTimeAnchor? {
        guard ringGen == .gen4,
              let primaryTimeAnchor,
              Self.isValidTimeAnchor(primaryTimeAnchor) else { return nil }
        return primaryTimeAnchor
    }

    /// Stronger commit gate for the active fetch. Ring 4 must receive either a matching token+counter
    /// 0x42 or a recent active-fetch 0x85; legacy generations retain the session-anchor rule.
    public var hasFreshAnchorForActiveFetch: Bool {
        ringGen == .gen4 ? (phase == .fetchingHistory && activeFetchHasFreshAnchor && hasUtcAnchor) : hasUtcAnchor
    }

    /// Timestamping gate used while ingesting. Outside a fetch, the session anchor remains useful for
    /// spontaneous records; during a Ring 4 fetch only its freshly-correlated anchor may resolve history.
    public var canResolveHistoryTimestamps: Bool {
        if ringGen == .gen4, phase == .fetchingHistory { return hasFreshAnchorForActiveFetch }
        return hasUtcAnchor
    }

    private func invalidateAnchor(invalidatePersistentState: Bool = false) {
        anchorUtcMs = nil
        anchorRingTime = nil
        anchorFactorMs = 100
        primaryTimeAnchor = nil
        persistedAnchorNeedsContinuity = false
        pendingSyncCounter = nil
        pendingSyncToken = nil
        activeFetchHasFreshAnchor = false
        timeSyncReleaseIssued = false
        activeHistoryHighWater = nil
        if invalidatePersistentState { persistentTimeStateInvalidated = true }
    }

    /// Consume a proven ring-clock reset exactly once so the transport can atomically clear its saved
    /// cursor + primary anchor. Session teardown and ordinary missing-anchor paths never set this signal.
    public func consumePersistentTimeStateInvalidation() -> Bool {
        let invalidated = persistentTimeStateInvalidated
        persistentTimeStateInvalidated = false
        return invalidated
    }

    /// Explicit transport hook for a durable-cursor regression discovered in the batch summary. This
    /// clears both the mapping and its exportable primary form before the cursor is reset to zero.
    public func invalidateTimeAnchorForRingClockRegression() {
        invalidateAnchor()
    }

    /// Convert a record's ring-clock timestamp to unix seconds using the current session's anchor
    /// (OURA_PROTOCOL.md s5.5). Returns nil when no anchor has arrived yet this session, so the caller
    /// can honestly fall back (e.g. to wall-clock arrival time) instead of guessing.
    public func unixSeconds(forRingTimestamp rt: UInt32) -> Int? {
        guard let anchorUtcMs, let anchorRingTime else { return nil }
        let deltaTicks = Int64(rt) - Int64(anchorRingTime)
        let ms = anchorUtcMs + deltaTicks * anchorFactorMs
        // #968: a corrupt/misaligned ring timestamp (seen on a full cursor=0 history dump) can convert to
        // an implausible epoch. Gate the RESULT to the same 2020-2035 plausible window used for anchoring
        // (was a weak `ms > 0`), so the caller honestly falls back to arrival time instead of banking a
        // 1970 or far-future sample.
        let seconds = ms / 1000
        guard seconds >= Self.minPlausibleEpochSeconds, seconds <= Self.maxPlausibleEpochSeconds else { return nil }
        return Int(seconds)
    }

    /// Bounds for a plausible anchor epoch (unix seconds): 2020-01-01 to 2035-01-01. A decoded 0x42/0x85
    /// value outside this range is a corrupt/misaligned record (seen on real hardware: a full cursor=0
    /// history dump hit one deep in the backlog) and is never trusted as an anchor (honest-data invariant).
    /// This gate ALSO bounds the input to the seconds->ms `* 1000` conversion so it can never overflow
    /// Int64 (a naive multiply on a near-Int64.max raw value traps).
    private static let minPlausibleEpochSeconds: Int64 = 1_577_836_800
    private static let maxPlausibleEpochSeconds: Int64 = 2_051_222_400
    /// Ring 4 firmware seen in hardware qualification can retain a valid RTC beacon for slightly more
    /// than two days while omitting 0x42 (a real retained-history capture measured ~52 hours). Accept at
    /// most three days of look-back, with only small forward clock skew; the active-fetch phase, pending
    /// SyncTime counter, durable-cursor floor, and plausible-epoch gates remain mandatory.
    private static let rtcFallbackMaximumAgeSeconds: Int64 = 72 * 60 * 60
    private static let rtcFallbackFutureToleranceSeconds: Int64 = 15 * 60

    private static func plausibleAnchorMs(fromEpochSeconds seconds: Int64) -> Int64? {
        guard seconds >= minPlausibleEpochSeconds, seconds <= maxPlausibleEpochSeconds else { return nil }
        return seconds * 1000   // safe: bounded input, cannot overflow
    }

    /// Qualify the coarser RTC beacon only when it belongs to the current Ring 4 fetch. The active
    /// SyncTime counter supplies a privacy-free wall-clock bound; the cursor floor prevents an older
    /// backlog beacon from authorizing a resumed cursor.
    private func rtcBeaconQualifiesForActiveFetch(_ beacon: OuraRtcBeacon) -> Bool {
        guard ringGen == .gen4, phase == .fetchingHistory,
              let pendingSyncCounter,
              beacon.ringTimestamp >= activeFetchStartCursor else { return false }
        let requestWindowStart = Int64(pendingSyncCounter) * 256
        let beaconSeconds = Int64(beacon.unixSeconds)
        return beaconSeconds >= requestWindowStart - Self.rtcFallbackMaximumAgeSeconds
            && beaconSeconds <= requestWindowStart + 255 + Self.rtcFallbackFutureToleranceSeconds
    }

    /// Validate an anchor loaded from durable storage before it is allowed to translate any history.
    public static func isValidTimeAnchor(_ anchor: OuraTimeAnchor) -> Bool {
        guard anchor.ringTimestamp > 0,
              anchor.factorMillisecondsPerTick == 1 || anchor.factorMillisecondsPerTick == 100 else {
            return false
        }
        let seconds = anchor.utcMilliseconds / 1000
        return seconds >= minPlausibleEpochSeconds && seconds <= maxPlausibleEpochSeconds
    }

    // MARK: - Record ingest (decode)

    /// Decode one parsed TLV inner record into zero or more events. A malformed/short record (or an
    /// unknown tag) yields []. Tier-B tags yield [] unless allowTierB is set. Per OURA_PROTOCOL.md s6.
    public func ingest(record: OuraRecord) -> [OuraEvent] {
        let previousRingTimestamp = lastRingTimestamp
        // Only real inner-record tag space may affect ring-time state. Unknown but structurally-valid
        // 0x41+ records still count toward the history ACK high-water, exactly like the official client.
        guard record.type >= 0x41 else { return [] }
        if phase == .fetchingHistory {
            activeHistoryHighWater = max(activeHistoryHighWater ?? 0, record.ringTimestamp)
            // A persisted mapping is translation state, not commit authority. Promote it only after a
            // structurally-valid record proves this fetch is monotonic beyond both durable boundaries and
            // the mapped result is still a plausible UTC instant. A ring-start/cursor regression clears it.
            if ringGen == .gen4,
               persistedAnchorNeedsContinuity,
               let anchorRingTime,
               record.ringTimestamp >= activeFetchStartCursor,
               record.ringTimestamp >= anchorRingTime,
               unixSeconds(forRingTimestamp: record.ringTimestamp) != nil {
                persistedAnchorNeedsContinuity = false
                activeFetchHasFreshAnchor = true
            }
        }
        lastRingTimestamp = record.ringTimestamp
        guard let tag = OuraEventTag(rawValue: record.type) else {
            // Unknown tag: decode to nothing, never a guessed value (honest-data invariant).
            return []
        }
        // Tier-B gate: when not explicitly allowed, drop the event so it cannot feed scoring.
        if tag.tier == .tierB && !allowTierB {
            return []
        }
        switch tag {
        // --- Tier A: HR / IBI ---
        case .ibiAmplitude:
            return (OuraDecoders.decodeIBIAmplitude(record) ?? []).map { OuraEvent.ibi($0) }
        case .greenIbiQuality:
            return (OuraDecoders.decodeGreenIBIQuality(record) ?? []).map { OuraEvent.ibi($0) }
        case .spo2IbiAmplitude:
            return (OuraDecoders.decodeSpO2IBI(record) ?? []).map { OuraEvent.ibi($0) }
        case .ibi:
            // The bare 0x44 IBI tag shares the bit-packed layout family; route through the same decoder.
            return (OuraDecoders.decodeIBIAmplitude(record) ?? []).map { OuraEvent.ibi($0) }
        case .greenIbiAmp:
            return (OuraDecoders.decodeIBIAmplitude(record) ?? []).map { OuraEvent.ibi($0) }

        // --- Tier A: HRV ---
        case .hrvRmssd:
            return (OuraDecoders.decodeHRV(record) ?? []).map { OuraEvent.hrv($0) }

        // --- SpO2 (0x8B is diagnostic-only in downstream mapping) ---
        case .spo2PerSample:
            return (OuraDecoders.decodeSpO2PerSample(record) ?? []).map { OuraEvent.spo2($0) }
        case .spo2Stable:
            if let s = OuraDecoders.decodeSpO2Stable(record) { return [.spo2(s)] }
            return []
        case .spo2Dc:
            return (OuraDecoders.decodeSpO2DC(record) ?? []).map { OuraEvent.spo2($0) }
        case .spo2RatioPI:
            guard let value = OuraDecoders.decodeSpO2RatioPI(record) else { return [] }
            return [.spo2Ratio(value,
                               calibrationProfile: OuraSpO2CalibrationProfile.forRingGeneration(ringGen))]

        // --- Tier A: Temperature ---
        case .temp:
            return (OuraDecoders.decodeTemp(record) ?? []).map { OuraEvent.temp($0) }
        case .tempPeriod:
            if let t = OuraDecoders.decodeTempPeriod(record) { return [.temp(t)] }
            return []
        case .sleepTemp:
            return (OuraDecoders.decodeSleepTemp(record) ?? []).map { OuraEvent.temp($0) }

        // --- Tier A: Motion ---
        case .motionPeriod:
            return (OuraDecoders.decodeMotionPeriod(record) ?? []).map { OuraEvent.motion($0) }
        case .motion:
            // 0x47 motion_events: surfaced as state-free motion is out of v1 scope; decode to nothing
            // rather than guess the partial layout. Per OURA_PROTOCOL.md s6.13.
            return []

        // --- Tier A: Sleep phase (2-bit codes are verified) ---
        case .sleepPhase, .sleepPhaseAlt:
            return (OuraDecoders.decodeSleepPhase(record) ?? []).map { OuraEvent.sleepPhase($0) }
        case .sleepPeriod:
            guard let period = OuraDecoders.decodeSleepPeriod(record) else { return [] }
            return [.sleepPeriod(period)]
        case .bedtimePeriod:
            guard let period = OuraDecoders.decodeBedtimePeriod(record) else { return [] }
            return [.bedtimePeriod(period)]

        // --- Tier A: Lifecycle / state / time ---
        case .timeSync:
            // Primary UTC anchor (s5.5): always wins over a secondary RTC-beacon anchor already set.
            guard let ts = OuraDecoders.decodeTimeSync(record, ringGen: ringGen) else { return [] }
            if ringGen == .gen4 {
                let matchesActiveRequest = pendingSyncCounter.map { ts.epochMs == Int64($0) * 256 } == true
                    && pendingSyncToken.map { ts.token == $0 } == true
                guard matchesActiveRequest || historicalAnchorBootstrapEnabled else {
                    // Preserve the decoded diagnostic event, but never let a stale backlog 0x42 replace
                    // the session anchor outside the explicitly-bounded bootstrap scan.
                    return [.timeSync(ts)]
                }
            }
            // The decoded wire value is unix seconds; the seconds->ms conversion lives here.
            // CRASH-SAFETY (s6.11): a full cursor=0 history dump can hit a 0x42 record with an implausible
            // raw value (a misaligned/corrupt record deep in the backlog); a naive `* 1000` overflows Int64
            // and traps. plausibleAnchorMs bounds-checks BEFORE multiplying, so an implausible value is
            // safely ignored (honest: never anchors to a garbage time) instead of crashing.
            if let ms = Self.plausibleAnchorMs(fromEpochSeconds: ts.epochMs) {
                anchorUtcMs = ms
                anchorRingTime = ts.ringTimestamp
                anchorFactorMs = Int64(ts.factorMsPerTick)
                primaryTimeAnchor = OuraTimeAnchor(
                    ringTimestamp: ts.ringTimestamp,
                    utcMilliseconds: ms,
                    factorMillisecondsPerTick: Int64(ts.factorMsPerTick)
                )
                persistedAnchorNeedsContinuity = false
                if ringGen == .gen4 { activeFetchHasFreshAnchor = true }
            }
            return [.timeSync(ts)]
        case .rtcBeacon:
            guard let r = OuraDecoders.decodeRtcBeacon(record) else { return [] }
            if rtcBeaconQualifiesForActiveFetch(r),
               let ms = Self.plausibleAnchorMs(fromEpochSeconds: Int64(r.unixSeconds)) {
                // Hardware-qualified fallback: some Ring 4 firmware returns a valid active SyncTime ack
                // and current RTC beacons but never banks 0x42. A recent beacon is a complete ring->UTC
                // mapping at 1-second UTC / 100-ms tick precision, so it can safely unblock this fetch.
                // A later correlated 0x42 still wins unconditionally in the timeSync case above.
                anchorUtcMs = ms
                anchorRingTime = r.ringTimestamp
                anchorFactorMs = 100
                primaryTimeAnchor = OuraTimeAnchor(
                    ringTimestamp: r.ringTimestamp,
                    utcMilliseconds: ms,
                    factorMillisecondsPerTick: 100
                )
                persistedAnchorNeedsContinuity = false
                activeFetchHasFreshAnchor = true
            } else if anchorUtcMs == nil,
                      let ms = Self.plausibleAnchorMs(fromEpochSeconds: Int64(r.unixSeconds)) {
                // Outside that narrow Ring 4 gate (and on legacy rings), preserve the established
                // session-only secondary-anchor behavior; it never authorizes or persists a cursor.
                anchorUtcMs = ms
                anchorRingTime = r.ringTimestamp
                anchorFactorMs = 100
            }
            return [.rtcBeacon(r)]
        case .stateChange, .wearEvent:
            if let s = OuraDecoders.decodeState(record) { return [.state(s)] }
            return []
        case .debugText:
            if let t = OuraDecoders.decodeDebugText(record) {
                return [.debugText(ringTimestamp: record.ringTimestamp, text: t)]
            }
            return []
        case .ringStart:
            // A reboot can reset the ring clock. Invalidate the entire UTC pair when ring-start regresses;
            // the next correlated SyncTime/0x42 establishes a fresh one.
            let durableFloor = max(activeFetchStartCursor, primaryTimeAnchor?.ringTimestamp ?? 0)
            if (previousRingTimestamp != 0 && record.ringTimestamp < previousRingTimestamp)
                || (durableFloor > 0 && record.ringTimestamp < durableFloor) {
                invalidateAnchor(invalidatePersistentState: true)
            }
            return []

        // --- Tier B (only reached when allowTierB == true; otherwise dropped above) ---
        case .sleepSummary1, .sleepSummaryB, .sleepSummaryC, .sleepSummaryD, .sleepSummaryE, .sleepSummaryF:
            return [.tierB(OuraTierBSummary(tag: record.type, ringTimestamp: record.ringTimestamp,
                                            rawPayload: record.payload, kind: "sleep_summary"))]
        case .activityInfo:
            // Split out of the raw-bytes .tierB wrapper: this ONE activity tag has a plausible decode
            // formula (Decoders.decodeActivityInfo, third-party [oura-rs], PR #960 investigation). Still
            // Tier B - only reached behind allowTierB (gated above), and OuraStreamMapping never folds
            // .activityInfo into a durable stream. 0x51/0x52 summaries stay raw below.
            guard let info = OuraDecoders.decodeActivityInfo(record) else { return [] }
            return [.activityInfo(info)]
        case .activitySummary1, .activitySummary2:
            return [.tierB(OuraTierBSummary(tag: record.type, ringTimestamp: record.ringTimestamp,
                                            rawPayload: record.payload, kind: "activity"))]
        case .realSteps1, .realSteps2:
            return [.tierB(OuraTierBSummary(tag: record.type, ringTimestamp: record.ringTimestamp,
                                            rawPayload: record.payload, kind: "real_steps"))]
        case .spo2Smoothed:
            return [.tierB(OuraTierBSummary(tag: record.type, ringTimestamp: record.ringTimestamp,
                                            rawPayload: record.payload, kind: "spo2_smoothed"))]
        }
    }

    /// Convenience: ingest a whole notification value by reassembling records and decoding each. The
    /// caller passes a fresh notification value; the supplied reassembler buffers partial trailing
    /// bytes across calls. Per OURA_PROTOCOL.md s2.4.
    public func ingest(notification value: [UInt8], reassembler: OuraReassembler) -> [OuraEvent] {
        var out: [OuraEvent] = []
        for rec in reassembler.feed(value) {
            out.append(contentsOf: ingest(record: rec))
        }
        return out
    }

    /// Decode a live-HR push (0x2F sub-op 0x28). The body is the bytes AFTER `2f 0f 28`; the push is
    /// not a TLV record, so it is stamped with the last seen ring time. Per OURA_PROTOCOL.md s5.6.
    public func ingestLiveHRPush(body: [UInt8]) -> [OuraEvent] {
        guard let hr = OuraDecoders.decodeLiveHRPush(body, ringTimestamp: lastRingTimestamp) else {
            return []
        }
        // The push also carries the IBI; surface both so HRV analytics see the R-R.
        return [.hr(hr), .ibi(OuraIBI(ringTimestamp: lastRingTimestamp, ibiMs: hr.ibiMs))]
    }

    /// Route a parsed secure sub-frame: extract the auth nonce / status, or a live-HR push body, so
    /// the app does not need to know the 0x2F sub-op map. Returns the matching transition or push
    /// events. Per OURA_PROTOCOL.md s4.2 / s5.6.
    public func handleSecureFrame(_ frame: OuraSecureFrame) -> SecureRouting {
        if let nonce = OuraAuth.nonce(from: frame) {
            return .nonce(nonce)
        }
        if let status = OuraAuth.authStatus(from: frame) {
            return .authStatus(status)
        }
        // Sub-op 0x28 carries the live-HR push samples (s5.6). subBody is everything after the subop.
        if frame.subop == 0x28 {
            return .liveHRPush(frame.subBody)
        }
        // Live-HR enable ACKs advance the triplet (s5.6): 0x21 is the dhr_read feature-read ACK from
        // step 1 (`2f 06 21 02 01 11 02 00`), 0x23 acks the enable write (step 2), 0x27 acks the
        // subscribe write (step 3). All three must be recognised or the sequencer stalls at step 0.
        if frame.subop == 0x21, phase != .enablingLiveHR,
           frame.subBody.count >= 5, frame.subBody[0] == 0x04 {
            return .featureStatus(OuraFeatureStatus(feature: frame.subBody[0],
                                                    mode: frame.subBody[1],
                                                    status: frame.subBody[2],
                                                    state: frame.subBody[3],
                                                    subscription: frame.subBody[4]))
        }
        if frame.subop == 0x21 || frame.subop == 0x23 || frame.subop == 0x27 {
            return .enableAck
        }
        return .unhandled
    }

    /// What handleSecureFrame resolved a 0x2F sub-frame to.
    public enum SecureRouting: Equatable {
        case nonce([UInt8])
        case authStatus(OuraAuthStatus)
        case liveHRPush([UInt8])
        case enableAck
        case featureStatus(OuraFeatureStatus)
        case unhandled
    }
}
