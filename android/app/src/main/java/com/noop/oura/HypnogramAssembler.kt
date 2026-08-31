package com.noop.oura

/** SleepNet classifies one stage per 30-second epoch. */
const val OURA_SLEEPNET_EPOCH_SECONDS: Long = 30

/**
 * One decoded sleep-phase record in transport arrival order. [envelopeUnixSeconds] is optional
 * because UTC may not be resolvable until the surrounding history page establishes a qualified
 * ring-clock anchor. It names the record write/finalization time, not the time of its first stage.
 */
data class OuraHypnogramRecord(
    val ringTimestamp: Long,
    val stages: List<OuraSleepStage>,
    val envelopeUnixSeconds: Long? = null,
    /** True slots reserve time but are omitted from the emitted staged hypnogram. */
    val unwritten: List<Boolean> = List(stages.size) { false },
) {
    init {
        require(unwritten.size == stages.size) { "unwritten flags must match stage count" }
    }
}

/** One reconstructed SleepNet epoch; [startUnixSeconds] names the interval start. */
data class OuraHypnogramEpoch(
    val stage: OuraSleepStage,
    val startUnixSeconds: Long,
)

/** Consecutive sleep-phase records written during one SleepNet finalization burst. */
data class OuraHypnogramBurst(val records: List<OuraHypnogramRecord>) {
    /** Total 2-bit stage codes across the burst. */
    val totalCodes: Int get() = records.sumOf { it.stages.size }

    /** Last envelope ring timestamp in arrival order. */
    val lastRingTimestamp: Long get() = records.lastOrNull()?.ringTimestamp ?: 0L

    /** Last UTC envelope anchor supplied by the caller, if any record could be anchored. */
    val lastEnvelopeUnixSeconds: Long?
        get() = records.asReversed().firstNotNullOfOrNull { it.envelopeUnixSeconds }

    /**
     * Surfaces an envelope timestamp step backwards without reordering the codes. Envelope times
     * describe near-simultaneous writes, so arrival order remains the only sequence ground truth.
     */
    val hasNonMonotonicRingTimes: Boolean
        get() = records.zipWithNext().any { (previous, next) ->
            next.ringTimestamp < previous.ringTimestamp
        }

    /**
     * Lay all stage codes backward from [endUnixSeconds]. Code j of N starts at
     * `end - (N - j) * secondsPerCode`, so the final code ends exactly at the supplied sleep end.
     * Records and codes are never sorted; transport arrival order is preserved.
     *
     * When [sleepStartUnixSeconds] is present, leading epochs before that 0x49 onset are clipped. A
     * clamp that would remove the entire burst is ignored so a mis-paired window cannot erase a night.
     */
    fun codesWithTimes(
        endUnixSeconds: Long,
        sleepStartUnixSeconds: Long? = null,
        secondsPerCode: Long = OURA_SLEEPNET_EPOCH_SECONDS,
    ): List<OuraHypnogramEpoch> {
        require(secondsPerCode > 0) { "secondsPerCode must be positive" }
        val count = totalCodes
        val laidOut = ArrayList<OuraHypnogramEpoch>(count)
        var index = 0
        for (record in records) {
            for ((recordIndex, stage) in record.stages.withIndex()) {
                val timestamp = endUnixSeconds - (count - index) * secondsPerCode
                if (!record.unwritten[recordIndex]) {
                    laidOut.add(
                        OuraHypnogramEpoch(
                            stage = stage,
                            startUnixSeconds = timestamp,
                        ),
                    )
                }
                index += 1
            }
        }
        if (sleepStartUnixSeconds == null) return laidOut
        val clipped = laidOut.filter { it.startUnixSeconds >= sleepStartUnixSeconds }
        return if (clipped.isEmpty()) laidOut else clipped
    }
}

/**
 * Groups phase records by their envelope ring-time proximity. SleepNet writes a completed night as
 * one burst; records within [burstGapTicks] belong together only when their UTC anchor availability
 * agrees and any two anchored envelopes are also within the equivalent wall-clock gap. Ring time is
 * in 100-ms ticks, so the default 600-tick gap is 60 seconds.
 */
class OuraHypnogramAssembler(
    val burstGapTicks: Long = 600,
) {
    init {
        require(burstGapTicks >= 0) { "burstGapTicks must be non-negative" }
    }

    private var current = ArrayList<OuraHypnogramRecord>()

    /** Feed an already-decoded phase series. */
    fun feed(
        series: OuraSleepPhaseSeries,
        envelopeUnixSeconds: Long? = null,
    ): OuraHypnogramBurst? = feed(
        ringTimestamp = series.ringTimestamp,
        stages = series.stages,
        envelopeUnixSeconds = envelopeUnixSeconds,
        unwritten = series.unwritten,
    )

    /**
     * Feed one record. Returns the previous burst when this record starts a new burst, or null while
     * the current burst is still accumulating. Records with no stage codes are ignored.
     */
    fun feed(
        ringTimestamp: Long,
        stages: List<OuraSleepStage>,
        envelopeUnixSeconds: Long? = null,
        unwritten: List<Boolean> = List(stages.size) { false },
    ): OuraHypnogramBurst? {
        if (stages.isEmpty()) return null
        require(unwritten.size == stages.size) { "unwritten flags must match stage count" }
        val record = OuraHypnogramRecord(
            ringTimestamp = ringTimestamp,
            stages = stages.toList(),
            envelopeUnixSeconds = envelopeUnixSeconds,
            unwritten = unwritten.toList(),
        )
        val previous = current.lastOrNull()
        if (previous != null) {
            val ringGap = if (ringTimestamp >= previous.ringTimestamp) {
                ringTimestamp - previous.ringTimestamp
            } else {
                previous.ringTimestamp - ringTimestamp
            }
            val previousEnvelope = previous.envelopeUnixSeconds
            val anchorAvailabilityChanged =
                (previousEnvelope == null) != (envelopeUnixSeconds == null)
            val wallGapExceeded = if (previousEnvelope != null && envelopeUnixSeconds != null) {
                val wallGap = if (envelopeUnixSeconds >= previousEnvelope) {
                    envelopeUnixSeconds - previousEnvelope
                } else {
                    previousEnvelope - envelopeUnixSeconds
                }
                wallGap > burstGapTicks / 10
            } else {
                false
            }
            if (ringGap > burstGapTicks || anchorAvailabilityChanged || wallGapExceeded) {
                val completed = OuraHypnogramBurst(current.toList())
                current = arrayListOf(record)
                return completed
            }
        }
        current.add(record)
        return null
    }

    /** Close and return the in-progress burst, or null when there is no pending record. */
    fun flush(): OuraHypnogramBurst? {
        if (current.isEmpty()) return null
        val completed = OuraHypnogramBurst(current.toList())
        current = ArrayList()
        return completed
    }

    /** Discard partial state before beginning a fresh history session. */
    fun reset() {
        current = ArrayList()
    }

    /** Number of records currently accumulating; useful for bounded-state diagnostics. */
    val pendingRecordCount: Int get() = current.size
}
