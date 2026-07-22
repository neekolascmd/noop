package com.noop.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.os.Build
import java.util.UUID

/** A queued Android GATT setup request shared by standard HR, FTMS, and Huami device sources. */
internal sealed interface AndroidGattSetupOperation {
    val characteristic: BluetoothGattCharacteristic
    val label: String
    /** True when failure means the source cannot produce its primary live stream. */
    val requiredForPrimaryStream: Boolean

    data class EnableNotifications(
        override val characteristic: BluetoothGattCharacteristic,
        override val label: String,
        override val requiredForPrimaryStream: Boolean,
    ) : AndroidGattSetupOperation

    data class Read(
        override val characteristic: BluetoothGattCharacteristic,
        override val label: String,
        override val requiredForPrimaryStream: Boolean = false,
    ) : AndroidGattSetupOperation
}

internal val GATT_CLIENT_CHARACTERISTIC_CONFIG_UUID: UUID =
    UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

/** Start one already-claimed operation. Completion still arrives through the corresponding callback. */
@SuppressLint("MissingPermission")
internal fun startAndroidGattSetupOperation(
    gatt: BluetoothGatt,
    operation: AndroidGattSetupOperation,
): Boolean {
    return when (operation) {
        is AndroidGattSetupOperation.EnableNotifications -> {
            val characteristic = operation.characteristic
            if (!gatt.setCharacteristicNotification(characteristic, true)) {
                false
            } else {
                val cccd = characteristic.getDescriptor(GATT_CLIENT_CHARACTERISTIC_CONFIG_UUID)
                    ?: return false
                val enableValue = when (gattCccdWriteKind(characteristic.properties)) {
                    GattCccdWriteKind.NOTIFY ->
                        BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    GattCccdWriteKind.INDICATE ->
                        BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                    GattCccdWriteKind.UNSUPPORTED -> return false
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeDescriptor(cccd, enableValue) ==
                        BluetoothGatt.GATT_SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    run {
                        cccd.value = enableValue
                        gatt.writeDescriptor(cccd)
                    }
                }
            }
        }
        is AndroidGattSetupOperation.Read -> gatt.readCharacteristic(operation.characteristic)
    }
}
