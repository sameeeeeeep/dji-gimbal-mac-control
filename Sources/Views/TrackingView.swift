import SwiftUI
import AVFoundation
import AppKit
import SceneKit

// MARK: - Color hex extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Design tokens

private enum DS {
    static let bg       = Color(hex: "0A0A0A")
    static let surface  = Color(hex: "111111")
    static let surface2 = Color(hex: "0D0D0D")
    static let yellow   = Color(hex: "FFE500")
    static let green    = Color(hex: "39FF14")
    static let cyan     = Color(hex: "00FFFF")
    static let orange   = Color(hex: "FF6B2B")
    static let purple   = Color(hex: "C77DFF")
    static let border   = Color(hex: "FFE500").opacity(0.25)
    static let divider  = Color(hex: "FFE500").opacity(0.18)

    static func modeColor(_ mode: ObservationMode) -> Color {
        switch mode {
        case .shot:     return cyan
        case .presence: return purple
        case .moment:   return orange
        }
    }
}

// MARK: - Root view

/// Tab kinds rendered inside the OperatorSidebar's swappable middle pane.
private enum SidebarTab: String, CaseIterable {
    case ai      = "AI"
    case connect = "CONNECT"
    case presets = "PRESETS"
    case manual  = "MANUAL"

    var icon: String {
        switch self {
        case .ai:      return "sparkles"
        case .connect: return "antenna.radiowaves.left.and.right"
        case .presets: return "bookmark.fill"
        case .manual:  return "gamecontroller.fill"
        }
    }
}

struct TrackingView: View {
    @ObservedObject var gimbal:  GimbalService
    @ObservedObject var tracker: CameraTracker
    @ObservedObject var presets: PresetsManager
    @State private var selectedTab: SidebarTab = .ai

    var body: some View {
        HStack(alignment: .top, spacing: 0) {

            // ── Left column: pure visual — stream + dynamic canvas ───
            VStack(spacing: 0) {
                StreamPane(gimbal: gimbal, tracker: tracker)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Rectangle().fill(DS.divider).frame(height: 1)

                DynamicCanvas(gimbal: gimbal, tracker: tracker)
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 220)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(DS.yellow).frame(width: 1)

            // ── Right column: full operator console ──────────────────
            OperatorSidebar(
                gimbal:  gimbal,
                tracker: tracker,
                presets: presets,
                selectedTab: $selectedTab
            )
            .frame(width: 300)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 720, minHeight: 540)
        .background(DS.bg)
        .onAppear {
            tracker.onSpeedCommand = { [weak gimbal] yaw, pitch in
                gimbal?.setSpeed(yaw: yaw, pitch: pitch, roll: 0)
            }
            tracker.claudeAgent.connect(gimbal: gimbal, tracker: tracker)
        }
    }
}

// MARK: - Operator sidebar (status + tabbed middle + always-on controls)

private struct OperatorSidebar: View {
    @ObservedObject var gimbal:  GimbalService
    @ObservedObject var tracker: CameraTracker
    @ObservedObject var presets: PresetsManager
    @Binding var selectedTab: SidebarTab

    var body: some View {
        VStack(spacing: 0) {
            StatusBar(gimbal: gimbal, tracker: tracker)
                .frame(height: 42)
            Rectangle().fill(DS.divider).frame(height: 1)

            // Tab strip — switches the swappable pane below
            TabStrip(selected: $selectedTab)
                .frame(height: 32)
            Rectangle().fill(DS.divider).frame(height: 1)

            // Swappable pane: content depends on selected tab
            Group {
                switch selectedTab {
                case .ai:      AIPane(tracker: tracker)
                case .connect: ConnectPane(gimbal: gimbal)
                case .presets: PresetsPane(gimbal: gimbal, presets: presets)
                case .manual:  ManualPane(gimbal: gimbal)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(DS.divider).frame(height: 1)

            // ── Always-on controls (these stay visible in every tab) ──
            FollowButton(gimbal: gimbal, tracker: tracker)
                .frame(height: 56)
            Rectangle().fill(DS.divider).frame(height: 1)

            QuickActions(gimbal: gimbal, tracker: tracker)
                .frame(height: 44)
            Rectangle().fill(DS.divider.opacity(0.6)).frame(height: 1)

            CaptureRow(tracker: tracker)
                .frame(height: 40)
        }
    }
}

// MARK: - Tab strip

private struct TabStrip: View {
    @Binding var selected: SidebarTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SidebarTab.allCases, id: \.self) { tab in
                Button { selected = tab } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11))
                        Text(tab.rawValue)
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(1)
                    }
                    .foregroundColor(selected == tab ? .black : .white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(selected == tab ? DS.yellow : DS.surface2)
                    .overlay(
                        Rectangle()
                            .fill(DS.yellow)
                            .frame(height: 2)
                            .opacity(selected == tab ? 1 : 0),
                        alignment: .top
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(DS.surface2)
    }
}

// MARK: - AI pane (the existing InsightCard + CommandBox stack)

private struct AIPane: View {
    @ObservedObject var tracker: CameraTracker

