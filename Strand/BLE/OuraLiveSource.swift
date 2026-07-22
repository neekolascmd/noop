import Foundation
import Combine
import CoreBluetooth
import LocalAuthentication
import Security
import WhoopProtocol
import WhoopStore
import OuraProtocol

/// Pure response gate for the serial-free identity reads issued when no install key is available.
/// Keeping this separate from CoreBluetooth makes the no-key disconnect ordering deterministic and
/// unit-testable: both requested replies complete the gate, while unrelated/duplicate opcodes do not.
struct OuraNoKeyIdentityGate {
    enum Progress: Equatable {
        case ignored
        case waiting
        case complete
    }

    private(set) var pendingResponseOps: Set<UInt8> = []

    var isWaiting: Bool { !pendingResponseOps.isEmpty }

    @discardableResult
    mutating func begin(commands: [OuraCommand]) -> Bool {
        var expected: Set<UInt8> = []
        if commands.contains(where: { $0.label == "get_firmware" }) {
            expected.insert(OuraFraming.firmwareResponseOp)
        }
        if commands.contains(where: { $0.label == "get_hardware" }) {
            expected.insert(OuraFraming.productInfoResponseOp)
        }
        pendingResponseOps = expected
        return isWaiting
    }

    mutating func receive(op: UInt8) -> Progress {
        guard pendingResponseOps.remove(op) != nil else { return .ignored }
        return pendingResponseOps.isEmpty ? .complete : .waiting
    }

    mutating func reset() {
        pendingResponseOps.removeAll()
    }
}

/// EXPERIMENTAL, ISOLATED live-BLE source for the Oura ring (gen 3/4/5), driven by the clean-room
/// `OuraProtocol.OuraDriver`.
///
/// This is a real transport (it replaced an earlier honest dead-end probe): it decodes the ring's OWN
/// raw signals + open event tags (HR / IBI / HRV / SpO2 / temp / sleep-phase / battery), persists them
/// under the ring's `deviceId`, and lets NOOP compute its own Charge/Rest from those streams exactly like
/// a WHOOP day. It NEVER reads or surfaces Oura's encrypted readiness/sleep scores (honest-data
/// invariant), and when a signal can't be read it stays at "-", never a fabricated value (Huami precedent).
///
/// WHOOP-FIRST ISOLATION (identical to `StandardHRSource` / `HuamiHRSource`): this class runs its OWN
/// `CBCentralManager` and never imports, calls, or shares state with `BLEManager` / `WhoopBleClient`. The
/// WHOOP path cannot regress. The only shared surfaces are `LiveState` and the injected closures
/// (`persist`, `log`, `onBattery`). All BLE specifics live here; all protocol specifics live in the pure,
/// headless-testable `OuraDriver` (no CoreBluetooth in that package).
///
/// Honest about the handshake, step by step:
///   1. Scan for the Oura GATT service and filter discoveries by `OuraRingGen.recognise`.
///   2. Connect, discover the write/notify characteristics, enable the generation's inbound
///      notification paths (`...0003` on Gen 3, `...0003/4/5/6` on Gen 4/5).
///   3. Run the application auth challenge through `OuraDriver` (GetAuthNonce -> compute proof ->
///      Authenticate). The 16-byte install key is injected via `authKey`; when it is nil (or auth fails
///      because the ring is in factory reset / wrong key) we surface an HONEST `needsPairing` message and
///      stream NO data rather than faking one.
///   3a. ADOPT (factory-reset ring + explicit consent only): when the ring is in factory reset (auth status
///      `inFactoryReset` / no key) AND `adoptIntent == true`, the transport PROVISIONS a fresh 16-byte key:
///      it writes the dangerous `0x24` install, awaits the `0x25` OK ack, persists the key to `OuraKeyStore`,
///      then re-runs auth with the new key (s3.2). Without `adoptIntent` the dangerous opcode is NEVER sent;
///      we announce needs-pairing instead. A failed install is honest (Failed), never a fake success.
///   4. On auth success, run the gen-appropriate live-HR enable triplet; HR/IBI then streams as 0x2F
///      sub-op 0x28 pushes which the driver decodes.
///   5. Once streaming, also run a `GetEvents` HISTORY FETCH (s5) from the last-persisted cursor, and
///      periodically thereafter. Skin temp and SpO2 are SLEEP-ONLY on this hardware (neither ever arrives
///      as a live push, only as banked history), so the fetch is the only way last night's readings ever
///      reach the app. Fetched records are stamped with their real ring-time-anchored UTC (s5.5, from the
///      ring's own correlated 0x42 time-sync event or qualified recent 0x85 RTC beacon), NOT wall-clock
///      arrival time, so "last night" data is never mis-timestamped as "now".
///   6. Decoded events map onto `Streams` via `OuraStreamMapping` and persist in batches; live HR also
///      feeds `LiveState`. Temp/SpO2/HRV/sleep-phase persist ONLY (no live surface - they are last-night
///      values, not a live readout). Battery is requested once streaming starts (`GetBattery`, 0x0C ->
///      0x0D) and feeds `onBattery`/`batteryPct`.
@MainActor
public final class OuraLiveSource: NSObject, ObservableObject {

    // MARK: - Public model

