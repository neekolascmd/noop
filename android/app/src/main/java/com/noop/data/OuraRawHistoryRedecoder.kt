package com.noop.data

import com.noop.oura.OuraDecoders
import com.noop.oura.OuraDriver
import com.noop.oura.OuraEvent
import com.noop.oura.OuraEventTag
import com.noop.oura.OuraRecord
import com.noop.oura.OuraRingGen
import com.noop.oura.OuraTimeAnchor
import com.noop.oura.OuraTimeAnchorMapping
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Bump only when retained TLVs can yield new durable information; independent of app releases. */
object OuraRawHistoryDecoderRevision {
    const val CURRENT = 7
}

data class OuraRawHistoryRedecodeReport(
    val decodedRecords: Int = 0,
    val insertedRows: Int = 0,
    val sleepSessions: Int = 0,
    val withheldEvents: Int = 0,
    val anchorRowsBackfilled: Int = 0,
)

internal data class OuraRawHistoryPageDecode(
    val batch: StreamBatch,
    val sleepWindows: List<Pair<Long, Long>>,
    val withheldEvents: Int,
)

/** Pure page-bounded decoder used by production replay and JVM parity tests. */
internal object OuraRawHistoryPageDecoder {
    fun decode(
        rows: List<StoredOuraRawHistoryRecord>,
        ringGen: OuraRingGen,
    ): OuraRawHistoryPageDecode {
        val driver = OuraDriver(ringGen = ringGen, authKey = null, allowTierB = false)
        val hr = mutableListOf<HrRow>()
        val rr = mutableListOf<RrRow>()
        val events = mutableListOf<EventEntry>()
        val battery = mutableListOf<BatteryRow>()
        val spo2 = mutableListOf<Spo2Row>()
        val skinTemp = mutableListOf<SkinTempRow>()
        val resp = mutableListOf<RespRow>()
        val gravity = mutableListOf<GravityRow>()
        val steps = mutableListOf<StepRow>()
        val sleepState = mutableListOf<SleepStateRow>()
        val ppgHr = mutableListOf<PpgHrRow>()
        val sleepWindows = mutableListOf<Pair<Long, Long>>()
        var withheld = 0

        for (row in rows) {
            for (event in driver.ingest(row.record)) {
                if (event is OuraEvent.BedtimePeriodEvent) {
                    val anchor = row.timeAnchor
                    val start = anchor?.let {
                        OuraTimeAnchorMapping.unixSeconds(event.value.startRingTimestamp, it)
                    }
                    val end = anchor?.let {
                        OuraTimeAnchorMapping.unixSeconds(event.value.endRingTimestamp, it)
                    }
                    val duration = if (start != null && end != null) end - start else null
                    if (start == null || end == null || duration !in 15L * 60L..16L * 60L * 60L) {
                        withheld += 1
                    } else {
                        sleepWindows += start to end
                    }
                    continue
                }

                if (!requiresDurableTimestamp(event)) continue
                val timestamp = if (physiologicallyPlausible(event)) {
                    row.timeAnchor?.let {
                        OuraTimeAnchorMapping.unixSeconds(event.ringTimestampForArchiveReplay(), it)
                    }
                } else {
                    null
                }
                if (timestamp == null || timestamp !in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) {
                    withheld += 1
                    continue
                }
                val mapped = StreamPersistence.toBatch(
                    OuraStreamMapping.streams(listOf(event)) { timestamp.toInt() },
                )
                hr += mapped.hr
                rr += mapped.rr
                events += mapped.events
                battery += mapped.battery
                spo2 += mapped.spo2
                skinTemp += mapped.skinTemp
                resp += mapped.resp
                gravity += mapped.gravity
                steps += mapped.steps
                sleepState += mapped.sleepState
                ppgHr += mapped.ppgHr
            }
        }
        return OuraRawHistoryPageDecode(
            batch = StreamBatch(
                hr = hr,
                rr = rr,
                events = events,
                battery = battery,
                spo2 = spo2,
                skinTemp = skinTemp,
                resp = resp,
                gravity = gravity,
                steps = steps,
                sleepState = sleepState,
                ppgHr = ppgHr,
            ),
            sleepWindows = sleepWindows,
            withheldEvents = withheld,
        )
    }

