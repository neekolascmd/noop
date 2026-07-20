package com.noop.oura

import kotlin.math.roundToInt

/**
 * Experimental local calibration for the raw `0x8B` R-ratio stream. Open Oura documents the
 * Gen 4/Oreo "SpO2 Simple" path as:
 *
 * `SpO2% = -13.4 * r^2 - 5.1 * r + 105.2`, clamped to the app's 85..100 daily range.
 *
 * This is distinct from the firmware-computed production `0x6F` percentage and must remain visibly
 * experimental until a NOOP Ring 4 overnight capture agrees with the official app.
 */
object OuraSpO2Calibration {
    fun ring4OreoPercent(ratio: Double): Double? {
        if (!ratio.isFinite() || ratio <= 0.0) return null
        val value = -13.4 * ratio * ratio - 5.1 * ratio + 105.2
        if (!value.isFinite()) return null
        return value.coerceIn(85.0, 100.0)
    }

    fun ring4OreoTenthsPercent(ratioQ14: Int): Int? {
        if (ratioQ14 !in 1..0xFFFF) return null
        return ring4OreoPercent(ratioQ14 / 16_384.0)?.let { (it * 10.0).roundToInt() }
    }
}