    /// An Oura ring seen during a scan.
    public struct DiscoveredRing: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
        /// Best-effort generation guess from the advertised name (confirmed by the model the user picks).
        public let detectedGen: OuraRingGen?
    }

    /// The coarse adopt outcome the wizard observes while it is in its "Taking over your ring" state, so it
    /// can drive Adopting -> success (on `.streaming`/connected) and Adopting -> an honest Failed (on
    /// `.failed`). It is ONLY meaningful for an adopt-intent connection; a read-only connect stays `.idle`
    /// until it streams (or surfaces `needsPairing`). PARITY: the Android twin exposes the same coarse
    /// adopt outcome the Compose wizard observes to leave its Adopting step.
    public enum AdoptPhase: Equatable, Sendable {
        case idle            // no adopt in flight (the default; a read-only connect never leaves this until streaming)
        case installingKey   // the dangerous 0x24 install was written; awaiting the 0x25 ack (an install IS running)
        case streaming       // auth (re-auth on the adopt path) succeeded and HR/IBI is streaming: adoption complete
        case failed          // an honest dead-end (no ack / ack != OK / re-auth failed / no key): never a fake success
    }

    @Published public private(set) var discovered: [DiscoveredRing] = []
    @Published public private(set) var scanning: Bool = false
    @Published public private(set) var batteryPct: Int? = nil
    /// Read-only state from feature 0x04; nil until the ring replies.
    @Published public private(set) var spo2AutomaticEnabled: Bool? = nil
    /// Set to an HONEST explanation string when the ring needs a pairing/key handshake NOOP can't complete
    /// (no install key, or the ring is in factory reset, or the key was rejected). nil otherwise. The UI
    /// surfaces this instead of a fake reading. Cleared on stop/disconnect.
    @Published public private(set) var needsPairing: String? = nil
    /// The live adopt outcome (see `AdoptPhase`). The wizard observes this to leave its Adopting step. Reset
    /// to `.idle` on every connect/stop/disconnect so a stale outcome never drives a transition.
    @Published public private(set) var adoptPhase: AdoptPhase = .idle

    // MARK: - BLE UUIDs (from the platform-pure OuraGatt facts)

    /// The Oura base service (gen3/4/5). `OuraGatt` keeps the raw strings so the package stays
    /// CoreBluetooth-free; the app turns them into `CBUUID` here.
    private static let service = CBUUID(string: OuraGatt.serviceUUID)
    private static let writeChar = CBUUID(string: OuraGatt.writeCharacteristicUUID)
    private static let notifyChar = CBUUID(string: OuraGatt.notifyCharacteristicUUID)
    private static let extraNotifyChars: Set<CBUUID> = [
        CBUUID(string: OuraGatt.extraCharacteristic4UUID),
        CBUUID(string: OuraGatt.extraCharacteristic5UUID),
        CBUUID(string: OuraGatt.extraCharacteristic6UUID),
    ]

    /// The `0x25` SetAuthKey-response outer opcode (`25 01 <status>`, status `0x00` = OK). Per
    /// OURA_PROTOCOL.md s3.2. This is the install-ack the adopt key-install awaits.
    private static let setAuthKeyRespOp: UInt8 = 0x25

    /// Local-time formatter for logging a decoded date/time next to a raw ring-tick cursor value, so a
    /// number like "1178203" reads as an actual date instead of an opaque tick count. Logging only.
    private static let cursorDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Decode a ring-tick cursor value to a human-readable local date/time via the driver's current
    /// session anchor (s5.5), or "no anchor yet" when none has arrived yet this session (honest: never
    /// guesses a time). Investigation/logging only.
    private func describeCursor(_ cursor: UInt32) -> String {
        guard let driver, let seconds = driver.unixSeconds(forRingTimestamp: cursor) else {
            return "no anchor yet"
        }
        return Self.cursorDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    // MARK: - Dependencies (injected - no BLEManager / WhoopBleClient reference)

    private let live: LiveState
    private let deviceId: String
    private let persist: (Streams) async -> Bool
    /// Persists a verified 0x76 bedtime window as a stage-less sleep session.
    private let persistSleepSession: (Int, Int) async -> Bool
    private let log: (String) -> Void
    private let onBattery: (Int) -> Void
    /// The ring generation (carried on `PairedDevice.model`, recovered via `OuraRingGen.from(model:)`).
    /// Selects the MTU clamp, which characteristics to discover, and the live-HR command set.
    private let ringGen: OuraRingGen
    /// Supplies the 16-byte application install key (from the Keychain) for this ring, or nil. A nil key
    /// drives the honest `needsPairing` path: the driver answers `.needsKeyInstall` and we never fake data.
    private let authKey: () -> Data?
    /// Optional status companion for `authKey`. Production supplies the latest Keychain OSStatus so an
    /// inaccessible saved key is not mistaken for a factory-reset ring; discovery/test sources omit it.
    private let authKeyStatus: () -> OSStatus?
    /// Retain a successfully-read install key for this source's lifetime. CoreBluetooth reconnects can
    /// race a temporarily unavailable Keychain; losing an already-proven key in that window used to make
    /// a healthy adopted ring look factory-reset and strand it at the pairing screen.
    private var cachedAuthKey: Data?
    /// When false (the wizard's discovery-only scanner) this source never writes `LiveState` or persists.
    private let feedsLive: Bool
    /// EXPLICIT, USER-GRANTED adopt consent for THIS connection. Default FALSE. The dangerous installKey
    /// opcode (`0x24`) may be sent ONLY when this is true: it is what gates the post-factory-reset key
    /// provisioning (s3.2). It is set true by the adopt flow AFTER the wizard's irreversible-consent gate
    /// (the consent tick AND the "Take over this ring?" confirm), and it gates the driver's `allowKeyInstall`
    /// so a read-only / Advanced-key connection can NEVER install a key. Set once at construction (the
    /// coordinator builds a fresh source per connection, so a new value just means a new source).
    private let adoptIntent: Bool

    // MARK: - Protocol state machine (pure - holds NO BLE handle)

    /// The transport-agnostic driver. Re-created on each connect so a fresh session re-runs auth (the
    /// app key is session-scoped). nil until a connection begins.
    private var driver: OuraDriver?
    /// Reassembles notification fragments into complete TLV inner records across feeds.
    private let reassembler = OuraReassembler()
    /// Passive, opt-in qualification capture of the history TLV bytes already delivered by the ring.
    /// It never changes the BLE command stream and never captures live secure-session traffic.
    private lazy var historyCaptureRecorder = OuraHistoryCaptureRecorder()
    /// Values-free metadata for every complete TLV observed during the active history pass. Unlike the
    /// opt-in raw capture above, this retains no payload/timestamp/identifier and is safe for the normal
    /// exportable strap log. It tells us which firmware tags are genuinely present before we add decoders.
    private var historyInventory = OuraRecordInventory()

    /// Logs the FIRST live HR sample of a connection only (never every push); reset on stop/disconnect.
    private var loggedFirstHR = false
    /// Logs the FIRST skin-temp sample DECODED THIS SESSION only (never every record); reset on
    /// stop/disconnect. These are last-night values from the history fetch, not live pushes, but we still
    /// only want one log line, not one per sample. Twin of `loggedFirstHR`.
    private var loggedFirstTemp = false
    /// Logs the FIRST SpO2 sample decoded this session only. Twin of `loggedFirstTemp`.
    private var loggedFirstSpo2 = false
    /// Logs the first verified bedtime boundary decoded in this connection.
    private var loggedFirstBedtime = false
    /// Logs the FIRST ring-time -> UTC anchor of this session only (s5.5); reset on stop/disconnect.
    private var loggedAnchor = false
    /// Logs once per history fetch when a decoded 0x42 record fails to establish the active fetch's
    /// fresh anchor. Presence-only diagnostics keep token/counter values and biometric data private.
    private var loggedUncorrelatedTimeSync = false
    /// Tier-B (UNVERIFIED) kinds ("activity" / "real_steps" / "sleep_summary" / "spo2_smoothed") already
    /// logged this session, so a repeated tag logs once per KIND, not once per record. INVESTIGATION
    /// ONLY (see the `allowTierB: true` comment at driver construction) - the log is how we collect raw
    /// captures to validate these layouts; nothing here ever persists or scores. Reset on stop/disconnect.
    private var loggedTierBKinds: Set<String> = []
    /// Every history-fetched event stays parked with its ring timestamp until the batch summary. Only then,
    /// after a UTC anchor authorizes the fetch, is the complete batch awaited into SQLite before the cursor
    /// advances. This prevents both fabricated arrival-time stamps and cursor-before-data crash loss.
    private var pendingAnchorEvents: [(event: OuraEvent, ringTimestamp: UInt32)] = []
    /// Whether decoded events came from a secure live push or the GetEvents TLV stream. The same `.ibi`
    /// value type is used by both paths, so origin must be carried by the transport; otherwise an overnight
    /// history dump is stamped at wall-clock arrival and appears as a giant current-hour R-R burst.
    private enum IngestOrigin: Equatable { case live, history }
    /// True once the live-HR stream has been requested, so the disconnect handler can tell "we never got
    /// authenticated/streaming" (-> honest note) from "the link just dropped".
    private var reachedStreaming = false
    /// Set only by the explicit Devices-screen confirmation. If history is currently in flight, the
    /// write waits until the driver returns to streaming; it is cleared on disconnect so consent never
    /// leaks into a later session.
    private var pendingSpO2AutomaticEnable = false
    /// The freshly-generated 16-byte key written to the ring during an adopt key install. Held in memory
    /// ONLY between writing the `0x24` install and receiving the `0x25` ack: it is persisted to the keystore
    /// ONLY on an OK ack (so a failed/absent ack never leaves a key the next session would wrongly trust).
    /// Cleared on stop/disconnect/failure.
    private var pendingInstallKey: Data?

    // MARK: - CoreBluetooth state (OWN central, separate from WHOOP)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    /// Every characteristic currently enabled as an inbound notification path. Ring 4/5 can route
    /// responses over ...0003/4/5/6; application commands are still written only to ...0002.
    private var inboundNotifyUUIDs: Set<CBUUID> = []
    private var pendingNotifyUUIDs: Set<CBUUID> = []
    private var enabledNotifyCount = 0
    /// Ring 4 category replies share opcode 0x19 with product-info responses. Track only category writes
    /// actually handed to BLE so their acknowledgements do not create misleading identity warnings.
    private var pendingEventCategoryResponses = 0
    private var acknowledgedEventCategoryResponses = 0

    /// CoreBluetooth queues ATT writes, but Ring 4 firmware can still miss back-to-back Write Without
    /// Response commands. Keep one paced queue, using both CoreBluetooth backpressure and the same 350 ms
    /// hardware-qualified receive window as Android.
    private var commandQueue: [OuraCommand] = []
    private var commandWorkItem: DispatchWorkItem?
    private var lastCommandWriteAt: TimeInterval = 0
    private static let minimumCommandSpacing: TimeInterval = 0.350
    /// With no install key, `.ready` still returns the two privacy-safe identity reads. Keep the
    /// connection alive until both replies arrive instead of cancelling it while those paced writes are
    /// still queued. The timeout preserves the honest bounded no-key teardown if firmware does not reply.
    private var noKeyIdentityGate = OuraNoKeyIdentityGate()
    private var noKeyIdentityTimeoutWorkItem: DispatchWorkItem?
    private static let noKeyIdentityResponseTimeout: TimeInterval = 2.0
    /// A peripheral asked to connect before `centralManagerDidUpdateState` reported `.poweredOn`.
    private var pendingConnectID: UUID?
    /// Peripherals retained by identifier so a chosen one survives until connection (exact
    /// StandardHRSource seenPeripherals/pendingConnectID/retrievePeripherals pattern).
    private var seenPeripherals: [UUID: CBPeripheral] = [:]

    // MARK: - Auto-reconnect (#912)

    /// The paired ring we should keep re-reaching. Set by `connect(_:)`, cleared by `stop()`. While it is
    /// non-nil an INVOLUNTARY drop (or a failed connect) re-issues a connect on a capped backoff, so the
    /// ring comes back on its own once it's in range again, exactly like the WHOOP strap's auto-reconnect
    /// (BLEManager). WHOOP has this loop; the non-WHOOP sources never did, so a dropped Oura ring stayed
    /// down until a manual reconnect. This never touches the WHOOP path or the shared central queue.
    private var reconnectID: UUID?
    /// True while a teardown was USER/COORDINATOR-initiated (`stop()`), so the disconnect handler suppresses
    /// the auto-reconnect (mirrors BLEManager's `intentionalDisconnect`). Cleared on every `connect(_:)`.
    private var intentionalDisconnect = false
    /// Consecutive involuntary reconnect attempts, driving the capped-exponential backoff (3, 6, 12, 24,
    /// 48, 60s). Reset to 0 on a successful connect and on an explicit `connect(_:)`. Matches BLEManager
    /// (#414) and the Android `ReconnectBackoff` so a ring genuinely out of range doesn't hammer BLE.
    private var failedReconnectAttempts = 0

    /// Next backoff delay, capped at 60s, matching BLEManager's `min(60, 3 * 2^(n-1))` and the Android twin.
    private func nextReconnectDelay() -> TimeInterval {
        min(60.0, 3.0 * pow(2.0, Double(max(0, failedReconnectAttempts - 1))))
    }

    /// Schedule an auto-reconnect to the paired ring after a backoff delay, unless the teardown was
    /// intentional or there is no known ring. Guarded again inside the deferred block: a `stop()` that
    /// lands in the meantime cancels the pending reconnect (it re-checks `intentionalDisconnect` and that
    /// the target is unchanged), so a deliberate teardown never races a stale reconnect.
    private func scheduleReconnect() {
        guard !intentionalDisconnect, let id = reconnectID else { return }
        failedReconnectAttempts += 1
        let delay = nextReconnectDelay()
        log("Oura: reconnecting in \(Int(delay))s (attempt \(failedReconnectAttempts))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalDisconnect, self.reconnectID == id else { return }
            self.connect(id)
        }
    }

    // MARK: - History fetch (GetEvents, s5) - the ONLY path skin temp / SpO2 / HRV / sleep-phase ever
    // arrive by. Neither temp nor SpO2 is ever pushed live on this hardware; both are banked overnight and
    // retrievable only by asking the ring for its history.

    /// The GetEvents cursor to resume from, loaded from `OuraHistoryCursorStore` on connect and advanced
    /// as `0x11` summaries arrive. 0 = fetch everything the ring has banked (first-ever connect for this
    /// ring; OURA_PROTOCOL.md s5.1).
    private var historyCursor: UInt32 = 0
    /// Periodic re-fetch while connected, so an overnight-connected session (or one left open after a nap)
    /// picks up freshly-banked sleep data without needing a reconnect. Mirrors BLEManager's ~15 min
    /// periodic WHOOP history-offload floor.
    private var historyFetchTimer: Timer?
    private let historyFetchInterval: TimeInterval = 900
    /// Ring 4 firmware can return a syntactically valid 0x13 whose echo does not match the request.
    /// Release the fetch once after a short wait; cursor commit still requires the fresh token+counter
    /// 0x42 anchor, so this cannot make an unanchored batch durable.
    private var timeSyncReleaseTimer: Timer?
    private let timeSyncReleaseTimeout: TimeInterval = 1
    /// Ring 4 can emit the 0x11 batch summary before the separate TLV notifications it describes.
    /// Hold the summary until the history stream has been idle briefly; every arriving TLV resets the
    /// timer. This keeps the driver in fetchingHistory long enough for 0x42 + records to establish the
    /// commit authority before the summary is evaluated.
    private var pendingHistorySummary: (cursor: UInt32, moreData: Bool)?
    private var historySummarySettleTimer: Timer?
    private let historySummarySettleDelay: TimeInterval = 0.5
    /// One bounded ordering fallback per BLE session: if the first fetch has no UTC anchor, send a
    /// fresh SyncTime after that response and repeat the same uncommitted fetch once.
    private var postFetchAnchorRetryIssued = false
    /// A fresh 0x42 can sit behind earlier history pages. Look ahead without a max=0 ACK while keeping
    /// decoded events parked, the durable cursor unchanged, and the active SyncTime correlation intact.
    private var provisionalHistoryHighWater: UInt32?
    private var provisionalHistoryPageCount = 0
    private var provisionalHistoryOverflowed = false
    private let provisionalHistoryPageLimit = 32
    /// A retained Ring 4 page can expand into tens of thousands of verified IBI/temp events (the
    /// hardware-qualified page measured ~74k). Keep a hard RAM bound, but make it large enough for one
    /// real page; persistence below maps/writes it in small chunks before the cursor is committed.
    private let provisionalHistoryEventLimit = 100_000
    private let historyPersistenceChunkSize = 2_048
    /// Continue a bounded read-only anchor search after provisional RAM fills. Nothing is ACKed; once a
    /// real 0x42 appears, every skipped page is refetched from the durable cursor before persistence.
    private var anchorBootstrapSkippedHistory = false
    private var anchorBootstrapWindowCount = 0
    private let anchorBootstrapWindowLimit = 8

    /// Kick a history-fetch pass at the current cursor, but ONLY when the driver is idle-streaming (never
    /// overlaps a fetch already in flight - the driver's own phase is the guard, so this is safe to call
    /// both right after reaching `.streaming` and from the periodic timer).
    private func fetchHistoryIfIdle() {
        guard let driver, driver.phase == .streaming else { return }
        historyInventory = OuraRecordInventory()
        log("Oura: fetching history from cursor \(historyCursor) (\(describeCursor(historyCursor)))")
        loggedUncorrelatedTimeSync = false
        resetProvisionalHistorySearch()
        resetAnchorBootstrap()
        advance(.startHistoryFetch(cursor: historyCursor,
                                   unixSeconds: Int(Date().timeIntervalSince1970)))
    }

    private func scheduleTimeSyncReleaseFallback() {
        cancelTimeSyncReleaseFallback()
        let t = Timer.scheduledTimer(withTimeInterval: timeSyncReleaseTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.driver?.phase == .fetchingHistory else { return }
                self.timeSyncReleaseTimer = nil
                self.log("Oura: time sync echo timeout - releasing one guarded history fetch")
                self.advance(.timeSyncReleaseTimedOut(cursor: self.historyCursor))
            }
        }
        timeSyncReleaseTimer = t
    }

    private func cancelTimeSyncReleaseFallback() {
        timeSyncReleaseTimer?.invalidate()
        timeSyncReleaseTimer = nil
    }

    private func scheduleHistorySummary(_ summary: (cursor: UInt32, moreData: Bool)) {
        pendingHistorySummary = summary
        armHistorySummarySettleTimer()
    }

    private func bumpHistorySummarySettleTimer() {
        guard pendingHistorySummary != nil else { return }
        armHistorySummarySettleTimer()
    }

    private func armHistorySummarySettleTimer() {
        historySummarySettleTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: historySummarySettleDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let summary = self.pendingHistorySummary else { return }
                self.pendingHistorySummary = nil
                self.historySummarySettleTimer = nil
                await self.handleHistorySummary(summary)
            }
        }
        historySummarySettleTimer = t
    }

    private func cancelHistorySummarySettle() {
        historySummarySettleTimer?.invalidate()
        historySummarySettleTimer = nil
        pendingHistorySummary = nil
    }

    @discardableResult
    private func retryHistoryAfterMissingAnchorOnce(from cursor: UInt32? = nil) -> Bool {
        guard ringGen == .gen4, !postFetchAnchorRetryIssued,
              !provisionalHistoryOverflowed,
              pendingAnchorEvents.count <= provisionalHistoryEventLimit else { return false }
        postFetchAnchorRetryIssued = true
        let retryCursor = cursor ?? provisionalHistoryHighWater ?? historyCursor
        // Keep parked events from the first window: the fresh anchor can resolve the same continuous
        // ring clock. Reset only the per-window progress guard so the retry extends rather than repeats.
        provisionalHistoryHighWater = nil
        provisionalHistoryPageCount = 0
        log("Oura: retrying history once with post-fetch time sync")
        advance(.startHistoryFetch(cursor: retryCursor,
                                   unixSeconds: Int(Date().timeIntervalSince1970)))
        return true
    }

    private func resetProvisionalHistorySearch() {
        provisionalHistoryHighWater = nil
        provisionalHistoryPageCount = 0
        provisionalHistoryOverflowed = false
    }

    private func resetAnchorBootstrap() {
        anchorBootstrapSkippedHistory = false
        anchorBootstrapWindowCount = 0
    }

    /// Cross an in-memory page/event bound without ACKing the ring. Earlier decoded events leave RAM only;
    /// the later anchored refetch recovers them because the durable cursor and ring cursor never advanced.
    private func continueAnchorBootstrapIfBounded(from highWater: UInt32) -> Bool {
        let hitWindowBound = provisionalHistoryOverflowed
            || provisionalHistoryPageCount >= provisionalHistoryPageLimit
        guard ringGen == .gen4, hitWindowBound,
              anchorBootstrapWindowCount < anchorBootstrapWindowLimit,
              highWater > 0 else { return false }
        anchorBootstrapWindowCount += 1
        anchorBootstrapSkippedHistory = true
        pendingAnchorEvents.removeAll()
        provisionalHistoryOverflowed = false
        provisionalHistoryHighWater = highWater
        provisionalHistoryPageCount = 0
        driver?.enableHistoricalAnchorBootstrap()
        log("Oura: continuing bounded UTC-anchor bootstrap window \(anchorBootstrapWindowCount)/\(anchorBootstrapWindowLimit)")
        advance(.continueProvisionalHistory(cursor: highWater))
        return true
    }

    /// Read another page from the actual record high-water without ACKing it. This is deliberately
    /// bounded: no progress, too many pages, or too many parked decoded events aborts with the durable
    /// cursor untouched. The first high-water may regress after a ring session reset, so only later pages
    /// must be strictly increasing.
    private func continueProvisionalHistoryIfSafe(from highWater: UInt32) -> Bool {
        if pendingAnchorEvents.count > provisionalHistoryEventLimit {
            provisionalHistoryOverflowed = true
        }
        guard !provisionalHistoryOverflowed,
              provisionalHistoryPageCount < provisionalHistoryPageLimit,
              highWater > 0,
              provisionalHistoryHighWater.map({ highWater > $0 }) ?? true else { return false }
        provisionalHistoryHighWater = highWater
        provisionalHistoryPageCount += 1
        log("Oura: scanning later provisional history page \(provisionalHistoryPageCount)/\(provisionalHistoryPageLimit) for a UTC anchor")
        advance(.continueProvisionalHistory(cursor: highWater))
        return true
    }

    private func commitHistoryCursor(_ committedCursor: UInt32) {
        if committedCursor < historyCursor {
            log("Oura: ring-time regression detected (record high-water \(committedCursor) [\(describeCursor(committedCursor))] < persisted \(historyCursor) [\(describeCursor(historyCursor))]) - the ring's session likely reset; resetting our cursor to 0")
            historyCursor = 0
            driver?.invalidateTimeAnchorForRingClockRegression()
            OuraHistorySyncStore.save(cursor: 0, anchor: nil, deviceId: deviceId)
        } else {
            historyCursor = committedCursor
            OuraHistorySyncStore.save(cursor: committedCursor,
                                      anchor: driver?.currentPrimaryTimeAnchor,
                                      deviceId: deviceId)
        }
    }

    /// The driver observed a Ring 4 ring-start below the saved cursor/anchor floor. Clear the coherent
    /// state immediately; waiting for a batch summary could otherwise let the stale pair survive a crash.
    private func consumeDriverTimeStateInvalidation(_ driver: OuraDriver) {
        guard driver.consumePersistentTimeStateInvalidation() else { return }
        historyCursor = 0
        OuraHistorySyncStore.save(cursor: 0, anchor: nil, deviceId: deviceId)
        pendingAnchorEvents.removeAll()
        resetProvisionalHistorySearch()
        resetAnchorBootstrap()
        log("Oura: ring-start invalidated the saved history mapping; next fetch starts read-only")
    }

    private func ingestDriverNotification(_ bytes: [UInt8], driver: OuraDriver,
                                          origin: IngestOrigin) {
        if origin == .history { historyCaptureRecorder.capture(bytes) }
        // Keep the complete raw-record boundary long enough to inventory tag/count/size metadata, then
        // immediately discard the record bytes after the existing typed decoder runs. This is equivalent
        // to `driver.ingest(notification:reassembler:)`, but preserves a privacy-safe view of what the
        // firmware actually emitted (including unknown tags) for the exported strap log.
        var events: [OuraEvent] = []
        for record in reassembler.feed(bytes) {
            let decoded = driver.ingest(record: record)
            if origin == .history {
                historyInventory.observe(record, emittedEventCount: decoded.count)
            }
            events.append(contentsOf: decoded)
        }
        consumeDriverTimeStateInvalidation(driver)
        ingest(events, origin: origin)
    }

    /// Emit and clear the current values-free inventory. `outcome` is one of our fixed lifecycle labels,
    /// never ring/user text. Empty passes stay quiet so a terminal no-data poll does not spam the log.
    private func finishHistoryInventory(outcome: String) {
        guard !historyInventory.isEmpty else { return }
        log("Oura: history inventory outcome=\(outcome) \(historyInventory.summary())")
        historyInventory = OuraRecordInventory()
    }

    private func startHistoryFetchTimer() {
        stopHistoryFetchTimer()
        let t = Timer.scheduledTimer(withTimeInterval: historyFetchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchHistoryIfIdle() }
        }
        historyFetchTimer = t
    }

    private func stopHistoryFetchTimer() {
        historyFetchTimer?.invalidate()
        historyFetchTimer = nil
    }

    /// Handle a `0x11` GetEvents response (OURA_PROTOCOL.md s5.2): persist the advanced cursor (so a LATER
    /// connection resumes rather than re-fetching everything) and drive the driver's cursor-loop state
    /// machine, which asks for another ack-fetch while `moreData` or returns to `.streaming` once caught up.
    ///
    /// The ring's terminal "no more data" response (moreData=false, status 0x00) zero-fills the cursor
    /// field, whereas a mid-fetch response (moreData=true) carries a real advancing nonzero cursor. So the
    /// cursor is only trusted/persisted while the response is actually carrying new data - persisting the
    /// terminal zero would reset the cursor to 0 on every fetch and force a full backlog re-fetch forever.
    ///
    /// A cursor persisted from one BLE connection can come back SMALLER on the next connection's first real
    /// cursor: `ringTimestamp = (session << 16) | counter` (OURA_PROTOCOL.md s2.3), and the ring's internal
    /// `session` component can shift across reconnects/restarts. This is the same class of problem s5.5
    /// documents for the UTC anchor (ring-start with rt regression -> invalidate anchor). Resuming from a
    /// cursor whose session no longer matches the ring's current one is not a real resume - the ring just
    /// re-dumps its whole backlog anyway - so we detect the regression and reset to an honest, explicit 0
    /// rather than feed the ring a now-meaningless reference.
    private func handleHistorySummary(_ summary: (cursor: UInt32, moreData: Bool)) async {
        historyCaptureRecorder.flush()
        guard let driver else { return }
        let committedCursor = driver.activeHistoryHighWater
        let parkedBatchIsWithinLimit = !provisionalHistoryOverflowed
            && pendingAnchorEvents.count <= provisionalHistoryEventLimit
        if driver.hasFreshAnchorForActiveFetch, anchorBootstrapSkippedHistory {
            // Earlier search windows were dropped only from provisional RAM. Re-read from the durable
            // cursor under the real anchor before persisting or ACKing any part of the history.
            pendingAnchorEvents.removeAll()
            anchorBootstrapSkippedHistory = false
            resetProvisionalHistorySearch()
            log("Oura: UTC anchor bootstrapped - refetching skipped history before cursor commit")
            advance(.restartHistoryFromBootstrap(cursor: historyCursor))
            return
        }
        if summary.moreData {
            if driver.hasFreshAnchorForActiveFetch,
               let committedCursor,
               parkedBatchIsWithinLimit {
                // Commit order: resolve every parked page, persist the batch, then advance the cursor.
                // A crash before the final step causes a harmless refetch instead of silent data loss.
                guard await persistPendingHistoryDurably(using: driver) else {
                    guard self.driver.map({ $0 === driver }) == true else { return }
                    abortHistoryAfterPersistenceFailure()
                    return
                }
                commitHistoryCursor(committedCursor)
                resetProvisionalHistorySearch()
                advance(.historyCursorAdvanced(cursor: committedCursor, moreData: true))
                return
            }

            // Keep the batch provisional and read later pages from the actual record high-water. This
            // emits max=255 only: no ACK, no cursor save, and no persistence before an anchor exists.
            log("Oura: history cursor kept provisional because no fresh anchor or record high-water arrived")
            if !driver.hasFreshAnchorForActiveFetch,
               let committedCursor,
               continueProvisionalHistoryIfSafe(from: committedCursor) {
                return
            }
            if !driver.hasFreshAnchorForActiveFetch,
               let committedCursor,
               continueAnchorBootstrapIfBounded(from: committedCursor) {
                return
            }
            let retryCursor = provisionalHistoryHighWater ?? committedCursor
            if retryHistoryAfterMissingAnchorOnce(from: retryCursor) { return }
            pendingAnchorEvents.removeAll()
            resetProvisionalHistorySearch()
            finishHistoryInventory(outcome: "unanchored")
            advance(.historyCursorAdvanced(cursor: historyCursor, moreData: false))
            return
        }

        if driver.hasFreshAnchorForActiveFetch, parkedBatchIsWithinLimit {
            guard await persistPendingHistoryDurably(using: driver) else {
                guard self.driver.map({ $0 === driver }) == true else { return }
                abortHistoryAfterPersistenceFailure()
                return
            }
            if let committedCursor { commitHistoryCursor(committedCursor) }
            resetProvisionalHistorySearch()
            log("Oura: history fetch caught up (cursor \(historyCursor) [\(describeCursor(historyCursor))])")
        } else {
            if driver.hasFreshAnchorForActiveFetch {
                log("Oura: history fetch exceeded the bounded decoded-event window; saved cursor unchanged")
            } else {
                log("Oura: history fetch ended without a valid UTC anchor; saved cursor unchanged")
            }
            let retryCursor = provisionalHistoryHighWater ?? committedCursor
            if retryHistoryAfterMissingAnchorOnce(from: retryCursor) { return }
            pendingAnchorEvents.removeAll()
            resetProvisionalHistorySearch()
        }
        let terminalCursor = committedCursor ?? historyCursor
        finishHistoryInventory(outcome: driver.hasFreshAnchorForActiveFetch ? "caught-up" : "unanchored")
        advance(.historyCursorAdvanced(cursor: terminalCursor, moreData: false))
    }

    /// A failed SQLite write leaves the durable cursor/anchor untouched. Any rows written before the
    /// failure are natural-key idempotent, so the next periodic/reconnect fetch safely retries the batch.
    private func abortHistoryAfterPersistenceFailure() {
        log("Oura: WARNING history persistence failed; saved cursor unchanged and batch will retry")
        pendingAnchorEvents.removeAll()
        resetProvisionalHistorySearch()
        finishHistoryInventory(outcome: "persistence-failed")
        advance(.historyCursorAdvanced(cursor: historyCursor, moreData: false))
    }

    // MARK: - Sample buffer

    /// Buffered decoded events, flushed to `persist` in batches to keep the write path off the
    /// per-notification hot loop. Each entry carries its own `ts` (unix seconds): live-push events (HR,
    /// IBI, battery) are stamped at wall-clock arrival time; history-fetched events (temp, SpO2, HRV,
    /// sleep-phase) are stamped with their REAL ring-time-anchored UTC (s5.5) when an anchor is available,
    /// so last night's data is never mis-recorded as happening right now.
    private var buffer: [(events: [OuraEvent], ts: Int)] = []
    private var lastFlush: Date = .init()
    private let flushCount = 30
    private let flushInterval: TimeInterval = 30

    // MARK: - Live-HR re-engagement

    /// Daytime-HR auto-reverts after ~20 s (OURA_PROTOCOL.md s5.7), so while a live session is open we
    /// re-send the enable+subscribe every ~15 s. nil when no session is streaming.
    private var reengageTimer: Timer?
    private let reengageInterval: TimeInterval = 15

    // MARK: - Init

    /// - Parameters:
    ///   - live: the shared `LiveState` the Live UI observes.
    ///   - deviceId: the datastore device id these samples are attributed to.
    ///   - ringGen: the ring generation (selects MTU clamp + command set).
    ///   - authKey: supplies the 16-byte install key from the Keychain, or nil to drive `needsPairing`.
    ///   - authKeyStatus: supplies the status of the latest key read when available. This lets a denied or
    ///     locked Keychain read surface recovery guidance without claiming the ring needs a factory reset.
    ///   - persist: wired by the app to `store.insert(_, deviceId:)`. Called on the main actor.
    ///   - log: connect-lifecycle diagnostics sink, wired at the composition root to the same strap log
    ///     `BLEManager` writes to (issue #421). Every line is prefixed "Oura: ". Defaults to a no-op.
    ///   - onBattery: fired with the ring's battery percent (0-100). Default no-op.
    ///   - feedsLive: when false (the discovery-only wizard scanner) this source never touches LiveState
    ///     or persists. Default true.
    ///   - adoptIntent: EXPLICIT user-granted adopt consent for this connection. Default FALSE. Only when
    ///     true may the dangerous `0x24` installKey opcode ever be sent (the post-factory-reset provisioning,
    ///     s3.2). The standard live path leaves it false (read-only / Advanced-key), so a key is NEVER
    ///     installed outside the wizard's irreversible-consent adopt flow.
    public init(live: LiveState,
                deviceId: String,
                ringGen: OuraRingGen,
                authKey: @escaping () -> Data?,
                authKeyStatus: @escaping () -> OSStatus? = { nil },
                persist: @escaping (Streams) async -> Bool = { _ in true },
                persistSleepSession: @escaping (Int, Int) async -> Bool = { _, _ in true },
                log: @escaping (String) -> Void = { _ in },
                onBattery: @escaping (Int) -> Void = { _ in },
                feedsLive: Bool = true,
                adoptIntent: Bool = false) {
        let initialAuthKey = authKey()
        self.live = live
        self.deviceId = deviceId
        self.ringGen = ringGen
        self.authKey = authKey
        self.authKeyStatus = authKeyStatus
        self.cachedAuthKey = initialAuthKey?.count == OuraKeyStore.keyLength ? initialAuthKey : nil
        self.persist = persist
        self.persistSleepSession = persistSleepSession
        self.log = log
        self.onBattery = onBattery
        self.feedsLive = feedsLive
        self.adoptIntent = adoptIntent
        super.init()
        // Dedicated queue-less central -> callbacks arrive on the main queue, matching @MainActor.
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    /// Prefer the last valid in-process key, then retry Keychain. A missing/short value is never cached.
    private func resolvedAuthKey() -> Data? {
        if let cachedAuthKey { return cachedAuthKey }
        guard let key = authKey(), key.count == OuraKeyStore.keyLength else {
            let status = authKeyStatus() ?? OuraKeyStore.lastReadStatus
            log("Oura: stored install key unavailable (Keychain status \(status))")
            return nil
        }
        cachedAuthKey = key
        return key
    }

    // MARK: - Scanning

    /// A paired ring is matched by its exact CoreBluetooth identifier, so its reconnect scan may safely
    /// run without a service filter. Ring 4's normal advertisement is visible to macOS but does not always
    /// include the proprietary service UUID; a service-filtered scan can therefore miss a nearby saved
    /// ring forever. Discovery still uses the service filter for the add-device flow, where there is no
    /// previously-qualified identity to constrain an unfiltered scan.
    private var scanServices: [CBUUID]? {
        pendingConnectID == nil ? [Self.service] : nil
    }

    /// Scan for Oura rings advertising the Oura GATT service, keeping only ones the ring-gen recogniser
    /// accepts as an Oura ring.
    public func scan() {
        discovered.removeAll()
        seenPeripherals.removeAll()
        scanning = true
        needsPairing = nil
        if pendingConnectID == nil {
            log("Oura: scanning for an Oura ring (service \(OuraGatt.serviceUUID))")
        } else {
            log("Oura: scanning for the paired Oura ring by saved identity")
        }
        guard central.state == .poweredOn else {
            log("Oura: Bluetooth not powered on (state=\(central.state.rawValue)) - scan deferred until ready")
            return
        }
        central.scanForPeripherals(withServices: scanServices,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    // MARK: - Connecting

    /// Connect to the chosen ring and start the auth -> enable -> stream flow. Mirrors the
    /// StandardHRSource cached-by-identifier-first, else scan-then-connect pattern.
    public func connect(_ id: UUID) {
        stopScan()
        needsPairing = nil
        // Remember the paired ring so an involuntary drop auto-reconnects to it (#912). An explicit connect
        // is never the intentional-teardown case, so clear the suppression flag.
        reconnectID = id
        intentionalDisconnect = false
        let p = seenPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else {
            // Never seen by this Mac/iPhone yet -> remember it and scan; didDiscover connects on sight.
            pendingConnectID = id
            log("Oura: paired ring not cached yet - scanning to find it")
            scan()
            return
        }
        seenPeripherals[id] = p
        peripheral = p
        p.delegate = self
        guard central.state == .poweredOn else {
            pendingConnectID = id
            log("Oura: Bluetooth not powered on - ring connection deferred until ready")
            return
        }
        log("Oura: connecting to paired ring")
        central.connect(p, options: nil)
    }

    /// Tear down: cancel the connection, stop scanning, flush, clear all transient state. Idempotent.
    public func stop() {
        // A deliberate teardown (device switch / removal) must NOT auto-reconnect: mark it intentional and
        // drop the reconnect target so any pending backoff bails and no fresh one is scheduled (#912).
        intentionalDisconnect = true
        reconnectID = nil
        failedReconnectAttempts = 0
        stopScan()
        pendingConnectID = nil
        stopReengageTimer()
        stopHistoryFetchTimer()
        cancelTimeSyncReleaseFallback()
        cancelHistorySummarySettle()
        cancelNoKeyIdentityQualification()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        writeCharacteristic = nil
        resetCommandQueue()
        inboundNotifyUUIDs.removeAll()
        pendingNotifyUUIDs.removeAll()
        enabledNotifyCount = 0
        pendingEventCategoryResponses = 0
        acknowledgedEventCategoryResponses = 0
        postFetchAnchorRetryIssued = false
        resetProvisionalHistorySearch()
        resetAnchorBootstrap()
        // An interrupted page was never cursor-committed and will be refetched; never fabricate teardown
        // timestamps or race an async write during disconnect.
        discardUnanchoredHistory()
        driver?.stop()
        driver = nil
        reassembler.reset()
        loggedFirstHR = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedFirstBedtime = false
        loggedAnchor = false
        loggedTierBKinds.removeAll()
        reachedStreaming = false
        pendingSpO2AutomaticEnable = false
        pendingInstallKey = nil
        adoptPhase = .idle
        batteryPct = nil
        spo2AutomaticEnabled = nil
        needsPairing = nil
        historyCaptureRecorder.flush()
        finishHistoryInventory(outcome: "stopped")
        flush()                       // persist anything still buffered
        if feedsLive { live.clearDeviceTelemetryForTransition() }
    }

    // MARK: - Driver wiring

    /// Queue commands for one-at-a-time, Ring-4-qualified Write Without Response delivery.
    private func write(_ commands: [OuraCommand]) {
        commandQueue.append(contentsOf: commands)
        drainCommandQueue()
    }

    private func resetCommandQueue() {
        commandWorkItem?.cancel()
        commandWorkItem = nil
        commandQueue.removeAll()
        lastCommandWriteAt = 0
    }

    private func drainCommandQueue() {
        guard commandWorkItem == nil,
              let peripheral,
              let writeCharacteristic,
              !commandQueue.isEmpty,
              peripheral.canSendWriteWithoutResponse else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(0, Self.minimumCommandSpacing - (now - lastCommandWriteAt))
        if delay > 0 {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.commandWorkItem = nil
                self.drainCommandQueue()
            }
            commandWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return
        }

        let cmd = commandQueue.removeFirst()
        let mtuPayload = min(ringGen.maxWritePayload,
                             peripheral.maximumWriteValueLength(for: .withoutResponse))
        guard cmd.bytes.count <= mtuPayload else {
            log("Oura: skipping \(cmd.label) - \(cmd.bytes.count)B exceeds the \(mtuPayload)B write window")
            drainCommandQueue()
            return
        }
        log("Oura: -> \(cmd.label)")
        peripheral.writeValue(Data(cmd.bytes), for: writeCharacteristic, type: .withoutResponse)
        if cmd.label.hasPrefix("event_category_") {
            pendingEventCategoryResponses += 1
        }
        // Start the liveness fallback from the actual BLE write, not from the earlier enqueue. Battery,
        // identity, or DHR commands can already be queued; arming at enqueue time allowed the timeout to
        // release Flush/GetEvents before SyncTime had physically reached Ring 4.
        if cmd.label == "sync_time", ringGen == .gen4, driver?.phase == .fetchingHistory {
            scheduleTimeSyncReleaseFallback()
        }
        lastCommandWriteAt = ProcessInfo.processInfo.systemUptime
        drainCommandQueue()
    }

    /// Advance the driver with a transition and write whatever it asks for next.
    private func advance(_ transition: OuraTransition) {
        guard let driver else { return }
        let commands = driver.nextStep(after: transition)
        if driver.phase == .needsKeyInstall, !adoptIntent {
            beginNoKeyIdentityQualification(commands: commands)
        }
        write(commands)
        // Surface the driver's coarse phase honestly into the UI state.
        switch driver.phase {
        case .needsKeyInstall:
            // A factory-reset ring (auth status inFactoryReset) or no key available. The dangerous key
            // install is the ONLY thing that recovers it, and ONLY with explicit adopt consent: provision
            // when `adoptIntent`, otherwise stay honest (never loop the dangerous command).
            if adoptIntent {
                cancelNoKeyIdentityQualification()
                provisionKeyInstall()
            } else if !noKeyIdentityGate.isWaiting {
                announceNeedsPairing(reason: .factoryResetOrNoKey)
            }
        case .authFailed(let status):
            announceNeedsPairing(reason: .authFailed(status))
        case .streaming:
            if !reachedStreaming {
                reachedStreaming = true
                adoptPhase = .streaming   // re-auth after an install (or a normal auth) reached the stream: adoption complete
                pendingInstallKey = nil   // an OK ack already persisted the key; nothing left in flight
                if feedsLive {
                    // Authentication + live-mode acknowledgement prove the transport is connected even
                    // while the ring is on its charger and has not produced a physiological sample yet.
                    // Keep `bonded` false: that flag carries WHOOP encrypted-bond/haptics semantics.
                    live.connected = true
                    live.streamingLiveHR = true
                }
                log("Oura: live-HR enabled - streaming HR / IBI")
                startReengageTimer()
                startHistoryFetchTimer()
                // Ask for battery BEFORE starting GetEvents. Tested Ring 4 firmware can leave an
                // already-caught-up history request unanswered; putting battery behind that request made
                // a healthy reconnect look battery-less even though the initial adoption read it fine.
                write([OuraCommands.getBattery()])   // the 0x0D reply routes to onBattery
                fetchHistoryIfIdle()   // then pull last night's banked temp/SpO2/HRV/sleep-phase
            }
            sendPendingSpO2AutomaticEnableIfReady()
        default:
            break
        }
    }

    /// Arm the no-key identity window before the commands are enqueued, so even a very fast response
    /// cannot race the gate. A second call replaces the prior window; `.ready` is the only normal caller.
    private func beginNoKeyIdentityQualification(commands: [OuraCommand]) {
        guard noKeyIdentityGate.begin(commands: commands) else { return }
        noKeyIdentityTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.noKeyIdentityGate.isWaiting else { return }
            self.log("Oura: identity qualification timed out - continuing with the pairing-required state")
            self.cancelNoKeyIdentityQualification()
            self.announceNeedsPairing(reason: .factoryResetOrNoKey)
        }
        noKeyIdentityTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.noKeyIdentityResponseTimeout,
            execute: item
        )
    }

    /// Consume only identity opcodes expected by the active no-key window. Opcode 0x19 is also used by
    /// Ring 4 event-category acknowledgements, but those occur after authentication/history fetch and can
    /// never overlap this pre-auth gate.
    private func recordNoKeyIdentityResponse(op: UInt8) {
        guard noKeyIdentityGate.receive(op: op) == .complete else { return }
        log("Oura: serial-free identity qualification complete")
        cancelNoKeyIdentityQualification()
        announceNeedsPairing(reason: .factoryResetOrNoKey)
    }

    private func cancelNoKeyIdentityQualification() {
        noKeyIdentityTimeoutWorkItem?.cancel()
        noKeyIdentityTimeoutWorkItem = nil
        noKeyIdentityGate.reset()
    }

    /// Queue the one sensor-setting write needed for overnight percentage records. The caller is the
    /// explicit confirmation button in Devices; normal connect/history code never invokes this.
    public func requestAutomaticSpO2Enable() {
        guard feedsLive else { return }
        guard spo2AutomaticEnabled != true else {
            log("Oura: automatic SpO2 measurement is already on")
            return
        }
        pendingSpO2AutomaticEnable = true
        log("Oura: automatic SpO2 enable requested by user")
        sendPendingSpO2AutomaticEnableIfReady()
    }

    private func sendPendingSpO2AutomaticEnableIfReady() {
        guard pendingSpO2AutomaticEnable, driver?.phase == .streaming else { return }
        pendingSpO2AutomaticEnable = false
        write([OuraCommands.spO2EnableAutomatic(), OuraCommands.spO2ReadStatus()])
    }

    // MARK: - Adopt key-install handshake (s3.2) - ONLY ever reached with explicit adopt consent

    /// PROVISION a fresh key into a factory-reset ring (OURA_PROTOCOL.md s3.2). Reached ONLY from `advance`
    /// when `driver.phase == .needsKeyInstall` AND `adoptIntent == true`. Steps: (1) generate a fresh
    /// cryptographically-random 16-byte key; (2) ask the driver for the dangerous `24 10 <key>` install
    /// command (the driver's own `allowKeyInstall`/phase gate is the second guard) and write it; (3) hold the
    /// key in memory and mark `.installingKey` (an install IS now running). The key is NOT persisted yet: it
    /// is written to the keystore only once the ring acks OK (`handleKeyInstallAck`), so a failed install
    /// never leaves a key the next session would wrongly trust. On any build/RNG failure we stay honest.
    private func provisionKeyInstall() {
        guard adoptIntent else { return }                 // belt-and-braces: never provision without consent
        guard pendingInstallKey == nil else { return }    // an install is already in flight; don't double-send
        guard let driver else { return }
        guard let key = Self.randomInstallKey() else {
            announceNeedsPairing(reason: .installFailed("could not generate a key"))
            return
        }
        guard let cmd = driver.beginKeyInstall(key: [UInt8](key)) else {
            // The driver refused (wrong phase / not allowed / build failed): stay honest, never retry blind.
            announceNeedsPairing(reason: .installFailed("the install command could not be prepared"))
            return
        }
        pendingInstallKey = key
        adoptPhase = .installingKey
        log("Oura: installing NOOP's key on the reset ring")
        write([cmd])
    }

    /// Handle the ring's `0x25` SetAuthKey ack (OURA_PROTOCOL.md s3.2: `25 01 00`, status byte `0x00` = OK).
    /// On OK: persist the freshly-provisioned key under this `deviceId` (so every future session authenticates
    /// with it), then reconnect because tested Ring 4 firmware requires authentication on a fresh link. On a
    /// non-OK status (or a missing pending key) announce an honest failure and do NOT retry the dangerous command.
    private func handleKeyInstallAck(status: UInt8) {
        guard driver?.phase == .installingKey,
              let key = pendingInstallKey,
              let peripheral else { return }
        guard status == 0x00 else {
            announceNeedsPairing(reason: .installFailed("the ring did not accept the key (status \(status))"))
            return
        }
        // Persist ONLY on OK, so a failed/absent ack never leaves a wrongly-trusted key behind.
        guard OuraKeyStore.save(key, deviceId: deviceId) else {
            announceNeedsPairing(reason: .installFailed("the installed key could not be stored"))
            return
        }
        cachedAuthKey = key
        log("Oura: key installed and stored - reconnecting with the new key")
        pendingInstallKey = nil
        adoptPhase = .idle
        // Ring 4 firmware 2.12.3 acknowledges the install but does not answer a nonce request on the same
        // link. The normal involuntary-disconnect path reconnects and constructs a fresh driver that reads
        // the acknowledged key from Keychain.
        central.cancelPeripheralConnection(peripheral)
    }

    /// A fresh 16-byte application key for the adopt install, from the system CSPRNG. Per OURA_PROTOCOL.md
    /// s3 the key is exactly 16 bytes; `SecRandomCopyBytes` is the same CSPRNG the rest of the app relies on.
    /// Returns nil if the RNG fails (then the caller stays honest rather than installing a weak key).
    private static func randomInstallKey() -> Data? {
        var bytes = [UInt8](repeating: 0, count: OuraKeyStore.keyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    // MARK: - Buffer / persistence

    private func enqueue(_ events: [OuraEvent], ts: Int) {
        guard !events.isEmpty else { return }
        buffer.append((events: events, ts: ts))
        if buffer.count >= flushCount || Date().timeIntervalSince(lastFlush) >= flushInterval {
            flush()
        }
    }

    private func flush() {
        guard feedsLive, !buffer.isEmpty else { lastFlush = Date(); return }
        let entries = buffer
        buffer.removeAll()
        lastFlush = Date()
        let persistOperation = persist
        Task {
            for entry in entries {
                // Live pushes are best-effort and independent of history cursor state. History uses the
                // awaited path below so its durable cursor can never outrun SQLite.
                _ = await persistOperation(OuraStreamMapping.streams(from: entry.events, at: entry.ts))
            }
        }
    }

    /// Resolve and durably persist the complete active history page before the caller saves/ACKs its
    /// cursor. Partial success is safe: natural-key inserts are idempotent and the unchanged cursor causes
    /// the whole page to be retried. Corrupt out-of-window timestamps are explicitly withheld, never
    /// restamped with wall-clock arrival time.
    private func persistPendingHistoryDurably(using driver: OuraDriver) async -> Bool {
        guard self.driver.map({ $0 === driver }) == true,
              driver.canResolveHistoryTimestamps else { return pendingAnchorEvents.isEmpty }
        let parkedBatch = pendingAnchorEvents
        var withheld = 0

        // Natural-key inserts are idempotent, so a failure after an earlier chunk is harmless: the
        // durable cursor remains unchanged and the next fetch rewrites the same rows. Chunking bounds the
        // transient Streams allocation even when one Ring 4 page expands to tens of thousands of events.
        for chunkStart in stride(from: 0, to: parkedBatch.count, by: historyPersistenceChunkSize) {
            let chunkEnd = min(chunkStart + historyPersistenceChunkSize, parkedBatch.count)
            var streamBatch = Streams()
            var sleepWindows: [(start: Int, end: Int)] = []

            for pending in parkedBatch[chunkStart..<chunkEnd] {
                if case .bedtimePeriod(let period) = pending.event {
                    guard let start = driver.unixSeconds(forRingTimestamp: period.startRingTimestamp),
                          let end = driver.unixSeconds(forRingTimestamp: period.endRingTimestamp) else {
                        withheld += 1
                        continue
                    }
                    let duration = end - start
                    guard duration >= 15 * 60, duration <= 16 * 60 * 60 else {
                        withheld += 1
                        continue
                    }
                    sleepWindows.append((start, end))
                    continue
                }
                guard let ts = driver.unixSeconds(forRingTimestamp: pending.ringTimestamp) else {
                    withheld += 1
                    continue
                }
                let mapped = OuraStreamMapping.streams(from: [pending.event], at: ts)
                streamBatch.hr.append(contentsOf: mapped.hr)
                streamBatch.rr.append(contentsOf: mapped.rr)
                streamBatch.spo2.append(contentsOf: mapped.spo2)
                streamBatch.skinTemp.append(contentsOf: mapped.skinTemp)
                streamBatch.resp.append(contentsOf: mapped.resp)
                streamBatch.gravity.append(contentsOf: mapped.gravity)
                streamBatch.steps.append(contentsOf: mapped.steps)
                streamBatch.sleepState.append(contentsOf: mapped.sleepState)
                streamBatch.ppgHr.append(contentsOf: mapped.ppgHr)
                streamBatch.events.append(contentsOf: mapped.events)
                streamBatch.battery.append(contentsOf: mapped.battery)
            }

            if feedsLive {
                if !streamBatch.isEmpty {
                    guard await persist(streamBatch) else { return false }
                    guard self.driver.map({ $0 === driver }) == true else { return false }
                }
                for window in sleepWindows {
                    guard await persistSleepSession(window.start, window.end) else { return false }
                    guard self.driver.map({ $0 === driver }) == true else { return false }
                }
            }
        }
        if withheld > 0 {
            log("Oura: withheld \(withheld) history sample(s) with implausible UTC timing")
        }
        // Preserve any TLV that arrived during an awaited SQLite operation. It was not in this snapshot
        // and the old cursor will cause it to be delivered again on the next page.
        guard pendingAnchorEvents.count >= parkedBatch.count else { return false }
        pendingAnchorEvents.removeFirst(parkedBatch.count)
        return true
    }

    /// Drop history that cannot be mapped to UTC at session teardown. The count is useful diagnostics and
    /// contains no biometric value; missing rows are more honest than confidently wrong timestamps.
    private func discardUnanchoredHistory() {
        guard !pendingAnchorEvents.isEmpty else { return }
        log("Oura: withheld \(pendingAnchorEvents.count) uncommitted history sample(s) for safe refetch")
        pendingAnchorEvents.removeAll()
    }

    // MARK: - Live ingest

    /// Fold decoded events into live state (HR / R-R only - skin temp and SpO2 are SLEEP-ONLY on this
    /// hardware, never a live readout) + the persist buffer. Live-push events (HR/IBI/battery) are stamped
    /// at wall-clock arrival time, since they genuinely are "now". History-fetched events (temp, SpO2, HRV,
    /// sleep-phase) are stamped with their REAL ring-time-anchored UTC (s5.5) so last night's data is never
    /// mis-recorded as happening right now; when no anchor has arrived yet this session, we park the event
    /// until one does (`pendingAnchorEvents`), rather than immediately guessing wall-clock. Out-of-range
    /// HR/temp is dropped, never shown.
    private func ingest(_ events: [OuraEvent], origin: IngestOrigin) {
        guard !events.isEmpty, let driver else { return }
        let now = Int(Date().timeIntervalSince1970)
        for e in events {
            switch e {
            case .hr(let hr):
                guard hr.bpm >= 30, hr.bpm <= 220 else { continue }   // physiological gate
                if origin == .live {
                    if !loggedFirstHR {
                        loggedFirstHR = true
                        log("Oura: receiving live heart-rate data")
                    }
                    if feedsLive {
                        live.heartRate = hr.bpm
                        live.connected = true
                    }
                    enqueue([e], ts: now)
                } else {
                    parkHistoryEvent(e, ringTimestamp: hr.ringTimestamp)
                }

            case .ibi(let ibi):
                if origin == .live {
                    if feedsLive { live.setRRIntervals([ibi.ibiMs]) }
                    enqueue([e], ts: now)
                } else {
                    parkHistoryEvent(e, ringTimestamp: ibi.ringTimestamp)
                }

            case .battery(let bat):
                batteryPct = bat.percent
                onBattery(bat.percent)
                log("Oura: battery status updated")
                enqueue([e], ts: now)

            case .temp(let t):
                guard t.celsius >= 20, t.celsius <= 45 else { continue }   // physiological gate (wrist skin temp)
                if !loggedFirstTemp {
                    loggedFirstTemp = true
                    log("Oura: skin-temperature history decoded")
                }
                parkHistoryEvent(e, ringTimestamp: t.ringTimestamp)

            case .spo2(let s):
                if !loggedFirstSpo2 {
                    loggedFirstSpo2 = true
                    log("Oura: SpO2 history decoded")
                }
                parkHistoryEvent(e, ringTimestamp: s.ringTimestamp)

            case .hrv(let v):
                parkHistoryEvent(e, ringTimestamp: v.ringTimestamp)

            case .sleepPhase(let v):
                parkHistoryEvent(e, ringTimestamp: v.ringTimestamp)

            case .sleepPeriod(let v):
                parkHistoryEvent(e, ringTimestamp: v.ringTimestamp)

            case .bedtimePeriod(let period):
                if !loggedFirstBedtime {
                    loggedFirstBedtime = true
                    log("Oura: bedtime history decoded")
                }
                parkHistoryEvent(e, ringTimestamp: period.ringTimestamp)

            case .timeSync(let sync):
                guard driver.canResolveHistoryTimestamps,
                      driver.unixSeconds(forRingTimestamp: sync.ringTimestamp) != nil else {
                    if origin == .history, !loggedUncorrelatedTimeSync {
                        loggedUncorrelatedTimeSync = true
                        log("Oura: time-sync history record did not establish the active fetch anchor")
                    }
                    continue
                }
                if !loggedAnchor {
                    loggedAnchor = true
                    log("Oura: UTC time anchor acquired - history-fetched samples now get their real time")
                }
                // The 0x42 can arrive anywhere; parked samples resolve only at the batch summary so SQLite
                // completion can be awaited before the cursor is saved/ACKed.

            case .rtcBeacon(let beacon):
                guard driver.canResolveHistoryTimestamps,
                      driver.unixSeconds(forRingTimestamp: beacon.ringTimestamp) != nil else { continue }
                if !loggedAnchor {
                    loggedAnchor = true
                    log("Oura: UTC time anchor acquired - history-fetched samples now get their real time")
                }
                // A qualified active-fetch beacon can be durable; otherwise this remains session-only.

            case .tierB(let summary):
                // Investigation-only presence marker. Do not place raw payload bytes or decoded biometric
                // values in the exportable strap log; fixture capture stays an explicit local workflow.
                if !loggedTierBKinds.contains(summary.kind) {
                    loggedTierBKinds.insert(summary.kind)
                    log("Oura: unverified \(summary.kind) history observed (not persisted)")
                }

            case .activityInfo:
                if !loggedTierBKinds.contains("activity_info") {
                    loggedTierBKinds.insert("activity_info")
                    log("Oura: unverified activity history observed (not persisted)")
                }

            default:
                break   // motion / state / debugText: not a durable Streams row (see OuraStreamMapping)
            }
        }
    }

    private func parkHistoryEvent(_ event: OuraEvent, ringTimestamp: UInt32) {
        pendingAnchorEvents.append((event, ringTimestamp))
    }

    // MARK: - Re-engagement timer (daytime-HR auto-reverts ~20s)

    private func startReengageTimer() {
        stopReengageTimer()
        let t = Timer.scheduledTimer(withTimeInterval: reengageInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reengageLiveHR() }
        }
        reengageTimer = t
    }

    private func stopReengageTimer() {
        reengageTimer?.invalidate()
        reengageTimer = nil
    }

    /// Re-send the live-HR enable+subscribe so the ~20 s auto-revert never silently stops the stream.
    private func reengageLiveHR() {
        guard let driver, reachedStreaming else { return }
        write(driver.reengageLiveHRCommands())
    }

    // MARK: - Honest needs-pairing fallback (Huami precedent)

    private enum NeedsPairingReason {
        case factoryResetOrNoKey
        case keychainUnavailable(OSStatus)
        case authFailed(OuraAuthStatus)
        case installFailed(String)
    }

    /// Record + log the honest "this ring needs a pairing handshake NOOP can't complete" outcome (once),
    /// and drop the link so no half-authenticated session lingers. We never fabricate a reading. Also marks
    /// `adoptPhase = .failed` so an in-flight adopt's Adopting step lands on a REACHABLE honest Failed state
    /// (file-import + Advanced-key fallbacks), and clears any in-flight install key WITHOUT persisting it (a
    /// failed install must never leave a wrongly-trusted key). RECOVERY-HONEST: a factory-reset ring is NOT
    /// bricked; re-pairing it in the Oura app brings it back. We never claim a key was installed here.
    private func announceNeedsPairing(reason: NeedsPairingReason) {
        cancelNoKeyIdentityQualification()
        // A failed install must drop its pending key whether or not this is the first announce.
        pendingInstallKey = nil
        adoptPhase = .failed
        // This is an honest dead-end (no key / auth rejected / install failed), NOT a transient drop, so the
        // ensuing disconnect must NOT auto-reconnect (that would loop the same auth failure and drain the
        // ring). Suppress it the same way a deliberate teardown does (#912): a later user reconnect re-arms.
        // Run this UNCONDITIONALLY, before the first-announce guard, so a SECOND announce in the same session
        // (needsPairing already set) still cancels the lingering peripheral and re-suppresses the reconnect,
        // mirroring the Android twin (OuraLiveSource.kt announceNeedsPairing).
        intentionalDisconnect = true
        reconnectID = nil
        failedReconnectAttempts = 0
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        guard needsPairing == nil else { return }
        let detail: String
        switch reason {
        case .factoryResetOrNoKey:
            detail = "NOOP needs the ring's install key to read it live, and that pairing handshake isn't set up yet."
        case .keychainUnavailable(let status):
            let msg = "NOOP couldn't read this ring's saved key from Keychain (status \(status)). Unlock your Mac, allow NOOP access if macOS asks, then reconnect. Do not factory reset the ring."
            needsPairing = msg
            log("Oura: \(msg)")
            stopReengageTimer()
            stopHistoryFetchTimer()
            cancelTimeSyncReleaseFallback()
            cancelHistorySummarySettle()
            if feedsLive { live.clearDeviceTelemetryForTransition() }
            return
        case .authFailed(let status):
            detail = "The ring rejected the pairing handshake (status \(status.rawValue))."
        case .installFailed(let why):
            detail = "NOOP couldn't take over this ring (\(why))."
        }
        let recovery = " The ring isn't bricked: re-pair it in the Oura app to recover it."
        let msg = detail + " Live data isn't available - export from the Oura app and import the file instead." + recovery
        needsPairing = msg
        log("Oura: \(msg)")
        stopReengageTimer()
        stopHistoryFetchTimer()
        cancelTimeSyncReleaseFallback()
        cancelHistorySummarySettle()
        if feedsLive { live.clearDeviceTelemetryForTransition() }
    }

    // CB delegate callbacks live in the @preconcurrency extensions below. The queue-less central delivers
    // them on the main thread, so MainActor isolation is sound; @preconcurrency lets this @MainActor type
    // satisfy the nonisolated CoreBluetooth requirements (same pattern as StandardHRSource / BLEManager).
}

