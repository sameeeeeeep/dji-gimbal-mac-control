import SwiftUI
import AVFoundation
import AppKit

struct TrackingView: View {
    @ObservedObject var gimbal: GimbalService
    @ObservedObject var tracker: CameraTracker

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Camera:")
                    .font(.caption.weight(.medium))
                Picker("", selection: $tracker.selectedCamera) {
                    ForEach(tracker.availableCameras, id: \.uniqueID) { cam in
                        Text(cam.localizedName).tag(cam as AVCaptureDevice?)
                    }
                }
                .pickerStyle(.menu)
                .disabled(tracker.isRunning)

                Picker("", selection: $tracker.trackingType) {
                    Text("Face").tag(TrackingType.face)
                    Text("Person").tag(TrackingType.person)
                }
                .pickerStyle(.segmented)
                .disabled(tracker.isRunning)
                .frame(maxWidth: 160)
            }

            ZStack {
                CameraPreviewView(tracker: tracker)
                    .frame(height: 300)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

                if !tracker.allSubjects.isEmpty {
                    SubjectsOverlayView(subjects: tracker.allSubjects,
                                        isFollowing: tracker.isFollowing)
                } else if let bbox = tracker.detectedBbox {
                    // Fallback for any path that still sets detectedBbox directly
                    SubjectsOverlayView(
                        subjects: [DetectedSubject(bbox: bbox, isSpeaking: false, isTracked: true, speakerLabel: nil)],
                        isFollowing: tracker.isFollowing
                    )
                }

                if !tracker.isRunning {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.black.opacity(0.6))
                        .overlay(
                            Text("Camera off")
                                .foregroundStyle(.secondary)
                        )
                        .frame(height: 300)
                }
            }

            HStack {
                if tracker.isRunning {
                    Image(systemName: tracker.detectedBbox != nil ? "person.fill.viewfinder" : "person.slash")
                        .foregroundStyle(tracker.detectedBbox != nil ? .green : .orange)
                    Text(tracker.detectedBbox != nil ? "Tracking" : "No subject")
                        .font(.caption)
                    Spacer()
                    Text("\(tracker.fps) FPS")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 16)

            Divider()

            HStack(spacing: 16) {
                Button(tracker.isRunning ? "Stop Camera" : "Start Camera") {
                    if tracker.isRunning { tracker.stopCamera() } else { tracker.startCamera() }
                }
                .buttonStyle(.bordered)

                Toggle("Follow Mode", isOn: Binding(
                    get: { tracker.isFollowing },
                    set: { on in
                        if on && gimbal.state.connectionState.isConnected {
                            tracker.startFollow()
                        } else {
                            tracker.stopFollow()
                        }
                    }
                ))
                .disabled(!tracker.isRunning || !gimbal.state.connectionState.isConnected
                          || tracker.roomSweepState == .sweeping)

                if tracker.palmGestureActive {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.cyan)
                        .imageScale(.small)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: tracker.palmGestureActive)

            VStack(alignment: .leading, spacing: 8) {
                LabeledSlider(label: "Gain", value: $tracker.gain, range: 0...1)
                LabeledSlider(label: "Dead zone", value: $tracker.deadZone, range: 0...0.2, format: "%.3f")
            }
            .disabled(!tracker.isFollowing)

            Divider()

            // MARK: Capture Controls
            HStack(spacing: 16) {
                // Photo button
                Button {
                    tracker.capturePhoto()
                } label: {
                    Label("Photo", systemImage: "camera.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!tracker.isRunning)

                // Record / Stop button
                Button {
                    if tracker.isRecording {
                        tracker.stopRecording()
                    } else {
                        tracker.startRecording()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(tracker.isRecording ? Color.red : Color.primary)
                            .frame(width: 8, height: 8)
                        if tracker.isRecording {
                            Text(recordingLabel)
                                .monospacedDigit()
                        } else {
                            Text("Record")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!tracker.isRunning)

                Spacer()

                // Reveal in Finder shortcuts
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
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                }
            }

            // Last capture status
            if let url = tracker.lastPhotoURL ?? tracker.lastVideoURL {
                HStack(spacing: 4) {
                    Image(systemName: tracker.lastPhotoURL != nil ? "photo" : "video")
                        .foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Divider()

            // MARK: Speaker Follow
            SpeakerFollowSection(tracker: tracker)

            Spacer()
        }
        .padding()
        .frame(minWidth: 320)
        .onAppear {
            // Wire follow loop → gimbal speed (also set in GimbalService.init; kept for safety)
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

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.2f"

    var body: some View {
        HStack {
            Text(label)
                .font(.caption.weight(.medium))
                .frame(width: 60, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Speaker Follow Section

private struct SpeakerFollowSection: View {
    @ObservedObject var tracker: CameraTracker
    @ObservedObject private var speaker: SpeakerFollowManager
    @ObservedObject private var transcriber: WhisperTranscriber

    init(tracker: CameraTracker) {
        self.tracker = tracker
        self.speaker = tracker.speakerManager
        self.transcriber = tracker.transcriber
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header + main toggle
            HStack {
                Label("Speaker Follow", systemImage: "waveform.and.person.filled")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $tracker.speakerFollowEnabled)
                    .labelsHidden()
                    .disabled(!tracker.isRunning)
            }

            // Sweep progress / subject map
            if tracker.speakerFollowEnabled {
                switch tracker.roomSweepState {
                case .sweeping:
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Scanning room…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .ready:
                    if tracker.subjectMap.isEmpty {
                        Text("No speakers detected in sweep")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(tracker.subjectMap) { entry in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.cyan)
                                        .frame(width: 6, height: 6)
                                    Text("Speaker \(entry.speakerNumber)")
                                        .font(.caption2.weight(.medium))
                                    Text(String(format: "yaw %.0f°", entry.approximateYaw))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                case .idle:
                    EmptyView()
                }
            }

            if tracker.speakerFollowEnabled {
                // Audio level meter
                HStack(spacing: 8) {
                    Image(systemName: speaker.isSpeechDetected ? "mic.fill" : "mic")
                        .foregroundStyle(speaker.isSpeechDetected ? .green : .secondary)
                        .imageScale(.small)
                        .frame(width: 14)
                    AudioLevelBar(level: speaker.audioLevel,
                                  isActive: speaker.isSpeechDetected)
                    Text(speaker.isSpeechDetected ? "Speaking" : "Silence")
                        .font(.caption)
                        .foregroundStyle(speaker.isSpeechDetected ? .green : .secondary)
                        .frame(width: 54, alignment: .leading)
                }

                // Sensitivity slider
                HStack {
                    Text("Sensitivity")
                        .font(.caption.weight(.medium))
                        .frame(width: 70, alignment: .leading)
                    Slider(value: $speaker.threshold, in: 0.005...0.06)
                    Text(String(format: "%.3f", speaker.threshold))
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }

                Divider().padding(.vertical, 2)

                // Live transcription
                HStack {
                    Label("Live Captions", systemImage: "captions.bubble")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !transcriber.isModelLoaded {
                        if transcriber.loadingStatus == "Not loaded" {
                            Button("Load Model") { transcriber.loadModel() }
                                .font(.caption2)
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                        } else {
                            Text(transcriber.loadingStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Toggle("", isOn: Binding(
                            get: { transcriber.isTranscribing },
                            set: { on in
                                if on { transcriber.start() }
                                else { transcriber.stop() }
                            }
                        ))
                        .labelsHidden()
                        .disabled(!tracker.isRunning)
                    }
                }

                if transcriber.isTranscribing || !transcriber.transcript.isEmpty {
                    ScrollView {
                        Text(transcriber.transcript.isEmpty ? "Listening…" : transcriber.transcript)
                            .font(.caption)
                            .foregroundStyle(transcriber.transcript.isEmpty ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(height: 72)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
            }
        }
    }
}

// MARK: - Audio level bar

private struct AudioLevelBar: View {
    let level: Float   // 0–1
    let isActive: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(isActive ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Multi-subject overlay

private struct SubjectsOverlayView: View {
    let subjects: [DetectedSubject]
    let isFollowing: Bool

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
                .stroke(Color.white.opacity(0.4), lineWidth: 1)

                // One layer per detected subject
                ForEach(subjects.indices, id: \.self) { idx in
                    let s = subjects[idx]
                    let bb = s.bbox
                    // Flip Y: Vision origin is bottom-left, SwiftUI is top-left
                    let x  = bb.origin.x * w
                    let y  = (1 - bb.origin.y - bb.height) * h
                    let bw = bb.width  * w
                    let bh = bb.height * h

                    let color: Color = s.isSpeaking ? .green
                                     : s.isTracked  ? (isFollowing ? .cyan : .yellow)
                                     : .white.opacity(0.5)
                    let lineWidth: CGFloat = (s.isTracked || s.isSpeaking) ? 2 : 1

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(color, lineWidth: lineWidth)
                            .frame(width: bw, height: bh)

                        // Label badge
                        let badgeText: String? = {
                            if let lbl = s.speakerLabel {
                                // Convert "0"→"Speaker 1", "1"→"Speaker 2", etc.
                                let n = (Int(lbl) ?? 0) + 1
                                return s.isSpeaking ? "Speaker \(n) ●" : "Speaker \(n)"
                            } else if s.isSpeaking {
                                return "Speaking"
                            } else if s.isTracked && subjects.count > 1 {
                                return "Tracked"
                            }
                            return nil
                        }()
                        if let badge = badgeText {
                            Text(badge)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(color, in: Capsule())
                                .offset(x: 4, y: -14)
                        }
                    }
                    .position(x: x + bw / 2, y: y + bh / 2)
                }
            }
        }
        .frame(height: 300)
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
