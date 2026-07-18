package com.noop.oura

import java.security.SecureRandom

// Commands: byte-exact opcode builders (OURA_PROTOCOL.md s4 / s5). Kotlin twin of Commands.swift.
// Pure functions returning the wire bytes to write to ...0002. The live-HR enable path (s5.6) is the
// feature-0x02 (0x2F) path, NOT the 0x06 path. Dangerous opcodes (reboot, factory reset, key install,
// DFU) are quarantined in OuraDangerousCommands and never produced by the normal builders.
//
// Platform-pure value types. Facts cited per OURA_PROTOCOL.md s4 / s5.

/**
 * A built command plus a short label for the strap log (statuses/UUIDs/counts only, never an
 * address). The OuraDriver returns these from nextStep(after:).
 */
data class OuraCommand(val label: String, val bytes: IntArray) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is OuraCommand) return false
        return label == other.label && bytes.contentEquals(other.bytes)
    }

    override fun hashCode(): Int = 31 * label.hashCode() + bytes.contentHashCode()
}

object OuraCommands {
    private val protocolRandom = SecureRandom()
    // The live daytime-HR feature id. Per OURA_PROTOCOL.md s5.6 / s7.1.
    const val featureDaytimeHR = 0x02

    // The SpO2 feature id. Per OURA_PROTOCOL.md s7.1.
    const val featureSpO2 = 0x04

    // MARK: - Pre-auth / identity (unauthenticated OK)

    /** GetFirmwareVersion: `08 03 00 00 00`. Pre-auth readable. Per OURA_PROTOCOL.md s4.1 / s3.6. */
    fun getFirmwareVersion(): OuraCommand =
        OuraCommand("get_firmware", intArrayOf(0x08, 0x03, 0x00, 0x00, 0x00))

    /**
     * GetProductInfo serial page: `18 03 08 00 10`. Pre-auth readable; used for generation detection.
     * Per OURA_PROTOCOL.md s4.1 / s7.3.
     */
    fun getProductSerial(): OuraCommand =
        OuraCommand("get_serial", intArrayOf(0x18, 0x03, 0x08, 0x00, 0x10))

    /**
     * GetProductInfo hardware page: `18 03 18 00 10`. Pre-auth readable; hardware id (e.g. BLB_03)
     * maps to the generation. Per OURA_PROTOCOL.md s4.1 / s7.3.
     */
    fun getProductHardware(): OuraCommand =
        OuraCommand("get_hardware", intArrayOf(0x18, 0x03, 0x18, 0x00, 0x10))

    /** Read-only official Ring 4 session probes sent immediately before the auth nonce request. */
    fun ring4PreAuthSessionReads(): List<OuraCommand> = listOf(
        OuraCommand("ring4_pre_auth_session_00", intArrayOf(0x2F, 0x02, 0x01, 0x00)),
        OuraCommand("ring4_pre_auth_session_01", intArrayOf(0x2F, 0x02, 0x01, 0x01)),
    )

    // MARK: - Notifications / state

    /** SetNotification (enable all): `1c 01 3f`. `00`=none, `3f`/`bf`=all. Per OURA_PROTOCOL.md s4.1. */
    fun enableAllNotifications(): OuraCommand =
        OuraCommand("notify_all", intArrayOf(0x1C, 0x01, 0x3F))

    /** SetNotification (disable): `1c 01 00`. Per OURA_PROTOCOL.md s4.1. */
    fun disableNotifications(): OuraCommand =
        OuraCommand("notify_none", intArrayOf(0x1C, 0x01, 0x00))

    /** Enable the Ring 4 event stream before SyncTime/history. Twin of Swift's enableEventStream. */
    fun enableEventStream(): OuraCommand =
        OuraCommand("event_stream_enable", intArrayOf(0x16, 0x01, 0x02))

    /** Byte-exact Ring 4 post-SyncTime state pulse, sent once per BLE session before category masks. */
    fun ring4PostSyncStatePulse(): OuraCommand =
        OuraCommand("ring4_post_sync_state", intArrayOf(0x1C, 0x01, 0xBF))

    /** Ring 4's six official post-auth event-category masks. */
    fun ring4EventCategorySubscriptions(): List<OuraCommand> = listOf(
        OuraCommand("event_category_14", intArrayOf(0x18, 0x03, 0x14, 0x00, 0x10)),
        OuraCommand("event_category_18", intArrayOf(0x18, 0x03, 0x18, 0x00, 0x10)),
        OuraCommand("event_category_28", intArrayOf(0x18, 0x03, 0x28, 0x00, 0x09)),
        OuraCommand("event_category_34", intArrayOf(0x18, 0x03, 0x34, 0x00, 0x04)),
        OuraCommand("event_category_04", intArrayOf(0x18, 0x03, 0x04, 0x00, 0x10)),
        OuraCommand("event_category_08", intArrayOf(0x18, 0x03, 0x08, 0x00, 0x10)),
    )

