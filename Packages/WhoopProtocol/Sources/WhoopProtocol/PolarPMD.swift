import Foundation

// MARK: - Polar Measurement Data (PMD) control plane
//
// PMD is the vendor GATT service exposed by devices such as the Polar H10, OH1, and
// Verity Sense. This implementation is an independent, bounds-checked implementation
// of the public wire behavior documented by Polar's official BLE SDK. It deliberately
// has no dependency on that SDK, so NOOP keeps its offline build and the decoder remains
// testable on every host.
//
// Reference (protocol behavior and UUIDs):
// https://github.com/polarofficial/polar-ble-sdk/tree/ccff6812c40fff1753c72385387d1877ca9b27b4/sources

public enum PolarPMDGATT {
    public static let service = "FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8"
    public static let controlPoint = "FB005C81-02E7-F387-1CAD-8ACD2D8DF0C8"
    public static let data = "FB005C82-02E7-F387-1CAD-8ACD2D8DF0C8"
}

public enum PolarPMDMeasurement: UInt8, CaseIterable, Codable, Sendable {
    case ecg = 0
    case ppg = 1
    case accelerometer = 2
    case ppi = 3
    case gyroscope = 5
    case magnetometer = 6
    case skinTemperature = 7
    case sdkMode = 9
    case location = 10
    case pressure = 11
    case temperature = 12
    case offlineRecording = 13
    case offlineHeartRate = 14
    case derived = 15

    public init?(wireByte: UInt8) {
        self.init(rawValue: wireByte & 0x3F)
    }
}

/// Measurement capabilities returned by reading the PMD Control Point characteristic.
///
/// The first byte is the PMD feature-response marker (`0x0F`); the next two bytes are
/// a bitset. Unknown future bits are retained in `rawBits` and safely ignored.
public struct PolarPMDFeatures: Equatable, Sendable {
    public static let responseMarker: UInt8 = 0x0F

    public let rawBits: UInt16
    public let measurements: Set<PolarPMDMeasurement>

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 3, bytes[0] == Self.responseMarker else { return nil }
        rawBits = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)

        var found = Set<PolarPMDMeasurement>()
        let bitMap: [(Int, PolarPMDMeasurement)] = [
            (0, .ecg),
            (1, .ppg),
            (2, .accelerometer),
            (3, .ppi),
            (5, .gyroscope),
            (6, .magnetometer),
            (7, .skinTemperature),
            (9, .sdkMode),
            (10, .location),
            (11, .pressure),
            (12, .temperature),
            (13, .offlineRecording),
            (14, .offlineHeartRate),
        ]
        for (bit, measurement) in bitMap where rawBits & (UInt16(1) << bit) != 0 {
            found.insert(measurement)
        }
        measurements = found
    }

    public func supports(_ measurement: PolarPMDMeasurement) -> Bool {
        measurements.contains(measurement)
    }
}

public enum PolarPMDSettingType: UInt8, CaseIterable, Codable, Sendable {
    case sampleRate = 0
    case resolution = 1
    case range = 2
    case rangeMilliunit = 3
    case channels = 4
    case factor = 5
    case security = 6
    case derivedMeasurementMethod = 7
    case sourceMeasurementType = 8
    case sourceMeasurementSampleRate = 9
    case sourceMeasurementRange = 10
    case derivedMeasurementTimeWindow = 11
    case derivedMeasurementSettingsGroupID = 12

    public var fieldWidth: Int {
        switch self {
        case .sampleRate, .resolution, .range, .sourceMeasurementSampleRate:
            return 2
        case .rangeMilliunit, .factor, .sourceMeasurementRange, .derivedMeasurementTimeWindow:
            return 4
        case .channels, .derivedMeasurementMethod, .sourceMeasurementType,
             .derivedMeasurementSettingsGroupID:
            return 1
        case .security:
            return 16
        }
    }

    /// Values returned only by the device and never echoed in a start request.
    public var isResponseOnly: Bool {
        self == .factor || self == .sourceMeasurementRange
    }
}

public enum PolarPMDError: Error, Equatable, CustomStringConvertible {
    case truncated(String)
    case malformed(String)
    case unsupported(String)
    case limitExceeded(String)

