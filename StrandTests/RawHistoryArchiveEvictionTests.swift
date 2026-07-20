import XCTest
@testable import Strand
import WhoopProtocol

/// #344: the reject archive has a byte cap. Before this fix, a full archive simply stopped accepting
/// new frames — so a rare never-seen layout version (WHOOP 4 v19, WHOOP 5 v20/v21) arriving when the
/// archive was full of the common version was dropped on the floor, the exact frames we keep the
/// archive to study. The fix gives every distinct hist_version a retention FLOOR: when over cap we
/// evict oldest surplus from the most-populous versions first, never below `perVersionFloor` newest
/// lines of any version, so the rare version always survives. These tests prove that survival.
final class RawHistoryArchiveEvictionTests: XCTestCase {

    private func tmpDir(_ tag: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noop-evict-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A minimal synthetic WHOOP 4 type-47 record whose hist_version byte (frame[5]) is `version`.
    /// Only the type byte (frame[4]==47) and version byte (frame[5]) matter for the archive's bucketing
    /// — it re-derives the version from the stored bytes, so the rest is filler to give the line size.
    private func whoop4Frame(version: UInt8, filler: UInt8) -> [UInt8] {
        var f: [UInt8] = [0xAA, 0x01, 0x00, 0x00, 47, version]
        f.append(contentsOf: [UInt8](repeating: filler, count: 24))   // 30 B → ~96 B JSONL line
        return f
    }

    /// Floods a small-capped archive with the common version, then archives a couple of rare-version
    /// frames, and asserts the rare frames are present in the read-back even though the archive is full.
    func testRareVersionSurvivesAFloodOfCommonFrames() {
        let dir = tmpDir("flood"); defer { try? FileManager.default.removeItem(at: dir) }
        // Small cap + small floor so the test drives eviction with a handful of frames, not 5 MB.
        let archive = RawHistoryArchive(directory: dir, maxBytes: 4_096, perVersionFloor: 2)

        // 1) Two rare v19 frames land FIRST (oldest in the archive).
        let rareA = whoop4Frame(version: 19, filler: 0xA1)
        let rareB = whoop4Frame(version: 19, filler: 0xB2)
        _ = archive.archive([rareA, rareB], trim: 1, family: .whoop4)

        // 2) Flood with the common v18 version — far more than the cap can hold, forcing eviction.
        for i in 0..<400 {
            _ = archive.archive([whoop4Frame(version: 18, filler: UInt8(i & 0xFF))], trim: 2, family: .whoop4)
        }

        let back = archive.readAll()
        // The archive must have stayed bounded (eviction happened) …
        let attrs = try? FileManager.default.attributesOfItem(atPath: archive.fileURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        XCTAssertLessThanOrEqual(size, 4_096 + 200, "archive should stay near its cap, not grow unbounded")
        // … yet BOTH rare v19 frames survived despite being the oldest lines in a full archive.
        let survivedRare = back.filter { RawHistoryArchive.versionByte($0.frame, family: .whoop4) == 19 }
        XCTAssertEqual(survivedRare.count, 2, "the floor must keep both rare v19 samples through the flood")
        XCTAssertTrue(back.contains { $0.frame == rareA })
        XCTAssertTrue(back.contains { $0.frame == rareB })
        // The common version is still represented too (just trimmed to its surplus).
        XCTAssertTrue(back.contains { RawHistoryArchive.versionByte($0.frame, family: .whoop4) == 18 })
    }

    /// The interleaved case: rare frames arrive AFTER the archive is already full of the common version.
    /// They must be written (the archive makes room by evicting common surplus) and then survive.
    func testRareVersionWrittenWhenArchiveAlreadyFull() {
        let dir = tmpDir("interleaved"); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RawHistoryArchive(directory: dir, maxBytes: 4_096, perVersionFloor: 2)

        // Fill the archive past the cap with the common version FIRST.
        for i in 0..<400 {
            _ = archive.archive([whoop4Frame(version: 18, filler: UInt8(i & 0xFF))], trim: 1, family: .whoop4)
        }
        // Now a brand-new v20 (WHOOP 5-style) record arrives into the already-full archive.
        let rare = whoop4Frame(version: 20, filler: 0xCC)
        let result = archive.archive([rare], trim: 2, family: .whoop4)
        if case .capReached = result {
            XCTFail("a single small rare frame must be accepted by evicting common surplus, not skipped")
        }
        let back = archive.readAll()
        XCTAssertTrue(back.contains { $0.frame == rare }, "the rare v20 frame must survive into a full archive")
    }

    /// Multiple distinct rare versions each get their own floor — none is starved by the others.
    func testEachDistinctVersionGetsItsOwnFloor() {
        let dir = tmpDir("multi"); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RawHistoryArchive(directory: dir, maxBytes: 6_144, perVersionFloor: 2)

        _ = archive.archive([whoop4Frame(version: 19, filler: 0x11)], trim: 1, family: .whoop4)
        _ = archive.archive([whoop4Frame(version: 21, filler: 0x22)], trim: 1, family: .whoop4)
        for i in 0..<400 {
            _ = archive.archive([whoop4Frame(version: 18, filler: UInt8(i & 0xFF))], trim: 2, family: .whoop4)
        }

        let back = archive.readAll()
        XCTAssertTrue(back.contains { RawHistoryArchive.versionByte($0.frame, family: .whoop4) == 19 },
                      "v19 must keep its floor")
        XCTAssertTrue(back.contains { RawHistoryArchive.versionByte($0.frame, family: .whoop4) == 21 },
                      "v21 must keep its floor")
    }

    /// The cap is still honoured for the common case (everything fits → plain append, no eviction).
    func testUnderCapPlainAppendKeepsEverything() {
        let dir = tmpDir("under"); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RawHistoryArchive(directory: dir, maxBytes: 1_000_000, perVersionFloor: 2)
        for i in 0..<10 {
            _ = archive.archive([whoop4Frame(version: 18, filler: UInt8(i))], trim: 1, family: .whoop4)
        }
        XCTAssertEqual(archive.readAll().count, 10, "nothing should be evicted while under the cap")
    }

    // MARK: - pure eviction core (mirrors the Android RawHistoryArchiveEvictionTest)

    private func jsonl(_ version: Int, _ family: String = "whoop4", filler: String = "00") -> String {
        // frame: AA 01 00 00 2F <version> <filler>  → type@4 = 0x2F (47), hist_version@5 = version.
        let hex = "aa0100002f" + String(format: "%02x", version) + filler
        return "{\"capturedAtMs\":1,\"trim\":1,\"family\":\"\(family)\",\"frameHex\":\"\(hex)\"}\n"
    }

    /// `evictLines` is the pure core: a flood of common-version lines plus two rare-version lines (the
    /// oldest), capped tight → the rare lines must survive and the result must fit the cap.
    func testEvictLinesKeepsRareVersionUnderCap() {
        var lines = [jsonl(19, filler: "a1"), jsonl(19, filler: "b2")]   // rare, oldest
        for i in 0..<400 { lines.append(jsonl(18, filler: String(format: "%02x", i & 0xFF))) }
        let kept = RawHistoryArchive.evictLines(lines, maxBytes: 4_096, floor: 2)
        let bytes = kept.reduce(0) { $0 + $1.utf8.count }
        XCTAssertLessThanOrEqual(bytes, 4_096, "eviction must bring the archive within the cap")
        XCTAssertTrue(kept.contains { $0.contains("2f13a1") }, "rare v19 #1 must survive")  // 0x13 = 19
        XCTAssertTrue(kept.contains { $0.contains("2f13b2") }, "rare v19 #2 must survive")
        XCTAssertTrue(kept.contains { $0.contains("2f12") }, "common v18 still represented")  // 0x12 = 18
    }

    /// Under the cap, `evictLines` is a no-op identity (no rewrite churn).
    func testEvictLinesNoOpUnderCap() {
        let lines = (0..<10).map { jsonl(18, filler: String(format: "%02x", $0)) }
        XCTAssertEqual(RawHistoryArchive.evictLines(lines, maxBytes: 1_000_000, floor: 2), lines)
    }
}
