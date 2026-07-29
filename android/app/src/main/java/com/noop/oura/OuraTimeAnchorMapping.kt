package com.noop.oura

/**
 * Overflow-safe conversion between Oura's ring clock and UTC.
 *
 * [OuraTimeSync.epochMs] keeps its historical API name, but the verified Gen 3 and Ring 4 wire
 * layouts both carry unix seconds. Live ingestion and offline raw-archive replay share this helper
 * so neither path can silently invent a different timestamp contract.
 */
object OuraTimeAnchorMapping {
    const val MINIMUM_PLAUSIBLE_EPOCH_SECONDS = 1_577_836_800L
    const val MAXIMUM_PLAUSIBLE_EPOCH_SECONDS = 2_051_222_400L

    fun anchor(sync: OuraTimeSync): OuraTimeAnchor? = anchor(
        ringTimestamp = sync.ringTimestamp,
        unixSeconds = sync.epochMs,
        factorMillisecondsPerTick = sync.factorMsPerTick.toLong(),
    )

    fun anchor(beacon: OuraRtcBeacon): OuraTimeAnchor? = anchor(
        ringTimestamp = beacon.ringTimestamp,
        unixSeconds = beacon.unixSeconds,
        factorMillisecondsPerTick = 100L,
    )

    /** Resolve a ring timestamp without unchecked multiply/add arithmetic or implausible UTC output. */
    fun unixSeconds(ringTimestamp: Long, anchor: OuraTimeAnchor): Long? {
        if (ringTimestamp !in 0L..0xFFFF_FFFFL || !isValid(anchor)) return null
        return try {
            val deltaTicks = Math.subtractExact(ringTimestamp, anchor.ringTimestamp)
            val offsetMs = Math.multiplyExact(deltaTicks, anchor.factorMillisecondsPerTick)
            val utcMs = Math.addExact(anchor.utcMilliseconds, offsetMs)
            (utcMs / 1_000L).takeIf(::isPlausible)
        } catch (_: ArithmeticException) {
            null
        }
    }

    fun isValid(anchor: OuraTimeAnchor): Boolean =
        anchor.ringTimestamp in 1L..0xFFFF_FFFFL &&
            anchor.factorMillisecondsPerTick in setOf(1L, 100L) &&
            isPlausible(anchor.utcMilliseconds / 1_000L)

    fun isPlausible(unixSeconds: Long): Boolean =
        unixSeconds in MINIMUM_PLAUSIBLE_EPOCH_SECONDS..MAXIMUM_PLAUSIBLE_EPOCH_SECONDS

    private fun anchor(
        ringTimestamp: Long,
        unixSeconds: Long,
        factorMillisecondsPerTick: Long,
    ): OuraTimeAnchor? {
        if (ringTimestamp !in 1L..0xFFFF_FFFFL ||
            factorMillisecondsPerTick !in setOf(1L, 100L) ||
            !isPlausible(unixSeconds)
        ) {
            return null
        }
        return try {
            OuraTimeAnchor(
                ringTimestamp = ringTimestamp,
                utcMilliseconds = Math.multiplyExact(unixSeconds, 1_000L),
                factorMillisecondsPerTick = factorMillisecondsPerTick,
            )
        } catch (_: ArithmeticException) {
            null
        }
    }
}
