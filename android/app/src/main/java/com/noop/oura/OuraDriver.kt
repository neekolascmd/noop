package com.noop.oura

// OuraDriver: the transport-agnostic protocol state machine. Kotlin twin of OuraDriver.swift. It holds
// NO BLE handle: the app's live source owns the BluetoothGatt / CBCentralManager and feeds the driver
// only bytes + transition events. This is what makes the protocol headless-testable (no
// android.bluetooth, no CoreBluetooth anywhere in this package).
//
// Two entry points:
//   - nextStep(after:) -> List<OuraCommand>   : given the last transition, return the commands to write.
//   - ingest(record:) -> List<OuraEvent>      : given a parsed TLV record, return decoded events.
//   - ingestLiveHRPush(body:) -> List<OuraEvent> : given a 0x2F sub-op 0x28 push body, return live HR.
//
// The flow mirrors OURA_PROTOCOL.md s3 (auth) + s5 (live HR / fetch): scan -> connect -> notify ->
// auth (nonce, proof) -> enable live HR (gen-appropriate triplet) -> stream. RingGen swaps the
// command set, not the code path.
//
// Tier discipline: Tier-B decoders are present but gated behind `allowTierB` (default false). When
// false, a Tier-B tag decodes to nothing (the event is dropped), so Tier-B values can never feed
// scoring silently. Per the brief's TIER DISCIPLINE and OURA_PROTOCOL.md s7.3.

/**
 * A transport-level transition the app reports to the driver to advance the flow. The driver answers
 * with the next batch of commands. This keeps all BLE specifics (peripheral, GATT callbacks) in the
 * app and all protocol specifics here. Kotlin twin of Swift's OuraTransition enum.
 */
sealed class OuraTransition {
    /** Service + characteristics discovered and notifications enabled on ...0003. Begin auth. */
    object Ready : OuraTransition()

    /** A 15-byte nonce arrived (from the GetAuthNonce response). Compute + submit the proof. */
    data class NonceReceived(val nonce: IntArray) : OuraTransition() {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is NonceReceived) return false
            return nonce.contentEquals(other.nonce)
        }
        override fun hashCode(): Int = nonce.contentHashCode()
    }

    /** The auth handshake completed with this status. On success, begin enabling live HR. */
    data class AuthCompleted(val status: OuraAuthStatus) : OuraTransition()

    /** A live-HR enable/subscribe ACK arrived; advance the triplet (or, when done, mark streaming). */
    object EnableAckReceived : OuraTransition()

    /** The app wants to sync the ring clock, then fetch buffered history from this cursor. */
    data class StartHistoryFetch(val cursor: Long, val unixSeconds: Long) : OuraTransition()

    /** Ring 4 acknowledged SyncTime; release Flush + GetEvents only after that correlation point. */
    data class TimeSyncAcknowledged(val cursor: Long) : OuraTransition()

    /** Guarded release; a correlated 0x42 or qualified recent 0x85 still gates cursor commit. */
    data class TimeSyncReleaseTimedOut(val cursor: Long) : OuraTransition()

    /** Read the next provisional page without ACK/flush while retaining active SyncTime correlation. */
    data class ContinueProvisionalHistory(val cursor: Long) : OuraTransition()

    /** Refetch skipped pages from the durable cursor after a bounded scan finds a real 0x42 anchor. */
    data class RestartHistoryFromBootstrap(val cursor: Long) : OuraTransition()

    /** The last GetEvents response advanced the cursor to this value; continue or stop. */
    data class HistoryCursorAdvanced(val cursor: Long, val moreData: Boolean) : OuraTransition()
}

/**
 * The driver's coarse phase, exposed for the app and tests to assert on. Kotlin twin of Swift's
 * OuraDriverPhase enum.
 */
sealed class OuraDriverPhase {
    object Idle : OuraDriverPhase()
    object Authenticating : OuraDriverPhase()
    object EnablingLiveHR : OuraDriverPhase()
    object Streaming : OuraDriverPhase()
    object FetchingHistory : OuraDriverPhase()

    /** Ring is in factory reset; honest pairing path (s3.5 status 0x02). */
    object NeedsKeyInstall : OuraDriverPhase()

    /** Post-factory-reset key install in flight (s3.2); awaiting the 0x25 ack. */
    object InstallingKey : OuraDriverPhase()

    data class AuthFailed(val status: OuraAuthStatus) : OuraDriverPhase()
    object Stopped : OuraDriverPhase()
}

