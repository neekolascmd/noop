package com.noop.data

import com.noop.oura.OuraHypnogramEpoch
import com.noop.oura.OuraSleepStage

/** Byte-identical Kotlin twin of Swift's OuraSleepSessionMapping. */
object OuraSleepSessionMapping {
    fun session(
        epochs: List<OuraHypnogramEpoch>,
        deviceId: String,
        secondsPerEpoch: Long = 30,
        sessionStartUnixSeconds: Long? = null,
        sessionEndUnixSeconds: Long? = null,
        includeEfficiency: Boolean = true,
    ): SleepSession? {
        if (epochs.isEmpty() || deviceId.isEmpty() || secondsPerEpoch <= 0) return null
        val sessionStart = sessionStartUnixSeconds ?: epochs.first().startUnixSeconds
        val sessionEnd = sessionEndUnixSeconds ?: (epochs.last().startUnixSeconds + secondsPerEpoch)
        if (sessionEnd <= sessionStart) return null

        data class Segment(var start: Long, var end: Long, val stage: OuraSleepStage)

        val segments = mutableListOf<Segment>()
        var asleepSeconds = 0L
        var awakeSeconds = 0L
        for (epoch in epochs) {
            val end = epoch.startUnixSeconds + secondsPerEpoch
            val previous = segments.lastOrNull()
            if (previous != null && previous.stage == epoch.stage &&
                previous.end == epoch.startUnixSeconds
            ) {
                previous.end = end
            } else {
                segments += Segment(epoch.startUnixSeconds, end, epoch.stage)
            }
            if (epoch.stage == OuraSleepStage.AWAKE) {
                awakeSeconds += secondsPerEpoch
            } else {
                asleepSeconds += secondsPerEpoch
            }
        }

        // Fixed field ordering is part of the cross-platform durable-value contract.
        val stagesJSON = segments.joinToString(prefix = "[", postfix = "]", separator = ",") {
            "{\"start\":${it.start},\"end\":${it.end},\"stage\":\"${token(it.stage)}\"}"
        }
        val inBedSeconds = asleepSeconds + awakeSeconds
        return SleepSession(
            deviceId = deviceId,
            startTs = sessionStart,
            endTs = sessionEnd,
            efficiency = if (includeEfficiency && inBedSeconds > 0) {
                asleepSeconds.toDouble() / inBedSeconds
            } else {
                null
            },
            stagesJSON = stagesJSON,
        )
    }

    fun token(stage: OuraSleepStage): String = when (stage) {
        OuraSleepStage.DEEP -> "deep"
        OuraSleepStage.LIGHT -> "light"
        OuraSleepStage.REM -> "rem"
        OuraSleepStage.AWAKE -> "wake"
    }
}
