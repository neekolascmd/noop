package com.noop.polar

import kotlin.math.round

/**
 * Dependency-free Polar Measurement Data (PMD) wire implementation.
 *
 * This is the Kotlin twin of `WhoopProtocol/PolarPMD*.swift`. It independently implements the
 * public protocol behavior documented by Polar's official BLE SDK; NOOP does not bundle that SDK.
 *
 * Reference: https://github.com/polarofficial/polar-ble-sdk/tree/ccff6812c40fff1753c72385387d1877ca9b27b4/sources
 */
object PolarPmdGatt {
    const val SERVICE = "FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8"
    const val CONTROL_POINT = "FB005C81-02E7-F387-1CAD-8ACD2D8DF0C8"
    const val DATA = "FB005C82-02E7-F387-1CAD-8ACD2D8DF0C8"
}

enum class PolarPmdMeasurement(val wire: Int) {
    ECG(0),
    PPG(1),
    ACCELEROMETER(2),
    PPI(3),
    GYROSCOPE(5),
    MAGNETOMETER(6),
    SKIN_TEMPERATURE(7),
    SDK_MODE(9),
    LOCATION(10),
    PRESSURE(11),
    TEMPERATURE(12),
    OFFLINE_RECORDING(13),
    OFFLINE_HEART_RATE(14),
    DERIVED(15);

    companion object {
        fun fromWire(value: Int): PolarPmdMeasurement? =
            entries.firstOrNull { it.wire == (value and 0x3F) }
    }
}

data class PolarPmdFeatures(
    val rawBits: Int,
    val measurements: Set<PolarPmdMeasurement>,
) {
    fun supports(measurement: PolarPmdMeasurement): Boolean = measurement in measurements

    companion object {
        const val RESPONSE_MARKER = 0x0F

        fun parse(bytes: ByteArray): PolarPmdFeatures? {
            if (bytes.size < 3 || bytes[0].u8() != RESPONSE_MARKER) return null
            val raw = bytes[1].u8() or (bytes[2].u8() shl 8)
            val map = listOf(
                0 to PolarPmdMeasurement.ECG,
                1 to PolarPmdMeasurement.PPG,
                2 to PolarPmdMeasurement.ACCELEROMETER,
                3 to PolarPmdMeasurement.PPI,
                5 to PolarPmdMeasurement.GYROSCOPE,
                6 to PolarPmdMeasurement.MAGNETOMETER,
                7 to PolarPmdMeasurement.SKIN_TEMPERATURE,
                9 to PolarPmdMeasurement.SDK_MODE,
                10 to PolarPmdMeasurement.LOCATION,
                11 to PolarPmdMeasurement.PRESSURE,
                12 to PolarPmdMeasurement.TEMPERATURE,
                13 to PolarPmdMeasurement.OFFLINE_RECORDING,
                14 to PolarPmdMeasurement.OFFLINE_HEART_RATE,
            )
            return PolarPmdFeatures(
                rawBits = raw,
                measurements = map.filterTo(mutableSetOf()) { (bit, _) ->
                    raw and (1 shl bit) != 0
                }.mapTo(mutableSetOf()) { it.second },
            )
        }
    }
}

enum class PolarPmdSettingType(val wire: Int, val fieldWidth: Int, val responseOnly: Boolean = false) {
    SAMPLE_RATE(0, 2),
    RESOLUTION(1, 2),
    RANGE(2, 2),
    RANGE_MILLIUNIT(3, 4),
    CHANNELS(4, 1),
    FACTOR(5, 4, true),
    SECURITY(6, 16),
    DERIVED_MEASUREMENT_METHOD(7, 1),
    SOURCE_MEASUREMENT_TYPE(8, 1),
    SOURCE_MEASUREMENT_SAMPLE_RATE(9, 2),
    SOURCE_MEASUREMENT_RANGE(10, 4, true),
    DERIVED_MEASUREMENT_TIME_WINDOW(11, 4),
    DERIVED_MEASUREMENT_SETTINGS_GROUP_ID(12, 1);

