import Foundation

struct GimbalPreset: Codable, Identifiable {
    var id: UUID
    var name: String
    var yaw: Double       // degrees
    var pitch: Double     // degrees
    var roll: Double      // degrees
    var transitionTime: UInt8   // 10ms units; e.g. 20 = 200ms
    var isBuiltIn: Bool

    init(name: String, yaw: Double, pitch: Double, roll: Double = 0,
         transitionTime: UInt8 = 20, isBuiltIn: Bool = false) {
        self.id = UUID()
        self.name = name
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.transitionTime = transitionTime
        self.isBuiltIn = isBuiltIn
    }

    var transitionSeconds: Double { Double(transitionTime) / 100.0 }

    // MARK: - Built-in Templates

    static let templates: [GimbalPreset] = [
        GimbalPreset(name: "Center",      yaw:   0, pitch:  0,  transitionTime: 20, isBuiltIn: true),
        GimbalPreset(name: "Landscape",   yaw:   0, pitch: -8,  transitionTime: 20, isBuiltIn: true),
        GimbalPreset(name: "Look Up",     yaw:   0, pitch:  30, transitionTime: 25, isBuiltIn: true),
        GimbalPreset(name: "Look Down",   yaw:   0, pitch: -30, transitionTime: 25, isBuiltIn: true),
        GimbalPreset(name: "Left 45°",   yaw: -45, pitch:  0,  transitionTime: 20, isBuiltIn: true),
        GimbalPreset(name: "Right 45°",  yaw:  45, pitch:  0,  transitionTime: 20, isBuiltIn: true),
        GimbalPreset(name: "Left 90°",   yaw: -90, pitch:  0,  transitionTime: 30, isBuiltIn: true),
        GimbalPreset(name: "Right 90°",  yaw:  90, pitch:  0,  transitionTime: 30, isBuiltIn: true),
        GimbalPreset(name: "High Angle",  yaw:   0, pitch:  20, transitionTime: 20, isBuiltIn: true),
        GimbalPreset(name: "Low Angle",   yaw:   0, pitch: -20, transitionTime: 20, isBuiltIn: true),
    ]
}
