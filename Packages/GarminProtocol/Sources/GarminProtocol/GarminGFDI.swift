import Foundation

public enum GarminGFDIStatus: UInt8, Sendable {
    case acknowledgement = 0, negativeAcknowledgement = 1, unsupported = 2
    case decodeError = 3, crcError = 4, lengthError = 5
}

public struct GarminGFDIMessage: Equatable, Sendable {
    public let messageID: UInt16
    public let sequence: UInt8?
    public let payload: [UInt8]
    public let responseToMessageID: UInt16?
    public let statusRaw: UInt8?
    public let status: GarminGFDIStatus?
}

public enum GarminGFDIError: Error, Equatable, Sendable {
    case tooShort, invalidLength, invalidCRC, invalidSequence, invalidMessageID
}

public enum GarminGFDI {
    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    public static func encode(messageID: UInt16, sequence: UInt8? = nil,
                              payload: [UInt8] = []) throws -> [UInt8] {
        var body: [UInt8]
        if let sequence {
            guard sequence < 32 else { throw GarminGFDIError.invalidSequence }
            guard (5_000...5_255).contains(Int(messageID)) else { throw GarminGFDIError.invalidMessageID }
            body = [UInt8(messageID - 5_000), 0x80 | sequence]
        } else {
            body = le(messageID)
        }
        body += payload
        let total = body.count + 4
        guard total <= Int(UInt16.max) else { throw GarminGFDIError.invalidLength }
        var envelope = le(UInt16(total)) + body
        envelope += le(crc16(envelope))
        return envelope
    }

    public static func decode(_ bytes: [UInt8]) throws -> GarminGFDIMessage {
        guard bytes.count >= 6 else { throw GarminGFDIError.tooShort }
        guard Int(u16(bytes, 0)) == bytes.count else { throw GarminGFDIError.invalidLength }
        guard crc16(Array(bytes.dropLast(2))) == u16(bytes, bytes.count - 2) else {
            throw GarminGFDIError.invalidCRC
        }
        let compact = bytes[3] & 0x80 != 0
        let messageID: UInt16 = compact ? 5_000 + UInt16(bytes[2]) : u16(bytes, 2)
        let sequence: UInt8? = compact ? bytes[3] & 0x1F : nil
        let payload = Array(bytes[4..<(bytes.count - 2)])
        var responseTo: UInt16?
        var statusRaw: UInt8?
        if messageID == 5_000, payload.count >= 3 {
            responseTo = u16(payload, 0)
            statusRaw = payload[2]
        }
        return GarminGFDIMessage(messageID: messageID, sequence: sequence, payload: payload,
                                responseToMessageID: responseTo, statusRaw: statusRaw,
                                status: statusRaw.flatMap(GarminGFDIStatus.init(rawValue:)))
    }

    private static func le(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }
}