    var body: some View {
        VStack(spacing: 0) {
            InsightCard(tracker: tracker)
                .frame(minHeight: 200, maxHeight: 260)
            Rectangle().fill(DS.divider).frame(height: 1)
            PipelinePanel(journal: tracker.journalAnalyzer)
            Rectangle().fill(DS.divider).frame(height: 1)
            CommandBox(tracker: tracker)
                .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Pipeline panel (collapsible: ring buffer → grid → in-flight → beat)

private struct PipelinePanel: View {
    @ObservedObject var journal: JournalAnalyzer
    @State private var expanded: Bool = false
    /// Drives elapsed-time text while a request is in-flight.
    @State private var tick: Date = Date()
    private let pulse = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible, collapses/expands the body
            Button(action: { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.white.opacity(0.6))
                    Text("PIPELINE")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    if journal.inflightStartedAt != nil {
                        Circle().fill(DS.yellow).frame(width: 5, height: 5)
                        Text("ANALYZING")
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .foregroundColor(DS.yellow)
                    } else if journal.isAnalyzing {
                        Circle().fill(DS.green).frame(width: 5, height: 5)
                        Text("IDLE")
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                pipelineBody
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
            }
        }
        .background(DS.surface2)
        .onReceive(pulse) { now in
            // Only force redraws while a request is in-flight (saves CPU when idle)
            if journal.inflightStartedAt != nil { tick = now }
        }
    }

    @ViewBuilder
    private var pipelineBody: some View {
        HStack(alignment: .center, spacing: 8) {
            bufferStage
            arrow
            gridStage
            arrow
            inflightStage
            arrow
            beatStage
        }
    }

    // ── Stage 1: ring buffer thumbnails (oldest → newest)
    private var bufferStage: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("BUFFER")
                .font(.system(size: 6, weight: .black, design: .monospaced))
                .tracking(1).foregroundColor(.white.opacity(0.4))
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { idx in
                    bufferCell(at: idx)
                }
            }
        }
    }

    @ViewBuilder
    private func bufferCell(at idx: Int) -> some View {
        let thumbs = journal.bufferThumbs
        let isNewest = !thumbs.isEmpty && idx == thumbs.count - 1
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.04))
                .frame(width: 28, height: 18)
            if idx < thumbs.count {
                Image(decorative: thumbs[idx], scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 18)
                    .clipped()
            }
            Rectangle()
                .stroke(isNewest ? DS.yellow.opacity(0.9) : Color.white.opacity(0.1),
                        lineWidth: isNewest ? 1.2 : 0.5)
                .frame(width: 28, height: 18)
        }
        .scaleEffect(isNewest ? 1.04 : 1.0)
        .animation(.easeOut(duration: 0.18), value: thumbs.count)
    }

    // ── Stage 2: composed grid preview (the next-to-send 2×2)
    private var gridStage: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("GRID")
                .font(.system(size: 6, weight: .black, design: .monospaced))
                .tracking(1).foregroundColor(.white.opacity(0.4))
            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .frame(width: 56, height: 36)
                if let g = nextGridPreview {
                    Image(decorative: g, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 36)
                }
                Rectangle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    .frame(width: 56, height: 36)
            }
        }
    }

    /// The grid that *would* be sent right now if a beat fired. Shows what's
    /// being assembled in parallel even while a previous request is in-flight.
    private var nextGridPreview: CGImage? {
        let buffer = journal.bufferThumbs
        guard buffer.count >= 2 else { return nil }
        let pairs = buffer.map { (image: $0, timestamp: Date()) }
        return JournalAnalyzer.composeTemporalGrid(buffer: pairs)
    }

    // ── Stage 3: in-flight request
    private var inflightStage: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("VLM")
                .font(.system(size: 6, weight: .black, design: .monospaced))
                .tracking(1).foregroundColor(.white.opacity(0.4))
            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .frame(width: 56, height: 36)
                if let g = journal.inflightGrid {
                    Image(decorative: g, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 36)
                        .opacity(0.55)
                    // Spinner + elapsed
                    VStack(spacing: 1) {
                        ProgressView()
                            .scaleEffect(0.45)
                            .progressViewStyle(.circular)
                            .tint(DS.yellow)
                        Text(elapsedText)
                            .font(.system(size: 6, weight: .black, design: .monospaced))
                            .foregroundColor(DS.yellow)
                    }
                } else {
                    Text("—")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundColor(.white.opacity(0.2))
                }
                Rectangle()
                    .stroke(journal.inflightGrid != nil ? DS.yellow.opacity(0.6) : Color.white.opacity(0.1),
                            lineWidth: journal.inflightGrid != nil ? 1.0 : 0.5)
                    .frame(width: 56, height: 36)
            }
        }
    }

    private var elapsedText: String {
        guard let s = journal.inflightStartedAt else { return "" }
        let dt = max(0, tick.timeIntervalSince(s))
        return String(format: "%.1fs", dt)
    }

    // ── Stage 4: latest beat
    private var beatStage: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("BEAT")
                .font(.system(size: 6, weight: .black, design: .monospaced))
                .tracking(1).foregroundColor(.white.opacity(0.4))
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
                if let beat = journal.latestBeat {
                    Text(beat.sentence)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(3)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                } else {
                    Text("—")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundColor(.white.opacity(0.2))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                }
                Rectangle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            }
            .frame(height: 36)
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white.opacity(0.25))
            .padding(.top, 12)
    }
}

// MARK: - Connect pane (BLE scan + connect)

private struct ConnectPane: View {
    @ObservedObject var gimbal: GimbalService

    var body: some View {
        VStack(spacing: 0) {
            // Status header
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(gimbal.state.connectionState.statusText.uppercased())
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1)
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                if gimbal.state.connectionState.isConnected {
                    BatteryStatusView(battery: gimbal.state.battery)
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(DS.surface2)

            // Scan + device list
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if case .scanning = gimbal.state.connectionState {
                        Button("STOP SCAN") { gimbal.stopScan() }
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.orange)
                            .buttonStyle(.plain)
                    } else if gimbal.state.connectionState.isConnected {
                        Button("DISCONNECT") { gimbal.disconnect() }
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.orange)
                            .buttonStyle(.plain)
                    } else {
                        Button("SCAN") { gimbal.startScan() }
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(DS.yellow)
                            .buttonStyle(.plain)
                            .disabled(gimbal.isSimulator)
                            .opacity(gimbal.isSimulator ? 0.4 : 1)
                    }
                    if gimbal.isSimulator {
                        Text("SIM ON — toggle off in ⚙ first")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(DS.purple.opacity(0.8))
                    }
                    Spacer()
                }

                Text("DISCOVERED")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.white.opacity(0.4))

                if gimbal.state.discoveredDevices.isEmpty {
                    Text("(no devices yet — tap SCAN)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(gimbal.state.discoveredDevices) { dev in
                                Button { gimbal.connect(to: dev) } label: {
                                    HStack {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                            .font(.system(size: 11))
                                        Text(dev.name)
                                            .font(.system(size: 11, design: .monospaced))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(dev.rssi) dBm")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.4))
                                    }
                                    .foregroundColor(.white.opacity(0.85))
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(DS.surface)
                                    .overlay(Rectangle().stroke(DS.divider, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DS.bg)
        }
    }

    private var statusColor: Color {
        switch gimbal.state.connectionState {
        case .ready: return DS.green
        case .scanning, .connecting, .discoveringServices: return Color.orange
        case .error: return Color.red
        case .disconnected: return Color.white.opacity(0.3)
        }
    }
}

// MARK: - Presets pane

private struct PresetsPane: View {
    @ObservedObject var gimbal:  GimbalService
    @ObservedObject var presets: PresetsManager
    @State private var newName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Save current position bar
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundColor(DS.yellow.opacity(0.7))
                TextField("name…", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .onSubmit(savePreset)
                Button("SAVE") { savePreset() }
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(newName.isEmpty ? DS.yellow.opacity(0.3) : DS.yellow)
                    .buttonStyle(.plain)
                    .disabled(newName.isEmpty)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(DS.surface2)
            Rectangle().fill(DS.divider).frame(height: 1)

            // Preset list
            if presets.allPresets.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.12))
                    Text("NO PRESETS YET")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(.white.opacity(0.3))
                    Text("Save the current gimbal position above.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.25))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.bg)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(presets.allPresets) { preset in
                            HStack {
                                Image(systemName: preset.isBuiltIn ? "bookmark" : "bookmark.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(preset.isBuiltIn ? .white.opacity(0.4) : DS.cyan.opacity(0.7))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(preset.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white.opacity(0.9))
                                    Text(String(format: "%+.0f°, %+.0f°", preset.yaw, preset.pitch))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                                Spacer()
                                Button {
                                    gimbal.absoluteRotate(yaw: preset.yaw, pitch: preset.pitch, time: preset.transitionTime)
                                } label: {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .font(.system(size: 17))
                                        .foregroundColor(DS.cyan)
                                }
                                .buttonStyle(.plain)
                                .disabled(!gimbal.state.connectionState.isConnected)
                                .opacity(gimbal.state.connectionState.isConnected ? 1 : 0.3)
                                .help("Go to preset")
                                if !preset.isBuiltIn {
                                    Button { presets.delete(preset) } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.35))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete")
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(DS.surface)
                            .overlay(Rectangle().fill(DS.divider).frame(height: 1), alignment: .bottom)
                        }
                    }
                }
                .background(DS.bg)
            }
        }
    }

    private func savePreset() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pos = gimbal.state.currentPosition
        presets.savePosition(name: trimmed, yaw: pos.yaw, pitch: pos.pitch, roll: pos.roll)
        newName = ""
    }
}

// MARK: - Manual pane (direct controls + joystick)