    companion object {
        fun fromWire(value: Int): PolarPmdSettingType? = entries.firstOrNull { it.wire == value }
    }
}

class PolarPmdException(message: String) : IllegalArgumentException(message)

class PolarPmdSettings private constructor(
    val options: Map<PolarPmdSettingType, List<ByteArray>>,
) {
    fun numericOptions(type: PolarPmdSettingType): List<Long> {
        if (type.fieldWidth > 4) return emptyList()
        return options[type].orEmpty().map { bytes ->
            var value = 0L
            bytes.forEachIndexed { index, byte -> value = value or (byte.u8().toLong() shl (index * 8)) }
            value
        }
    }

    val factor: Double
        get() {
            val bits = numericOptions(PolarPmdSettingType.FACTOR).firstOrNull()?.toInt() ?: return 1.0
            return Float.fromBits(bits).toDouble()
        }

    val maximumSelection: Map<PolarPmdSettingType, Long>
        get() = buildMap {
            for (type in PolarPmdSettingType.entries) {
                if (!type.responseOnly) numericOptions(type).maxOrNull()?.let { put(type, it) }
            }
        }

    companion object {
        fun empty(): PolarPmdSettings = PolarPmdSettings(emptyMap())

        fun parse(parameters: ByteArray): PolarPmdSettings {
            val parsed = linkedMapOf<PolarPmdSettingType, List<ByteArray>>()
            var offset = 0
            while (offset < parameters.size) {
                if (offset + 2 > parameters.size) throw PolarPmdException("truncated settings header")
                val type = PolarPmdSettingType.fromWire(parameters[offset].u8())
                    ?: throw PolarPmdException("unsupported setting type ${parameters[offset].u8()}")
                val count = parameters[offset + 1].u8()
                offset += 2
                if (count > 64) throw PolarPmdException("setting count exceeds limit")
                val byteCount = count.toLong() * type.fieldWidth.toLong()
                if (byteCount > Int.MAX_VALUE || offset + byteCount.toInt() > parameters.size) {
                    throw PolarPmdException("truncated ${type.name} values")
                }
                parsed[type] = List(count) {
                    val value = parameters.copyOfRange(offset, offset + type.fieldWidth)
                    offset += type.fieldWidth
                    value
                }
            }
            return PolarPmdSettings(parsed)
        }

        fun encodeSelection(selected: Map<PolarPmdSettingType, Long>): ByteArray {
            val output = mutableListOf<Byte>()
            for (type in selected.keys.sortedBy { it.wire }) {
                if (type.responseOnly) continue
                if (type.fieldWidth > 4) throw PolarPmdException("unsupported numeric ${type.name}")
                val value = selected.getValue(type)
                val max = if (type.fieldWidth == 4) 0xFFFF_FFFFL else (1L shl (type.fieldWidth * 8)) - 1
                if (value !in 0..max) throw PolarPmdException("${type.name} value exceeds field")
                output += type.wire.toByte()
                // This is a VALUE COUNT, not a byte length.
                output += 1
                repeat(type.fieldWidth) { index -> output += (value ushr (index * 8)).toByte() }
            }
            return output.toByteArray()
        }
    }
}

enum class PolarPmdControlOpcode(val wire: Int) {
    GET_MEASUREMENT_SETTINGS(1),
    START_MEASUREMENT(2),
    STOP_MEASUREMENT(3),
    GET_SDK_MODE_MEASUREMENT_SETTINGS(4),
    GET_MEASUREMENT_STATUS(5),
    GET_SDK_MODE_STATUS(6),
}

object PolarPmdCommand {
    fun querySettings(measurement: PolarPmdMeasurement): ByteArray =
        byteArrayOf(PolarPmdControlOpcode.GET_MEASUREMENT_SETTINGS.wire.toByte(), measurement.wire.toByte())

