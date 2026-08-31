import XCTest
@testable import OuraProtocol

final class HypnogramAssemblerTests: XCTestCase {
    private func series(_ stages: [OuraSleepStage], rt: UInt32, unwritten: [Bool]? = nil,
                        tag: UInt8 = OuraEventTag.sleepPhase.rawValue) -> OuraSleepPhaseSeries {
        OuraSleepPhaseSeries(ringTimestamp: rt, sourceTag: tag, header: 0,
                             stages: stages, unwritten: unwritten)
    }

    private func fourCodeBurst() -> OuraHypnogramBurst {
        let assembler = OuraHypnogramAssembler()
        XCTAssertNil(assembler.feed(series([.awake, .light, .deep, .rem], rt: 1_000)))
        return assembler.finish()!
    }

    func testStagesLayBackwardFromEndAtThirtySecondEpochs() {
        let epochs = fourCodeBurst().codesWithTimes(endUnixSeconds: 10_000)
        XCTAssertEqual(epochs.map(\.ts), [9_880, 9_910, 9_940, 9_970])
        XCTAssertEqual(epochs.map(\.stage), [.awake, .light, .deep, .rem])
        XCTAssertEqual(epochs.last!.ts + 30, 10_000)
    }

    func testArrivalOrderIsPreservedAcrossAtomicRecords() {
        let assembler = OuraHypnogramAssembler()
        XCTAssertNil(assembler.feed(series([.awake, .light], rt: 5_010)))
        XCTAssertNil(assembler.feed(series([.deep, .rem], rt: 5_000)))
        let burst = assembler.finish()!
        XCTAssertTrue(burst.hasNonMonotonicRingTimes)
        XCTAssertEqual(burst.codesWithTimes(endUnixSeconds: 1_000).map(\.stage),
                       [.awake, .light, .deep, .rem])
    }

    func testMiddleUnwrittenPageLeavesGapWithoutShiftingWrittenStages() {
        let assembler = OuraHypnogramAssembler()
        XCTAssertNil(assembler.feed(series([.deep, .light, .rem, .awake], rt: 1_000)))
        XCTAssertNil(assembler.feed(series(Array(repeating: .awake, count: 4),
                                                rt: 1_001,
                                                unwritten: Array(repeating: true, count: 4))))
        XCTAssertNil(assembler.feed(series([.light, .deep, .rem, .light], rt: 1_002)))

        let burst = assembler.finish()!
        XCTAssertEqual(burst.totalCodes, 12, "unwritten slots remain part of the time axis")
        let epochs = burst.codesWithTimes(endUnixSeconds: 10_000)
        XCTAssertEqual(epochs.count, 8)
        XCTAssertEqual(epochs.prefix(4).map(\.ts), [9_640, 9_670, 9_700, 9_730])
        XCTAssertEqual(epochs.suffix(4).map(\.ts), [9_880, 9_910, 9_940, 9_970])
        XCTAssertEqual(epochs.map(\.stage),
                       [.deep, .light, .rem, .awake, .light, .deep, .rem, .light])
    }

    func testAllUnwrittenBurstProducesNoEpochs() {
        let assembler = OuraHypnogramAssembler()
        XCTAssertNil(assembler.feed(series(Array(repeating: .awake, count: 8),
                                                rt: 1_000,
                                                unwritten: Array(repeating: true, count: 8))))
        let burst = assembler.finish()!
        XCTAssertEqual(burst.totalCodes, 8)
        XCTAssertEqual(burst.codesWithTimes(endUnixSeconds: 10_000), [])
        XCTAssertEqual(burst.codesWithTimes(endUnixSeconds: 10_000,
                                            sleepStartUnixSeconds: 9_000), [])
    }

