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

// MARK: - Neobrutalist card modifier

private struct BrutalCard: ViewModifier {
    let borderColor: Color
    let lineWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Color.black)
            .overlay(
                Rectangle()
                    .stroke(borderColor, lineWidth: lineWidth)
            )
    }
}

extension View {
    func brutalCard(_ color: Color, lineWidth: CGFloat = 2) -> some View {
        modifier(BrutalCard(borderColor: color, lineWidth: lineWidth))
    }
}

// MARK: - Main TrackingView

struct TrackingView: View {
    @ObservedObject var gimbal: GimbalService
    @ObservedObject var tracker: CameraTracker

    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // ── 1. CAMERA STRIP ──────────────────────────────────────────
                CameraStripSection(gimbal: gimbal, tracker: tracker,
                                   showSettings: $showSettings)

                // ── 2. INTELLIGENCE PANEL ────────────────────────────────────
                HStack(alignment: .top, spacing: 0) {
                    RoomCardSection(gimbal: gimbal, tracker: tracker)
                        .frame(maxWidth: .infinity)

                    Rectangle()
                        .fill(Color(hex: "FFE500"))
                        .frame(width: 1)

                    FollowCardSection(tracker: tracker)
                        .frame(maxWidth: .infinity)
                }
                .frame(minHeight: 260)
                .brutalCard(Color(hex: "FFE500"), lineWidth: 2)
                .padding(.top, 2)

                // ── 3. OBSERVE STRIP ─────────────────────────────────────────
                ObserveStrip(tracker: tracker)
                    .padding(.top, 2)

                // ── 4. NARRATIVE PANEL ───────────────────────────────────────
                NarrativePanel(tracker: tracker)
                    .padding(.top, 2)

                // ── 5. CAPTURE ROW ───────────────────────────────────────────
                CaptureRow(tracker: tracker)
                    .padding(.top, 2)

