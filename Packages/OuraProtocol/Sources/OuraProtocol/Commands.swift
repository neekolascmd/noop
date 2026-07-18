import Foundation

// Commands: byte-exact opcode builders (OURA_PROTOCOL.md s4 / s5). Pure functions returning the
// wire bytes to write to ...0002. The live-HR enable path (s5.6) is the feature-0x02 (0x2F) path,
// NOT the 0x06 path. Dangerous opcodes (reboot, factory reset, key install, DFU) are quarantined in
// OuraDangerousCommands and never produced by the normal builders.
//
// Platform-pure value types. Facts cited per OURA_PROTOCOL.md s4 / s5.

/// A built command plus a short label for the strap log (statuses/UUIDs/counts only, never an
/// address). The OuraDriver returns these from nextStep(after:).
public struct OuraCommand: Equatable, Sendable {
    public let label: String
    public let bytes: [UInt8]
    public init(label: String, bytes: [UInt8]) { self.label = label; self.bytes = bytes }
}

public enum OuraCommands {
    // The live daytime-HR feature id. Per OURA_PROTOCOL.md s5.6 / s7.1.
    public static let featureDaytimeHR: UInt8 = 0x02
    // The SpO2 feature id. Per OURA_PROTOCOL.md s7.1.
    public static let featureSpO2: UInt8 = 0x04

    // MARK: - Pre-auth / identity (unauthenticated OK)

    /// GetFirmwareVersion: `08 03 00 00 00`. Pre-auth readable. Per OURA_PROTOCOL.md s4.1 / s3.6.
    public static func getFirmwareVersion() -> OuraCommand {
        OuraCommand(label: "get_firmware", bytes: [0x08, 0x03, 0x00, 0x00, 0x00])
    }

    /// GetProductInfo serial page: `18 03 08 00 10`. Pre-auth readable; used for generation detection.
    /// Per OURA_PROTOCOL.md s4.1 / s7.3.
    public static func getProductSerial() -> OuraCommand {
        OuraCommand(label: "get_serial", bytes: [0x18, 0x03, 0x08, 0x00, 0x10])
    }

    /// GetProductInfo hardware page: `18 03 18 00 10`. Pre-auth readable; hardware id (e.g. BLB_03)
    /// maps to the generation. Per OURA_PROTOCOL.md s4.1 / s7.3.
    public static func getProductHardware() -> OuraCommand {
        OuraCommand(label: "get_hardware", bytes: [0x18, 0x03, 0x18, 0x00, 0x10])
    }

    /// Two read-only Ring 4 session probes sent by the official app immediately before requesting the
    /// authentication nonce. Their response semantics are still unknown, so keep them isolated and
    /// never reuse these builders as parameter writes.
    public static func ring4PreAuthSessionReads() -> [OuraCommand] {
        [
            OuraCommand(label: "ring4_pre_auth_session_00", bytes: [0x2F, 0x02, 0x01, 0x00]),
            OuraCommand(label: "ring4_pre_auth_session_01", bytes: [0x2F, 0x02, 0x01, 0x01]),
        ]
    }

    // MARK: - Notifications / state

    /// SetNotification (enable all): `1c 01 3f`. `00`=none, `3f`/`bf`=all. Per OURA_PROTOCOL.md s4.1.
    public static func enableAllNotifications() -> OuraCommand {
        OuraCommand(label: "notify_all", bytes: [0x1C, 0x01, 0x3F])
    }

    /// SetNotification (disable): `1c 01 00`. Per OURA_PROTOCOL.md s4.1.
    public static func disableNotifications() -> OuraCommand {
        OuraCommand(label: "notify_none", bytes: [0x1C, 0x01, 0x00])
    }

    /// Enable the Ring 4 event stream before a time-sync/history pass: `16 01 02`.
    /// The ring acknowledges with `17 01 02`. This is separate from the secure DHR subscription below.
    /// Per open_ring's executable setup sequence and OURA_PROTOCOL.md s4.1/s5.4.
    public static func enableEventStream() -> OuraCommand {
        OuraCommand(label: "event_stream_enable", bytes: [0x16, 0x01, 0x02])
    }

    /// Ring 4's official post-SyncTime state pulse: `1c 01 bf`. This is sent once per BLE session,
    /// after authentication and SyncTime but before the category masks. It is deliberately distinct
    /// from the older generic `notify_all` helper (`1c 01 3f`): current Ring 4 captures use `0xbf` at
    /// this exact point in the setup state machine.
    public static func ring4PostSyncStatePulse() -> OuraCommand {
        OuraCommand(label: "ring4_post_sync_state", bytes: [0x1C, 0x01, 0xBF])
    }