    public var description: String {
        switch self {
        case .truncated(let message): return "truncated PMD data: \(message)"
        case .malformed(let message): return "malformed PMD data: \(message)"
        case .unsupported(let message): return "unsupported PMD data: \(message)"
        case .limitExceeded(let message): return "PMD decode limit exceeded: \(message)"
        }
    }
}

/// Available or selected PMD settings.
///
/// Values stay as raw little-endian byte strings so the 128-bit security setting and
/// IEEE-754 factor bits are never lossy. Numeric convenience accessors are provided for
/// the ordinary 1/2/4-byte settings used by online ECG/PPG/ACC/PPI.
public struct PolarPMDSettings: Equatable, Sendable {
    public let options: [PolarPMDSettingType: [[UInt8]]]

    public init(options: [PolarPMDSettingType: [[UInt8]]] = [:]) {
        self.options = options
    }

    public init(parameters: [UInt8]) throws {
        var parsed: [PolarPMDSettingType: [[UInt8]]] = [:]
        var offset = 0
        while offset < parameters.count {
            guard offset + 2 <= parameters.count else {
                throw PolarPMDError.truncated("settings header at byte \(offset)")
            }
            guard let type = PolarPMDSettingType(rawValue: parameters[offset]) else {
                throw PolarPMDError.unsupported("setting type \(parameters[offset])")
            }
            let count = Int(parameters[offset + 1])
            offset += 2
            guard count <= 64 else {
                throw PolarPMDError.limitExceeded("setting \(type) advertises \(count) values")
            }
            let byteCount = count.multipliedReportingOverflow(by: type.fieldWidth)
            guard !byteCount.overflow, offset + byteCount.partialValue <= parameters.count else {
                throw PolarPMDError.truncated("\(type) values")
            }
            var values: [[UInt8]] = []
            values.reserveCapacity(count)
            for _ in 0..<count {
                let end = offset + type.fieldWidth
                values.append(Array(parameters[offset..<end]))
                offset = end
            }
            parsed[type] = values
        }
        options = parsed
    }

    /// Unsigned numeric options for an ordinary 1/2/4-byte setting.
    public func numericOptions(_ type: PolarPMDSettingType) -> [UInt32] {
        guard type.fieldWidth <= 4 else { return [] }
        return (options[type] ?? []).compactMap(Self.unsignedLE)
    }

    /// IEEE-754 scale returned in a start response, or 1 when no factor was returned.
    public var factor: Double {
        guard let bits = numericOptions(.factor).first else { return 1 }
        return Double(Float(bitPattern: bits))
    }

    /// Deterministic "maximum advertised value" selection, matching Polar's public SDK
    /// examples. A device can reject an invalid combination; the control response remains
    /// authoritative and callers should then try a lower setting.
    public var maximumSelection: [PolarPMDSettingType: UInt32] {
        var selected: [PolarPMDSettingType: UInt32] = [:]
        for type in PolarPMDSettingType.allCases where !type.isResponseOnly {
            if let maximum = numericOptions(type).max() {
                selected[type] = maximum
            }
        }
        return selected
    }

    public static func encodeSelection(_ selected: [PolarPMDSettingType: UInt32]) throws -> [UInt8] {
        var output: [UInt8] = []
        for type in selected.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard !type.isResponseOnly else { continue }
            guard type.fieldWidth <= 4 else {
                throw PolarPMDError.unsupported("numeric encoding for \(type)")
            }
            guard let value = selected[type] else { continue }
            let maxValue: UInt64 = type.fieldWidth == 4
                ? UInt64(UInt32.max)
                : (UInt64(1) << UInt64(type.fieldWidth * 8)) - 1
            guard UInt64(value) <= maxValue else {
                throw PolarPMDError.malformed("\(type) value \(value) exceeds \(type.fieldWidth) bytes")
            }
            // The byte after the setting type is a VALUE COUNT, not a byte length.
            output.append(type.rawValue)
            output.append(1)
            for shift in stride(from: 0, to: type.fieldWidth * 8, by: 8) {
                output.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
            }
        }
        return output
    }

    private static func unsignedLE(_ bytes: [UInt8]) -> UInt32? {
        guard !bytes.isEmpty, bytes.count <= 4 else { return nil }
        var value: UInt32 = 0
        for (index, byte) in bytes.enumerated() {
            value |= UInt32(byte) << UInt32(index * 8)
        }
        return value
    }
}