    fun start(
        measurement: PolarPmdMeasurement,
        selection: Map<PolarPmdSettingType, Long> = emptyMap(),
    ): ByteArray = byteArrayOf(
        PolarPmdControlOpcode.START_MEASUREMENT.wire.toByte(),
        measurement.wire.toByte(),
    ) + PolarPmdSettings.encodeSelection(selection)

    fun stop(measurement: PolarPmdMeasurement): ByteArray =
        byteArrayOf(PolarPmdControlOpcode.STOP_MEASUREMENT.wire.toByte(), measurement.wire.toByte())
}

data class PolarPmdControlResponse(
    val opcode: Int,
    val measurementByte: Int,
    val status: Int,
    val hasMore: Boolean,
    val parameters: ByteArray,
) {
    val measurement: PolarPmdMeasurement? get() = PolarPmdMeasurement.fromWire(measurementByte)
    val succeeded: Boolean get() = status == 0

    companion object {
        const val RESPONSE_MARKER = 0xF0

        fun parse(bytes: ByteArray): PolarPmdControlResponse {
            if (bytes.size < 4) throw PolarPmdException("truncated control response")
            if (bytes[0].u8() != RESPONSE_MARKER) throw PolarPmdException("invalid control marker")
            val status = bytes[3].u8()
            return PolarPmdControlResponse(
                opcode = bytes[1].u8(),
                measurementByte = bytes[2].u8(),
                status = status,
                hasMore = status == 0 && bytes.size >= 5 && bytes[4].u8() != 0,
                parameters = if (status == 0 && bytes.size > 5) bytes.copyOfRange(5, bytes.size) else byteArrayOf(),
            )
        }
    }
}

class PolarPmdControlResponseAssembler(
    private val maximumParameterBytes: Int = 4_096,
) {
    private var partial: PolarPmdControlResponse? = null

    fun reset() {
        partial = null
    }

    /** Returns null while another response part is required. */
    fun append(bytes: ByteArray): PolarPmdControlResponse? {
        val next = PolarPmdControlResponse.parse(bytes)
        val current = partial
        if (current != null) {
            if (current.opcode != next.opcode ||
                current.measurementByte != next.measurementByte ||
                current.status != next.status
            ) {
                partial = null
                throw PolarPmdException("control response parts do not match")
            }
            val combined = current.parameters + next.parameters
            if (combined.size > maximumParameterBytes) {
                partial = null
                throw PolarPmdException("control response exceeds limit")
            }
            val result = current.copy(hasMore = next.hasMore, parameters = combined)
            return if (next.hasMore) {
                partial = result
                null
            } else {
                partial = null
                result
            }
        }
        if (next.parameters.size > maximumParameterBytes) throw PolarPmdException("control response exceeds limit")
        return if (next.hasMore) {
            partial = next
            null
        } else {
            next
        }
    }
}

data class PolarPmdStartedStream(
    val measurement: PolarPmdMeasurement,
    val selection: Map<PolarPmdSettingType, Long>,
    val startResponse: PolarPmdSettings?,
)

data class PolarPmdSessionUpdate(
    val command: ByteArray? = null,
    val started: PolarPmdStartedStream? = null,
    val skipped: PolarPmdMeasurement? = null,
    val finished: Boolean = false,
)

/**
 * Hardware-independent serial PMD control-point planner. One settings query/start pair is in flight
 * at a time; a rejected stream is skipped without blocking later advertised streams.
 */
class PolarPmdSessionPlanner {
    private sealed interface Phase {
        data object Idle : Phase
        data class Querying(val measurement: PolarPmdMeasurement) : Phase
        data class Starting(
            val measurement: PolarPmdMeasurement,
            val selection: Map<PolarPmdSettingType, Long>,
        ) : Phase
        data object Finished : Phase
    }

