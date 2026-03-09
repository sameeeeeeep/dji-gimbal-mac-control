import AVFoundation
import Vision
import os

enum TrackingType {
    case face
    case person
}

@MainActor
final class CameraTracker: NSObject, ObservableObject {
    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var selectedCamera: AVCaptureDevice?
    @Published var isRunning = false
    @Published var isFollowing = false
    @Published var detectedBbox: CGRect? // Vision coords: bottom-left origin, normalized [0,1]
    @Published var fps = 0
    @Published var trackingType: TrackingType = .face {
        didSet { bgTrackingType = trackingType }
    }
    @Published var gain: Double = 0.3
    @Published var deadZone: Double = 0.05

    /// Set by GimbalService to receive speed commands from the follow loop.
    var onSpeedCommand: ((_ yaw: Double, _ pitch: Double) -> Void)?

    private(set) var captureSession: AVCaptureSession?
    private var followTimer: Timer?
    private var frameCount = 0
    private var lastFrameTime: Date?
    private let logger = Logger(subsystem: "com.gimbal.controller", category: "Camera")
    nonisolated(unsafe) private var bgTrackingType: TrackingType = .face

    override init() {
        super.init()
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .front
        )
        availableCameras = session.devices
        selectedCamera = availableCameras.first
    }

    func startCamera() {
        guard let camera = selectedCamera else { return }
        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: camera) else { return }
        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.gimbal.camera"))
        if session.canAddOutput(output) { session.addOutput(output) }

        captureSession = session
        session.startRunning()
        isRunning = true
        logger.info("Camera started: \(camera.localizedName)")
    }

    func stopCamera() {
        stopFollow()
        captureSession?.stopRunning()
        captureSession = nil
        isRunning = false
        detectedBbox = nil
    }

    func startFollow() {
        guard isRunning else { return }
        isFollowing = true
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let bbox = self.detectedBbox {
                    // Vision: bottom-left origin, Y needs flip for gimbal (up = positive pitch)
                    let ex = bbox.midX - 0.5
                    let ey = 0.5 - bbox.midY
                    let dx = abs(ex) < self.deadZone ? 0 : ex
                    let dy = abs(ey) < self.deadZone ? 0 : ey
                    self.onSpeedCommand?(dx * self.gain * 1500, dy * self.gain * 1500)
                } else {
                    self.onSpeedCommand?(0, 0)
                }
            }
        }
    }

    func stopFollow() {
        followTimer?.invalidate()
        followTimer = nil
        isFollowing = false
        onSpeedCommand?(0, 0)
    }
}

// MARK: - Sample buffer delegate (background thread)

extension CameraTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)

        let request: VNRequest
        switch bgTrackingType {
        case .face:
            request = VNDetectFaceRectanglesRequest { [weak self] req, _ in
                let box = (req.results as? [VNFaceObservation])?.first?.boundingBox
                Task { @MainActor [weak self] in self?.updateBbox(box) }
            }
        case .person:
            request = VNDetectHumanRectanglesRequest { [weak self] req, _ in
                let box = (req.results as? [VNHumanObservation])?.first?.boundingBox
                Task { @MainActor [weak self] in self?.updateBbox(box) }
            }
        }
        try? handler.perform([request])
    }

    private func updateBbox(_ box: CGRect?) {
        detectedBbox = box
        if box != nil { bumpFPS() }
    }

    private func bumpFPS() {
        frameCount += 1
        let now = Date()
        if let last = lastFrameTime, now.timeIntervalSince(last) >= 1.0 {
            Task { @MainActor in fps = frameCount }
            frameCount = 0
            lastFrameTime = now
        } else if lastFrameTime == nil {
            lastFrameTime = now
        }
    }
}
