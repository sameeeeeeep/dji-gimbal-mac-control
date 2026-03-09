import SwiftUI

@main
struct GimbalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var gimbalService = GimbalService()

    var body: some Scene {
        WindowGroup("Gimbal Controller") {
            NavigationSplitView {
                List {
                    NavigationLink {
                        ConnectionView(gimbal: gimbalService)
                    } label: {
                        Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }

                    NavigationLink {
                        ControlView(gimbal: gimbalService)
                    } label: {
                        Label("Control", systemImage: "gamecontroller")
                    }

                    NavigationLink {
                        TrackingView(gimbal: gimbalService, tracker: gimbalService.cameraTracker)
                    } label: {
                        Label("Tracking", systemImage: "camera.fill")
                    }

                    NavigationLink {
                        SettingsView(gimbal: gimbalService)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 180)
            } detail: {
                ControlView(gimbal: gimbalService)
            }
            .frame(minWidth: 700, minHeight: 450)
            .toolbar {
                ToolbarItem(placement: .status) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(gimbalService.state.connectionState.statusText)
                            .font(.caption)
                        if gimbalService.state.connectionState.isConnected {
                            BatteryStatusView(battery: gimbalService.state.battery)
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var statusColor: Color {
        switch gimbalService.state.connectionState {
        case .ready: return .green
        case .scanning, .connecting, .discoveringServices: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }
}
