import SwiftUI

struct BatteryStatusView: View {
    let battery: BatteryStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
            Text("\(battery.level)%")
                .font(.system(.body, design: .monospaced))
        }
        .foregroundColor(batteryColor)
    }

    private var iconName: String {
        if battery.isCharging {
            return "battery.100.bolt"
        }
        switch battery.level {
        case 0..<13:  return "battery.0"
        case 13..<38: return "battery.25"
        case 38..<63: return "battery.50"
        case 63..<88: return "battery.75"
        default:      return "battery.100"
        }
    }

    private var batteryColor: Color {
        if battery.isCharging { return .green }
        if battery.level < 20 { return .red }
        if battery.level < 40 { return .orange }
        return .primary
    }
}
