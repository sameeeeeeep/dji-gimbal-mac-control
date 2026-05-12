import XCTest
@testable import GimbalController

final class DUMLPacketBuilderTests: XCTestCase {
    func testMinimalPacket() {
        let builder = DUMLPacketBuilder()
        let packet = builder.build(
            cmdSet: DUMLConstants.CmdSet.battery.rawValue,
            cmdID: DUMLConstants.BatteryCmd.statusPush.rawValue
        )

        // Minimal packet should be 13 bytes (no payload)
        XCTAssertEqual(packet.count, 13)

        // SOF
        XCTAssertEqual(packet[0], 0x55)

        // Length should be 13
        let length = UInt16(packet[1]) | (UInt16(packet[2] & 0x03) << 8)
        XCTAssertEqual(length, 13)

        // CRC-8 should validate
        let headerCRC = CRC8.compute(Data([packet[0], packet[1], packet[2]]))
        XCTAssertEqual(packet[3], headerCRC)

        // Packet byte layout: type in low 5 bits, index in high 3 bits
        // (matches DUMLPacketBuilder: `(index << 5) | (type & 0x1F)`).
        // Default index is 0 for both sender and receiver.
        let senderType  = packet[4] & 0x1F
        let senderIndex = (packet[4] >> 5) & 0x07
        XCTAssertEqual(senderType, DUMLConstants.DeviceType.mobileApp.rawValue)
        XCTAssertEqual(senderIndex, 0)

        let receiverType  = packet[5] & 0x1F
        let receiverIndex = (packet[5] >> 5) & 0x07
        XCTAssertEqual(receiverType, DUMLConstants.DeviceType.gimbal.rawValue)
        XCTAssertEqual(receiverIndex, 0)

        // Command set and ID
        XCTAssertEqual(packet[9], DUMLConstants.CmdSet.battery.rawValue)
        XCTAssertEqual(packet[10], DUMLConstants.BatteryCmd.statusPush.rawValue)

        // CRC-16 should validate
        let bodyCRC = CRC16.compute(Data(packet[0..<11]))
        let packetCRC = UInt16(packet[11]) | (UInt16(packet[12]) << 8)
        XCTAssertEqual(bodyCRC, packetCRC)
    }

    func testPacketWithPayload() {
        let builder = DUMLPacketBuilder()
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let packet = builder.build(
            cmdSet: DUMLConstants.CmdSet.gimbal.rawValue,
            cmdID: DUMLConstants.GimbalCmd.control.rawValue,
            payload: payload
        )

        // Should be 13 + 4 = 17 bytes
        XCTAssertEqual(packet.count, 17)

        let length = UInt16(packet[1]) | (UInt16(packet[2] & 0x03) << 8)
        XCTAssertEqual(length, 17)

        // Payload bytes
        XCTAssertEqual(packet[11], 0x01)
        XCTAssertEqual(packet[12], 0x02)
        XCTAssertEqual(packet[13], 0x03)
        XCTAssertEqual(packet[14], 0x04)
    }

    func testSequenceIncrements() {
        let builder = DUMLPacketBuilder()

        let p1 = builder.build(cmdSet: 0x04, cmdID: 0x01)
        let seq1 = UInt16(p1[6]) | (UInt16(p1[7]) << 8)

        let p2 = builder.build(cmdSet: 0x04, cmdID: 0x01)
        let seq2 = UInt16(p2[6]) | (UInt16(p2[7]) << 8)

        XCTAssertEqual(seq2, seq1 + 1)
    }

    func testResetSequence() {
        let builder = DUMLPacketBuilder()
        _ = builder.build(cmdSet: 0x04, cmdID: 0x01)
        _ = builder.build(cmdSet: 0x04, cmdID: 0x01)

        builder.resetSequence()

        let p = builder.build(cmdSet: 0x04, cmdID: 0x01)
        let seq = UInt16(p[6]) | (UInt16(p[7]) << 8)
        XCTAssertEqual(seq, 0)
    }
}

final class DUMLPacketParserTests: XCTestCase {
    func testRoundTrip() {
        let builder = DUMLPacketBuilder()
        let parser = DUMLPacketParser()

        let payload = Data([0xAA, 0xBB, 0xCC])
        let rawPacket = builder.build(
            cmdSet: DUMLConstants.CmdSet.gimbal.rawValue,
            cmdID: DUMLConstants.GimbalCmd.control.rawValue,
            payload: payload
        )

        let packets = parser.feed(rawPacket)
        XCTAssertEqual(packets.count, 1)

        let parsed = packets[0]
        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.senderType, DUMLConstants.DeviceType.mobileApp.rawValue)
        XCTAssertEqual(parsed.receiverType, DUMLConstants.DeviceType.gimbal.rawValue)
        XCTAssertEqual(parsed.cmdSet, DUMLConstants.CmdSet.gimbal.rawValue)
        XCTAssertEqual(parsed.cmdID, DUMLConstants.GimbalCmd.control.rawValue)
        XCTAssertEqual(parsed.payload, payload)
    }

    func testMultiplePacketsInOneChunk() {
        let builder = DUMLPacketBuilder()
        let parser = DUMLPacketParser()

        let p1 = builder.build(cmdSet: 0x04, cmdID: 0x01)
        let p2 = builder.build(cmdSet: 0x05, cmdID: 0x06, payload: Data([0x64]))

        // Feed both packets concatenated
        var combined = Data()
        combined.append(p1)
        combined.append(p2)

        let packets = parser.feed(combined)
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].cmdSet, 0x04)
        XCTAssertEqual(packets[1].cmdSet, 0x05)
        XCTAssertEqual(packets[1].payload, Data([0x64]))
    }

    func testPartialPacketBuffering() {
        let builder = DUMLPacketBuilder()
        let parser = DUMLPacketParser()

        let rawPacket = builder.build(
            cmdSet: 0x04,
            cmdID: 0x01,
            payload: Data([0x01, 0x02, 0x03])
        )

        // Feed first half
        let midpoint = rawPacket.count / 2
        let firstHalf = Data(rawPacket[0..<midpoint])
        let secondHalf = Data(rawPacket[midpoint...])

        let packets1 = parser.feed(firstHalf)
        XCTAssertEqual(packets1.count, 0, "Should not parse incomplete packet")

        let packets2 = parser.feed(secondHalf)
        XCTAssertEqual(packets2.count, 1, "Should parse after receiving rest")
        XCTAssertTrue(packets2[0].isValid)
    }

    func testGarbageBeforeSOF() {
        let builder = DUMLPacketBuilder()
        let parser = DUMLPacketParser()

        let rawPacket = builder.build(cmdSet: 0x04, cmdID: 0x01)

        var withGarbage = Data([0xDE, 0xAD, 0xBE, 0xEF])
        withGarbage.append(rawPacket)

        let packets = parser.feed(withGarbage)
        XCTAssertEqual(packets.count, 1)
        XCTAssertTrue(packets[0].isValid)
    }

    func testReset() {
        let builder = DUMLPacketBuilder()
        let parser = DUMLPacketParser()

        // Feed partial data then reset
        let rawPacket = builder.build(cmdSet: 0x04, cmdID: 0x01)
        let partial = Data(rawPacket[0..<5])
        _ = parser.feed(partial)

        parser.reset()

        // Feed a complete packet — should work fine
        let newPacket = builder.build(cmdSet: 0x05, cmdID: 0x06)
        let packets = parser.feed(newPacket)
        XCTAssertEqual(packets.count, 1)
        XCTAssertTrue(packets[0].isValid)
    }
}
