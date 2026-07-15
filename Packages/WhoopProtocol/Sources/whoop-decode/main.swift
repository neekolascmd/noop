import Foundation
import WhoopProtocol

// whoop-decode — decode captured WHOOP frames with the SAME WhoopProtocol decoder the macOS/iOS app
// uses, from the command line on any platform (Linux included). This is the Swift half of the
// headless protocol-RE workflow: the Python `whoop_capture.py` tool records frames off a strap into a
// capture JSON file, and this decodes them — guaranteeing the Linux RE path and the app agree
// byte-for-byte (no second decoder to drift).
//
// Usage:
//   whoop-decode [options] [FILE]
//   cat capture.json | whoop-decode --family whoop5
//   whoop-decode --hex aa0108000001e67123019101363e5c8d
//
// Input (any one of):
//   FILE            a capture/fixture JSON array or append-only JSONL of {"hex": …} objects. Richer
//                   Apple/Android provenance records are supersets and are read too.
//   (stdin)         the same JSON, piped in, when no FILE is given.
//   --hex HEX …     one or more raw frame hex strings instead of a file.
//
// Options:
//   --family F      whoop4 | whoop5 | auto   (default: auto — per-frame from `char`, else whoop5)
//   --json          emit decoded frames as JSON (ParsedFrame + provenance) instead of a text dump
//   --raw-only      print only frames that did NOT fully decode (ok=false) — the RE worklist
//   -h, --help      show this help

// MARK: - Input model

/// One input frame. `hex` is required; the rest are provenance the capture tool adds and the decoder
/// ignores (but we use `char` to pick the family and echo `hr`/`ts_ms` for correlation).
struct CaptureRecord: Decodable {
    let hex: String
    let char: String?
    let hr: Int?
    let tsMs: Int?
    let direction: String?
    let offload: Bool?
    let sessionId: String?
    let firmware: String?
    let worn: Bool?
    let batteryPct: Double?

    enum CodingKeys: String, CodingKey {
        case hex, char, characteristic, hr, direction, offload, firmware, worn
        case tsMs = "ts_ms"
        case capturedAtMs = "captured_at_ms"
        case sessionId = "session_id"
        case batteryPct = "battery_pct"
    }

    init(hex: String, char: String? = nil, hr: Int? = nil, tsMs: Int? = nil,
         direction: String? = nil, offload: Bool? = nil, sessionId: String? = nil,
         firmware: String? = nil, worn: Bool? = nil, batteryPct: Double? = nil) {
        self.hex = hex; self.char = char; self.hr = hr; self.tsMs = tsMs
        self.direction = direction; self.offload = offload; self.sessionId = sessionId
        self.firmware = firmware; self.worn = worn; self.batteryPct = batteryPct
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hex = try c.decode(String.self, forKey: .hex)
        let primaryChar = try c.decodeIfPresent(String.self, forKey: .char)
        let legacyChar = try c.decodeIfPresent(String.self, forKey: .characteristic)
        char = primaryChar ?? legacyChar
        hr = try c.decodeIfPresent(Int.self, forKey: .hr)
        let appleTs = try c.decodeIfPresent(Int.self, forKey: .tsMs)
        let androidTs = try c.decodeIfPresent(Int.self, forKey: .capturedAtMs)
        tsMs = appleTs ?? androidTs
        direction = try c.decodeIfPresent(String.self, forKey: .direction)
        offload = try c.decodeIfPresent(Bool.self, forKey: .offload)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        firmware = try c.decodeIfPresent(String.self, forKey: .firmware)
        worn = try c.decodeIfPresent(Bool.self, forKey: .worn)
        batteryPct = try c.decodeIfPresent(Double.self, forKey: .batteryPct)
    }
}

enum FamilyMode { case whoop4, whoop5, auto }

// MARK: - Arg parsing (dependency-free)

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

