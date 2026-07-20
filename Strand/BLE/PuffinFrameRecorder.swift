import Foundation
import CoreBluetooth
import WhoopProtocol

/// App-side glue around the pure `PuffinCapture`: gates on a user toggle, stamps each frame with a
/// wall-clock time and the live (standard-profile) heart rate, and persists the growing capture to a
/// append-only JSONL file under Application Support. Passive with respect to the strap: it records
/// notifications and copies of commands BLEManager was already sending, and never causes a write.
///
/// `@MainActor` because it reads `LiveState.heartRate` and updates published capture status; the
/// BLEManager delegate callbacks that feed it are already on the main queue.
@MainActor
final class PuffinFrameRecorder {
    /// UserDefaults flag, mirrored by the Settings toggle (`@AppStorage`). Separate from the puffin
    /// *probe* switch (`PuffinExperiment`): capturing is passive/safe, probing actively guesses.
    static let enabledKey = "noopPuffinCapture"

    /// Flush to disk every this-many frames so a crash/yank loses at most a handful of frames.
    private static let flushEvery = 25

    /// Soft cap on the total size of the puffin-captures directory (#27). One file is written per app
    /// launch and never trimmed, so without a cap the directory grows without bound — an experimental
    /// capture toggle a 5/MG user left on reached 19 GB. After each flush, oldest files are evicted
    /// (by filename, which is timestamp-sorted) until the total is back under the cap. Never deletes
    /// the file the current session is still writing.
    private static let directorySoftCapBytes = 50 * 1024 * 1024
    /// Bound the active in-memory capture by raw frame bytes. JSON hex/provenance expands this roughly
    /// 2-3x, keeping the exported file near the directory budget while retaining a large mapping corpus.
    private static let activeRawCapBytes = 20 * 1024 * 1024

    private weak var state: LiveState?
    private let buffer = PuffinCapture()
    private var sinceFlush = 0
    private var fileURL: URL?
    private var sessionId = UUID().uuidString.lowercased()
    private var activeRawBytes = 0
    private var flushedCount = 0
    private var truncated = false

    init(state: LiveState) {
        self.state = state
    }

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// `<AppSupport>/OpenWhoop/puffin-captures/`, created on demand.
    private static func captureDirectory() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
            .appendingPathComponent("puffin-captures", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Start a new connection grouping without discarding frames already captured during this app launch.
    /// One file can therefore cover a reconnect while every record still identifies its BLE session.
    func beginConnection() {
        sessionId = UUID().uuidString.lowercased()
    }

    /// Record one proprietary 5/MG frame. No-op unless capture is enabled. The recorder itself is passive:
    /// outbound frames are copies of writes BLEManager was already going to send, never recorder-triggered IO.
    func capture(frame: [UInt8], char: CBUUID,
                 direction: String = "strap_to_app", offload: Bool = false) {
        guard isEnabled else { return }
        guard !truncated else { return }
        guard activeRawBytes + frame.count <= Self.activeRawCapBytes else {
            truncated = true
            state?.puffinCaptureTruncated = true
            flush()
            return
        }
        let tsMs = Int(Date().timeIntervalSince1970 * 1000)
        buffer.record(frame: frame, char: char.uuidString.lowercased(),
                      tsMs: tsMs, hr: state?.heartRate,
                      direction: direction, offload: offload,
                      sessionId: sessionId, firmware: state?.strapFirmware,
                      worn: state?.worn, batteryPct: state?.batteryPct)
        activeRawBytes += frame.count
        sinceFlush += 1
        state?.puffinCaptureCount = buffer.count
        if sinceFlush >= Self.flushEvery { flush() }
    }

    /// Append only records not already on disk. JSONL keeps each flush proportional to the new frames
    /// instead of repeatedly rewriting a multi-megabyte capture on the CoreBluetooth/main-actor path.
    func flush() {
        guard buffer.count > flushedCount else { return }
        do {
            let url = try sessionFileURL()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = Data()
            for record in buffer.records[flushedCount...] {
                data.append(try encoder.encode(record))
                data.append(0x0A)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            flushedCount = buffer.count
            sinceFlush = 0
            state?.puffinCaptureURL = url
            state?.puffinCaptureError = nil
            // Bound on-disk growth (#27): evict oldest captures beyond the soft cap, never the
            // file this session is still writing.
            Self.evictOldCaptures(keeping: url)
        } catch {
            state?.puffinCaptureError = error.localizedDescription
        }
    }

    /// Enforce the directory soft cap by deleting the oldest capture files (best-effort). Filenames are
    /// `puffin-yyyyMMdd-HHmmss.jsonl`, so lexicographic order is chronological — delete from the front
    /// until the total is back under the cap. `keep` (the active session file) is never deleted.
    private static func evictOldCaptures(keeping keep: URL) {
        let fm = FileManager.default
        guard let dir = try? captureDirectory() else { return }
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }
        // Sort oldest-first by name (timestamped). Pair each with its size up front.
        let files = entries
            .filter { $0.pathExtension == "json" || $0.pathExtension == "jsonl" }
            .map { (url: $0, size: (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files {
            guard total > directorySoftCapBytes else { break }
            if file.url == keep { continue }   // never delete the active session file
            do {
                try fm.removeItem(at: file.url)
                total -= file.size
            } catch {
                // Best-effort: skip a file we couldn't remove; the next flush retries.
            }
        }
    }

    /// One append-only JSONL file per recorder lifetime (i.e. per app launch).
    private func sessionFileURL() throws -> URL {
        if let url = fileURL { return url }
        let stamp = Self.fileStampFormatter.string(from: Date())
        let url = try Self.captureDirectory().appendingPathComponent("puffin-\(stamp).jsonl")
        fileURL = url
        return url
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
