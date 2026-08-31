import OuraProtocol

/// Converts the ring-provided, 30-second SleepNet epochs into the segment shape the existing sleep UI
/// and analytics already consume. This is a representation change only: the stages remain Oura's raw
/// on-ring classification and are persisted under the ring's own device id.
public enum OuraSleepSessionMapping {
    public static func session(
        from epochs: [OuraHypnogramEpoch],
        secondsPerEpoch: Int = 30,
        sessionStartUnixSeconds: Int? = nil,
        sessionEndUnixSeconds: Int? = nil,
        includeEfficiency: Bool = true
    ) -> CachedSleepSession? {
        guard secondsPerEpoch > 0, let first = epochs.first, let last = epochs.last else { return nil }
        let sessionStart = sessionStartUnixSeconds ?? first.ts
        let sessionEnd = sessionEndUnixSeconds ?? (last.ts + secondsPerEpoch)
        guard sessionEnd > sessionStart else { return nil }

        struct Segment {
            var start: Int
            var end: Int
            let stage: OuraSleepStage
        }

        var segments: [Segment] = []
        var asleepSeconds = 0
        var awakeSeconds = 0
        for epoch in epochs {
            let end = epoch.ts + secondsPerEpoch
            if var previous = segments.last,
               previous.stage == epoch.stage,
               previous.end == epoch.ts {
                previous.end = end
                segments[segments.count - 1] = previous
            } else {
                segments.append(Segment(start: epoch.ts, end: end, stage: epoch.stage))
            }
            if epoch.stage == .awake {
                awakeSeconds += secondsPerEpoch
            } else {
                asleepSeconds += secondsPerEpoch
            }
        }

        // Fixed key ordering keeps the durable Swift/Kotlin representation byte-identical.
        let stagesJSON = "[" + segments.map {
            "{\"start\":\($0.start),\"end\":\($0.end),\"stage\":\"\(token($0.stage))\"}"
        }.joined(separator: ",") + "]"
        let inBedSeconds = asleepSeconds + awakeSeconds

        return CachedSleepSession(
            startTs: sessionStart,
            endTs: sessionEnd,
            efficiency: includeEfficiency && inBedSeconds > 0
                ? Double(asleepSeconds) / Double(inBedSeconds)
                : nil,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: stagesJSON
        )
    }

    public static func token(_ stage: OuraSleepStage) -> String {
        switch stage {
        case .deep: return "deep"
        case .light: return "light"
        case .rem: return "rem"
        case .awake: return "wake"
        }
    }
}