    private val queue = ArrayDeque<PolarPmdMeasurement>()
    private var phase: Phase = Phase.Idle

    fun reset() {
        queue.clear()
        phase = Phase.Idle
    }

    fun begin(
        features: PolarPmdFeatures,
        requested: List<PolarPmdMeasurement>,
    ): PolarPmdSessionUpdate {
        queue.clear()
        val seen = mutableSetOf<PolarPmdMeasurement>()
        requested.filterTo(queue) { features.supports(it) && seen.add(it) }
        return advance()
    }

    fun handle(response: PolarPmdControlResponse): PolarPmdSessionUpdate {
        return when (val current = phase) {
            Phase.Idle -> PolarPmdSessionUpdate()
            Phase.Finished -> PolarPmdSessionUpdate(finished = true)
            is Phase.Querying -> {
                val measurement = current.measurement
                if (response.opcode != PolarPmdControlOpcode.GET_MEASUREMENT_SETTINGS.wire ||
                    response.measurement != measurement
                ) {
                    reset()
                    PolarPmdSessionUpdate(skipped = measurement, finished = true)
                } else if (!response.succeeded) {
                    advance(skipped = measurement)
                } else {
                    val settings = runCatching { PolarPmdSettings.parse(response.parameters) }.getOrNull()
                    if (settings == null) {
                        advance(skipped = measurement)
                    } else {
                        val selection = settings.maximumSelection
                        phase = Phase.Starting(measurement, selection)
                        val command = runCatching { PolarPmdCommand.start(measurement, selection) }.getOrNull()
                        if (command == null) advance(skipped = measurement)
                        else PolarPmdSessionUpdate(command = command)
                    }
                }
            }
            is Phase.Starting -> {
                val measurement = current.measurement
                if (response.opcode != PolarPmdControlOpcode.START_MEASUREMENT.wire ||
                    response.measurement != measurement
                ) {
                    reset()
                    PolarPmdSessionUpdate(skipped = measurement, finished = true)
                } else if (!response.succeeded) {
                    advance(skipped = measurement)
                } else {
                    val startSettings = if (response.parameters.isEmpty()) {
                        null
                    } else {
                        val parsed = runCatching { PolarPmdSettings.parse(response.parameters) }.getOrNull()
                        if (parsed == null) return advance(skipped = measurement)
                        parsed
                    }
                    advance(
                        started = PolarPmdStartedStream(measurement, current.selection, startSettings),
                    )
                }
            }
        }
    }

    private fun advance(
        started: PolarPmdStartedStream? = null,
        skipped: PolarPmdMeasurement? = null,
    ): PolarPmdSessionUpdate {
        val next = queue.removeFirstOrNull()
        if (next == null) {
            phase = Phase.Finished
            return PolarPmdSessionUpdate(started = started, skipped = skipped, finished = true)
        }
        phase = Phase.Querying(next)
        return PolarPmdSessionUpdate(
            command = PolarPmdCommand.querySettings(next),
            started = started,
            skipped = skipped,
        )
    }
}

data class PolarPmdDataFrame(
    val measurement: PolarPmdMeasurement,
    val sensorTimestampNs: Long,
    val frameType: Int,
    val compressed: Boolean,
    val payload: ByteArray,
) {
    companion object {
        fun parse(bytes: ByteArray): PolarPmdDataFrame {
            if (bytes.size < 10) throw PolarPmdException("truncated data-frame header")
            val measurement = PolarPmdMeasurement.fromWire(bytes[0].u8())
                ?: throw PolarPmdException("unsupported measurement ${bytes[0].u8() and 0x3F}")
            var timestamp = 0L
            for (index in 0 until 8) {
                val value = bytes[index + 1].u8().toLong()
                if (index == 7 && value and 0x80 != 0L) {
                    throw PolarPmdException("timestamp exceeds signed 64-bit range")
                }
                timestamp = timestamp or (value shl (index * 8))
            }
            return PolarPmdDataFrame(
                measurement = measurement,
                sensorTimestampNs = timestamp,
                frameType = bytes[9].u8() and 0x7F,
                compressed = bytes[9].u8() and 0x80 != 0,
                payload = bytes.copyOfRange(10, bytes.size),
            )
        }
    }
}

