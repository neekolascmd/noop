import Foundation

/// Software-only clean-room facts for Garmin's Multi-Link v2 GATT service. Strings keep this package
/// independent of CoreBluetooth; transports may construct their platform UUID type at the edge.
public enum GarminMultiLinkUUID {
    public static let service = "6A4E2800-667B-11E3-949A-0800200C9A66"
    public static let readCharacteristics = (0...4).map {
        String(format: "6A4E281%X-667B-11E3-949A-0800200C9A66", $0)
    }
    public static let writeCharacteristics = (0...4).map {
        String(format: "6A4E282%X-667B-11E3-949A-0800200C9A66", $0)
    }
}

/// Pure ATT fragmentation: every write repeats the logical service handle, then carries MTU-4 bytes.
public enum GarminMultiLinkFraming {
    public static func fragment(handle: UInt8, encodedPayload: [UInt8], attMTU: Int) -> [[UInt8]] {
        precondition(handle != 0, "application service handle must be nonzero")
        precondition(attMTU >= 5, "ATT MTU must leave room for headers")
        let contentPerWrite = attMTU - 4 // ATT header (3) + logical handle (1)
        guard !encodedPayload.isEmpty else { return [[handle]] }
        return stride(from: 0, to: encodedPayload.count, by: contentPerWrite).map { offset in
            let end = min(offset + contentPerWrite, encodedPayload.count)
            return [handle] + Array(encodedPayload[offset..<end])
        }
    }
}

public enum GarminMultiLinkService: UInt16, CaseIterable, Sendable {
    case gfdi = 1
    case realtimeHeartRate = 6
    case realtimeSteps = 7
    case realtimeHRV = 12
    case realtimeAccelerometer = 16
    case realtimeSpO2 = 19
    case realtimeBodyBattery = 20
    case realtimeRespiration = 21
}

public struct GarminClientID: Equatable, Sendable {
    public let bytes: [UInt8]
    /// The currently observed Garmin phone-client identifier. Keep it configurable because the field is
    /// routing state, not an authentication secret, and future firmware may require a different value.
    public init(_ bytes: [UInt8] = [2, 0, 0, 0, 0, 0, 0, 0]) {
        precondition(bytes.count == 8, "Garmin client id must contain eight bytes")
        self.bytes = bytes
    }
}

public enum GarminHandleReliability: UInt8, Sendable { case multiLink = 0, reliable = 2 }

public enum GarminHandleStatus: UInt8, Sendable {
    /// Zero is the only status whose meaning is established by current primary-source implementations.
    /// Non-zero values remain available as `statusRaw`; assigning names to them would invent semantics.
    case success = 0
}

public struct GarminHandleRegistration: Equatable, Sendable {
    public let clientID: GarminClientID
    public let service: UInt16
    public let statusRaw: UInt8
    public let status: GarminHandleStatus?
    public let handle: UInt8?
    public let reliable: Bool?
    public let usesMultiLinkCharacteristic: Bool?
}

public enum GarminHandleManagement {
    public static func register(service: GarminMultiLinkService, clientID: GarminClientID = .init(),
                                reliability: GarminHandleReliability = .multiLink) -> [UInt8] {
        [0, 0] + clientID.bytes + le(service.rawValue) + [reliability.rawValue]
    }

    public static func close(service: GarminMultiLinkService, handle: UInt8,
                             clientID: GarminClientID = .init()) -> [UInt8] {
        [0, 2] + clientID.bytes + le(service.rawValue) + [handle]
    }

    public static func closeAll(clientID: GarminClientID = .init(), flags: UInt16 = 0) -> [UInt8] {
        [0, 5] + clientID.bytes + le(flags)
    }

    public static func isCloseAllResponse(_ bytes: [UInt8], clientID: GarminClientID = .init()) -> Bool {
        bytes.count >= 10 && bytes[0] == 0 && bytes[1] == 6 && Array(bytes[2..<10]) == clientID.bytes
    }

    public static func parseRegistrationResponse(_ bytes: [UInt8]) -> GarminHandleRegistration? {
        guard bytes.count >= 13, bytes[0] == 0, bytes[1] == 1 else { return nil }
        let client = GarminClientID(Array(bytes[2..<10]))
        let service = u16(bytes, 10)
        let rawStatus = bytes[12]
        let status = GarminHandleStatus(rawValue: rawStatus)
        guard rawStatus == GarminHandleStatus.success.rawValue else {
            return GarminHandleRegistration(clientID: client, service: service, statusRaw: rawStatus,
                                            status: status, handle: nil, reliable: nil,
                                            usesMultiLinkCharacteristic: nil)
        }
        guard bytes.count == 15 || bytes.count == 16 else { return nil }
        let handle = bytes[13]
        let reliable = bytes[14] != 0
        let usesML = bytes.count == 16 ? (bytes[15] & 1) != 0 : nil
        return GarminHandleRegistration(clientID: client, service: service, statusRaw: rawStatus,
                                        status: status, handle: handle, reliable: reliable,
                                        usesMultiLinkCharacteristic: usesML)
    }

    private static func le(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }
}