                // ── SETTINGS (collapsible) ───────────────────────────────────
                if showSettings {
                    SettingsPanel(tracker: tracker, gimbal: gimbal)
                        .padding(.top, 2)
                }

            }
            .padding(8)
            .background(Color(hex: "0A0A0A"))
        }
        .background(Color(hex: "0A0A0A"))
        .frame(minWidth: 340)
        .onAppear {
            tracker.onSpeedCommand = { [weak gimbal] yaw, pitch in
                gimbal?.setSpeed(yaw: yaw, pitch: pitch, roll: 0)
            }
        }
    }

    private var recordingLabel: String {
        let total = Int(tracker.recordingDuration)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Camera Strip

private struct CameraStripSection: View {
    @ObservedObject var gimbal: GimbalService
    @ObservedObject var tracker: CameraTracker
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                Text("CAMERA")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Color(hex: "FFE500"))

                Spacer()

                // Camera picker inline
                Picker("", selection: $tracker.selectedCamera) {
                    ForEach(tracker.availableCameras, id: \.uniqueID) { cam in
                        Text(cam.localizedName).tag(cam as AVCaptureDevice?)
                    }
                }
                .pickerStyle(.menu)
                .disabled(tracker.isRunning)
                .font(.system(size: 10, design: .monospaced))

                // Tracking type picker
                Picker("", selection: $tracker.trackingType) {
                    Text("FACE").tag(TrackingType.face)
                    Text("BODY").tag(TrackingType.person)
                }
                .pickerStyle(.segmented)
                .disabled(tracker.isRunning)
                .frame(maxWidth: 110)

                // Settings gear
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11))
                        .foregroundColor(showSettings ? Color(hex: "FFE500") : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(hex: "111111"))

            // Camera preview
            ZStack {
                CameraPreviewView(tracker: tracker)
                    .frame(height: 280)

                if !tracker.allSubjects.isEmpty {
                    SubjectsOverlayView(subjects: tracker.allSubjects,
                                        isFollowing: tracker.isFollowing,
                                        height: 280)
                } else if let bbox = tracker.detectedBbox {
                    SubjectsOverlayView(
                        subjects: [DetectedSubject(bbox: bbox, isSpeaking: false,
                                                   isTracked: true, speakerLabel: nil)],
                        isFollowing: tracker.isFollowing,
                        height: 280
                    )
                }

                if !tracker.isRunning {
                    Rectangle()
                        .fill(Color.black.opacity(0.75))
                        .frame(height: 280)
                        .overlay(
                            Text("CAMERA OFF")
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                .tracking(3)
                                .foregroundColor(.white.opacity(0.4))
                        )
                }

                // FPS badge — top right
                if tracker.isRunning {
                    VStack {
                        HStack {
                            Spacer()
                            Text("\(tracker.fps) FPS")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Color(hex: "39FF14"))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.7))
                                .overlay(Rectangle().stroke(Color(hex: "39FF14"), lineWidth: 1))
                                .padding(6)
                        }
                        Spacer()
                    }
                }

                // Palm gesture badge
                if tracker.palmGestureActive {
                    VStack {
                        Spacer()
                        HStack {
                            HStack(spacing: 4) {
                                Image(systemName: "hand.raised.fill")
                                    .font(.system(size: 9))
                                Text("PALM")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                            }
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(hex: "00FFFF"))
                            .padding(6)
                            Spacer()
                        }
                    }
                }

                // Tracking status — bottom right
                if tracker.isRunning {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(tracker.detectedBbox != nil ? Color(hex: "39FF14") : Color.orange)
                                    .frame(width: 5, height: 5)
                                Text(tracker.detectedBbox != nil ? "TRACKING" : "NO SUBJECT")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .foregroundColor(tracker.detectedBbox != nil ? Color(hex: "39FF14") : .orange)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.7))
                            .padding(6)
                        }
                    }
                }
            }
            .frame(height: 280)

            // Bottom action bar
            HStack(spacing: 8) {
                Button(tracker.isRunning ? "STOP CAM" : "START CAM") {
                    if tracker.isRunning { tracker.stopCamera() } else { tracker.startCamera() }
                }
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1)
                .foregroundColor(tracker.isRunning ? .black : Color(hex: "0A0A0A"))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(tracker.isRunning ? Color.orange : Color(hex: "FFE500"))

                Spacer()

                // Follow toggle
                HStack(spacing: 6) {
                    Text("FOLLOW")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(1)
                        .foregroundColor(tracker.isFollowing ? Color(hex: "00FFFF") : .white.opacity(0.4))

                    Toggle("", isOn: Binding(
                        get: { tracker.isFollowing },
                        set: { on in
                            if on && gimbal.state.connectionState.isConnected {
                                tracker.startFollow()
                            } else {
                                tracker.stopFollow()
                            }
                        }
                    ))
                    .labelsHidden()
                    .disabled(!tracker.isRunning || !gimbal.state.connectionState.isConnected
                              || tracker.roomSweepState == .sweeping)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(hex: "111111"))
        }
        .brutalCard(Color(hex: "FFE500"), lineWidth: 2)
    }
}

// MARK: - Room Card

private struct RoomCardSection: View {
    @ObservedObject var gimbal: GimbalService
    @ObservedObject var tracker: CameraTracker
    @ObservedObject private var panorama: PanoramaBuilder

    init(gimbal: GimbalService, tracker: CameraTracker) {
        self.gimbal = gimbal
        self.tracker = tracker
        self.panorama = tracker.panoramaBuilder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("ROOM")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Color(hex: "39FF14"))
                Spacer()

