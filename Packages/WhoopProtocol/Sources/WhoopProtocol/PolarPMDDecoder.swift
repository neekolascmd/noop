import Foundation

// MARK: - Polar PMD data plane

public struct PolarPMDDataFrame: Equatable, Sendable {
    public let measurement: PolarPMDMeasurement
    public let sensorTimestampNs: UInt64
    public let frameType: UInt8
    public let isCompressed: Bool
    public let payload: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= 10 else {
            throw PolarPMDError.truncated("data-frame header")
        }
        guard let measurement = PolarPMDMeasurement(wireByte: bytes[0]) else {
            throw PolarPMDError.unsupported("measurement type \(bytes[0] & 0x3F)")
        }
        var timestamp: UInt64 = 0
        for index in 0..<8 {
            timestamp |= UInt64(bytes[index + 1]) << UInt64(index * 8)
        }
        self.measurement = measurement
        sensorTimestampNs = timestamp
        frameType = bytes[9] & 0x7F
        isCompressed = bytes[9] & 0x80 != 0
        payload = Array(bytes.dropFirst(10))
    }
}

public struct PolarPMDECGSample: Equatable, Sendable {
    public let sensorTimestampNs: UInt64
    public let microVolts: Int
}

public struct PolarPMDPPGSample: Equatable, Sendable {
    public let sensorTimestampNs: UInt64
    public let channels: [Int]
    public let ambient: Int
}

public struct PolarPMDAccelerationSample: Equatable, Sendable {
    public let sensorTimestampNs: UInt64
    public let xMilliG: Int
    public let yMilliG: Int
    public let zMilliG: Int
}

public struct PolarPMDPPISample: Equatable, Sendable {
    public let sensorTimestampNs: UInt64
    public let heartRate: Int
    public let intervalMs: Int
    public let errorEstimateMs: Int
    /// Polar's bit 0: the peak-to-peak sample was blocked/invalid.
    public let blocker: Bool
    /// nil when the device says contact sensing is unsupported; otherwise current contact.
    public let skinContact: Bool?
}

public struct PolarPMDDecodedFrame: Equatable, Sendable {
    public let frame: PolarPMDDataFrame
    public var ecg: [PolarPMDECGSample] = []
    public var ppg: [PolarPMDPPGSample] = []
    public var acceleration: [PolarPMDAccelerationSample] = []
    public var ppi: [PolarPMDPPISample] = []

    public init(frame: PolarPMDDataFrame) {
        self.frame = frame
    }
}

public struct PolarPMDDecodeSettings: Equatable, Sendable {
    public var sampleRateHz: Int
    public var factor: Double

    public init(sampleRateHz: Int = 0, factor: Double = 1) {
        self.sampleRateHz = sampleRateHz
        self.factor = factor
    }
}

/// Stateful decoder: the PMD timestamp interpolation contract uses the preceding frame
/// timestamp for the same `(measurement, frameType)` pair when one exists.
public struct PolarPMDDecoder: Sendable {
    private struct StreamKey: Hashable, Sendable {
        let measurement: PolarPMDMeasurement
        let frameType: UInt8
    }

    private var previousTimestamps: [StreamKey: UInt64] = [:]
    private var settings: [PolarPMDMeasurement: PolarPMDDecodeSettings] = [:]

    public init() {}

    public mutating func reset() {
        previousTimestamps.removeAll()
        settings.removeAll()
    }

    public mutating func configure(_ measurement: PolarPMDMeasurement,
                                   sampleRateHz: Int,
                                   factor: Double = 1) {
        settings[measurement] = PolarPMDDecodeSettings(
            sampleRateHz: sampleRateHz,
            factor: factor.isFinite ? factor : 1
        )
    }

    public mutating func configure(_ measurement: PolarPMDMeasurement,
                                   selection: [PolarPMDSettingType: UInt32],
                                   startResponse: PolarPMDSettings? = nil) {
        let rate = Int(selection[.sampleRate] ?? 0)
        configure(measurement, sampleRateHz: rate, factor: startResponse?.factor ?? 1)
    }

