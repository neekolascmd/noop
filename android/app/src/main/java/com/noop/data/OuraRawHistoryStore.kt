package com.noop.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.noop.oura.OuraRecord
import com.noop.oura.OuraTimeAnchor
import com.noop.oura.OuraTimeAnchorMapping

/** One complete Oura history TLV retained before typed decoding. */
data class StoredOuraRawHistoryRecord(
    val archiveId: Long,
    val tag: Int,
    val ringTimestamp: Long,
    val payload: ByteArray,
    val firstSeenAtUnixMs: Long,
    val timeAnchor: OuraTimeAnchor? = null,
    val decodedRevision: Int = 0,
) {
    val record: OuraRecord
        get() = OuraRecord(
            type = tag,
            ringTimestamp = ringTimestamp,
            payload = IntArray(payload.size) { payload[it].toInt() and 0xFF },
        )

    override fun equals(other: Any?): Boolean =
        other is StoredOuraRawHistoryRecord &&
            archiveId == other.archiveId &&
            tag == other.tag &&
            ringTimestamp == other.ringTimestamp &&
            payload.contentEquals(other.payload) &&
            firstSeenAtUnixMs == other.firstSeenAtUnixMs &&
            timeAnchor == other.timeAnchor &&
            decodedRevision == other.decodedRevision

    override fun hashCode(): Int {
        var result = archiveId.hashCode()
        result = 31 * result + tag
        result = 31 * result + ringTimestamp.hashCode()
        result = 31 * result + payload.contentHashCode()
        result = 31 * result + firstSeenAtUnixMs.hashCode()
        result = 31 * result + (timeAnchor?.hashCode() ?: 0)
        return 31 * result + decodedRevision
    }
}

/**
 * Exact record equality is indexed directly, including the BLOB. This makes a history refetch
 * idempotent without a collision-prone digest or any cloud-generated identifier.
 */
@Entity(
    tableName = "ouraRawHistory",
    indices = [
        Index(
            value = ["deviceId", "ringTimestamp", "tag", "payload"],
            name = "idx_ouraRawHistory_exact",
            unique = true,
        ),
        Index(
            value = ["deviceId", "firstSeenAtUnixMs", "archiveId"],
            name = "idx_ouraRawHistory_device_seen",
        ),
        Index(
            value = ["deviceId", "decodedRevision", "archiveId"],
            name = "idx_ouraRawHistory_device_revision",
        ),
    ],
)
data class OuraRawHistoryEntity(
    @PrimaryKey(autoGenerate = true) val archiveId: Long = 0,
    val deviceId: String,
    val ringTimestamp: Long,
    val tag: Int,
    val payload: ByteArray,
    val wireByteSize: Long,
    val firstSeenAtUnixMs: Long,
    val anchorUtcMilliseconds: Long? = null,
    val anchorRingTimestamp: Long? = null,
    val anchorFactorMillisecondsPerTick: Long? = null,
    val decodedRevision: Int = 0,
)

val OuraRawHistoryEntity.timeAnchor: OuraTimeAnchor?
    get() {
        val utc = anchorUtcMilliseconds ?: return null
        val ring = anchorRingTimestamp ?: return null
        val factor = anchorFactorMillisecondsPerTick ?: return null
        return OuraTimeAnchor(ring, utc, factor).takeIf(OuraTimeAnchorMapping::isValid)
    }

data class OuraRawHistoryPruneRow(val archiveId: Long, val wireByteSize: Long)

data class OuraRawHistoryRetentionLimits(val maxWireBytesPerDevice: Long) {
    companion object {
        val PRODUCTION = OuraRawHistoryRetentionLimits(
            maxWireBytesPerDevice = 128L * 1_024 * 1_024,
        )
    }
}

object OuraRawHistoryStoreContract {
    fun validate(record: OuraRecord) {
        require(record.type in 0x41..0xFF) { "tag is not an Oura history event" }
        require(record.ringTimestamp in 0..0xFFFF_FFFFL) { "invalid Oura ring timestamp" }
        require(record.payload.size <= 251) { "Oura payload exceeds TLV length" }
        require(record.payload.all { it in 0..0xFF }) { "Oura payload contains a non-byte value" }
    }

    /** Pure whole-record byte-retention policy, shared by the DAO transaction and JVM tests. */
    fun rowIdsToEvict(
        oldestFirst: List<OuraRawHistoryPruneRow>,
        totalWireBytes: Long,
        maxWireBytes: Long,
    ): List<Long> {
        require(maxWireBytes > 0)
        var total = totalWireBytes.coerceAtLeast(0)
        val evict = mutableListOf<Long>()
        for (row in oldestFirst) {
            if (total <= maxWireBytes) break
            evict += row.archiveId
            total = (total - row.wireByteSize.coerceAtLeast(0)).coerceAtLeast(0)
        }
        return evict
    }
}