    /** Read-only official-history parameter sweep; the duplicate 0x0b read is intentional. */
    fun ring4HistoryParameterReads(): List<OuraCommand> = listOf(
        OuraCommand("ring4_param_read_02", intArrayOf(0x2F, 0x02, 0x20, 0x02)),
        OuraCommand("ring4_param_read_04", intArrayOf(0x2F, 0x02, 0x20, 0x04)),
        OuraCommand("ring4_param_read_0b", intArrayOf(0x2F, 0x02, 0x20, 0x0B)),
        OuraCommand("ring4_param_read_0d", intArrayOf(0x2F, 0x02, 0x20, 0x0D)),
        OuraCommand("ring4_param_read_03", intArrayOf(0x2F, 0x02, 0x20, 0x03)),
        OuraCommand("ring4_param_read_0b_again", intArrayOf(0x2F, 0x02, 0x20, 0x0B)),
        OuraCommand("ring4_param_read_10", intArrayOf(0x2F, 0x02, 0x20, 0x10)),
    )

    /**
     * Byte-exact Ring 4 session-state selector from the official history setup. Its semantics remain
     * provisional, so it stays separate from parameter-write helpers and runs once per BLE connection.
     */
    fun ring4HistorySessionMode(): OuraCommand =
        OuraCommand("ring4_history_session_mode", intArrayOf(0x2F, 0x02, 0x03, 0x01))

    // MARK: - Time sync

    /**
     * SyncTime: `12 09 <token:1> <counter:3 LE> 00 00 00 00 f6` where counter = floor(unix_s / 256)
     * and the trailer 0xf6 is fixed. The official Ring 4 client uses a fresh random token for each
     * request; callers may supply one explicitly for deterministic replay/tests.
     */
    fun syncTime(unixSeconds: Long, token: Int = protocolRandom.nextInt(256)): OuraCommand {
        val counter = unixSeconds / 256
        val c0 = (counter and 0xFFL).toInt()
        val c1 = ((counter shr 8) and 0xFFL).toInt()
        val c2 = ((counter shr 16) and 0xFFL).toInt()
        return OuraCommand(
            "sync_time",
            intArrayOf(0x12, 0x09, token and 0xFF, c0, c1, c2, 0x00, 0x00, 0x00, 0x00, 0xF6),
        )
    }

    // MARK: - Event fetch (cursor)

    /**
     * GetEvents request: `10 09 <ringTimestamp:4 LE> <max:1> <flags:4 LE>`. cursor 0 = full dump;
     * max 0 = ack-only (advance cursor without data); flags = 0xFFFFFFFF. Per OURA_PROTOCOL.md s5.1.
     * `cursor` is the unsigned-32 ring timestamp carried as a Long; `maxEvents` is 0..255.
     */
    fun getEvents(cursor: Long, maxEvents: Int): OuraCommand {
        val c0 = (cursor and 0xFFL).toInt()
        val c1 = ((cursor shr 8) and 0xFFL).toInt()
        val c2 = ((cursor shr 16) and 0xFFL).toInt()
        val c3 = ((cursor shr 24) and 0xFFL).toInt()
        return OuraCommand(
            "get_events",
            intArrayOf(0x10, 0x09, c0, c1, c2, c3, maxEvents and 0xFF, 0xFF, 0xFF, 0xFF, 0xFF),
        )
    }

    /** Flush flash-buffered events first: `28 01 00`. Per OURA_PROTOCOL.md s4.1 / s5.3. */
    fun flushBuffer(): OuraCommand =
        OuraCommand("flush_buffer", intArrayOf(0x28, 0x01, 0x00))

    /** GetBattery: `0c 00`. Auth-gated after key set. Per OURA_PROTOCOL.md s4.1. */
    fun getBattery(): OuraCommand =
        OuraCommand("get_battery", intArrayOf(0x0C, 0x00))

    // MARK: - Live-HR realtime (feature-0x02 path; s5.6)