public enum PolarPMDControlOpcode: UInt8, Codable, Sendable {
    case getMeasurementSettings = 1
    case startMeasurement = 2
    case stopMeasurement = 3
    case getSDKModeMeasurementSettings = 4
    case getMeasurementStatus = 5
    case getSDKModeStatus = 6
}

public enum PolarPMDCommand {
    public static func querySettings(_ measurement: PolarPMDMeasurement) -> [UInt8] {
        [PolarPMDControlOpcode.getMeasurementSettings.rawValue, measurement.rawValue]
    }

    public static func start(_ measurement: PolarPMDMeasurement,
                             selection: [PolarPMDSettingType: UInt32] = [:]) throws -> [UInt8] {
        [PolarPMDControlOpcode.startMeasurement.rawValue, measurement.rawValue]
            + (try PolarPMDSettings.encodeSelection(selection))
    }

    public static func stop(_ measurement: PolarPMDMeasurement) -> [UInt8] {
        [PolarPMDControlOpcode.stopMeasurement.rawValue, measurement.rawValue]
    }
}

public struct PolarPMDControlResponse: Equatable, Sendable {
    public static let responseMarker: UInt8 = 0xF0

    public let opcode: UInt8
    public let measurementByte: UInt8
    public let status: UInt8
    public let hasMore: Bool
    public let parameters: [UInt8]

    public var measurement: PolarPMDMeasurement? {
        PolarPMDMeasurement(wireByte: measurementByte)
    }
    public var succeeded: Bool { status == 0 }

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= 4 else {
            throw PolarPMDError.truncated("control response")
        }
        guard bytes[0] == Self.responseMarker else {
            throw PolarPMDError.malformed("control marker \(bytes[0])")
        }
        opcode = bytes[1]
        measurementByte = bytes[2]
        status = bytes[3]
        if status == 0 {
            hasMore = bytes.count >= 5 && bytes[4] != 0
            parameters = bytes.count > 5 ? Array(bytes[5...]) : []
        } else {
            hasMore = false
            parameters = []
        }
    }

    init(opcode: UInt8, measurementByte: UInt8, status: UInt8,
         hasMore: Bool, parameters: [UInt8]) {
        self.opcode = opcode
        self.measurementByte = measurementByte
        self.status = status
        self.hasMore = hasMore
        self.parameters = parameters
    }
}

/// Reassembles a multi-notification control response. Polar repeats the five-byte
/// response header on each part; only the parameter tails are concatenated.
public struct PolarPMDControlResponseAssembler: Sendable {
    private var partial: PolarPMDControlResponse?
    private let maximumParameterBytes: Int

    public init(maximumParameterBytes: Int = 4_096) {
        self.maximumParameterBytes = maximumParameterBytes
    }

    public mutating func reset() {
        partial = nil
    }

    /// Returns a complete response, or nil while another part is required.
    public mutating func append(_ bytes: [UInt8]) throws -> PolarPMDControlResponse? {
        let next = try PolarPMDControlResponse(bytes: bytes)
        if var current = partial {
            guard current.opcode == next.opcode,
                  current.measurementByte == next.measurementByte,
                  current.status == next.status else {
                partial = nil
                throw PolarPMDError.malformed("control response parts do not match")
            }
            let combinedCount = current.parameters.count + next.parameters.count
            guard combinedCount <= maximumParameterBytes else {
                partial = nil
                throw PolarPMDError.limitExceeded("control response parameters")
            }
            current = PolarPMDControlResponse(
                opcode: current.opcode,
                measurementByte: current.measurementByte,
                status: current.status,
                hasMore: next.hasMore,
                parameters: current.parameters + next.parameters
            )
            if next.hasMore {
                partial = current
                return nil
            }
            partial = nil
            return current
        }

        guard next.parameters.count <= maximumParameterBytes else {
            throw PolarPMDError.limitExceeded("control response parameters")
        }
        if next.hasMore {
            partial = next
            return nil
        }
        return next
    }
}

// MARK: - Hardware-independent control-point state machine

public struct PolarPMDStartedStream: Equatable, Sendable {
    public let measurement: PolarPMDMeasurement
    public let selection: [PolarPMDSettingType: UInt32]
    public let startResponse: PolarPMDSettings?

