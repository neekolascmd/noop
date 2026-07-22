import XCTest
@testable import WhoopProtocol

final class PeripheralReconnectPolicyTests: XCTestCase {
    func testReconnectRequiresUnintentionalDropAndRememberedTarget() {
        XCTAssertTrue(PeripheralReconnectPolicy.shouldReconnect(
            intentionalDisconnect: false, hasTarget: true
        ))
        XCTAssertFalse(PeripheralReconnectPolicy.shouldReconnect(
            intentionalDisconnect: true, hasTarget: true
        ))
        XCTAssertFalse(PeripheralReconnectPolicy.shouldReconnect(
            intentionalDisconnect: false, hasTarget: false
        ))
        XCTAssertFalse(PeripheralReconnectPolicy.shouldReconnect(
            intentionalDisconnect: true, hasTarget: false
        ))
    }

    func testDelayUsesCappedExponentialSchedule() {
        XCTAssertEqual(
            (1...8).map { PeripheralReconnectPolicy.delaySeconds(attempt: $0) },
            [3, 6, 12, 24, 48, 60, 60, 60]
        )
        XCTAssertEqual(PeripheralReconnectPolicy.delaySeconds(attempt: 0), 3)
        XCTAssertEqual(PeripheralReconnectPolicy.delaySeconds(attempt: Int.max), 60)
    }
}
