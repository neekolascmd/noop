/// Pure reconnect policy shared by the isolated, non-WHOOP BLE sources.
///
/// A source may retry only while it still owns an explicit device target and its teardown was not
/// intentional. The delay follows the same capped exponential curve as the WHOOP and Oura clients:
/// 3, 6, 12, 24, 48, then 60 seconds. Keeping this policy free of CoreBluetooth makes the two safety
/// gates and the full schedule testable without a radio.
public enum PeripheralReconnectPolicy {
    public static func shouldReconnect(intentionalDisconnect: Bool, hasTarget: Bool) -> Bool {
        !intentionalDisconnect && hasTarget
    }

    /// Delay before the `attempt`-th reconnect. Attempts are 1-based; zero/negative values coerce to 1.
    public static func delaySeconds(attempt: Int) -> Double {
        let n = max(1, attempt)
        if n >= 6 { return 60 }
        return Double(3 * (1 << (n - 1)))
    }
}