// MARK: - CBCentralManagerDelegate

extension OuraLiveSource: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Oura: Bluetooth central state \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            // Replay any intent that arrived before the radio was ready.
            if let id = pendingConnectID, let p = seenPeripherals[id] {
                pendingConnectID = nil
                central.connect(p, options: nil)
            } else if scanning {
                central.scanForPeripherals(withServices: scanServices,
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        default:
            // Radio off / unauthorized / resetting -> the link is not live.
            if feedsLive { live.clearDeviceTelemetryForTransition() }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        // The scan already filters on the Oura service, but re-check the name through the gen recogniser
        // so a coincidental service match without an Oura-shaped name is dropped (best-effort).
        let detectedGen = OuraRingGen.recognise(advertisedName: name)
        let id = peripheral.identifier
        // An unfiltered reconnect scan is authorized only by the exact saved CoreBluetooth identity.
        // Ignore every other nearby BLE device before it reaches the picker or the exportable log.
        if let pendingConnectID, id != pendingConnectID {
            if detectedGen != nil {
                log("Oura: found a nearby Oura ring that does not match the saved identity")
            }
            return
        }
        let firstSight = seenPeripherals[id] == nil
        seenPeripherals[id] = peripheral
        // Reset-mode names can contain a ring serial. The UI may show the local advertisement so the
        // owner can pick their ring, but the exportable strap log must never persist that identifier.
        if firstSight { log("Oura: found candidate ring rssi \(RSSI.intValue)") }
        let ring = DiscoveredRing(id: id,
                                  name: name.isEmpty ? "Oura" : name,
                                  rssi: RSSI.intValue,
                                  detectedGen: detectedGen)
        if let idx = discovered.firstIndex(where: { $0.id == id }) {
            discovered[idx] = ring
        } else {
            discovered.append(ring)
        }
        // If we were scanning specifically to reach this ring (a not-yet-cached active ring), connect now.
        if pendingConnectID == id {
            pendingConnectID = nil
            connect(id)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Oura: connected - discovering services")
        failedReconnectAttempts = 0   // a real connection clears the reconnect backoff (#912)
        peripheral.delegate = self
        resetCommandQueue()
        cancelNoKeyIdentityQualification()
        inboundNotifyUUIDs.removeAll()
        pendingNotifyUUIDs.removeAll()
        enabledNotifyCount = 0
        pendingEventCategoryResponses = 0
        acknowledgedEventCategoryResponses = 0
        postFetchAnchorRetryIssued = false
        resetProvisionalHistorySearch()
        resetAnchorBootstrap()
        // Fresh driver per connection so a new session re-runs auth (the app key is session-scoped). The
        // driver's `allowKeyInstall` is gated on this connection's adopt consent ONLY: with no consent the
        // dangerous `0x24` installKey can never be sequenced, so a read-only / Advanced-key connect stays
        // honest (it announces needs-pairing instead of provisioning). Per OURA_PROTOCOL.md s3.2.
        // allowTierB: true - INVESTIGATION ONLY (activity/real_steps/sleep-summary/smoothed-SpO2 tags,
        // OURA_PROTOCOL.md s7.3 Tier B, UNVERIFIED layouts; PR #960). This lets `ingest` LOG what the
        // ring actually sends (raw bytes per kind, decoded MET for 0x50) so the layouts can be validated
        // against real captures. It can never leak a value into scoring: OuraStreamMapping drops
        // .tierB/.activityInfo unconditionally - the Tier-discipline gate that matters lives there, not here.
        // Cursor + validated durable time anchor are one coherent state. The driver may use the saved
        // mapping for timestamp conversion after reconnect, but it independently re-authorizes cursor
        // commits only after monotonic ring-clock continuity is proven.
        let syncState = OuraHistorySyncStore.read(deviceId: deviceId)
        historyCursor = syncState.cursor
        let resolvedKey = resolvedAuthKey()
        if resolvedKey == nil,
           let status = authKeyStatus(),
           status != errSecSuccess,
           status != errSecItemNotFound {
            announceNeedsPairing(reason: .keychainUnavailable(status))
            return
        }
        driver = OuraDriver(ringGen: ringGen,
                            authKey: resolvedKey.map { [UInt8]($0) },
                            allowTierB: true,
                            allowKeyInstall: adoptIntent,
                            persistedTimeAnchor: syncState.anchor)
        reachedStreaming = false
        pendingSpO2AutomaticEnable = false
        loggedFirstHR = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedFirstBedtime = false
        loggedAnchor = false
        loggedTierBKinds.removeAll()
        pendingAnchorEvents.removeAll()   // a fresh session must never replay a stale-anchor guess
        historyInventory = OuraRecordInventory()
        pendingInstallKey = nil
        adoptPhase = .idle
        spo2AutomaticEnabled = nil
        reassembler.reset()
        peripheral.discoverServices([Self.service])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Oura: WARNING failed to connect - \(error?.localizedDescription ?? "unknown error")")
        if feedsLive { live.clearDeviceTelemetryForTransition() }
        // The ring wiped its bond (re-paired in the Oura app, or a firmware reset). CoreBluetooth surfaces
        // this as a stable CBError, and re-issuing connect just loops the same stale-pairing failure and
        // drains the ring, so DON'T auto-reconnect: route to the honest needs-pairing path instead, exactly
        // like BLEManager returns early on this error without rescheduling (#912/#414).
        if let cbErr = error as? CBError, cbErr.code == .peerRemovedPairingInformation {
            announceNeedsPairing(reason: .factoryResetOrNoKey)
            return
        }
        // A failed connect to the paired ring (e.g. out of range at launch) retries on the backoff so the
        // ring comes back on its own, mirroring BLEManager's failed-connect reschedule (#912/#414).
        scheduleReconnect()
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            log("Oura: disconnected - \(error.localizedDescription)")
        } else {
            log("Oura: disconnected (clean)")
        }
        stopReengageTimer()
        stopHistoryFetchTimer()
        cancelTimeSyncReleaseFallback()
        cancelHistorySummarySettle()
        cancelNoKeyIdentityQualification()
        // The uncommitted page remains on-ring and will be refetched after reconnect.
        discardUnanchoredHistory()
        driver?.stop()
        driver = nil
        reassembler.reset()
        writeCharacteristic = nil
        resetCommandQueue()
        inboundNotifyUUIDs.removeAll()
        pendingNotifyUUIDs.removeAll()
        enabledNotifyCount = 0
        pendingEventCategoryResponses = 0
        acknowledgedEventCategoryResponses = 0
        postFetchAnchorRetryIssued = false
        resetProvisionalHistorySearch()
        resetAnchorBootstrap()
        loggedFirstHR = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedFirstBedtime = false
        loggedAnchor = false
        loggedTierBKinds.removeAll()
        reachedStreaming = false
        pendingSpO2AutomaticEnable = false
        pendingInstallKey = nil
        // A disconnect MID-install is an honest failure (no ack came); a disconnect after streaming leaves
        // the completed `.streaming` outcome intact so the wizard's success transition isn't undone.
        if adoptPhase == .installingKey { adoptPhase = .failed }
        batteryPct = nil
        spo2AutomaticEnabled = nil
        historyCaptureRecorder.flush()
        finishHistoryInventory(outcome: "disconnected")
        flush()
        if feedsLive { live.clearDeviceTelemetryForTransition() }
        if self.peripheral?.identifier == peripheral.identifier { self.peripheral = nil }
        // Auto-reconnect on an INVOLUNTARY drop (#912): the paired ring went out of range or the link timed
        // out. Re-issue a connect on the backoff so it comes back on its own, exactly like the WHOOP strap.
        // A deliberate `stop()` set `intentionalDisconnect`/cleared `reconnectID`, so this is a no-op there.
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension OuraLiveSource: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("Oura: WARNING service discovery failed - \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            log("Oura: services discovered but the list was empty")
            return
        }
        guard let svc = services.first(where: { $0.uuid == Self.service }) else {
            log("Oura: Oura service NOT FOUND - this ring may not expose the expected GATT layout")
            return
        }
        log("Oura: Oura service found - discovering characteristics")
        // Discover the write + notify chars (gen5 also advertises ...0004/5/6, which v1 discovers but
        // never writes to). RingGen drives which to discover.
        let charUUIDs = OuraGatt.characteristicUUIDs(for: ringGen).map { CBUUID(string: $0) }
        peripheral.discoverCharacteristics(charUUIDs, for: svc)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("Oura: WARNING characteristic discovery failed - \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else {
            log("Oura: characteristics discovered but the list was empty")
            return
        }
        if let wc = chars.first(where: { $0.uuid == Self.writeChar }) {
            writeCharacteristic = wc
            log("Oura: write characteristic found")
        } else {
            log("Oura: write characteristic NOT FOUND - cannot drive the ring")
        }
        let candidateUUIDs: Set<CBUUID> = ringGen.hasExtraNotifyChars
            ? Self.extraNotifyChars.union([Self.notifyChar])
            : [Self.notifyChar]
        let notifyChars = chars.filter { characteristic in
            candidateUUIDs.contains(characteristic.uuid) &&
                (characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate))
        }
        guard !notifyChars.isEmpty else {
            log("Oura: notify characteristic NOT FOUND - cannot read the ring")
            return
        }
        inboundNotifyUUIDs = Set(notifyChars.map(\.uuid))
        pendingNotifyUUIDs = inboundNotifyUUIDs
        enabledNotifyCount = 0
        log("Oura: enabling \(notifyChars.count) inbound notification path(s)")
        for characteristic in notifyChars {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard inboundNotifyUUIDs.contains(characteristic.uuid) else { return }
        pendingNotifyUUIDs.remove(characteristic.uuid)
        if let error = error {
            log("Oura: WARNING enabling notification path FAILED - \(error.localizedDescription)")
        } else if characteristic.isNotifying {
            enabledNotifyCount += 1
        }
        guard pendingNotifyUUIDs.isEmpty else { return }
        guard enabledNotifyCount > 0 else {
            log("Oura: WARNING every notification path failed - ring will send no data")
            return
        }
        log("Oura: notifications enabled on \(enabledNotifyCount) inbound path(s) - beginning auth")
        // Transport subscriptions are live: request the auth nonce directly (or, with no key, drive the
        // honest needs-pairing path).
        advance(.ready)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              let value = characteristic.value,
              inboundNotifyUUIDs.contains(characteristic.uuid) else { return }
        guard let driver else { return }
        let bytes = [UInt8](value)
        // Capture phase before a terminal summary can transition the driver back to `.streaming` in this
        // same notification. TLV records sharing that notification still belong to the history response.
        let tlvOrigin: IngestOrigin = driver.phase == .fetchingHistory ? .history : .live
        // The notify char carries TWO framings on the same channel (OURA_PROTOCOL.md s2):
        //   - 0x2F secure-session sub-frames (auth nonce/status, enable ACKs, live-HR pushes)
        //   - inner TLV event records (IBI / HRV / SpO2 / temp / sleep-phase / battery)
        // Split the notification into outer frames; route 0x2F ones through the driver's secure handler,
        // and feed the remainder to the reassembler as TLV records.
        // Event tags occupy 0x41+ while command/response opcodes are below that range. Once a partial TLV
        // is buffered, every continuation byte belongs to it regardless of its first value. Take this
        // unambiguous path before trying the outer-frame parser.
        if reassembler.bufferedByteCount > 0 || (bytes.first.map { $0 >= 0x41 } ?? false) {
            ingestDriverNotification(bytes, driver: driver, origin: tlvOrigin)
            bumpHistorySummarySettleTimer()
            return
        }
        let frames = OuraFraming.parseOuterFrames(bytes)
        // A TLV record may be split across notifications. If no complete outer-shaped frame exists yet,
        // preserve the raw fragment in the reassembler instead of dropping it. Identity responses fit one
        // minimum-MTU notification (20 bytes), so they still take the explicit route below.
        if frames.isEmpty {
            ingestDriverNotification(bytes, driver: driver, origin: tlvOrigin)
            bumpHistorySummarySettleTimer()
            return
        }
        // Qualification identity reads are deliberately pre-auth and serial-free. Log the exact firmware
        // tuple plus the selected generation so a privacy-redacted test bundle is reproducible; the
        // decoder intentionally discards the response's Bluetooth-address bytes.
        if let frame = frames.first(where: { $0.op == OuraFraming.firmwareResponseOp }) {
            if let identity = OuraDecoders.decodeFirmwareIdentity(frame.body) {
                log("Oura: identity selected=\(ringGen.displayName) firmware=\(identity.firmware) api=\(identity.api) bootloader=\(identity.bootloader) bluetooth=\(identity.bluetooth)")
            } else {
                log("Oura: identity firmware response received but could not be decoded (\(frame.body.count)B)")
            }
            recordNoKeyIdentityResponse(op: frame.op)
        }
        for frame in frames where frame.op == OuraFraming.productInfoResponseOp {
            if pendingEventCategoryResponses > 0, driver.phase == .fetchingHistory {
                pendingEventCategoryResponses -= 1
                acknowledgedEventCategoryResponses += 1
                if acknowledgedEventCategoryResponses == OuraCommands.ring4EventCategorySubscriptions().count {
                    log("Oura: event-category subscriptions acknowledged")
                }
            } else if let hardware = OuraDecoders.decodeProductHardware(frame.body) {
                log("Oura: identity hardware=\(hardware)")
            } else {
                log("Oura: identity hardware response received but no privacy-safe family token was found (\(frame.body.count)B)")
            }
            recordNoKeyIdentityResponse(op: frame.op)
        }
        // The `0x25` SetAuthKey-response is an OUTER frame (NOT a 0x2F secure sub-frame): `25 01 <status>`,
        // status `0x00` = OK (OURA_PROTOCOL.md s3.2). It only ever arrives during an adopt install we
        // initiated, so handle it ONLY while a key install is pending; otherwise it is ignored (never fed to
        // the TLV decoder, where its op byte would be misread as a record type). Per OURA_PROTOCOL.md s3.2.
        if pendingInstallKey != nil,
           let ackFrame = frames.first(where: { $0.op == Self.setAuthKeyRespOp }) {
            handleKeyInstallAck(status: ackFrame.body.first ?? 0xFF)
            return
        }
        // The `0x11` GetEvents summary drives the history-fetch cursor loop (s5.2/5.3). It is an outer
        // response and is consumed here; only frames whose op is in the 0x41+ event-tag range are ever
        // passed to the TLV reassembler below.
        // Cursor handling is deferred until the 0x41+ records packed into this notification have been
        // decoded and buffered. Persisting the cursor is the batch's final commit operation.
        let historySummary = frames.first(where: { $0.op == OuraFraming.getEventsResponseOp })
            .flatMap { OuraFraming.parseGetEventsResponse($0.body) }
        // Ring 4's `0x13` is only an ACK plus the echoed coarse time counter. Explicitly consume it so it
        // can never enter TLV reassembly; the following inner `0x42` event is the actual UTC anchor.
        if let syncFrame = frames.first(where: { $0.op == OuraFraming.syncTimeResponseOp }),
           driver.handleSyncTimeAcknowledgement(body: syncFrame.body) {
            cancelTimeSyncReleaseFallback()
            log("Oura: time sync acknowledged")
            advance(.timeSyncAcknowledged(cursor: historyCursor))
        } else if frames.contains(where: { $0.op == OuraFraming.syncTimeResponseOp }) {
            log("Oura: time sync response echo did not match the active request - guarded fallback remains armed")
        }
        // The `0x0D` GetBattery response is ALSO an outer frame (never a TLV record, s6.10), detected the
        // same non-destructive way as the 0x11 summary: its op is below the event-tag range (>= 0x41), so
        // it round-trips safely through the TLV decoder as an "unknown tag" no-op if left unfiltered. Routed
        // through the existing `.battery` ingest path (batteryPct/onBattery/log side effects).
        if let batteryFrame = frames.first(where: { $0.op == OuraFraming.batteryResponseOp }),
           let battery = OuraDecoders.decodeBattery(batteryFrame.body) {
            ingest([.battery(battery)], origin: .live)
        }
        if frames.contains(where: { $0.op == OuraFraming.secureSessionOp }) {
            for frame in frames where frame.op == OuraFraming.secureSessionOp {
                guard let secure = OuraFraming.parseSecureFrame(frame) else { continue }
                handleSecure(driver.handleSecureFrame(secure))
            }
            // Any non-secure outer frames in the same notification are TLV records; fall through to decode.
            // The 0x25 ack (if any) is consumed above, so it never reaches here.
            let tlvBytes = frames.filter { $0.op >= 0x41 }
                                 .flatMap { [$0.op, UInt8($0.body.count)] + $0.body }
            if !tlvBytes.isEmpty {
                ingestDriverNotification(tlvBytes, driver: driver, origin: tlvOrigin)
                bumpHistorySummarySettleTimer()
            }
            if let historySummary { scheduleHistorySummary(historySummary) }
            return
        }
        // No secure frame: outer responses are consumed above; only 0x41+ event tags reach TLV parsing.
        let tlvBytes = frames.filter { $0.op >= 0x41 }
            .flatMap { [$0.op, UInt8($0.body.count)] + $0.body }
        if !tlvBytes.isEmpty {
            ingestDriverNotification(tlvBytes, driver: driver, origin: tlvOrigin)
            bumpHistorySummarySettleTimer()
        }
        if let historySummary { scheduleHistorySummary(historySummary) }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drainCommandQueue()
    }

    /// Act on what the driver resolved a 0x2F secure sub-frame to.
    private func handleSecure(_ routing: OuraDriver.SecureRouting) {
        switch routing {
        case .nonce(let nonce):
            log("Oura: auth nonce received - submitting proof")
            advance(.nonceReceived(nonce))
        case .authStatus(let status):
            if status.isSuccess {
                log("Oura: auth OK - enabling live HR")
            } else {
                log("Oura: WARNING auth status \(status.rawValue)")
            }
            advance(.authCompleted(status))
        case .enableAck:
            advance(.enableAckReceived)
        case .featureStatus(let status):
            if let enabled = status.isSpO2Automatic {
                spo2AutomaticEnabled = enabled
                log("Oura: automatic SpO2 measurement is \(enabled ? "on" : "off")")
            }
        case .liveHRPush(let body):
            guard let driver else { return }
            ingest(driver.ingestLiveHRPush(body: body), origin: .live)
        case .unhandled:
            break
        }
    }
}

