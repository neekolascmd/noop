import Foundation
import XCTest
@testable import StrandImport

final class SharedWearableImportGoldenTests: XCTestCase {
    func testSharedWearableImportGoldenCases() throws {
        let fixture = try Self.loadFixture()
        XCTAssertEqual((fixture["schemaVersion"] as? NSNumber)?.intValue, 1)
        let tolerance = try XCTUnwrap(
            (fixture["tolerances"] as? [String: Any])?["metric"] as? NSNumber
        ).doubleValue
        let cases = try XCTUnwrap(fixture["wearableImports"] as? [[String: Any]])

        for testCase in cases {
            let id = try XCTUnwrap(testCase["id"] as? String)
            let brand = try XCTUnwrap(WearableBrand(rawValue: try XCTUnwrap(testCase["brand"] as? String)))
            let strings = try XCTUnwrap(testCase["files"] as? [String: String])
            let files = strings.mapValues { Data($0.utf8) }
            let result = WearableExportImporter.parse(brand: brand, files: files)
            let expected = try XCTUnwrap(testCase["expected"] as? [String: Any])

            XCTAssertEqual(result.days.count, try integer(expected["dayCount"]), id)
            XCTAssertEqual(result.sleeps.count, try integer(expected["sleepCount"]), id)
            XCTAssertEqual(
                result.heartRates.count,
                (expected["heartRateCount"] as? NSNumber)?.intValue ?? 0,
                id)
            XCTAssertEqual(
                result.workouts.count,
                (expected["workoutCount"] as? NSNumber)?.intValue ?? 0,
                id)

            if let dayExpected = expected["firstDay"] as? [String: Any] {
                let day = try XCTUnwrap(result.days.first, id)
                XCTAssertEqual(day.day, dayExpected["day"] as? String, id)
                XCTAssertEqual(day.restingHr, try integer(dayExpected["restingHr"]), id)
                XCTAssertEqual(day.steps, try integer(dayExpected["steps"]), id)
                XCTAssertEqual(day.readinessScore, try integer(dayExpected["readinessScore"]), id)
                try assertMetric(day.avgHrvMs, dayExpected["avgHrvMs"], tolerance, id)
                try assertMetric(day.respRateBpm, dayExpected["respRateBpm"], tolerance, id)
                try assertMetric(day.skinTempDevC, dayExpected["skinTempDevC"], tolerance, id)
                try assertMetric(day.activeKcal, dayExpected["activeKcal"], tolerance, id)
                try assertMetric(day.totalSleepMin, dayExpected["totalSleepMin"], tolerance, id)
            }

            if let sleepExpected = expected["firstSleep"] as? [String: Any] {
                let sleep = try XCTUnwrap(result.sleeps.first, id)
                XCTAssertEqual(sleep.lowestHr, try integer(sleepExpected["lowestHr"]), id)
                try assertMetric(sleep.totalSleepMin, sleepExpected["totalSleepMin"], tolerance, id)
                try assertMetric(sleep.deepMin, sleepExpected["deepMin"], tolerance, id)
                try assertMetric(sleep.remMin, sleepExpected["remMin"], tolerance, id)
                try assertMetric(sleep.avgHrvMs, sleepExpected["avgHrvMs"], tolerance, id)
                try assertMetric(sleep.respRateBpm, sleepExpected["respRateBpm"], tolerance, id)
                if let count = sleepExpected["stageCount"] as? NSNumber {
                    XCTAssertEqual(sleep.stages.count, count.intValue, id)
                }
                if let stage = sleepExpected["firstStage"] as? String {
                    let first = try XCTUnwrap(sleep.stages.first, id)
                    XCTAssertEqual(first.stage, stage, id)
                    if let duration = sleepExpected["firstStageDurationSec"] as? NSNumber {
                        XCTAssertEqual(first.end.timeIntervalSince(first.start), duration.doubleValue,
                                       accuracy: tolerance, id)
                    }
                }
            }

            if let heartRateExpected = expected["firstHeartRate"] as? [String: Any] {
                let sample = try XCTUnwrap(result.heartRates.first, id)
                XCTAssertEqual(sample.bpm, try integer(heartRateExpected["bpm"]), id)
                XCTAssertEqual(
                    Int(sample.timestamp.timeIntervalSince1970),
                    try integer(heartRateExpected["timestamp"]),
                    id)
            }

            if let workoutExpected = expected["firstWorkout"] as? [String: Any] {
                let workout = try XCTUnwrap(result.workouts.first, id)
                XCTAssertEqual(
                    Int(workout.start.timeIntervalSince1970),
                    try integer(workoutExpected["start"]),
                    id)
                XCTAssertEqual(
                    Int(workout.end.timeIntervalSince1970),
                    try integer(workoutExpected["end"]),
                    id)
                XCTAssertEqual(workout.activity, workoutExpected["activity"] as? String, id)
                XCTAssertEqual(workout.intensity, workoutExpected["intensity"] as? String, id)
                XCTAssertEqual(workout.source, workoutExpected["source"] as? String, id)
                XCTAssertEqual(workout.label, workoutExpected["label"] as? String, id)
                try assertMetric(workout.caloriesKcal, workoutExpected["caloriesKcal"], tolerance, id)
                try assertMetric(workout.distanceM, workoutExpected["distanceM"], tolerance, id)
            }
        }
    }

    private func integer(_ value: Any?) throws -> Int {
        try XCTUnwrap(value as? NSNumber).intValue
    }

    private func assertMetric(_ actual: Double?, _ expected: Any?, _ accuracy: Double, _ id: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try XCTUnwrap(actual, id), try XCTUnwrap(expected as? NSNumber).doubleValue,
                       accuracy: accuracy, id, file: file, line: line)
    }

    private static func loadFixture() throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("shared-fixtures/analytics/v1/golden.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any], "Invalid fixture at \(url.path)")
    }
}
