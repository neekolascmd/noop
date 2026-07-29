package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RawSensorExportTest {

    @Test
    fun contractCarriesDeviceProvenanceInSharedColumnOrder() {
        assertEquals(
            "unix_s,iso_utc,device_id,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z,step_counter," +
                "ppg_bpm,ppg_conf,spo2_red,spo2_ir,skintemp_raw,resp_raw,band_sleep_state,event_kind,event_payload",
            RawSensorExport.HEADER,
        )

        val line = RawSensorExport.line(
            deviceId = "oura-ring",
            stream = "event",
            ts = 1_750_000_000,
            13 to "OURA_SLEEP_PHASE_SERIES",
            14 to WhoopCsvExporter.csvField("""{"phase_codes":[0,1,2,3]}"""),
        )

        assertTrue(line.startsWith("1750000000,2025-06-15T15:06:40Z,oura-ring,event,"))
        assertTrue(line.contains("OURA_SLEEP_PHASE_SERIES"))
        assertTrue(line.contains("phase_codes"))
    }

    @Test
    fun deviceIdUsesRfc4180Escaping() {
        val line = RawSensorExport.line(
            deviceId = "oura,\"lab\"",
            stream = "hr",
            ts = 1_750_000_000,
            0 to "60",
        )

        assertTrue(line.startsWith("1750000000,2025-06-15T15:06:40Z,\"oura,\"\"lab\"\"\",hr,60,"))
    }
}