    /**
     * Step 1 of the live-HR enable triplet: read the daytime-HR feature status, `2f 02 20 02`.
     * ACK: `2f 06 21 02 ...`. Per OURA_PROTOCOL.md s5.6.
     */
    fun liveHRReadStatus(): OuraCommand =
        OuraCommand("dhr_read", intArrayOf(0x2F, 0x02, 0x20, featureDaytimeHR))

    /**
     * Step 2: enable (param write byte 0 = 3), `2f 03 22 02 03`. ACK: `2f 03 23 02 00`.
     * Per OURA_PROTOCOL.md s5.6.
     */
    fun liveHREnable(): OuraCommand =
        OuraCommand("dhr_enable", intArrayOf(0x2F, 0x03, 0x22, featureDaytimeHR, 0x03))

    /**
     * Step 3: subscribe (param write byte 2 = 2), `2f 03 26 02 02`. ACK: `2f 03 27 02 00`. Live HR/IBI
     * then streams ~1 Hz as 0x2F sub-op 0x28 pushes. Per OURA_PROTOCOL.md s5.6.
     */
    fun liveHRSubscribe(): OuraCommand =
        OuraCommand("dhr_subscribe", intArrayOf(0x2F, 0x03, 0x26, featureDaytimeHR, 0x02))

    /**
     * Disable live HR: `2f 03 22 02 01`. ACK: `2f 03 23 02 00`; stream stops on ACK.
     * Per OURA_PROTOCOL.md s5.6.
     */
    fun liveHRDisable(): OuraCommand =
        OuraCommand("dhr_disable", intArrayOf(0x2F, 0x03, 0x22, featureDaytimeHR, 0x01))

    /**
     * The ordered live-HR enable triplet (read, enable, subscribe). The driver gates each on its ACK.
     * Per OURA_PROTOCOL.md s5.6.
     */
    fun liveHREnableSequence(): List<OuraCommand> =
        listOf(liveHRReadStatus(), liveHREnable(), liveHRSubscribe())

    // MARK: - Automatic overnight SpO2 (explicit user opt-in only)

    /** Read automatic-SpO2 status without changing it: `2f 02 20 04`. */
    fun spO2ReadStatus(): OuraCommand =
        OuraCommand("spo2_read", intArrayOf(0x2F, 0x02, 0x20, featureSpO2))

    /** Enable automatic overnight SpO2. Must only follow an explicit user action. */
    fun spO2EnableAutomatic(): OuraCommand =
        OuraCommand("spo2_enable_automatic", intArrayOf(0x2F, 0x03, 0x22, featureSpO2, 0x01))
}

// MARK: - Dangerous commands (quarantined)

/**
 * Opcodes that reboot, wipe, reflash, or re-key the ring. These are isolated here and NEVER produced
 * by the normal builders or the OuraDriver flow, so they can only be sent through an explicit, named
 * call. Per the brief's FOOTGUN WATCH and OURA_PROTOCOL.md s4.1 (DANGEROUS markers).
 */
object OuraDangerousCommands {
    /** 0x0E StartFirmwareUpdate / soft_reset (reboots 22-35 s): `0e 01 ff`. Per OURA_PROTOCOL.md s4.1. */
    fun softReset(): OuraCommand =
        OuraCommand("DANGEROUS_soft_reset", intArrayOf(0x0E, 0x01, 0xFF))

    /** 0x1A FactoryReset (wipes the ring, forces re-onboard + key reinstall). Per OURA_PROTOCOL.md s4.1. */
    fun factoryReset(): OuraCommand =
        OuraCommand("DANGEROUS_factory_reset", intArrayOf(0x1A, 0x00))

    /**
     * 0x24 SetAuthKey (installs a new 16-byte app key; only legitimate post-factory-reset). Builds
     * via OuraAuth.installKeyCommand so the length guard is shared. Per OURA_PROTOCOL.md s3.2.
     */
    fun installKey(key: IntArray): OuraCommand =
        OuraCommand("DANGEROUS_install_key", OuraAuth.installKeyCommand(key))

    /** 0x2B DFU start (OTA firmware). Payload is the OTA control body. Per OURA_PROTOCOL.md s4.1. */
    fun dfuStart(body: IntArray): OuraCommand =
        OuraCommand("DANGEROUS_dfu_start", intArrayOf(0x2B, body.size and 0xFF) + body)

    /** 0x2C DFU bulk payload chunk (OTA firmware data). Per OURA_PROTOCOL.md s4.1. */
    fun dfuBulk(body: IntArray): OuraCommand =
        OuraCommand("DANGEROUS_dfu_bulk", intArrayOf(0x2C, body.size and 0xFF) + body)
}
