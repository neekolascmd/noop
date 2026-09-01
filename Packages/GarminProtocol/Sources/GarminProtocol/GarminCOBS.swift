import Foundation

public enum GarminCOBSError: Error, Equatable, Sendable { case missingBoundary, malformed, frameTooLarge }

/// Garmin GFDI uses ordinary COBS content wrapped in a leading and trailing zero delimiter.
public enum GarminCOBS {
    public static func encode(_ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0]
        var codeIndex = out.count
        out.append(0)
        var code: UInt8 = 1
        for byte in payload {
            if byte == 0 {
                out[codeIndex] = code
                codeIndex = out.count
                out.append(0)
                code = 1
            } else {
                out.append(byte)
                code &+= 1
                if code == 0xFF {
                    out[codeIndex] = code
                    codeIndex = out.count
                    out.append(0)
                    code = 1
                }
            }
        }
        out[codeIndex] = code
        out.append(0)
        return out
    }

    public static func decode(_ framed: [UInt8], maximumDecodedSize: Int = 65_535) throws -> [UInt8] {
        guard framed.count >= 3, framed.first == 0, framed.last == 0 else { throw GarminCOBSError.missingBoundary }
        let encoded = Array(framed.dropFirst().dropLast())
        var out: [UInt8] = []
        var i = 0
        while i < encoded.count {
            let code = Int(encoded[i])
            guard code != 0, i + code <= encoded.count + 1 else { throw GarminCOBSError.malformed }
            i += 1
            let count = code - 1
            guard i + count <= encoded.count else { throw GarminCOBSError.malformed }
            out.append(contentsOf: encoded[i..<(i + count)])
            i += count
            if code != 0xFF && i < encoded.count { out.append(0) }
            guard out.count <= maximumDecodedSize else { throw GarminCOBSError.frameTooLarge }
        }
        return out
    }
}

/// Bounded delimiter reassembly for arbitrarily split or coalesced BLE notifications.
public struct GarminCOBSStreamDecoder: Sendable {
    public let maximumEncodedSize: Int
    private var encoded: [UInt8] = []
    private var insideFrame = false
    private var droppingOversize = false

    public init(maximumEncodedSize: Int = 65_536) {
        precondition(maximumEncodedSize > 0)
        self.maximumEncodedSize = maximumEncodedSize
    }

    public mutating func feed(_ bytes: [UInt8]) -> [Result<[UInt8], GarminCOBSError>] {
        var results: [Result<[UInt8], GarminCOBSError>] = []
        for byte in bytes {
            if byte == 0 {
                if droppingOversize {
                    droppingOversize = false; encoded.removeAll(keepingCapacity: true); insideFrame = true
                } else if insideFrame && !encoded.isEmpty {
                    let framed = [UInt8(0)] + encoded + [0]
                    do {
                        results.append(.success(try GarminCOBS.decode(
                            framed,
                            maximumDecodedSize: maximumEncodedSize
                        )))
                    } catch let error as GarminCOBSError {
                        results.append(.failure(error))
                    } catch {
                        // `GarminCOBS.decode` is intentionally closed over GarminCOBSError. Keep this
                        // fallback deterministic if that implementation ever changes.
                        results.append(.failure(.malformed))
                    }
                    encoded.removeAll(keepingCapacity: true)
                    insideFrame = true
                } else {
                    insideFrame = true
                }
            } else if insideFrame && !droppingOversize {
                encoded.append(byte)
                if encoded.count > maximumEncodedSize {
                    encoded.removeAll(keepingCapacity: true)
                    droppingOversize = true
                    results.append(.failure(.frameTooLarge))
                }
            }
        }
        return results
    }
}
