import XCTest
@testable import OuraProtocol

final class IdentityTests: XCTestCase {
    func testFirmwareIdentityDecodesVersionTripletsAndDropsAddress() {
        // Gen-5 example from OURA_PROTOCOL.md s4.3. The final six address bytes must not be exposed.
        let body: [UInt8] = [
            0x02, 0x01, 0x00, 0x02, 0x01, 0x03,
            0x01, 0x00, 0x01, 0x09, 0x03, 0x29,
            0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
        ]
        let identity = OuraDecoders.decodeFirmwareIdentity(body)
        XCTAssertEqual(identity?.api.description, "2.1.0")
        XCTAssertEqual(identity?.firmware.description, "2.1.3")
        XCTAssertEqual(identity?.bootloader.description, "1.0.1")
        XCTAssertEqual(identity?.bluetooth.description, "9.3.41")
    }

    func testFirmwareIdentityRejectsShortBody() {
        XCTAssertNil(OuraDecoders.decodeFirmwareIdentity(Array(repeating: 0, count: 11)))
    }

    func testProductHardwareExtractsDelimitedFamilyToken() {
        let body = [UInt8]("\0\0BLB_03\0".utf8)
        XCTAssertEqual(OuraDecoders.decodeProductHardware(body), "BLB_03")
    }

    func testProductHardwareNeverReturnsUndelimitedSerialLikeText() {
        XCTAssertNil(OuraDecoders.decodeProductHardware([UInt8]("ABC123456789\0".utf8)))
    }
}
