package com.noop.data

import com.noop.oura.OuraDecoders
import com.noop.oura.OuraEventTag
import com.noop.oura.OuraHypnogramAssembler
import com.noop.oura.OuraHypnogramBurst
import com.noop.oura.OuraHypnogramEpoch
import com.noop.oura.OuraTimeAnchorMapping
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlin.math.abs

internal data class OuraSleepNetWindowCandidate(
    val ringTimestamp: Long,
    val eventUnixSeconds: Long,
    val startUnixSeconds: Long,
    val endUnixSeconds: Long,
)

internal object OuraSleepNetWindowPairing {
    const val TOLERANCE_TICKS: Long = 6_000 // 10 minutes at 100 ms/tick
    const val TOLERANCE_SECONDS: Long = 10 * 60

    fun closest(
        ringTimestamp: Long,
        envelopeUnixSeconds: Long,
        candidates: List<OuraSleepNetWindowCandidate>,
        toleranceTicks: Long = TOLERANCE_TICKS,
        toleranceSeconds: Long = TOLERANCE_SECONDS,
    ): OuraSleepNetWindowCandidate? = candidates
        .map {
            Triple(
                it,
                abs(it.ringTimestamp - ringTimestamp),
                abs(it.eventUnixSeconds - envelopeUnixSeconds),
            )
        }
        .filter { it.second <= toleranceTicks && it.third <= toleranceSeconds }
        .minWithOrNull(compareBy<Triple<OuraSleepNetWindowCandidate, Long, Long>> { it.second }
            .thenBy { it.third }
            .thenBy { it.first.ringTimestamp })
        ?.first
}

internal object OuraSleepNetPersistencePolicy {
    const val SECONDS_PER_EPOCH: Long = 30
    const val MINIMUM_OBSERVED_COVERAGE_FOR_EFFICIENCY: Double = 0.95

    /** Stable across the small 0x49 anchor jitter observed when a ring re-serves one night. */
    fun stableStartUnixSeconds(rawStartUnixSeconds: Long): Long =
        ((rawStartUnixSeconds + 30) / 60) * 60

    fun epochsWithinStableWindow(
        epochs: List<OuraHypnogramEpoch>,
        startUnixSeconds: Long,
        endUnixSeconds: Long,
    ): List<OuraHypnogramEpoch> = epochs.filter {
        it.startUnixSeconds >= startUnixSeconds && it.startUnixSeconds < endUnixSeconds
    }

    fun coveredSeconds(
        epochs: List<OuraHypnogramEpoch>,
        secondsPerEpoch: Long = SECONDS_PER_EPOCH,
    ): Long = if (secondsPerEpoch > 0) {
        epochs.asSequence().map { it.startUnixSeconds }.distinct().count() * secondsPerEpoch
    } else {
        0
    }

    /** Erased slots still reserve time, so total code slots—not written stages—prove a terminal burst. */
    fun structurallySpansWindow(
        totalCodeSlots: Int,
        startUnixSeconds: Long,
        endUnixSeconds: Long,
        secondsPerEpoch: Long = SECONDS_PER_EPOCH,
    ): Boolean {
        val duration = endUnixSeconds - startUnixSeconds
        if (totalCodeSlots <= 0 || duration <= 0 || secondsPerEpoch <= 0) return false
        if (totalCodeSlots.toLong() > Long.MAX_VALUE / secondsPerEpoch) return false
        return totalCodeSlots * secondsPerEpoch >= duration
    }

    fun observedCoverage(
        epochs: List<OuraHypnogramEpoch>,
        startUnixSeconds: Long,
        endUnixSeconds: Long,
    ): Double {
        val duration = endUnixSeconds - startUnixSeconds
        if (duration <= 0) return 0.0
        val covered = coveredSeconds(epochs).coerceAtMost(duration)
        return covered.toDouble() / duration
    }

    fun hasCompleteObservedCoverage(
        epochs: List<OuraHypnogramEpoch>,
        startUnixSeconds: Long,
        endUnixSeconds: Long,
        minimumCoverage: Double = MINIMUM_OBSERVED_COVERAGE_FOR_EFFICIENCY,
    ): Boolean {
        if (minimumCoverage <= 0 || minimumCoverage > 1) return false
        return observedCoverage(epochs, startUnixSeconds, endUnixSeconds) >= minimumCoverage
    }
}

private data class OuraSleepNetPersistableCandidate(
    val session: SleepSession,
    val coveredSeconds: Long,
)

