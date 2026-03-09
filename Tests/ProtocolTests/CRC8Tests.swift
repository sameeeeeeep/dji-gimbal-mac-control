import XCTest
@testable import GimbalController

final class CRC8Tests: XCTestCase {
    func testTableHas256Entries() {
        XCTAssertEqual(CRC8.table.count, 256)
    }

    func testKnownHeader() {
        // The om-research header [0x55, 0x15, 0x04] should produce CRC8 = 0xA9
        // (the 4th byte of their fixed header is the CRC8)
        let header: [UInt8] = [0x55, 0x15, 0x04]
        let crc = CRC8.compute(header)
        XCTAssertEqual(crc, 0xA9, "CRC8 of om-research header should be 0xA9")
    }

    func testEmptyData() {
        // With no data, should return the init value
        let crc = CRC8.compute(Data())
        XCTAssertEqual(crc, 0x77, "CRC8 of empty data should be init value 0x77")
    }

    func testSingleByte() {
        // CRC8 of [0x55] with init 0x77: table[0x77 ^ 0x55] = table[0x22] = 0x9F
        let crc = CRC8.compute([0x55])
        XCTAssertEqual(crc, CRC8.table[0x77 ^ 0x55])
    }

    func testDeterministic() {
        let data = Data([0x55, 0x15, 0x04])
        let crc1 = CRC8.compute(data)
        let crc2 = CRC8.compute(data)
        XCTAssertEqual(crc1, crc2)
    }
}