class OuraDriver(
    val ringGen: OuraRingGen,
    /**
     * The 16-byte application auth key (injected, never hardcoded). null drives the honest
     * needs-pairing path (the app surfaces "needsPairing" instead of faking data).
     */
    private val authKey: IntArray?,
    /** When false (default), Tier-B (UNVERIFIED) tags decode to nothing so they can never feed scoring. */
    val allowTierB: Boolean = false,
    /**
     * When false (default), the driver MUST NOT sequence a post-factory-reset key install: it stays at
     * NeedsKeyInstall and writes nothing dangerous. Only an explicit opt-in adopt flow sets this true.
     * Per OURA_PROTOCOL.md s3.2 (the 0x24 SetAuthKey is a DANGEROUS, one-time provisioning write).
     */
    val allowKeyInstall: Boolean = false,
    /** Deterministic token injection for replay/tests; production uses a fresh random byte. */
    private val timeSyncToken: Int? = null,
    /**
     * Last validated durable time anchor stored with the cursor. It is useful for timestamp
     * interpolation immediately after reconnect, but does not by itself authorize a history ACK.
     */
    persistedPrimaryAnchor: OuraTimeAnchor? = null,
    /** Cursor stored atomically beside [persistedPrimaryAnchor]. */
    durableCursor: Long = 0L,
) {
    var phase: OuraDriverPhase = OuraDriverPhase.Idle
        private set

    /** Tracks how many of the live-HR enable triplet ACKs have been seen. */
    private var liveHREnableStep = 0

    /**
     * The most recent ring time seen on any record, used to stamp live-HR pushes (which are not TLV
     * records and carry no timestamp of their own).
     */
    private var lastRingTimestamp: Long = 0

    /**
     * Ring-time -> UTC anchor (OURA_PROTOCOL.md s5.5): the ring's clock ticks at 100 ms/tick by default
     * and 1 ms/tick when Ring 4's 0x42 token is 0xFD. Set from the ring's own 0x42 time-sync event
     * (primary) or, only while no 0x42 has arrived yet THIS session, the coarser 1s-granularity 0x85 RTC
     * beacon (secondary). A validated durable anchor may be seeded from per-ring state after a
     * reconnect. The seed permits interpolation, but a Ring 4 fetch remains provisional until monotonic
     * history proves continuity with both the durable cursor and the anchor.
     */
    private var anchorUtcMs: Long? = null
    private var anchorRingTime: Long? = null
    /** Generation/token-specific ring-clock scale selected by the primary 0x42 anchor. */
    private var anchorFactorMs: Long = 100L
    /** Durable mapping: a correlated 0x42, or a recent active-fetch 0x85 fallback when firmware omits it. */
    private var primaryTimeAnchor: OuraTimeAnchor? = if (ringGen == OuraRingGen.GEN4) {
        validateTimeAnchor(persistedPrimaryAnchor)
    } else {
        null
    }
    /** Cursor whose continuity the first seeded-anchor fetch must prove before it may ACK. */
    private var activeFetchDurableCursor: Long = durableCursor.takeIf { it in 0L..MAX_RING_TIMESTAMP } ?: 0L
    /** True while the active fetch is qualifying a carried-over primary mapping. */
    private var seededAnchorNeedsContinuity = primaryTimeAnchor != null
    /** One-shot signal for the transport to clear the coherent cursor+anchor store. */
    private var persistentStateInvalidated = false
    /** Counter from the active Ring 4 SyncTime request; used to reject stale backlog 0x42 anchors. */
    private var pendingSyncCounter: Long? = null
    /** Random request token; the fetched 0x42 must match it as well as the counter. */
    private var pendingSyncToken: Int? = null
    /**
     * Cursor commit authority is separate from timestamp mapping. A correlated 0x42 or qualified 0x85
     * grants it immediately; a persisted anchor needs monotonic history continuity.
     */
    private var activeFetchHasFreshAnchor = false
    /** Duplicate/late 0x13 responses must not enqueue duplicate flush/fetch writes. */
    private var timeSyncReleaseIssued = false
    /** Allows a plausible backlog 0x42 only during the transport's bounded bootstrap scan. */
    private var historicalAnchorBootstrapEnabled = false
    /** Ring 4 category masks are configured once per driver/BLE session, not each periodic fetch. */
    private var ring4HistoryCategoriesConfigured = false
    /** Max ring timestamp across every structurally-valid inner record in the active history batch. */
    var activeHistoryHighWater: Long? = null
        private set

    /**
     * The freshly-provisioned key the transport generated during an adopt flow (s3.2). Once set by
     * beginKeyInstall it becomes the effective key for the post-install re-auth. null otherwise.
     */
    private var installedKey: IntArray? = null

    init {
        primaryTimeAnchor?.let {
            anchorUtcMs = it.utcMilliseconds
            anchorRingTime = it.ringTimestamp
            anchorFactorMs = it.factorMillisecondsPerTick
        }
    }

    /**
     * The key the auth handshake should use: the freshly-installed key takes precedence over the
     * injected one (so re-auth after a key install uses the new key). Per OURA_PROTOCOL.md s3.2.
     */
    private val effectiveKey: IntArray?
        get() = installedKey ?: authKey

    // MARK: - Command flow

    /**
     * Given the last transport transition, return the commands the app should write next. Pure: it
     * only mutates the driver's own phase, never touches BLE. Per OURA_PROTOCOL.md s3 / s5.
     */
    fun nextStep(after: OuraTransition): List<OuraCommand> = when (after) {
        is OuraTransition.Ready -> {
            // Capture a reproducible firmware/hardware tuple on every connection. These safe pre-auth
            // reads omit the serial page, so a redacted strap log can qualify hardware without exposing
            // a persistent identifier (OURA_PROTOCOL.md s3.6/s4.3).
            val identity = listOf(OuraCommands.getFirmwareVersion(), OuraCommands.getProductHardware())
            // No app key -> we cannot authenticate; surface the honest pairing path (no faked data).
            if (effectiveKey == null) {
                phase = OuraDriverPhase.NeedsKeyInstall
                identity
            } else {
                phase = OuraDriverPhase.Authenticating
                if (ringGen == OuraRingGen.GEN4) {
                    identity + OuraCommands.ring4PreAuthSessionReads() +
                        OuraCommand("get_nonce", OuraAuth.getAuthNonceCommand())
                } else {
                    listOf(OuraCommand("get_nonce", OuraAuth.getAuthNonceCommand())) + identity
                }
            }
        }

        is OuraTransition.NonceReceived -> {
            val key = effectiveKey
            if (key == null) {
                phase = OuraDriverPhase.NeedsKeyInstall
                emptyList()
            } else {
                // Compute the proof and submit it. On any crypto error, fail honestly (no proof sent).
                val cmd = try {
                    OuraAuth.authenticateCommand(after.nonce, key)
                } catch (e: Exception) {
                    null
                }
                if (cmd == null) {
                    phase = OuraDriverPhase.AuthFailed(OuraAuthStatus.AUTH_ERROR)
                    emptyList()
                } else {
                    listOf(OuraCommand("submit_proof", cmd))
                }
            }
        }

        is OuraTransition.AuthCompleted -> when (after.status) {
            OuraAuthStatus.SUCCESS -> {
                phase = OuraDriverPhase.EnablingLiveHR
                liveHREnableStep = 0
                // The transport already enabled the inbound CCCDs; begin live HR directly. Ring 4
                // firmware 2.12.3 stalls the following control write when `notify_all` is sent here.
                listOf(OuraCommands.liveHREnableSequence()[0])
            }
            OuraAuthStatus.IN_FACTORY_RESET -> {
                // Ring needs a key install first; this is an explicit, named provisioning step the app
                // drives, not the normal flow. Surface honestly.
                phase = OuraDriverPhase.NeedsKeyInstall
                emptyList()
            }
            OuraAuthStatus.AUTH_ERROR, OuraAuthStatus.NOT_ORIGINAL_DEVICE -> {
                phase = OuraDriverPhase.AuthFailed(after.status)
                emptyList()
            }
        }

        is OuraTransition.EnableAckReceived -> {
            if (phase != OuraDriverPhase.EnablingLiveHR) {
                emptyList()
            } else {
                liveHREnableStep += 1
                val seq = OuraCommands.liveHREnableSequence()
                if (liveHREnableStep < seq.size) {
                    listOf(seq[liveHREnableStep])
                } else {
                    // All three ACKed: HR/IBI now streams as 0x2F sub-op 0x28 pushes.
                    phase = OuraDriverPhase.Streaming
                    emptyList()
                }
            }
        }

        is OuraTransition.StartHistoryFetch -> {
            phase = OuraDriverPhase.FetchingHistory
            activeHistoryHighWater = null
            activeFetchHasFreshAnchor = false
            activeFetchDurableCursor = after.cursor.takeIf { it in 0L..MAX_RING_TIMESTAMP } ?: 0L
            seededAnchorNeedsContinuity = primaryTimeAnchor != null
            // A new active SyncTime correlation supersedes any prior bounded backlog-bootstrap mode.
            historicalAnchorBootstrapEnabled = false
            timeSyncReleaseIssued = false
            if (ringGen == OuraRingGen.GEN4 && after.unixSeconds >= 0L) {
                val sync = if (timeSyncToken == null) OuraCommands.syncTime(after.unixSeconds)
                else OuraCommands.syncTime(after.unixSeconds, token = timeSyncToken)
                pendingSyncCounter = (after.unixSeconds / 256L) and 0x00FF_FFFFL
                pendingSyncToken = sync.bytes[2] and 0xFF
                // Enable the Ring 4 event stream, then gate data-plane writes on its correlated 0x13.
                // Back-to-back
                // SyncTime/Flush/GetEvents writes race on real hardware and can deliver history before
                // the fresh 0x42 anchor exists.
                buildList {
                    add(OuraCommands.enableEventStream())
                    add(sync)
                    if (!ring4HistoryCategoriesConfigured) {
                        add(OuraCommands.ring4PostSyncStatePulse())
                        addAll(OuraCommands.ring4EventCategorySubscriptions())
                        add(OuraCommands.getBattery())
                        val parameterReads = OuraCommands.ring4HistoryParameterReads()
                        addAll(parameterReads.take(2))
                        add(OuraCommands.ring4HistorySessionMode())
                        addAll(parameterReads.drop(2))
                        ring4HistoryCategoriesConfigured = true
                    }
                }
            } else {
                // Gen 3 retains its legacy sequence until its response layout is hardware-qualified.
                listOf(
                    OuraCommands.syncTime(after.unixSeconds),
                    OuraCommands.flushBuffer(),
                    OuraCommands.getEvents(cursor = after.cursor, maxEvents = 255),
                )
            }
        }

        is OuraTransition.TimeSyncAcknowledged,
        is OuraTransition.TimeSyncReleaseTimedOut -> {
            val cursor = when (after) {
                is OuraTransition.TimeSyncAcknowledged -> after.cursor
                is OuraTransition.TimeSyncReleaseTimedOut -> after.cursor
                else -> error("unreachable")
            }
            if (ringGen != OuraRingGen.GEN4 || phase != OuraDriverPhase.FetchingHistory ||
                pendingSyncCounter == null || timeSyncReleaseIssued) {
                emptyList()
            } else {
                timeSyncReleaseIssued = true
                listOf(
                OuraCommands.flushBuffer(),
                OuraCommands.getEvents(cursor = cursor, maxEvents = 255),
                )
            }
        }

        is OuraTransition.ContinueProvisionalHistory -> {
            if (ringGen != OuraRingGen.GEN4 || phase != OuraDriverPhase.FetchingHistory ||
                hasFreshAnchorForActiveFetch) {
                emptyList()
            } else {
                // Read-only look-ahead: never ACK (max=0), flush, or reset active SyncTime correlation.
                listOf(OuraCommands.getEvents(cursor = after.cursor, maxEvents = 255))
            }
        }

        is OuraTransition.RestartHistoryFromBootstrap -> {
            if (ringGen != OuraRingGen.GEN4 || phase != OuraDriverPhase.FetchingHistory || !hasUtcAnchor) {
                emptyList()
            } else {
                historicalAnchorBootstrapEnabled = false
                activeHistoryHighWater = null
                activeFetchHasFreshAnchor = true
                pendingSyncCounter = null
                pendingSyncToken = null
                timeSyncReleaseIssued = true
                listOf(
                    OuraCommands.flushBuffer(),
                    OuraCommands.getEvents(cursor = after.cursor, maxEvents = 255),
                )
            }
        }

        is OuraTransition.HistoryCursorAdvanced -> {
            if (!after.moreData) {
                phase = OuraDriverPhase.Streaming
                pendingSyncCounter = null
                pendingSyncToken = null
                activeFetchHasFreshAnchor = false
                timeSyncReleaseIssued = false
                activeHistoryHighWater = null
                emptyList()
            } else {
                // Ack-fetch (max=0) at the new cursor advances without re-pulling data (s5.3 step 4).
                listOf(OuraCommands.getEvents(cursor = after.cursor, maxEvents = 0))
            }
        }
    }

    /**
     * Re-engage live HR (daytime-HR auto-reverts after ~20 s; the app calls this every ~15 s while a
     * live session is open). Per OURA_PROTOCOL.md s5.7. Returns the enable+subscribe commands.
     */
    fun reengageLiveHRCommands(): List<OuraCommand> =
        listOf(OuraCommands.liveHREnable(), OuraCommands.liveHRSubscribe())

    // MARK: - Post-factory-reset key install (adopt flow, s3.2)

    /**
     * Begin the one-time post-factory-reset key install (OURA_PROTOCOL.md s3.2). The transport in the
     * adopt flow generates a fresh 16-byte key, persists it, and calls this to obtain the dangerous
     * `24 10 <key>` write; once the ring replies `25 01 00` the transport calls keyInstallAcknowledged
     * to drive re-auth.
     *
     * SAFETY GATE: this only sequences an install when phase == NeedsKeyInstall AND allowKeyInstall is
     * true. When allowKeyInstall is false it stays at NeedsKeyInstall and returns null, so the
     * dangerous 0x24 write is never emitted outside an explicit opt-in adopt flow. Returns null (and
     * leaves phase unchanged) when not gated on, the key length is wrong, or the command cannot build.
     * Kotlin twin of Swift's beginKeyInstall.
     */
    fun beginKeyInstall(key: IntArray): OuraCommand? {
        if (!allowKeyInstall || phase != OuraDriverPhase.NeedsKeyInstall) return null
        val cmd = try {
            OuraDangerousCommands.installKey(key)
        } catch (e: Exception) {
            null
        } ?: return null
        installedKey = key                 // re-auth after the ack must use the freshly-provisioned key
        phase = OuraDriverPhase.InstallingKey
        return cmd
    }

    /**
     * Handle the ring's 0x25 SetAuthKey ack (`25 01 00`, s3.2) by driving re-auth with the freshly
     * installed key: transition InstallingKey -> Authenticating and request the nonce first. Returns []
     * (phase unchanged) when not in InstallingKey or when no
     * installed key is present, so a stray ack cannot advance the flow. Kotlin twin of Swift's
     * keyInstallAcknowledged.
     */
    fun keyInstallAcknowledged(): List<OuraCommand> {
        if (phase != OuraDriverPhase.InstallingKey || installedKey == null) return emptyList()
        phase = OuraDriverPhase.Authenticating
        return listOf(OuraCommand("get_nonce", OuraAuth.getAuthNonceCommand()))
    }

    /** Stop: reset the flow so a fresh session re-runs auth (the app key is session-scoped, s3.1). */
    fun stop() {
        phase = OuraDriverPhase.Stopped
        liveHREnableStep = 0
        lastRingTimestamp = 0
        installedKey = null
        // A stale anchor must not survive stop()/a new session - the ring may have rebooted (s5.5).
        anchorUtcMs = null
        anchorRingTime = null
        anchorFactorMs = 100L
        primaryTimeAnchor = null
        pendingSyncCounter = null
        pendingSyncToken = null
        activeFetchHasFreshAnchor = false
        seededAnchorNeedsContinuity = false
        timeSyncReleaseIssued = false
        historicalAnchorBootstrapEnabled = false
        activeHistoryHighWater = null
    }

    // MARK: - Ring-time -> UTC anchor (s5.5)

    /**
     * Accept any well-formed Ring 4 0x13 while a SyncTime request is active. This is liveness only;
     * an independently-qualified 0x42/0x85 remains mandatory for anchor/cursor commit.
     */
    fun handleSyncTimeAcknowledgement(body: IntArray): Boolean {
        if (ringGen != OuraRingGen.GEN4) return false
        if (OuraFraming.parseSyncTimeResponse(body) == null) return false
        return pendingSyncCounter != null
    }

    /** Enable bounded backlog-anchor bootstrap; skipped pages must be refetched before commit. */
    fun enableHistoricalAnchorBootstrap() {
        if (ringGen == OuraRingGen.GEN4 && phase == OuraDriverPhase.FetchingHistory) {
            historicalAnchorBootstrapEnabled = true
        }
    }

    /** True while any validated primary or session-only secondary mapping can interpolate ring time. */
    val hasUtcAnchor: Boolean get() = anchorUtcMs != null && anchorRingTime != null

    /** Validated anchor suitable for durable reuse: correlated 0x42 or qualified Ring 4 RTC fallback. */
    val currentPrimaryAnchor: OuraTimeAnchor?
        get() = primaryTimeAnchor.takeIf { ringGen == OuraRingGen.GEN4 }

    /** Strong Ring 4 cursor/ACK gate, intentionally separate from [hasUtcAnchor]. */
    val activeFetchCommitAuthorized: Boolean
        get() = if (ringGen == OuraRingGen.GEN4) {
            phase == OuraDriverPhase.FetchingHistory && activeFetchHasFreshAnchor && hasUtcAnchor
        } else {
            hasUtcAnchor
        }

    /** Strong commit gate for the active Ring 4 fetch; legacy generations retain session-anchor gating. */
    val hasFreshAnchorForActiveFetch: Boolean
        get() = activeFetchCommitAuthorized

    /** Mapping availability only. The transport must still use [activeFetchCommitAuthorized] before commit. */
    val canResolveHistoryTimestamps: Boolean get() = hasUtcAnchor

    /** Consume a reset/regression signal exactly once so the transport can clear its coherent sync state. */
    fun consumePersistentStateInvalidation(): Boolean {
        val invalidated = persistentStateInvalidated
        persistentStateInvalidated = false
        return invalidated
    }

    /**
     * A terminal page whose real record high-water is below the requested durable cursor proves that the
     * ring clock/session regressed. An empty response proves nothing and leaves state intact.
     */
    fun invalidatePersistedStateIfHistoryRegressed(): Boolean {
        val highWater = activeHistoryHighWater ?: return false
        if (ringGen != OuraRingGen.GEN4 || highWater >= activeFetchDurableCursor) return false
        invalidateAnchor(invalidatePersistentState = true)
        return true
    }

    private fun invalidateAnchor(invalidatePersistentState: Boolean = false) {
        anchorUtcMs = null
        anchorRingTime = null
        anchorFactorMs = 100L
        primaryTimeAnchor = null
        pendingSyncCounter = null
        pendingSyncToken = null
        activeFetchHasFreshAnchor = false
        seededAnchorNeedsContinuity = false
        timeSyncReleaseIssued = false
        activeHistoryHighWater = null
        if (invalidatePersistentState) persistentStateInvalidated = true
    }

    /**
     * Convert a record's ring-clock timestamp to unix seconds using the current session's anchor
     * (OURA_PROTOCOL.md s5.5). Returns null when no anchor has arrived yet this session, so the caller
     * can honestly fall back (e.g. to wall-clock arrival time) instead of guessing. Kotlin twin of
     * Swift's `unixSeconds(forRingTimestamp:)`. `rt` is the unsigned 32-bit ring timestamp as a Long.
     */
    fun unixSeconds(forRingTimestamp: Long): Long? {
        val anchorMs = anchorUtcMs ?: return null
        val anchorRt = anchorRingTime ?: return null
        val deltaTicks = forRingTimestamp - anchorRt
        val ms = anchorMs + deltaTicks * anchorFactorMs
        // #968: a corrupt/misaligned ring timestamp (seen on a full cursor=0 history dump) can convert to
        // an implausible epoch. Gate the RESULT to the same 2020-2035 plausible window used for anchoring
        // (was a weak `ms <= 0`), so the caller honestly falls back to arrival time instead of banking a
        // 1970 or far-future sample. Byte-identical to the Swift twin.
        val seconds = ms / 1000
        if (seconds < MIN_PLAUSIBLE_EPOCH_SECONDS || seconds > MAX_PLAUSIBLE_EPOCH_SECONDS) return null
        return seconds
    }

    /**
     * Set the session anchor from a decoded epoch (unix SECONDS on the wire, s6.11) if it is plausible.
     * `preferPrimary` is true for a 0x42 time-sync (always wins) and false for a 0x85 RTC beacon (fills a
     * gap only while no time-sync anchor exists yet). Kotlin twin of the anchor-set logic inlined in the
     * Swift driver's `.timeSync` / `.rtcBeacon` ingest cases.
     */
    private fun setAnchorIfPlausible(
        epochSeconds: Long,
        ringTimestamp: Long,
        preferPrimary: Boolean,
        factorMsPerTick: Int = 100,
    ): Boolean {
        // A secondary (beacon) anchor never displaces an already-set primary (time-sync) anchor.
        if (!preferPrimary && anchorUtcMs != null) return false
        if (ringTimestamp !in 1L..MAX_RING_TIMESTAMP || factorMsPerTick.toLong() !in VALID_FACTORS) return false
        val ms = plausibleAnchorMs(epochSeconds) ?: return false
        anchorUtcMs = ms
        anchorRingTime = ringTimestamp
        anchorFactorMs = factorMsPerTick.toLong()
        if (preferPrimary && ringGen == OuraRingGen.GEN4) {
            primaryTimeAnchor = OuraTimeAnchor(
                ringTimestamp = ringTimestamp,
                utcMilliseconds = ms,
                factorMillisecondsPerTick = factorMsPerTick.toLong(),
            )
            seededAnchorNeedsContinuity = false
        }
        return true
    }

    /**
     * Ring 4 firmware observed in hardware qualification can acknowledge SyncTime yet bank no 0x42.
     * Accept a 0x85 only inside the current fetch, no older than two days and not ahead beyond small
     * clock skew. The cursor floor prevents an older backlog beacon from authorizing a resumed cursor.
     */
    private fun rtcBeaconQualifiesForActiveFetch(beacon: OuraRtcBeacon): Boolean {
        if (ringGen != OuraRingGen.GEN4 || phase != OuraDriverPhase.FetchingHistory) return false
        val counter = pendingSyncCounter ?: return false
        if (beacon.ringTimestamp < activeFetchDurableCursor) return false
        val requestWindowStart = counter * 256L
        return beacon.unixSeconds >= requestWindowStart - RTC_FALLBACK_MAXIMUM_AGE_SECONDS &&
            beacon.unixSeconds <= requestWindowStart + 255L + RTC_FALLBACK_FUTURE_TOLERANCE_SECONDS
    }

    /** Promote a carried-over anchor only after real history spans both the durable cursor and anchor. */
    private fun qualifyPersistedAnchorIfContinuous() {
        if (ringGen != OuraRingGen.GEN4 || phase != OuraDriverPhase.FetchingHistory ||
            !seededAnchorNeedsContinuity) return
        val anchor = primaryTimeAnchor ?: return
        val highWater = activeHistoryHighWater ?: return
        if (highWater >= activeFetchDurableCursor && highWater >= anchor.ringTimestamp &&
            unixSeconds(forRingTimestamp = highWater) != null) {
            activeFetchHasFreshAnchor = true
            seededAnchorNeedsContinuity = false
        }
    }

    /**
     * Bounds-check a decoded epoch (unix seconds) and convert to ms, or null if implausible. Kotlin twin
     * of Swift's `plausibleAnchorMs(fromEpochSeconds:)`. The 2020-2035 gate rejects a corrupt/misaligned
     * 0x42/0x85 value (seen on real hardware: a full cursor=0 history dump hit one deep in the backlog) so
     * it is never trusted as an anchor (honest-data invariant). The gate ALSO bounds the input to the
     * seconds->ms `* 1000` conversion so it can never overflow Long.
     */
    private fun plausibleAnchorMs(epochSeconds: Long): Long? {
        if (epochSeconds < MIN_PLAUSIBLE_EPOCH_SECONDS || epochSeconds > MAX_PLAUSIBLE_EPOCH_SECONDS) return null
        return epochSeconds * 1000   // safe: bounded input, cannot overflow
    }

    // MARK: - Record ingest (decode)

    /**
     * Decode one parsed TLV inner record into zero or more events. A malformed/short record (or an
     * unknown tag) yields []. Tier-B tags yield [] unless allowTierB is set. Per OURA_PROTOCOL.md s6.
     */
    fun ingest(record: OuraRecord): List<OuraEvent> {
        val previousRingTimestamp = lastRingTimestamp
        // Only real inner tag space may mutate ring-time state. Unknown but structurally-valid records
        // still advance the batch high-water used for the durable history ACK.
        if (record.type < 0x41) return emptyList()
        if (record.ringTimestamp !in 1L..MAX_RING_TIMESTAMP) return emptyList()
        if (phase == OuraDriverPhase.FetchingHistory) {
            activeHistoryHighWater = maxOf(activeHistoryHighWater ?: 0L, record.ringTimestamp)
            qualifyPersistedAnchorIfContinuous()
        }
        lastRingTimestamp = record.ringTimestamp
        val tag = OuraEventTag.fromRaw(record.type)
            // Unknown tag: decode to nothing, never a guessed value (honest-data invariant).
            ?: return emptyList()
        // Tier-B gate: when not explicitly allowed, drop the event so it cannot feed scoring.
        if (tag.tier == TrustTier.TIER_B && !allowTierB) {
            return emptyList()
        }
        return when (tag) {
            // --- Tier A: HR / IBI ---
            OuraEventTag.IBI_AMPLITUDE ->
                (OuraDecoders.decodeIBIAmplitude(record) ?: emptyList()).map { OuraEvent.Ibi(it) }
            OuraEventTag.GREEN_IBI_QUALITY ->
                (OuraDecoders.decodeGreenIBIQuality(record) ?: emptyList()).map { OuraEvent.Ibi(it) }
            OuraEventTag.SPO2_IBI_AMPLITUDE ->
                (OuraDecoders.decodeSpO2IBI(record) ?: emptyList()).map { OuraEvent.Ibi(it) }
            OuraEventTag.IBI ->
                // The bare 0x44 IBI tag shares the bit-packed layout family; route through the same decoder.
                (OuraDecoders.decodeIBIAmplitude(record) ?: emptyList()).map { OuraEvent.Ibi(it) }
            OuraEventTag.GREEN_IBI_AMP ->
                (OuraDecoders.decodeIBIAmplitude(record) ?: emptyList()).map { OuraEvent.Ibi(it) }

            // --- Tier A: HRV ---
            OuraEventTag.HRV_RMSSD ->
                (OuraDecoders.decodeHRV(record) ?: emptyList()).map { OuraEvent.Hrv(it) }

            // --- SpO2 (0x8B is diagnostic-only in downstream mapping) ---
            OuraEventTag.SPO2_PER_SAMPLE ->
                (OuraDecoders.decodeSpO2PerSample(record) ?: emptyList()).map { OuraEvent.Spo2(it) }
            OuraEventTag.SPO2_STABLE ->
                OuraDecoders.decodeSpO2Stable(record)?.let { listOf(OuraEvent.Spo2(it)) } ?: emptyList()
            OuraEventTag.SPO2_DC ->
                (OuraDecoders.decodeSpO2DC(record) ?: emptyList()).map { OuraEvent.Spo2(it) }
            OuraEventTag.SPO2_RATIO_PI ->
                OuraDecoders.decodeSpO2RatioPI(record)?.let {
                    listOf(OuraEvent.Spo2Ratio(it, OuraSpO2CalibrationProfile.forRingGeneration(ringGen)))
                } ?: emptyList()

            // --- Tier A: Temperature ---
            OuraEventTag.TEMP ->
                (OuraDecoders.decodeTemp(record) ?: emptyList()).map { OuraEvent.Temp(it) }
            OuraEventTag.TEMP_PERIOD ->
                OuraDecoders.decodeTempPeriod(record)?.let { listOf(OuraEvent.Temp(it)) } ?: emptyList()
            OuraEventTag.SLEEP_TEMP ->
                (OuraDecoders.decodeSleepTemp(record) ?: emptyList()).map { OuraEvent.Temp(it) }

            // --- Tier A: Motion ---
            OuraEventTag.MOTION_PERIOD ->
                (OuraDecoders.decodeMotionPeriod(record) ?: emptyList()).map { OuraEvent.MotionEvent(it) }
            OuraEventTag.MOTION ->
                // 0x47 motion_events: surfaced as state-free motion is out of v1 scope; decode to nothing
                // rather than guess the partial layout. Per OURA_PROTOCOL.md s6.13.
                emptyList()

            // --- Tier A: Sleep phase (2-bit codes are verified) ---
            OuraEventTag.SLEEP_PHASE, OuraEventTag.SLEEP_PHASE_ALT ->
                (OuraDecoders.decodeSleepPhase(record) ?: emptyList()).map { OuraEvent.SleepPhaseEvent(it) }
            OuraEventTag.SLEEP_PERIOD ->
                OuraDecoders.decodeSleepPeriod(record)?.let { listOf(OuraEvent.SleepPeriodEvent(it)) } ?: emptyList()
            OuraEventTag.BEDTIME_PERIOD ->
                OuraDecoders.decodeBedtimePeriod(record)?.let { listOf(OuraEvent.BedtimePeriodEvent(it)) } ?: emptyList()

            // --- Tier A: Lifecycle / state / time ---
            OuraEventTag.TIME_SYNC -> {
                // Primary UTC anchor (s5.5): always wins over a secondary RTC-beacon anchor already set.
                val ts = OuraDecoders.decodeTimeSync(record, ringGen) ?: return emptyList()
                if (ringGen == OuraRingGen.GEN4) {
                    val matchesActiveRequest = pendingSyncCounter?.let { ts.epochMs == it * 256L } == true &&
                        pendingSyncToken?.let { ts.token == it } == true
                    if (!matchesActiveRequest && !historicalAnchorBootstrapEnabled) {
                        return listOf(OuraEvent.TimeSyncEvent(ts))
                    }
                }
                // The decoded wire value is unix seconds; the seconds->ms conversion lives in the anchor gate.
                // CRASH-SAFETY (s6.11): a full cursor=0 history dump can hit a 0x42 record with an
                // implausible raw value; plausibleAnchorMs bounds-checks BEFORE multiplying, so an
                // implausible value is safely ignored (never anchors to garbage) instead of overflowing.
                val anchored = setAnchorIfPlausible(
                    ts.epochMs,
                    ts.ringTimestamp,
                    preferPrimary = true,
                    factorMsPerTick = ts.factorMsPerTick,
                )
                if (ringGen == OuraRingGen.GEN4 && anchored) activeFetchHasFreshAnchor = true
                listOf(OuraEvent.TimeSyncEvent(ts))
            }
            OuraEventTag.RTC_BEACON -> {
                val r = OuraDecoders.decodeRtcBeacon(record) ?: return emptyList()
                if (rtcBeaconQualifiesForActiveFetch(r)) {
                    // Hardware-qualified fallback at the beacon's documented 100-ms tick scale. Calling
                    // this primary/durable path intentionally replaces a carried-over mapping; a later
                    // correlated 0x42 still wins unconditionally.
                    if (setAnchorIfPlausible(r.unixSeconds, r.ringTimestamp, preferPrimary = true)) {
                        activeFetchHasFreshAnchor = true
                    }
                } else {
                    // Outside the narrow gate, retain the legacy session-only secondary behavior.
                    setAnchorIfPlausible(r.unixSeconds, r.ringTimestamp, preferPrimary = false)
                }
                listOf(OuraEvent.RtcBeaconEvent(r))
            }
            OuraEventTag.STATE_CHANGE, OuraEventTag.WEAR_EVENT ->
                OuraDecoders.decodeState(record)?.let { listOf(OuraEvent.StateEvent(it)) } ?: emptyList()
            OuraEventTag.DEBUG_TEXT ->
                OuraDecoders.decodeDebugText(record)?.let {
                    listOf(OuraEvent.DebugTextEvent(ringTimestamp = record.ringTimestamp, text = it))
                } ?: emptyList()
            OuraEventTag.RING_START -> {
                val persistedFloor = maxOf(activeFetchDurableCursor, primaryTimeAnchor?.ringTimestamp ?: 0L)
                if ((previousRingTimestamp != 0L && record.ringTimestamp < previousRingTimestamp) ||
                    (persistedFloor > 0L && record.ringTimestamp < persistedFloor)) {
                    invalidateAnchor(invalidatePersistentState = true)
                }
                emptyList()
            }

            // --- Tier B (only reached when allowTierB == true; otherwise dropped above) ---
            OuraEventTag.SLEEP_SUMMARY_1, OuraEventTag.SLEEP_SUMMARY_B, OuraEventTag.SLEEP_SUMMARY_C,
            OuraEventTag.SLEEP_SUMMARY_D, OuraEventTag.SLEEP_SUMMARY_E, OuraEventTag.SLEEP_SUMMARY_F ->
                listOf(
                    OuraEvent.TierB(
                        OuraTierBSummary(
                            tag = record.type, ringTimestamp = record.ringTimestamp,
                            rawPayload = record.payload, kind = "sleep_summary",
                        ),
                    ),
                )
            OuraEventTag.ACTIVITY_INFO ->
                // Split out of the raw-bytes TierB wrapper: this ONE activity tag has a plausible decode
                // formula (OuraDecoders.decodeActivityInfo, third-party [oura-rs], PR #960 investigation).
                // Still Tier B - only reached behind allowTierB (gated above), and OuraStreamMapping never
                // folds ActivityInfo into a durable stream. 0x51/0x52 summaries stay raw below.
                OuraDecoders.decodeActivityInfo(record)?.let { listOf(OuraEvent.ActivityInfo(it)) }
                    ?: emptyList()
            OuraEventTag.ACTIVITY_SUMMARY_1, OuraEventTag.ACTIVITY_SUMMARY_2 ->
                listOf(
                    OuraEvent.TierB(
                        OuraTierBSummary(
                            tag = record.type, ringTimestamp = record.ringTimestamp,
                            rawPayload = record.payload, kind = "activity",
                        ),
                    ),
                )
            OuraEventTag.REAL_STEPS_1, OuraEventTag.REAL_STEPS_2 ->
                listOf(
                    OuraEvent.TierB(
                        OuraTierBSummary(
                            tag = record.type, ringTimestamp = record.ringTimestamp,
                            rawPayload = record.payload, kind = "real_steps",
                        ),
                    ),
                )
            OuraEventTag.SPO2_SMOOTHED ->
                listOf(
                    OuraEvent.TierB(
                        OuraTierBSummary(
                            tag = record.type, ringTimestamp = record.ringTimestamp,
                            rawPayload = record.payload, kind = "spo2_smoothed",
                        ),
                    ),
                )
        }
    }

    /**
     * Convenience: ingest a whole notification value by reassembling records and decoding each. The
     * caller passes a fresh notification value; the supplied reassembler buffers partial trailing
     * bytes across calls. Per OURA_PROTOCOL.md s2.4.
     */
    fun ingest(notification: IntArray, reassembler: OuraReassembler): List<OuraEvent> {
        val out = ArrayList<OuraEvent>()
        for (rec in reassembler.feed(notification)) {
            out.addAll(ingest(rec))
        }
        return out
    }

    /**
     * Decode a live-HR push (0x2F sub-op 0x28). The body is the bytes AFTER `2f 0f 28`; the push is
     * not a TLV record, so it is stamped with the last seen ring time. Per OURA_PROTOCOL.md s5.6.
     */
    fun ingestLiveHRPush(body: IntArray): List<OuraEvent> {
        val hr = OuraDecoders.decodeLiveHRPush(body, lastRingTimestamp) ?: return emptyList()
        // The push also carries the IBI; surface both so HRV analytics see the R-R.
        return listOf(
            OuraEvent.Hr(hr),
            OuraEvent.Ibi(OuraIBI(ringTimestamp = lastRingTimestamp, ibiMs = hr.ibiMs)),
        )
    }

    /**
     * Route a parsed secure sub-frame: extract the auth nonce / status, or a live-HR push body, so
     * the app does not need to know the 0x2F sub-op map. Returns the matching transition or push
     * events. Per OURA_PROTOCOL.md s4.2 / s5.6.
     */
    fun handleSecureFrame(frame: OuraSecureFrame): SecureRouting {
        OuraAuth.nonce(frame)?.let { return SecureRouting.Nonce(it) }
        OuraAuth.authStatus(frame)?.let { return SecureRouting.AuthStatus(it) }
        // Sub-op 0x28 carries the live-HR push samples (s5.6). subBody is everything after the subop.
        if (frame.subop == 0x28) {
            return SecureRouting.LiveHRPush(frame.subBody)
        }
        // Live-HR enable ACKs advance the triplet (s5.6): 0x21 is the dhr_read feature-read ACK from
        // step 1 (`2f 06 21 02 01 11 02 00`), 0x23 acks the enable write (step 2), 0x27 acks the
        // subscribe write (step 3). All three must be recognised or the sequencer stalls at step 0.
        if (frame.subop == 0x21 && phase != OuraDriverPhase.EnablingLiveHR &&
            frame.subBody.size >= 5 && frame.subBody[0] == 0x04) {
            return SecureRouting.FeatureStatus(
                OuraFeatureStatus(
                    feature = frame.subBody[0],
                    mode = frame.subBody[1],
                    status = frame.subBody[2],
                    state = frame.subBody[3],
                    subscription = frame.subBody[4],
                ),
            )
        }
        if (frame.subop == 0x21 || frame.subop == 0x23 || frame.subop == 0x27) {
            return SecureRouting.EnableAck
        }
        return SecureRouting.Unhandled
    }

    /** What handleSecureFrame resolved a 0x2F sub-frame to. Kotlin twin of Swift's SecureRouting. */
    sealed class SecureRouting {
        data class Nonce(val nonce: IntArray) : SecureRouting() {
            override fun equals(other: Any?): Boolean {
                if (this === other) return true
                if (other !is Nonce) return false
                return nonce.contentEquals(other.nonce)
            }
            override fun hashCode(): Int = nonce.contentHashCode()
        }

        data class AuthStatus(val status: OuraAuthStatus) : SecureRouting()

        data class LiveHRPush(val body: IntArray) : SecureRouting() {
            override fun equals(other: Any?): Boolean {
                if (this === other) return true
                if (other !is LiveHRPush) return false
                return body.contentEquals(other.body)
            }
            override fun hashCode(): Int = body.contentHashCode()
        }

        object EnableAck : SecureRouting()
        data class FeatureStatus(val value: OuraFeatureStatus) : SecureRouting()
        object Unhandled : SecureRouting()
    }

    companion object {
        /**
         * Bounds for a plausible anchor epoch (unix seconds): 2020-01-01 to 2035-01-01. A decoded
         * 0x42/0x85 value outside this range is a corrupt/misaligned record (seen on real hardware: a full
         * cursor=0 history dump hit one deep in the backlog) and is never trusted as an anchor (honest-data
         * invariant). This gate ALSO bounds the input to the seconds->ms `* 1000` conversion so it can
         * never overflow Long. Byte-identical to Swift's min/maxPlausibleEpochSeconds.
         */
        private const val MIN_PLAUSIBLE_EPOCH_SECONDS = 1_577_836_800L
        private const val MAX_PLAUSIBLE_EPOCH_SECONDS = 2_051_222_400L
        private const val RTC_FALLBACK_MAXIMUM_AGE_SECONDS = 48L * 60L * 60L
        private const val RTC_FALLBACK_FUTURE_TOLERANCE_SECONDS = 15L * 60L
        private const val MAX_RING_TIMESTAMP = 0xFFFF_FFFFL
        private val VALID_FACTORS = setOf(1L, 100L)

        /** Validate untrusted durable state before it can seed interpolation. */
        fun validateTimeAnchor(candidate: OuraTimeAnchor?): OuraTimeAnchor? {
            candidate ?: return null
            if (candidate.ringTimestamp !in 1L..MAX_RING_TIMESTAMP) return null
            val seconds = candidate.utcMilliseconds / 1_000L
            if (seconds !in MIN_PLAUSIBLE_EPOCH_SECONDS..MAX_PLAUSIBLE_EPOCH_SECONDS) return null
            if (candidate.factorMillisecondsPerTick !in VALID_FACTORS) return null
            return candidate
        }
    }
}
