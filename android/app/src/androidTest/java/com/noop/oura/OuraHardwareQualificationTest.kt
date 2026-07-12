package com.noop.oura

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.content.Context
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.noop.ble.OuraLiveSource
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Opt-in physical-hardware qualification for a Ring 4 already bonded in Android Settings.
 *
 * This exercises the production [OuraLiveSource] direct-connect path and waits only for its safe,
 * pre-auth identity reads. It never grants adopt consent, never installs an application key, and never
 * requests the serial-number product page. Run explicitly on a connected Android device:
 *
 *   ./gradlew :app:connectedFullDebugAndroidTest \
 *     -Pandroid.testInstrumentationRunnerArguments.class=com.noop.oura.OuraHardwareQualificationTest
 */
@RunWith(AndroidJUnit4::class)
class OuraHardwareQualificationTest {
    @SuppressLint("MissingPermission")
    @Test
    fun readsPrivacySafeIdentityFromBondedRing4() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val adapter = context.getSystemService(BluetoothManager::class.java).adapter
        val ring = adapter.bondedDevices.firstOrNull { device ->
            runCatching { device.name }.getOrNull()?.contains("Oura Ring 4", ignoreCase = true) == true
        }
        assertNotNull("Bond an Oura Ring 4 in Android Settings before running this test", ring)

        val identityLines = Collections.synchronizedList(mutableListOf<String>())
        val identityLatch = CountDownLatch(2)
        val source = OuraLiveSource(
            context = context,
            deviceId = "hardware-qualification",
            ringGen = OuraRingGen.GEN4,
            liveSink = { _, _ -> },
            authKey = { null },
            persist = { _, _ -> },
            log = { line ->
                val safe = line.replace(MAC_ADDRESS, "XX:XX:XX:XX:XX:XX")
                Log.i(LOG_TAG, safe)
                if (safe.startsWith("Oura: identity ")) {
                    identityLines += safe
                    identityLatch.countDown()
                }
            },
        )

        try {
            source.connect(requireNotNull(ring).address)
            val complete = identityLatch.await(75, TimeUnit.SECONDS)
            assertTrue("Timed out waiting for both privacy-safe identity responses: $identityLines", complete)
            assertTrue(identityLines.any { it.contains("selected=Oura Ring 4 firmware=") })
            assertTrue(identityLines.any { it.startsWith("Oura: identity hardware=") })
        } finally {
            source.stop()
        }
    }

    private companion object {
        const val LOG_TAG = "OuraQualification"
        val MAC_ADDRESS = Regex("(?i)(?:[0-9a-f]{2}:){5}[0-9a-f]{2}")
    }
}
