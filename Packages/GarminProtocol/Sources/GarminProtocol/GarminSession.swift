import Foundation

public enum GarminGFDIMessageID: UInt16, Sendable {
    case response = 5000
    case deviceInformation = 5024
    case deviceSettings = 5026
    case systemEvent = 5030
    case supportedFileTypes = 5031
    case notificationSubscription = 5036
    case protobufRequest = 5043
    case configuration = 5050
    case currentTimeRequest = 5052
    case authNegotiation = 5101
}

public struct GarminHostIdentity: Equatable, Sendable {
    public let protocolVersion: UInt16
    public let productNumber: UInt16
    public let unitNumber: UInt32
    public let softwareVersion: UInt16
    public let maximumPacketSize: UInt16
    public let bluetoothName: String
    public let manufacturer: String
    public let model: String

    public init(protocolVersion: UInt16 = 150, productNumber: UInt16 = .max,
                unitNumber: UInt32 = .max, softwareVersion: UInt16 = 8300,
                maximumPacketSize: UInt16 = .max, bluetoothName: String = "NOOP",
                manufacturer: String = "NOOP", model: String = "Offline companion") {
        self.protocolVersion = protocolVersion
        self.productNumber = productNumber
        self.unitNumber = unitNumber
        self.softwareVersion = softwareVersion
        self.maximumPacketSize = maximumPacketSize
        self.bluetoothName = bluetoothName
        self.manufacturer = manufacturer
        self.model = model
    }
}

public enum GarminSessionError: Error, Equatable, Sendable {
    case malformedRequest, invalidTime, fieldTooLong, tooManyCapabilities
}

public struct GarminSessionReply: Equatable, Sendable {
    public let outgoing: [[UInt8]]
    public let configurationCompleted: Bool
    public init(outgoing: [[UInt8]], configurationCompleted: Bool = false) {
        self.outgoing = outgoing
        self.configurationCompleted = configurationCompleted
    }
}

/// Minimal, honest GFDI handshake responder. It advertises only the capabilities explicitly supplied
/// by NOOP and returns UNSUPPORTED for phone features that are not implemented yet.
public enum GarminSessionResponder {
    public static let syncReadyEvent: UInt8 = 8

    public static func reply(
        to message: GarminGFDIMessage,
        nowUnixSeconds: Int64,
        timeZoneOffsetSeconds: Int32,
        identity: GarminHostIdentity = .init(),
        supportedCapabilities: [UInt8] = []
    ) throws -> GarminSessionReply? {
        guard let kind = GarminGFDIMessageID(rawValue: message.messageID) else { return nil }
        switch kind {
        case .deviceInformation:
            guard message.payload.count >= 2 else { throw GarminSessionError.malformedRequest }
            let incomingProtocol = u16(message.payload, 0)
            var body = responsePrefix(for: kind, status: .acknowledgement)
            body += le(identity.protocolVersion)
            body += le(identity.productNumber)
            body += le(identity.unitNumber)
            body += le(identity.softwareVersion)
            body += le(identity.maximumPacketSize)
            body += try string(identity.bluetoothName)
            body += try string(identity.manufacturer)
            body += try string(identity.model)
            body.append(incomingProtocol / 100 == 1 ? 1 : 0)
            return .init(outgoing: [try GarminGFDI.encode(messageID: GarminGFDIMessageID.response.rawValue,
                                                          payload: body)])

        case .configuration:
            guard supportedCapabilities.count <= 255 else { throw GarminSessionError.tooManyCapabilities }
            // Do not mirror the watch's bitset: that would claim phone features NOOP has not implemented.
            let config = try GarminGFDI.encode(
                messageID: kind.rawValue,
                payload: [UInt8(supportedCapabilities.count)] + supportedCapabilities
            )
            let ready = try GarminGFDI.encode(
                messageID: GarminGFDIMessageID.systemEvent.rawValue,
                payload: [syncReadyEvent]
            )
            return .init(outgoing: [config, ready], configurationCompleted: true)

        case .authNegotiation:
            let body = responsePrefix(for: kind, status: .acknowledgement) + [0, 0, 0, 0, 0]
            return .init(outgoing: [try GarminGFDI.encode(messageID: GarminGFDIMessageID.response.rawValue,
                                                          payload: body)])

        case .currentTimeRequest:
            guard message.payload.count >= 4,
                  let garminTime = GarminEpoch.garminSeconds(fromUnixSeconds: nowUnixSeconds)
            else { throw GarminSessionError.invalidTime }
            var body = responsePrefix(for: kind, status: .acknowledgement)
            body += Array(message.payload.prefix(4))
            body += le(garminTime)
            body += le(UInt32(bitPattern: timeZoneOffsetSeconds))
            body += [UInt8](repeating: 0, count: 8) // transition end/start: unknown, not fabricated
            return .init(outgoing: [try GarminGFDI.encode(messageID: GarminGFDIMessageID.response.rawValue,
                                                          payload: body)])

        case .notificationSubscription, .protobufRequest:
            let body = responsePrefix(for: kind, status: .unsupported)
            return .init(outgoing: [try GarminGFDI.encode(messageID: GarminGFDIMessageID.response.rawValue,
                                                          payload: body)])

        case .response, .deviceSettings, .systemEvent, .supportedFileTypes:
            return nil
        }
    }

    private static func responsePrefix(for id: GarminGFDIMessageID,
                                       status: GarminGFDIStatus) -> [UInt8] {
        le(id.rawValue) + [status.rawValue]
    }

    private static func string(_ value: String) throws -> [UInt8] {
        let bytes = Array(value.utf8)
        guard bytes.count <= 255 else { throw GarminSessionError.fieldTooLong }
        return [UInt8(bytes.count)] + bytes
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    private static func le(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
    private static func le(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
         UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)]
    }
}
