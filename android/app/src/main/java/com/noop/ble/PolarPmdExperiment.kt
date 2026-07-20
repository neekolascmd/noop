package com.noop.ble

import android.content.Context
import android.content.SharedPreferences

/**
 * Opt-in Polar Measurement Data (PMD) streams.
 *
 * Standard 0x180D heart rate and battery stay enabled regardless. PMD is a separate, default-off
 * switch because keeping Polar's accelerometer and beat-to-beat stream active costs more battery.
 * The BLE source reads it when the connection is established; changes apply on reconnect.
 */
class PolarPmdExperiment(private val prefs: SharedPreferences) {
    var enabled: Boolean
        get() = prefs.getBoolean(KEY, false)
        set(value) = prefs.edit().putBoolean(KEY, value).apply()

    companion object {
        private const val PREFS = "noop_experiments"
        const val KEY = "noopPolarDeepStreams"

        fun from(context: Context): PolarPmdExperiment =
            PolarPmdExperiment(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}
