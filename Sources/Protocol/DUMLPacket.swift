import Foundation

/// A parsed DUML packet.
struct DUMLPacket {
    let rawData: Data
    let length: UInt16
    let protocolVersion: UInt8
    let senderType: UInt8
    let senderIndex: UInt8
    let receiverType: UInt8
    let receiverIndex: UInt8
    let sequence: UInt16
    let cmdType: UInt8
    let cmdSet: UInt8
    let cmdID: UInt8
    let payload: Data
    let crc16: UInt16

    /// Validates both CRC-8 (header) and CRC-16 (full packet).
    var isValid: Bool {
        guard rawData.count >= 13 else { return false }

        // Validate CRC-8 over bytes 0..2
        let headerBytes = Data(rawData[0..<3])
        let expectedCRC8 = CRC8.compute(headerBytes)
        guard rawData[3] == expectedCRC8 else { return false }

        // Validate CRC-16 over all bytes except final 2
        let bodyBytes = Data(rawData[0..<(rawData.count - 2)])
        let expectedCRC16 = CRC16.compute(bodyBytes)
        guard crc16 == expectedCRC16 else { return false }

        return true
    }
}

extension DUMLPacket: CustomStringConvertible {
    var description: String {
        let cmdSetHex = String(format: "0x%02X", cmdSet)
        let cmdIDHex = String(format: "0x%02X", cmdID)
        let payloadHex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        return "DUML[len=\(length) sender=\(senderType):\(senderIndex) recv=\(receiverType):\(receiverIndex) seq=\(sequence) set=\(cmdSetHex) id=\(cmdIDHex) payload=\(payloadHex)]"
    }
}