data class PolarPmdEcgSample(val sensorTimestampNs: Long, val microVolts: Int)
data class PolarPmdPpgSample(val sensorTimestampNs: Long, val channels: List<Int>, val ambient: Int)
data class PolarPmdAccelerationSample(
    val sensorTimestampNs: Long,
    val xMilliG: Int,
    val yMilliG: Int,
    val zMilliG: Int,
)
data class PolarPmdPpiSample(
    val sensorTimestampNs: Long,
    val heartRate: Int,
    val intervalMs: Int,
    val errorEstimateMs: Int,
    val blocker: Boolean,
    val skinContact: Boolean?,
)

data class PolarPmdDecodedFrame(
    val frame: PolarPmdDataFrame,
    val ecg: List<PolarPmdEcgSample> = emptyList(),
    val ppg: List<PolarPmdPpgSample> = emptyList(),
    val acceleration: List<PolarPmdAccelerationSample> = emptyList(),
    val ppi: List<PolarPmdPpiSample> = emptyList(),
)

data class PolarPmdDecodeSettings(val sampleRateHz: Int = 0, val factor: Double = 1.0)

class PolarPmdDecoder {
    private data class StreamKey(val measurement: PolarPmdMeasurement, val frameType: Int)

    private val previousTimestamps = mutableMapOf<StreamKey, Long>()
    private val settings = mutableMapOf<PolarPmdMeasurement, PolarPmdDecodeSettings>()

    fun reset() {
        previousTimestamps.clear()
        settings.clear()
    }

    fun configure(measurement: PolarPmdMeasurement, sampleRateHz: Int, factor: Double = 1.0) {
        settings[measurement] = PolarPmdDecodeSettings(sampleRateHz, factor.takeIf { it.isFinite() } ?: 1.0)
    }

    fun configure(
        measurement: PolarPmdMeasurement,
        selection: Map<PolarPmdSettingType, Long>,
        startResponse: PolarPmdSettings? = null,
    ) {
        configure(
            measurement,
            sampleRateHz = selection[PolarPmdSettingType.SAMPLE_RATE]?.toInt() ?: 0,
            factor = startResponse?.factor ?: 1.0,
        )
    }

    fun decode(bytes: ByteArray): PolarPmdDecodedFrame {
        val frame = PolarPmdDataFrame.parse(bytes)
        val key = StreamKey(frame.measurement, frame.frameType)
        val previous = previousTimestamps[key] ?: 0
        val config = settings[frame.measurement] ?: PolarPmdDecodeSettings()
        val decoded = when (frame.measurement) {
            PolarPmdMeasurement.ECG -> decodeEcg(frame, previous, config.sampleRateHz)
            PolarPmdMeasurement.PPG -> decodePpg(frame, previous, config)
            PolarPmdMeasurement.ACCELEROMETER -> decodeAcceleration(frame, previous, config)
            PolarPmdMeasurement.PPI -> decodePpi(frame)
            else -> throw PolarPmdException("unsupported measurement ${frame.measurement}")
        }
        previousTimestamps[key] = frame.sensorTimestampNs
        return decoded
    }

    private fun decodeEcg(frame: PolarPmdDataFrame, previous: Long, sampleRate: Int): PolarPmdDecodedFrame {
        if (frame.compressed || frame.frameType != 0) throw PolarPmdException("unsupported ECG frame")
        val width = 3
        if (frame.payload.isEmpty() || frame.payload.size % width != 0) {
            throw PolarPmdException("truncated ECG type-0 sample")
        }
        val count = frame.payload.size / width
        val times = timestamps(frame.sensorTimestampNs, previous, count, sampleRate)
        return PolarPmdDecodedFrame(
            frame = frame,
            ecg = List(count) { index ->
                PolarPmdEcgSample(
                    times[index],
                    signedLe(frame.payload, index * width, width, 24),
                )
            },
        )
    }

