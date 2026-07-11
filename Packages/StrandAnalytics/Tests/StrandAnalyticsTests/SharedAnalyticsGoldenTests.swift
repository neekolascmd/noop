import Foundation
import XCTest
@testable import StrandAnalytics

final class SharedAnalyticsGoldenTests: XCTestCase {
    private var fixture: [String: Any]!
    private var scoreTolerance: Double!
    private var metricTolerance: Double!
    private var sleepTolerance: Double!

    override func setUpWithError() throws {
        fixture = try Self.loadFixture()
        XCTAssertEqual((fixture["schemaVersion"] as? NSNumber)?.intValue, 1)
        let tolerances = try XCTUnwrap(fixture["tolerances"] as? [String: Any])
        scoreTolerance = try number(tolerances["score"])
        metricTolerance = try number(tolerances["metric"])
        sleepTolerance = try number(tolerances["sleepMinutes"])
    }

    func testRecoveryGoldenCases() throws {
        for testCase in try cases(named: "recovery") {
            let id = try XCTUnwrap(testCase["id"] as? String)
            let input = try XCTUnwrap(testCase["input"] as? [String: Any])
            let actual = RecoveryScorer.recovery(
                hrv: try number(input["hrv"]),
                rhr: try number(input["rhr"]),
                resp: optionalNumber(input["resp"]),
                hrvBaseline: baseline(input["hrvBaseline"]),
                rhrBaseline: baseline(input["rhrBaseline"]),
                respBaseline: baseline(input["respBaseline"]),
                sleepPerf: optionalNumber(input["sleepPerf"]),
                skinTempDev: optionalNumber(input["skinTempDev"]),
                hrvBaselineUsable: try XCTUnwrap(input["hrvBaselineUsable"] as? Bool)
            )
            try assertOptional(actual, equals: testCase["expectedScore"], accuracy: scoreTolerance, id: id)
        }
    }

    func testStrainGoldenCases() throws {
        for testCase in try cases(named: "strain") {
            let id = try XCTUnwrap(testCase["id"] as? String)
            let actual = StrainScorer.trimpToStrain(try number(testCase["trimp"]))
            XCTAssertEqual(actual, try number(testCase["expectedScore"]), accuracy: scoreTolerance, id)
        }
    }

    func testHrvGoldenCases() throws {
        for testCase in try cases(named: "hrv") {
            let id = try XCTUnwrap(testCase["id"] as? String)
            let rr = try XCTUnwrap(testCase["rrMs"] as? [NSNumber]).map(\.doubleValue)
            let expected = try XCTUnwrap(testCase["expected"] as? [String: Any])
            let actual = HRVAnalyzer.analyze(rawRR: rr)

            try assertOptional(actual.rmssd, equals: expected["rmssd"], accuracy: metricTolerance, id: "\(id).rmssd")
            try assertOptional(actual.sdnn, equals: expected["sdnn"], accuracy: metricTolerance, id: "\(id).sdnn")
            try assertOptional(actual.meanNN, equals: expected["meanNN"], accuracy: metricTolerance, id: "\(id).meanNN")
            try assertOptional(actual.pnn50, equals: expected["pnn50"], accuracy: metricTolerance, id: "\(id).pnn50")
            XCTAssertEqual(actual.nInput, try integer(expected["nInput"]), id)
            XCTAssertEqual(actual.nClean, try integer(expected["nClean"]), id)
        }
    }

    func testSleepGoldenCases() throws {
        for testCase in try cases(named: "sleep") {
            let id = try XCTUnwrap(testCase["id"] as? String)
            let stagesJSON = try XCTUnwrap(testCase["stagesJSON"] as? String)
            let actual = SleepStageTotals.minutes(fromStagesJSON: stagesJSON)

            guard let expected = testCase["expected"] as? [String: Any] else {
                XCTAssertNil(actual, id)
                XCTAssertNil(SleepStageTotals.dailyAggregate([stagesJSON]), id)
                continue
            }
            let minutes = try XCTUnwrap(actual, id)
            XCTAssertEqual(minutes.awake, try number(expected["awake"]), accuracy: sleepTolerance, id)
            XCTAssertEqual(minutes.light, try number(expected["light"]), accuracy: sleepTolerance, id)
            XCTAssertEqual(minutes.deep, try number(expected["deep"]), accuracy: sleepTolerance, id)
            XCTAssertEqual(minutes.rem, try number(expected["rem"]), accuracy: sleepTolerance, id)
            XCTAssertEqual(minutes.asleep, try number(expected["asleep"]), accuracy: sleepTolerance, id)
            XCTAssertEqual(minutes.inBed, try number(expected["inBed"]), accuracy: sleepTolerance, id)

            let daily = try XCTUnwrap(SleepStageTotals.dailyAggregate([stagesJSON]), id)
            XCTAssertEqual(daily.totalSleepMin, try number(expected["asleep"]), accuracy: sleepTolerance, id)
            XCTAssertEqual(daily.efficiency, try number(expected["efficiency"]), accuracy: metricTolerance, id)
        }
    }

    private func cases(named name: String) throws -> [[String: Any]] {
        try XCTUnwrap(fixture[name] as? [[String: Any]], "Missing fixture section \(name)")
    }

    private func baseline(_ value: Any?) -> RecoveryScorer.DriverBaseline? {
        guard let object = value as? [String: Any],
              let mean = (object["mean"] as? NSNumber)?.doubleValue,
              let spread = (object["spread"] as? NSNumber)?.doubleValue else { return nil }
        return .init(mean: mean, spread: spread)
    }

    private func number(_ value: Any?) throws -> Double {
        try XCTUnwrap(value as? NSNumber).doubleValue
    }

    private func integer(_ value: Any?) throws -> Int {
        try XCTUnwrap(value as? NSNumber).intValue
    }

    private func optionalNumber(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func assertOptional(_ actual: Double?, equals expected: Any?, accuracy: Double,
                                id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard !(expected is NSNull) else {
            XCTAssertNil(actual, id, file: file, line: line)
            return
        }
        XCTAssertEqual(try XCTUnwrap(actual, id), try number(expected), accuracy: accuracy,
                       id, file: file, line: line)
    }

    private static func loadFixture() throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("shared-fixtures/analytics/v1/golden.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any], "Invalid fixture at \(url.path)")
    }
}
