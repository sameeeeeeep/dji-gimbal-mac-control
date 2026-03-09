import SwiftUI
import AVFoundation

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

                if let bbox = tracker.detectedBbox {
                    BboxOverlayView(bbox: bbox, isFollowing: tracker.isFollowing)
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
                .disabled(!tracker.isRunning || !gimbal.state.connectionState.isConnected)
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledSlider(label: "Gain", value: $tracker.gain, range: 0...1)
                LabeledSlider(label: "Dead zone", value: $tracker.deadZone, range: 0...0.2, format: "%.3f")
            }
            .disabled(!tracker.isFollowing)

            Spacer()
        }
        .padding()
        .frame(minWidth: 320)
        .onAppear {
            // Wire follow loop → gimbal speed
            tracker.onSpeedCommand = { [weak gimbal] yaw, pitch in
                gimbal?.setSpeed(yaw: yaw, pitch: pitch, roll: 0)
            }
        }
        .onDisappear {
            tracker.stopFollow()
        }
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

private struct BboxOverlayView: View {
    let bbox: CGRect // Vision coords: bottom-left origin, [0,1]
    let isFollowing: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // Flip Y: Vision origin is bottom-left, SwiftUI origin is top-left
            let x = bbox.origin.x * w
            let y = (1 - bbox.origin.y - bbox.height) * h
            let bw = bbox.width * w
            let bh = bbox.height * h

            ZStack {
                // Cross at frame center
                Path { p in
                    p.move(to: CGPoint(x: w / 2 - 10, y: h / 2))
                    p.addLine(to: CGPoint(x: w / 2 + 10, y: h / 2))
                    p.move(to: CGPoint(x: w / 2, y: h / 2 - 10))
                    p.addLine(to: CGPoint(x: w / 2, y: h / 2 + 10))
                }
                .stroke(Color.white.opacity(0.4), lineWidth: 1)

                // Bounding box
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isFollowing ? Color.cyan : Color.yellow, lineWidth: 2)
                    .frame(width: bw, height: bh)
                    .position(x: x + bw / 2, y: y + bh / 2)
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
