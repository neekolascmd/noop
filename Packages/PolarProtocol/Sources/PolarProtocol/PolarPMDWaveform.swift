import Foundation

/// The dense PMD streams NOOP retains in its bounded rolling waveform store.
public enum PolarPMDWaveformKind: String, Codable, CaseIterable, Sendable {
    case ecg = "polar_ecg"
    case ppg = "polar_ppg"
}

/// A compact, platform-neutral block of interleaved signed-32-bit samples.
///
/// `payload` is row-major `int32_le_v1`: one ECG value per sample, or PPG channel 0/1/2/ambient
/// per sample. Exact sample instants are reconstructed linearly from `startUnixNs`, `endUnixNs`,
/// and `sampleCount`; the decoder already interpolates those instants from the device clock.
public struct PolarPMDWaveformChunk: Equatable, Sendable {
    public static let encoding = "int32_le_v1"

    public let kind: PolarPMDWaveformKind
    public let startUnixNs: UInt64
    public let endUnixNs: UInt64
    public let sampleRateHz: Int
    public let channels: Int
    public let sampleCount: Int
    public let payload: [UInt8]

    public init(kind: PolarPMDWaveformKind,
                startUnixNs: UInt64,
                endUnixNs: UInt64,
                sampleRateHz: Int,
                channels: Int,
                sampleCount: Int,
                payload: [UInt8]) {
        self.kind = kind
        self.startUnixNs = startUnixNs
        self.endUnixNs = endUnixNs
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.sampleCount = sampleCount
        self.payload = payload
    }
}

/// Coalesces high-rate notification frames into bounded chunks before they reach SQLite.
///
/// A row per BLE notification would create hundreds of thousands of rows per day. Five-second
/// chunks keep row overhead small, while the hard sample cap prevents one malformed frame or clock
/// from growing an in-memory block without bound.
public struct PolarPMDWaveformBuffer: Sendable {
    public static let targetDurationNs: UInt64 = 5_000_000_000
    public static let maximumSamplesPerChunk = 4_096

    private struct Pending: Sendable {
        let kind: PolarPMDWaveformKind
        let startUnixNs: UInt64
        var endUnixNs: UInt64
        let sampleRateHz: Int
        let channels: Int
        var sampleCount: Int
        var payload: [UInt8]

        func chunk() -> PolarPMDWaveformChunk {
            PolarPMDWaveformChunk(
                kind: kind,
                startUnixNs: startUnixNs,
                endUnixNs: endUnixNs,
                sampleRateHz: sampleRateHz,
                channels: channels,
                sampleCount: sampleCount,
                payload: payload
            )
        }
    }

    private var pending: [PolarPMDWaveformKind: Pending] = [:]

    public init() {}

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    public mutating func append(
        ecg samples: [PolarPMDECGSample],
        unixTimestampsNs: [UInt64],
        sampleRateHz: Int
    ) throws -> [PolarPMDWaveformChunk] {
        guard samples.count == unixTimestampsNs.count else {
            throw PolarPMDError.malformed("ECG waveform timestamp count")
        }
        return try append(
            kind: .ecg,
            unixTimestampsNs: unixTimestampsNs,
            sampleRateHz: sampleRateHz,
            channels: 1,
            values: samples.map { [$0.microVolts] }
        )
    }

    public mutating func append(
        ppg samples: [PolarPMDPPGSample],
        unixTimestampsNs: [UInt64],
        sampleRateHz: Int
    ) throws -> [PolarPMDWaveformChunk] {
        guard samples.count == unixTimestampsNs.count else {
            throw PolarPMDError.malformed("PPG waveform timestamp count")
        }
        let values = try samples.map { sample -> [Int] in
            guard sample.channels.count == 3 else {
                throw PolarPMDError.malformed("PPG waveform channel count")
            }
            return sample.channels + [sample.ambient]
        }
        return try append(
            kind: .ppg,
            unixTimestampsNs: unixTimestampsNs,
            sampleRateHz: sampleRateHz,
            channels: 4,
            values: values
        )
    }

    /// Emit every partial chunk, used on disconnect/stop so the final seconds are durable.
    public mutating func flush() -> [PolarPMDWaveformChunk] {
        let chunks = pending.values.map { $0.chunk() }.sorted {
            if $0.startUnixNs != $1.startUnixNs { return $0.startUnixNs < $1.startUnixNs }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        pending.removeAll(keepingCapacity: true)
        return chunks
    }

    private mutating func append(
        kind: PolarPMDWaveformKind,
        unixTimestampsNs: [UInt64],
        sampleRateHz: Int,
        channels: Int,
        values: [[Int]]
    ) throws -> [PolarPMDWaveformChunk] {
        guard !values.isEmpty else { return [] }
        guard values.count == unixTimestampsNs.count else {
            throw PolarPMDError.malformed("\(kind.rawValue) waveform timestamp count")
        }
        guard (1...10_000).contains(sampleRateHz) else {
            throw PolarPMDError.malformed("\(kind.rawValue) waveform sample rate")
        }
        guard (1...16).contains(channels) else {
            throw PolarPMDError.limitExceeded("\(kind.rawValue) waveform channels")
        }

        var emitted: [PolarPMDWaveformChunk] = []
        for index in values.indices {
            let timestamp = unixTimestampsNs[index]
            let row = values[index]
            guard row.count == channels else {
                throw PolarPMDError.malformed("\(kind.rawValue) waveform row width")
            }

            if let current = pending[kind] {
                guard timestamp > current.endUnixNs else {
                    throw PolarPMDError.malformed("\(kind.rawValue) waveform timestamps are not increasing")
                }
                if current.sampleRateHz != sampleRateHz ||
                    current.channels != channels ||
                    timestamp - current.startUnixNs >= Self.targetDurationNs ||
                    current.sampleCount >= Self.maximumSamplesPerChunk {
                    emitted.append(current.chunk())
                    pending[kind] = nil
                }
            }

            if pending[kind] == nil {
                pending[kind] = Pending(
                    kind: kind,
                    startUnixNs: timestamp,
                    endUnixNs: timestamp,
                    sampleRateHz: sampleRateHz,
                    channels: channels,
                    sampleCount: 0,
                    payload: []
                )
            }

            guard var current = pending[kind] else {
                throw PolarPMDError.malformed("\(kind.rawValue) waveform buffer state")
            }
            for value in row {
                guard let narrowed = Int32(exactly: value) else {
                    throw PolarPMDError.limitExceeded("\(kind.rawValue) waveform sample")
                }
                let raw = UInt32(bitPattern: narrowed)
                current.payload.append(UInt8(truncatingIfNeeded: raw))
                current.payload.append(UInt8(truncatingIfNeeded: raw >> 8))
                current.payload.append(UInt8(truncatingIfNeeded: raw >> 16))
                current.payload.append(UInt8(truncatingIfNeeded: raw >> 24))
            }
            current.endUnixNs = timestamp
            current.sampleCount += 1
            pending[kind] = current
        }
        return emitted
    }
}
