package com.noop.data

import com.noop.oura.OuraEvent
import com.noop.protocol.SkinTempSample
import com.noop.protocol.Spo2Sample
import com.noop.protocol.Streams
import com.noop.protocol.WhoopEvent

/**
 * Pure, JVM-testable mapping from the Oura ring's decoded [OuraEvent]s onto the datastore's
 * protocol [Streams] shape, so the WHOOP-isolated `OuraLiveSource` can persist its samples through
 * the SAME [WhoopRepository.insert] path (via [StreamPersistence.toBatch]) the WHOOP pipeline uses,
 * without duplicating row construction in the (untestable) app/BLE target. Kotlin twin of the Swift
 * `OuraStreamMapping` (WhoopStore), built from the architecture plan's section-4 table.
 *
 * HONEST-DATA INVARIANT (hard): we surface ONLY the ring's decoded raw signals and its OWN open
 * event tags. We never read or display Oura's encrypted readiness/sleep scores. NOOP computes its
 * own Charge/Rest downstream:
 *   - the IBI stream becomes [Streams.rr], from which RecoveryScorer reconstructs NOOP's OWN RMSSD;
 *   - the HR stream feeds resting-HR + strain;
 *   - the ring's open 0x5D HRV tag is recorded as an `OURA_HRV` diagnostic event carrying ITS RAW
 *     decoded fields (time_ms/b1/b2) ONLY, never a fabricated rmssd_ms (the int8 b1/b2 byte->ms
 *     scale is not Tier-A; NOOP's scoring RMSSD comes from `rr`, not this tag);
 *   - the open sleep-phase tags become diagnostic ordered-series events; cadence is not guessed.
 *
 * Each event carries a ring-clock `ringTimestamp` (not wall-clock). To stay pure and avoid baking a
 * clock model in here, the caller supplies an [anchor] resolving a ring timestamp to wall-clock unix
 * seconds (driven by the ring's 0x42/0x85 time-sync events upstream). When the anchor cannot place a
 * record (anchor returns null), the sample is DROPPED rather than stamped with a guessed time
 * (honest-data invariant), a ts-less biometric row is unstorable anyway.
 */
object OuraStreamMapping {
    /** Oura's app-side Ring 4 / Oreo quadratic, never confused with a firmware percentage. */
    const val ESTIMATED_SPO2_UNIT = "estimated_tenths_percent"


    /** The event `kind` recorded for the ring's own open HRV (0x5D) tag. Must match Swift exactly. */
    const val EVENT_HRV = "OURA_HRV"

    /**
     * The event `kind` for one complete diagnostic sleep-phase record. The new name intentionally
     * avoids legacy `OURA_SLEEP_PHASE` rows that stored only the record's first code.
     */
    const val EVENT_SLEEP_PHASE = "OURA_SLEEP_PHASE_SERIES"

    /** Verified 0x6A measurements; the unnamed state is preserved raw, never promoted to a stage. */
    const val EVENT_SLEEP_PERIOD = "OURA_SLEEP_PERIOD"

    /** Lossless raw `0x8B` record alongside any explicitly calibrated estimate. */
    const val EVENT_SPO2_RATIO_PI = "OURA_SPO2_RATIO_PI"

    /** Ring 4 hardware-backed `0x47` motion fields, retained as units-labelled diagnostics. */
    const val EVENT_MOTION_SUMMARY = "OURA_MOTION_SUMMARY"

    /** Six units-neutral fixed-point values from `0x72 sleep_acm_period`. */
    const val EVENT_SLEEP_ACM_PERIOD = "OURA_SLEEP_ACM_PERIOD"

    /** Ring 4-qualified `0x50` wire-order MET bins; state/timestamp role remain diagnostic. */
    const val EVENT_ACTIVITY_MET_SERIES = "OURA_ACTIVITY_MET_SERIES"

    /** Native-parser-backed 0x74 values with unresolved physical meaning. */
    const val EVENT_EXERCISE_HR_INTENSITY = "OURA_EXERCISE_HR_INTENSITY_SERIES"

    /** Native-parser-backed 0x86 arrays; never production HR until hardware-qualified. */
    const val EVENT_ALWAYS_ON_HR_SERIES = "OURA_ALWAYS_ON_HR_SERIES"

    /** Native-parser-backed 0x7E/0x7F fields with unresolved names and cross-part state. */
    const val EVENT_REAL_STEPS_FEATURES = "OURA_REAL_STEPS_FEATURES"

