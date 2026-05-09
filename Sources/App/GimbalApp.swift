import SwiftUI

@main
struct GimbalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var gimbalService  = GimbalService()
    @StateObject private var presetsManager = PresetsManager()

    var body: some Scene {
        WindowGroup("Gimbal Controller") {
            TrackingView(
                gimbal:  gimbalService,
                tracker: gimbalService.cameraTracker,
                presets: presetsManager
            )
            .frame(minWidth: 760, minHeight: 540)
        }
        .windowResizability(.contentSize)
    }
}