    public mutating func decode(_ bytes: [UInt8]) throws -> PolarPMDDecodedFrame {
        let frame = try PolarPMDDataFrame(bytes: bytes)
        let key = StreamKey(measurement: frame.measurement, frameType: frame.frameType)
        let previous = previousTimestamps[key] ?? 0
        let config = settings[frame.measurement] ?? PolarPMDDecodeSettings()

        let decoded: PolarPMDDecodedFrame
        switch frame.measurement {
        case .ecg:
            decoded = try decodeECG(frame, previous: previous, sampleRate: config.sampleRateHz)
        case .ppg:
            decoded = try decodePPG(frame, previous: previous, sampleRate: config.sampleRateHz,
                                    factor: config.factor)
        case .accelerometer:
            decoded = try decodeAcceleration(frame, previous: previous,
                                             sampleRate: config.sampleRateHz,
                                             factor: config.factor)
        case .ppi:
            decoded = try decodePPI(frame)
        default:
            throw PolarPMDError.unsupported("measurement \(frame.measurement)")
        }

        previousTimestamps[key] = frame.sensorTimestampNs
        return decoded
    }

    private func decodeECG(_ frame: PolarPMDDataFrame,
                           previous: UInt64,
                           sampleRate: Int) throws -> PolarPMDDecodedFrame {
        guard !frame.isCompressed, frame.frameType == 0 else {
            throw PolarPMDError.unsupported("ECG frame type \(frame.frameType), compressed=\(frame.isCompressed)")
        }
        let width = 3
        guard !frame.payload.isEmpty, frame.payload.count % width == 0 else {
            throw PolarPMDError.truncated("ECG type-0 sample")
        }
        let count = frame.payload.count / width
        let timestamps = try Self.timestamps(end: frame.sensorTimestampNs, previous: previous,
                                             count: count, sampleRate: sampleRate)
        var output = PolarPMDDecodedFrame(frame: frame)
        output.ecg.reserveCapacity(count)
        for index in 0..<count {
            output.ecg.append(PolarPMDECGSample(
                sensorTimestampNs: timestamps[index],
                microVolts: try Self.signedLE(frame.payload, at: index * width,
                                              byteCount: width, significantBits: 24)
            ))
        }
        return output
    }

    private func decodePPG(_ frame: PolarPMDDataFrame,
                           previous: UInt64,
                           sampleRate: Int,
                           factor: Double) throws -> PolarPMDDecodedFrame {
        guard frame.frameType == 0 else {
            throw PolarPMDError.unsupported("PPG frame type \(frame.frameType)")
        }
        let vectors: [[Int]]
        if frame.isCompressed {
            vectors = try Self.deltaSamples(frame.payload, channels: 4, resolution: 24)
        } else {
            let sampleBytes = 12
            guard !frame.payload.isEmpty, frame.payload.count % sampleBytes == 0 else {
                throw PolarPMDError.truncated("PPG type-0 sample")
            }
            vectors = try stride(from: 0, to: frame.payload.count, by: sampleBytes).map { offset in
                try (0..<4).map {
                    try Self.signedLE(frame.payload, at: offset + $0 * 3,
                                      byteCount: 3, significantBits: 24)
                }
            }
        }
        let timestamps = try Self.timestamps(end: frame.sensorTimestampNs, previous: previous,
                                             count: vectors.count, sampleRate: sampleRate)
        var output = PolarPMDDecodedFrame(frame: frame)
        output.ppg.reserveCapacity(vectors.count)
        for (index, vector) in vectors.enumerated() {
            guard vector.count == 4 else {
                throw PolarPMDError.malformed("PPG channel count")
            }
            // Polar applies the start-response factor only to delta-compressed type-0 PPG.
            // Raw type-0 samples are already expressed in their final integer units.
            let scale = frame.isCompressed ? factor : 1
            let scaled = vector.map { Int(Double($0) * scale) }
            output.ppg.append(PolarPMDPPGSample(
                sensorTimestampNs: timestamps[index],
                channels: Array(scaled.prefix(3)),
                ambient: scaled[3]
            ))
        }
        return output
    }