    private fun physiologicallyPlausible(event: OuraEvent): Boolean = when (event) {
        is OuraEvent.Hr -> event.value.bpm in 30..220
        is OuraEvent.Temp -> event.value.celsius in 20.0..45.0
        else -> true
    }

    private fun requiresDurableTimestamp(event: OuraEvent): Boolean = when (event) {
        is OuraEvent.Hr,
        is OuraEvent.Ibi,
        is OuraEvent.Hrv,
        is OuraEvent.Spo2,
        is OuraEvent.Spo2Ratio,
        is OuraEvent.Temp,
        is OuraEvent.SleepPhaseEvent,
        is OuraEvent.SleepPeriodEvent,
        is OuraEvent.MotionSummaryEvent,
        is OuraEvent.SleepAcmPeriodEvent,
        is OuraEvent.ActivityInfo,
        is OuraEvent.ExerciseHRIntensity,
        is OuraEvent.RealStepsFeatures,
        is OuraEvent.AlwaysOnHR,
        -> true
        else -> false
    }

    private fun OuraEvent.ringTimestampForArchiveReplay(): Long = when (this) {
        is OuraEvent.Hr -> value.ringTimestamp
        is OuraEvent.Ibi -> value.ringTimestamp
        is OuraEvent.Hrv -> value.ringTimestamp
        is OuraEvent.Spo2 -> value.ringTimestamp
        is OuraEvent.Spo2Ratio -> value.ringTimestamp
        is OuraEvent.Temp -> value.ringTimestamp
        is OuraEvent.SleepPhaseEvent -> value.ringTimestamp
        is OuraEvent.SleepPeriodEvent -> value.ringTimestamp
        is OuraEvent.BedtimePeriodEvent -> value.ringTimestamp
        is OuraEvent.MotionEvent -> value.ringTimestamp
        is OuraEvent.MotionSummaryEvent -> value.ringTimestamp
        is OuraEvent.SleepAcmPeriodEvent -> value.ringTimestamp
        is OuraEvent.StateEvent -> value.ringTimestamp
        is OuraEvent.TimeSyncEvent -> value.ringTimestamp
        is OuraEvent.RtcBeaconEvent -> value.ringTimestamp
        is OuraEvent.DebugTextEvent -> ringTimestamp
        is OuraEvent.TierB -> value.ringTimestamp
        is OuraEvent.ActivityInfo -> value.ringTimestamp
        is OuraEvent.ExerciseHRIntensity -> value.ringTimestamp
        is OuraEvent.RealStepsFeatures -> value.ringTimestamp
        is OuraEvent.AlwaysOnHR -> value.ringTimestamp
        is OuraEvent.Battery -> 0L
    }
}

/**
 * Re-run the current Oura clean-room decoder against retained TLVs without BLE, an Oura account, or
 * network access. Pages are marked only after all idempotent stream/sleep writes complete.
 */