let helpText = """
whoop-decode — decode captured WHOOP frames with the WhoopProtocol decoder.

USAGE:
  whoop-decode [--family whoop4|whoop5|auto] [--json] [--raw-only] [FILE]
  cat capture.json | whoop-decode --family whoop5
  whoop-decode --hex aa0108000001e67123019101363e5c8d

Reads a capture/fixture JSON array or NOOP Android JSONL of {"hex": …} (richer
provenance records are read too) from FILE or stdin, or raw frames from --hex.
Family defaults to auto: derived per-frame from `char`/`characteristic`
(fd4b…→whoop5, 6108…→whoop4), falling back to whoop5.
"""

var familyMode: FamilyMode = .auto
var jsonOut = false
var rawOnly = false
var hexArgs: [String] = []
var filePath: String?

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "-h", "--help":
        print(helpText); exit(0)
    case "--json": jsonOut = true
    case "--raw-only": rawOnly = true
    case "--family":
        i += 1
        guard i < args.count else { die("--family needs a value") }
        switch args[i] {
        case "whoop4": familyMode = .whoop4
        case "whoop5": familyMode = .whoop5
        case "auto": familyMode = .auto
        default: die("--family must be whoop4|whoop5|auto")
        }
    case "--hex":
        i += 1
        // Consume following non-flag tokens as hex frames.
        while i < args.count && !args[i].hasPrefix("--") {
            hexArgs.append(args[i]); i += 1
        }
        continue
    default:
        if a.hasPrefix("-") { die("unknown option: \(a)") }
        filePath = a
    }
    i += 1
}

// MARK: - Gather input records

func loadJSON(_ data: Data) -> [CaptureRecord] {
    let decoder = JSONDecoder()
    if let array = try? decoder.decode([CaptureRecord].self, from: data) { return array }
    guard let text = String(data: data, encoding: .utf8) else { die("capture is not UTF-8") }
    var records: [CaptureRecord] = []
    let lines = text.split(whereSeparator: \.isNewline)
    let hasTerminatedTail = text.hasSuffix("\n") || text.hasSuffix("\r")
    do {
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            do {
                records.append(try decoder.decode(CaptureRecord.self, from: Data(trimmed.utf8)))
            } catch where index == lines.count - 1 && !hasTerminatedTail {
                FileHandle.standardError.write(Data("warning: ignored torn final JSONL record\n".utf8))
            }
        }
    } catch {
        die("could not parse capture JSON/JSONL: \(error)")
    }
    if records.isEmpty { die("capture contains no frame records") }
    return records
}

var records: [CaptureRecord] = []
if !hexArgs.isEmpty {
    records = hexArgs.map { CaptureRecord(hex: $0, char: nil, hr: nil, tsMs: nil) }
} else if let path = filePath {
    guard let data = FileManager.default.contents(atPath: path) else { die("cannot read file: \(path)") }
    records = loadJSON(data)
} else {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else { die(helpText) }
    records = loadJSON(data)
}

// MARK: - Decode helpers

func bytes(fromHex hex: String) -> [UInt8]? {
    let s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.count % 2 == 0 else { return nil }
    var out = [UInt8](); out.reserveCapacity(s.count / 2)
    var idx = s.startIndex
    while idx < s.endIndex {
        let next = s.index(idx, offsetBy: 2)
        guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
        out.append(b); idx = next
    }
    return out
}

func resolveFamily(_ rec: CaptureRecord) -> DeviceFamily {
    switch familyMode {
    case .whoop4: return .whoop4
    case .whoop5: return .whoop5
    case .auto:
        if let c = rec.char?.lowercased() {
            if c.hasPrefix("fd4b") { return .whoop5 }
            if c.hasPrefix("6108") { return .whoop4 }
        }
        return .whoop5   // RE focus is the puffin protocol
    }
}

/// Left- or right-justify `s` to `width` with spaces (manual, to avoid String(format:) %@ on Linux).
func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
    if s.count >= width { return s }
    let fill = String(repeating: " ", count: width - s.count)
    return right ? fill + s : s + fill
}

func render(_ v: ParsedValue?) -> String {
    guard let v else { return "—" }
    switch v {
    case .int(let n): return String(n)
    case .double(let d): return String(d)
    case .string(let s): return s
    case .intArray(let a): return "[\(a.count) ints]"
    case .bool(let b): return String(b)
    case .null: return "null"
    }
}