    private fun decodePpg(
        frame: PolarPmdDataFrame,
        previous: Long,
        config: PolarPmdDecodeSettings,
    ): PolarPmdDecodedFrame {
        if (frame.frameType != 0) throw PolarPmdException("unsupported PPG frame")
        val vectors = if (frame.compressed) {
            deltaSamples(frame.payload, channels = 4, resolution = 24)
        } else {
            val sampleBytes = 12
            if (frame.payload.isEmpty() || frame.payload.size % sampleBytes != 0) {
                throw PolarPmdException("truncated PPG type-0 sample")
            }
            (frame.payload.indices step sampleBytes).map { offset ->
                List(4) { signedLe(frame.payload, offset + it * 3, 3, 24) }
            }
        }
        val times = timestamps(frame.sensorTimestampNs, previous, vectors.size, config.sampleRateHz)
        return PolarPmdDecodedFrame(
            frame = frame,
            ppg = vectors.mapIndexed { index, vector ->
                // Polar applies the start-response factor only to compressed type-0 PPG.
                val scale = if (frame.compressed) config.factor else 1.0
                val scaled = vector.map { (it.toDouble() * scale).toInt() }
                PolarPmdPpgSample(times[index], scaled.take(3), scaled[3])
            },
        )
    }

    private fun decodeAcceleration(
        frame: PolarPmdDataFrame,
        previous: Long,
        config: PolarPmdDecodeSettings,
    ): PolarPmdDecodedFrame {
        val vectors: List<List<Int>>
        val scale: Double
        if (frame.compressed) {
            when (frame.frameType) {
                0 -> {
                    vectors = deltaSamples(frame.payload, channels = 3, resolution = 16)
                    scale = config.factor * 1_000.0
                }
                1 -> {
                    vectors = deltaSamples(frame.payload, channels = 3, resolution = 16)
                    scale = config.factor
                }
                else -> throw PolarPmdException("unsupported compressed ACC frame")
            }
        } else {
            val width = when (frame.frameType) {
                0 -> 1
                1 -> 2
                2 -> 3
                else -> throw PolarPmdException("unsupported raw ACC frame")
            }
            val sampleBytes = width * 3
            if (frame.payload.isEmpty() || frame.payload.size % sampleBytes != 0) {
                throw PolarPmdException("truncated ACC sample")
            }
            vectors = (frame.payload.indices step sampleBytes).map { offset ->
                List(3) { signedLe(frame.payload, offset + it * width, width, width * 8) }
            }
            scale = 1.0
        }
        val times = timestamps(frame.sensorTimestampNs, previous, vectors.size, config.sampleRateHz)
        return PolarPmdDecodedFrame(
            frame = frame,
            acceleration = vectors.mapIndexed { index, vector ->
                PolarPmdAccelerationSample(
                    times[index],
                    (vector[0] * scale).toInt(),
                    (vector[1] * scale).toInt(),
                    (vector[2] * scale).toInt(),
                )
            },
        )
    }