                if tracker.isNavigating {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.55)
                            .tint(Color(hex: "39FF14"))
                        Text("NAV")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(hex: "39FF14"))
                    }
                } else if tracker.roomSweepState == .sweeping {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.55)
                            .tint(Color(hex: "39FF14"))
                        Text("SCANNING")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(hex: "39FF14"))
                    }
                } else if panorama.isBuilding {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.55)
                            .tint(Color(hex: "39FF14"))
                        Text("BUILDING")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(hex: "39FF14"))
                    }
                } else {
                    Button(tracker.roomSweepState == .ready ? "RE-SCAN" : "SCAN") {
                        tracker.scanRoom()
                    }
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(hex: "39FF14"))
                    .disabled(!tracker.isRunning || !gimbal.state.connectionState.isConnected)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(hex: "0D0D0D"))

            // Content
            VStack(alignment: .leading, spacing: 6) {
                if tracker.roomSweepState == .sweeping {
                    SplatMapView(
                        subjects: tracker.subjectMap,
                        currentYaw: gimbal.state.currentPosition.yaw,
                        currentPitch: gimbal.state.currentPosition.pitch,
                        sweepState: tracker.roomSweepState,
                        sweepCurrentYaw: tracker.sweepCurrentYaw,
                        sweepCurrentPitch: tracker.sweepCurrentPitch
                    )
                    Text("SCANNING ROOM…")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                        .padding(.horizontal, 4)
                }

                if tracker.roomSweepState == .ready {
                    if let pano = panorama.panorama {
                        PanoramaSphereView(
                            panorama: pano,
                            subjects: tracker.subjectMap,
                            onTapSubject: { entry in
                                tracker.navigateTo(
                                    yaw: entry.approximateYaw,
                                    pitch: entry.approximatePitch)
                            }
                        )
                        .frame(height: 200)
                        .overlay(Rectangle().stroke(Color(hex: "39FF14").opacity(0.3), lineWidth: 1))

                        Text("DRAG TO LOOK  •  TAP DOT TO GO")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.white.opacity(0.25))
                            .padding(.horizontal, 4)
                    } else if panorama.isBuilding {
                        PanoramaBuildingView()
                            .frame(height: 100)
                    } else {
                        SplatMapView(
                            subjects: tracker.subjectMap,
                            currentYaw: gimbal.state.currentPosition.yaw,
                            currentPitch: gimbal.state.currentPosition.pitch,
                            sweepState: tracker.roomSweepState,
                            sweepCurrentYaw: tracker.sweepCurrentYaw,
                            sweepCurrentPitch: tracker.sweepCurrentPitch,
                            onTapSubject: { entry in
                                tracker.navigateTo(
                                    yaw: entry.approximateYaw,
                                    pitch: entry.approximatePitch)
                            }
                        )
                    }

                    // Person count + list
                    if tracker.subjectMap.isEmpty {
                        Text("NO PEOPLE DETECTED")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.25))
                            .padding(.horizontal, 4)
                    } else {
                        HStack {
                            Text("\(tracker.subjectMap.count) PERSON\(tracker.subjectMap.count == 1 ? "" : "S")")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .foregroundColor(Color(hex: "39FF14"))
                        }
                        .padding(.horizontal, 4)

                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(tracker.subjectMap.indices, id: \.self) { idx in
                                PersonTagRow(
                                    entry: tracker.subjectMap[idx],
                                    onTap: {
                                        tracker.navigateTo(
                                            yaw: tracker.subjectMap[idx].approximateYaw,
                                            pitch: tracker.subjectMap[idx].approximatePitch)
                                    },
                                    onNameChange: { newName in
                                        tracker.subjectMap[idx].name = newName.isEmpty ? nil : newName
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }

                if tracker.roomSweepState == .idle {
                    Spacer()
                    Text("PRESS SCAN TO MAP\nTHE ROOM")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.2))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Follow Card

private struct FollowCardSection: View {
    @ObservedObject var tracker: CameraTracker
    @ObservedObject private var speaker: SpeakerFollowManager
    @ObservedObject private var transcriber: WhisperTranscriber

    init(tracker: CameraTracker) {
        self.tracker = tracker
        self.speaker = tracker.speakerManager
        self.transcriber = tracker.transcriber
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("FOLLOW")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Color(hex: "00FFFF"))
                Spacer()
                Toggle("", isOn: $tracker.speakerFollowEnabled)
                    .labelsHidden()
                    .disabled(!tracker.isRunning)
                    .tint(Color(hex: "00FFFF"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(hex: "0D0D0D"))

            VStack(alignment: .leading, spacing: 8) {
                if tracker.speakerFollowEnabled {
                    // Audio level bar
                    HStack(spacing: 6) {
                        Image(systemName: speaker.isSpeechDetected ? "mic.fill" : "mic")
                            .foregroundColor(speaker.isSpeechDetected ? Color(hex: "39FF14") : .white.opacity(0.3))
                            .font(.system(size: 10))
                            .frame(width: 12)
                        AudioLevelBar(level: speaker.audioLevel, isActive: speaker.isSpeechDetected)
                    }

                    HStack(spacing: 4) {
                        Circle()
                            .fill(speaker.isSpeechDetected ? Color(hex: "39FF14") : .white.opacity(0.2))
                            .frame(width: 5, height: 5)
                        Text(speaker.isSpeechDetected ? "SPEAKING" : "SILENCE")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundColor(speaker.isSpeechDetected ? Color(hex: "39FF14") : .white.opacity(0.3))
                    }

                    // Room sweep status
                    switch tracker.roomSweepState {
                    case .sweeping:
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.55).tint(Color(hex: "00FFFF"))
                            Text("SCANNING…")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Color(hex: "00FFFF"))
                        }
                    case .ready:
                        if !tracker.subjectMap.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(tracker.subjectMap) { entry in
                                    HStack(spacing: 4) {
                                        Rectangle()
                                            .fill(Color(hex: "00FFFF"))
                                            .frame(width: 4, height: 4)
                                        Text("SPK \(entry.speakerNumber)  \(String(format: "%.0f°", entry.approximateYaw))")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                }
                            }
                        }
                    case .idle:
                        EmptyView()
                    }

                    // Divider
                    Rectangle()
                        .fill(Color(hex: "00FFFF").opacity(0.2))
                        .frame(height: 1)

                    // Live captions header
                    HStack {
                        Text("CAPTIONS")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .tracking(1)
                            .foregroundColor(Color(hex: "00FFFF").opacity(0.7))
                        Spacer()
                        if !transcriber.isModelLoaded {
                            if transcriber.loadingStatus == "Not loaded" {
                                Button("LOAD") { transcriber.loadModel() }
                                    .font(.system(size: 8, weight: .black, design: .monospaced))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color(hex: "00FFFF"))
                            } else {
                                Text(transcriber.loadingStatus)
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                        } else {
                            Toggle("", isOn: Binding(
                                get: { transcriber.isTranscribing },
                                set: { on in if on { transcriber.start() } else { transcriber.stop() } }
                            ))
                            .labelsHidden()
                            .disabled(!tracker.isRunning)
                            .tint(Color(hex: "00FFFF"))
                        }
                    }

                    // Last 2 lines of transcript
                    if transcriber.isTranscribing || !transcriber.transcript.isEmpty {
                        let lines = transcriber.transcript.isEmpty
                            ? ["LISTENING…"]
                            : transcriber.transcript.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(2).map { String($0) }

                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(transcriber.transcript.isEmpty
                                                     ? .white.opacity(0.25)
                                                     : .white.opacity(0.8))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: "00FFFF").opacity(0.05))
                        .overlay(Rectangle().stroke(Color(hex: "00FFFF").opacity(0.2), lineWidth: 1))
                    }

                } else {
                    Spacer()
                    Text("TOGGLE TO\nENABLE FOLLOW")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.2))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Observe Strip

