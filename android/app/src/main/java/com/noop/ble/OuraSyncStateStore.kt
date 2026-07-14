package com.noop.ble

import android.content.Context
import android.content.SharedPreferences
import com.noop.oura.OuraDriver
import com.noop.oura.OuraTimeAnchor
import org.json.JSONObject

/**
 * One coherent, per-ring history resume point. The primary 0x42 anchor and cursor are serialized in the
 * same value so a process death can never expose a new cursor with an old/missing time mapping.
 */
data class OuraSyncState(
    val cursor: Long = 0L,
    val primaryAnchor: OuraTimeAnchor? = null,
    val savedAtMilliseconds: Long = 0L,
)

/** Small backend seam: production uses one SharedPreferences commit; local JVM tests use an in-memory map. */
internal interface OuraSyncStateBackend {
    fun string(key: String): String?
    fun long(key: String): Long?
    fun commit(values: Map<String, Any?>): Boolean
}

private class SharedPreferencesOuraSyncStateBackend(
    private val preferences: SharedPreferences,
) : OuraSyncStateBackend {
    override fun string(key: String): String? =
        runCatching { preferences.getString(key, null) }.getOrNull()

    override fun long(key: String): Long? =
        runCatching { if (preferences.contains(key)) preferences.getLong(key, 0L) else null }.getOrNull()

    override fun commit(values: Map<String, Any?>): Boolean = runCatching {
        val editor = preferences.edit()
        for ((key, value) in values) when (value) {
            null -> editor.remove(key)
            is String -> editor.putString(key, value)
            is Long -> editor.putLong(key, value)
            else -> error("unsupported Oura sync-state value")
        }
        // The ring must not be ACKed until the coherent cursor+anchor value is durably handed to prefs.
        editor.commit()
    }.getOrDefault(false)
}

/** Strict versioned JSON codec. Corrupt/partial state is absent state; no timestamp is fabricated. */
internal object OuraSyncStateCodec {
    private const val FORMAT_VERSION = 1
    private const val MIN_REASONABLE_MS = 1_577_836_800_000L // 2020-01-01
    private const val MAX_REASONABLE_MS = 2_051_222_400_000L // 2035-01-01
    private const val FUTURE_SKEW_MS = 24L * 60L * 60L * 1_000L
    private const val MAX_RING_TIMESTAMP = 0xFFFF_FFFFL

    fun encode(state: OuraSyncState): String = JSONObject().apply {
        put("version", FORMAT_VERSION)
        put("cursor", state.cursor)
        put("savedAtMilliseconds", state.savedAtMilliseconds)
        state.primaryAnchor?.let { anchor ->
            put("primaryAnchor", JSONObject().apply {
                put("ringTimestamp", anchor.ringTimestamp)
                put("utcMilliseconds", anchor.utcMilliseconds)
                put("factorMillisecondsPerTick", anchor.factorMillisecondsPerTick)
            })
        }
    }.toString()

    fun decode(raw: String, nowMilliseconds: Long): OuraSyncState? = runCatching {
        val json = JSONObject(raw)
        if (json.getInt("version") != FORMAT_VERSION) return null
        val cursor = json.getLong("cursor")
        if (cursor !in 0L..MAX_RING_TIMESTAMP) return null
        val savedAt = json.getLong("savedAtMilliseconds")
        val anchorCandidate = if (json.has("primaryAnchor") && !json.isNull("primaryAnchor")) {
            val a = json.getJSONObject("primaryAnchor")
            val candidate = OuraTimeAnchor(
                ringTimestamp = a.getLong("ringTimestamp"),
                utcMilliseconds = a.getLong("utcMilliseconds"),
                factorMillisecondsPerTick = a.getLong("factorMillisecondsPerTick"),
            )
            OuraDriver.validateTimeAnchor(candidate) ?: return null
        } else {
            null
        }
        // A dubious device clock must not erase a valid opaque cursor. It only disqualifies the UTC mapping.
        val anchor = anchorCandidate.takeIf { reasonableSavedAt(savedAt, nowMilliseconds) }
        OuraSyncState(cursor = cursor, primaryAnchor = anchor, savedAtMilliseconds = savedAt)
    }.getOrNull()

    fun reasonableSavedAt(savedAt: Long, nowMilliseconds: Long): Boolean {
        if (nowMilliseconds < MIN_REASONABLE_MS) return false
        val latest = minOf(MAX_REASONABLE_MS, nowMilliseconds + FUTURE_SKEW_MS)
        return savedAt in MIN_REASONABLE_MS..latest
    }
}

/**
 * Per-device synchronous persistence for [OuraSyncState]. Legacy scalar cursors migrate once into a
 * versioned state with a null anchor; migration never invents a ring-time -> UTC mapping.
 */
object OuraSyncStateStore {
    private const val FILE_NAME = "noop_oura_history_cursor"
    private const val STATE_KEY_PREFIX = "sync_state_v1_"
    private const val LEGACY_CURSOR_KEY_PREFIX = "history_cursor_"
    private const val MAX_RING_TIMESTAMP = 0xFFFF_FFFFL

    private fun backend(context: Context): OuraSyncStateBackend = SharedPreferencesOuraSyncStateBackend(
        context.applicationContext.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE),
    )

    internal fun stateKey(deviceId: String): String = "$STATE_KEY_PREFIX$deviceId"
    internal fun legacyCursorKey(deviceId: String): String = "$LEGACY_CURSOR_KEY_PREFIX$deviceId"

    fun read(context: Context, deviceId: String): OuraSyncState =
        read(backend(context), deviceId, System.currentTimeMillis())

    internal fun read(
        backend: OuraSyncStateBackend,
        deviceId: String,
        nowMilliseconds: Long,
    ): OuraSyncState {
        backend.string(stateKey(deviceId))?.let { raw ->
            return OuraSyncStateCodec.decode(raw, nowMilliseconds) ?: OuraSyncState()
        }

        val legacy = backend.long(legacyCursorKey(deviceId)) ?: return OuraSyncState()
        val migrated = OuraSyncState(
            cursor = legacy.coerceIn(0L, MAX_RING_TIMESTAMP),
            primaryAnchor = null,
            savedAtMilliseconds = nowMilliseconds,
        )
        // One synchronous editor commit both creates the coherent value and removes the legacy scalar.
        backend.commit(
            mapOf(
                stateKey(deviceId) to OuraSyncStateCodec.encode(migrated),
                legacyCursorKey(deviceId) to null,
            ),
        )
        return migrated
    }

    /** Save cursor + primary anchor as one value. Returns false rather than weakening validation. */
    fun save(context: Context, deviceId: String, state: OuraSyncState): Boolean =
        save(backend(context), deviceId, state, System.currentTimeMillis())

    internal fun save(
        backend: OuraSyncStateBackend,
        deviceId: String,
        state: OuraSyncState,
        nowMilliseconds: Long,
    ): Boolean {
        if (state.cursor !in 0L..MAX_RING_TIMESTAMP) return false
        if (state.primaryAnchor != null && OuraDriver.validateTimeAnchor(state.primaryAnchor) == null) return false
        if (!OuraSyncStateCodec.reasonableSavedAt(nowMilliseconds, nowMilliseconds)) return false
        val stamped = state.copy(savedAtMilliseconds = nowMilliseconds)
        return backend.commit(
            mapOf(
                stateKey(deviceId) to OuraSyncStateCodec.encode(stamped),
                legacyCursorKey(deviceId) to null,
            ),
        )
    }

    /** Clear cursor and anchor coherently after a proven reset/regression. */
    fun clear(context: Context, deviceId: String): Boolean =
        save(context, deviceId, OuraSyncState())
}