// MARK: - Oura install-key Keychain accessor

private let ouraInstallKeyService = "com.noop.oura.installkey"
private let ouraKeychainReadQueue = DispatchQueue(label: "com.noop.oura.keychain-read",
                                                   qos: .userInitiated)

/// A Keychain IPC can ignore cancellation while macOS waits on an item's access policy. This one-shot
/// lock lets either the result or the main-actor timeout win without double-calling the source builder.
private final class OuraKeyReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Keychain Services wrapper for the per-ring 16-byte Oura application install key. Mirrors the
/// `AIKeyStore` generic-password pattern (`Strand/AI/AICoach.swift`) so the key never lands in
/// UserDefaults, a plist, or on disk in the clear. The key is scoped per `deviceId` (the `account`), so
/// each registered ring has its own item. The install key is written here from exactly two places: the
/// adopt key-install handshake (on an OK `0x25` ack, `OuraLiveSource.handleKeyInstallAck`) and the wizard's
/// Advanced "I already have my ring's key" path. This accessor only stores/reads/clears it.
@MainActor
public enum OuraKeyStore {
    /// The fixed key length per OURA_PROTOCOL.md s3 (16-byte application auth key).
    public static let keyLength = 16
    /// Process-lifetime fallback for a key Keychain has already returned successfully. This is not
    /// durable storage; it only prevents a transient reconnect-time Keychain failure from discarding an
    /// already-proven secret. The only durable copy remains in Keychain.
    private static var memoryCache: [String: Data] = [:]
    /// Privacy-safe diagnostic only: OSStatus from the latest Keychain read (never the key/account).
    public private(set) static var lastReadStatus: OSStatus = errSecSuccess