private struct ObserveStrip: View {
    @ObservedObject var tracker: CameraTracker
    @ObservedObject private var journal: JournalAnalyzer

    init(tracker: CameraTracker) {
        self.tracker = tracker
        self.journal = tracker.journalAnalyzer
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("OBSERVE")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Color(hex: "FFE500"))

                Spacer()

                if journal.isWriting {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.5).tint(Color(hex: "FFE500"))
                        Text("MLX WRITING")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(hex: "FFE500").opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(hex: "0D0D0D"))

            HStack(spacing: 8) {
                if journal.isAnalyzing, let obs = journal.latestObservation {
                    Text(obs.oneLiner)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeInOut(duration: 0.4), value: obs.timestamp)
                } else {
                    Text("JOURNAL NOT ACTIVE")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.2))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .brutalCard(Color(hex: "FFE500").opacity(0.5), lineWidth: 1)
    }
}

// MARK: - Narrative Panel

private struct NarrativePanel: View {
    @ObservedObject var tracker: CameraTracker
    @ObservedObject private var journal: JournalAnalyzer
    @ObservedObject private var runner: MLXRunner

    init(tracker: CameraTracker) {
        self.tracker = tracker
        self.journal = tracker.journalAnalyzer
        self.runner = tracker.journalAnalyzer.runner
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("JOURNAL")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Color(hex: "FFE500"))

                Spacer()