// MARK: - Run

struct DecodedOut: Encodable {
    let char: String?
    let hr: Int?
    let tsMs: Int?
    let direction: String?
    let offload: Bool?
    let sessionId: String?
    let firmware: String?
    let worn: Bool?
    let batteryPct: Double?
    let family: String
    let frame: ParsedFrame
    enum CodingKeys: String, CodingKey {
        case char, hr, direction, offload, firmware, worn, family, frame
        case tsMs = "ts_ms"; case sessionId = "session_id"; case batteryPct = "battery_pct"
    }
}

var decodedOut: [DecodedOut] = []
var typeCounts: [String: Int] = [:]
var layoutCounts: [String: Int] = [:]
var okCount = 0, total = 0

for (n, rec) in records.enumerated() {
    guard let frame = bytes(fromHex: rec.hex) else {
        FileHandle.standardError.write(Data("skipping bad hex at index \(n)\n".utf8))
        continue
    }
    let family = resolveFamily(rec)
    // Full diagnostic decode (D#742): the CLI is the annotated-fields inspector, so it opts into
    // the per-field metadata the live pipeline skips.
    let parsed = parseFrame(frame, family: family, collectFields: true)
    total += 1
    // A structurally parsed frame with a failed CRC is still raw evidence, not a fully decoded success.
    // Keep it on the --raw-only worklist and out of the success count.
    let fullyDecoded = parsed.ok && parsed.crcOK != false
    if fullyDecoded { okCount += 1 }
    typeCounts[parsed.typeName, default: 0] += 1
    let version = parsed.parsed["hist_version"]?.intValue.map { " v\($0)" } ?? ""
    layoutCounts["\(parsed.typeName)\(version) · \(frame.count)B · \(rec.char ?? "unknown-char")", default: 0] += 1

    if rawOnly && fullyDecoded { continue }

    if jsonOut {
        decodedOut.append(DecodedOut(char: rec.char, hr: rec.hr, tsMs: rec.tsMs,
                                     direction: rec.direction, offload: rec.offload,
                                     sessionId: rec.sessionId, firmware: rec.firmware,
                                     worn: rec.worn, batteryPct: rec.batteryPct,
                                     family: family.rawValue, frame: parsed))
        continue
    }

    // Text dump.
    let crc = parsed.crcOK.map { $0 ? "ok" : "BAD" } ?? "—"
    var head = "[\(n)] \(family.rawValue) ok=\(parsed.ok) type=\(parsed.typeName) seq=\(parsed.seq.map(String.init) ?? "—") crc=\(crc)"
    if let c = rec.char { head += " char=\(c)" }
    if let hr = rec.hr { head += " hr=\(hr)" }
    if let direction = rec.direction { head += " direction=\(direction)" }
    if rec.offload == true { head += " offload=true" }
    if let firmware = rec.firmware { head += " fw=\(firmware)" }
    print(head)
    for f in parsed.fields {
        let note = f.note.map { "  // \($0)" } ?? ""
        let off = pad(String(f.off), 4, right: true)
        let name = pad(f.name, 14)
        let val = pad(render(f.value), 18)
        print("      \(off)  \(name) = \(val) (\(f.raw))\(note)")
    }
}

if jsonOut {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    if let data = try? enc.encode(decodedOut), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
} else {
    // Summary to stderr so it doesn't pollute a piped dump.
    var summary = "\n— \(okCount)/\(total) frames decoded ok —\n"
    for (t, c) in typeCounts.sorted(by: { $0.value > $1.value }) {
        summary += "  \(pad(String(c), 5, right: true))  \(t)\n"
    }
    summary += "— layout / size / characteristic —\n"
    for (layout, count) in layoutCounts.sorted(by: { $0.value > $1.value }) {
        summary += "  \(pad(String(count), 5, right: true))  \(layout)\n"
    }
    FileHandle.standardError.write(Data(summary.utf8))
}