    private static func baseQuery(deviceId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ouraInstallKeyService,
            kSecAttrAccount as String: deviceId,
        ]
    }

    /// Store (or replace) the 16-byte install key for `deviceId`. A wrong-length key is rejected (no
    /// partial key is ever stored, so a later read can't return a malformed key).
    @discardableResult
    public static func save(_ key: Data, deviceId: String) -> Bool {
        guard key.count == keyLength else { return false }
        var query = baseQuery(deviceId: deviceId)
        // Keychain authorization UI can synchronously block the main actor. Normal app access succeeds
        // without UI; a changed/unauthorized local build fails promptly and gets honest recovery copy.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         [kSecValueData as String: key] as CFDictionary)
        let status: OSStatus
        if updateStatus == errSecItemNotFound {
            var attrs = query
            // This is a new generic-password item, so there is no existing ACL to authorize. Keep the
            // query-only authentication control out of the add attributes.
            attrs.removeValue(forKey: kSecUseAuthenticationContext as String)
            attrs[kSecValueData as String] = key
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(attrs as CFDictionary, nil)
        } else {
            status = updateStatus
        }
        guard status == errSecSuccess else { return false }
        memoryCache[deviceId] = key
        return true
    }

    /// Read the stored key without ever blocking the main actor. Security.framework can wait indefinitely
    /// when a development build's signature no longer satisfies an existing item's access policy, even
    /// with interaction disabled. The serial worker contains that IPC; after `timeout` the app proceeds
    /// with an honest Keychain-unavailable state. Only one callback can win.
    public static func readWithTimeout(deviceId: String,
                                       timeout: TimeInterval = 2,
                                       completion: @MainActor @escaping (Data?, OSStatus) -> Void) {
        if let cached = memoryCache[deviceId], cached.count == keyLength {
            lastReadStatus = errSecSuccess
            completion(cached, errSecSuccess)
            return
        }

        let gate = OuraKeyReadGate()
        ouraKeychainReadQueue.async {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: ouraInstallKeyService,
                kSecAttrAccount as String: deviceId,
                kSecReturnData as String: kCFBooleanTrue as Any,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            var item: CFTypeRef?
            var status = SecItemCopyMatching(query as CFDictionary, &item)
            var data = item as? Data
            if status == errSecSuccess, data?.count != keyLength {
                status = errSecDecode
                data = nil
            }
            let shouldComplete = gate.claim()
            let resultStatus = status
            let resultData = data
            Task { @MainActor in
                // If Security finally answers after the UI timeout, retain a valid result so the next
                // reconnect succeeds without another IPC wait; the timed-out source is not mutated.
                if resultStatus == errSecSuccess, let resultData {
                    memoryCache[deviceId] = resultData
                }
                guard shouldComplete else { return }
                lastReadStatus = resultStatus
                completion(resultData, resultStatus)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, timeout)) {
            guard gate.claim() else { return }
            lastReadStatus = errSecInteractionNotAllowed
            completion(nil, errSecInteractionNotAllowed)
        }
    }

    /// Remove the stored install key for `deviceId`.
    public static func clear(deviceId: String) {
        memoryCache.removeValue(forKey: deviceId)
        SecItemDelete(baseQuery(deviceId: deviceId) as CFDictionary)
    }
}