    private func decodeAcceleration(_ frame: PolarPMDDataFrame,
                                    previous: UInt64,
                                    sampleRate: Int,
                                    factor: Double) throws -> PolarPMDDecodedFrame {
        let vectors: [[Int]]
        var scale = factor
        if frame.isCompressed {
            switch frame.frameType {
            case 0:
                // PMD compressed ACC type 0 carries G units with a start-response factor.
                vectors = try Self.deltaSamples(frame.payload, channels: 3, resolution: 16)
                scale *= 1_000
            case 1:
                vectors = try Self.deltaSamples(frame.payload, channels: 3, resolution: 16)
            default:
                throw PolarPMDError.unsupported("compressed ACC frame type \(frame.frameType)")
            }
        } else {
            let width: Int
            switch frame.frameType {
            case 0: width = 1
            case 1: width = 2
            case 2: width = 3
            default:
                throw PolarPMDError.unsupported("raw ACC frame type \(frame.frameType)")
            }
            let sampleBytes = width * 3
            guard !frame.payload.isEmpty, frame.payload.count % sampleBytes == 0 else {
                throw PolarPMDError.truncated("ACC type-\(frame.frameType) sample")
            }
            vectors = try stride(from: 0, to: frame.payload.count, by: sampleBytes).map { offset in
                try (0..<3).map {
                    try Self.signedLE(frame.payload, at: offset + $0 * width,
                                      byteCount: width, significantBits: width * 8)
                }
            }
            // Raw ACC values are already milli-g.
            scale = 1
        }

        let timestamps = try Self.timestamps(end: frame.sensorTimestampNs, previous: previous,
                                             count: vectors.count, sampleRate: sampleRate)
        var output = PolarPMDDecodedFrame(frame: frame)
        output.acceleration.reserveCapacity(vectors.count)
        for (index, vector) in vectors.enumerated() {
            guard vector.count == 3 else {
                throw PolarPMDError.malformed("ACC channel count")
            }
            output.acceleration.append(PolarPMDAccelerationSample(
                sensorTimestampNs: timestamps[index],
                xMilliG: Int(Double(vector[0]) * scale),
                yMilliG: Int(Double(vector[1]) * scale),
                zMilliG: Int(Double(vector[2]) * scale)
            ))
        }
        return output
    }

    private func decodePPI(_ frame: PolarPMDDataFrame) throws -> PolarPMDDecodedFrame {
        guard !frame.isCompressed, frame.frameType == 0 else {
            throw PolarPMDError.unsupported("PPI frame type \(frame.frameType), compressed=\(frame.isCompressed)")
        }
        let width = 6
        guard !frame.payload.isEmpty, frame.payload.count % width == 0 else {
            throw PolarPMDError.truncated("PPI type-0 sample")
        }

        struct Fields {
            let heartRate: Int
            let interval: Int
            let error: Int
            let flags: UInt8
        }
        let fields: [Fields] = stride(from: 0, to: frame.payload.count, by: width).map { offset in
            Fields(
                heartRate: Int(frame.payload[offset]),
                interval: Int(frame.payload[offset + 1]) | (Int(frame.payload[offset + 2]) << 8),
                error: Int(frame.payload[offset + 3]) | (Int(frame.payload[offset + 4]) << 8),
                flags: frame.payload[offset + 5]
            )
        }

        var timestamps = Array(repeating: UInt64(0), count: fields.count)
        var current = frame.sensorTimestampNs
        for index in fields.indices.reversed() {
            timestamps[index] = current
            let delta = UInt64(fields[index].interval) * 1_000_000
            current = current >= delta ? current - delta : 0
        }

        var output = PolarPMDDecodedFrame(frame: frame)
        output.ppi.reserveCapacity(fields.count)
        for (index, value) in fields.enumerated() {
            let contactSupported = value.flags & 0x04 != 0
            output.ppi.append(PolarPMDPPISample(
                sensorTimestampNs: timestamps[index],
                heartRate: value.heartRate,
                intervalMs: value.interval,
                errorEstimateMs: value.error,
                blocker: value.flags & 0x01 != 0,
                skinContact: contactSupported ? value.flags & 0x02 != 0 : nil
            ))
        }
        return output
    }

    // MARK: - Shared wire helpers