    /// Ring 4's official post-auth category masks. `0x16` enables the record stream globally; these
    /// `0x18` writes select the event families delivered by the following history fetch. The separate,
    /// byte-exact `ring4PostSyncStatePulse()` precedes them once per BLE session.
    public static func ring4EventCategorySubscriptions() -> [OuraCommand] {
        [
            OuraCommand(label: "event_category_14", bytes: [0x18, 0x03, 0x14, 0x00, 0x10]),
            OuraCommand(label: "event_category_18", bytes: [0x18, 0x03, 0x18, 0x00, 0x10]),
            OuraCommand(label: "event_category_28", bytes: [0x18, 0x03, 0x28, 0x00, 0x09]),
            OuraCommand(label: "event_category_34", bytes: [0x18, 0x03, 0x34, 0x00, 0x04]),
            OuraCommand(label: "event_category_04", bytes: [0x18, 0x03, 0x04, 0x00, 0x10]),
            OuraCommand(label: "event_category_08", bytes: [0x18, 0x03, 0x08, 0x00, 0x10]),
        ]
    }

    /// Read-only Ring 4 parameter sweep used by the official history setup after category selection.
    /// These reads register interest in the current configuration without changing any sensor setting.
    /// The duplicate 0x0b read is intentional and preserves the observed order.
    public static func ring4HistoryParameterReads() -> [OuraCommand] {
        [
            OuraCommand(label: "ring4_param_read_02", bytes: [0x2F, 0x02, 0x20, 0x02]),
            OuraCommand(label: "ring4_param_read_04", bytes: [0x2F, 0x02, 0x20, 0x04]),
            OuraCommand(label: "ring4_param_read_0b", bytes: [0x2F, 0x02, 0x20, 0x0B]),
            OuraCommand(label: "ring4_param_read_0d", bytes: [0x2F, 0x02, 0x20, 0x0D]),
            OuraCommand(label: "ring4_param_read_03", bytes: [0x2F, 0x02, 0x20, 0x03]),
            OuraCommand(label: "ring4_param_read_0b_again", bytes: [0x2F, 0x02, 0x20, 0x0B]),
            OuraCommand(label: "ring4_param_read_10", bytes: [0x2F, 0x02, 0x20, 0x10]),
        ]
    }

    /// Ring 4 session-state selector observed between the 0x04 and 0x0b reads in the official
    /// application's history setup: `2f 02 03 01`. Its payload is byte-exact but its semantic name is
    /// still provisional, so keep it isolated from the documented parameter-write helpers. It is sent
    /// once per BLE connection and never used for pairing, reset, or biometric-data mutation.
    public static func ring4HistorySessionMode() -> OuraCommand {
        OuraCommand(label: "ring4_history_session_mode", bytes: [0x2F, 0x02, 0x03, 0x01])
    }

    // MARK: - Time sync

    /// SyncTime: `12 09 <token:1> <counter:3 LE> 00 00 00 00 f6` where counter = floor(unix_s / 256)
    /// and the trailer 0xf6 is fixed. The official Ring 4 client uses a fresh random token for every
    /// request; callers may pass one explicitly for deterministic replay/tests. Per OURA_PROTOCOL.md s5.4.
    public static func syncTime(unixSeconds: Int, token: UInt8 = .random(in: .min ... .max)) -> OuraCommand {
        let counter = unixSeconds / 256
        let c0 = UInt8(counter & 0xFF)
        let c1 = UInt8((counter >> 8) & 0xFF)
        let c2 = UInt8((counter >> 16) & 0xFF)
        return OuraCommand(label: "sync_time",
                           bytes: [0x12, 0x09, token, c0, c1, c2, 0x00, 0x00, 0x00, 0x00, 0xF6])
    }

    // MARK: - Event fetch (cursor)

