import Foundation
import WhoopProtocol
import OuraProtocol

/// Pure, testable mapping from a batch of decoded `OuraEvent` (emitted by `OuraProtocol.OuraDriver`)
/// onto the datastore's `Streams` shape, so the isolated live Oura source (`OuraLiveSource` in the app
/// target) can persist its samples through the SAME `StreamStore.insert` path the WHOOP pipeline uses,
/// keyed by the ring's own `deviceId`, without duplicating row-construction logic in the app target
/// where it can't be unit-tested. Parallels `StandardHRMapping`.
///
/// Honest-data invariant (hard): we surface only the ring's decoded raw signals + its own open event
/// tags (HR/IBI/HRV/SpO2/temp/sleep-phase/battery). We NEVER read or surface Oura's encrypted readiness
/// or sleep scores. NOOP computes its own Charge/Rest downstream from these per-device streams. The
/// `OuraHRV` 0x5D tag is the ring's OWN RMSSD-derived HRV signal (OURA_PROTOCOL.md s6.9), not a readiness
/// score; NOOP also independently reconstructs RMSSD from the IBI streams for its own scoring.
///
/// Timestamping: the live source streams a batch and stamps every row at the arrival wall-clock `ts`
/// (unix seconds), exactly as `StandardHRMapping.samples(...at:)` does. The decoded events carry only a
/// ring-clock `ringTimestamp` (a `(session << 16) | counter` value, NOT wall-clock), so anchoring is the
/// transport's job; the mapping stays pure and deterministic by taking the wall-clock `ts` as input. A
/// signal that could not be decoded never reaches this layer (the decoders return nil upstream), so a
/// missing stream stays empty here, never faked (Huami precedent).
///
/// Tier-B (UNVERIFIED) events are dropped. Tier-A signals may enter production streams; explicitly
/// named diagnostic events (sleep-phase, raw SpO2 ratio/PI, motion, and activity series) are durable
/// evidence but have no scoring consumer. An unverified summary can therefore never silently feed scoring.
public enum OuraStreamMapping {
    /// Oura's app-side Ring 4 / Oreo quadratic, kept distinct from a firmware percentage.
    public static let estimatedSpO2Unit = "estimated_tenths_percent"

    /// WhoopEvent.kind for the ring's own HRV 0x5D tag. The payload carries the RAW decoded fields
    /// (`time_ms`/`b1`/`b2`) only, never a fabricated `rmssd_ms` (the b1/b2 byte -> ms scale is not
    /// Tier-A; see OURA_PROTOCOL.md s6.9). Must match the Kotlin twin (OuraStreamMapping.kt) exactly.
    public static let hrvEventKind = "OURA_HRV"
    /// WhoopEvent.kind for one complete diagnostic sleep-phase record. The new name intentionally
    /// does not collide with legacy `OURA_SLEEP_PHASE` rows that stored only the record's first code.
    public static let sleepPhaseEventKind = "OURA_SLEEP_PHASE_SERIES"
    /// Verified 0x6A measurements, preserved without interpreting its unnamed 0/1/2 state as stages.
    public static let sleepPeriodEventKind = "OURA_SLEEP_PERIOD"
    /// Lossless raw `0x8B` record alongside any explicitly calibrated estimate.
    public static let spo2RatioEventKind = "OURA_SPO2_RATIO_PI"
    /// Ring 4 hardware-backed `0x47` motion fields, retained as units-labelled diagnostics.
    public static let motionSummaryEventKind = "OURA_MOTION_SUMMARY"
    /// Six units-neutral fixed-point values from `0x72 sleep_acm_period`.
    public static let sleepAcmPeriodEventKind = "OURA_SLEEP_ACM_PERIOD"
    /// Ring 4-qualified `0x50` wire-order MET bins. The raw state and record anchor remain unresolved.
    public static let activityMetSeriesEventKind = "OURA_ACTIVITY_MET_SERIES"
    /// Native-parser-backed 0x74 values with unresolved physical meaning.
    public static let exerciseHRIntensityEventKind = "OURA_EXERCISE_HR_INTENSITY_SERIES"
    /// Native-parser-backed 0x7E/0x7F fields with unresolved names and cross-part state.
    public static let realStepsFeaturesEventKind = "OURA_REAL_STEPS_FEATURES"

