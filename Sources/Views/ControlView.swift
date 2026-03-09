import SwiftUI

struct ControlView: View {
    @ObservedObject var gimbal: GimbalService

    @State private var rollValue: Double = 0
    @State private var speedMultiplier: Double = 1.0

    private var isConnected: Bool {
        gimbal.state.connectionState.isConnected
    }

    var body: some View {
        if !isConnected {
            ContentUnavailableView(
                "Not Connected",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("Connect to a gimbal first using the Connection tab.")
            )
        } else {
            HStack(spacing: 0) {
                // Left: Controls
                controlPanel
                    .frame(minWidth: 350)

                Divider()

                // Right: Status sidebar
                statusSidebar
                    .frame(width: 220)
            }
        }
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        VStack(spacing: 24) {
            Text("Gimbal Control")
                .font(.title2.weight(.semibold))

            HStack(spacing: 32) {
                // Pan/Tilt joystick — continuous speed commands at 30Hz
                JoystickView(label: "Pan / Tilt") { dx, dy in
                    let yawSpeed = dx * 100.0 * speedMultiplier
                    let pitchSpeed = dy * 100.0 * speedMultiplier
                    gimbal.setSpeed(yaw: yawSpeed, pitch: pitchSpeed, roll: 0)
                }

                // Roll control
                VStack(spacing: 8) {
                    Text("Roll")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Slider(value: $rollValue, in: -45...45)
                        .frame(width: 140)
                        .onChange(of: rollValue) { _, newVal in
                            gimbal.setSpeed(yaw: 0, pitch: 0, roll: newVal * 5)
                        }

                    Text(String(format: "%.1f\u{00B0}", rollValue))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Speed multiplier
            HStack {
                Text("Speed")
                    .font(.caption)
                Slider(value: $speedMultiplier, in: 0.1...3.0)
                    .frame(width: 120)
                Text(String(format: "%.1fx", speedMultiplier))
                    .font(.caption.monospacedDigit())
                    .frame(width: 35, alignment: .trailing)
            }
            .foregroundStyle(.secondary)

            Divider()

            // Quick actions
            HStack(spacing: 12) {
                Button {
                    gimbal.recenter()
                    rollValue = 0
                } label: {
                    Label("Recenter", systemImage: "scope")
                }
                .buttonStyle(.bordered)

                ForEach(GimbalMode.allCases) { mode in
                    Button {
                        gimbal.setMode(mode)
                    } label: {
                        Text(mode.rawValue)
                    }
                    .buttonStyle(.bordered)
                    .tint(gimbal.state.currentMode == mode ? .accentColor : .secondary)
                }
            }

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Status Sidebar

    private var statusSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Battery
            GroupBox("Battery") {
                BatteryStatusView(battery: gimbal.state.battery)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Position
            GroupBox("Position") {
                VStack(alignment: .leading, spacing: 4) {
                    positionRow("Yaw", value: gimbal.state.currentPosition.yaw)
                    positionRow("Pitch", value: gimbal.state.currentPosition.pitch)
                    positionRow("Roll", value: gimbal.state.currentPosition.roll)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Mode
            GroupBox("Mode") {
                Text(gimbal.state.currentMode.rawValue)
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Motor
            GroupBox("Motor") {
                Toggle("Enabled", isOn: Binding(
                    get: { gimbal.state.isMotorOn },
                    set: { gimbal.setMotorState(on: $0) }
                ))
            }

            Spacer()
        }
        .padding()
    }

    private func positionRow(_ label: String, value: Double) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(String(format: "%.1f\u{00B0}", value))
                .font(.system(.caption, design: .monospaced))
        }
    }
}
