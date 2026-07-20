import Foundation

/// Experimental local calibration for the raw `0x8B` R-ratio stream. The coefficients are documented
/// by Open Oura from Oura's Android `SpO2 Simple` path and selected for Gen 4/Oreo hardware:
///
/// `SpO2% = -13.4 * r^2 - 5.1 * r + 105.2`, clamped to the app's 85...100 daily range.
///
/// This is not the firmware-computed production `0x6F` percentage. Keep the source distinction in
/// diagnostics and do not promote it into scoring until a NOOP Ring 4 overnight capture agrees with
/// the official app.
public enum OuraSpO2Calibration {
    public static func ring4OreoPercent(ratio: Double) -> Double? {
        guard ratio.isFinite, ratio > 0 else { return nil }
        let value = -13.4 * ratio * ratio - 5.1 * ratio + 105.2
        guard value.isFinite else { return nil }
        return min(100.0, max(85.0, value))
    }

    public static func ring4OreoTenthsPercent(ratioQ14: Int) -> Int? {
        guard (1...0xFFFF).contains(ratioQ14),
              let percent = ring4OreoPercent(ratio: Double(ratioQ14) / 16_384.0)
        else { return nil }
        return Int((percent * 10.0).rounded())
    }
}
