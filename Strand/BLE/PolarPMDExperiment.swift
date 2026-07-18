import Foundation

/// Opt-in Polar Measurement Data (PMD) streams.
///
/// Standard 0x180D heart rate and battery remain the default path. PMD is deliberately separate
/// because keeping the ring/strap accelerometer and beat-to-beat stream active costs more battery.
/// The source reads this preference when a Polar connection is established; changing it takes effect
/// on the next connection.
enum PolarPMDExperiment {
    static let defaultsKey = "noopPolarDeepStreams"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
