package com.noop.oura

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * OuraDriver flow tests: the transport-agnostic state machine drives scan -> auth -> enable -> stream
 * purely from transitions (no BLE), and ingest(record:) decodes records (with Tier-B gating). Kotlin
 * twin of the Swift OuraDriverTests.swift.
 *
 * PARITY NOTE: the deterministic 16-byte app key (0..15), the rt anchor (0x00010002), and every
 * fixture hex string match the Swift OuraDriverTests fixtures byte-for-byte, so the same transitions
 * and the same record bytes drive the same commands/events across both ports.
 */
class OuraDriverTest {
    private val key: IntArray = IntArray(16) { it }   // deterministic 16-byte app key (0..15)
    private val rt: Long = 0x0001_0002

    private fun bytes(s: String) = OuraTestHex.bytes(s)

    // MARK: - Full happy-path step sequence (auth -> enable triplet -> streaming)

    @Test
    fun testFullEnableSequence() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        assertEquals(OuraDriverPhase.Idle, d.phase)

        // ready -> request nonce first, then capture serial-free identity.
        val onReady = d.nextStep(OuraTransition.Ready)
        assertEquals(OuraDriverPhase.Authenticating, d.phase)
        assertEquals(listOf("get_nonce", "get_firmware", "get_hardware"), onReady.map { it.label })
        assertArrayEquals(intArrayOf(0x2F, 0x01, 0x2B), onReady[0].bytes)

        // nonce -> submit proof.
        val nonce = bytes("0102030405060708090a0b0c0d0e0f")
        val onNonce = d.nextStep(OuraTransition.NonceReceived(nonce))
        assertEquals(1, onNonce.size)
        assertArrayEquals(intArrayOf(0x2F, 0x11, 0x2D), onNonce[0].bytes.copyOfRange(0, 3))
        // The proof body matches the known vector.
        assertArrayEquals(bytes("c49fb9e83c46087a555183a9dc511ee9"), onNonce[0].bytes.copyOfRange(3, onNonce[0].bytes.size))

        // auth success -> first live-HR step (read DHR status); CCCDs are already enabled by transport.
        val onAuth = d.nextStep(OuraTransition.AuthCompleted(OuraAuthStatus.SUCCESS))
        assertEquals(OuraDriverPhase.EnablingLiveHR, d.phase)
        assertEquals(listOf("dhr_read"), onAuth.map { it.label })
        assertArrayEquals(intArrayOf(0x2F, 0x02, 0x20, 0x02), onAuth[0].bytes)

        // ack 1 -> enable ; ack 2 -> subscribe ; ack 3 -> streaming (no more commands).
        val step2 = d.nextStep(OuraTransition.EnableAckReceived)
        assertEquals(listOf("dhr_enable"), step2.map { it.label })
        assertArrayEquals(intArrayOf(0x2F, 0x03, 0x22, 0x02, 0x03), step2[0].bytes)

        val step3 = d.nextStep(OuraTransition.EnableAckReceived)
        assertEquals(listOf("dhr_subscribe"), step3.map { it.label })
        assertArrayEquals(intArrayOf(0x2F, 0x03, 0x26, 0x02, 0x02), step3[0].bytes)

