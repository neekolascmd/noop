import XCTest
@testable import OuraProtocol

final class TimeAnchorMappingTests: XCTestCase {
    func testGen3SecondsBecomeMillisecondsExactlyOnce() {
        let sync = OuraTimeSync(
            ringTimestamp: 10_000,
            epochMs: 1_719_662_400,
            tzOffsetSeconds: 3_600
        )
        let anchor = OuraTimeAnchorMapping.anchor(from: sync)
        XCTAssertEqual(
            anchor,
            OuraTimeAnchor(
                ringTimestamp: 10_000,
                utcMilliseconds: 1_719_662_400_000,
                factorMillisecondsPerTick: 100
            )
        )
        XCTAssertEqual(
            anchor.flatMap {
                OuraTimeAnchorMapping.unixSeconds(forRingTimestamp: 9_900, using: $0)
            },
            1_719_662_390
        )
    }

    func testRing4BurstFactorIsPreserved() {
        let sync = OuraTimeSync(
            ringTimestamp: 20_000,
            epochMs: 1_700_000_000,
            tzOffsetSeconds: 0,
            factorMsPerTick: 1,
            token: 0xFD
        )
        let anchor = OuraTimeAnchorMapping.anchor(from: sync)
        XCTAssertEqual(anchor?.factorMillisecondsPerTick, 1)
        XCTAssertEqual(
            anchor.flatMap {
                OuraTimeAnchorMapping.unixSeconds(forRingTimestamp: 21_000, using: $0)
            },
            1_700_000_001
        )
    }

    func testRtcBeaconBuildsNormalClockAnchor() {
        let anchor = OuraTimeAnchorMapping.anchor(
            from: OuraRtcBeacon(ringTimestamp: 1_000, unixSeconds: 1_700_000_000)
        )
        XCTAssertEqual(anchor?.factorMillisecondsPerTick, 100)
        XCTAssertEqual(anchor?.utcMilliseconds, 1_700_000_000_000)
    }

    func testImplausibleAndOverflowingMappingsAreRejected() {
        XCTAssertNil(
            OuraTimeAnchorMapping.anchor(
                from: OuraTimeSync(
                    ringTimestamp: 1,
                    epochMs: Int64.max,
                    tzOffsetSeconds: 0
                )
            )
        )
        let corrupt = OuraTimeAnchor(
            ringTimestamp: 1,
            utcMilliseconds: Int64.max,
            factorMillisecondsPerTick: 100
        )
        XCTAssertNil(
            OuraTimeAnchorMapping.unixSeconds(
                forRingTimestamp: UInt32.max,
                using: corrupt
            )
        )
    }
}
