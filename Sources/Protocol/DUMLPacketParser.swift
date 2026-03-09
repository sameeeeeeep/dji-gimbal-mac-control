import Foundation

/// Reassembles and parses inbound DUML packets from BLE notification data.
///
/// BLE notifications may deliver partial packets or multiple packets per notification.
/// This parser buffers incoming data and extracts complete, valid DUML packets.
final class DUMLPacketParser {
    private var buffer = Data()

    /// Feed raw BLE notification data. Returns zero or more parsed packets.
    func feed(_ data: Data) -> [DUMLPacket] {
        buffer.append(data)
        var packets: [DUMLPacket] = []

        while let packet = tryParse() {
            packets.append(packet)
        }

        return packets
    }

    /// Clears the internal buffer (e.g., on disconnect).
    func reset() {
        buffer.removeAll()
    }

    // MARK: - Private

    private func tryParse() -> DUMLPacket? {
        // Find SOF byte (0x55)
        guard let sofIndex = buffer.firstIndex(of: DUMLConstants.sof) else {
            buffer.removeAll()
            return nil
        }

        // Discard bytes before SOF
        if sofIndex > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<sofIndex)
        }

        // Need at least 4 bytes for header (SOF + len/ver + CRC8)
        guard buffer.count >= 4 else { return nil }

        // Extract length (10 bits from bytes 1-2)
        let lengthRaw = UInt16(buffer[buffer.startIndex + 1])
            | (UInt16(buffer[buffer.startIndex + 2] & 0x03) << 8)

        // Minimum valid packet is 13 bytes
        guard lengthRaw >= 13, lengthRaw <= 1023 else {
            buffer.removeFirst() // corrupt SOF, skip it
            return nil
        }

        // Wait for full packet to arrive
        guard buffer.count >= Int(lengthRaw) else { return nil }

        // Extract the complete packet data
        let packetData = Data(buffer.prefix(Int(lengthRaw)))
        buffer.removeFirst(Int(lengthRaw))

        // Parse fields
        return parsePacket(packetData)
    }

    private func parsePacket(_ data: Data) -> DUMLPacket? {
        guard data.count >= 13 else { return nil }

        let length = UInt16(data[0 + 1]) | (UInt16(data[0 + 2] & 0x03) << 8)
        let version = (data[0 + 2] >> 2) & 0x3F

        // Sender byte: index in bits 5-7, type in bits 0-4
        let senderByte = data[4]
        let senderType = senderByte & 0x1F
        let senderIndex = (senderByte >> 5) & 0x07

        // Receiver byte: index in bits 5-7, type in bits 0-4
        let receiverByte = data[5]
        let receiverType = receiverByte & 0x1F
        let receiverIndex = (receiverByte >> 5) & 0x07

        // Sequence (little-endian)
        let sequence = UInt16(data[6]) | (UInt16(data[7]) << 8)

        // Command type / attribute
        let cmdType = data[8]

        // Command set + ID
        let cmdSet = data[9]
        let cmdID = data[10]

        // Payload: bytes 11 to (length - 3), i.e., everything between cmdID and CRC-16
        let payloadStart = 11
        let payloadEnd = Int(length) - 2
        let payload: Data
        if payloadEnd > payloadStart {
            payload = Data(data[payloadStart..<payloadEnd])
        } else {
            payload = Data()
        }

        // CRC-16 (last 2 bytes, little-endian)
        let crc16 = UInt16(data[Int(length) - 2]) | (UInt16(data[Int(length) - 1]) << 8)

        return DUMLPacket(
            rawData: data,
            length: length,
            protocolVersion: version,
            senderType: senderType,
            senderIndex: senderIndex,
            receiverType: receiverType,
            receiverIndex: receiverIndex,
            sequence: sequence,
            cmdType: cmdType,
            cmdSet: cmdSet,
            cmdID: cmdID,
            payload: payload,
            crc16: crc16
        )
    }
}
