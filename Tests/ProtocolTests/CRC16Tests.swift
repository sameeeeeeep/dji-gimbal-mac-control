import XCTest
@testable import GimbalController

final class CRC16Tests: XCTestCase {
    func testTableHas256Entries() {
        XCTAssertEqual(CRC16.table.count, 256)
    }

    func testEmptyData() {
        let crc = CRC16.compute(Data())
        XCTAssertEqual(crc, 0x3692, "CRC16 of empty data should be init value 0x3692")
    }

    func testKnownHeaderProducesOmResearchInit() {
        // The om-research code uses init 0xDF0C which is the CRC-16 running value
        // after processing the fixed header [0x55, 0x15, 0x04, 0xA9].
        // Our CRC16 with init 0x3692 over those 4 bytes should produce 0xDF0C.
        let header: [UInt8] = [0x55, 0x15, 0x04, 0xA9]
        let crc = CRC16.compute(header)
        // This validates that our init value and table match the om-research implementation
        // The value 0xDF0C is the pre-computed init used in their JS/Python code
        XCTAssertEqual(crc, 0xDF0C,
            "CRC16 of header [55 15 04 A9] should equal om-research init 0xDF0C")
    }

    func testDeterministic() {
        let data = Data([0x55, 0x15, 0x04, 0xA9, 0x11, 0x21])
        let crc1 = CRC16.compute(data)
        let crc2 = CRC16.compute(data)
        XCTAssertEqual(crc1, crc2)
    }
}
