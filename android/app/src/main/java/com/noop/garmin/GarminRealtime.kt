package com.noop.garmin

object GarminEpoch {
    /** FIT/Garmin epoch: 1989-12-31 00:00:00 UTC. */
    const val UNIX_OFFSET_SECONDS: Long = 631_065_600L
    fun unixSeconds(garminSeconds: Long): Long = UNIX_OFFSET_SECONDS + garminSeconds
    fun garminSeconds(unixSeconds: Long): Long? =
        (unixSeconds - UNIX_OFFSET_SECONDS).takeIf { it in 0..0xffff_ffffL }
}

sealed interface GarminRealtimeValue {
    val raw: ByteArray

    data class HeartRate(
        override val raw: ByteArray,
        val type: Int,
        val rawHeartRate: Int,
        val heartRateBpm: Int?,
        val restingHeartRate: Int,
    ) : GarminRealtimeValue

    data class Steps(override val raw: ByteArray, val steps: Int, val goal: Int) : GarminRealtimeValue

    data class Hrv(
        override val raw: ByteArray,
        val rawRrMilliseconds: Int,
        val rrMilliseconds: Int?,
        val unknown: Int,
    ) : GarminRealtimeValue

    data class Spo2(
        override val raw: ByteArray,
        val rawValue: Int,
        val percent: Int?,
        val garminTimestamp: Long,
        val unixSeconds: Long,
    ) : GarminRealtimeValue

    data class Respiration(
        override val raw: ByteArray,
        val rawValue: Int,
        val breathsPerMinute: Int?,
    ) : GarminRealtimeValue

    data class Opaque(
        val service: GarminMultiLinkService,
        override val raw: ByteArray,
    ) : GarminRealtimeValue
}

object GarminRealtimeDecoder {
    fun decode(service: GarminMultiLinkService, payload: ByteArray): GarminRealtimeValue? {
        return when (service) {
        GarminMultiLinkService.REALTIME_HEART_RATE -> {
            if (payload.size != 3 &&
                !(payload.size == 5 && payload[3] == 0xff.toByte() && payload[4] == 0xff.toByte())
            ) return null
            val rawHr = payload[1].toInt() and 0xff
            GarminRealtimeValue.HeartRate(
                raw = payload.copyOf(),
                type = payload[0].toInt() and 0xff,
                rawHeartRate = rawHr,
                heartRateBpm = rawHr.takeIf { it > 0 },
                restingHeartRate = payload[2].toInt() and 0xff,
            )
        }
        GarminMultiLinkService.REALTIME_STEPS -> {
            if (payload.size != 8) return null
            val steps = i32(payload, 0)
            val goal = i32(payload, 4)
            if (steps < 0 || goal < 0) return null
            GarminRealtimeValue.Steps(payload.copyOf(), steps, goal)
        }
        GarminMultiLinkService.REALTIME_HRV -> {
            if (payload.size != 6) return null
            val rawRr = i16(payload, 0)
            GarminRealtimeValue.Hrv(
                raw = payload.copyOf(),
                rawRrMilliseconds = rawRr,
                rrMilliseconds = rawRr.takeIf { it in 200..3_000 },
                unknown = i32(payload, 2),
            )
        }
        GarminMultiLinkService.REALTIME_SPO2 -> {
            if (payload.size != 5) return null
            val raw = payload[0].toInt()
            val timestamp = u32(payload, 1)
            GarminRealtimeValue.Spo2(
                raw = payload.copyOf(),
                rawValue = raw,
                percent = raw.takeIf { it in 1..100 },
                garminTimestamp = timestamp,
                unixSeconds = GarminEpoch.unixSeconds(timestamp),
            )
        }
        GarminMultiLinkService.REALTIME_RESPIRATION -> {
            if (payload.size != 1) return null
            val raw = payload[0].toInt()
            GarminRealtimeValue.Respiration(
                raw = payload.copyOf(),
                rawValue = raw,
                breathsPerMinute = raw.takeIf { it in 1..120 },
            )
        }
        GarminMultiLinkService.REALTIME_ACCELEROMETER,
        GarminMultiLinkService.REALTIME_BODY_BATTERY ->
            payload.takeIf { it.isNotEmpty() }?.let {
                GarminRealtimeValue.Opaque(service, it.copyOf())
            }
            GarminMultiLinkService.GFDI -> null
        }
    }

    private fun i16(bytes: ByteArray, offset: Int): Int =
        (((bytes[offset].toInt() and 0xff) or ((bytes[offset + 1].toInt() and 0xff) shl 8)).toShort()).toInt()

    private fun i32(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xff) or
            ((bytes[offset + 1].toInt() and 0xff) shl 8) or
            ((bytes[offset + 2].toInt() and 0xff) shl 16) or
            ((bytes[offset + 3].toInt() and 0xff) shl 24)

    private fun u32(bytes: ByteArray, offset: Int): Long = i32(bytes, offset).toLong() and 0xffff_ffffL
}
