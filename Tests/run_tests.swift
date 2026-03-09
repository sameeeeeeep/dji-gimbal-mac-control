import Foundation

@main
struct TestRunner {
    static var passed = 0
    static var failed = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1 }
        else { failed += 1; print("    FAIL: \(message)") }
    }

    static func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") {
        if a == b { passed += 1 }
        else { failed += 1; print("    FAIL: \(message) — expected \(b), got \(a)") }
    }

    static func main() {
        print("CRC-8 Tests:")
        checkEqual(CRC8.table.count, 256, "table size")
        checkEqual(CRC8.compute([0x55, 0x15, 0x04]), 0xA9, "known header CRC8")
        checkEqual(CRC8.compute(Data()), 0x77, "empty data = init")
        let d1 = Data([0x55, 0x15, 0x04])
        checkEqual(CRC8.compute(d1), CRC8.compute(d1), "deterministic")

        print("CRC-16 Tests:")
        checkEqual(CRC16.table.count, 256, "table size")
        checkEqual(CRC16.compute(Data()), 0x3692, "empty data = init")
        checkEqual(CRC16.compute([0x55, 0x15, 0x04, 0xA9]), 0xDF0C, "header -> om-research init")
        let d2 = Data([0x55, 0x15, 0x04, 0xA9, 0x11])
        checkEqual(CRC16.compute(d2), CRC16.compute(d2), "deterministic")

        print("Packet Builder Tests:")
        let b1 = DUMLPacketBuilder()
        let p1 = b1.build(cmdSet: 0x05, cmdID: 0x06)
        checkEqual(p1.count, 13, "minimal packet = 13 bytes")
        checkEqual(p1[0], 0x55, "SOF")
        let len = UInt16(p1[1]) | (UInt16(p1[2] & 0x03) << 8)
        checkEqual(len, 13, "length field")
        let hcrc = CRC8.compute(Data([p1[0], p1[1], p1[2]]))
        checkEqual(p1[3], hcrc, "CRC-8 header")
        checkEqual(p1[4] & 0x1F, 0x02, "sender type = mobileApp")
        checkEqual((p1[4] >> 5) & 0x07, 0x00, "sender index = 0")
        checkEqual(p1[5] & 0x1F, 0x04, "receiver type = gimbal")
        checkEqual((p1[5] >> 5) & 0x07, 0x00, "receiver index = 0")
        let bodyCRC = CRC16.compute(Data(p1[0..<11]))
        let pktCRC = UInt16(p1[11]) | (UInt16(p1[12]) << 8)
        checkEqual(bodyCRC, pktCRC, "CRC-16 packet")

        let b2 = DUMLPacketBuilder()
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let p2 = b2.build(cmdSet: 0x04, cmdID: 0x01, payload: payload)
        checkEqual(p2.count, 17, "packet with payload = 17 bytes")

        let b3 = DUMLPacketBuilder()
        let s1 = b3.build(cmdSet: 0x04, cmdID: 0x01)
        let seq1 = UInt16(s1[6]) | (UInt16(s1[7]) << 8)
        let s2 = b3.build(cmdSet: 0x04, cmdID: 0x01)
        let seq2 = UInt16(s2[6]) | (UInt16(s2[7]) << 8)
        checkEqual(seq2, seq1 + 1, "sequence increments")

        print("Packet Parser Tests:")
        let builder = DUMLPacketBuilder()
        let parser = DUMLPacketParser()

        // Round-trip
        let rtPayload = Data([0xAA, 0xBB, 0xCC])
        let rtPacket = builder.build(cmdSet: 0x04, cmdID: 0x01, payload: rtPayload)
        let rtParsed = parser.feed(rtPacket)
        checkEqual(rtParsed.count, 1, "round-trip: one packet")
        if let rt = rtParsed.first {
            check(rt.isValid, "round-trip: valid")
            checkEqual(rt.senderType, 0x02, "round-trip: sender")
            checkEqual(rt.receiverType, 0x04, "round-trip: receiver")
            checkEqual(rt.cmdSet, 0x04, "round-trip: cmdSet")
            checkEqual(rt.cmdID, 0x01, "round-trip: cmdID")
            checkEqual(rt.payload, rtPayload, "round-trip: payload")
        }

        // Multiple packets in one chunk
        let parser2 = DUMLPacketParser()
        let mp1 = builder.build(cmdSet: 0x04, cmdID: 0x01)
        let mp2 = builder.build(cmdSet: 0x05, cmdID: 0x06, payload: Data([0x64]))
        var combined = Data()
        combined.append(mp1)
        combined.append(mp2)
        let multiParsed = parser2.feed(combined)
        checkEqual(multiParsed.count, 2, "multi: two packets")
        if multiParsed.count >= 2 {
            checkEqual(multiParsed[0].cmdSet, 0x04, "multi: first cmdSet")
            checkEqual(multiParsed[1].cmdSet, 0x05, "multi: second cmdSet")
            checkEqual(multiParsed[1].payload, Data([0x64]), "multi: second payload")
        }

        // Partial buffering
        let parser3 = DUMLPacketParser()
        let partialPkt = builder.build(cmdSet: 0x04, cmdID: 0x01, payload: Data([0x01, 0x02, 0x03]))
        let mid = partialPkt.count / 2
        let first = parser3.feed(Data(partialPkt[0..<mid]))
        checkEqual(first.count, 0, "partial: no packet yet")
        let second = parser3.feed(Data(partialPkt[mid...]))
        checkEqual(second.count, 1, "partial: packet after rest")
        if let sp = second.first { check(sp.isValid, "partial: valid") }

        // Garbage before SOF
        let parser4 = DUMLPacketParser()
        let garbagePkt = builder.build(cmdSet: 0x04, cmdID: 0x01)
        var withGarbage = Data([0xDE, 0xAD, 0xBE, 0xEF])
        withGarbage.append(garbagePkt)
        let garbageParsed = parser4.feed(withGarbage)
        checkEqual(garbageParsed.count, 1, "garbage: one packet")
        if let gp = garbageParsed.first { check(gp.isValid, "garbage: valid") }

        // Summary
        print("\n" + String(repeating: "=", count: 50))
        print("Results: \(passed) passed, \(failed) failed")
        if failed > 0 {
            print("SOME TESTS FAILED")
            exit(1)
        } else {
            print("ALL TESTS PASSED")
        }
    }
}