        val done = d.nextStep(OuraTransition.EnableAckReceived)
        assertTrue(done.isEmpty())
        assertEquals(OuraDriverPhase.Streaming, d.phase)
    }

    // MARK: - Honest pairing path when no key

    @Test
    fun testNoKeyDrivesNeedsKeyInstall() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null)
        val cmds = d.nextStep(OuraTransition.Ready)
        assertEquals(
            "without a key, collect only safe serial-free identity and never authenticate",
            listOf("get_firmware", "get_hardware"),
            cmds.map { it.label },
        )
        assertEquals(OuraDriverPhase.NeedsKeyInstall, d.phase)
    }

    @Test
    fun testRing4ReadyUsesOfficialReadOnlyPreAuthOrder() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN4, authKey = key)
        val commands = d.nextStep(OuraTransition.Ready)
        assertEquals(
            listOf(
                "get_firmware", "get_hardware",
                "ring4_pre_auth_session_00", "ring4_pre_auth_session_01", "get_nonce",
            ),
            commands.map { it.label },
        )
        assertArrayEquals(intArrayOf(0x2F, 0x02, 0x01, 0x00), commands[2].bytes)
        assertArrayEquals(intArrayOf(0x2F, 0x02, 0x01, 0x01), commands[3].bytes)
        assertArrayEquals(intArrayOf(0x2F, 0x01, 0x2B), commands[4].bytes)
    }

    @Test
    fun testFactoryResetStatusDrivesNeedsKeyInstall() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        d.nextStep(OuraTransition.Ready)
        val cmds = d.nextStep(OuraTransition.AuthCompleted(OuraAuthStatus.IN_FACTORY_RESET))
        assertTrue(cmds.isEmpty())
        assertEquals(OuraDriverPhase.NeedsKeyInstall, d.phase)
    }

    @Test
    fun testAuthErrorIsSurfacedNotRetriedBlindly() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        d.nextStep(OuraTransition.Ready)
        d.nextStep(OuraTransition.AuthCompleted(OuraAuthStatus.AUTH_ERROR))
        assertEquals(OuraDriverPhase.AuthFailed(OuraAuthStatus.AUTH_ERROR), d.phase)
    }

    // MARK: - Post-factory-reset key install sequencing (s3.2), gated on allowKeyInstall

    /**
     * With allowKeyInstall == true the adopt flow sequences NeedsKeyInstall -> InstallingKey ->
     * (on the 0x25 ack) re-auth, and the post-install re-auth uses the freshly-provisioned key. Kotlin
     * twin of the Swift testKeyInstallSequencesReauthWhenAllowed (same key, nonce, proof vector).
     */
    @Test
    fun testKeyInstallSequencesReauthWhenAllowed() {
        // No injected key -> the honest needs-pairing path; the transport will provision one.
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null, allowKeyInstall = true)
        val onReady = d.nextStep(OuraTransition.Ready)
        assertEquals(listOf("get_firmware", "get_hardware"), onReady.map { it.label })
        assertEquals(OuraDriverPhase.NeedsKeyInstall, d.phase)

        // The transport generates + persists a fresh 16-byte key and asks the driver for the install
        // command. It must be the DANGEROUS `24 10 <key>` write (s3.2) and advance to InstallingKey.
        val install = d.beginKeyInstall(key)
        assertTrue(install != null)
        assertEquals("DANGEROUS_install_key", install!!.label)
        assertArrayEquals(intArrayOf(0x24, 0x10) + key, install.bytes)
        assertEquals(OuraDriverPhase.InstallingKey, d.phase)

        // The ring acks with `25 01 00`; the transport calls back and the driver drives re-auth.
        val onAck = d.keyInstallAcknowledged()
        assertEquals(listOf("get_nonce"), onAck.map { it.label })
        assertArrayEquals(intArrayOf(0x2F, 0x01, 0x2B), onAck[0].bytes)
        assertEquals(OuraDriverPhase.Authenticating, d.phase)

        // Re-auth uses the freshly-installed key: the proof matches the known vector for that key.
        val nonce = bytes("0102030405060708090a0b0c0d0e0f")
        val onNonce = d.nextStep(OuraTransition.NonceReceived(nonce))
        assertEquals(1, onNonce.size)
        assertArrayEquals(intArrayOf(0x2F, 0x11, 0x2D), onNonce[0].bytes.copyOfRange(0, 3))
        assertArrayEquals(
            bytes("c49fb9e83c46087a555183a9dc511ee9"),
            onNonce[0].bytes.copyOfRange(3, onNonce[0].bytes.size),
        )
    }

    /**
     * With allowKeyInstall == false (the default) the driver MUST NOT sequence an install: it stays at
     * NeedsKeyInstall, emits no command, and a stray 0x25 ack cannot advance the flow.
     */
    @Test
    fun testNoKeyInstallSequencedWhenNotAllowed() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null)   // allowKeyInstall defaults to false
        d.nextStep(OuraTransition.Ready)
        assertEquals(OuraDriverPhase.NeedsKeyInstall, d.phase)

        val install = d.beginKeyInstall(key)
        assertTrue("no dangerous 0x24 write may be produced without an opt-in adopt flow", install == null)
        assertEquals(OuraDriverPhase.NeedsKeyInstall, d.phase)

        // A stray ack must be ignored too (no install was sequenced, so there is nothing to acknowledge).
        val onAck = d.keyInstallAcknowledged()
        assertTrue(onAck.isEmpty())
        assertEquals(OuraDriverPhase.NeedsKeyInstall, d.phase)
    }

    /**
     * Even with allowKeyInstall == true, beginKeyInstall only fires from NeedsKeyInstall; a call from
     * another phase is a no-op (the gate is BOTH the flag and the phase).
     */
    @Test
    fun testKeyInstallIgnoredOutsideNeedsKeyInstallPhase() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowKeyInstall = true)
        d.nextStep(OuraTransition.Ready)        // -> Authenticating (a real key is present)
        assertEquals(OuraDriverPhase.Authenticating, d.phase)
        assertTrue("install must not fire outside NeedsKeyInstall", d.beginKeyInstall(key) == null)
        assertEquals(OuraDriverPhase.Authenticating, d.phase)
    }

    // MARK: - History fetch loop

    @Test
    fun testRing4HistoryFetchWaitsForTimeSyncAckThenFlushesFetchesAndAcks() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN4, authKey = key, timeSyncToken = 0x5A)
        val start = d.nextStep(OuraTransition.StartHistoryFetch(cursor = 0L, unixSeconds = 256L))
        assertEquals(OuraDriverPhase.FetchingHistory, d.phase)
        assertEquals(
            listOf(
                "event_stream_enable", "sync_time", "ring4_post_sync_state",
                "event_category_14", "event_category_18", "event_category_28",
                "event_category_34", "event_category_04", "event_category_08",
                "get_battery", "ring4_param_read_02", "ring4_param_read_04",
                "ring4_history_session_mode",
                "ring4_param_read_0b", "ring4_param_read_0d", "ring4_param_read_03",
                "ring4_param_read_0b_again", "ring4_param_read_10",
            ),
            start.map { it.label },
        )
        assertArrayEquals(intArrayOf(0x16, 0x01, 0x02), start[0].bytes)
        assertArrayEquals(intArrayOf(0x1C, 0x01, 0xBF), start[2].bytes)
        assertArrayEquals(intArrayOf(0x12, 0x09), start[1].bytes.copyOfRange(0, 2))
        assertArrayEquals(intArrayOf(0x01, 0x00, 0x00), start[1].bytes.copyOfRange(3, 6))
        assertArrayEquals(intArrayOf(0x00, 0x00, 0x00, 0x00, 0xF6), start[1].bytes.copyOfRange(6, 11))
        val expectedCategoryFrames = listOf(
            intArrayOf(0x18, 0x03, 0x14, 0x00, 0x10),
            intArrayOf(0x18, 0x03, 0x18, 0x00, 0x10),
            intArrayOf(0x18, 0x03, 0x28, 0x00, 0x09),
            intArrayOf(0x18, 0x03, 0x34, 0x00, 0x04),
            intArrayOf(0x18, 0x03, 0x04, 0x00, 0x10),
            intArrayOf(0x18, 0x03, 0x08, 0x00, 0x10),
        )
        start.drop(3).zip(expectedCategoryFrames).forEach { (actual, expected) ->
            assertArrayEquals(expected, actual.bytes)
        }
        assertArrayEquals(intArrayOf(0x0C, 0x00), start[9].bytes)
        val expectedParameterReads = listOf(
            intArrayOf(0x2F, 0x02, 0x20, 0x02),
            intArrayOf(0x2F, 0x02, 0x20, 0x04),
            intArrayOf(0x2F, 0x02, 0x03, 0x01),
            intArrayOf(0x2F, 0x02, 0x20, 0x0B),
            intArrayOf(0x2F, 0x02, 0x20, 0x0D),
            intArrayOf(0x2F, 0x02, 0x20, 0x03),
            intArrayOf(0x2F, 0x02, 0x20, 0x0B),
            intArrayOf(0x2F, 0x02, 0x20, 0x10),
        )
        start.drop(10).zip(expectedParameterReads).forEach { (actual, expected) ->
            assertArrayEquals(expected, actual.bytes)
        }

        val fetch = d.nextStep(OuraTransition.TimeSyncAcknowledged(cursor = 0L))
        assertEquals(listOf("flush_buffer", "get_events"), fetch.map { it.label })
        assertTrue(d.nextStep(OuraTransition.TimeSyncAcknowledged(cursor = 0L)).isEmpty())
        assertTrue(d.nextStep(OuraTransition.TimeSyncReleaseTimedOut(cursor = 0L)).isEmpty())
        // get_events cursor 0, max 255, flags FFFFFFFF.
        assertArrayEquals(
            intArrayOf(0x10, 0x09, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF),
            fetch[1].bytes,
        )

        // More data -> ack-fetch (max 0) at the advanced cursor.
        val ack = d.nextStep(OuraTransition.HistoryCursorAdvanced(cursor = 0x12345678L, moreData = true))
        assertEquals(1, ack.size)
        assertArrayEquals(
            intArrayOf(0x10, 0x09, 0x78, 0x56, 0x34, 0x12, 0x00, 0xFF, 0xFF, 0xFF, 0xFF),
            ack[0].bytes,
        )

        // No more -> back to streaming.
        val stop = d.nextStep(OuraTransition.HistoryCursorAdvanced(cursor = 0x12345678L, moreData = false))
        assertTrue(stop.isEmpty())
        assertEquals(OuraDriverPhase.Streaming, d.phase)

        val nextPoll = d.nextStep(OuraTransition.StartHistoryFetch(cursor = 0x12345678L, unixSeconds = 512L))
        assertEquals(listOf("event_stream_enable", "sync_time"), nextPoll.map { it.label })
    }

    @Test
    fun ring4TimeSyncTimeout_releasesExactlyOneGuardedFetch() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN4, authKey = key, timeSyncToken = 0x5A)
        d.nextStep(OuraTransition.StartHistoryFetch(cursor = 7L, unixSeconds = 256L))
        val fetch = d.nextStep(OuraTransition.TimeSyncReleaseTimedOut(cursor = 7L))
        assertEquals(listOf("flush_buffer", "get_events"), fetch.map { it.label })
        val provisional = d.nextStep(OuraTransition.ContinueProvisionalHistory(cursor = 0x12345678L))
        assertEquals(listOf("get_events"), provisional.map { it.label })
        assertArrayEquals(
            intArrayOf(0x10, 0x09, 0x78, 0x56, 0x34, 0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF),
            provisional[0].bytes,
        )
        assertTrue(d.nextStep(OuraTransition.TimeSyncReleaseTimedOut(cursor = 7L)).isEmpty())
        assertTrue(d.nextStep(OuraTransition.TimeSyncAcknowledged(cursor = 7L)).isEmpty())
        assertTrue(!d.hasFreshAnchorForActiveFetch)
    }

    // MARK: - Ring-time -> UTC anchor (s5.5)

    /**
     * Little-endian bytes of the RAW 0x42 wire value the decoder reads into [OuraTimeSync.epochMs]. The
     * wire value is unix SECONDS (s6.11), despite the field's "epochMs" name (which reflects what
     * OURA_PROTOCOL.md s6.11 claims, not what the driver now does with it), so tests build this from a
     * seconds value. Byte-for-byte identical to the Swift OuraDriverTests `le8` helper.
     */
    private fun le8(v: Long): IntArray = IntArray(8) { ((v ushr (8 * it)) and 0xFFL).toInt() }

    @Test
    fun testNoAnchorBeforeAnyTimeSyncOrBeacon() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        assertNull(d.unixSeconds(forRingTimestamp = rt))
    }

    @Test
    fun persistedPrimaryAnchorMapsImmediatelyButNeedsHistoryContinuityForCommit() {
        val anchor = OuraTimeAnchor(
            ringTimestamp = 10_000L,
            utcMilliseconds = 1_700_000_000_000L,
            factorMillisecondsPerTick = 100L,
        )
        val d = OuraDriver(
            ringGen = OuraRingGen.GEN4,
            authKey = key,
            persistedPrimaryAnchor = anchor,
            durableCursor = 10_100L,
            timeSyncToken = 0x5A,
        )
        assertEquals(anchor, d.currentPrimaryAnchor)
        assertEquals(1_700_000_010L, d.unixSeconds(forRingTimestamp = 10_100L))

        d.nextStep(OuraTransition.StartHistoryFetch(cursor = 10_100L, unixSeconds = 1_700_000_000L))
        assertTrue("a loaded mapping alone must never authorize ACK", !d.activeFetchCommitAuthorized)

        // A structurally valid record below the durable cursor cannot qualify continuity.
        d.ingest(OuraRecord(OuraEventTag.STATE_CHANGE.raw, 10_099L, intArrayOf(1)))
        assertTrue(!d.activeFetchCommitAuthorized)
        // Reaching both the durable cursor and anchor proves this ring-time sequence is continuous.
        d.ingest(OuraRecord(OuraEventTag.STATE_CHANGE.raw, 10_100L, intArrayOf(1)))
        assertTrue(d.activeFetchCommitAuthorized)
    }

    @Test
    fun persistedAnchorValidationRejectsMalformedTriples() {
        val invalid = listOf(
            OuraTimeAnchor(0L, 1_700_000_000_000L, 100L),
            OuraTimeAnchor(1L, 1_500_000_000_000L, 100L),
            OuraTimeAnchor(1L, 1_700_000_000_000L, 10L),
        )
        for (candidate in invalid) {
            val d = OuraDriver(
                ringGen = OuraRingGen.GEN4,
                authKey = key,
                persistedPrimaryAnchor = candidate,
                durableCursor = 1L,
            )
            assertNull(candidate.toString(), d.currentPrimaryAnchor)
            assertNull(candidate.toString(), d.unixSeconds(forRingTimestamp = 1L))
        }
    }

    @Test
    fun nonRing4DriverNeverImportsOrExportsReconnectDurableAnchor() {
        val anchor = OuraTimeAnchor(1_000L, 1_700_000_000_000L, 100L)
        val d = OuraDriver(
            ringGen = OuraRingGen.GEN3,
            authKey = key,
            persistedPrimaryAnchor = anchor,
            durableCursor = 1_000L,
        )

        assertNull(d.currentPrimaryAnchor)
        assertNull(d.unixSeconds(forRingTimestamp = 1_000L))
    }

    @Test
    fun persistedAnchorPreservesNormalAndBurstFactorsAcrossDriverRecreation() {
        val normal = OuraDriver(
            ringGen = OuraRingGen.GEN4,
            authKey = key,
            persistedPrimaryAnchor = OuraTimeAnchor(1_000L, 1_700_000_000_000L, 100L),
            durableCursor = 1_000L,
        )
        val burst = OuraDriver(
            ringGen = OuraRingGen.GEN4,
            authKey = key,
            persistedPrimaryAnchor = OuraTimeAnchor(1_000L, 1_700_000_000_000L, 1L),
            durableCursor = 1_000L,
        )
        assertEquals(1_700_000_001L, normal.unixSeconds(forRingTimestamp = 1_010L))
        assertEquals(1_700_000_001L, burst.unixSeconds(forRingTimestamp = 2_000L))
    }

    @Test
    fun persistedAnchorRegressionInvalidatesMappingAndCommitAuthority() {
        val anchor = OuraTimeAnchor(10_000L, 1_700_000_000_000L, 100L)
        val d = OuraDriver(
            ringGen = OuraRingGen.GEN4,
            authKey = key,
            persistedPrimaryAnchor = anchor,
            durableCursor = 10_100L,
        )
        d.nextStep(OuraTransition.StartHistoryFetch(cursor = 10_100L, unixSeconds = 1_700_000_000L))
        d.ingest(OuraRecord(OuraEventTag.RING_START.raw, 5L, intArrayOf()))
        assertNull(d.currentPrimaryAnchor)
        assertNull(d.unixSeconds(forRingTimestamp = 10_100L))
        assertTrue(!d.activeFetchCommitAuthorized)
        assertTrue(d.consumePersistentStateInvalidation())
        assertTrue(!d.consumePersistentStateInvalidation())
    }

    @Test
    fun terminalHighWaterBelowDurableCursorInvalidatesPersistedState() {
        val d = OuraDriver(
            ringGen = OuraRingGen.GEN4,
            authKey = key,
            persistedPrimaryAnchor = OuraTimeAnchor(500L, 1_700_000_000_000L, 100L),
            durableCursor = 1_000L,
        )
        d.nextStep(OuraTransition.StartHistoryFetch(cursor = 1_000L, unixSeconds = 1_700_000_000L))
        d.ingest(OuraRecord(OuraEventTag.STATE_CHANGE.raw, 900L, intArrayOf(1)))
        assertTrue(d.invalidatePersistedStateIfHistoryRegressed())
        assertTrue(d.consumePersistentStateInvalidation())
        assertNull(d.currentPrimaryAnchor)
    }

    @Test
    fun testSyncTimeResponseIsAckOnlyAndDoesNotAnchor() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN4, authKey = key, timeSyncToken = 0x5A)
        val requested = 1_800_000_123L
        d.nextStep(OuraTransition.StartHistoryFetch(cursor = 0L, unixSeconds = requested))
        val counter = requested / 256L
        val body = intArrayOf(
            0x00, (counter and 0xFF).toInt(), ((counter shr 8) and 0xFF).toInt(),
            ((counter shr 16) and 0xFF).toInt(), 0x00,
        )
        val response = OuraFraming.parseSyncTimeResponse(body)
        assertEquals(0, response?.ackCode)
        assertEquals(counter, response?.counterEcho)
        assertTrue(d.handleSyncTimeAcknowledgement(body))
        val nonZeroStatus = body.copyOf().also { it[0] = 0x7F }
        assertTrue(d.handleSyncTimeAcknowledgement(nonZeroStatus))
        assertTrue(d.handleSyncTimeAcknowledgement(intArrayOf(0x00, 0x01, 0x02, 0x03, 0x00)))
        assertTrue(!d.handleSyncTimeAcknowledgement(intArrayOf(0x00, 0x01)))
        assertNull(d.unixSeconds(forRingTimestamp = 1_000L))
        assertTrue(!d.hasUtcAnchor)
    }

    @Test
    fun testTimeSyncSetsAnchorAndConvertsPastAndFutureRingTimes() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val anchorEpochSeconds = 1_700_000_000L   // the wire's raw value (seconds, not ms)
        val anchorRt = 10_000L
        val payload = le8(anchorEpochSeconds) + intArrayOf(0x00)   // raw wire epoch (8B) + tz offset (0 half-hours)
        val rec = OuraRecord(type = OuraEventTag.TIME_SYNC.raw, ringTimestamp = anchorRt, payload = payload)
        val events = d.ingest(rec)
        assertEquals(
            listOf(
                OuraEvent.TimeSyncEvent(
                    OuraTimeSync(ringTimestamp = anchorRt, epochMs = anchorEpochSeconds, tzOffsetSeconds = 0),
                ),
            ),
            events,
        )

        // Exactly at the anchor: the driver applies the x1000 seconds->ms correction internally, so
        // unixSeconds recovers the ORIGINAL seconds value.
        assertEquals(anchorEpochSeconds, d.unixSeconds(forRingTimestamp = anchorRt))
        // 100 ticks (10s at the default 100ms/tick) BEFORE the anchor -> 10s earlier (a past/historical
        // record, e.g. from a GetEvents history fetch).
        assertEquals(anchorEpochSeconds - 10, d.unixSeconds(forRingTimestamp = anchorRt - 100))
        // 100 ticks AFTER the anchor -> 10s later.
        assertEquals(anchorEpochSeconds + 10, d.unixSeconds(forRingTimestamp = anchorRt + 100))
    }

    @Test
    fun testRing4TimeSyncSetsNormalAndBurstClockFactors() {
        val epochSeconds = 1_700_000_000L
        val counter = epochSeconds / 256L
        fun payload(token: Int) = intArrayOf(
            token, (counter and 0xFF).toInt(), ((counter shr 8) and 0xFF).toInt(),
            ((counter shr 16) and 0xFF).toInt(), 0, 0, 0, 0, 0xF6,
        )

        val normal = OuraDriver(ringGen = OuraRingGen.GEN4, authKey = key, timeSyncToken = 0x00)
        normal.nextStep(OuraTransition.StartHistoryFetch(cursor = 0L, unixSeconds = epochSeconds))
        normal.ingest(OuraRecord(OuraEventTag.TIME_SYNC.raw, 10_000L, payload(0x00)))
        assertEquals(epochSeconds + 1, normal.unixSeconds(forRingTimestamp = 10_010L))
        assertEquals(
            OuraTimeAnchor(10_000L, epochSeconds * 1_000L, 100L),
            normal.currentPrimaryAnchor,
        )

        val burst = OuraDriver(ringGen = OuraRingGen.GEN4, authKey = key, timeSyncToken = 0xFD)
        burst.nextStep(OuraTransition.StartHistoryFetch(cursor = 0L, unixSeconds = epochSeconds))
        burst.ingest(OuraRecord(OuraEventTag.TIME_SYNC.raw, 20_000L, payload(0xFD)))
        assertEquals(epochSeconds + 1, burst.unixSeconds(forRingTimestamp = 21_000L))
        assertEquals(
            OuraTimeAnchor(20_000L, epochSeconds * 1_000L, 1L),
            burst.currentPrimaryAnchor,
        )
    }

    @Test
    fun testRing4RejectsStaleAnchorAndRingStartRegressionClearsFreshAnchor() {
        val requested = 1_700_000_000L
        fun payload(epochSeconds: Long, token: Int): IntArray {
            val counter = epochSeconds / 256L
            return intArrayOf(
                token, (counter and 0xFF).toInt(), ((counter shr 8) and 0xFF).toInt(),
                ((counter shr 16) and 0xFF).toInt(), 0, 0, 0, 0, 0xF6,
            )
        }

        val d = OuraDriver(ringGen = OuraRingGen.GEN4, authKey = key, timeSyncToken = 0x5A)
        d.nextStep(OuraTransition.StartHistoryFetch(cursor = 0L, unixSeconds = requested))
        d.ingest(OuraRecord(OuraEventTag.TIME_SYNC.raw, 9_000L, payload(requested - 256L, 0x5A)))
        assertTrue("a plausible stale anchor must not match the active request", !d.hasUtcAnchor)

        d.ingest(OuraRecord(OuraEventTag.TIME_SYNC.raw, 10_000L, payload(requested, 0x01)))
        assertTrue(!d.hasUtcAnchor)
        d.ingest(OuraRecord(OuraEventTag.TIME_SYNC.raw, 10_001L, payload(requested, 0x5A)))
        assertTrue(d.hasUtcAnchor)
        assertTrue(d.hasFreshAnchorForActiveFetch)
        d.ingest(OuraRecord(OuraEventTag.RING_START.raw, 1L, intArrayOf()))
        assertTrue(!d.hasUtcAnchor)
        assertNull(d.unixSeconds(forRingTimestamp = 10_000L))
    }

    @Test
    fun testRing4BoundedBootstrapAcceptsHistoricalAnchorThenRefetchesDurableCursor() {
        val requested = 1_700_000_000L
        val historical = requested - 256L
        val counter = historical / 256L
        val payload = intArrayOf(
            0x11, (counter and 0xFF).toInt(), ((counter shr 8) and 0xFF).toInt(),
            ((counter shr 16) and 0xFF).toInt(), 0, 0, 0, 0, 0xF6,
        )
        val d = OuraDriver(ringGen = OuraRingGen.GEN4, authKey = key, timeSyncToken = 0x5A)
        d.nextStep(OuraTransition.StartHistoryFetch(cursor = 77L, unixSeconds = requested))
        d.enableHistoricalAnchorBootstrap()
        d.ingest(OuraRecord(OuraEventTag.TIME_SYNC.raw, 9_000L, payload))
        assertTrue(d.hasFreshAnchorForActiveFetch)
        val restart = d.nextStep(OuraTransition.RestartHistoryFromBootstrap(cursor = 77L))
        assertEquals(listOf("flush_buffer", "get_events"), restart.map { it.label })
        assertArrayEquals(
            intArrayOf(0x10, 0x09, 0x4D, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF),
            restart[1].bytes,
        )
        assertTrue(d.hasFreshAnchorForActiveFetch)
        assertNull(d.activeHistoryHighWater)
    }

    @Test
    fun newPostFetchSyncRequiresFreshCorrelationAfterHistoricalBootstrapMode() {
        val requested = 1_700_000_000L
        val stale = requested - 256L
        fun payload(epochSeconds: Long): IntArray {
            val counter = epochSeconds / 256L
            return intArrayOf(
                0x11, (counter and 0xFF).toInt(), ((counter shr 8) and 0xFF).toInt(),
                ((counter shr 16) and 0xFF).toInt(), 0, 0, 0, 0, 0xF6,
            )
        }
        val d = OuraDriver(ringGen = OuraRingGen.GEN4, authKey = key, timeSyncToken = 0x5A)
        d.nextStep(OuraTransition.StartHistoryFetch(cursor = 0L, unixSeconds = requested))
        d.enableHistoricalAnchorBootstrap()

        // The delayed/high-water retry starts a new SyncTime request and must close historical acceptance.
        d.nextStep(OuraTransition.StartHistoryFetch(cursor = 9_000L, unixSeconds = requested))
        d.ingest(OuraRecord(OuraEventTag.TIME_SYNC.raw, 9_001L, payload(stale)))
        assertNull("the retry must wait for its newly-correlated 0x42", d.currentPrimaryAnchor)
        assertTrue(!d.activeFetchCommitAuthorized)
    }

    @Test
    fun testHistoryHighWaterUsesEveryValidInnerRecordAndStartsEmpty() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN4, authKey = key, timeSyncToken = 0x5A)
        d.nextStep(OuraTransition.StartHistoryFetch(cursor = 0L, unixSeconds = 1_700_000_000L))
        assertNull(d.activeHistoryHighWater)
        d.ingest(OuraRecord(type = 0x99, ringTimestamp = 10L, payload = intArrayOf()))
        d.ingest(OuraRecord(type = OuraEventTag.STATE_CHANGE.raw, ringTimestamp = 42L,
                            payload = intArrayOf(1)))
        d.ingest(OuraRecord(type = 0x13, ringTimestamp = 999L, payload = intArrayOf()))
        assertEquals(42L, d.activeHistoryHighWater)
    }

    @Test
    fun testRing4RecentRtcBeaconQualifiesActiveFetchWhenFirmwareOmitsTimeSyncRecord() {
        val requested = 1_700_000_000L
        val beaconSeconds = requested - 8L * 60L * 60L
        val payload = intArrayOf(
            (beaconSeconds and 0xFF).toInt(), ((beaconSeconds shr 8) and 0xFF).toInt(),
            ((beaconSeconds shr 16) and 0xFF).toInt(), ((beaconSeconds shr 24) and 0xFF).toInt(),
        )
        val d = OuraDriver(ringGen = OuraRingGen.GEN4, authKey = key, timeSyncToken = 0x5A)
        d.nextStep(OuraTransition.StartHistoryFetch(cursor = 77L, unixSeconds = requested))
        d.ingest(OuraRecord(OuraEventTag.RTC_BEACON.raw, 5_000L, payload))

        assertTrue(d.hasFreshAnchorForActiveFetch)
        assertEquals(OuraTimeAnchor(5_000L, beaconSeconds * 1_000L, 100L), d.currentPrimaryAnchor)
        assertEquals(beaconSeconds + 1L, d.unixSeconds(forRingTimestamp = 5_010L))
    }

    @Test
    fun testRing4StaleRtcBeaconCannotAuthorizeActiveFetch() {
        val requested = 1_700_000_000L
        val beaconSeconds = requested - 3L * 24L * 60L * 60L
        val payload = intArrayOf(
            (beaconSeconds and 0xFF).toInt(), ((beaconSeconds shr 8) and 0xFF).toInt(),
            ((beaconSeconds shr 16) and 0xFF).toInt(), ((beaconSeconds shr 24) and 0xFF).toInt(),
        )
        val d = OuraDriver(ringGen = OuraRingGen.GEN4, authKey = key, timeSyncToken = 0x5A)
        d.nextStep(OuraTransition.StartHistoryFetch(cursor = 77L, unixSeconds = requested))
        d.ingest(OuraRecord(OuraEventTag.RTC_BEACON.raw, 5_000L, payload))

        assertTrue(!d.hasFreshAnchorForActiveFetch)
        assertNull(d.currentPrimaryAnchor)
    }

    @Test
    fun testRtcBeaconOnlyAnchorsWhenNoTimeSyncSeenYet() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val beaconRt = 5_000L
        val beaconUnixSeconds = 1_700_000_500L
        // 0x85 rtc_beacon_ind: unix_s u32 LE + trailer (payload just needs >= 4 bytes).
        val beaconPayload = intArrayOf(
            (beaconUnixSeconds and 0xFF).toInt(), ((beaconUnixSeconds shr 8) and 0xFF).toInt(),
            ((beaconUnixSeconds shr 16) and 0xFF).toInt(), ((beaconUnixSeconds shr 24) and 0xFF).toInt(),
        )
        val beaconRec = OuraRecord(type = OuraEventTag.RTC_BEACON.raw, ringTimestamp = beaconRt, payload = beaconPayload)
        d.ingest(beaconRec)
        assertEquals(beaconUnixSeconds, d.unixSeconds(forRingTimestamp = beaconRt))
        assertNull("a secondary 0x85 must never become durable primary state", d.currentPrimaryAnchor)

        // A later, more precise 0x42 time-sync must override the coarser beacon anchor.
        val syncEpochSeconds = 1_700_001_000L
        val syncRt = 6_000L
        val syncPayload = le8(syncEpochSeconds) + intArrayOf(0x00)
        val syncRec = OuraRecord(type = OuraEventTag.TIME_SYNC.raw, ringTimestamp = syncRt, payload = syncPayload)
        d.ingest(syncRec)
        assertEquals(syncEpochSeconds, d.unixSeconds(forRingTimestamp = syncRt))

        // A SECOND beacon after a time-sync anchor is already set must NOT override it (secondary only
        // fills a gap, never displaces the primary source).
        val laterBeaconRec = OuraRecord(
            type = OuraEventTag.RTC_BEACON.raw, ringTimestamp = syncRt + 100, payload = beaconPayload,
        )
        d.ingest(laterBeaconRec)
        assertEquals(
            "a later RTC beacon must not displace an already-set time-sync anchor",
            syncEpochSeconds, d.unixSeconds(forRingTimestamp = syncRt),
        )
    }

    @Test
    fun testStopClearsTheAnchor() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val payload = le8(1_700_000_000L) + intArrayOf(0x00)
        val rec = OuraRecord(type = OuraEventTag.TIME_SYNC.raw, ringTimestamp = 1_000L, payload = payload)
        d.ingest(rec)
        assertNotNull(d.unixSeconds(forRingTimestamp = 1_000L))
        d.stop()
        assertNull("a stale anchor must not survive stop()/a new session", d.unixSeconds(forRingTimestamp = 1_000L))
    }

    /**
     * Regression test for the crash-safety rule (s6.11): a full cursor=0 history dump can hit a 0x42
     * record deep in the backlog with an implausible raw value that would overflow Long on the naive
     * seconds->ms `* 1000` conversion. The plausibility gate must reject it WITHOUT crashing and WITHOUT
     * setting a garbage anchor. Kotlin twin of Swift's testImplausibleTimeSyncNeverCrashesOrAnchors.
     */
    @Test
    fun testImplausibleTimeSyncNeverCrashesOrAnchors() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val hugePayload = le8(Long.MAX_VALUE) + intArrayOf(0x00)   // the exact class of value that overflows the multiply
        val hugeRec = OuraRecord(type = OuraEventTag.TIME_SYNC.raw, ringTimestamp = 1_000L, payload = hugePayload)
        d.ingest(hugeRec)   // must not throw
        assertNull("an implausible epoch must never become the anchor", d.unixSeconds(forRingTimestamp = 1_000L))

        // A negative epoch (int64 sign bit set on a misaligned record) must be equally rejected.
        val negativePayload = le8(-1L) + intArrayOf(0x00)
        val negativeRec = OuraRecord(type = OuraEventTag.TIME_SYNC.raw, ringTimestamp = 2_000L, payload = negativePayload)
        d.ingest(negativeRec)   // must not throw
        assertNull(d.unixSeconds(forRingTimestamp = 2_000L))

        // A GOOD time-sync arriving afterward must still anchor normally (the gate doesn't wedge the driver).
        val goodPayload = le8(1_700_000_000L) + intArrayOf(0x00)
        val goodRec = OuraRecord(type = OuraEventTag.TIME_SYNC.raw, ringTimestamp = 3_000L, payload = goodPayload)
        d.ingest(goodRec)
        assertEquals(1_700_000_000L, d.unixSeconds(forRingTimestamp = 3_000L))
    }

    // MARK: - ingest(record:) decoding

    @Test
    fun testIngestDecodesTierARecord() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        // 0x7B SpO2 stable record -> one spo2 event (970, BE).
        val rec = OuraFraming.parseRecord(bytes("7b060200010003ca"))!!
        val events = d.ingest(rec)
        assertEquals(
            listOf(OuraEvent.Spo2(OuraSpO2(ringTimestamp = rt, value = 970, unit = "tenths_percent"))),
            events,
        )
    }

    @Test
    fun testIngestUnknownTagYieldsNothing() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        // 0x99 is not in the dictionary -> [] (never a guessed value).
        val rec = OuraRecord(type = 0x99, ringTimestamp = rt, payload = intArrayOf(0x01, 0x02))
        assertEquals(emptyList<OuraEvent>(), d.ingest(rec))
    }

    @Test
    fun testUnknownOuterOpcodeCannotChangeLivePushRingTime() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val valid = OuraFraming.parseRecord(bytes("420d0200010000d2dd639001000002"))!!
        d.ingest(valid)
        d.ingest(OuraRecord(type = 0x13, ringTimestamp = 0xDEAD_BEEFL, payload = intArrayOf()))

        val events = d.ingestLiveHRPush(bytes("020002000001040000000000007f"))
        assertEquals(OuraEvent.Hr(OuraHR(ringTimestamp = rt, bpm = 59, ibiMs = 1025)), events.first())
    }

    // MARK: - Tier-B gating

    @Test
    fun testTierBDroppedByDefault() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)   // allowTierB defaults to false
        // 0x49 sleep_summary_1 is Tier B (UNVERIFIED).
        val rec = OuraFraming.parseRecord(bytes("49080200010001020304"))!!
        assertEquals(
            "Tier-B must not feed values when not explicitly allowed",
            emptyList<OuraEvent>(),
            d.ingest(rec),
        )
    }

    @Test
    fun testTierBEmittedOnlyWhenAllowed() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        val rec = OuraFraming.parseRecord(bytes("49080200010001020304"))!!
        val events = d.ingest(rec)
        assertEquals(1, events.size)
        assertTrue(events[0].isTierB)
        val ev = events[0]
        assertTrue("expected a tierB event", ev is OuraEvent.TierB)
        ev as OuraEvent.TierB
        assertEquals(0x49, ev.value.tag)
        assertEquals("sleep_summary", ev.value.kind)
        assertArrayEquals(bytes("01020304"), ev.value.rawPayload)
    }

    // MARK: - Activity info (0x50, Tier B, third-party formula) - real Gen 3 captures (PR #960)
    //
    // PARITY: the six payloads below are byte-for-byte the real Gen 3 captures pinned in the Swift
    // OuraDriverTests (PR #960 investigation, 2026-07-02): three short static captures, then a full day
    // from steady resting (~0.9 MET) through a vigorous-activity burst (7.4 MET). The ringTimestamp was
    // not part of the captures, so the fixture `rt` stamps them - the pinned evidence is the decoded
    // state/MET values, each RECOMPUTED from the s6.13 formula (met = byte*0.1 below 0x80), not copied
    // blind (the v8.0.1 Oura SpO2 bug was a wrong-decode that asserted constants would have hidden).

    @Test
    fun testActivityInfoDecodesRealCapture1() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        // Raw payload 41 12 13 13 20: state 0x41=65; MET 18*0.1, 19*0.1, 19*0.1, 32*0.1.
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("4112131320"))
        val events = d.ingest(rec)
        assertEquals(
            listOf<OuraEvent>(
                OuraEvent.ActivityInfo(
                    OuraActivityInfo(ringTimestamp = rt, state = 0x41, met = listOf(1.8, 1.9, 1.9, 3.2)),
                ),
            ),
            events,
        )
        assertTrue("activityInfo must still report isTierB - the formula is UNVERIFIED", events[0].isTierB)
    }

    @Test
    fun testActivityInfoDecodesRealCapture2() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        // Raw payload 37 21 17 0e 0e 0d 0f 11: state 0x37=55; MET 3.3, 2.3, 1.4, 1.4, 1.3, 1.5, 1.7.
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("3721170e0e0d0f11"))
        assertEquals(
            listOf<OuraEvent>(
                OuraEvent.ActivityInfo(
                    OuraActivityInfo(ringTimestamp = rt, state = 0x37,
                                     met = listOf(3.3, 2.3, 1.4, 1.4, 1.3, 1.5, 1.7)),
                ),
            ),
            d.ingest(rec),
        )
    }

    @Test
    fun testActivityInfoDecodesRealCapture3() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        // Raw payload 4a 19 20 0e 18: state 0x4a=74; MET 2.5, 3.2, 1.4, 2.4.
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("4a19200e18"))
        assertEquals(
            listOf<OuraEvent>(
                OuraEvent.ActivityInfo(
                    OuraActivityInfo(ringTimestamp = rt, state = 0x4a, met = listOf(2.5, 3.2, 1.4, 2.4)),
                ),
            ),
            d.ingest(rec),
        )
    }

    @Test
    fun testActivityInfoDecodesRealCapture4Resting() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        // Full-day session, steady resting: state 0, MET 1.1 then 12 x 0.9 (bytes 0x0B, 0x09 x 12).
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("000b090909090909090909090909"))
        assertEquals(
            listOf<OuraEvent>(
                OuraEvent.ActivityInfo(
                    OuraActivityInfo(ringTimestamp = rt, state = 0,
                                     met = listOf(1.1, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9)),
                ),
            ),
            d.ingest(rec),
        )
    }

    @Test
    fun testActivityInfoDecodesRealCapture5ModerateActivity() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        // Light/moderate period: state 0x2E=46, 13 MET samples 1.2-2.3.
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("2e1711110e0d110d0d0d0e0e0c13"))
        assertEquals(
            listOf<OuraEvent>(
                OuraEvent.ActivityInfo(
                    OuraActivityInfo(ringTimestamp = rt, state = 46,
                                     met = listOf(2.3, 1.7, 1.7, 1.4, 1.3, 1.7, 1.3, 1.3, 1.3, 1.4, 1.4, 1.2, 1.9)),
                ),
            ),
            d.ingest(rec),
        )
    }

    @Test
    fun testActivityInfoDecodesRealCapture6ExerciseBurst() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        // Vigorous burst: state 0x8B=139 (high bit set on the STATE byte, which is NOT MET-encoded),
        // MET 1.8 and 7.4 (0x4A=74 -> 7.4, the highest real value seen). Also the shortest real payload
        // (2 samples), consistent with more frequent flushes during a high-variability period.
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("8b124a"))
        assertEquals(
            listOf<OuraEvent>(
                OuraEvent.ActivityInfo(
                    OuraActivityInfo(ringTimestamp = rt, state = 139, met = listOf(1.8, 7.4)),
                ),
            ),
            d.ingest(rec),
        )
    }

    @Test
    fun testActivityInfoHighByteBranchUsesCoarseSlope() {
        // No real capture has hit the >= 0x80 MET branch yet (nothing above 7.4 MET seen), so pin it
        // with SYNTHETIC vectors recomputed from the s6.13 formula: met = 12.8 + (byte - 128) * 0.2.
        //   0x80 = 128 -> 12.8  |  0x90 = 144 -> 12.8 + 16*0.2 = 16.0  |  0xFF = 255 -> 12.8 + 127*0.2 = 38.2
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("018090ff"))
        assertEquals(
            OuraActivityInfo(ringTimestamp = rt, state = 1, met = listOf(12.8, 16.0, 38.2)),
            OuraDecoders.decodeActivityInfo(rec),
        )
    }

    @Test
    fun testActivityInfoDroppedByDefaultLikeOtherTierB() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)   // allowTierB defaults to false
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("4112131320"))
        assertEquals(
            "the Tier-B gate must cover ActivityInfo too",
            emptyList<OuraEvent>(),
            d.ingest(rec),
        )
    }

    @Test
    fun testActivityInfoEmptyPayloadDecodesToNull() {
        // No state byte at all -> honest null, never a guessed state.
        assertNull(
            OuraDecoders.decodeActivityInfo(
                OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt, payload = intArrayOf()),
            ),
        )
    }

    // MARK: - Live-HR push routing + decode

    @Test
    fun testHandleSecureFrameRoutesNonceStatusAndPush() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val nonceFrame = OuraSecureFrame(subop = 0x2C, subBody = bytes("0102030405060708090a0b0c0d0e0f"))
        assertEquals(
            OuraDriver.SecureRouting.Nonce(bytes("0102030405060708090a0b0c0d0e0f")),
            d.handleSecureFrame(nonceFrame),
        )

        val statusFrame = OuraSecureFrame(subop = 0x2E, subBody = intArrayOf(0x00))
        assertEquals(OuraDriver.SecureRouting.AuthStatus(OuraAuthStatus.SUCCESS), d.handleSecureFrame(statusFrame))

        val ackFrame = OuraSecureFrame(subop = 0x23, subBody = intArrayOf(0x02, 0x00))
        assertEquals(OuraDriver.SecureRouting.EnableAck, d.handleSecureFrame(ackFrame))

        // s5.6 step 1: the dhr_read feature-read ACK (`2f 06 21 02 01 11 02 00`) is subop 0x21 with body
        // `02 01 11 02 00`. It must route to EnableAck or the enable triplet stalls at step 0 (#900).
        val dhrReadAck = OuraSecureFrame(subop = 0x21, subBody = bytes("0201110200"))
        assertEquals(OuraDriver.SecureRouting.EnableAck, d.handleSecureFrame(dhrReadAck))

        val spo2Status = OuraSecureFrame(subop = 0x21, subBody = bytes("0401000000"))
        assertEquals(
            OuraDriver.SecureRouting.FeatureStatus(OuraFeatureStatus(0x04, 0x01, 0, 0, 0)),
            d.handleSecureFrame(spo2Status),
        )

        // The push subBody is the 14 bytes AFTER `2f 0f 28` from the s5.6 wire frame (IBI at [5..6]).
        val pushBody = bytes("020002000001040000000000007f")
        assertEquals(14, pushBody.size)
        assertEquals(
            OuraDriver.SecureRouting.LiveHRPush(pushBody),
            d.handleSecureFrame(OuraSecureFrame(subop = 0x28, subBody = pushBody)),
        )
    }

    @Test
    fun testLiveHRPushIngestStampsLastRingTime() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        // Ingest a TLV record first so the driver learns a ring time to stamp the push with.
        val rec = OuraFraming.parseRecord(bytes("420d0200010000d2dd639001000002"))!!
        d.ingest(rec)
        // The push body is the 14-byte s5.6 subBody (after `2f 0f 28`); IBI at [5..6] = 01 04 -> 1025 ms.
        val push = bytes("020002000001040000000000007f")
        val events = d.ingestLiveHRPush(push)
        assertEquals(
            listOf(
                OuraEvent.Hr(OuraHR(ringTimestamp = rt, bpm = 59, ibiMs = 1025)),
                OuraEvent.Ibi(OuraIBI(ringTimestamp = rt, ibiMs = 1025)),
            ),
            events,
        )
    }

    // MARK: - Notification-level ingest via reassembler

    @Test
    fun testIngestNotificationReassemblesAndDecodes() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val reassembler = OuraReassembler()
        // Two records packed together: 0x7B SpO2 then 0x46 temp.
        val value = bytes("7b060200010003ca" + "460802000100420e470e")
        val events = d.ingest(notification = value, reassembler = reassembler)
        // 36.50 and 36.55 are computed identically (IEEE-754 Int/100.0) in both ports.
        assertEquals(3, events.size)
        assertEquals(
            OuraEvent.Spo2(OuraSpO2(ringTimestamp = rt, value = 970, unit = "tenths_percent")),
            events[0],
        )
        assertTrue(events[1] is OuraEvent.Temp)
        assertEquals(36.50, (events[1] as OuraEvent.Temp).value.celsius, 1e-9)
        assertEquals(36.55, (events[2] as OuraEvent.Temp).value.celsius, 1e-9)
    }

    // MARK: - Generation-driven command set / MTU

    @Test
    fun testRingGenMtuAndCaps() {
        assertEquals(203, OuraRingGen.GEN3.mtu)
        assertEquals(247, OuraRingGen.GEN5.mtu)
        assertTrue(OuraRingGen.GEN4.hasExtraNotifyChars)
        assertTrue(OuraRingGen.GEN5.hasExtraNotifyChars)
        assertTrue(!OuraRingGen.GEN3.hasExtraNotifyChars)
        assertEquals(5, OuraGatt.characteristicUUIDs(OuraRingGen.GEN4).size)
        assertEquals(OuraRingGen.GEN5, OuraRingGen.from("Oura Ring 5"))
        assertEquals(OuraRingGen.GEN3, OuraRingGen.from("Oura Ring 3"))
        assertEquals(OuraRingGen.GEN4, OuraRingGen.recognise("Oura Ring 4"))
        assertEquals(OuraRingGen.GEN5, OuraRingGen.recognise("Oura Gen 5"))
        assertEquals(null, OuraRingGen.recognise("Oura 9051280476123456"))
        assertTrue(OuraRingGen.GEN3.capabilities.contains(OuraMetric.HRV))
    }

    @Test
    fun testSyncTimeCommandCounter() {
        // counter = floor(unix / 256). For unix = 256 -> counter 1 -> bytes 01 00 00, trailer 0xF6.
        val cmd = OuraCommands.syncTime(unixSeconds = 256L, token = 0)
        assertArrayEquals(
            intArrayOf(0x12, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF6),
            cmd.bytes,
        )
    }

    // MARK: - Dangerous commands are isolated and labelled

    @Test
    fun testDangerousCommandsAreClearlyNamed() {
        assertArrayEquals(intArrayOf(0x0E, 0x01, 0xFF), OuraDangerousCommands.softReset().bytes)
        assertTrue(OuraDangerousCommands.softReset().label.startsWith("DANGEROUS_"))
        assertTrue(OuraDangerousCommands.factoryReset().label.startsWith("DANGEROUS_"))
        // The normal command builders never produce a reboot/reset opcode.
        assertTrue(OuraCommands.getBattery().bytes[0] != 0x0E)
        assertTrue(OuraCommands.getBattery().bytes[0] != 0x1A)
    }

    @Test
    fun testAutomaticSpO2CommandsAreByteExactAndExplicitlyNamed() {
        assertArrayEquals(intArrayOf(0x2F, 0x02, 0x20, 0x04), OuraCommands.spO2ReadStatus().bytes)
        assertArrayEquals(
            intArrayOf(0x2F, 0x03, 0x22, 0x04, 0x01),
            OuraCommands.spO2EnableAutomatic().bytes,
        )
        assertEquals("spo2_enable_automatic", OuraCommands.spO2EnableAutomatic().label)
    }
}
