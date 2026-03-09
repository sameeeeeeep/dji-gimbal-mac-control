import SwiftUI

/// Observable state container for all gimbal-related data.
/// Views bind to this to reactively update the UI.
@MainActor
final class GimbalState: ObservableObject {
    @Published var connectionState: BLEConnectionState = .disconnected
    @Published var discoveredDevices: [DiscoveredGimbal] = []
    @Published var currentPosition: GimbalPosition = .init()
    @Published var battery: BatteryStatus = .init()
    @Published var currentMode: GimbalMode = .follow
    @Published var calibration: CalibrationState = .idle
    @Published var isMotorOn: Bool = false
    @Published var lastError: String?
    @Published var packetLog: [String] = [] // Debug log of recent packets
    @Published var bleCharacteristics: [DiscoveredCharacteristic] = []
    var probeIndex: Int = 0
}
