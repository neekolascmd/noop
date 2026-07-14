import XCTest
@testable import OuraProtocol

/// OuraDriver flow tests: the transport-agnostic state machine drives scan -> auth -> enable -> stream
/// purely from transitions (no BLE), and ingest(record:) decodes records (with Tier-B gating).
final class OuraDriverTests: XCTestCase {
    private let key: [UInt8] = Array(0..<16)   // deterministic 16-byte app key
    private let rt: UInt32 = 0x0001_0002

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    // MARK: - Full happy-path step sequence (auth -> enable triplet -> streaming)

    func testFullEnableSequence() throws {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        XCTAssertEqual(d.phase, .idle)

        // ready -> request nonce first, then capture serial-free identity.
        let onReady = d.nextStep(after: .ready)
        XCTAssertEqual(d.phase, .authenticating)
        XCTAssertEqual(onReady.map { $0.label }, ["get_nonce", "get_firmware", "get_hardware"])
        XCTAssertEqual(onReady[0].bytes, [0x2F, 0x01, 0x2B])

        // nonce -> submit proof.
        let nonce = bytes("0102030405060708090a0b0c0d0e0f")
        let onNonce = d.nextStep(after: .nonceReceived(nonce))
        XCTAssertEqual(onNonce.count, 1)
        XCTAssertEqual(Array(onNonce[0].bytes[0..<3]), [0x2F, 0x11, 0x2D])
        // The proof body matches the known vector.
        XCTAssertEqual(Array(onNonce[0].bytes[3...]), bytes("c49fb9e83c46087a555183a9dc511ee9"))

        // auth success -> first live-HR step (read DHR status); CCCDs are already enabled by transport.
        let onAuth = d.nextStep(after: .authCompleted(.success))
        XCTAssertEqual(d.phase, .enablingLiveHR)
        XCTAssertEqual(onAuth.map { $0.label }, ["dhr_read"])
        XCTAssertEqual(onAuth[0].bytes, [0x2F, 0x02, 0x20, 0x02])

        // ack 1 -> enable ; ack 2 -> subscribe ; ack 3 -> streaming (no more commands).
        let step2 = d.nextStep(after: .enableAckReceived)
        XCTAssertEqual(step2.map { $0.label }, ["dhr_enable"])
        XCTAssertEqual(step2[0].bytes, [0x2F, 0x03, 0x22, 0x02, 0x03])

        let step3 = d.nextStep(after: .enableAckReceived)
        XCTAssertEqual(step3.map { $0.label }, ["dhr_subscribe"])
        XCTAssertEqual(step3[0].bytes, [0x2F, 0x03, 0x26, 0x02, 0x02])

        let done = d.nextStep(after: .enableAckReceived)
        XCTAssertTrue(done.isEmpty)
        XCTAssertEqual(d.phase, .streaming)
    }

    // MARK: - Honest pairing path when no key

    func testNoKeyDrivesNeedsKeyInstall() {
        let d = OuraDriver(ringGen: .gen3, authKey: nil)
        let cmds = d.nextStep(after: .ready)
        XCTAssertEqual(cmds.map { $0.label }, ["get_firmware", "get_hardware"],
                       "without a key, collect only safe serial-free identity and never authenticate")
        XCTAssertEqual(d.phase, .needsKeyInstall)
    }

    func testRing4ReadyUsesOfficialReadOnlyPreAuthOrder() {
        let d = OuraDriver(ringGen: .gen4, authKey: key)
        let commands = d.nextStep(after: .ready)
        XCTAssertEqual(commands.map(\.label), [
            "get_firmware", "get_hardware",
            "ring4_pre_auth_session_00", "ring4_pre_auth_session_01", "get_nonce",
        ])
        XCTAssertEqual(commands[2].bytes, [0x2F, 0x02, 0x01, 0x00])
        XCTAssertEqual(commands[3].bytes, [0x2F, 0x02, 0x01, 0x01])
        XCTAssertEqual(commands[4].bytes, [0x2F, 0x01, 0x2B])
    }

