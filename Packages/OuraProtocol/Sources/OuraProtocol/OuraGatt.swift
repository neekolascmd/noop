import Foundation

// OuraGatt: the GATT layout facts for the Oura ring, as plain UUID strings + MTU values.
// Platform-pure: this module NEVER imports CoreBluetooth or android.bluetooth, so the app layer
// is responsible for turning these strings into CBUUID / ParcelUuid. Keeping CBUUID out of here
// lets the protocol code run headless on any platform (CLI tools, JVM, XCTest) unchanged.
//
// All facts cited tersely per docs/OURA_PROTOCOL.md s1 (GATT Layout). The RE repos were read for
// protocol facts ONLY; no RE source was copied.

public enum OuraGatt {
    // Base service shared by all generations (gen3/4/5). Per OURA_PROTOCOL.md s1.1.
    public static let serviceUUID = "98ED0001-A541-11E4-B6A0-0002A5D5C51B"

    // Write characteristic (phone to ring), Write Without Response. Per OURA_PROTOCOL.md s1.1.
    public static let writeCharacteristicUUID = "98ED0002-A541-11E4-B6A0-0002A5D5C51B"

    // Notify characteristic (ring to phone), Handle-Value-Notification. Per OURA_PROTOCOL.md s1.1.
    public static let notifyCharacteristicUUID = "98ED0003-A541-11E4-B6A0-0002A5D5C51B"

    // Gen-4/5 extra characteristics. Their presence + properties are hardware-verified on Ring 4;
    // functional roles remain UNCONFIRMED, so leave them UNUSED in v1 and never write to them.
    public static let extraCharacteristic4UUID = "98ED0004-A541-11E4-B6A0-0002A5D5C51B"
    public static let extraCharacteristic5UUID = "98ED0005-A541-11E4-B6A0-0002A5D5C51B"
    public static let extraCharacteristic6UUID = "98ED0006-A541-11E4-B6A0-0002A5D5C51B"

    // MTU values per generation. Gen3 = 203, Gen4/5 = 247 (max payload = MTU - 3 ATT bytes).
    // Per OURA_PROTOCOL.md s1.2 / s1.3.
    public static let mtuGen3 = 203
    public static let mtuGen45 = 247

    // The ATT overhead subtracted from MTU to get the max writable payload. Per OURA_PROTOCOL.md s1.3.
    public static let attOverhead = 3

    /// The set of characteristic UUID strings the app must discover for a given generation.
    /// Gen3 exposes only ...0002/...0003 beyond the service; Gen4/5 additionally advertise
    /// ...0004/5/6 (which v1 discovers but never writes to). Per OURA_PROTOCOL.md s1.2.
    public static func characteristicUUIDs(for gen: OuraRingGen) -> [String] {
        switch gen {
        case .gen3:
            return [writeCharacteristicUUID, notifyCharacteristicUUID]
        case .gen4, .gen5:
            return [writeCharacteristicUUID, notifyCharacteristicUUID,
                    extraCharacteristic4UUID, extraCharacteristic5UUID, extraCharacteristic6UUID]
        }
    }
}
