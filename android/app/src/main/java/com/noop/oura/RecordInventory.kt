package com.noop.oura

import java.util.Locale

/**
 * Privacy-safe metadata for complete Oura history records observed by the decoder.
 *
 * This deliberately retains only the tag, record count, wire-byte count, and current typed-event
 * count. It never retains record payloads, timestamps, device identifiers, authentication material,
 * or biometric values, so [summary] is safe for NOOP's normal redacted diagnostic log.
 */
class OuraRecordInventory {
    data class Entry(
        val tag: Int,
        val recordCount: Int,
        val wireByteCount: Int,
        val emittedEventCount: Int,
        val decodedRecordCount: Int,
    ) {
        /** The current NOOP dictionary entry, or null for a genuinely unknown tag. */
        val knownTag: OuraEventTag? get() = OuraEventTag.fromRaw(tag)

        /** Structurally valid records that intentionally or unexpectedly emitted no typed event. */
        val silentRecordCount: Int get() = recordCount - decodedRecordCount
    }

    private data class MutableEntry(
        var recordCount: Int = 0,
        var wireByteCount: Int = 0,
        var emittedEventCount: Int = 0,
        var decodedRecordCount: Int = 0,
    )

    private val counts = mutableMapOf<Int, MutableEntry>()

    /** Observe one complete, structurally-valid TLV after the current decoder has processed it. */
    fun observe(record: OuraRecord, emittedEventCount: Int) {
        val entry = counts.getOrPut(record.type) { MutableEntry() }
        entry.recordCount += 1
        entry.wireByteCount += record.totalLength
        entry.emittedEventCount += emittedEventCount.coerceAtLeast(0)
        if (emittedEventCount > 0) entry.decodedRecordCount += 1
    }

    /** Stable tag-ascending entries for deterministic logs and tests. */
    val entries: List<Entry>
        get() = counts.keys.sorted().map { tag ->
            val value = requireNotNull(counts[tag])
            Entry(
                tag = tag,
                recordCount = value.recordCount,
                wireByteCount = value.wireByteCount,
                emittedEventCount = value.emittedEventCount,
                decodedRecordCount = value.decodedRecordCount,
            )
        }

    val totalRecordCount: Int get() = counts.values.sumOf { it.recordCount }
    val totalWireByteCount: Int get() = counts.values.sumOf { it.wireByteCount }
    val emittedEventCount: Int get() = counts.values.sumOf { it.emittedEventCount }
    val unknownRecordCount: Int
        get() = entries.filter { it.knownTag == null }.sumOf { it.recordCount }
    val isEmpty: Boolean get() = counts.isEmpty()

    /**
     * One bounded, deterministic, values-free line. Each item is `tag(name)=records/events/bytes`; a tag absent
     * from the current dictionary is named `UNKNOWN`.
     */
    fun summary(maximumTags: Int = 24): String {
        val allEntries = entries
        val visible = allEntries.take(maximumTags.coerceAtLeast(0))
        val parts = visible.map { entry ->
            val tag = String.format(Locale.ROOT, "0x%02X", entry.tag)
            val name = entry.knownTag?.tagName ?: "UNKNOWN"
            "$tag($name)=${entry.recordCount}r/${entry.emittedEventCount}e/${entry.wireByteCount}b"
        }
        val omitted = (allEntries.size - visible.size).coerceAtLeast(0)
        val suffix = if (omitted > 0) " +$omitted tag(s)" else ""
        val detail = if (parts.isEmpty()) "none$suffix" else parts.joinToString(",") + suffix
        return "records=$totalRecordCount bytes=$totalWireByteCount events=$emittedEventCount " +
            "unknown=$unknownRecordCount tags=[$detail]"
    }
}