/** Whole-archive pass so one phase burst remains intact even when it crosses Room query pages. */
internal suspend fun WhoopRepository.rebuildOuraSleepNetSessions(
    deviceId: String,
    throughArchiveId: Long,
    pageSize: Int,
): List<SleepSession> {
    val boundedPageSize = pageSize.coerceIn(1, 10_000)
    val windows = mutableListOf<OuraSleepNetWindowCandidate>()
    var afterArchiveId = 0L

    while (true) {
        currentCoroutineContext().ensureActive()
        val rows = ouraRawHistoryRecords(
            deviceId = deviceId,
            afterArchiveId = afterArchiveId,
            throughArchiveId = throughArchiveId,
            limit = boundedPageSize,
        )
        if (rows.isEmpty()) break
        for (row in rows) {
            if (row.tag != OuraEventTag.SLEEP_SUMMARY_1.raw) continue
            val window = OuraDecoders.decodeSleepWindow(row.record) ?: continue
            val anchor = row.timeAnchor ?: continue
            val eventTime = OuraTimeAnchorMapping.unixSeconds(window.ringTimestamp, anchor) ?: continue
            if (window.startOffsetMinutes <= window.endOffsetMinutes) continue
            val start = eventTime - window.startOffsetMinutes * 60L
            val end = eventTime - window.endOffsetMinutes * 60L
            if (end - start !in 15L * 60L..16L * 60L * 60L) continue
            windows += OuraSleepNetWindowCandidate(
                ringTimestamp = window.ringTimestamp,
                eventUnixSeconds = eventTime,
                startUnixSeconds = start,
                endUnixSeconds = end,
            )
        }
        afterArchiveId = rows.last().archiveId
    }
    if (windows.isEmpty()) return emptyList()
    if (windows.size > 8_192) windows.subList(0, windows.size - 8_192).clear()

    val assembler = OuraHypnogramAssembler()
    val sessionsByStart = linkedMapOf<Long, OuraSleepNetPersistableCandidate>()
    fun appendSession(burst: OuraHypnogramBurst) {
        val envelopeUnixSeconds = burst.lastEnvelopeUnixSeconds ?: return
        val window = OuraSleepNetWindowPairing.closest(
            ringTimestamp = burst.lastRingTimestamp,
            envelopeUnixSeconds = envelopeUnixSeconds,
            candidates = windows,
        ) ?: return
        if (!OuraSleepNetPersistencePolicy.structurallySpansWindow(
                totalCodeSlots = burst.totalCodes,
                startUnixSeconds = window.startUnixSeconds,
                endUnixSeconds = window.endUnixSeconds,
            )
        ) return
        val laidOutEpochs = burst.codesWithTimes(
            endUnixSeconds = window.endUnixSeconds,
            sleepStartUnixSeconds = window.startUnixSeconds,
        )
        val stableStart = OuraSleepNetPersistencePolicy.stableStartUnixSeconds(
            window.startUnixSeconds,
        )
        val epochs = OuraSleepNetPersistencePolicy.epochsWithinStableWindow(
            laidOutEpochs,
            startUnixSeconds = stableStart,
            endUnixSeconds = window.endUnixSeconds,
        )
        val hasCompleteObservedCoverage =
            OuraSleepNetPersistencePolicy.hasCompleteObservedCoverage(
                epochs = epochs,
                startUnixSeconds = stableStart,
                endUnixSeconds = window.endUnixSeconds,
            )
        val session = OuraSleepSessionMapping.session(
            epochs = epochs,
            deviceId = deviceId,
            sessionStartUnixSeconds = stableStart,
            sessionEndUnixSeconds = window.endUnixSeconds,
            includeEfficiency = hasCompleteObservedCoverage,
        ) ?: return
        if (session.endTs - session.startTs !in 15L * 60L..16L * 60L * 60L) return
        val candidate = OuraSleepNetPersistableCandidate(
            session = session,
            coveredSeconds = OuraSleepNetPersistencePolicy.coveredSeconds(epochs),
        )
        val existing = sessionsByStart[stableStart]
        if (existing != null &&
            (existing.coveredSeconds > candidate.coveredSeconds ||
                (existing.coveredSeconds == candidate.coveredSeconds &&
                    existing.session.endTs >= candidate.session.endTs))
        ) return
        sessionsByStart[stableStart] = candidate
    }

    afterArchiveId = 0L
    while (true) {
        currentCoroutineContext().ensureActive()
        val rows = ouraRawHistoryRecords(
            deviceId = deviceId,
            afterArchiveId = afterArchiveId,
            throughArchiveId = throughArchiveId,
            limit = boundedPageSize,
        )
        if (rows.isEmpty()) break
        for (row in rows) {
            if (row.tag != OuraEventTag.SLEEP_PHASE_INFO.raw &&
                row.tag != OuraEventTag.SLEEP_PHASE.raw &&
                row.tag != OuraEventTag.SLEEP_PHASE_ALT.raw
            ) continue
            val series = OuraDecoders.decodeSleepPhase(row.record) ?: continue
            val envelopeUnixSeconds = row.timeAnchor?.let {
                OuraTimeAnchorMapping.unixSeconds(series.ringTimestamp, it)
            }
            assembler.feed(series, envelopeUnixSeconds)?.let(::appendSession)
        }
        afterArchiveId = rows.last().archiveId
    }
    assembler.flush()?.let(::appendSession)
    return sessionsByStart.values.map { it.session }.sortedBy { it.startTs }
}
