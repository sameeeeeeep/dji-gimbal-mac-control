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

    // --- Smoothed output (EMA filter — kills oscillation at any gain) ---
    private var smoothedYaw: Double = 0
    private var smoothedPitch: Double = 0
    private let smoothing: Double = 0.15  // EMA alpha: lower = smoother (0.1–0.3 range)

    // --- Search/scan state when face is lost ---
    private var lastExitSide: Double = 0   // -1 = left, +1 = right
    private var lastExitPitch: Double = 0  // remember vertical direction too
    private var lostFaceTime: Date?
    // Scan grid: sweep yaw left→right, step pitch down, sweep right→left, repeat
    private var scanSweepIndex: Int = 0
    private var scanSweepStartTime: TimeInterval = 0
    private let scanYawSpeed: Double = 500    // yaw sweep speed
    private let scanPitchStep: Double = 150   // pitch step between rows
    private let scanSweepDuration: Double = 1.8  // seconds per yaw sweep
    private let scanRows: Int = 4             // how many pitch rows to cover
    private let scanTimeout: TimeInterval = 10.0  // total scan budget

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
        guard isRunning else {
            logger.warning("startFollow called but camera not running")
            return
        }
        if onSpeedCommand == nil {
            logger.error("FOLLOW: onSpeedCommand is nil — gimbal won't move!")
        }
        isFollowing = true
        smoothedYaw = 0
        smoothedPitch = 0
        logger.info("FOLLOW: started (gain=\(self.gain, privacy: .public) deadZone=\(self.deadZone, privacy: .public))")
        var logTick = 0
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                logTick += 1
                let shouldLog = (logTick % 15 == 0)

                if let bbox = self.detectedBbox {
                    self.trackFace(bbox, shouldLog: shouldLog)
                } else {
                    self.searchForFace(shouldLog: shouldLog)
                }
            }
        }
    }

    func stopFollow() {
        followTimer?.invalidate()
        followTimer = nil
        isFollowing = false
        resetSearchState()
        smoothedYaw = 0
        smoothedPitch = 0
        onSpeedCommand?(0, 0)
    }

    // MARK: - Tracking (proportional + EMA smoothing)

    private func trackFace(_ bbox: CGRect, shouldLog: Bool) {
        // Face reacquired — reset scan state
        if lostFaceTime != nil {
            logger.info("FOLLOW: face reacquired!")
            resetSearchState()
        }

        let ex = bbox.midX - 0.5
        let ey = bbox.midY - 0.5

        let dx = abs(ex) < deadZone ? 0.0 : ex
        let dy = abs(ey) < deadZone ? 0.0 : ey

        // Raw proportional command with power curve
        let rawYaw   = Self.powerScale(dx) * gain * 1500
        let rawPitch = Self.powerScale(dy) * gain * 1500

        // EMA smoothing: smoothed = alpha * raw + (1-alpha) * previous
        // This is a low-pass filter — high-frequency jitter (oscillation) gets killed
        // regardless of how high gain is, because the output can only change gradually.
        smoothedYaw  = smoothing * rawYaw  + (1.0 - smoothing) * smoothedYaw
        smoothedPitch = smoothing * rawPitch + (1.0 - smoothing) * smoothedPitch

        // Remember exit direction for scan
        if abs(ex) > 0.25 {
            lastExitSide = ex > 0 ? 1.0 : -1.0
        }
        if abs(ey) > 0.25 {
            lastExitPitch = ey > 0 ? 1.0 : -1.0
        }

        if shouldLog {
            self.logger.info("FOLLOW: face=(\(String(format: "%.2f", bbox.midX), privacy: .public),\(String(format: "%.2f", bbox.midY), privacy: .public)) err=(\(String(format: "%+.3f", dx), privacy: .public),\(String(format: "%+.3f", dy), privacy: .public)) raw=(\(String(format: "%+.0f", rawYaw), privacy: .public),\(String(format: "%+.0f", rawPitch), privacy: .public)) out=(\(String(format: "%+.0f", self.smoothedYaw), privacy: .public),\(String(format: "%+.0f", self.smoothedPitch), privacy: .public))")
        }
        onSpeedCommand?(smoothedYaw, smoothedPitch)
    }

    // MARK: - 3D serpentine scan when face is lost

    /// Scan pattern: coast in exit direction, then systematic grid search.
    /// Sweeps yaw fully left→right, steps pitch down, sweeps right→left, etc.
    /// Like reading a page — covers the whole reachable space.
    private func searchForFace(shouldLog: Bool) {
        if lostFaceTime == nil {
            lostFaceTime = Date()
            scanSweepIndex = 0
            scanSweepStartTime = 0
            logger.info("FOLLOW: face lost — starting search (exit yaw=\(self.lastExitSide > 0 ? "right" : self.lastExitSide < 0 ? "left" : "center", privacy: .public) pitch=\(self.lastExitPitch > 0 ? "up" : self.lastExitPitch < 0 ? "down" : "center", privacy: .public))")
        }

        let elapsed = Date().timeIntervalSince(lostFaceTime!)

        guard elapsed < scanTimeout else {
            if shouldLog {
                logger.info("FOLLOW: scan timeout (\(String(format: "%.0f", self.scanTimeout), privacy: .public)s) — stopping")
            }
            onSpeedCommand?(0, 0)
            return
        }

        // Phase 1 (0–1.0s): Coast in exit direction
        if elapsed < 1.0 {
            let coastDecay = 1.0 - (elapsed / 1.0)
            let dir = lastExitSide != 0 ? lastExitSide : 1.0
            let yaw = dir * scanYawSpeed * coastDecay
            let pitch = lastExitPitch * scanPitchStep * coastDecay
            if shouldLog {
                logger.info("FOLLOW: coast (\(String(format: "%.1f", elapsed), privacy: .public)s) yaw=\(String(format: "%+.0f", yaw), privacy: .public) pitch=\(String(format: "%+.0f", pitch), privacy: .public)")
            }
            onSpeedCommand?(yaw, pitch)
            return
        }

        // Phase 2 (1.0s+): Serpentine grid scan
        let scanT = elapsed - 1.0

        // Which sweep are we on?
        let sweepIndex = Int(scanT / scanSweepDuration)
        let sweepT = scanT - Double(sweepIndex) * scanSweepDuration
        let sweepProgress = sweepT / scanSweepDuration  // 0→1

        // Clamp to scanRows * 2 sweeps (each row = one left + one right)
        if sweepIndex >= scanRows * 2 {
            if shouldLog {
                logger.info("FOLLOW: grid complete — stopping")
            }
            onSpeedCommand?(0, 0)
            return
        }

        // Did we just start a new sweep? → step pitch
        if sweepIndex != scanSweepIndex {
            scanSweepIndex = sweepIndex
        }

        // Yaw: alternate direction each sweep
        // Even sweeps go in exit direction, odd sweeps come back
        let startDir = lastExitSide != 0 ? lastExitSide : 1.0
        let yawDir = (sweepIndex % 2 == 0) ? startDir : -startDir

        // Ramp up at start, sustain, ramp down at end of each sweep
        let ramp: Double
        if sweepProgress < 0.1 {
            ramp = sweepProgress / 0.1
        } else if sweepProgress > 0.9 {
            ramp = (1.0 - sweepProgress) / 0.1
        } else {
            ramp = 1.0
        }
        let yaw = yawDir * scanYawSpeed * ramp

        // Pitch: step down (or up) at the transition between sweep pairs
        // Each pair of sweeps (left+right) = one row
        let rowIndex = sweepIndex / 2
        let pitchDir = lastExitPitch != 0 ? -lastExitPitch : -1.0  // scan opposite to exit
        // Brief pitch impulse at the start of each new row
        let pitch: Double
        if sweepIndex > 0 && sweepProgress < 0.15 && sweepIndex % 2 == 0 {
            pitch = pitchDir * scanPitchStep
        } else {
            pitch = 0
        }

        if shouldLog {
            logger.info("FOLLOW: scan row=\(rowIndex, privacy: .public)/\(self.scanRows, privacy: .public) sweep=\(sweepIndex % 2 == 0 ? "→" : "←", privacy: .public) yaw=\(String(format: "%+.0f", yaw), privacy: .public) pitch=\(String(format: "%+.0f", pitch), privacy: .public)")
        }
        onSpeedCommand?(yaw, pitch)
    }

    private func resetSearchState() {
        lostFaceTime = nil
        lastExitSide = 0
        lastExitPitch = 0
        scanSweepIndex = 0
        scanSweepStartTime = 0
    }

    // MARK: - Helpers

    /// Preserves sign, scales magnitude with x^0.7 so response is non-linear:
    /// aggressive for large errors, gentle for small ones.
    private static func powerScale(_ x: Double) -> Double {
        guard x != 0 else { return 0 }
        return (x < 0 ? -1 : 1) * pow(abs(x), 0.7)
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