    /// Build a `Streams` from a batch of decoded Oura events, all stamped at the arrival wall-clock `ts`
    /// (unix seconds). Pure → unit-testable. Section-4 table:
    ///   - `.hr`         (0x55 live-HR push)            → `hr:[HRSample]`
    ///   - `.ibi`        (0x44/0x60 IBI)                → `rr:[RRInterval]`
    ///   - `.hrv`        (0x5D HRV tag, raw int8 b1/b2)  → `events:[WhoopEvent(kind: OURA_HRV)]`
    ///   - `.spo2`       (0x6F/0x70/0x77)              → `spo2:[SpO2Sample(raw_adc)]`
    ///   - `.temp`       (0x46/0x75)                    → `skinTemp:[SkinTempSample(raw_adc)]`
    ///   - `.sleepPhase` (0x4E/0x5A ordered codes)      → one diagnostic series event per source record
    ///   - `.battery`                                   → `battery:[BatterySample]`
    /// The hardware-backed `.motionSummary`, `.sleepAcmPeriod`, and `.activityInfo` cases become
    /// diagnostic events only. Packed `.motion`, lifecycle, transport, debug, and Tier-B cases remain
    /// non-durable. In particular the 0x50 activity/MET decode NEVER mints a `steps`, calories, or workout
    /// row: MET is not a step count, and the state/timestamp roles remain unresolved.
    public static func streams(from events: [OuraEvent], at ts: Int) -> Streams {
        var out = Streams()
        for e in events {
            switch e {
            case .hr(let v):
                // Honest HR: surface only the ring's decoded BPM. The push also carries one IBI, but the
                // dedicated `.ibi` events are the R-R source, so we do not synthesise an RR row from the HR
                // push here to avoid double-counting the same interval.
                out.hr.append(HRSample(ts: ts, bpm: v.bpm))

            case .ibi(let v):
                out.rr.append(RRInterval(ts: ts, rrMs: v.ibiMs))

            case .hrv(let v):
                // The ring's own 0x5D tag, carried RAW for diagnostics/parity. The two int8 fields
                // (b1/b2) plus the sample's relative time offset are surfaced under units-neutral keys.
                // We do NOT mint an `rmssd_ms` here: the int8 b1/b2 byte -> millisecond scaling is NOT
                // Tier-A (OURA_PROTOCOL.md s6.9 leaves it unpinned), so labelling a raw byte as a
                // millisecond RMSSD would fabricate units (honest-data invariant). NOOP's own scoring
                // RMSSD is reconstructed from the IBI stream (`rr`), never from this open tag. Keys and
                // values are IDENTICAL to the Kotlin twin (OuraStreamMapping.kt) so both platforms emit
                // byte-for-byte the same OURA_HRV payload.
                out.events.append(WhoopEvent(ts: ts, kind: hrvEventKind, payload: [
                    "time_ms": .int(v.timeMs),
                    "b1": .int(v.b1),
                    "b2": .int(v.b2),
                ]))

            case .spo2(let v):
                // Only percentage-qualified sources become a durable oxygen sample. Ring 4's 0x77 DC
                // channel is a raw optical waveform, not a percentage, and must never feed daily SpO2.
                let tenths: Int
                switch v.unit {
                case "percent": tenths = v.value * 10
                case "tenths_percent": tenths = v.value
                default: continue
                }
                guard (700...1000).contains(tenths) else { continue }
                out.spo2.append(SpO2Sample(ts: ts + v.sampleOffsetSeconds,
                                          red: tenths, ir: 0, unit: "tenths_percent"))

            case .spo2Ratio(let record, let profile):
                let ratioQ14 = record.samples.map(\.ratioQ14)
                let perfusionRaw = record.samples.map(\.perfusionRaw)
                var payload: [String: ParsedValue] = [
                    "header": .int(Int(record.header)),
                    "ratio_q14": .intArray(ratioQ14),
                    "perfusion_u8": .intArray(perfusionRaw),
                    "calibration_profile": .string(profile?.rawValue ?? "none"),
                ]
                if let profile {
                    let calibrated = record.samples.enumerated().compactMap { index, sample -> (Int, Int)? in
                        guard let tenths = profile.calibratedTenthsPercent(ratio: sample.ratio),
                              (850...1_000).contains(tenths) else { return nil }
                        return (index, tenths)
                    }
                    if !calibrated.isEmpty {
                        payload["calibrated_sample_indices"] = .intArray(calibrated.map(\.0))
                        payload["calibrated_tenths_percent_samples"] = .intArray(calibrated.map(\.1))
                        // Retain one explicitly-labelled estimate per real record timestamp. Almost every
                        // qualified Ring 4 record carries four one-second optical samples, but partial
                        // boundary records exist and the per-sample clock has no independent timestamp.
                        // A record mean avoids inventing timestamps or primary-key collisions while making
                        // the locally reproducible Oura Simple result available to offline analytics.
                        let meanTenths = Int(
                            (Double(calibrated.reduce(0) { $0 + $1.1 }) /
                             Double(calibrated.count)).rounded()
                        )
                        out.spo2.append(SpO2Sample(
                            ts: ts, red: meanTenths, ir: 0, unit: estimatedSpO2Unit
                        ))
                    }
                }
                // The raw and calibrated arrays remain available for lossless future re-analysis. The
                // SpO2 row above carries an estimate-specific unit; analytics keeps measured percentages
                // authoritative and propagates explicit provenance to every user-facing daily value.
                out.events.append(WhoopEvent(ts: ts, kind: spo2RatioEventKind, payload: payload))

            case .temp(let v):
                // The decoder yields degrees C. The durable `SkinTempSample.raw` is an integer in the
                // codebase-wide CENTI-degree-C convention: the WHOOP @73 historical path stores raw at
                // this scale and the analytics reader (AnalyticsEngine.skinTempFunnel) divides raw by 100
                // to recover °C. We store the SAME centi-°C scale so an Oura night reads on the SAME gates
                // as a WHOOP night with no scorer change, and tag the unit so the convention is explicit
                // and never silently assumed. PARITY: the Kotlin twin stores the SAME celsius * 100, so a
                // given decoded celsius yields an IDENTICAL raw integer on both platforms.
                out.skinTemp.append(SkinTempSample(ts: ts, raw: Int((v.celsius * 100).rounded()), unit: "centi_c"))

            case .sleepPhase(let v):
                guard !v.stages.isEmpty else { continue }
                out.events.append(WhoopEvent(ts: ts, kind: sleepPhaseEventKind, payload: [
                    "source_tag": .int(Int(v.sourceTag)),
                    "header": .int(Int(v.header)),
                    "ring_timestamp": .int(Int(v.ringTimestamp)),
                    "phase_codes": .intArray(v.stages.map(\.rawValue)),
                    "codebook": .string("0=deep,1=light,2=rem,3=awake"),
                ]))

            case .sleepPeriod(let v):
                out.events.append(WhoopEvent(ts: ts, kind: sleepPeriodEventKind, payload: [
                    "average_hr_bpm": .double(v.averageHeartRate),
                    "respiration_bpm": .double(v.respirationRate),
                    "motion_count": .int(v.motionCount),
                    "sleep_state": .int(v.sleepState),
                ]))

            case .motionSummary(let v):
                var payload: [String: ParsedValue] = [
                    "orientation": .int(v.orientation),
                    "motion_seconds": .int(v.motionSeconds),
                    "average_x_x8": .int(v.averageX),
                    "average_y_x8": .int(v.averageY),
                    "average_z_x8": .int(v.averageZ),
                    "axis_unit": .string("raw_x8"),
                ]
                if let value = v.lowIntensity { payload["low_intensity"] = .int(value) }
                if let value = v.lowIntensityFlag { payload["low_intensity_flag"] = .bool(value) }
                if let value = v.highIntensity { payload["high_intensity"] = .int(value) }
                if let value = v.highIntensityFlag { payload["high_intensity_flag"] = .bool(value) }
                out.events.append(WhoopEvent(ts: ts, kind: motionSummaryEventKind, payload: payload))

            case .sleepAcmPeriod(let v):
                guard v.values.count == 6 else { continue }
                out.events.append(WhoopEvent(ts: ts, kind: sleepAcmPeriodEventKind, payload: [
                    "mad_0": .double(v.values[0]),
                    "mad_1": .double(v.values[1]),
                    "mad_2": .double(v.values[2]),
                    "mad_3": .double(v.values[3]),
                    "mad_4": .double(v.values[4]),
                    "mad_5": .double(v.values[5]),
                    "unit": .string("fixed_point_raw"),
                ]))

            case .activityInfo(let v):
                guard !v.met.isEmpty else { continue }
                // The retained Ring 4 corpus validates one-minute bin cadence, but not whether the
                // record timestamp names the first or last bin. Keep the ordered array atomic at the
                // real record anchor; future offline re-decoding can resolve direction without ever
                // reconnecting the ring. Integer tenths are lossless for the wire's 0.1/0.2-MET scales.
                out.events.append(WhoopEvent(ts: ts, kind: activityMetSeriesEventKind, payload: [
                    "ring_timestamp": .int(Int(v.ringTimestamp)),
                    "state_raw": .int(v.state),
                    "met_x10": .intArray(v.met.map { Int(($0 * 10).rounded()) }),
                    "sample_interval_seconds": .int(60),
                    "sequence_order": .string("wire_order"),
                    "timestamp_semantics": .string("record_anchor_only"),
                    "unit": .string("tenths_met"),
                ]))

            case .exerciseHRIntensity(let v):
                guard !v.values.isEmpty else { continue }
                out.events.append(WhoopEvent(ts: ts, kind: exerciseHRIntensityEventKind, payload: [
                    "ring_timestamp": .int(Int(v.ringTimestamp)),
                    "intensity_u16": .intArray(v.values),
                    "sequence_order": .string("wire_order"),
                    "timestamp_semantics": .string("record_anchor_only"),
                    "unit": .string("raw_u16"),
                    "field_semantics": .string("unvalidated"),
                ]))

            case .realStepsFeatures(let v):
                guard v.fields.count == 14 else { continue }
                out.events.append(WhoopEvent(ts: ts, kind: realStepsFeaturesEventKind, payload: [
                    "ring_timestamp": .int(Int(v.ringTimestamp)),
                    "source_tag": .int(Int(v.sourceTag)),
                    "feature_fields_u16": .intArray(v.fields),
                    "sequence_order": .string("wire_order"),
                    "timestamp_semantics": .string("record_anchor_only"),
                    "field_semantics": .string("unvalidated"),
                    "part_relationship": .string("stateful_unknown"),
                ]))

            case .battery(let v):
                out.battery.append(BatterySample(
                    ts: ts,
                    soc: Double(v.percent),
                    mv: v.voltageMv,
                    charging: v.charging))

            case .bedtimePeriod, .motion, .state, .timeSync, .rtcBeacon, .debugText, .tierB:
                // Not a durable per-device stream row (timeSync/rtcBeacon anchor the transport's clock;
                // packed motion/state/debug remain non-durable; Tier-B must never feed scoring).
                continue
            }
        }
        return out
    }
}