    /**
     * Fold a batch of decoded [events] into a protocol [Streams] for one flush. [anchor] maps a
     * ring-clock timestamp to wall-clock unix seconds (null => drop the sample). Pure: no BLE, no DB,
     * no clock, fully JVM-unit-testable. Tier-B events never reach scoring; if any leak in (they only
     * appear when the driver's allowTierB is set), they are ignored here so they cannot fabricate a
     * stream value.
     */
    fun streams(events: List<OuraEvent>, anchor: (Long) -> Int?): Streams {
        val out = Streams()
        for (ev in events) {
            when (ev) {
                is OuraEvent.Hr -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.hr.add(com.noop.protocol.HrSample(ts, ev.value.bpm))
                }

                is OuraEvent.Ibi -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.rr.add(com.noop.protocol.RrInterval(ts, ev.value.ibiMs))
                }

                is OuraEvent.Hrv -> {
                    // The ring's OWN open HRV tag, recorded raw for diagnostics/parity. NOT Oura's
                    // readiness score, and NOT used as NOOP's RMSSD (that comes from `rr`).
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.events.add(
                        WhoopEvent(
                            ts = ts,
                            kind = EVENT_HRV,
                            payload = linkedMapOf(
                                "time_ms" to ev.value.timeMs,
                                "b1" to ev.value.b1,
                                "b2" to ev.value.b2,
                            ),
                        ),
                    )
                }

                is OuraEvent.Spo2 -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    val tenths = when (ev.value.unit) {
                        "percent" -> ev.value.value * 10
                        "tenths_percent" -> ev.value.value
                        else -> continue
                    }
                    if (tenths !in 700..1000) continue
                    out.spo2.add(
                        Spo2Sample(
                            ts = ts + ev.value.sampleOffsetSeconds,
                            red = tenths,
                            ir = 0,
                            unit = "tenths_percent",
                        ),
                    )
                }

