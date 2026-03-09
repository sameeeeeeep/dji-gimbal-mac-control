import SwiftUI

struct SettingsView: View {
    @ObservedObject var gimbal: GimbalService

    private var isConnected: Bool {
        gimbal.state.connectionState.isConnected
    }

    var body: some View {
        if !isConnected {
            ContentUnavailableView(
                "Not Connected",
                systemImage: "gearshape",
                description: Text("Connect to a gimbal to access settings.")
            )
        } else {
            ScrollView {
                Form {
                    Section("Motor Control") {
                        Toggle("Motors Enabled", isOn: Binding(
                            get: { gimbal.state.isMotorOn },
                            set: { gimbal.setMotorState(on: $0) }
                        ))
                    }

                    Section("Calibration") {
                        HStack {
                            Button("Start Auto-Calibration") {
                                gimbal.startCalibration()
                            }
                            .disabled(gimbal.state.calibration != .idle)

                            Spacer()

                            calibrationStatus
                        }

                        Text("Place the gimbal on a flat surface before calibrating.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // MARK: - BLE Transport Debug

                    Section("BLE Transport") {
                        HStack {
                            Text("Write Type:")
                                .font(.caption)
                            Text(gimbal.writeTypeDescription)
                                .font(.caption.weight(.medium))
                            Spacer()
                            Button("Toggle") {
                                gimbal.toggleWriteType()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text("Motor toggle works → BLE transport OK. Trying alternative write modes to debug rotation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // MARK: - Exact om-research Packet

                    Section("Exact om-research Packet") {
                        Text("Sends byte-identical packet to om-research Python (yaw=1500, SPEED mode). Bypasses our packet builder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Send Exact om-research Rotation") {
                            gimbal.sendExactOMResearchRotation(yaw: 1500)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        HStack {
                            Button("yaw = -1500") {
                                gimbal.sendExactOMResearchRotation(yaw: -1500)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("yaw = 500") {
                                gimbal.sendExactOMResearchRotation(yaw: 500)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Send 10x rapid") {
                                // Simulate om-research's loop
                                for _ in 0..<10 {
                                    gimbal.sendExactOMResearchRotation(yaw: 1500)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    // MARK: - Protocol Discovery

                    Section("Protocol Discovery") {
                        Text("Brute-force cmdSet/cmdID combos (yaw=1500).")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Probe Next Command") {
                            gimbal.probeNextCommand()
                        }
                        .buttonStyle(.borderedProminent)

                        Text("Probe \(gimbal.state.probeIndex) / 10")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    // MARK: - BLE Profile

                    Section("BLE Profile (\(gimbal.state.bleCharacteristics.count) characteristics)") {
                        if gimbal.state.bleCharacteristics.isEmpty {
                            Text("Discovering...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(gimbal.state.bleCharacteristics) { char in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(char.characteristicUUID)
                                            .font(.system(.caption, design: .monospaced))
                                            .fontWeight(.medium)
                                        Text("[\(char.properties)]")
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("Service: \(char.serviceUUID)")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)

                                    if char.isWrite || char.isWriteNoResponse {
                                        Button("Send rotation to this char") {
                                            gimbal.sendExactOMResearchToChar(char.characteristicUUID, yaw: 1500)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                        .tint(.purple)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    // MARK: - Debug Log

                    Section("Debug Log (\(gimbal.state.packetLog.count) entries)") {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(gimbal.state.packetLog.enumerated()), id: \.offset) { _, entry in
                                    Text(entry)
                                        .font(.system(.caption2, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(minHeight: 300)

                        if !gimbal.state.packetLog.isEmpty {
                            Button("Clear Log") {
                                gimbal.state.packetLog.removeAll()
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .padding()
        }
    }

    @ViewBuilder
    private var calibrationStatus: some View {
        switch gimbal.state.calibration {
        case .idle:
            EmptyView()
        case .inProgress(let progress):
            HStack {
                ProgressView(value: Double(progress), total: 100)
                    .frame(width: 100)
                Text("\(progress)%")
                    .font(.caption.monospacedDigit())
            }
        case .completed:
            Label("Done", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }
}