    func testFactoryResetStatusDrivesNeedsKeyInstall() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        _ = d.nextStep(after: .ready)
        let cmds = d.nextStep(after: .authCompleted(.inFactoryReset))
        XCTAssertTrue(cmds.isEmpty)
        XCTAssertEqual(d.phase, .needsKeyInstall)
    }

    func testAuthErrorIsSurfacedNotRetriedBlindly() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        _ = d.nextStep(after: .ready)
        _ = d.nextStep(after: .authCompleted(.authError))
        XCTAssertEqual(d.phase, .authFailed(.authError))
    }

    // MARK: - Post-factory-reset key install sequencing (s3.2), gated on allowKeyInstall

    /// With allowKeyInstall == true the adopt flow sequences needsKeyInstall -> installingKey ->
    /// (on the 0x25 ack) re-auth, and the post-install re-auth uses the freshly-provisioned key.
    func testKeyInstallSequencesReauthWhenAllowed() throws {
        // No injected key -> the honest needs-pairing path; the transport will provision one.
        let d = OuraDriver(ringGen: .gen3, authKey: nil, allowKeyInstall: true)
        let onReady = d.nextStep(after: .ready)
        XCTAssertEqual(onReady.map { $0.label }, ["get_firmware", "get_hardware"])
        XCTAssertEqual(d.phase, .needsKeyInstall)

        // The transport generates + persists a fresh 16-byte key and asks the driver for the install
        // command. It must be the DANGEROUS `24 10 <key>` write (s3.2) and advance to installingKey.
        let install = d.beginKeyInstall(key: key)
        XCTAssertNotNil(install)
        XCTAssertEqual(install?.label, "DANGEROUS_install_key")
        XCTAssertEqual(install?.bytes, [0x24, 0x10] + key)
        XCTAssertEqual(d.phase, .installingKey)

        // The ring acks with `25 01 00`; the transport calls back and the driver drives re-auth.
        let onAck = d.keyInstallAcknowledged()
        XCTAssertEqual(onAck.map { $0.label }, ["get_nonce"])
        XCTAssertEqual(onAck[0].bytes, [0x2F, 0x01, 0x2B])
        XCTAssertEqual(d.phase, .authenticating)

        // Re-auth uses the freshly-installed key: the proof matches the known vector for that key.
        let nonce = bytes("0102030405060708090a0b0c0d0e0f")
        let onNonce = d.nextStep(after: .nonceReceived(nonce))
        XCTAssertEqual(onNonce.count, 1)
        XCTAssertEqual(Array(onNonce[0].bytes[0..<3]), [0x2F, 0x11, 0x2D])
        XCTAssertEqual(Array(onNonce[0].bytes[3...]), bytes("c49fb9e83c46087a555183a9dc511ee9"))
    }

    /// With allowKeyInstall == false (the default) the driver MUST NOT sequence an install: it stays at
    /// needsKeyInstall, emits no command, and a stray 0x25 ack cannot advance the flow.
    func testNoKeyInstallSequencedWhenNotAllowed() {
        let d = OuraDriver(ringGen: .gen3, authKey: nil)   // allowKeyInstall defaults to false
        _ = d.nextStep(after: .ready)
        XCTAssertEqual(d.phase, .needsKeyInstall)

        let install = d.beginKeyInstall(key: key)
        XCTAssertNil(install, "no dangerous 0x24 write may be produced without an opt-in adopt flow")
        XCTAssertEqual(d.phase, .needsKeyInstall, "phase must stay needsKeyInstall")

        // A stray ack must be ignored too (no install was sequenced, so there is nothing to acknowledge).
        let onAck = d.keyInstallAcknowledged()
        XCTAssertTrue(onAck.isEmpty)
        XCTAssertEqual(d.phase, .needsKeyInstall)
    }

    /// Even with allowKeyInstall == true, beginKeyInstall only fires from needsKeyInstall; a call from
    /// another phase is a no-op (the gate is BOTH the flag and the phase).
    func testKeyInstallIgnoredOutsideNeedsKeyInstallPhase() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowKeyInstall: true)
        _ = d.nextStep(after: .ready)        // -> authenticating (a real key is present)
        XCTAssertEqual(d.phase, .authenticating)
        XCTAssertNil(d.beginKeyInstall(key: key), "install must not fire outside needsKeyInstall")
        XCTAssertEqual(d.phase, .authenticating)
    }

    // MARK: - History fetch loop

    func testRing4HistoryFetchWaitsForTimeSyncAckThenFlushesFetchesAndAcks() {
        let d = OuraDriver(ringGen: .gen4, authKey: key, timeSyncToken: 0x5A)
        let start = d.nextStep(after: .startHistoryFetch(cursor: 0, unixSeconds: 256))
        XCTAssertEqual(d.phase, .fetchingHistory)
        XCTAssertEqual(start.map { $0.label }, [
            "event_stream_enable", "sync_time", "ring4_post_sync_state",
            "event_category_14", "event_category_18", "event_category_28",
            "event_category_34", "event_category_04", "event_category_08",
            "get_battery", "ring4_param_read_02", "ring4_param_read_04",
            "ring4_history_session_mode",
            "ring4_param_read_0b", "ring4_param_read_0d", "ring4_param_read_03",
            "ring4_param_read_0b_again", "ring4_param_read_10",
        ])
        XCTAssertEqual(start[0].bytes, [0x16, 0x01, 0x02])
        XCTAssertEqual(Array(start[1].bytes[0...1]), [0x12, 0x09])
        XCTAssertEqual(Array(start[1].bytes[3...5]), [0x01, 0x00, 0x00])
        XCTAssertEqual(Array(start[1].bytes[6...10]), [0x00, 0x00, 0x00, 0x00, 0xF6])
        XCTAssertEqual(start[2].bytes, [0x1C, 0x01, 0xBF])
        XCTAssertEqual(Array(start.dropFirst(3).prefix(6).map(\.bytes)), [
            [0x18, 0x03, 0x14, 0x00, 0x10],
            [0x18, 0x03, 0x18, 0x00, 0x10],
            [0x18, 0x03, 0x28, 0x00, 0x09],
            [0x18, 0x03, 0x34, 0x00, 0x04],
            [0x18, 0x03, 0x04, 0x00, 0x10],
            [0x18, 0x03, 0x08, 0x00, 0x10],
        ])
        XCTAssertEqual(start[9].bytes, [0x0C, 0x00])
        XCTAssertEqual(Array(start.dropFirst(10).map(\.bytes)), [
            [0x2F, 0x02, 0x20, 0x02],
            [0x2F, 0x02, 0x20, 0x04],
            [0x2F, 0x02, 0x03, 0x01],
            [0x2F, 0x02, 0x20, 0x0B],
            [0x2F, 0x02, 0x20, 0x0D],
            [0x2F, 0x02, 0x20, 0x03],
            [0x2F, 0x02, 0x20, 0x0B],
            [0x2F, 0x02, 0x20, 0x10],
        ])

        let fetch = d.nextStep(after: .timeSyncAcknowledged(cursor: 0))
        XCTAssertEqual(fetch.map { $0.label }, ["flush_buffer", "get_events"])
        XCTAssertTrue(d.nextStep(after: .timeSyncAcknowledged(cursor: 0)).isEmpty,
                      "a duplicate 0x13 must not release a second history fetch")
        XCTAssertTrue(d.nextStep(after: .timeSyncReleaseTimedOut(cursor: 0)).isEmpty,
                      "a late timeout must not release a second history fetch")
        // get_events cursor 0, max 255, flags FFFFFFFF.
        XCTAssertEqual(fetch[1].bytes, [0x10, 0x09, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])

        // More data -> ack-fetch (max 0) at the advanced cursor.
        let ack = d.nextStep(after: .historyCursorAdvanced(cursor: 0x12345678, moreData: true))
        XCTAssertEqual(ack.count, 1)
        XCTAssertEqual(ack[0].bytes, [0x10, 0x09, 0x78, 0x56, 0x34, 0x12, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])

        // No more -> back to streaming.
        let stop = d.nextStep(after: .historyCursorAdvanced(cursor: 0x12345678, moreData: false))
        XCTAssertTrue(stop.isEmpty)
        XCTAssertEqual(d.phase, .streaming)

        let nextPoll = d.nextStep(after: .startHistoryFetch(cursor: 0x12345678, unixSeconds: 512))
        XCTAssertEqual(nextPoll.map(\.label), ["event_stream_enable", "sync_time"],
                       "category masks are sent once per BLE session")
    }

    func testRing4TimeSyncTimeoutReleasesExactlyOneGuardedFetch() {
        let d = OuraDriver(ringGen: .gen4, authKey: key, timeSyncToken: 0x5A)
        _ = d.nextStep(after: .startHistoryFetch(cursor: 7, unixSeconds: 256))
        let fetch = d.nextStep(after: .timeSyncReleaseTimedOut(cursor: 7))
        XCTAssertEqual(fetch.map { $0.label }, ["flush_buffer", "get_events"])
        let provisional = d.nextStep(after: .continueProvisionalHistory(cursor: 0x12345678))
        XCTAssertEqual(provisional.map(\.label), ["get_events"])
        XCTAssertEqual(provisional[0].bytes,
                       [0x10, 0x09, 0x78, 0x56, 0x34, 0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
                       "provisional continuation must read max=255 and never emit a max=0 ACK")
        XCTAssertTrue(d.nextStep(after: .timeSyncReleaseTimedOut(cursor: 7)).isEmpty)
        XCTAssertTrue(d.nextStep(after: .timeSyncAcknowledged(cursor: 7)).isEmpty)
        XCTAssertFalse(d.hasFreshAnchorForActiveFetch,
                       "timeout release alone must never authorize cursor commit")
    }

    // MARK: - Ring-time -> UTC anchor (s5.5)

    /// Little-endian bytes of the RAW 0x42 wire value the decoder reads into `OuraTimeSync.epochMs`. The
    /// wire value is unix SECONDS (s6.11), despite the field's "epochMs" name (which reflects what
    /// OURA_PROTOCOL.md s6.11 claims, not what the driver now does with it), so tests build this from a
    /// seconds value.
    private func le8(_ v: Int64) -> [UInt8] {
        (0..<8).map { UInt8((UInt64(bitPattern: v) >> (8 * $0)) & 0xFF) }
    }

    func testNoAnchorBeforeAnyTimeSyncOrBeacon() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        XCTAssertNil(d.unixSeconds(forRingTimestamp: rt))
    }

    func testSyncTimeResponseIsAckOnlyAndDoesNotAnchor() {
        let d = OuraDriver(ringGen: .gen4, authKey: key, timeSyncToken: 0x5A)
        let requested = 1_800_000_123
        _ = d.nextStep(after: .startHistoryFetch(cursor: 0, unixSeconds: requested))
        let counter = UInt32(requested / 256)
        let body: [UInt8] = [0x00, UInt8(counter & 0xFF), UInt8((counter >> 8) & 0xFF),
                             UInt8((counter >> 16) & 0xFF), 0x00]
        let response = OuraFraming.parseSyncTimeResponse(body)
        XCTAssertEqual(response?.ackCode, 0)
        XCTAssertEqual(response?.counterEcho, counter)
        XCTAssertTrue(d.handleSyncTimeAcknowledgement(body: body))
        var nonZeroStatus = body
        nonZeroStatus[0] = 0x7F
        XCTAssertTrue(d.handleSyncTimeAcknowledgement(body: nonZeroStatus),
                      "0x13 is one-way liveness; its fields never authorize history commit")
        XCTAssertTrue(d.handleSyncTimeAcknowledgement(body: [0x00, 0x01, 0x02, 0x03, 0x00]),
                      "a well-formed 0x13 is liveness-only even when firmware does not echo our counter")
        XCTAssertFalse(d.handleSyncTimeAcknowledgement(body: [0x00, 0x01]))
        XCTAssertNil(d.unixSeconds(forRingTimestamp: 1_000))
        XCTAssertFalse(d.hasUtcAnchor)
    }

    func testTimeSyncSetsAnchorAndConvertsPastAndFutureRingTimes() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let anchorEpochSeconds: Int64 = 1_700_000_000   // the wire's raw value (seconds, not ms)
        let anchorRt: UInt32 = 10_000
        let payload = le8(anchorEpochSeconds) + [0x00]   // raw wire epoch (8B) + tz offset (0 half-hours)
        let rec = OuraRecord(type: OuraEventTag.timeSync.rawValue, ringTimestamp: anchorRt, payload: payload)
        let events = d.ingest(record: rec)
        XCTAssertEqual(events, [.timeSync(OuraTimeSync(ringTimestamp: anchorRt, epochMs: anchorEpochSeconds, tzOffsetSeconds: 0))])

        // Exactly at the anchor: the driver applies the x1000 seconds->ms correction internally, so
        // unixSeconds recovers the ORIGINAL seconds value.
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: anchorRt), Int(anchorEpochSeconds))
        // 100 ticks (10s at the default 100ms/tick) BEFORE the anchor -> 10s earlier (a past/historical
        // record, e.g. from a GetEvents history fetch).
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: anchorRt - 100), Int(anchorEpochSeconds) - 10)
        // 100 ticks AFTER the anchor -> 10s later.
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: anchorRt + 100), Int(anchorEpochSeconds) + 10)
    }

    func testRing4TimeSyncSetsNormalAndBurstClockFactors() {
        let epochSeconds: Int64 = 1_700_000_000
        let counter = UInt32(epochSeconds / 256)
        func payload(token: UInt8) -> [UInt8] {
            [token, UInt8(counter & 0xFF), UInt8((counter >> 8) & 0xFF),
             UInt8((counter >> 16) & 0xFF), 0, 0, 0, 0, 0xF6]
        }

        let normal = OuraDriver(ringGen: .gen4, authKey: key, timeSyncToken: 0x00)
        _ = normal.nextStep(after: .startHistoryFetch(cursor: 0, unixSeconds: Int(epochSeconds)))
        _ = normal.ingest(record: OuraRecord(type: OuraEventTag.timeSync.rawValue,
                                             ringTimestamp: 10_000, payload: payload(token: 0x00)))
        XCTAssertEqual(normal.unixSeconds(forRingTimestamp: 10_010), Int(epochSeconds) + 1)

        let burst = OuraDriver(ringGen: .gen4, authKey: key, timeSyncToken: 0xFD)
        _ = burst.nextStep(after: .startHistoryFetch(cursor: 0, unixSeconds: Int(epochSeconds)))
        _ = burst.ingest(record: OuraRecord(type: OuraEventTag.timeSync.rawValue,
                                            ringTimestamp: 20_000, payload: payload(token: 0xFD)))
        XCTAssertEqual(burst.unixSeconds(forRingTimestamp: 21_000), Int(epochSeconds) + 1)
    }

    func testRing4RejectsStaleAnchorAndRingStartRegressionClearsFreshAnchor() {
        let requested: Int64 = 1_700_000_000
        func payload(epochSeconds: Int64, token: UInt8) -> [UInt8] {
            let counter = UInt32(epochSeconds / 256)
            return [token, UInt8(counter & 0xFF), UInt8((counter >> 8) & 0xFF),
                    UInt8((counter >> 16) & 0xFF), 0, 0, 0, 0, 0xF6]
        }

        let d = OuraDriver(ringGen: .gen4, authKey: key, timeSyncToken: 0x5A)
        _ = d.nextStep(after: .startHistoryFetch(cursor: 0, unixSeconds: Int(requested)))
        _ = d.ingest(record: OuraRecord(type: OuraEventTag.timeSync.rawValue,
                                        ringTimestamp: 9_000,
                                        payload: payload(epochSeconds: requested - 256, token: 0x5A)))
        XCTAssertFalse(d.hasUtcAnchor, "a plausible stale backlog anchor must not match the active request")

        _ = d.ingest(record: OuraRecord(type: OuraEventTag.timeSync.rawValue,
                                        ringTimestamp: 10_000,
                                        payload: payload(epochSeconds: requested, token: 0x01)))
        XCTAssertFalse(d.hasUtcAnchor, "the right counter with the wrong request token must remain provisional")

        _ = d.ingest(record: OuraRecord(type: OuraEventTag.timeSync.rawValue,
                                        ringTimestamp: 10_001,
                                        payload: payload(epochSeconds: requested, token: 0x5A)))
        XCTAssertTrue(d.hasUtcAnchor)
        XCTAssertTrue(d.hasFreshAnchorForActiveFetch)
        _ = d.ingest(record: OuraRecord(type: OuraEventTag.ringStart.rawValue,
                                        ringTimestamp: 1, payload: []))
        XCTAssertFalse(d.hasUtcAnchor)
        XCTAssertNil(d.unixSeconds(forRingTimestamp: 10_000))
    }

    func testRing4BoundedBootstrapAcceptsHistoricalAnchorThenRefetchesDurableCursor() {
        let requested: Int64 = 1_700_000_000
        let historical: Int64 = requested - 256
        let counter = UInt32(historical / 256)
        let payload: [UInt8] = [
            0x11, UInt8(counter & 0xFF), UInt8((counter >> 8) & 0xFF),
            UInt8((counter >> 16) & 0xFF), 0, 0, 0, 0, 0xF6,
        ]
        let d = OuraDriver(ringGen: .gen4, authKey: key, timeSyncToken: 0x5A)
        _ = d.nextStep(after: .startHistoryFetch(cursor: 77, unixSeconds: Int(requested)))
        d.enableHistoricalAnchorBootstrap()
        _ = d.ingest(record: OuraRecord(type: OuraEventTag.timeSync.rawValue,
                                        ringTimestamp: 9_000, payload: payload))
        XCTAssertTrue(d.hasFreshAnchorForActiveFetch)
        let restart = d.nextStep(after: .restartHistoryFromBootstrap(cursor: 77))
        XCTAssertEqual(restart.map(\.label), ["flush_buffer", "get_events"])
        XCTAssertEqual(restart[1].bytes,
                       [0x10, 0x09, 0x4D, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertTrue(d.hasFreshAnchorForActiveFetch)
        XCTAssertNil(d.activeHistoryHighWater)
    }

    func testRing4PersistedAnchorTranslatesButNeedsMonotonicContinuityToCommit() {
        let anchor = OuraTimeAnchor(ringTimestamp: 1_000,
                                    utcMilliseconds: 1_700_000_000_000,
                                    factorMillisecondsPerTick: 100)
        let d = OuraDriver(ringGen: .gen4, authKey: key, timeSyncToken: 0x5A,
                           persistedTimeAnchor: anchor)
        XCTAssertEqual(d.currentPrimaryTimeAnchor, anchor)
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: 1_100), 1_700_000_010)

        _ = d.nextStep(after: .startHistoryFetch(cursor: 1_100, unixSeconds: 1_700_000_100))
        XCTAssertFalse(d.hasFreshAnchorForActiveFetch,
                       "loading a mapping must never authorize a cursor ACK by itself")
        XCTAssertFalse(d.canResolveHistoryTimestamps,
                       "history must stay parked until continuity authorizes the active fetch")

        _ = d.ingest(record: OuraRecord(type: 0x99, ringTimestamp: 1_099, payload: []))
        XCTAssertFalse(d.hasFreshAnchorForActiveFetch,
                       "a record behind the durable cursor cannot prove continuity")
        _ = d.ingest(record: OuraRecord(type: 0x99, ringTimestamp: 1_100, payload: []))
        XCTAssertTrue(d.hasFreshAnchorForActiveFetch)
        XCTAssertTrue(d.canResolveHistoryTimestamps)
    }

    func testRing4RejectsInvalidPersistedAnchors() {
        let zeroRingTime = OuraTimeAnchor(ringTimestamp: 0,
                                          utcMilliseconds: 1_700_000_000_000,
                                          factorMillisecondsPerTick: 100)
        let badFactor = OuraTimeAnchor(ringTimestamp: 1_000,
                                       utcMilliseconds: 1_700_000_000_000,
                                       factorMillisecondsPerTick: 10)
        let futureEpoch = OuraTimeAnchor(ringTimestamp: 1_000,
                                         utcMilliseconds: 2_200_000_000_000,
                                         factorMillisecondsPerTick: 100)
        for anchor in [zeroRingTime, badFactor, futureEpoch] {
            let d = OuraDriver(ringGen: .gen4, authKey: key, persistedTimeAnchor: anchor)
            XCTAssertNil(d.currentPrimaryTimeAnchor)
            XCTAssertFalse(d.hasUtcAnchor)
        }
    }

    func testPersistedAnchorRingStartRegressionSignalsDurableStateInvalidationOnce() {
        let anchor = OuraTimeAnchor(ringTimestamp: 1_000,
                                    utcMilliseconds: 1_700_000_000_000,
                                    factorMillisecondsPerTick: 100)
        let d = OuraDriver(ringGen: .gen4, authKey: key, persistedTimeAnchor: anchor)
        _ = d.nextStep(after: .startHistoryFetch(cursor: 1_100, unixSeconds: 1_700_000_100))

        _ = d.ingest(record: OuraRecord(type: OuraEventTag.ringStart.rawValue,
                                        ringTimestamp: 5, payload: []))

        XCTAssertNil(d.currentPrimaryTimeAnchor)
        XCTAssertFalse(d.hasUtcAnchor)
        XCTAssertTrue(d.consumePersistentTimeStateInvalidation())
        XCTAssertFalse(d.consumePersistentTimeStateInvalidation())
    }

    func testRtcBeaconIsNeverExportedAsDurablePrimaryAnchor() {
        let d = OuraDriver(ringGen: .gen4, authKey: key)
        let seconds = 1_700_000_500
        let beaconPayload: [UInt8] = [
            UInt8(seconds & 0xFF), UInt8((seconds >> 8) & 0xFF),
            UInt8((seconds >> 16) & 0xFF), UInt8((seconds >> 24) & 0xFF),
        ]
        _ = d.ingest(record: OuraRecord(type: OuraEventTag.rtcBeacon.rawValue,
                                        ringTimestamp: 5_000, payload: beaconPayload))
        XCTAssertTrue(d.hasUtcAnchor, "the beacon remains useful within this connection")
        XCTAssertNil(d.currentPrimaryTimeAnchor,
                     "the secondary beacon must not become reconnect-durable state")
    }

    func testHistoryHighWaterUsesEveryValidInnerRecordAndStartsEmpty() {
        let d = OuraDriver(ringGen: .gen4, authKey: key, timeSyncToken: 0x5A)
        _ = d.nextStep(after: .startHistoryFetch(cursor: 0, unixSeconds: 1_700_000_000))
        XCTAssertNil(d.activeHistoryHighWater)
        _ = d.ingest(record: OuraRecord(type: 0x99, ringTimestamp: 10, payload: []))
        _ = d.ingest(record: OuraRecord(type: OuraEventTag.stateChange.rawValue,
                                        ringTimestamp: 42, payload: [1]))
        _ = d.ingest(record: OuraRecord(type: 0x13, ringTimestamp: 999, payload: []))
        XCTAssertEqual(d.activeHistoryHighWater, 42,
                       "unknown valid TLVs count; outer opcodes below 0x41 never do")
    }

    func testRtcBeaconOnlyAnchorsWhenNoTimeSyncSeenYet() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let beaconRt: UInt32 = 5_000
        let beaconUnixSeconds = 1_700_000_500
        // 0x85 rtc_beacon_ind: unix_s u32 LE + 4 reserved + trailer (payload just needs >= 4 bytes).
        let beaconPayload: [UInt8] = [
            UInt8(beaconUnixSeconds & 0xFF), UInt8((beaconUnixSeconds >> 8) & 0xFF),
            UInt8((beaconUnixSeconds >> 16) & 0xFF), UInt8((beaconUnixSeconds >> 24) & 0xFF),
        ]
        let beaconRec = OuraRecord(type: OuraEventTag.rtcBeacon.rawValue, ringTimestamp: beaconRt, payload: beaconPayload)
        _ = d.ingest(record: beaconRec)
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: beaconRt), beaconUnixSeconds)

        // A later, more precise 0x42 time-sync must override the coarser beacon anchor.
        let syncEpochSeconds: Int64 = 1_700_001_000
        let syncRt: UInt32 = 6_000
        let syncPayload = le8(syncEpochSeconds) + [0x00]
        let syncRec = OuraRecord(type: OuraEventTag.timeSync.rawValue, ringTimestamp: syncRt, payload: syncPayload)
        _ = d.ingest(record: syncRec)
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: syncRt), Int(syncEpochSeconds))

        // A SECOND beacon after a time-sync anchor is already set must NOT override it (secondary only
        // fills a gap, never displaces the primary source).
        let laterBeaconRec = OuraRecord(type: OuraEventTag.rtcBeacon.rawValue, ringTimestamp: syncRt + 100,
                                        payload: beaconPayload)
        _ = d.ingest(record: laterBeaconRec)
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: syncRt), Int(syncEpochSeconds),
                       "a later RTC beacon must not displace an already-set time-sync anchor")
    }

    func testStopClearsTheAnchor() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let payload = le8(1_700_000_000) + [0x00]
        let rec = OuraRecord(type: OuraEventTag.timeSync.rawValue, ringTimestamp: 1_000, payload: payload)
        _ = d.ingest(record: rec)
        XCTAssertNotNil(d.unixSeconds(forRingTimestamp: 1_000))
        d.stop()
        XCTAssertNil(d.unixSeconds(forRingTimestamp: 1_000), "a stale anchor must not survive stop()/a new session")
    }

    /// Regression test for the crash-safety rule (s6.11): a full cursor=0 history dump can hit a 0x42
    /// record deep in the backlog with an implausible raw value that would overflow Int64 on the naive
    /// seconds->ms `* 1000` conversion (Swift traps on overflow). The plausibility gate must reject it
    /// WITHOUT crashing and WITHOUT setting a garbage anchor.
    func testImplausibleTimeSyncNeverCrashesOrAnchors() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let hugePayload = le8(Int64.max) + [0x00]   // the exact class of value that overflows the multiply
        let hugeRec = OuraRecord(type: OuraEventTag.timeSync.rawValue, ringTimestamp: 1_000, payload: hugePayload)
        XCTAssertNoThrow(_ = d.ingest(record: hugeRec))
        XCTAssertNil(d.unixSeconds(forRingTimestamp: 1_000), "an implausible epoch must never become the anchor")

        // A negative epoch (int64 sign bit set on a misaligned record) must be equally rejected.
        let negativePayload = le8(-1) + [0x00]
        let negativeRec = OuraRecord(type: OuraEventTag.timeSync.rawValue, ringTimestamp: 2_000, payload: negativePayload)
        XCTAssertNoThrow(_ = d.ingest(record: negativeRec))
        XCTAssertNil(d.unixSeconds(forRingTimestamp: 2_000))

        // A GOOD time-sync arriving afterward must still anchor normally (the gate doesn't wedge the driver).
        let goodPayload = le8(1_700_000_000) + [0x00]
        let goodRec = OuraRecord(type: OuraEventTag.timeSync.rawValue, ringTimestamp: 3_000, payload: goodPayload)
        _ = d.ingest(record: goodRec)
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: 3_000), 1_700_000_000)
    }

    // MARK: - ingest(record:) decoding

    func testIngestDecodesTierARecord() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        // 0x7B SpO2 stable record -> one spo2 event (970, BE).
        let rec = OuraFraming.parseRecord(bytes("7b060200010003ca"))!
        let events = d.ingest(record: rec)
        XCTAssertEqual(events, [.spo2(OuraSpO2(ringTimestamp: rt, value: 970, unit: "tenths_percent"))])
    }

    func testIngestUnknownTagYieldsNothing() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        // 0x99 is not in the dictionary -> [] (never a guessed value).
        let rec = OuraRecord(type: 0x99, ringTimestamp: rt, payload: [0x01, 0x02])
        XCTAssertEqual(d.ingest(record: rec), [])
    }

    // MARK: - Tier-B gating

    func testTierBDroppedByDefault() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)   // allowTierB defaults to false
        // 0x49 sleep_summary_1 is Tier B (UNVERIFIED).
        let rec = OuraFraming.parseRecord(bytes("49080200010001020304"))!
        XCTAssertEqual(d.ingest(record: rec), [], "Tier-B must not feed values when not explicitly allowed")
    }

    func testTierBEmittedOnlyWhenAllowed() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        let rec = OuraFraming.parseRecord(bytes("49080200010001020304"))!
        let events = d.ingest(record: rec)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].isTierB)
        if case .tierB(let summary) = events[0] {
            XCTAssertEqual(summary.tag, 0x49)
            XCTAssertEqual(summary.kind, "sleep_summary")
            XCTAssertEqual(summary.rawPayload, bytes("01020304"))
        } else {
            XCTFail("expected a tierB event")
        }
    }

    // MARK: - Activity info (0x50, Tier B, third-party formula) - real Gen 3 captures (PR #960)
    //
    // The six payloads below are byte-for-byte what a real Gen 3 ring sent across the PR #960
    // investigation sessions (2026-07-02): three short static captures, then a full day from steady
    // resting (~0.9 MET) through a vigorous-activity burst (7.4 MET). The ringTimestamp was not part of
    // the captures, so the fixture `rt` stamps them - the pinned evidence is the decoded state/MET
    // values, each RECOMPUTED from the s6.13 formula (met = byte*0.1 below 0x80), not copied blind
    // (the v8.0.1 Oura SpO2 bug was a wrong-decode that asserted constants would have hidden).

    func testActivityInfoDecodesRealCapture1() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        // Raw payload 41 12 13 13 20: state 0x41=65; MET 18*0.1, 19*0.1, 19*0.1, 32*0.1.
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt,
                             payload: bytes("4112131320"))
        let events = d.ingest(record: rec)
        XCTAssertEqual(events, [.activityInfo(OuraActivityInfo(ringTimestamp: rt, state: 0x41,
                                                               met: [1.8, 1.9, 1.9, 3.2]))])
        XCTAssertTrue(events[0].isTierB, "activityInfo must still report isTierB - the formula is UNVERIFIED")
    }

    func testActivityInfoDecodesRealCapture2() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        // Raw payload 37 21 17 0e 0e 0d 0f 11: state 0x37=55; MET 3.3, 2.3, 1.4, 1.4, 1.3, 1.5, 1.7.
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt,
                             payload: bytes("3721170e0e0d0f11"))
        XCTAssertEqual(d.ingest(record: rec),
                       [.activityInfo(OuraActivityInfo(ringTimestamp: rt, state: 0x37,
                                                       met: [3.3, 2.3, 1.4, 1.4, 1.3, 1.5, 1.7]))])
    }

    func testActivityInfoDecodesRealCapture3() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        // Raw payload 4a 19 20 0e 18: state 0x4a=74; MET 2.5, 3.2, 1.4, 2.4.
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt,
                             payload: bytes("4a19200e18"))
        XCTAssertEqual(d.ingest(record: rec),
                       [.activityInfo(OuraActivityInfo(ringTimestamp: rt, state: 0x4a,
                                                       met: [2.5, 3.2, 1.4, 2.4]))])
    }

    func testActivityInfoDecodesRealCapture4Resting() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        // Full-day session, steady resting: state 0, MET 1.1 then 12 x 0.9 (bytes 0x0B, 0x09 x 12).
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt, payload: [
            0x00, 0x0B, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09,
        ])
        XCTAssertEqual(d.ingest(record: rec),
                       [.activityInfo(OuraActivityInfo(ringTimestamp: rt, state: 0,
                           met: [1.1, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9]))])
    }

    func testActivityInfoDecodesRealCapture5ModerateActivity() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        // Light/moderate period: state 0x2E=46, 13 MET samples 1.2-2.3.
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt, payload: [
            0x2E, 0x17, 0x11, 0x11, 0x0E, 0x0D, 0x11, 0x0D, 0x0D, 0x0D, 0x0E, 0x0E, 0x0C, 0x13,
        ])
        XCTAssertEqual(d.ingest(record: rec),
                       [.activityInfo(OuraActivityInfo(ringTimestamp: rt, state: 46,
                           met: [2.3, 1.7, 1.7, 1.4, 1.3, 1.7, 1.3, 1.3, 1.3, 1.4, 1.4, 1.2, 1.9]))])
    }

    func testActivityInfoDecodesRealCapture6ExerciseBurst() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        // Vigorous burst: state 0x8B=139 (high bit set on the STATE byte, which is NOT MET-encoded),
        // MET 1.8 and 7.4 (0x4A=74 -> 7.4, the highest real value seen). Also the shortest real payload
        // (2 samples), consistent with more frequent flushes during a high-variability period.
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt,
                             payload: [0x8B, 0x12, 0x4A])
        XCTAssertEqual(d.ingest(record: rec),
                       [.activityInfo(OuraActivityInfo(ringTimestamp: rt, state: 139, met: [1.8, 7.4]))])
    }

    func testActivityInfoHighByteBranchUsesCoarseSlope() {
        // No real capture has hit the >= 0x80 MET branch yet (nothing above 7.4 MET seen), so pin it
        // with SYNTHETIC vectors recomputed from the s6.13 formula: met = 12.8 + (byte - 128) * 0.2.
        //   0x80 = 128 -> 12.8   |   0x90 = 144 -> 12.8 + 16*0.2 = 16.0   |   0xFF = 255 -> 12.8 + 127*0.2 = 38.2
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt,
                             payload: [0x01, 0x80, 0x90, 0xFF])
        XCTAssertEqual(OuraDecoders.decodeActivityInfo(rec),
                       OuraActivityInfo(ringTimestamp: rt, state: 1, met: [12.8, 16.0, 38.2]))
    }

    func testActivityInfoDroppedByDefaultLikeOtherTierB() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)   // allowTierB defaults to false
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt,
                             payload: bytes("4112131320"))
        XCTAssertEqual(d.ingest(record: rec), [], "the Tier-B gate must cover .activityInfo too")
    }

    func testActivityInfoEmptyPayloadDecodesToNil() {
        // No state byte at all -> honest nil, never a guessed state.
        XCTAssertNil(OuraDecoders.decodeActivityInfo(
            OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt, payload: [])))
    }

    // MARK: - Live-HR push routing + decode

    func testHandleSecureFrameRoutesNonceStatusAndPush() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let nonceFrame = OuraSecureFrame(subop: 0x2C, subBody: bytes("0102030405060708090a0b0c0d0e0f"))
        XCTAssertEqual(d.handleSecureFrame(nonceFrame), .nonce(bytes("0102030405060708090a0b0c0d0e0f")))

        let statusFrame = OuraSecureFrame(subop: 0x2E, subBody: [0x00])
        XCTAssertEqual(d.handleSecureFrame(statusFrame), .authStatus(.success))

        let ackFrame = OuraSecureFrame(subop: 0x23, subBody: [0x02, 0x00])
        XCTAssertEqual(d.handleSecureFrame(ackFrame), .enableAck)

        // s5.6 step 1: the dhr_read feature-read ACK (`2f 06 21 02 01 11 02 00`) is subop 0x21 with body
        // `02 01 11 02 00`. It must route to .enableAck or the enable triplet stalls at step 0 (#900).
        let dhrReadAck = OuraSecureFrame(subop: 0x21, subBody: bytes("0201110200"))
        XCTAssertEqual(d.handleSecureFrame(dhrReadAck), .enableAck)

        let spo2Status = OuraSecureFrame(subop: 0x21, subBody: bytes("0401000000"))
        XCTAssertEqual(d.handleSecureFrame(spo2Status),
                       .featureStatus(OuraFeatureStatus(feature: 0x04, mode: 0x01,
                                                        status: 0, state: 0, subscription: 0)))

        // The push subBody is the 14 bytes AFTER `2f 0f 28` from the s5.6 wire frame (IBI at [5..6]).
        let pushBody = bytes("020002000001040000000000007f")
        XCTAssertEqual(pushBody.count, 14)
        XCTAssertEqual(d.handleSecureFrame(OuraSecureFrame(subop: 0x28, subBody: pushBody)), .liveHRPush(pushBody))
    }

    func testLiveHRPushIngestStampsLastRingTime() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        // Ingest a TLV record first so the driver learns a ring time to stamp the push with.
        let rec = OuraFraming.parseRecord(bytes("420d0200010000d2dd639001000002"))!
        _ = d.ingest(record: rec)
        // The push body is the 14-byte s5.6 subBody (after `2f 0f 28`); IBI at [5..6] = 01 04 -> 1025 ms.
        let push = bytes("020002000001040000000000007f")
        let events = d.ingestLiveHRPush(body: push)
        XCTAssertEqual(events, [
            .hr(OuraHR(ringTimestamp: rt, bpm: 59, ibiMs: 1025)),
            .ibi(OuraIBI(ringTimestamp: rt, ibiMs: 1025)),
        ])
    }

    func testUnknownOuterOpcodeCannotChangeLivePushRingTime() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let valid = OuraFraming.parseRecord(bytes("420d0200010000d2dd639001000002"))!
        _ = d.ingest(record: valid)
        _ = d.ingest(record: OuraRecord(type: 0x13, ringTimestamp: 0xDEAD_BEEF, payload: []))

        let events = d.ingestLiveHRPush(body: bytes("020002000001040000000000007f"))
        XCTAssertEqual(events.first, .hr(OuraHR(ringTimestamp: rt, bpm: 59, ibiMs: 1025)))
    }

    // MARK: - Notification-level ingest via reassembler

    func testIngestNotificationReassemblesAndDecodes() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let reassembler = OuraReassembler()
        // Two records packed together: 0x7B SpO2 then 0x46 temp.
        let value = bytes("7b060200010003ca" + "460802000100420e470e")
        let events = d.ingest(notification: value, reassembler: reassembler)
        XCTAssertEqual(events, [
            .spo2(OuraSpO2(ringTimestamp: rt, value: 970, unit: "tenths_percent")),
            .temp(OuraTemp(ringTimestamp: rt, celsius: 36.50)),
            .temp(OuraTemp(ringTimestamp: rt, celsius: 36.55)),
        ])
    }

    // MARK: - Generation-driven command set / MTU

    func testRingGenMtuAndCaps() {
        XCTAssertEqual(OuraRingGen.gen3.mtu, 203)
        XCTAssertEqual(OuraRingGen.gen5.mtu, 247)
        XCTAssertTrue(OuraRingGen.gen4.hasExtraNotifyChars)
        XCTAssertTrue(OuraRingGen.gen5.hasExtraNotifyChars)
        XCTAssertFalse(OuraRingGen.gen3.hasExtraNotifyChars)
        XCTAssertEqual(OuraGatt.characteristicUUIDs(for: .gen4).count, 5)
        XCTAssertEqual(OuraRingGen.from(model: "Oura Ring 5"), .gen5)
        XCTAssertEqual(OuraRingGen.from(model: "Oura Ring 3"), .gen3)
        XCTAssertEqual(OuraRingGen.recognise(advertisedName: "Oura Ring 4"), .gen4)
        XCTAssertEqual(OuraRingGen.recognise(advertisedName: "Oura Gen 5"), .gen5)
        XCTAssertNil(OuraRingGen.recognise(advertisedName: "Oura 9051280476123456"))
        XCTAssertTrue(OuraRingGen.gen3.capabilities.contains(.hrv))
    }

    func testSyncTimeCommandCounter() {
        // counter = floor(unix / 256). For unix = 256 -> counter 1 -> bytes 01 00 00, trailer 0xF6.
        let cmd = OuraCommands.syncTime(unixSeconds: 256, token: 0)
        XCTAssertEqual(cmd.bytes, [0x12, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF6])
    }

    // MARK: - Dangerous commands are isolated and labelled

    func testDangerousCommandsAreClearlyNamed() {
        XCTAssertEqual(OuraDangerousCommands.softReset().bytes, [0x0E, 0x01, 0xFF])
        XCTAssertTrue(OuraDangerousCommands.softReset().label.hasPrefix("DANGEROUS_"))
        XCTAssertTrue(OuraDangerousCommands.factoryReset().label.hasPrefix("DANGEROUS_"))
        // The normal command builders never produce a reboot/reset opcode.
        XCTAssertNotEqual(OuraCommands.getBattery().bytes.first, 0x0E)
        XCTAssertNotEqual(OuraCommands.getBattery().bytes.first, 0x1A)
    }

    func testAutomaticSpO2CommandsAreByteExactAndExplicitlyNamed() {
        XCTAssertEqual(OuraCommands.spO2ReadStatus().bytes, [0x2F, 0x02, 0x20, 0x04])
        XCTAssertEqual(OuraCommands.spO2EnableAutomatic().bytes, [0x2F, 0x03, 0x22, 0x04, 0x01])
        XCTAssertEqual(OuraCommands.spO2EnableAutomatic().label, "spo2_enable_automatic")
    }
}