private struct ManualPane: View {
    @ObservedObject var gimbal: GimbalService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Recenter row
            HStack(spacing: 8) {
                Button {
                    gimbal.recenter()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "scope").font(.system(size: 13))
                        Text("RECENTER")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(1)
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(DS.yellow)
                }
                .buttonStyle(.plain)
                .disabled(!gimbal.state.connectionState.isConnected)

                Button {
                    gimbal.setSpeed(yaw: 0, pitch: 0, roll: 0)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 13))
                        Text("STOP")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(1)
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(DS.surface)
                    .overlay(Rectangle().stroke(.white.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer()
            }

            // Quick rotation arrows
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Spacer()
                    rotateButton(icon: "arrow.up", deltaYaw: 0, deltaPitch: 15)
                    Spacer()
                }
                HStack(spacing: 4) {
                    rotateButton(icon: "arrow.left",      deltaYaw: -30, deltaPitch: 0)
                    rotateButton(icon: "circle",          deltaYaw: 0,   deltaPitch: 0,
                                 label: "0°", absolute: true)
                    rotateButton(icon: "arrow.right",     deltaYaw: 30,  deltaPitch: 0)
                }
                HStack(spacing: 4) {
                    Spacer()
                    rotateButton(icon: "arrow.down", deltaYaw: 0, deltaPitch: -15)
                    Spacer()
                }
            }

            // Position readout
            VStack(alignment: .leading, spacing: 4) {
                Text("POSITION")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.white.opacity(0.4))
                Text(String(format: "Yaw  %+6.1f°", gimbal.state.currentPosition.yaw))
                    .font(.system(size: 13, design: .monospaced).monospacedDigit())
                    .foregroundColor(DS.yellow)
                Text(String(format: "Pitch %+6.1f°", gimbal.state.currentPosition.pitch))
                    .font(.system(size: 13, design: .monospaced).monospacedDigit())
                    .foregroundColor(DS.yellow)
            }

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.bg)
    }

    @ViewBuilder
    private func rotateButton(
        icon: String, deltaYaw: Double, deltaPitch: Double,
        label: String? = nil, absolute: Bool = false
    ) -> some View {
        Button {
            if absolute {
                gimbal.recenter()
            } else {
                let cur = gimbal.state.currentPosition
                gimbal.absoluteRotate(
                    yaw:   max(-160, min(160, cur.yaw   + deltaYaw)),
                    pitch: max(-35,  min(35,  cur.pitch + deltaPitch)),
                    time:  40
                )
            }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: icon).font(.system(size: 16))
                if let label {
                    Text(label).font(.system(size: 8, design: .monospaced))
                }
            }
            .foregroundColor(.white.opacity(0.85))
            .frame(width: 60, height: 44)
            .background(DS.surface)
            .overlay(Rectangle().stroke(.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!gimbal.state.connectionState.isConnected)
        .opacity(gimbal.state.connectionState.isConnected ? 1 : 0.4)
    }
}

// MARK: - Primary FOLLOW button

private struct FollowButton: View {
    @ObservedObject var gimbal:  GimbalService
    @ObservedObject var tracker: CameraTracker

    var body: some View {
        Button {
            if tracker.isFollowing { tracker.stopFollow() }
            else if gimbal.state.connectionState.isConnected { tracker.startFollow() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tracker.isFollowing ? "viewfinder.circle.fill" : "viewfinder.circle")
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 1) {
                    Text(tracker.isFollowing ? "FOLLOWING" : "FOLLOW")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(2)
                    if tracker.followLocked {
                        Text("LOCKED")
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .foregroundColor(DS.yellow)
                    } else if !tracker.isFollowing {
                        Text(canFollow ? "TAP TO START" : disabledReason)
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundColor(.white.opacity(0.45))
                    }
                }
                Spacer()
                if tracker.isFollowing {
                    // Tappable lock toggle. This is the ONLY way to unlock
                    // once a peace-sign gesture or AI tool has locked follow —
                    // palm gestures intentionally cannot release the lock.
                    Button {
                        tracker.followLocked.toggle()
                    } label: {
                        Image(systemName: tracker.followLocked ? "lock.fill" : "lock.open")
                            .font(.system(size: 13))
                            .foregroundColor(tracker.followLocked ? DS.yellow : .black.opacity(0.45))
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tracker.followLocked ? "Unlock follow" : "Lock follow")
                }
            }
            .foregroundColor(tracker.isFollowing ? .black : DS.cyan)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tracker.isFollowing ? DS.cyan : DS.cyan.opacity(0.08))
            .overlay(Rectangle().stroke(DS.cyan.opacity(tracker.isFollowing ? 0 : 0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!canFollow)
        .opacity(canFollow ? 1 : 0.45)
    }

    private var canFollow: Bool {
        tracker.isRunning && gimbal.state.connectionState.isConnected
            && tracker.roomSweepState != .sweeping
    }

    private var disabledReason: String {
        if !tracker.isRunning                      { return "START CAMERA FIRST" }
        if !gimbal.state.connectionState.isConnected { return "CONNECT GIMBAL" }
        if tracker.roomSweepState == .sweeping     { return "WAIT FOR SCAN" }
        return ""
    }
}

// MARK: - Quick actions row

private struct QuickActions: View {
    @ObservedObject var gimbal:  GimbalService
    @ObservedObject var tracker: CameraTracker
    @ObservedObject private var journal: JournalAnalyzer

    init(gimbal: GimbalService, tracker: CameraTracker) {
        self.gimbal  = gimbal
        self.tracker = tracker
        self.journal = tracker.journalAnalyzer
    }

    var body: some View {
        HStack(spacing: 6) {
            // START / STOP camera
            Button(tracker.isRunning ? "STOP" : "START") {
                if tracker.isRunning { tracker.stopCamera() } else { tracker.startCamera() }
            }
            .font(.system(size: 11, weight: .black, design: .monospaced))
            .tracking(1)
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tracker.isRunning ? Color.orange : DS.yellow)
            .buttonStyle(.plain)

            // ANALYZE
            let runner = journal.runner
            Button {
                if journal.isAnalyzing {
                    journal.stop()
                } else {
                    if !runner.isReady { runner.start() }
                    if runner.isReady {
                        journal.start(tracker: tracker, transcriber: tracker.transcriber)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: journal.isAnalyzing ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 13))
                    Text(journal.isAnalyzing ? "STOP AI" : "ANALYZE")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1)
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(journal.isAnalyzing ? Color.orange : DS.yellow)
            }
            .buttonStyle(.plain)
            .disabled(!tracker.isRunning && !journal.isAnalyzing)
            .opacity(tracker.isRunning || journal.isAnalyzing ? 1 : 0.4)

            // SCAN ROOM
            Button {
                tracker.scanRoom()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: tracker.roomSweepState == .sweeping ? "stop.circle" : "scope")
                        .font(.system(size: 13))
                    Text(tracker.roomSweepState == .sweeping ? "SCANNING" : "SCAN")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1)
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(tracker.roomSweepState == .sweeping ? Color.orange : DS.green)
            }
            .buttonStyle(.plain)
            .disabled(!tracker.isRunning || !gimbal.state.connectionState.isConnected)
            .opacity(tracker.isRunning && gimbal.state.connectionState.isConnected ? 1 : 0.4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(DS.surface2)
    }
}

// MARK: - Capture row (photo / rec / files)

private struct CaptureRow: View {
    @ObservedObject var tracker: CameraTracker

