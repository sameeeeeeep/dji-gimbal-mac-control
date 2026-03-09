import Foundation

/// Builds outbound DUML binary packets.
final class DUMLPacketBuilder {
    private var sequenceCounter: UInt16 = 0

    /// Builds a complete DUML packet ready for BLE transmission.
    ///
    /// Packet layout (13 + payload.count bytes total):
    /// ```
    /// [0]      SOF (0x55)
    /// [1-2]    Length (10 bits) | Version (6 bits)
    /// [3]      CRC-8 of bytes 0..2
    /// [4]      Sender: index (bits 5-7) | type (bits 0-4)
    /// [5]      Receiver: index (bits 5-7) | type (bits 0-4)
    /// [6-7]    Sequence number (little-endian)
    /// [8]      Command type / attribute flags
    /// [9]      Command set
    /// [10]     Command ID
    /// [11..N-2] Payload
    /// [N-1..N]  CRC-16 of bytes 0..N-2 (little-endian)
    /// ```
    func build(
        senderType: UInt8 = DUMLConstants.DeviceType.mobileApp.rawValue,
        senderIndex: UInt8 = 0x00,
        receiverType: UInt8 = DUMLConstants.DeviceType.gimbal.rawValue,
        receiverIndex: UInt8 = 0x00,
        cmdType: UInt8 = DUMLConstants.CmdType.request.rawValue,
        cmdSet: UInt8,
        cmdID: UInt8,
        payload: Data = Data()
    ) -> Data {
        let totalLength = 13 + payload.count
        var bytes = [UInt8]()
        bytes.reserveCapacity(totalLength)

        // SOF
        bytes.append(DUMLConstants.sof)

        // Length (10 bits) + Version (6 bits, version=1 in bits 10-11)
        let lengthLow = UInt8(totalLength & 0xFF)
        let lengthHigh = UInt8((totalLength >> 8) & 0x03) | (0x01 << 2) // version=1
        bytes.append(lengthLow)
        bytes.append(lengthHigh)

        // CRC-8 over bytes 0..2
        let headerCRC = CRC8.compute(bytes)
        bytes.append(headerCRC)

        // Sender: index in bits 5-7, type in bits 0-4
        bytes.append((senderIndex << 5) | (senderType & 0x1F))

        // Receiver: index in bits 5-7, type in bits 0-4
        bytes.append((receiverIndex << 5) | (receiverType & 0x1F))

        // Sequence (little-endian)
        let seq = sequenceCounter
        sequenceCounter &+= 1
        bytes.append(UInt8(seq & 0xFF))
        bytes.append(UInt8((seq >> 8) & 0xFF))

        // Command type / attribute byte
        bytes.append(cmdType)

        // Command set + ID
        bytes.append(cmdSet)
        bytes.append(cmdID)

        // Payload
        bytes.append(contentsOf: payload)

        // CRC-16 over entire packet so far (little-endian)
        let crc = CRC16.compute(bytes)
        bytes.append(UInt8(crc & 0xFF))
        bytes.append(UInt8((crc >> 8) & 0xFF))

        return Data(bytes)
    }

    /// Resets the sequence counter (e.g., on reconnect).
    func resetSequence() {
        sequenceCounter = 0
    }
}
