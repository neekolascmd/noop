import Foundation

/// A privacy-safe inventory of complete Oura history records observed by the decoder.
///
/// The inventory deliberately retains metadata only: tag, record count, wire-byte count, and the
/// number of typed events emitted by NOOP's current decoder. It never retains record payloads,
/// timestamps, device identifiers, auth material, or biometric values. This makes the summary safe to
/// include in the normal redacted strap log while still answering the protocol-mapping questions that
/// matter: which tags a firmware emitted, whether NOOP knows their names, and whether they currently
/// produce typed events.
public struct OuraRecordInventory: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let tag: UInt8
        public let recordCount: Int
        public let wireByteCount: Int
        public let emittedEventCount: Int
        public let decodedRecordCount: Int

        public init(tag: UInt8, recordCount: Int, wireByteCount: Int,
                    emittedEventCount: Int, decodedRecordCount: Int) {
            self.tag = tag
            self.recordCount = recordCount
            self.wireByteCount = wireByteCount
            self.emittedEventCount = emittedEventCount
            self.decodedRecordCount = decodedRecordCount
        }

        /// The current NOOP dictionary entry, or nil when this is a genuinely unknown tag.
        public var knownTag: OuraEventTag? { OuraEventTag(rawValue: tag) }

        /// Records from this tag that were structurally valid but produced no typed event. A known
        /// lifecycle/diagnostic tag may intentionally be silent, so this is not labelled a decode error.
        public var silentRecordCount: Int { recordCount - decodedRecordCount }
    }

    private struct MutableEntry: Equatable, Sendable {
        var recordCount = 0
        var wireByteCount = 0
        var emittedEventCount = 0
        var decodedRecordCount = 0
    }

    private var counts: [UInt8: MutableEntry] = [:]

    public init() {}

    /// Observe one complete, structurally-valid TLV record after the current decoder has processed it.
    /// Passing the event count keeps the inventory independent of app/storage types and lets one record
    /// honestly report that it expanded to several IBI/temperature/etc. samples.
    public mutating func observe(_ record: OuraRecord, emittedEventCount: Int) {
        var entry = counts[record.type] ?? MutableEntry()
        entry.recordCount += 1
        entry.wireByteCount += record.totalLength
        entry.emittedEventCount += max(0, emittedEventCount)
        if emittedEventCount > 0 { entry.decodedRecordCount += 1 }
        counts[record.type] = entry
    }

    /// Stable tag-ascending entries for deterministic logs, CLI output, and tests.
    public var entries: [Entry] {
        counts.keys.sorted().compactMap { tag in
            guard let value = counts[tag] else { return nil }
            return Entry(tag: tag,
                         recordCount: value.recordCount,
                         wireByteCount: value.wireByteCount,
                         emittedEventCount: value.emittedEventCount,
                         decodedRecordCount: value.decodedRecordCount)
        }
    }

    public var totalRecordCount: Int { counts.values.reduce(0) { $0 + $1.recordCount } }
    public var totalWireByteCount: Int { counts.values.reduce(0) { $0 + $1.wireByteCount } }
    public var emittedEventCount: Int { counts.values.reduce(0) { $0 + $1.emittedEventCount } }

    /// Count of records whose tag is absent from NOOP's dictionary. This is the honest mapping backlog;
    /// known-but-silent records are kept separate because some lifecycle tags intentionally emit nothing.
    public var unknownRecordCount: Int {
        entries.filter { $0.knownTag == nil }.reduce(0) { $0 + $1.recordCount }
    }

    public var isEmpty: Bool { counts.isEmpty }

    /// One bounded, deterministic, values-free line suitable for NOOP's exportable strap log.
    /// Each item is `tag(name)=records/events/bytes`; an unknown tag is named `UNKNOWN`.
    public func summary(maximumTags: Int = 24) -> String {
        let limit = max(0, maximumTags)
        let visible = entries.prefix(limit)
        let parts = visible.map { entry in
            let tag = String(format: "0x%02X", entry.tag)
            let name = entry.knownTag?.name ?? "UNKNOWN"
            return "\(tag)(\(name))=\(entry.recordCount)r/\(entry.emittedEventCount)e/\(entry.wireByteCount)b"
        }
        let omitted = max(0, entries.count - visible.count)
        let suffix = omitted > 0 ? " +\(omitted) tag(s)" : ""
        let detail = parts.isEmpty ? "none" + suffix : parts.joined(separator: ",") + suffix
        return "records=\(totalRecordCount) bytes=\(totalWireByteCount) "
            + "events=\(emittedEventCount) unknown=\(unknownRecordCount) tags=[\(detail)]"
    }
}