                is OuraEvent.Spo2Ratio -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    val payload = linkedMapOf<String, Any?>(
                        "header" to ev.value.header,
                        "ratio_q14" to ev.value.samples.map { it.ratioQ14 },
                        "perfusion_u8" to ev.value.samples.map { it.perfusionRaw },
                        "calibration_profile" to (ev.calibrationProfile?.raw ?: "none"),
                    )
                    ev.calibrationProfile?.let { profile ->
                        val calibrated = ev.value.samples.mapIndexedNotNull { index, sample ->
                            profile.calibratedTenthsPercent(sample.ratio)
                                ?.takeIf { it in 850..1_000 }
                                ?.let { index to it }
                        }
                        if (calibrated.isNotEmpty()) {
                            payload["calibrated_sample_indices"] = calibrated.map { it.first }
                            payload["calibrated_tenths_percent_samples"] = calibrated.map { it.second }
                            // One estimate per real record timestamp: partial boundary records exist and
                            // the individual optical samples do not carry independent timestamps.
                            out.spo2.add(
                                Spo2Sample(
                                    ts = ts,
                                    red = Math.round(calibrated.map { it.second }.average()).toInt(),
                                    ir = 0,
                                    unit = ESTIMATED_SPO2_UNIT,
                                ),
                            )
                        }
                    }
                    // The estimate-specific unit is preserved through storage. Analytics prefers measured
                    // firmware percentages and stamps provenance before any user-facing daily value.
                    out.events.add(WhoopEvent(ts, EVENT_SPO2_RATIO_PI, payload))
                }

                is OuraEvent.Temp -> {
                    // The ring exposes skin temperature in degrees C; the store's raw integer uses the
                    // codebase-wide CENTI-degree-C convention (°C = raw / 100, the scale the analytics
                    // reader divides by), so persist celsius * 100 and tag the unit. PARITY: the Swift
                    // twin stores the IDENTICAL celsius * 100, so the same decoded celsius yields the same
                    // raw integer on both platforms.
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.skinTemp.add(
                        SkinTempSample(
                            ts = ts,
                            raw = Math.round(ev.value.celsius * 100.0).toInt(),
                            unit = "centi_c",
                        ),
                    )
                }

                is OuraEvent.SleepPhaseEvent -> {
                    if (ev.value.stages.isEmpty()) continue
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.events.add(
                        WhoopEvent(
                            ts = ts,
                            kind = EVENT_SLEEP_PHASE,
                            payload = linkedMapOf<String, Any?>(
                                "source_tag" to ev.value.sourceTag,
                                "header" to ev.value.header,
                                "ring_timestamp" to ev.value.ringTimestamp,
                                "phase_codes" to ev.value.stages.map { it.raw },
                                "codebook" to "0=deep,1=light,2=rem,3=awake",
                            ),
                        ),
                    )
                }

                is OuraEvent.SleepPeriodEvent -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.events.add(
                        WhoopEvent(
                            ts = ts,
                            kind = EVENT_SLEEP_PERIOD,
                            payload = linkedMapOf<String, Any?>(
                                "average_hr_bpm" to ev.value.averageHeartRate,
                                "respiration_bpm" to ev.value.respirationRate,
                                "motion_count" to ev.value.motionCount,
                                "sleep_state" to ev.value.sleepState,
                            ),
                        ),
                    )
                }

                is OuraEvent.MotionSummaryEvent -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    val payload = linkedMapOf<String, Any?>(
                        "orientation" to ev.value.orientation,
                        "motion_seconds" to ev.value.motionSeconds,
                        "average_x_x8" to ev.value.averageX,
                        "average_y_x8" to ev.value.averageY,
                        "average_z_x8" to ev.value.averageZ,
                        "axis_unit" to "raw_x8",
                    )
                    ev.value.lowIntensity?.let { payload["low_intensity"] = it }
                    ev.value.lowIntensityFlag?.let { payload["low_intensity_flag"] = it }
                    ev.value.highIntensity?.let { payload["high_intensity"] = it }
                    ev.value.highIntensityFlag?.let { payload["high_intensity_flag"] = it }
                    out.events.add(WhoopEvent(ts, EVENT_MOTION_SUMMARY, payload))
                }

                is OuraEvent.SleepAcmPeriodEvent -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    if (ev.value.values.size != 6) continue
                    out.events.add(
                        WhoopEvent(
                            ts,
                            EVENT_SLEEP_ACM_PERIOD,
                            linkedMapOf(
                                "mad_0" to ev.value.values[0],
                                "mad_1" to ev.value.values[1],
                                "mad_2" to ev.value.values[2],
                                "mad_3" to ev.value.values[3],
                                "mad_4" to ev.value.values[4],
                                "mad_5" to ev.value.values[5],
                                "unit" to "fixed_point_raw",
                            ),
                        ),
                    )
                }

                is OuraEvent.ActivityInfo -> {
                    if (ev.value.met.isEmpty()) continue
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    // The retained Ring 4 corpus validates one-minute bin cadence, but not whether the
                    // record timestamp names the first or last bin. Preserve the ordered array at the
                    // real record anchor. Integer tenths are lossless for the wire's 0.1/0.2-MET scales.
                    out.events.add(
                        WhoopEvent(
                            ts,
                            EVENT_ACTIVITY_MET_SERIES,
                            linkedMapOf(
                                "ring_timestamp" to ev.value.ringTimestamp,
                                "state_raw" to ev.value.state,
                                "met_x10" to ev.value.met.map { Math.round(it * 10.0).toInt() },
                                "sample_interval_seconds" to 60,
                                "sequence_order" to "wire_order",
                                "timestamp_semantics" to "record_anchor_only",
                                "unit" to "tenths_met",
                            ),
                        ),
                    )
                }

                is OuraEvent.ExerciseHRIntensity -> {
                    if (ev.value.values.isEmpty()) continue
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.events.add(
                        WhoopEvent(
                            ts,
                            EVENT_EXERCISE_HR_INTENSITY,
                            linkedMapOf(
                                "ring_timestamp" to ev.value.ringTimestamp,
                                "intensity_u16" to ev.value.values,
                                "sequence_order" to "wire_order",
                                "timestamp_semantics" to "record_anchor_only",
                                "unit" to "raw_u16",
                                "field_semantics" to "unvalidated",
                            ),
                        ),
                    )
                }

                is OuraEvent.AlwaysOnHR -> {
                    if (ev.value.bpm.isEmpty() || ev.value.bpm.size != ev.value.quality.size) continue
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.events.add(
                        WhoopEvent(
                            ts,
                            EVENT_ALWAYS_ON_HR_SERIES,
                            linkedMapOf(
                                "ring_timestamp" to ev.value.ringTimestamp,
                                "flag_raw" to ev.value.flag,
                                "base_offset_raw" to ev.value.baseOffset,
                                "interval_ms" to ev.value.intervalMs,
                                "bpm_u8" to ev.value.bpm,
                                "quality_u8" to ev.value.quality,
                                "sequence_order" to "wire_order",
                                "timestamp_semantics" to "record_anchor_only",
                                "field_semantics" to "unvalidated",
                            ),
                        ),
                    )
                }

                is OuraEvent.RealStepsFeatures -> {
                    if (ev.value.fields.size != 14) continue
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.events.add(
                        WhoopEvent(
                            ts,
                            EVENT_REAL_STEPS_FEATURES,
                            linkedMapOf(
                                "ring_timestamp" to ev.value.ringTimestamp,
                                "source_tag" to ev.value.sourceTag,
                                "feature_fields_u16" to ev.value.fields,
                                "sequence_order" to "wire_order",
                                "timestamp_semantics" to "record_anchor_only",
                                "field_semantics" to "unvalidated",
                                "part_relationship" to "stateful_unknown",
                            ),
                        ),
                    )
                }

                is OuraEvent.Battery -> {
                    // Live battery percent. No ring timestamp on a battery reading (it is a command
                    // response), so it is stamped by the live source's `onBattery` path, not persisted
                    // as a tied-to-ts row here. Leave the batch's battery list empty (honest: no faked ts).
                }

                // Packed motion / state / time-sync / rtc / debug / TierB never map onto a scored
                // stream. Hardware-backed summary records above are diagnostic events only. In
                // particular, 0x50 activity/MET NEVER mints steps, calories, or a workout row.
                else -> Unit
            }
        }
        return out
    }
}