    static func timestamps(end: UInt64,
                           previous: UInt64,
                           count: Int,
                           sampleRate: Int) throws -> [UInt64] {
        guard count > 0, count <= 4_096 else {
            throw PolarPMDError.limitExceeded("sample count \(count)")
        }
        if count == 1 { return [end] }

        let delta: Double
        if previous > 0, end > previous {
            delta = Double(end - previous) / Double(count)
        } else {
            guard sampleRate > 0, sampleRate <= 10_000 else {
                throw PolarPMDError.malformed("missing valid sample rate for first frame")
            }
            delta = 1_000_000_000 / Double(sampleRate)
        }
        guard delta.isFinite, delta > 0 else {
            throw PolarPMDError.malformed("invalid timestamp delta")
        }

        let start = previous > 0 && end > previous
            ? Double(previous) + delta
            : Double(end) - delta * Double(count - 1)
        guard start >= 0 else {
            throw PolarPMDError.malformed("negative interpolated timestamp")
        }
        var result: [UInt64] = []
        result.reserveCapacity(count)
        for index in 0..<(count - 1) {
            result.append(UInt64((start + delta * Double(index)).rounded()))
        }
        result.append(end)
        return result
    }

    static func signedLE(_ bytes: [UInt8],
                         at offset: Int,
                         byteCount: Int,
                         significantBits: Int) throws -> Int {
        guard byteCount > 0, byteCount <= 4,
              significantBits > 0, significantBits <= byteCount * 8,
              offset >= 0, offset + byteCount <= bytes.count else {
            throw PolarPMDError.truncated("signed integer at byte \(offset)")
        }
        var raw: UInt32 = 0
        for index in 0..<byteCount {
            raw |= UInt32(bytes[offset + index]) << UInt32(index * 8)
        }
        if significantBits < 32 {
            let valueMask = (UInt32(1) << UInt32(significantBits)) - 1
            raw &= valueMask
            let signBit = UInt32(1) << UInt32(significantBits - 1)
            if raw & signBit != 0 {
                raw |= ~valueMask
            }
        }
        return Int(Int32(bitPattern: raw))
    }

    /// Decode a PMD delta payload: one signed reference vector followed by blocks of
    /// `[deltaBitWidth, sampleCount, packed signed deltas…]`. Packed bits are LSB-first.
    public static func deltaSamples(_ bytes: [UInt8],
                                    channels: Int,
                                    resolution: Int,
                                    maximumSamples: Int = 4_096) throws -> [[Int]] {
        guard channels > 0, channels <= 32,
              resolution > 0, resolution <= 32,
              maximumSamples > 0 else {
            throw PolarPMDError.malformed("delta decoder dimensions")
        }
        let referenceWidth = (resolution + 7) / 8
        let referenceBytes = channels * referenceWidth
        guard bytes.count >= referenceBytes else {
            throw PolarPMDError.truncated("delta reference vector")
        }
        var reference: [Int] = []
        reference.reserveCapacity(channels)
        for channel in 0..<channels {
            reference.append(try signedLE(
                bytes,
                at: channel * referenceWidth,
                byteCount: referenceWidth,
                significantBits: resolution
            ))
        }

        var samples = [reference]
        var offset = referenceBytes
        while offset < bytes.count {
            guard offset + 2 <= bytes.count else {
                throw PolarPMDError.truncated("delta block header")
            }
            let deltaWidth = Int(bytes[offset])
            let count = Int(bytes[offset + 1])
            offset += 2
            guard deltaWidth <= 32 else {
                throw PolarPMDError.unsupported("delta width \(deltaWidth)")
            }
            guard samples.count + count <= maximumSamples else {
                throw PolarPMDError.limitExceeded("delta samples")
            }
            let bitCountResult = count.multipliedReportingOverflow(by: channels)
            guard !bitCountResult.overflow else {
                throw PolarPMDError.limitExceeded("delta bit count")
            }
            let totalBitsResult = bitCountResult.partialValue.multipliedReportingOverflow(by: deltaWidth)
            guard !totalBitsResult.overflow else {
                throw PolarPMDError.limitExceeded("delta bit count")
            }
            let totalBits = totalBitsResult.partialValue
            let packedBytes = (totalBits + 7) / 8
            guard offset + packedBytes <= bytes.count else {
                throw PolarPMDError.truncated("delta block payload")
            }

            var bitOffset = 0
            for _ in 0..<count {
                var next = samples.last!
                for channel in 0..<channels {
                    let delta: Int
                    if deltaWidth == 0 {
                        delta = 0
                    } else {
                        var raw: UInt32 = 0
                        for bit in 0..<deltaWidth {
                            let absoluteBit = bitOffset + bit
                            let byte = bytes[offset + absoluteBit / 8]
                            if byte & (UInt8(1) << UInt8(absoluteBit % 8)) != 0 {
                                raw |= UInt32(1) << UInt32(bit)
                            }
                        }
                        if deltaWidth < 32 {
                            let mask = (UInt32(1) << UInt32(deltaWidth)) - 1
                            let sign = UInt32(1) << UInt32(deltaWidth - 1)
                            if raw & sign != 0 { raw |= ~mask }
                        }
                        delta = Int(Int32(bitPattern: raw))
                    }
                    let sum = next[channel].addingReportingOverflow(delta)
                    guard !sum.overflow else {
                        throw PolarPMDError.malformed("delta accumulation overflow")
                    }
                    next[channel] = sum.partialValue
                    bitOffset += deltaWidth
                }
                samples.append(next)
            }
            offset += packedBytes
        }
        return samples
    }
}