    var body: some View {
        HStack(spacing: 6) {
            // Photo
            Button { tracker.capturePhoto() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "camera").font(.system(size: 13))
                    Text("PHOTO").font(.system(size: 10, weight: .black, design: .monospaced))
                }
                .foregroundColor(.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.surface)
                .overlay(Rectangle().stroke(.white.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!tracker.isRunning)
            .opacity(tracker.isRunning ? 1 : 0.4)

            // Record
            Button {
                if tracker.isRecording { tracker.stopRecording() }
                else                   { tracker.startRecording() }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(tracker.isRecording ? Color.red : .white.opacity(0.7))
                        .frame(width: 9, height: 9)
                    Text(tracker.isRecording ? recLabel : "REC")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .monospacedDigit()
                }
                .foregroundColor(tracker.isRecording ? .white : .white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(tracker.isRecording ? Color.red.opacity(0.35) : DS.surface)
                .overlay(Rectangle().stroke(tracker.isRecording ? Color.red.opacity(0.7) : .white.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!tracker.isRunning || tracker.isTimelapsing)
            .opacity(tracker.isRunning && !tracker.isTimelapsing ? 1 : 0.4)

            // Timelapse
            Button {
                if tracker.isTimelapsing { tracker.stopTimelapse() }
                else                     { tracker.startTimelapse() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: tracker.isTimelapsing ? "stopwatch.fill" : "stopwatch")
                        .font(.system(size: 12))
                    Text(tracker.isTimelapsing ? tlpLabel : "TLP")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .monospacedDigit()
                }
                .foregroundColor(tracker.isTimelapsing ? .black : .white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(tracker.isTimelapsing ? DS.purple : DS.surface)
                .overlay(Rectangle().stroke(tracker.isTimelapsing ? DS.purple : .white.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!tracker.isRunning || tracker.isRecording)
            .opacity(tracker.isRunning && !tracker.isRecording ? 1 : 0.4)
            .help("Capture a timelapse — every \(Int(tracker.timelapseInterval))s")

            // Files menu
            Menu {
                if let url = tracker.lastPhotoURL {
                    Button("Last Photo") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                if let url = tracker.lastVideoURL {
                    Button("Last Video") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Open Captures Folder") { NSWorkspace.shared.open(gimbalCapturesDir) }
                if let path = tracker.journalAnalyzer.currentSessionPath {
                    Button("Open Journal Log") {
                        NSWorkspace.shared.activateFileViewerSelecting([path])
                    }
                }
            } label: {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.65))
                    .frame(maxHeight: .infinity)
                    .frame(width: 46)
                    .background(DS.surface)
                    .overlay(Rectangle().stroke(.white.opacity(0.18), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 46)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(DS.surface2)
    }

    private var recLabel: String {
        let t = Int(tracker.recordingDuration)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Compact label for the active timelapse: shows frame count + elapsed wall time.
    private var tlpLabel: String {
        let f = tracker.timelapseFrameCount
        let t = Int(tracker.timelapseDuration)
        return "\(f)·\(t)s"
    }
}

// MARK: - AI Command box (Claude natural-language control)

private struct CommandBox: View {
    @ObservedObject var tracker: CameraTracker
    @ObservedObject private var agent: ClaudeAgent
    @State private var input: String = ""
    @State private var showHistory: Bool = true
    @FocusState private var inputFocused: Bool

    init(tracker: CameraTracker) {
        self.tracker = tracker
        self.agent   = tracker.claudeAgent
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundColor(agent.isConfigured ? DS.yellow : .white.opacity(0.25))
                Text("COMMAND")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(agent.isConfigured ? DS.yellow : .white.opacity(0.35))
                if agent.isThinking {
                    ProgressView().scaleEffect(0.5).tint(DS.yellow)
                }
                Spacer()
                if !agent.messages.isEmpty {
                    Button { agent.clearHistory() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear chat")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(DS.surface2)

            // Conversation history
            if !agent.isConfigured {
                missingKeyView
            } else if agent.messages.isEmpty {
                emptyHintView
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(agent.messages) { msg in
                                ChatBubble(msg: msg).id(msg.id)
                            }
                            if let err = agent.lastError {
                                Text(err)
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.orange.opacity(0.1))
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(8)
                    }
                    .onChange(of: agent.messages.count) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.bg)
            }

            // Input
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(DS.yellow.opacity(0.7))
                TextField("ask claude to do anything…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .focused($inputFocused)
                    .onSubmit { submit() }
                    .disabled(!agent.isConfigured || agent.isThinking)
                if !input.isEmpty {
                    Button { submit() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(DS.yellow)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(DS.surface)
            .overlay(Rectangle().fill(DS.divider).frame(height: 1), alignment: .top)
        }
    }

    private func submit() {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        agent.send(s)
        input = ""
    }

    @ViewBuilder
    private var missingKeyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                Text("CLAUDE CLI NOT FOUND")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(.orange)
            }
            Text("Install Claude Code, then re-launch this app:")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            Text("npm i -g @anthropic-ai/claude-code")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.yellow)
                .textSelection(.enabled)
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.surface)
            Text("Then run `claude login` in your terminal.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.bg)
    }

    @ViewBuilder
    private var emptyHintView: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("TRY ASKING")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(2)
                .foregroundColor(.white.opacity(0.4))
            ForEach([
                "scan the room, then look at Alice",
                "rotate 30° left and take a photo",
                "follow whoever is talking",
                "lock here, then start recording",
                "what do you see right now?"
            ], id: \.self) { hint in
                Button { input = hint; inputFocused = true } label: {
                    Text("→ \(hint)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DS.yellow.opacity(0.65))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help("Click to fill")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.bg)
    }
}

private struct ChatBubble: View {
    let msg: ChatMessage

    var body: some View {
        switch msg.role {
        case .user:
            HStack(alignment: .top, spacing: 4) {
                Spacer(minLength: 24)
                Text(msg.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(DS.cyan)
                    .frame(maxWidth: 230, alignment: .trailing)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 5) {
                if !msg.toolCalls.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(msg.toolCalls.indices, id: \.self) { i in
                            Text(msg.toolCalls[i])
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .foregroundColor(.black)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(DS.yellow.opacity(0.9))
                        }
                    }
                }
                if !msg.text.isEmpty {
                    Text(msg.text)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .system:
            Text(msg.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(msg.isError ? .orange : .white.opacity(0.5))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(msg.isError ? Color.orange.opacity(0.12) : Color.clear)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Stream pane (top-left)

private struct StreamPane: View {
    @ObservedObject var gimbal:  GimbalService
    @ObservedObject var tracker: CameraTracker
    @ObservedObject private var journal: JournalAnalyzer

    init(gimbal: GimbalService, tracker: CameraTracker) {
        self.gimbal  = gimbal
        self.tracker = tracker
        self.journal = tracker.journalAnalyzer
    }

    var body: some View {
        ZStack {
            // Feed
            if tracker.isRunning {
                CameraPreviewView(tracker: tracker)
            } else {
                Rectangle().fill(Color.black)
                Text("CAMERA OFF")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(3)
                    .foregroundColor(.white.opacity(0.12))
            }

            // Click-to-lock: tap a spot on the feed to lock follow onto the
            // subject closest to that point. Tap again on empty area to clear.
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { loc in
                        let nx = loc.x / max(1, geo.size.width)
                        // SwiftUI tap is top-left origin; Vision bbox is bottom-left.
                        let ny = 1 - (loc.y / max(1, geo.size.height))
                        let p = CGPoint(x: max(0, min(1, nx)), y: max(0, min(1, ny)))
                        // Tap on (or very near) the current lock = clear it.
                        if let cur = tracker.lockedTargetPoint,
                           hypot(cur.x - p.x, cur.y - p.y) < 0.08 {
                            tracker.clearSubjectLock()
                        } else {
                            tracker.aimAt(normalizedPoint: p)
                        }
                    }
            }

            // Subject bboxes
            if !tracker.allSubjects.isEmpty {
                SubjectsOverlayView(subjects: tracker.allSubjects,
                                    isFollowing: tracker.isFollowing,
                                    lockPoint: tracker.lockedTargetPoint)
            } else if let bbox = tracker.detectedBbox {
                SubjectsOverlayView(
                    subjects: [DetectedSubject(bbox: bbox, isSpeaking: false,
                                               isTracked: true, speakerLabel: nil)],
                    isFollowing: tracker.isFollowing,
                    lockPoint: tracker.lockedTargetPoint
                )
            }

            // Observation overlay pill — bottom of feed
            if let beat = journal.latestBeat {
                VStack {
                    Spacer()
                    ObservationOverlay(beat: beat)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }

            // Corner badges — top corners only, minimal
            VStack {
                HStack(alignment: .top) {
                    // Top-left: gesture/lock badges
                    VStack(alignment: .leading, spacing: 3) {
                        if tracker.followLocked {
                            badge("LOCKED", icon: "lock.fill", color: DS.yellow)
                        }
                        if tracker.palmGestureActive {
                            badge("PALM", icon: "hand.raised.fill", color: DS.cyan)
                        }
                        if tracker.pointingGestureActive {
                            badge("POINTING", icon: "hand.point.right.fill", color: DS.purple)
                        }
                    }
                    Spacer()
                    // Top-right: tracking state
                    if tracker.isRunning {
                        let tracked = tracker.detectedBbox != nil || !tracker.allSubjects.isEmpty
                        badge(tracked ? "TRACKING" : "NO SUBJECT",
                              dot: true,
                              color: tracked ? DS.green : .orange)
                    }
                }
                Spacer()
            }
            .padding(7)
        }
    }

    @ViewBuilder
    private func badge(_ text: String, icon: String? = nil, dot: Bool = false, color: Color) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 7)) }
            if dot { Circle().fill(color).frame(width: 5, height: 5) }
            Text(text).font(.system(size: 7, weight: .black, design: .monospaced))
        }
        .foregroundColor(dot ? color : .black)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(dot ? Color.black.opacity(0.65) : color)
        .overlay(dot ? Rectangle().stroke(color, lineWidth: 1) : nil)
    }
}

// MARK: - Dynamic canvas (bottom-left)

/// Contextually shows whatever is most useful right now:
/// - Room sweep in progress  → live splat map
/// - Panorama built           → panorama sphere
/// - Sweep done, no panorama  → static splat map with tap-to-navigate
/// - Camera running, no sweep → live scene labels from journal
/// - Idle                     → dark placeholder

private struct DynamicCanvas: View {
    @ObservedObject var gimbal:   GimbalService
    @ObservedObject var tracker:  CameraTracker
    @ObservedObject private var panorama: PanoramaBuilder
    @ObservedObject private var journal:  JournalAnalyzer

    init(gimbal: GimbalService, tracker: CameraTracker) {
        self.gimbal   = gimbal
        self.tracker  = tracker
        self.panorama = tracker.panoramaBuilder
        self.journal  = tracker.journalAnalyzer
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
            canvasLabel
        }
        .background(DS.surface2)
    }

    @ViewBuilder
    private var content: some View {
        switch canvasMode {
        case .sweeping:
            SplatMapView(
                subjects: tracker.subjectMap,
                currentYaw: gimbal.state.currentPosition.yaw,
                currentPitch: gimbal.state.currentPosition.pitch,
                sweepState: tracker.roomSweepState,
                sweepCurrentYaw: tracker.sweepCurrentYaw,
                sweepCurrentPitch: tracker.sweepCurrentPitch
            )

        case .panorama(let img):
            PanoramaSphereView(
                panorama: img,
                subjects: tracker.subjectMap,
                onTapSubject: { entry in
                    tracker.navigateTo(yaw: entry.approximateYaw, pitch: entry.approximatePitch)
                }
            )
            .overlay(
                Text("DRAG · TAP DOT")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.white.opacity(0.2))
                    .padding(5),
                alignment: .bottomLeading
            )

        case .building:
            PanoramaBuildingView()

        case .splatReady:
            SplatMapView(
                subjects: tracker.subjectMap,
                currentYaw: gimbal.state.currentPosition.yaw,
                currentPitch: gimbal.state.currentPosition.pitch,
                sweepState: tracker.roomSweepState,
                sweepCurrentYaw: tracker.sweepCurrentYaw,
                sweepCurrentPitch: tracker.sweepCurrentPitch,
                onTapSubject: { entry in
                    tracker.navigateTo(yaw: entry.approximateYaw, pitch: entry.approximatePitch)
                }
            )
            .overlay(
                // People tags below the map
                VStack(spacing: 0) {
                    Spacer()
                    ForEach(tracker.subjectMap.indices, id: \.self) { idx in
                        PersonTagRow(
                            entry: tracker.subjectMap[idx],
                            onTap: {
                                tracker.navigateTo(yaw: tracker.subjectMap[idx].approximateYaw,
                                                   pitch: tracker.subjectMap[idx].approximatePitch)
                            },
                            onNameChange: { name in
                                tracker.subjectMap[idx].name = name.isEmpty ? nil : name
                            }
                        )
                        .padding(.horizontal, 8)
                        .background(DS.surface2.opacity(0.9))
                    }
                }
            )

        case .sceneLabels:
            sceneLabelsView

        case .idle:
            idleView
        }
    }

    private enum CanvasMode {
        case sweeping
        case panorama(NSImage)
        case building
        case splatReady
        case sceneLabels
        case idle
    }

    private var canvasMode: CanvasMode {
        if tracker.roomSweepState == .sweeping { return .sweeping }
        if panorama.isBuilding                  { return .building }
        if let img = panorama.panorama           { return .panorama(img) }
        if tracker.roomSweepState == .ready      { return .splatReady }
        if let obs = journal.latestObservation,
           !obs.sceneLabels.isEmpty || !obs.subjects.isEmpty {
            return .sceneLabels
        }
        return .idle
    }

    @ViewBuilder
    private var sceneLabelsView: some View {
        let obs = journal.latestObservation
        VStack(alignment: .leading, spacing: 6) {
            if let obs {
                // People chips
                if !obs.subjects.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 9))
                            .foregroundColor(DS.cyan)
                        Text("\(obs.subjects.count) in frame")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(DS.cyan)
                        if !obs.bodyActivities.isEmpty {
                            Text("·")
                                .foregroundColor(.white.opacity(0.2))
                            Text(obs.bodyActivities.prefix(2).joined(separator: ", "))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                }
                // Scene label chips
                let labels = obs.sceneLabels.prefix(8)
                if !labels.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(labels.indices, id: \.self) { i in
                            let item = labels[i]
                            HStack(spacing: 3) {
                                Text(item.label)
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.65))
                                Text(String(format: "%.0f%%", item.confidence * 100))
                                    .font(.system(size: 7, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.3))
                            }
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(DS.surface)
                            .overlay(Rectangle().stroke(DS.divider, lineWidth: 1))
                        }
                    }
                }
                // Visible text
                if !obs.visibleText.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.3))
                        Text(obs.visibleText.prefix(3).joined(separator: "  ·  "))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var idleView: some View {
        VStack(spacing: 6) {
            Image(systemName: "globe.desk")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.08))
            Text("SCAN ROOM TO MAP")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(1)
                .foregroundColor(.white.opacity(0.12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var canvasLabel: some View {
        HStack(spacing: 4) {
            let (icon, label, color) = canvasLabelInfo
            Image(systemName: icon).font(.system(size: 7)).foregroundColor(color)
            Text(label)
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(Color.black.opacity(0.55))
        .padding(5)
    }

    private var canvasLabelInfo: (String, String, Color) {
        switch canvasMode {
        case .sweeping:      return ("scope",          "SCANNING",  DS.green)
        case .panorama:      return ("globe.americas", "PANORAMA",  DS.green)
        case .building:      return ("gearshape",      "BUILDING",  DS.yellow)
        case .splatReady:    return ("map",             "ROOM MAP",  DS.green)
        case .sceneLabels:   return ("sparkles",        "SCENE",     DS.yellow)
        case .idle:          return ("globe.desk",      "CANVAS",    Color.white.opacity(0.2))
        }
    }
}

// MARK: - Simple flow layout for chips

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxW && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.minX + maxW && x > bounds.minX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Status bar (top-right)

private struct StatusBar: View {
    @ObservedObject var gimbal:       GimbalService
    @ObservedObject var tracker:      CameraTracker
    @ObservedObject private var speaker:     SpeakerFollowManager
    @ObservedObject private var transcriber: WhisperTranscriber
    @State private var showSettings = false

    init(gimbal: GimbalService, tracker: CameraTracker) {
        self.gimbal      = gimbal
        self.tracker     = tracker
        self.speaker     = tracker.speakerManager
        self.transcriber = tracker.transcriber
    }

    var body: some View {
        HStack(spacing: 10) {
            // Camera live indicator
            HStack(spacing: 5) {
                Circle()
                    .fill(tracker.isRunning ? DS.green : Color.white.opacity(0.15))
                    .frame(width: 7, height: 7)
                Text(tracker.isRunning ? "LIVE" : "OFF")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1)
                    .foregroundColor(tracker.isRunning ? DS.green : .white.opacity(0.3))
            }

            // SIM badge — visible only when simulator is on
            if gimbal.isSimulator {
                Text("SIM")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(DS.purple)
            }

            // Subject count
            if tracker.isRunning {
                let n = tracker.allSubjects.isEmpty
                    ? (tracker.detectedBbox != nil ? 1 : 0)
                    : tracker.allSubjects.count
                if n > 0 {
                    Text("\(n)P")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundColor(DS.cyan)
                }
            }

            Spacer()

            // Gimbal position readout — proves the sim/real motor is actually moving
            if gimbal.state.connectionState.isConnected {
                let p = gimbal.state.currentPosition
                HStack(spacing: 0) {
                    Text(String(format: "%+.0f°", p.yaw))
                        .font(.system(size: 11, design: .monospaced).monospacedDigit())
                        .foregroundColor(DS.yellow.opacity(0.85))
                    Text(",")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                    Text(String(format: "%+.0f°", p.pitch))
                        .font(.system(size: 11, design: .monospaced).monospacedDigit())
                        .foregroundColor(DS.yellow.opacity(0.85))
                }
                .help("Gimbal yaw, pitch")
            }

            // FPS readout
            if tracker.isRunning {
                HStack(spacing: 2) {
                    Text("\(tracker.fps)")
                        .font(.system(size: 12, design: .monospaced).monospacedDigit())
                        .foregroundColor(DS.green.opacity(0.85))
                    Text("fps")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                }
            }

            // Mic / speech indicator
            Image(systemName: speaker.isSpeechDetected ? "mic.fill" : "mic")
                .font(.system(size: 14))
                .foregroundColor(speaker.isSpeechDetected ? DS.green : Color.white.opacity(0.3))
                .frame(width: 22, height: 22)
                .help(transcriber.isTranscribing ? "Listening" : "Mic idle")

            // Simulator toggle (icon button)
            Button { gimbal.toggleSimulator() } label: {
                Image(systemName: gimbal.isSimulator ? "die.face.5.fill" : "die.face.5")
                    .font(.system(size: 14))
                    .foregroundColor(gimbal.isSimulator ? DS.purple : .white.opacity(0.4))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(gimbal.isSimulator ? "Disable simulator (use real BLE)" : "Enable gimbal simulator")

            // Settings popover
            Button { showSettings.toggle() } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundColor(showSettings ? DS.yellow : .white.opacity(0.4))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSettings, arrowEdge: .trailing) {
                SettingsPopover(tracker: tracker, gimbal: gimbal)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(DS.surface2)
    }
}

// MARK: - Settings popover

private struct SettingsPopover: View {
    @ObservedObject var tracker:    CameraTracker
    @ObservedObject var gimbal:     GimbalService
    @ObservedObject private var speaker:     SpeakerFollowManager
    @ObservedObject private var transcriber: WhisperTranscriber

    init(tracker: CameraTracker, gimbal: GimbalService) {
        self.tracker     = tracker
        self.gimbal      = gimbal
        self.speaker     = tracker.speakerManager
        self.transcriber = tracker.transcriber
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // ── Camera selection ──────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("CAMERA")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.white.opacity(0.45))
                Picker("", selection: $tracker.selectedCamera) {
                    ForEach(tracker.availableCameras, id: \.uniqueID) { cam in
                        Text(cam.localizedName).tag(cam as AVCaptureDevice?)
                    }
                }
                .pickerStyle(.menu)
                .disabled(tracker.isRunning)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
            }

            // ── Microphone selection (never the laptop mic) ───────
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("MICROPHONE")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(.white.opacity(0.45))
                    Spacer()
                    Button {
                        tracker.refreshMicrophones()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .help("Re-scan for mics")
                }
                if tracker.availableMicrophones.isEmpty {
                    Text("No iPhone or external mic detected.\nLaptop mic is intentionally excluded.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange.opacity(0.85))
                        .lineLimit(2)
                } else {
                    Picker("", selection: $tracker.selectedMicrophone) {
                        ForEach(tracker.availableMicrophones, id: \.uniqueID) { mic in
                            Text(mic.localizedName).tag(mic as AVCaptureDevice?)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                }
                if let inUse = tracker.audioInputName {
                    Text("Live: \(inUse)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            // ── Live transcription ───────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("LIVE TRANSCRIPTION")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.white.opacity(0.45))
                if transcriber.isModelLoaded {
                    Toggle(isOn: Binding(
                        get: { transcriber.isTranscribing },
                        set: { on in if on { transcriber.start() } else { transcriber.stop() } }
                    )) {
                        Text(transcriber.isTranscribing ? "Listening" : "Off")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .toggleStyle(.switch)
                    .disabled(!tracker.isRunning)
                    .tint(DS.cyan)
                } else {
                    HStack {
                        Text(transcriber.loadingStatus)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                        Spacer()
                        Button("LOAD MODEL") { transcriber.loadModel() }
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(DS.cyan)
                            .buttonStyle(.plain)
                    }
                }
            }

            Divider().background(DS.divider)

            // ── Follow tuning ────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("FOLLOW TUNING")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.white.opacity(0.45))
                LabeledSlider(label: "GAIN",     value: $tracker.gain,    range: 0...1)
                    .disabled(!tracker.isFollowing)
                LabeledSlider(label: "DEADZONE", value: $tracker.deadZone, range: 0...0.2, format: "%.3f")
                    .disabled(!tracker.isFollowing)
                LabeledSliderFloat(label: "MIC SENS", value: $speaker.threshold, range: 0.005...0.06, format: "%.3f")
            }

            Divider().background(DS.divider)

            // ── Timelapse ────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("TIMELAPSE")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.white.opacity(0.45))
                LabeledSlider(label: "INTERVAL", value: $tracker.timelapseInterval, range: 0.5...30, format: "%.1fs")
                    .disabled(tracker.isTimelapsing)
                Text("Output: 24fps. At interval=\(String(format: "%.1f", tracker.timelapseInterval))s, 1 hour real = \(String(format: "%.0f", 3600.0 / tracker.timelapseInterval / 24.0))s playback.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(DS.divider)

            // ── Simulator ────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("GIMBAL SOURCE")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.white.opacity(0.45))
                Toggle(isOn: Binding(
                    get: { gimbal.isSimulator },
                    set: { on in if on { gimbal.enableSimulator() } else { gimbal.disableSimulator() } }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: gimbal.isSimulator ? "die.face.5.fill" : "die.face.5")
                            .font(.system(size: 13))
                            .foregroundColor(gimbal.isSimulator ? DS.purple : .white.opacity(0.6))
                        Text(gimbal.isSimulator ? "Simulator (no hardware)" : "Real BLE gimbal")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
                .toggleStyle(.switch)
                .tint(DS.purple)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(DS.surface)
    }
}

// MARK: - Insight card (right panel, fills available height)

private struct InsightCard: View {
    @ObservedObject var tracker: CameraTracker
    @ObservedObject private var journal: JournalAnalyzer
    @ObservedObject private var runner:  MLXRunner

    init(tracker: CameraTracker) {
        self.tracker = tracker
        self.journal = tracker.journalAnalyzer
        self.runner  = tracker.journalAnalyzer.runner
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────
            HStack(spacing: 5) {
                if journal.isWriting {
                    ProgressView().scaleEffect(0.45).tint(DS.yellow)
                } else {
                    Circle()
                        .fill(journal.isAnalyzing ? DS.yellow : Color.white.opacity(0.15))
                        .frame(width: 5, height: 5)
                }
                Text("INSIGHT")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(journal.isAnalyzing ? DS.yellow : Color.white.opacity(0.3))

                Spacer()

                // Mode rotation indicator
                if journal.isAnalyzing {
                    HStack(spacing: 3) {
                        ForEach(ObservationMode.allCases, id: \.self) { m in
                            let isLatest = journal.latestBeat?.mode == m
                            Text(String(m.rawValue.prefix(3)))
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .foregroundColor(isLatest ? .black : DS.modeColor(m).opacity(0.55))
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .background(isLatest ? DS.modeColor(m) : DS.modeColor(m).opacity(0.12))
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(DS.surface2)

            // ── Main observation ─────────────────────────────────────
            if let beat = journal.latestBeat {
                let accent = DS.modeColor(beat.mode)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Rectangle().fill(accent).frame(width: 3, height: 16)
                        Text(beat.mode.rawValue)
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(1)
                            .foregroundColor(accent)
                        Spacer()
                        Text(timeAgo(beat.timestamp))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    Text(beat.sentence)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeInOut(duration: 0.4), value: beat.id)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(DS.bg)
            } else if journal.isAnalyzing {
                HStack {
                    ProgressView().scaleEffect(0.5).tint(DS.yellow)
                    Text("Watching…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.2))
                    Spacer()
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(DS.bg)
            } else {
                // Not running — show MLX state
                VStack(alignment: .leading, spacing: 8) {
                    MLXStatusRow(runner: runner, journal: journal, tracker: tracker)
                    Spacer()
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(DS.bg)
            }

            // ── History strip (last 3 beats) ─────────────────────────
            if journal.beats.count > 1 {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(DS.divider).frame(height: 1)
                    ForEach(journal.beats.dropLast().suffix(3).reversed()) { beat in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(String(beat.mode.rawValue.prefix(3)))
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .foregroundColor(DS.modeColor(beat.mode).opacity(0.65))
                                .frame(width: 32, alignment: .leading)
                            Text(beat.sentence)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(Rectangle().fill(DS.divider.opacity(0.5)).frame(height: 1), alignment: .bottom)
                    }
                }
            }
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60   { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        return "\(s/3600)h"
    }
}

// MARK: - Observation overlay (on video feed)

private struct ObservationOverlay: View {
    let beat: NarrativeBeat

    var body: some View {
        let accent = DS.modeColor(beat.mode)
        HStack(alignment: .top, spacing: 6) {
            Text(String(beat.mode.rawValue.prefix(3)))
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(accent)

            Text(beat.sentence)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.black.opacity(0.70))
        .overlay(Rectangle().stroke(accent.opacity(0.3), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(.easeInOut(duration: 0.5), value: beat.id)
    }
}

// MARK: - MLX status row

private struct MLXStatusRow: View {
    @ObservedObject var runner:  MLXRunner
    @ObservedObject var journal: JournalAnalyzer
    var tracker: CameraTracker

    var body: some View {
        switch runner.state {
        case .idle:
            Button { runner.start() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu").font(.system(size: 9))
                    Text("LOAD MODEL")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(DS.yellow)
            }
            .buttonStyle(.plain)

        case .loading(let name):
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.5).tint(DS.yellow)
                Text("LOADING \(name.uppercased())…")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(DS.yellow.opacity(0.7))
                    .lineLimit(2)
            }

        case .ready:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Rectangle().fill(DS.green).frame(width: 5, height: 5)
                    Text("MODEL READY")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundColor(DS.green.opacity(0.8))
                }
                Button("ANALYZE NOW") {
                    journal.start(tracker: tracker, transcriber: tracker.transcriber)
                }
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(tracker.isRunning ? DS.yellow : DS.yellow.opacity(0.3))
                .buttonStyle(.plain)
                .disabled(!tracker.isRunning)
            }

        case .error(let msg):
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange).font(.system(size: 9))
                    Text(msg)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.orange)
                        .lineLimit(3)
                }
                if msg.contains("mlx_vlm") || msg.contains("dependency") {
                    Text("pip install mlx-vlm Pillow")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                        .textSelection(.enabled)
                }
                Button("RETRY") { runner.state = .idle; runner.start() }
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange)
                    .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Shared helpers (sliders, audio bar, overlays, preview)

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.2f"

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 78, alignment: .leading)
            Slider(value: $value, in: range).tint(DS.yellow)
            Text(String(format: format, value))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(DS.yellow)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

private struct LabeledSliderFloat: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var format: String = "%.2f"

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 78, alignment: .leading)
            Slider(value: $value, in: range).tint(DS.yellow)
            Text(String(format: format, value))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(DS.yellow)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

private struct SubjectsOverlayView: View {
    let subjects:    [DetectedSubject]
    let isFollowing: Bool
    var lockPoint:   CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: w/2-8, y: h/2)); p.addLine(to: CGPoint(x: w/2+8, y: h/2))
                    p.move(to: CGPoint(x: w/2, y: h/2-8)); p.addLine(to: CGPoint(x: w/2, y: h/2+8))
                }
                .stroke(Color.white.opacity(0.2), lineWidth: 1)

                // Click-lock target indicator (bottom-left origin → flip y)
                if let lock = lockPoint {
                    let lx = lock.x * w
                    let ly = (1 - lock.y) * h
                    Circle()
                        .stroke(DS.cyan, lineWidth: 2)
                        .frame(width: 22, height: 22)
                        .position(x: lx, y: ly)
                    Circle()
                        .fill(DS.cyan)
                        .frame(width: 4, height: 4)
                        .position(x: lx, y: ly)
                }

                ForEach(subjects.indices, id: \.self) { idx in
                    let s  = subjects[idx]
                    let bb = s.bbox
                    let x  = bb.origin.x * w
                    let y  = (1 - bb.origin.y - bb.height) * h
                    let bw = bb.width  * w
                    let bh = bb.height * h
                    let color: Color = s.isSpeaking ? DS.green
                                     : s.isTracked  ? (isFollowing ? DS.cyan : DS.yellow)
                                     : .white.opacity(0.4)
                    let lw: CGFloat = (s.isTracked || s.isSpeaking) ? 2 : 1
                    ZStack(alignment: .topLeading) {
                        Rectangle().stroke(color, lineWidth: lw).frame(width: bw, height: bh)
                        if let badge = badgeText(s, count: subjects.count) {
                            Text(badge)
                                .font(.system(size: 7, weight: .black, design: .monospaced))
                                .foregroundColor(.black)
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(color)
                                .offset(x: 0, y: -14)
                        }
                    }
                    .position(x: x + bw/2, y: y + bh/2)
                }
            }
        }
    }

    private func badgeText(_ s: DetectedSubject, count: Int) -> String? {
        if let lbl = s.speakerLabel {
            let n = (Int(lbl) ?? 0) + 1
            return s.isSpeaking ? "SPK \(n) ●" : "SPK \(n)"
        } else if s.isSpeaking { return "SPEAKING" }
        else if s.isTracked && count > 1 { return "TRACKED" }
        return nil
    }
}

struct CameraPreviewView: NSViewRepresentable {
    @ObservedObject var tracker: CameraTracker

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer()
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let layer = nsView.layer?.sublayers?.first as? AVCaptureVideoPreviewLayer else { return }
        layer.session = tracker.captureSession
    }
}

// MARK: - Splat Map

private struct SplatMapView: View {
    let subjects:        [SubjectMapEntry]
    let currentYaw:      Double
    let currentPitch:    Double
    let sweepState:      RoomSweepState
    let sweepCurrentYaw: Double
    var sweepCurrentPitch: Double = 0
    var onTapSubject: ((SubjectMapEntry) -> Void)? = nil

    private let yawMin:   Double = -160
    private let yawMax:   Double =  160
    private let pitchMin: Double = -35
    private let pitchMax: Double =  35

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Rectangle().fill(Color.black)

                ForEach([-160, -90, 0, 90, 160], id: \.self) { deg in
                    let x = yawX(Double(deg), w: w)
                    Path { p in
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: h))
                    }
                    .stroke(Color.white.opacity(deg == 0 ? 0.2 : 0.06), lineWidth: 1)
                    Text("\(deg)°")
                        .font(.system(size: 6, design: .monospaced))
                        .foregroundColor(.white.opacity(0.2))
                        .position(x: x, y: h - 6)
                }

                Path { p in
                    let y = pitchY(0, h: h)
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                }
                .stroke(Color.white.opacity(0.1), lineWidth: 1)

                if sweepState == .sweeping {
                    let cx = yawX(sweepCurrentYaw, w: w)
                    let sy = pitchY(sweepCurrentPitch, h: h)
                    Rectangle().fill(DS.green.opacity(0.15)).frame(width: 3, height: h)
                        .position(x: cx, y: h/2).animation(.linear(duration: 0.3), value: sweepCurrentYaw)
                    Rectangle().fill(DS.green.opacity(0.7)).frame(width: w, height: 2)
                        .position(x: w/2, y: sy).animation(.linear(duration: 0.2), value: sweepCurrentPitch)
                }

                ForEach(subjects) { entry in
                    let x = yawX(entry.approximateYaw, w: w)
                    let y = pitchY(entry.approximatePitch, h: h)
                    ZStack(alignment: .bottom) {
                        ZStack {
                            Circle().fill(DS.cyan.opacity(0.2)).frame(width: 18, height: 18)
                            Circle().fill(DS.cyan).frame(width: 8, height: 8)
                            Text("\(entry.speakerNumber)")
                                .font(.system(size: 5, weight: .black, design: .monospaced))
                                .foregroundColor(.black)
                        }
                        if let name = entry.name {
                            Text(name)
                                .font(.system(size: 6, weight: .black, design: .monospaced))
                                .foregroundColor(DS.cyan)
                                .padding(.horizontal, 2).padding(.vertical, 1)
                                .background(Color.black.opacity(0.8))
                                .offset(y: 14)
                        }
                    }
                    .position(x: x, y: y)
                    .transition(.scale.combined(with: .opacity))
                    .onTapGesture { onTapSubject?(entry) }
                    .help("Tap to navigate gimbal here")
                }

                let cx = yawX(currentYaw, w: w)
                let cy = pitchY(currentPitch, h: h)
                Path { p in
                    p.move(to: CGPoint(x: cx-6, y: cy)); p.addLine(to: CGPoint(x: cx+6, y: cy))
                    p.move(to: CGPoint(x: cx, y: cy-6)); p.addLine(to: CGPoint(x: cx, y: cy+6))
                }
                .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                Circle().stroke(Color.white.opacity(0.4), lineWidth: 1).frame(width: 5, height: 5)
                    .position(x: cx, y: cy)
            }
            .clipShape(Rectangle())
            .overlay(Rectangle().stroke(DS.green.opacity(0.15), lineWidth: 1))
            .animation(.easeInOut(duration: 0.3), value: subjects.count)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func yawX(_ yaw: Double, w: CGFloat) -> CGFloat {
        CGFloat((yaw - yawMin) / (yawMax - yawMin)) * w
    }
    private func pitchY(_ pitch: Double, h: CGFloat) -> CGFloat {
        CGFloat(1 - (pitch - pitchMin) / (pitchMax - pitchMin)) * h
    }
}

// MARK: - Person tag row

private struct PersonTagRow: View {
    let entry:        SubjectMapEntry
    let onTap:        () -> Void
    let onNameChange: (String) -> Void
    @State private var nameText = ""

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onTap) {
                ZStack {
                    Circle().fill(DS.cyan.opacity(0.2)).frame(width: 14, height: 14)
                    Text("\(entry.speakerNumber)")
                        .font(.system(size: 7, weight: .black, design: .monospaced))
                        .foregroundColor(DS.cyan)
                }
            }
            .buttonStyle(.plain)

            Text(String(format: "%.0f°,%.0f°", entry.approximateYaw, entry.approximatePitch))
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
                .frame(width: 55, alignment: .leading)

            TextField("name…", text: $nameText)
                .font(.system(size: 9, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit { onNameChange(nameText) }
                .onChange(of: nameText) { _, v in onNameChange(v) }
        }
        .padding(.vertical, 3)
        .onAppear { nameText = entry.name ?? "" }
    }
}