    private fun decodePpi(frame: PolarPmdDataFrame): PolarPmdDecodedFrame {
        if (frame.compressed || frame.frameType != 0) throw PolarPmdException("unsupported PPI frame")
        val width = 6
        if (frame.payload.isEmpty() || frame.payload.size % width != 0) {
            throw PolarPmdException("truncated PPI sample")
        }
        data class Fields(val hr: Int, val interval: Int, val error: Int, val flags: Int)
        val fields = (frame.payload.indices step width).map { offset ->
            Fields(
                frame.payload[offset].u8(),
                frame.payload[offset + 1].u8() or (frame.payload[offset + 2].u8() shl 8),
                frame.payload[offset + 3].u8() or (frame.payload[offset + 4].u8() shl 8),
                frame.payload[offset + 5].u8(),
            )
        }
        val times = LongArray(fields.size)
        var current = frame.sensorTimestampNs
        for (index in fields.indices.reversed()) {
            times[index] = current
            val delta = fields[index].interval.toLong() * 1_000_000L
            current = if (current >= delta) current - delta else 0
        }
        return PolarPmdDecodedFrame(
            frame = frame,
            ppi = fields.mapIndexed { index, value ->
                val supported = value.flags and 0x04 != 0
                PolarPmdPpiSample(
                    sensorTimestampNs = times[index],
                    heartRate = value.hr,
                    intervalMs = value.interval,
                    errorEstimateMs = value.error,
                    blocker = value.flags and 0x01 != 0,
                    skinContact = if (supported) value.flags and 0x02 != 0 else null,
                )
            },
        )
    }

    companion object {
        fun timestamps(end: Long, previous: Long, count: Int, sampleRate: Int): List<Long> {
            if (count !in 1..4_096) throw PolarPmdException("sample count exceeds limit")
            if (count == 1) return listOf(end)
            val delta = if (previous > 0 && end > previous) {
                (end - previous).toDouble() / count.toDouble()
            } else {
                if (sampleRate !in 1..10_000) throw PolarPmdException("missing valid sample rate")
                1_000_000_000.0 / sampleRate.toDouble()
            }
            if (!delta.isFinite() || delta <= 0.0) throw PolarPmdException("invalid timestamp delta")
            val start = if (previous > 0 && end > previous) {
                previous.toDouble() + delta
            } else {
                end.toDouble() - delta * (count - 1).toDouble()
            }
            if (start < 0) throw PolarPmdException("negative interpolated timestamp")
            return List(count) { index ->
                if (index == count - 1) end else round(start + delta * index).toLong()
            }
        }

        fun signedLe(
            bytes: ByteArray,
            offset: Int,
            byteCount: Int,
            significantBits: Int,
        ): Int {
            if (byteCount !in 1..4 || significantBits !in 1..(byteCount * 8) ||
                offset < 0 || offset + byteCount > bytes.size
            ) {
                throw PolarPmdException("truncated signed integer")
            }
            var raw = 0L
            repeat(byteCount) { index -> raw = raw or (bytes[offset + index].u8().toLong() shl (index * 8)) }
            val mask = if (significantBits == 32) 0xFFFF_FFFFL else (1L shl significantBits) - 1
            raw = raw and mask
            val sign = 1L shl (significantBits - 1)
            if (raw and sign != 0L) raw = raw or mask.inv()
            return raw.toInt()
        }

        /**
         * Reference vector + `[deltaBitWidth, sampleCount, packed signed deltas…]`, LSB-first.
         */
        fun deltaSamples(
            bytes: ByteArray,
            channels: Int,
            resolution: Int,
            maximumSamples: Int = 4_096,
        ): List<List<Int>> {
            if (channels !in 1..32 || resolution !in 1..32 || maximumSamples <= 0) {
                throw PolarPmdException("invalid delta dimensions")
            }
            val referenceWidth = (resolution + 7) / 8
            val referenceBytes = channels * referenceWidth
            if (bytes.size < referenceBytes) throw PolarPmdException("truncated delta reference")
            val samples = mutableListOf(
                List(channels) { channel ->
                    signedLe(bytes, channel * referenceWidth, referenceWidth, resolution)
                },
            )
            var offset = referenceBytes
            while (offset < bytes.size) {
                if (offset + 2 > bytes.size) throw PolarPmdException("truncated delta header")
                val width = bytes[offset].u8()
                val count = bytes[offset + 1].u8()
                offset += 2
                if (width > 32) throw PolarPmdException("unsupported delta width")
                if (samples.size + count > maximumSamples) throw PolarPmdException("delta sample limit")
                val totalBits = count.toLong() * channels.toLong() * width.toLong()
                if (totalBits > Int.MAX_VALUE) throw PolarPmdException("delta bit limit")
                val packedBytes = ((totalBits + 7) / 8).toInt()
                if (offset + packedBytes > bytes.size) throw PolarPmdException("truncated delta payload")

                var bitOffset = 0
                repeat(count) {
                    val next = samples.last().toMutableList()
                    repeat(channels) { channel ->
                        var raw = 0L
                        if (width > 0) {
                            repeat(width) { bit ->
                                val absolute = bitOffset + bit
                                if (bytes[offset + absolute / 8].u8() and (1 shl (absolute % 8)) != 0) {
                                    raw = raw or (1L shl bit)
                                }
                            }
                            val mask = if (width == 32) 0xFFFF_FFFFL else (1L shl width) - 1
                            val sign = 1L shl (width - 1)
                            if (raw and sign != 0L) raw = raw or mask.inv()
                        }
                        val delta = raw.toInt()
                        val sum = next[channel].toLong() + delta.toLong()
                        if (sum !in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) {
                            throw PolarPmdException("delta accumulation overflow")
                        }
                        next[channel] = sum.toInt()
                        bitOffset += width
                    }
                    samples += next
                }
                offset += packedBytes
            }
            return samples
        }
    }
}

