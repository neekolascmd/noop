package com.noop.analytics

import com.noop.ingest.WearableExportImporter
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class SharedAnalyticsGoldenTest {
    private val fixture: JSONObject by lazy {
        val path = checkNotNull(System.getProperty("noop.analyticsFixtures")) {
            "Gradle did not provide noop.analyticsFixtures"
        }
        JSONObject(File(path).readText())
    }

    private val scoreTolerance: Double get() = fixture.getJSONObject("tolerances").getDouble("score")
    private val metricTolerance: Double get() = fixture.getJSONObject("tolerances").getDouble("metric")
    private val sleepTolerance: Double get() = fixture.getJSONObject("tolerances").getDouble("sleepMinutes")

    @Test
    fun recoveryGoldenCases() {
        assertEquals(1, fixture.getInt("schemaVersion"))
        fixture.getJSONArray("recovery").objects().forEach { testCase ->
            val id = testCase.getString("id")
            val input = testCase.getJSONObject("input")
            val actual = RecoveryScorer.recovery(
                hrv = input.getDouble("hrv"),
                rhr = input.getDouble("rhr"),
                resp = input.optionalDouble("resp"),
                hrvBaseline = input.optionalBaseline("hrvBaseline"),
                rhrBaseline = input.optionalBaseline("rhrBaseline"),
                respBaseline = input.optionalBaseline("respBaseline"),
                sleepPerf = input.optionalDouble("sleepPerf"),
                skinTempDev = input.optionalDouble("skinTempDev"),
                hrvBaselineUsable = input.getBoolean("hrvBaselineUsable"),
            )
            assertOptional(id, testCase, "expectedScore", actual, scoreTolerance)
        }
    }

    @Test
    fun strainGoldenCases() {
        fixture.getJSONArray("strain").objects().forEach { testCase ->
            val id = testCase.getString("id")
            assertEquals(id, testCase.getDouble("expectedScore"),
                StrainScorer.trimpToStrain(testCase.getDouble("trimp")), scoreTolerance)
        }
    }

    @Test
    fun hrvGoldenCases() {
        fixture.getJSONArray("hrv").objects().forEach { testCase ->
            val id = testCase.getString("id")
            val rr = testCase.getJSONArray("rrMs").let { array ->
                (0 until array.length()).map(array::getDouble)
            }
            val expected = testCase.getJSONObject("expected")
            val actual = HrvAnalyzer.analyzeRaw(rr)
            assertOptional("$id.rmssd", expected, "rmssd", actual.rmssd, metricTolerance)
            assertOptional("$id.sdnn", expected, "sdnn", actual.sdnn, metricTolerance)
            assertOptional("$id.meanNN", expected, "meanNN", actual.meanNN, metricTolerance)
            assertOptional("$id.pnn50", expected, "pnn50", actual.pnn50, metricTolerance)
            assertEquals(id, expected.getInt("nInput"), actual.nInput)
            assertEquals(id, expected.getInt("nClean"), actual.nClean)
        }
    }

    @Test
    fun sleepGoldenCases() {
        fixture.getJSONArray("sleep").objects().forEach { testCase ->
            val id = testCase.getString("id")
            val stages = testCase.getString("stagesJSON")
            val actual = SleepStageTotals.minutes(stages)
            if (testCase.isNull("expected")) {
                assertNull(id, actual)
                assertNull(id, SleepStageTotals.dailyAggregate(listOf(stages)))
                return@forEach
            }
            val expected = testCase.getJSONObject("expected")
            checkNotNull(actual)
            assertEquals(id, expected.getDouble("awake"), actual.awake, sleepTolerance)
            assertEquals(id, expected.getDouble("light"), actual.light, sleepTolerance)
            assertEquals(id, expected.getDouble("deep"), actual.deep, sleepTolerance)
            assertEquals(id, expected.getDouble("rem"), actual.rem, sleepTolerance)
            assertEquals(id, expected.getDouble("asleep"), actual.asleep, sleepTolerance)
            assertEquals(id, expected.getDouble("inBed"), actual.inBed, sleepTolerance)
            val daily = checkNotNull(SleepStageTotals.dailyAggregate(listOf(stages)))
            assertEquals(id, expected.getDouble("asleep"), daily.totalSleepMin, sleepTolerance)
            assertEquals(id, expected.getDouble("efficiency"), daily.efficiency, metricTolerance)
        }
    }

    @Test
    fun wearableImportGoldenCases() {
        fixture.getJSONArray("wearableImports").objects().forEach { testCase ->
            val id = testCase.getString("id")
            val brand = WearableExportImporter.Brand.valueOf(testCase.getString("brand").uppercase())
            val filesObject = testCase.getJSONObject("files")
            val files = filesObject.keys().asSequence().associateWith { name ->
                filesObject.getString(name).toByteArray()
            }
            val parsed = when (brand) {
                WearableExportImporter.Brand.OURA -> WearableExportImporter.parseOura(files)
                WearableExportImporter.Brand.FITBIT -> WearableExportImporter.parseFitbit(files)
                WearableExportImporter.Brand.GARMIN -> WearableExportImporter.parseGarmin(files)
            }
            val expected = testCase.getJSONObject("expected")
            assertEquals(id, expected.getInt("dayCount"), parsed.days.size)
            assertEquals(id, expected.getInt("sleepCount"), parsed.sleeps.size)

            expected.optJSONObject("firstDay")?.let { dayExpected ->
                val day = parsed.days.first()
                assertEquals(id, dayExpected.getString("day"), day.day)
                assertEquals(id, dayExpected.getInt("restingHr"), day.restingHr)
                assertEquals(id, dayExpected.getInt("steps"), day.steps)
                assertEquals(id, dayExpected.getInt("readinessScore"), day.readinessScore)
                assertEquals(id, dayExpected.getDouble("avgHrvMs"), day.avgHrvMs!!, metricTolerance)
                assertEquals(id, dayExpected.getDouble("respRateBpm"), day.respRateBpm!!, metricTolerance)
                assertEquals(id, dayExpected.getDouble("skinTempDevC"), day.skinTempDevC!!, metricTolerance)
                assertEquals(id, dayExpected.getDouble("activeKcal"), day.activeKcal!!, metricTolerance)
                assertEquals(id, dayExpected.getDouble("totalSleepMin"), day.totalSleepMin!!, metricTolerance)
            }
            expected.optJSONObject("firstSleep")?.let { sleepExpected ->
                val sleep = parsed.sleeps.first()
                assertEquals(id, sleepExpected.getInt("lowestHr"), sleep.lowestHr)
                assertEquals(id, sleepExpected.getDouble("totalSleepMin"), sleep.totalSleepMin!!, metricTolerance)
                assertEquals(id, sleepExpected.getDouble("deepMin"), sleep.deepMin!!, metricTolerance)
                assertEquals(id, sleepExpected.getDouble("remMin"), sleep.remMin!!, metricTolerance)
                assertEquals(id, sleepExpected.getDouble("avgHrvMs"), sleep.avgHrvMs!!, metricTolerance)
                assertEquals(id, sleepExpected.getDouble("respRateBpm"), sleep.respRateBpm!!, metricTolerance)
            }
        }
    }

    private fun JSONObject.optionalDouble(key: String): Double? =
        if (isNull(key)) null else getDouble(key)

    private fun JSONObject.optionalBaseline(key: String): RecoveryScorer.DriverBaseline? =
        optJSONObject(key)?.let { RecoveryScorer.DriverBaseline(it.getDouble("mean"), it.getDouble("spread")) }

    private fun assertOptional(id: String, objectValue: JSONObject, key: String,
                               actual: Double?, tolerance: Double) {
        if (objectValue.isNull(key)) assertNull(id, actual)
        else assertEquals(id, objectValue.getDouble(key), checkNotNull(actual), tolerance)
    }

    private fun org.json.JSONArray.objects(): Sequence<JSONObject> =
        (0 until length()).asSequence().map(::getJSONObject)
}