/// Maps the sensor's PMD nanosecond clock onto Unix nanoseconds.
///
/// Polar defines PMD timestamps relative to 2000-01-01. If that candidate is plausible,
/// it is used directly. Sensors whose clock was never set are instead anchored to the
/// host receive time; the stable offset preserves all inter-sample spacing.
public struct PolarPMDClock: Sendable {
    public static let polarToUnixEpochNs: UInt64 = 946_684_800_000_000_000
    /// A live sensor clock farther from receive time than this is treated as unset/stale.
    public static let liveClockToleranceNs: UInt64 = 5 * 60 * 1_000_000_000
    private var fallbackOffset: Int64?

    public init() {}

    public mutating func reset() {
        fallbackOffset = nil
    }

    public mutating func unixNanoseconds(sensorTimestampNs: UInt64,
                                         receivedAtUnixNs: UInt64) -> UInt64 {
        let candidateResult = sensorTimestampNs.addingReportingOverflow(Self.polarToUnixEpochNs)
        if !candidateResult.overflow {
            let candidate = candidateResult.partialValue
            let difference = candidate >= receivedAtUnixNs
                ? candidate - receivedAtUnixNs
                : receivedAtUnixNs - candidate
            if difference <= Self.liveClockToleranceNs {
                return candidate
            }
        }

        if fallbackOffset == nil {
            let receive = Int64(clamping: receivedAtUnixNs)
            let sensor = Int64(clamping: sensorTimestampNs)
            fallbackOffset = receive.subtractingReportingOverflow(sensor).partialValue
        }
        let mapped = Int64(clamping: sensorTimestampNs)
            .addingReportingOverflow(fallbackOffset ?? 0)
        return mapped.overflow || mapped.partialValue < 0 ? receivedAtUnixNs : UInt64(mapped.partialValue)
    }

    /// PPI frames are allowed to carry a zero timestamp because an exact sample time may be
    /// unavailable. In that case, anchor the newest beat to receive time and walk older beats
    /// backward by their intervals instead of mapping every zero to one stale instant.
    public mutating func unixNanoseconds(ppiSamples: [PolarPMDPPISample],
                                         receivedAtUnixNs: UInt64) -> [UInt64] {
        guard !ppiSamples.isEmpty else { return [] }
        guard ppiSamples.allSatisfy({ $0.sensorTimestampNs == 0 }) else {
            return ppiSamples.map {
                unixNanoseconds(
                    sensorTimestampNs: $0.sensorTimestampNs,
                    receivedAtUnixNs: receivedAtUnixNs
                )
            }
        }

        var timestamps = Array(repeating: receivedAtUnixNs, count: ppiSamples.count)
        var current = receivedAtUnixNs
        for index in ppiSamples.indices.reversed() {
            timestamps[index] = current
            let product = UInt64(max(0, ppiSamples[index].intervalMs))
                .multipliedReportingOverflow(by: 1_000_000)
            let delta = product.overflow ? UInt64.max : product.partialValue
            current = current >= delta ? current - delta : 0
        }
        return timestamps
    }
}