class PolarPmdClock {
    private var fallbackOffset: Long? = null

    fun reset() {
        fallbackOffset = null
    }

    fun unixNanoseconds(sensorTimestampNs: Long, receivedAtUnixNs: Long): Long {
        if (sensorTimestampNs >= 0 && sensorTimestampNs <= Long.MAX_VALUE - POLAR_TO_UNIX_EPOCH_NS) {
            val candidate = sensorTimestampNs + POLAR_TO_UNIX_EPOCH_NS
            val difference = if (candidate >= receivedAtUnixNs) {
                candidate - receivedAtUnixNs
            } else {
                receivedAtUnixNs - candidate
            }
            if (difference <= LIVE_CLOCK_TOLERANCE_NS) return candidate
        }
        if (fallbackOffset == null) {
            fallbackOffset = if (receivedAtUnixNs >= sensorTimestampNs) {
                receivedAtUnixNs - sensorTimestampNs
            } else {
                0
            }
        }
        val offset = fallbackOffset ?: 0
        return if (sensorTimestampNs <= Long.MAX_VALUE - offset) sensorTimestampNs + offset else receivedAtUnixNs
    }

    /**
     * PPI frames may carry timestamp zero. Anchor the newest beat to receive time and walk older
     * beats backward by their intervals so repeated zero-timestamp frames still advance.
     */
    fun unixNanoseconds(
        ppiSamples: List<PolarPmdPpiSample>,
        receivedAtUnixNs: Long,
    ): List<Long> {
        if (ppiSamples.isEmpty()) return emptyList()
        if (ppiSamples.any { it.sensorTimestampNs != 0L }) {
            return ppiSamples.map { unixNanoseconds(it.sensorTimestampNs, receivedAtUnixNs) }
        }
        val timestamps = MutableList(ppiSamples.size) { receivedAtUnixNs }
        var current = receivedAtUnixNs
        for (index in ppiSamples.indices.reversed()) {
            timestamps[index] = current
            val delta = ppiSamples[index].intervalMs.coerceAtLeast(0).toLong() * 1_000_000L
            current = if (current >= delta) current - delta else 0
        }
        return timestamps
    }

    companion object {
        const val POLAR_TO_UNIX_EPOCH_NS = 946_684_800_000_000_000L
        const val LIVE_CLOCK_TOLERANCE_NS = 5L * 60 * 1_000_000_000
    }
}

private fun Byte.u8(): Int = toInt() and 0xFF