// MARK: - Oura history sync-state persistence

/// Versioned, atomic cursor + durable-anchor state. Keeping the pair in one encoded UserDefaults value
/// prevents a crash between two scalar writes from producing a cursor that no longer matches its UTC
/// mapping. The old scalar cursor key is read only for one-way migration; no anchor is ever invented.
struct OuraHistorySyncState: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let cursor: UInt32
    let anchor: OuraTimeAnchor?
    let savedAtUnixSeconds: Int64

    init(cursor: UInt32, anchor: OuraTimeAnchor?, savedAtUnixSeconds: Int64) {
        version = Self.currentVersion
        self.cursor = cursor
        self.anchor = anchor
        self.savedAtUnixSeconds = savedAtUnixSeconds
    }
}

enum OuraHistorySyncStore {
    private static func key(deviceId: String) -> String { "com.noop.oura.historySyncState.v1.\(deviceId)" }
    private static func legacyCursorKey(deviceId: String) -> String { "com.noop.oura.historyCursor.\(deviceId)" }
    private static let earliestSavedAt: Int64 = 1_577_836_800 // 2020-01-01
    private static let futureClockSkew: Int64 = 24 * 60 * 60

    static func read(deviceId: String, now: Date = Date()) -> OuraHistorySyncState {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key(deviceId: deviceId)),
           let decoded = try? JSONDecoder().decode(OuraHistorySyncState.self, from: data),
           decoded.version == OuraHistorySyncState.currentVersion {
            let nowSeconds = Int64(now.timeIntervalSince1970)
            let savedAtIsPlausible = decoded.savedAtUnixSeconds >= earliestSavedAt
                && decoded.savedAtUnixSeconds <= nowSeconds + futureClockSkew
            let validAnchor = savedAtIsPlausible
                ? decoded.anchor.flatMap { OuraDriver.isValidTimeAnchor($0) ? $0 : nil }
                : nil
            return OuraHistorySyncState(cursor: decoded.cursor,
                                        anchor: validAnchor,
                                        savedAtUnixSeconds: decoded.savedAtUnixSeconds)
        }

