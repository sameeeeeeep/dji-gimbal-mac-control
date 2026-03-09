import SwiftUI

struct ConnectionView: View {
    @ObservedObject var gimbal: GimbalService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Circle()
                    .fill(stateColor)
                    .frame(width: 10, height: 10)
                Text(gimbal.state.connectionState.statusText)
                    .font(.headline)
                Spacer()
            }

            Divider()

            switch gimbal.state.connectionState {
            case .disconnected, .error:
                Button("Scan for Gimbals") {
                    gimbal.startScan()
                }
                .buttonStyle(.borderedProminent)

                if case .error(let msg) = gimbal.state.connectionState {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

            case .scanning:
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Scanning...")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { gimbal.stopScan() }
                }

                if gimbal.state.discoveredDevices.isEmpty {
                    Text("No gimbals found yet. Make sure your DJI OM is powered on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    deviceList
                }

            case .connecting, .discoveringServices:
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Connecting...")
                }

            case .ready:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    HStack {
                        BatteryStatusView(battery: gimbal.state.battery)
                        Spacer()
                        Button("Disconnect") {
                            gimbal.disconnect()
                        }
                        .foregroundStyle(.red)
                    }
                }
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 300)
    }

    private var deviceList: some View {
        List(gimbal.state.discoveredDevices) { device in
            HStack {
                VStack(alignment: .leading) {
                    Text(device.name)
                        .font(.body.weight(.medium))
                    Text("RSSI: \(device.rssi) dBm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Connect") {
                    gimbal.connect(to: device)
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
        .listStyle(.inset)
        .frame(minHeight: 150)
    }

    private var stateColor: Color {
        switch gimbal.state.connectionState {
        case .ready: return .green
        case .scanning, .connecting, .discoveringServices: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }
}