                if journal.isAnalyzing {
                    Button("STOP") { journal.stop() }
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.orange)
                } else {
                    Button("START") {
                        journal.start(tracker: tracker, transcriber: tracker.transcriber)
                    }
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(hex: "FFE500"))
                    .disabled(!tracker.isRunning || !runner.isReady)
                    .opacity(!tracker.isRunning || !runner.isReady ? 0.4 : 1.0)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(hex: "0D0D0D"))

            // MLX status
            HStack(spacing: 0) {
                MLXStatusRow(runner: runner, journal: journal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: "050505"))

            // Config row (when stopped + idle)
            if !journal.isAnalyzing, case .idle = runner.state {
                HStack(spacing: 8) {
                    Text("MODEL")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 44, alignment: .leading)
                    TextField("mlx-community/Qwen2.5-1.5B-Instruct-4bit",
                              text: $runner.modelTag)
                        .font(.system(size: 9, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(hex: "050505"))
            }

            // Narrative text
            ScrollView {
                if journal.narrative.isEmpty {
                    Text("Waiting for first scene change…")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.2))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                } else {
                    Text(journal.narrative)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.85))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .animation(.easeIn(duration: 0.3), value: journal.beats.count)
                }
            }
            .frame(height: 110)
        }
        .brutalCard(Color(hex: "FFE500"), lineWidth: 2)
    }
}

// MARK: - Capture Row

private struct CaptureRow: View {
    @ObservedObject var tracker: CameraTracker

    var body: some View {
        HStack(spacing: 8) {
            Text("CAPTURE")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(2)
                .foregroundColor(.white.opacity(0.5))

            Button {
                tracker.capturePhoto()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "camera.fill").font(.system(size: 9))
                    Text("PHOTO").font(.system(size: 9, weight: .black, design: .monospaced))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white)
            }
            .buttonStyle(.plain)
            .disabled(!tracker.isRunning)
            .opacity(!tracker.isRunning ? 0.3 : 1.0)

            Button {
                if tracker.isRecording { tracker.stopRecording() }
                else { tracker.startRecording() }
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(tracker.isRecording ? Color.red : Color.white)
                        .frame(width: 7, height: 7)
                    if tracker.isRecording {
                        Text(recordingLabel)
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundColor(.black)
                            .monospacedDigit()
                    } else {
                        Text("REC").font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundColor(.black)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tracker.isRecording ? Color.red : Color.white)
            }
            .buttonStyle(.plain)
            .disabled(!tracker.isRunning)
            .opacity(!tracker.isRunning ? 0.3 : 1.0)

            Spacer()

            if tracker.lastPhotoURL != nil || tracker.lastVideoURL != nil {
                Menu {
                    if let url = tracker.lastPhotoURL {
                        Button("Show Last Photo") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    if let url = tracker.lastVideoURL {
                        Button("Show Last Video") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Button("Open Captures Folder") {
                        NSWorkspace.shared.open(gimbalCapturesDir)
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }

            if let url = tracker.lastPhotoURL ?? tracker.lastVideoURL {
                Text(url.lastPathComponent)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 120)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .brutalCard(Color.white.opacity(0.15), lineWidth: 1)
    }

    private var recordingLabel: String {
        let total = Int(tracker.recordingDuration)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Settings Panel (collapsible)

private struct SettingsPanel: View {
    @ObservedObject var tracker: CameraTracker
    @ObservedObject var gimbal: GimbalService
    @ObservedObject private var speaker: SpeakerFollowManager

    init(tracker: CameraTracker, gimbal: GimbalService) {
        self.tracker = tracker
        self.gimbal = gimbal
        self.speaker = tracker.speakerManager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SETTINGS")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(2)
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(hex: "0D0D0D"))
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                LabeledSlider(label: "GAIN", value: $tracker.gain, range: 0...1)
                    .disabled(!tracker.isFollowing)
                LabeledSlider(label: "DEADZONE", value: $tracker.deadZone, range: 0...0.2, format: "%.3f")
                    .disabled(!tracker.isFollowing)
                LabeledSliderFloat(label: "MIC SENS", value: $speaker.threshold, range: 0.005...0.06, format: "%.3f")
                    .disabled(!tracker.speakerFollowEnabled)
            }
            .padding(8)
        }
        .brutalCard(Color.white.opacity(0.2), lineWidth: 1)
    }
}

// MARK: - Helpers reused from original

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.2f"

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 68, alignment: .leading)
            Slider(value: $value, in: range)
                .tint(Color(hex: "FFE500"))
            Text(String(format: format, value))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(hex: "FFE500"))
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct LabeledSliderFloat: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var format: String = "%.2f"

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 68, alignment: .leading)
            Slider(value: $value, in: range)
                .tint(Color(hex: "FFE500"))
            Text(String(format: format, value))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(hex: "FFE500"))
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Audio level bar