        let legacyRaw = defaults.object(forKey: legacyCursorKey(deviceId: deviceId)) as? Int ?? 0
        let migrated = OuraHistorySyncState(cursor: UInt32(clamping: legacyRaw),
                                            anchor: nil,
                                            savedAtUnixSeconds: Int64(now.timeIntervalSince1970))
        save(migrated, deviceId: deviceId)
        return migrated
    }

    static func save(cursor: UInt32, anchor: OuraTimeAnchor?, deviceId: String, now: Date = Date()) {
        let validatedAnchor = anchor.flatMap { OuraDriver.isValidTimeAnchor($0) ? $0 : nil }
        save(OuraHistorySyncState(cursor: cursor,
                                  anchor: validatedAnchor,
                                  savedAtUnixSeconds: Int64(now.timeIntervalSince1970)),
             deviceId: deviceId)
    }

    private static func save(_ state: OuraHistorySyncState, deviceId: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key(deviceId: deviceId))
    }
}

// MARK: - Passive Oura history qualification capture

/// Opt-in local capture for mapping Oura history records that the production decoder does not yet
/// understand. Only TLV bytes already delivered during a GetEvents fetch reach this recorder; live secure
/// frames, device identifiers, the install key, and outgoing commands never do. The JSON shape is the
/// input accepted by the package's `oura-decode` CLI.
@MainActor
final class OuraHistoryCaptureRecorder {
    static let enabledKey = "noopOuraHistoryCapture"

