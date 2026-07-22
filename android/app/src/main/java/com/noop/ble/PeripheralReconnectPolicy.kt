package com.noop.ble

/** Pure reconnect gate + schedule for isolated non-WHOOP BLE sources. */
internal object PeripheralReconnectPolicy {
    /** An explicit stop or missing remembered target must make every deferred callback inert. */
    fun shouldReconnect(intentionalDisconnect: Boolean, hasTarget: Boolean): Boolean =
        !intentionalDisconnect && hasTarget

    /** Same capped 3, 6, 12, 24, 48, 60-second curve used by WHOOP and Oura. */
    fun delayMs(attempt: Int): Long = ReconnectBackoff.nextDelayMs(attempt)
}
