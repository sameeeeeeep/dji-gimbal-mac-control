import Foundation

enum GimbalMode: String, CaseIterable, Identifiable {
    case follow = "Follow"
    case lock   = "Lock"
    case fpv    = "FPV"

    var id: String { rawValue }
}

struct GimbalPosition: Equatable {
    var yaw: Double   = 0  // degrees
    var pitch: Double = 0  // degrees
    var roll: Double  = 0  // degrees
}

struct BatteryStatus: Equatable {
    var level: Int       = 0     // 0-100
    var isCharging: Bool = false
}

enum CalibrationState: Equatable {
    case idle
    case inProgress(progress: Int) // 0-100
    case completed
    case failed(String)
}