    public init(measurement: PolarPMDMeasurement,
                selection: [PolarPMDSettingType: UInt32],
                startResponse: PolarPMDSettings?) {
        self.measurement = measurement
        self.selection = selection
        self.startResponse = startResponse
    }
}

public struct PolarPMDSessionUpdate: Equatable, Sendable {
    /// Next control-point value to write, if the session has more setup work.
    public let command: [UInt8]?
    /// A stream whose start response just succeeded and can now configure the data decoder.
    public let started: PolarPMDStartedStream?
    /// A stream skipped after a settings/start rejection or malformed successful response.
    public let skipped: PolarPMDMeasurement?
    public let finished: Bool

    public init(command: [UInt8]? = nil,
                started: PolarPMDStartedStream? = nil,
                skipped: PolarPMDMeasurement? = nil,
                finished: Bool = false) {
        self.command = command
        self.started = started
        self.skipped = skipped
        self.finished = finished
    }
}

/// Serial planner for PMD setup. BLE control points allow only one in-flight command:
/// query one stream's settings, start it, then advance. A rejected stream is skipped
/// without preventing the remaining supported streams from starting.
public struct PolarPMDSessionPlanner: Sendable {
    private enum Phase: Sendable {
        case idle
        case querying(PolarPMDMeasurement)
        case starting(PolarPMDMeasurement, [PolarPMDSettingType: UInt32])
        case finished
    }

    private var queue: [PolarPMDMeasurement] = []
    private var phase: Phase = .idle

    public init() {}

    public mutating func reset() {
        queue.removeAll()
        phase = .idle
    }

    /// Begin with the intersection of requested and advertised streams. The requested order
    /// is preserved, making energy/utility priority explicit at the call site.
    public mutating func begin(features: PolarPMDFeatures,
                               requested: [PolarPMDMeasurement]) -> PolarPMDSessionUpdate {
        var seen = Set<PolarPMDMeasurement>()
        queue = requested.filter {
            features.supports($0) && seen.insert($0).inserted
        }
        return advance()
    }

    public mutating func handle(_ response: PolarPMDControlResponse) -> PolarPMDSessionUpdate {
        switch phase {
        case .idle:
            return PolarPMDSessionUpdate()
        case .finished:
            return PolarPMDSessionUpdate(finished: true)

        case .querying(let measurement):
            guard response.opcode == PolarPMDControlOpcode.getMeasurementSettings.rawValue,
                  response.measurement == measurement else {
                reset()
                return PolarPMDSessionUpdate(skipped: measurement, finished: true)
            }
            guard response.succeeded,
                  let settings = try? PolarPMDSettings(parameters: response.parameters) else {
                return advance(skipped: measurement)
            }
            let selection = settings.maximumSelection
            phase = .starting(measurement, selection)
            guard let command = try? PolarPMDCommand.start(measurement, selection: selection) else {
                return advance(skipped: measurement)
            }
            return PolarPMDSessionUpdate(command: command)

        case .starting(let measurement, let selection):
            guard response.opcode == PolarPMDControlOpcode.startMeasurement.rawValue,
                  response.measurement == measurement else {
                reset()
                return PolarPMDSessionUpdate(skipped: measurement, finished: true)
            }
            guard response.succeeded else {
                return advance(skipped: measurement)
            }
            let startSettings: PolarPMDSettings?
            if response.parameters.isEmpty {
                startSettings = nil
            } else {
                guard let parsed = try? PolarPMDSettings(parameters: response.parameters) else {
                    return advance(skipped: measurement)
                }
                startSettings = parsed
            }
            let started = PolarPMDStartedStream(
                measurement: measurement,
                selection: selection,
                startResponse: startSettings
            )
            return advance(started: started)
        }
    }

    private mutating func advance(started: PolarPMDStartedStream? = nil,
                                  skipped: PolarPMDMeasurement? = nil) -> PolarPMDSessionUpdate {
        guard !queue.isEmpty else {
            phase = .finished
            return PolarPMDSessionUpdate(started: started, skipped: skipped, finished: true)
        }
        let next = queue.removeFirst()
        phase = .querying(next)
        return PolarPMDSessionUpdate(
            command: PolarPMDCommand.querySettings(next),
            started: started,
            skipped: skipped
        )
    }
}
