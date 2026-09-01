package com.noop.garmin

import com.noop.data.EventEntry
import com.noop.data.HrRow
import com.noop.data.RrRow
import com.noop.data.Spo2Row
import com.noop.data.StepRow
import com.noop.data.StreamBatch

/**
 * Conservative bridge from decoded Garmin realtime values into NOOP's existing device-agnostic rows.
 *
 * The decoder always preserves raw bytes. This mapper emits a row only when the value's meaning and
 * range are known. In particular, Body Battery and accelerometer payloads remain opaque and are never
 * squeezed into an unrelated table. Garmin SpO2 is a percentage, so it uses the existing explicit
 * `tenths_percent` unit rather than pretending to be WHOOP raw ADC.
 */
data class GarminMappedRealtime(
    val batch: StreamBatch = StreamBatch(),
    val liveHeartRate: Int? = null,
    val liveRrMilliseconds: Int? = null,
)

object GarminRealtimeMapping {
    /** 2023-11-01 UTC, matching NOOP's existing raw-history plausibility floor. */
    const val MIN_PLAUSIBLE_UNIX_SECONDS: Long = 1_698_796_800L
    const val FUTURE_MARGIN_SECONDS: Long = 86_400L

    fun map(
        value: GarminRealtimeValue,
        receiptUnixSeconds: Long,
        nowUnixSeconds: Long = receiptUnixSeconds,
    ): GarminMappedRealtime = when (value) {
        is GarminRealtimeValue.HeartRate -> {
            val bpm = value.heartRateBpm?.takeIf { it in 30..220 }
            GarminMappedRealtime(
                batch = if (bpm == null) StreamBatch() else StreamBatch(hr = listOf(HrRow(receiptUnixSeconds, bpm))),
                liveHeartRate = bpm,
            )
        }
        is GarminRealtimeValue.Hrv -> {
            val rr = value.rrMilliseconds?.takeIf { it in 200..3_000 }
            GarminMappedRealtime(
                batch = if (rr == null) StreamBatch() else StreamBatch(rr = listOf(RrRow(receiptUnixSeconds, rr))),
                liveRrMilliseconds = rr,
            )
        }
        is GarminRealtimeValue.Steps -> GarminMappedRealtime(
            batch = StreamBatch(steps = listOf(StepRow(receiptUnixSeconds, value.steps))),
        )
        is GarminRealtimeValue.Spo2 -> {
            val percent = value.percent
            val timestamp = value.unixSeconds
            val plausible = timestamp in MIN_PLAUSIBLE_UNIX_SECONDS..(nowUnixSeconds + FUTURE_MARGIN_SECONDS)
            GarminMappedRealtime(
                batch = if (percent == null || !plausible) StreamBatch() else StreamBatch(
                    spo2 = listOf(Spo2Row(timestamp, red = percent * 10, ir = 0, unit = "tenths_percent")),
                ),
            )
        }
        is GarminRealtimeValue.Respiration -> {
            val breaths = value.breathsPerMinute
            GarminMappedRealtime(
                batch = if (breaths == null) StreamBatch() else StreamBatch(
                    events = listOf(
                        EventEntry(
                            ts = receiptUnixSeconds,
                            kind = "GARMIN_REALTIME_RESPIRATION",
                            payloadJSON = "{\"breaths_per_minute\":$breaths}",
                        ),
                    ),
                ),
            )
        }
        is GarminRealtimeValue.Opaque -> GarminMappedRealtime()
    }
}