    /// GetEvents request: `10 09 <ringTimestamp:4 LE> <max:1> <flags:4 LE>`. cursor 0 = full dump;
    /// max 0 = ack-only (advance cursor without data); flags = 0xFFFFFFFF. Per OURA_PROTOCOL.md s5.1.
    public static func getEvents(cursor: UInt32, maxEvents: UInt8) -> OuraCommand {
        let c0 = UInt8(cursor & 0xFF)
        let c1 = UInt8((cursor >> 8) & 0xFF)
        let c2 = UInt8((cursor >> 16) & 0xFF)
        let c3 = UInt8((cursor >> 24) & 0xFF)
        return OuraCommand(label: "get_events",
                           bytes: [0x10, 0x09, c0, c1, c2, c3, maxEvents, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    /// Flush flash-buffered events first: `28 01 00`. Per OURA_PROTOCOL.md s4.1 / s5.3.
    public static func flushBuffer() -> OuraCommand {
        OuraCommand(label: "flush_buffer", bytes: [0x28, 0x01, 0x00])
    }

    /// GetBattery: `0c 00`. Auth-gated after key set. Per OURA_PROTOCOL.md s4.1.
    public static func getBattery() -> OuraCommand {
        OuraCommand(label: "get_battery", bytes: [0x0C, 0x00])
    }

    // MARK: - Live-HR realtime (feature-0x02 path; s5.6)

    /// Step 1 of the live-HR enable triplet: read the daytime-HR feature status, `2f 02 20 02`.
    /// ACK: `2f 06 21 02 ...`. Per OURA_PROTOCOL.md s5.6.
    public static func liveHRReadStatus() -> OuraCommand {
        OuraCommand(label: "dhr_read", bytes: [0x2F, 0x02, 0x20, featureDaytimeHR])
    }

    /// Step 2: enable (param write byte 0 = 3), `2f 03 22 02 03`. ACK: `2f 03 23 02 00`.
    /// Per OURA_PROTOCOL.md s5.6.
    public static func liveHREnable() -> OuraCommand {
        OuraCommand(label: "dhr_enable", bytes: [0x2F, 0x03, 0x22, featureDaytimeHR, 0x03])
    }

    /// Step 3: subscribe (param write byte 2 = 2), `2f 03 26 02 02`. ACK: `2f 03 27 02 00`. Live HR/IBI
    /// then streams ~1 Hz as 0x2F sub-op 0x28 pushes. Per OURA_PROTOCOL.md s5.6.
    public static func liveHRSubscribe() -> OuraCommand {
        OuraCommand(label: "dhr_subscribe", bytes: [0x2F, 0x03, 0x26, featureDaytimeHR, 0x02])
    }

    /// Disable live HR: `2f 03 22 02 01`. ACK: `2f 03 23 02 00`; stream stops on ACK.
    /// Per OURA_PROTOCOL.md s5.6.
    public static func liveHRDisable() -> OuraCommand {
        OuraCommand(label: "dhr_disable", bytes: [0x2F, 0x03, 0x22, featureDaytimeHR, 0x01])
    }

    /// The ordered live-HR enable triplet (read, enable, subscribe). The driver gates each on its ACK.
    /// Per OURA_PROTOCOL.md s5.6.
    public static func liveHREnableSequence() -> [OuraCommand] {
        [liveHRReadStatus(), liveHREnable(), liveHRSubscribe()]
    }

    // MARK: - Automatic overnight SpO2 (explicit user opt-in only)

    /// Read automatic-SpO2 status without changing it: `2f 02 20 04`.
    public static func spO2ReadStatus() -> OuraCommand {
        OuraCommand(label: "spo2_read", bytes: [0x2F, 0x02, 0x20, featureSpO2])
    }

    /// Enable automatic overnight SpO2 measurement: `2f 03 22 04 01`.
    /// This changes a ring sensor setting and must only follow an explicit user action.
    public static func spO2EnableAutomatic() -> OuraCommand {
        OuraCommand(label: "spo2_enable_automatic", bytes: [0x2F, 0x03, 0x22, featureSpO2, 0x01])
    }
}

// MARK: - Dangerous commands (quarantined)

/// Opcodes that reboot, wipe, reflash, or re-key the ring. These are isolated here and NEVER produced
/// by the normal builders or the OuraDriver flow, so they can only be sent through an explicit, named
/// call. Per the brief's FOOTGUN WATCH and OURA_PROTOCOL.md s4.1 (DANGEROUS markers).
public enum OuraDangerousCommands {
    /// 0x0E StartFirmwareUpdate / soft_reset (reboots 22-35 s): `0e 01 ff`. Per OURA_PROTOCOL.md s4.1.
    public static func softReset() -> OuraCommand {
        OuraCommand(label: "DANGEROUS_soft_reset", bytes: [0x0E, 0x01, 0xFF])
    }

    /// 0x1A FactoryReset (wipes the ring, forces re-onboard + key reinstall). Per OURA_PROTOCOL.md s4.1.
    public static func factoryReset() -> OuraCommand {
        OuraCommand(label: "DANGEROUS_factory_reset", bytes: [0x1A, 0x00])
    }

    /// 0x24 SetAuthKey (installs a new 16-byte app key; only legitimate post-factory-reset). Builds
    /// via OuraAuth.installKeyCommand so the length guard is shared. Per OURA_PROTOCOL.md s3.2.
    public static func installKey(_ key: [UInt8]) throws -> OuraCommand {
        OuraCommand(label: "DANGEROUS_install_key", bytes: try OuraAuth.installKeyCommand(key))
    }

    /// 0x2B DFU start (OTA firmware). Payload is the OTA control body. Per OURA_PROTOCOL.md s4.1.
    public static func dfuStart(_ body: [UInt8]) -> OuraCommand {
        OuraCommand(label: "DANGEROUS_dfu_start", bytes: [0x2B, UInt8(body.count & 0xFF)] + body)
    }

    /// 0x2C DFU bulk payload chunk (OTA firmware data). Per OURA_PROTOCOL.md s4.1.
    public static func dfuBulk(_ body: [UInt8]) -> OuraCommand {
        OuraCommand(label: "DANGEROUS_dfu_bulk", bytes: [0x2C, UInt8(body.count & 0xFF)] + body)
    }
}