private struct AudioLevelBar: View {
    let level: Float
    let isActive: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                Rectangle()
                    .fill(isActive ? Color(hex: "39FF14") : Color.white.opacity(0.2))
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(height: 5)
        .overlay(Rectangle().stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

// MARK: - Multi-subject overlay

private struct SubjectsOverlayView: View {
    let subjects: [DetectedSubject]
    let isFollowing: Bool
    var height: CGFloat = 280

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Frame-centre crosshair
                Path { p in
                    p.move(to: CGPoint(x: w / 2 - 10, y: h / 2))
                    p.addLine(to: CGPoint(x: w / 2 + 10, y: h / 2))
                    p.move(to: CGPoint(x: w / 2, y: h / 2 - 10))
                    p.addLine(to: CGPoint(x: w / 2, y: h / 2 + 10))
                }
                .stroke(Color.white.opacity(0.3), lineWidth: 1)

                ForEach(subjects.indices, id: \.self) { idx in
                    let s = subjects[idx]
                    let bb = s.bbox
                    let x  = bb.origin.x * w
                    let y  = (1 - bb.origin.y - bb.height) * h
                    let bw = bb.width  * w
                    let bh = bb.height * h

                    let color: Color = s.isSpeaking ? Color(hex: "39FF14")
                                     : s.isTracked  ? (isFollowing ? Color(hex: "00FFFF") : Color(hex: "FFE500"))
                                     : .white.opacity(0.4)
                    let lineWidth: CGFloat = (s.isTracked || s.isSpeaking) ? 2 : 1

                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .stroke(color, lineWidth: lineWidth)
                            .frame(width: bw, height: bh)

                        let badgeText: String? = {
                            if let lbl = s.speakerLabel {
                                let n = (Int(lbl) ?? 0) + 1
                                return s.isSpeaking ? "SPK \(n) ●" : "SPK \(n)"
                            } else if s.isSpeaking {
                                return "SPEAKING"
                            } else if s.isTracked && subjects.count > 1 {
                                return "TRACKED"
                            }
                            return nil
                        }()
                        if let badge = badgeText {
                            Text(badge)
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundColor(.black)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(color)
                                .offset(x: 0, y: -16)
                        }
                    }
                    .position(x: x + bw / 2, y: y + bh / 2)
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Camera Preview (NSViewRepresentable)

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
        guard let previewLayer = nsView.layer?.sublayers?.first as? AVCaptureVideoPreviewLayer else { return }
        previewLayer.session = tracker.captureSession
    }
}

// MARK: - Splat Map

private struct SplatMapView: View {
    let subjects: [SubjectMapEntry]
    let currentYaw: Double
    let currentPitch: Double
    let sweepState: RoomSweepState
    let sweepCurrentYaw: Double
    var sweepCurrentPitch: Double = 0
    var onTapSubject: ((SubjectMapEntry) -> Void)? = nil

    private let yawMin: Double = -160
    private let yawMax: Double =  160
    private let pitchMin: Double = -35
    private let pitchMax: Double =  35

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                Rectangle()
                    .fill(Color.black)

                ForEach([-160, -90, 0, 90, 160], id: \.self) { deg in
                    let x = yawX(Double(deg), w: w)
                    Path { p in
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: h))
                    }
                    .stroke(Color.white.opacity(deg == 0 ? 0.25 : 0.08), lineWidth: 1)

