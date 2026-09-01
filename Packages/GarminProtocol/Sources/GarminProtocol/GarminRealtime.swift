import Foundation

public enum GarminEpoch {
    /// FIT/Garmin epoch: 1989-12-31 00:00:00 UTC.
    public static let unixOffsetSeconds: Int64 = 631_065_600
    public static func unixSeconds(fromGarminSeconds seconds: UInt32) -> Int64 {
        unixOffsetSeconds + Int64(seconds)
    }
    public static func garminSeconds(fromUnixSeconds seconds: Int64) -> UInt32? {
        let delta = seconds - unixOffsetSeconds
        return UInt32(exactly: delta)
    }
}

public struct GarminRealtimeHeartRate: Equatable, Sendable {
    public let raw: [UInt8]; public let type: UInt8; public let rawHeartRate: UInt8
    public let heartRateBPM: Int?; public let restingHeartRate: UInt8
}
public struct GarminRealtimeSteps: Equatable, Sendable {
    public let raw: [UInt8]; public let steps: Int32; public let goal: Int32
}
public struct GarminRealtimeSpO2: Equatable, Sendable {
    public let raw: [UInt8]; public let rawValue: Int8; public let percent: Int?
    public let garminTimestamp: UInt32; public let unixSeconds: Int64
}
public struct GarminRealtimeRespiration: Equatable, Sendable {
    public let raw: [UInt8]; public let rawValue: Int8; public let breathsPerMinute: Int?
}
public struct GarminRealtimeHRV: Equatable, Sendable {
    public let raw: [UInt8]; public let rawRRMilliseconds: Int16; public let rrMilliseconds: Int?
    public let unknown: Int32
}
public struct GarminOpaqueRealtime: Equatable, Sendable {
    public let service: GarminMultiLinkService; public let raw: [UInt8]
}

public enum GarminRealtimeValue: Equatable, Sendable {
    case heartRate(GarminRealtimeHeartRate), steps(GarminRealtimeSteps), hrv(GarminRealtimeHRV)
    case spo2(GarminRealtimeSpO2), respiration(GarminRealtimeRespiration)
    case accelerometer(GarminOpaqueRealtime), bodyBattery(GarminOpaqueRealtime)
}

public enum GarminRealtimeDecoder {
    public static func decode(service: GarminMultiLinkService, payload b: [UInt8]) -> GarminRealtimeValue? {
        switch service {
        case .realtimeHeartRate:
            guard b.count == 3 || (b.count == 5 && b.suffix(2) == [0xFF, 0xFF]) else { return nil }
            let bpm = b[1] == 0 ? nil : Int(b[1])
            return .heartRate(.init(raw: b, type: b[0], rawHeartRate: b[1], heartRateBPM: bpm,
                                    restingHeartRate: b[2]))
        case .realtimeSteps:
            guard b.count == 8 else { return nil }
            let steps = i32(b, 0), goal = i32(b, 4)
            guard steps >= 0, goal >= 0 else { return nil }
            return .steps(.init(raw: b, steps: steps, goal: goal))
        case .realtimeHRV:
            guard b.count == 6 else { return nil }
            let rawRR = i16(b, 0)
            let qualified = (200...3_000).contains(Int(rawRR)) ? Int(rawRR) : nil
            return .hrv(.init(raw: b, rawRRMilliseconds: rawRR, rrMilliseconds: qualified,
                              unknown: i32(b, 2)))
        case .realtimeSpO2:
            guard b.count == 5 else { return nil }
            let raw = Int8(bitPattern: b[0]), timestamp = u32(b, 1)
            let qualified = raw > 0 && raw <= 100 ? Int(raw) : nil
            return .spo2(.init(raw: b, rawValue: raw, percent: qualified,
                               garminTimestamp: timestamp,
                               unixSeconds: GarminEpoch.unixSeconds(fromGarminSeconds: timestamp)))
        case .realtimeRespiration:
            guard b.count == 1 else { return nil }
            let raw = Int8(bitPattern: b[0])
            return .respiration(.init(raw: b, rawValue: raw,
                                      breathsPerMinute: raw > 0 && raw <= 120 ? Int(raw) : nil))
        case .realtimeAccelerometer:
            return b.isEmpty ? nil : .accelerometer(.init(service: service, raw: b))
        case .realtimeBodyBattery:
            return b.isEmpty ? nil : .bodyBattery(.init(service: service, raw: b))
        case .gfdi:
            return nil
        }
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24
    }
    private static func i16(_ b: [UInt8], _ i: Int) -> Int16 {
        Int16(bitPattern: UInt16(b[i]) | UInt16(b[i+1]) << 8)
    }
    private static func i32(_ b: [UInt8], _ i: Int) -> Int32 {
        Int32(bitPattern: u32(b, i))
    }
}