    private struct Record: Encodable {
        let hex: String
        let kind: String
        let tsMs: Int

        enum CodingKeys: String, CodingKey {
            case hex, kind
            case tsMs = "ts_ms"
        }
    }

    private static let maximumRecords = 100_000
    /// Hex encoding roughly doubles the raw byte count; cap raw input so one JSON capture remains small.
    private static let maximumCapturedBytes = 8 * 1024 * 1024
    /// Bound total retained qualification data just like the existing WHOOP raw recorder.
    private static let directorySoftCapBytes = 50 * 1024 * 1024
    private var records: [Record] = []
    private var capturedBytes = 0
    private var fileURL: URL?
    private var dirty = false

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func capture(_ bytes: [UInt8]) {
        guard enabled, !bytes.isEmpty, records.count < Self.maximumRecords,
              capturedBytes + bytes.count <= Self.maximumCapturedBytes else { return }
        records.append(Record(
            hex: bytes.map { String(format: "%02x", $0) }.joined(),
            kind: "history_tlv",
            tsMs: Int(Date().timeIntervalSince1970 * 1_000)
        ))
        capturedBytes += bytes.count
        dirty = true
    }

    func flush() {
        // Preserve bytes already captured even if the opt-in was switched off before disconnect.
        guard dirty, !records.isEmpty else { return }
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(records)
            let url = try sessionFileURL()
            try data.write(to: url, options: .atomic)
            dirty = false
            Self.evictOldCaptures(keeping: url)
        } catch {
            // Qualification-only and best-effort: the normal decode/persistence path remains unchanged.
        }
    }

    private func sessionFileURL() throws -> URL {
        if let fileURL { return fileURL }
        let directory = try Self.captureDirectory()
        let stamp = Self.fileStampFormatter.string(from: Date())
        let url = directory.appendingPathComponent("oura-history-\(stamp).json")
        fileURL = url
        return url
    }

    private static func captureDirectory() throws -> URL {
        let fm = FileManager.default
        let directory = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
            .appendingPathComponent("oura-captures", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Delete oldest completed captures until the directory is back below its soft cap. Never delete
    /// the file this recorder is actively rewriting.
    private static func evictOldCaptures(keeping keep: URL) {
        let fm = FileManager.default
        guard let directory = try? captureDirectory(),
              let entries = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]) else { return }
        let files = entries
            .filter { $0.pathExtension == "json" }
            .map { (url: $0, size: (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files {
            guard total > directorySoftCapBytes else { break }
            if file.url == keep { continue }
            if (try? fm.removeItem(at: file.url)) != nil { total -= file.size }
        }
    }

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
