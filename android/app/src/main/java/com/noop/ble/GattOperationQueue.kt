package com.noop.ble

import java.util.ArrayDeque

internal enum class GattOperationFailureAction { RECONNECT, SKIP_OPTIONAL }

internal enum class PrimarySubscriptionSetupOutcome { READY, RETRY, UNSUPPORTED }
internal enum class SingleSubscriptionSetupOutcome { READY, RETRY, UNAVAILABLE }
internal enum class GattCccdWriteKind { NOTIFY, INDICATE, UNSUPPORTED }

/** ATT/GATT status codes defined for authentication, authorization, and encryption refusal. */
internal fun isGattAuthenticationFailure(status: Int): Boolean = status in setOf(0x05, 0x08, 0x0c, 0x0f)

/** Bluetooth characteristic-property bits are fixed by the GATT specification. */
internal fun gattCccdWriteKind(properties: Int): GattCccdWriteKind = when {
    properties and 0x10 != 0 -> GattCccdWriteKind.NOTIFY
    properties and 0x20 != 0 -> GattCccdWriteKind.INDICATE
    else -> GattCccdWriteKind.UNSUPPORTED
}

/** Required single-stream policy used by Huami's preferred-standard / fallback-custom HR lane. */
internal fun singleSubscriptionSetupOutcome(
    candidateFound: Boolean,
    enabled: Boolean,
    transportFailure: Boolean,
): SingleSubscriptionSetupOutcome = when {
    enabled -> SingleSubscriptionSetupOutcome.READY
    transportFailure -> SingleSubscriptionSetupOutcome.RETRY
    !candidateFound -> SingleSubscriptionSetupOutcome.UNAVAILABLE
    else -> SingleSubscriptionSetupOutcome.UNAVAILABLE
}

/** Any-of subscription policy used by FTMS devices, which can expose more than one machine stream. */
internal fun primarySubscriptionSetupOutcome(
    candidateCount: Int,
    enabledCount: Int,
): PrimarySubscriptionSetupOutcome = when {
    candidateCount <= 0 -> PrimarySubscriptionSetupOutcome.UNSUPPORTED
    enabledCount > 0 -> PrimarySubscriptionSetupOutcome.READY
    else -> PrimarySubscriptionSetupOutcome.RETRY
}

/** Required primary-stream failures recover the link; optional telemetry must not take it down. */
internal fun gattOperationFailureAction(requiredForPrimaryStream: Boolean): GattOperationFailureAction =
    if (requiredForPrimaryStream) GattOperationFailureAction.RECONNECT
    else GattOperationFailureAction.SKIP_OPTIONAL

/**
 * Pure one-at-a-time queue for Android BLE GATT operations.
 *
 * Android permits only one asynchronous GATT operation at a time. A characteristic read or descriptor
 * write must receive its callback before the next operation starts. This small state machine deliberately
 * has no android.bluetooth dependency so its ordering, rejection retries, stale-callback handling, and
 * teardown behaviour can be covered by ordinary JVM tests.
 */
internal class GattOperationQueue<T>(
    private val maxStartRetries: Int,
) {
    init {
        require(maxStartRetries >= 0) { "maxStartRetries must be non-negative" }
    }

    private data class Entry<T>(
        val operation: T,
        var rejectedStarts: Int = 0,
    )

    data class StartRejection<T>(
        val operation: T,
        /** One for the first rejected start, two for the second, and so on. */
        val rejectionNumber: Int,
        /** True when the same operation was restored to the front of the queue for another attempt. */
        val willRetry: Boolean,
    )

    private val pending = ArrayDeque<Entry<T>>()
    private var active: Entry<T>? = null

    val current: T? get() = synchronized(this) { active?.operation }
    val pendingCount: Int get() = synchronized(this) { pending.size }
    val isIdle: Boolean get() = synchronized(this) { active == null && pending.isEmpty() }

    @Synchronized
    fun enqueue(operation: T) {
        pending.addLast(Entry(operation))
    }

    /** Claim the next operation, or null when another operation is active / nothing is pending. */
    @Synchronized
    fun beginNext(): T? {
        if (active != null) return null
        val next = pending.pollFirst() ?: return null
        active = next
        return next.operation
    }

    /**
     * Return the active operation to the front after Android rejected the start request. Once the retry
     * budget is exhausted it is dropped so an optional read cannot permanently block later subscriptions.
     */
    @Synchronized
    fun rejectCurrentStart(): StartRejection<T>? {
        val entry = active ?: return null
        active = null
        entry.rejectedStarts += 1
        val willRetry = entry.rejectedStarts <= maxStartRetries
        if (willRetry) pending.addFirst(entry)
        return StartRejection(entry.operation, entry.rejectedStarts, willRetry)
    }

    /** Complete only the callback-matching operation; a late/stale callback cannot advance the queue. */
    @Synchronized
    fun completeIf(matches: (T) -> Boolean): T? {
        val entry = active ?: return null
        if (!matches(entry.operation)) return null
        active = null
        return entry.operation
    }

    /** Remove and return the active operation when its platform callback never arrives. */
    @Synchronized
    fun timeoutCurrent(): T? {
        val entry = active ?: return null
        active = null
        return entry.operation
    }

    @Synchronized
    fun clear() {
        active = null
        pending.clear()
    }
}