suspend fun WhoopRepository.redecodeOuraRawHistory(
    deviceId: String,
    ringGen: OuraRingGen,
    decoderRevision: Int = OuraRawHistoryDecoderRevision.CURRENT,
    pageSize: Int = 2_000,
): OuraRawHistoryRedecodeReport {
    require(deviceId.isNotEmpty() && decoderRevision > 0)
    val boundedPageSize = pageSize.coerceIn(1, 10_000)
    var report = OuraRawHistoryRedecodeReport()
    var attemptedAnchorBackfill = false

    while (true) {
        currentCoroutineContext().ensureActive()
        var rows = ouraRawHistoryRecordsNeedingDecode(deviceId, decoderRevision, boundedPageSize)
        if (rows.isEmpty()) return report

        if (!attemptedAnchorBackfill && rows.any { it.timeAnchor == null }) {
            val backfilled = backfillOuraRawHistoryTimeAnchors(
                deviceId = deviceId,
                ringGen = ringGen,
                pageSize = maxOf(boundedPageSize, 5_000),
            )
            report = report.copy(anchorRowsBackfilled = report.anchorRowsBackfilled + backfilled)
            attemptedAnchorBackfill = true
            rows = ouraRawHistoryRecordsNeedingDecode(deviceId, decoderRevision, boundedPageSize)
            if (rows.isEmpty()) return report
        }

        val decoded = OuraRawHistoryPageDecoder.decode(rows, ringGen)
        var inserted = 0
        if (!decoded.batch.isEmpty) {
            val counts = insert(decoded.batch, deviceId)
            inserted = counts.hr + counts.rr + counts.events + counts.battery + counts.spo2 +
                counts.skinTemp + counts.steps + counts.resp + counts.gravity
        }
        if (decoded.sleepWindows.isNotEmpty()) {
            upsertSleepSessions(
                decoded.sleepWindows.map { (start, end) ->
                    SleepSession(deviceId = "$deviceId-noop", startTs = start, endTs = end)
                },
            )
        }

        // Last by design: any exception above leaves the page on its old revision for a safe retry.
        markOuraRawHistoryDecoded(rows.map { it.archiveId }, decoderRevision)
        report = report.copy(
            decodedRecords = report.decodedRecords + rows.size,
            insertedRows = report.insertedRows + inserted,
            sleepSessions = report.sleepSessions + decoded.sleepWindows.size,
            withheldEvents = report.withheldEvents + decoded.withheldEvents,
        )
    }
}

private suspend fun WhoopRepository.backfillOuraRawHistoryTimeAnchors(
    deviceId: String,
    ringGen: OuraRingGen,
    pageSize: Int,
): Int {
    var afterArchiveId = 0L
    var previousRingTimestamp = 0L
    var previousArchiveId = 0L
    var unassignedStart: Long? = null
    var currentAnchor: OuraTimeAnchor? = null
    var changed = 0

    while (true) {
        currentCoroutineContext().ensureActive()
        val rows = ouraRawHistoryRecords(deviceId, afterArchiveId, pageSize)
        if (rows.isEmpty()) return changed
        val assignments = mutableListOf<Triple<OuraTimeAnchor, Long, Long>>()

        for (row in rows) {
            if (unassignedStart == null) unassignedStart = row.archiveId
            if (row.tag == OuraEventTag.RING_START.raw &&
                previousRingTimestamp != 0L && row.ringTimestamp < previousRingTimestamp
            ) {
                val start = checkNotNull(unassignedStart)
                currentAnchor?.let { anchor ->
                    if (start <= previousArchiveId) {
                        assignments += Triple(anchor, start, previousArchiveId)
                    }
                }
                currentAnchor = null
                unassignedStart = row.archiveId
            }

            val stored = row.timeAnchor
            val discovered = if (stored == null) archiveAnchor(row.record, ringGen) else null
            val nextAnchor = stored ?: discovered
            if (nextAnchor != null) {
                currentAnchor = nextAnchor
                val start = checkNotNull(unassignedStart)
                val end = if (stored != null) row.archiveId - 1 else row.archiveId
                if (start <= end) assignments += Triple(nextAnchor, start, end)
                unassignedStart = row.archiveId + 1
            }

            previousRingTimestamp = row.ringTimestamp
            previousArchiveId = row.archiveId
        }

        val start = checkNotNull(unassignedStart)
        currentAnchor?.let { anchor ->
            if (start <= previousArchiveId) {
                assignments += Triple(anchor, start, previousArchiveId)
                unassignedStart = previousArchiveId + 1
            }
        }
        for ((anchor, from, through) in assignments) {
            changed += setOuraRawHistoryTimeAnchor(anchor, deviceId, from, through)
        }
        afterArchiveId = rows.last().archiveId
    }
}

private fun archiveAnchor(record: OuraRecord, ringGen: OuraRingGen): OuraTimeAnchor? = when (record.type) {
    OuraEventTag.TIME_SYNC.raw ->
        OuraDecoders.decodeTimeSync(record, ringGen)?.let(OuraTimeAnchorMapping::anchor)
    OuraEventTag.RTC_BEACON.raw ->
        OuraDecoders.decodeRtcBeacon(record)?.let(OuraTimeAnchorMapping::anchor)
    else -> null
}
