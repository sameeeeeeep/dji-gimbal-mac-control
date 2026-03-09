import CoreBluetooth

enum BLEConstants {
    static let serviceUUID = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    static let notifyCharacteristicUUID = CBUUID(string: "0000FFF4-0000-1000-8000-00805F9B34FB")
    static let writeCharacteristicUUID = CBUUID(string: "0000FFF5-0000-1000-8000-00805F9B34FB")
}

enum BLEConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting
    case discoveringServices
    case ready
    case error(String)

    var isConnected: Bool {
        if case .ready = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning..."
        case .connecting: return "Connecting..."
        case .discoveringServices: return "Setting up..."
        case .ready: return "Connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

struct DiscoveredGimbal: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int
    let peripheral: CBPeripheral

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.rssi == rhs.rssi
    }
}

/// Represents a discovered BLE characteristic for UI display and alternative writes
struct DiscoveredCharacteristic: Identifiable, Equatable {
    let id: String // "serviceUUID/charUUID" composite
    let serviceUUID: String
    let characteristicUUID: String
    let properties: String // Human-readable property flags
    let isNotify: Bool
    let isWrite: Bool
    let isWriteNoResponse: Bool
    let isRead: Bool
}
