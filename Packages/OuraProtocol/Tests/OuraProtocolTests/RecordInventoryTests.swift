import XCTest
@testable import OuraProtocol

final class RecordInventoryTests: XCTestCase {
    func testInventoryCountsMetadataWithoutRetainingPayloadValues() {
        var inventory = OuraRecordInventory()
        let temp = OuraRecord(type: OuraEventTag.temp.rawValue,
                              ringTimestamp: 0x1234_5678,
                              payload: [0xE4, 0x0C])
        let unknown = OuraRecord(type: 0x90,
                                 ringTimestamp: 0x8765_4321,
                                 payload: [0xAA, 0xBB, 0xCC])

        inventory.observe(temp, emittedEventCount: 1)
        inventory.observe(unknown, emittedEventCount: 0)
        inventory.observe(unknown, emittedEventCount: 0)

        XCTAssertEqual(inventory.totalRecordCount, 3)
        XCTAssertEqual(inventory.totalWireByteCount, temp.totalLength + 2 * unknown.totalLength)
        XCTAssertEqual(inventory.emittedEventCount, 1)
        XCTAssertEqual(inventory.unknownRecordCount, 2)

        XCTAssertEqual(inventory.entries, [
            .init(tag: 0x46, recordCount: 1, wireByteCount: 8,
                  emittedEventCount: 1, decodedRecordCount: 1),
            .init(tag: 0x90, recordCount: 2, wireByteCount: 18,
                  emittedEventCount: 0, decodedRecordCount: 0),
        ])
        XCTAssertEqual(inventory.entries[0].knownTag, .temp)
        XCTAssertNil(inventory.entries[1].knownTag)
        XCTAssertEqual(inventory.entries[1].silentRecordCount, 2)

        let summary = inventory.summary()
        XCTAssertTrue(summary.contains("records=3 bytes=26 events=1 unknown=2"))
        XCTAssertTrue(summary.contains("0x46(TEMP)=1r/1e/8b"))
        XCTAssertTrue(summary.contains("0x90(UNKNOWN)=2r/0e/18b"))
        XCTAssertFalse(summary.contains("12345678"))
        XCTAssertFalse(summary.contains("AABBCC"))
    }

    func testKnownSilentRecordIsNotReportedAsUnknown() {
        var inventory = OuraRecordInventory()
        inventory.observe(
            OuraRecord(type: OuraEventTag.ringStart.rawValue,
                       ringTimestamp: 1,
                       payload: [1, 2, 3, 4]),
            emittedEventCount: 0
        )

        XCTAssertEqual(inventory.unknownRecordCount, 0)
        XCTAssertEqual(inventory.entries.single?.knownTag, .ringStart)
        XCTAssertEqual(inventory.entries.single?.silentRecordCount, 1)
    }

    func testSummaryTagLimitIsBoundedAndDeterministic() {
        var inventory = OuraRecordInventory()
        inventory.observe(OuraRecord(type: 0x90, ringTimestamp: 1, payload: []), emittedEventCount: 0)
        inventory.observe(OuraRecord(type: 0x46, ringTimestamp: 2, payload: [0, 0]), emittedEventCount: 1)
        inventory.observe(OuraRecord(type: 0x85, ringTimestamp: 3, payload: [0, 0, 0, 0]), emittedEventCount: 1)

        XCTAssertEqual(
            inventory.summary(maximumTags: 2),
            "records=3 bytes=24 events=2 unknown=1 tags=[0x46(TEMP)=1r/1e/8b,0x85(RTC_BEACON)=1r/1e/10b +1 tag(s)]"
        )
        XCTAssertEqual(
            inventory.summary(maximumTags: 0),
            "records=3 bytes=24 events=2 unknown=1 tags=[none +3 tag(s)]"
        )
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
