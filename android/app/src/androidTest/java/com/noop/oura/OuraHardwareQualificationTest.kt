package com.noop.oura

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.content.Context
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.noop.ble.OuraInstallKeyStore
import com.noop.ble.OuraLiveSource
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.security.KeyFactory
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertEquals
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
    /** Scan-only recovery probe; never connects, bonds, authenticates, or writes to the ring. */
    @Test
    fun discoversRing4Advertisement() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val source = OuraLiveSource(
            context = context,
            deviceId = "hardware-qualification-ring4",
            ringGen = OuraRingGen.GEN4,
            liveSink = { _, _ -> },
            authKey = { null },
            persist = { _, _ -> },
            log = ::safeLog,
        )
        try {
            source.scan()
            assertNotNull("No Ring 4 advertisement appeared", waitUntil(45_000) { source.discovered.value.firstOrNull() })
        } finally {
            source.stop()
        }
    }

    /**
     * Debug-test-only bridge for cross-host qualification. The stored ring key is encrypted to a caller-
     * supplied ephemeral RSA public key before it leaves the Android process; plaintext, device address,
     * and serial are never logged. Two explicit runner arguments prevent an ordinary test invocation from
     * exporting even ciphertext.
     */
    @Test
    fun exportsStoredKeyEncryptedForAppleQualification() {
        val args = InstrumentationRegistry.getArguments()
        assertEquals("true", args.getString("ouraEncryptedKeyExportConfirmed"))
        val publicKeyBase64 = requireNotNull(args.getString("ouraTransferPublicKey"))
        val context = ApplicationProvider.getApplicationContext<Context>()
        val key = requireNotNull(OuraInstallKeyStore.load(context, "hardware-qualification-ring4"))
        val plaintext = ByteArray(key.size) { key[it].toByte() }
        try {
            val publicKey = KeyFactory.getInstance("RSA").generatePublic(
                X509EncodedKeySpec(Base64.decode(publicKeyBase64, Base64.NO_WRAP)),
            )
            val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
            cipher.init(
                Cipher.ENCRYPT_MODE,
                publicKey,
                OAEPParameterSpec(
                    "SHA-256",
                    "MGF1",
                    MGF1ParameterSpec.SHA256,
                    PSource.PSpecified.DEFAULT,
                ),
            )
            val encrypted = cipher.doFinal(plaintext)
            Log.i(LOG_TAG, "Oura: encrypted key transfer payload=${Base64.encodeToString(encrypted, Base64.NO_WRAP)}")
        } finally {
            plaintext.fill(0)
            key.fill(0)
        }
    }

    /** Read-only verification that a previously acknowledged NOOP key authenticates on a fresh link. */
    @SuppressLint("MissingPermission")
    @Test
    fun reconnectsWithStoredAdoptedKey() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val deviceId = "hardware-qualification-ring4"
        assertTrue("No acknowledged Ring 4 install key is stored", OuraInstallKeyStore.hasKey(context, deviceId))

        val adapter = context.getSystemService(BluetoothManager::class.java).adapter
        val ring = adapter.bondedDevices.firstOrNull { device ->
            runCatching { device.name }.getOrNull()?.contains("Oura", ignoreCase = true) == true
        }
        assertNotNull("The adopted Ring 4 is not bonded in Android Settings", ring)

        val sawHr = AtomicBoolean(false)
        val sawRr = AtomicBoolean(false)
        val hrCount = AtomicInteger(0)
        val rrCount = AtomicInteger(0)
        val lastHrAt = AtomicLong(0)
        val lastRrAt = AtomicLong(0)
        val liveLatch = CountDownLatch(1)

        val source = OuraLiveSource(
            context = context,
            deviceId = deviceId,
            ringGen = OuraRingGen.GEN4,
            liveSink = { hr, rr ->
                val now = SystemClock.elapsedRealtime()
                if (hr in 30..240) {
                    sawHr.set(true)
                    hrCount.incrementAndGet()
                    lastHrAt.set(now)
                }
                if (rr.any { it in 250..2_500 }) {
                    sawRr.set(true)
                    rrCount.incrementAndGet()
                    lastRrAt.set(now)
                }
                if (sawHr.get() && sawRr.get()) liveLatch.countDown()
            },
            authKey = { OuraInstallKeyStore.load(context, deviceId) },
            persist = { _, _ -> },
            log = ::safeLog,
        )

        try {
            source.connect(requireNotNull(ring).address)
            val phase = waitUntil(75_000) {
                source.adoptPhase.value.takeIf {
                    it == OuraLiveSource.AdoptPhase.Streaming || it == OuraLiveSource.AdoptPhase.Failed
                }
            }
            assertEquals(OuraLiveSource.AdoptPhase.Streaming, phase)
            assertTrue(
                "Streaming started but no plausible live HR + R-R pair arrived",
                liveLatch.await(120, TimeUnit.SECONDS),
            )
            safeLog("Oura: qualification live sample received (hr=true rr=true)")

            val sustainMs = InstrumentationRegistry.getArguments()
                .getString("ouraSustainDurationMs")
                ?.toLongOrNull()
                ?.coerceIn(0, TimeUnit.HOURS.toMillis(24))
                ?: 0L
            if (sustainMs > 0) {
                val startedAt = SystemClock.elapsedRealtime()
                val startingHrCount = hrCount.get()
                val startingRrCount = rrCount.get()
                val deadline = startedAt + sustainMs
                while (SystemClock.elapsedRealtime() < deadline) {
                    assertEquals(OuraLiveSource.AdoptPhase.Streaming, source.adoptPhase.value)
                    SystemClock.sleep(maxOf(1L, minOf(1_000L, deadline - SystemClock.elapsedRealtime())))
                }
                val finishedAt = SystemClock.elapsedRealtime()
                assertTrue("No plausible HR samples during sustained run", hrCount.get() > startingHrCount)
                assertTrue("No plausible R-R samples during sustained run", rrCount.get() > startingRrCount)
                assertTrue("HR stream was stale at the end of sustained run", finishedAt - lastHrAt.get() < 120_000)
                assertTrue("R-R stream was stale at the end of sustained run", finishedAt - lastRrAt.get() < 120_000)
                safeLog(
                    "Oura: sustained qualification passed " +
                        "(durationMs=${finishedAt - startedAt} " +
                        "hrCallbacks=${hrCount.get()} rrCallbacks=${rrCount.get()})",
                )
            }
        } finally {
            source.stop()
        }
    }

    /**
     * Destructive, explicit-consent-only adoption of a factory-reset Ring 4. The separate runner argument
     * is a second safety gate so an ordinary connected-test invocation cannot install a key by accident.
     */
    @SuppressLint("MissingPermission")
    @Test
    fun adoptsFactoryResetRing4AfterExplicitConsent() {
        assertEquals(
            "true",
            InstrumentationRegistry.getArguments().getString("ouraAdoptConfirmed"),
        )

        val context = ApplicationProvider.getApplicationContext<Context>()
        val deviceId = "hardware-qualification-ring4"
        OuraInstallKeyStore.clear(context, deviceId)

        val source = OuraLiveSource(
            context = context,
            deviceId = deviceId,
            ringGen = OuraRingGen.GEN4,
            liveSink = { _, _ -> },
            authKey = { OuraInstallKeyStore.load(context, deviceId) },
            persist = { _, _ -> },
            log = ::safeLog,
        )

        try {
            source.setAdoptIntent(true)
            source.scan()
            val ring = waitUntil(45_000) { source.discovered.value.firstOrNull() }
            assertNotNull("No reset Oura Ring 4 advertisement appeared", ring)
            source.connect(requireNotNull(ring).address)

            val phase = waitUntil(120_000) {
                source.adoptPhase.value.takeIf {
                    it == OuraLiveSource.AdoptPhase.Streaming || it == OuraLiveSource.AdoptPhase.Failed
                }
            }
            assertEquals(OuraLiveSource.AdoptPhase.Streaming, phase)
            assertTrue("The acknowledged install key was not stored", OuraInstallKeyStore.hasKey(context, deviceId))
        } finally {
            source.stop()
        }
    }

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
                val safe = safeLog(line)
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

    private fun safeLog(line: String): String {
        val safe = line.replace(MAC_ADDRESS, "XX:XX:XX:XX:XX:XX")
        Log.i(LOG_TAG, safe)
        return safe
    }

    private fun <T> waitUntil(timeoutMs: Long, block: () -> T?): T? {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            block()?.let { return it }
            SystemClock.sleep(100)
        }
        return block()
    }

    private companion object {
        const val LOG_TAG = "OuraQualification"
        val MAC_ADDRESS = Regex("(?i)(?:[0-9a-f]{2}:){5}[0-9a-f]{2}")
    }
}