    func testSleepWindowOnsetClipsLeadingEpochsButNeverEmptiesBurst() {
        let burst = fourCodeBurst()
        let clipped = burst.codesWithTimes(endUnixSeconds: 10_000,
                                           sleepStartUnixSeconds: 9_910)
        XCTAssertEqual(clipped.map(\.ts), [9_910, 9_940, 9_970])
        XCTAssertEqual(clipped.map(\.stage), [.light, .deep, .rem])

        XCTAssertEqual(burst.codesWithTimes(endUnixSeconds: 10_000,
                                            sleepStartUnixSeconds: 9_880).count, 4)
        XCTAssertEqual(burst.codesWithTimes(endUnixSeconds: 10_000,
                                            sleepStartUnixSeconds: 99_999).map(\.ts),
                       [9_880, 9_910, 9_940, 9_970])
    }

    func testGapThresholdKeepsSixHundredTicksAndSplitsAboveIt() {
        let assembler = OuraHypnogramAssembler()
        XCTAssertNil(assembler.feed(series([.light], rt: 1_000)))
        XCTAssertNil(assembler.feed(series([.deep], rt: 1_600)),
                     "the configured boundary remains in one burst")
        let closed = assembler.feed(series([.rem], rt: 2_201))
        XCTAssertEqual(closed?.records.map(\.ringTimestamp), [1_000, 1_600])
        XCTAssertEqual(assembler.finish()?.records.map(\.ringTimestamp), [2_201])
    }

    func testEnvelopeAnchorBoundarySplitsConservatively() {
        let assembler = OuraHypnogramAssembler()
        XCTAssertNil(assembler.feed(series([.light], rt: 100), envelopeUnixSeconds: 50_000))
        let anchored = assembler.feed(series([.deep], rt: 110), envelopeUnixSeconds: nil)
        XCTAssertEqual(anchored?.records.map(\.ringTimestamp), [100])
        XCTAssertEqual(anchored?.lastEnvelopeUnixSeconds, 50_000)
        XCTAssertEqual(assembler.finish()?.records.map(\.ringTimestamp), [110])
    }

    func testSameRawTicksFromDifferentWallClockNightsNeverMerge() {
        let assembler = OuraHypnogramAssembler()
        XCTAssertNil(assembler.feed(series([.light], rt: 1_000),
                                    envelopeUnixSeconds: 1_700_000_000))
        let previousNight = assembler.feed(series([.deep], rt: 1_001),
                                           envelopeUnixSeconds: 1_700_086_400)
        XCTAssertEqual(previousNight?.records.map(\.ringTimestamp), [1_000])
        XCTAssertEqual(assembler.finish()?.records.map(\.ringTimestamp), [1_001])
    }

    func testFullNightScaleProducesUniqueContiguousEpochs() {
        let assembler = OuraHypnogramAssembler()
        for index in 0..<23 {
            XCTAssertNil(assembler.feed(series(Array(repeating: .light, count: 52),
                                                rt: 3_970_000 + UInt32(index))))
        }
        let burst = assembler.finish()!
        XCTAssertEqual(burst.totalCodes, 1_196)
        let end = 1_760_000_000
        let epochs = burst.codesWithTimes(endUnixSeconds: end)
        XCTAssertEqual(epochs.first?.ts, end - 1_196 * 30)
        XCTAssertEqual(epochs.count, 1_196)
        XCTAssertTrue(zip(epochs, epochs.dropFirst()).allSatisfy { $1.ts - $0.ts == 30 })
    }

    func testEmptyRecordsFinishResetAndInvalidCadenceAreSafe() {
        let assembler = OuraHypnogramAssembler()
        XCTAssertNil(assembler.feed(series([], rt: 10)))
        XCTAssertNil(assembler.finish())
        XCTAssertNil(assembler.feed(series([.rem], rt: 20)))
        XCTAssertEqual(assembler.pendingRecordCount, 1)
        assembler.reset()
        XCTAssertEqual(assembler.pendingRecordCount, 0)
        XCTAssertNil(assembler.flush())
        XCTAssertEqual(fourCodeBurst().codesWithTimes(endUnixSeconds: 1_000,
                                                      secondsPerCode: 0), [])
    }
}
