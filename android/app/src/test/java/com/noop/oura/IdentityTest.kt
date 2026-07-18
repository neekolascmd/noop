package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class IdentityTest {
    @Test
    fun firmwareIdentityDecodesVersionTripletsAndDropsAddress() {
        val body = intArrayOf(
            0x02, 0x01, 0x00, 0x02, 0x01, 0x03,
            0x01, 0x00, 0x01, 0x09, 0x03, 0x29,
            0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
        )
        val identity = OuraDecoders.decodeFirmwareIdentity(body)
        assertEquals("2.1.0", identity?.api.toString())
        assertEquals("2.1.3", identity?.firmware.toString())
        assertEquals("1.0.1", identity?.bootloader.toString())
        assertEquals("9.3.41", identity?.bluetooth.toString())
    }

    @Test
    fun firmwareIdentityRejectsShortBody() {
        assertNull(OuraDecoders.decodeFirmwareIdentity(IntArray(11)))
    }

    @Test
    fun productHardwareExtractsDelimitedFamilyToken() {
        val body = "\u0000\u0000BLB_03\u0000".map { it.code }.toIntArray()
        assertEquals("BLB_03", OuraDecoders.decodeProductHardware(body))
    }

    @Test
    fun productHardwareNeverReturnsUndelimitedSerialLikeText() {
        val body = "ABC123456789\u0000".map { it.code }.toIntArray()
        assertNull(OuraDecoders.decodeProductHardware(body))
    }
}