                    Text("\(deg)°")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundColor(.white.opacity(0.25))
                        .position(x: x, y: h - 6)
                }

                Path { p in
                    let y = pitchY(0, h: h)
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: w, y: y))
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 1)

                if sweepState == .sweeping {
                    let cx = yawX(sweepCurrentYaw, w: w)
                    let sy = pitchY(sweepCurrentPitch, h: h)
                    Rectangle()
                        .fill(Color(hex: "39FF14").opacity(0.15))
                        .frame(width: 3, height: h)
                        .position(x: cx, y: h / 2)
                        .animation(.linear(duration: 0.3), value: sweepCurrentYaw)
                    Rectangle()
                        .fill(Color(hex: "39FF14").opacity(0.7))
                        .frame(width: w, height: 2)
                        .position(x: w / 2, y: sy)
                        .animation(.linear(duration: 0.2), value: sweepCurrentPitch)
                }

                ForEach(subjects) { entry in
                    let x = yawX(entry.approximateYaw, w: w)
                    let y = pitchY(entry.approximatePitch, h: h)
                    let label = entry.name ?? "\(entry.speakerNumber)"
                    ZStack(alignment: .bottom) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: "00FFFF").opacity(0.2))
                                .frame(width: 20, height: 20)
                            Circle()
                                .fill(Color(hex: "00FFFF"))
                                .frame(width: 9, height: 9)
                            Text("\(entry.speakerNumber)")
                                .font(.system(size: 6, weight: .black, design: .monospaced))
                                .foregroundColor(.black)
                        }
                        if entry.name != nil {
                            Text(label)
                                .font(.system(size: 7, weight: .black, design: .monospaced))
                                .foregroundColor(Color(hex: "00FFFF"))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Color.black.opacity(0.8))
                                .overlay(Rectangle().stroke(Color(hex: "00FFFF").opacity(0.4), lineWidth: 1))
                                .offset(y: 16)
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
                    p.move(to: CGPoint(x: cx - 7, y: cy)); p.addLine(to: CGPoint(x: cx + 7, y: cy))
                    p.move(to: CGPoint(x: cx, y: cy - 7)); p.addLine(to: CGPoint(x: cx, y: cy + 7))
                }
                .stroke(Color.white.opacity(0.85), lineWidth: 1.5)

                Circle()
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                    .frame(width: 6, height: 6)
                    .position(x: cx, y: cy)
            }
            .clipShape(Rectangle())
            .overlay(Rectangle().stroke(Color(hex: "39FF14").opacity(0.2), lineWidth: 1))
            .animation(.easeInOut(duration: 0.3), value: subjects.count)
        }
        .frame(height: 90)
    }

    private func yawX(_ yaw: Double, w: CGFloat) -> CGFloat {
        CGFloat((yaw - yawMin) / (yawMax - yawMin)) * w
    }

    private func pitchY(_ pitch: Double, h: CGFloat) -> CGFloat {
        CGFloat(1 - (pitch - pitchMin) / (pitchMax - pitchMin)) * h
    }
}

// MARK: - Person Tag Row

private struct PersonTagRow: View {
    let entry: SubjectMapEntry
    let onTap: () -> Void
    let onNameChange: (String) -> Void
    @State private var nameText: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onTap) {
                ZStack {
                    Circle()
                        .fill(Color(hex: "00FFFF").opacity(0.2))
                        .frame(width: 16, height: 16)
                    Text("\(entry.speakerNumber)")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .foregroundColor(Color(hex: "00FFFF"))
                }
            }
            .buttonStyle(.plain)
            .help("Click to point gimbal here")

            Text(String(format: "%.0f°,%.0f°", entry.approximateYaw, entry.approximatePitch))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 64, alignment: .leading)

            TextField("name…", text: $nameText)
                .font(.system(size: 10, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit { onNameChange(nameText) }
                .onChange(of: nameText) { _, v in onNameChange(v) }
        }
        .onAppear { nameText = entry.name ?? "" }
    }
}

// MARK: - MLX Status Row

private struct MLXStatusRow: View {
    @ObservedObject var runner: MLXRunner
    @ObservedObject var journal: JournalAnalyzer

    var body: some View {
        switch runner.state {
        case .idle:
            Button {
                runner.start()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(.system(size: 9))
                    Text("LOAD MLX MODEL")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(hex: "FFE500"))
            }
            .buttonStyle(.plain)

        case .loading(let name):
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.55).tint(Color(hex: "FFE500"))
                Text("LOADING \(name.uppercased())…")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(hex: "FFE500").opacity(0.7))
                Spacer()
                Text("~30s")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.white.opacity(0.2))
            }

        case .ready:
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color(hex: "39FF14"))
                    .frame(width: 6, height: 6)
                Text(journal.modelStatus.uppercased())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                if let path = journal.currentSessionPath {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([path])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }

        case .error(let msg):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange).font(.system(size: 9))
                    Text(msg.uppercased())
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
                if msg.contains("mlx_lm") {
                    Text("pip install mlx-lm")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                        .textSelection(.enabled)
                }
                Button("RETRY") { runner.state = .idle; runner.start() }
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .buttonStyle(.plain)
            }
        }
    }
}
