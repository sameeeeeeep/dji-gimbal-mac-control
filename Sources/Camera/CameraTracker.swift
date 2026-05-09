import AVFoundation
import Vision
import os
import CoreImage

/// Root directory for all camera captures (~/Movies/GimbalCaptures)
let gimbalCapturesDir: URL = {
    let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    return movies.appendingPathComponent("GimbalCaptures", isDirectory: true)
}()

enum TrackingType {
    case face
    case person
}

/// A subject detected in the current camera frame.
struct DetectedSubject {
    let bbox: CGRect            // Vision coords: bottom-left origin, normalised [0,1]
    let isSpeaking: Bool        // actively speaking right now (VAD + mouth)
    let isTracked: Bool         // driving the gimbal
    let speakerLabel: String?   // audio-identity label from ASR diarization, e.g. "0", "1"
    var recognizedName: String? = nil  // set by FaceRecognizer when known
}

/// Internal per-face tracking state maintained across frames (background thread only).
private struct FaceSlot {
    var center: CGPoint
    var confidence: Float     // accumulated speaking confidence 0–1
    var speakerNumber: Int?   // 1-based speaker index, assigned on first confirmed speech
}

/// A waypoint for the serpentine scan grid.
struct ScanWaypoint {
    let yaw: Double    // absolute degrees
    let pitch: Double  // absolute degrees
    let time: UInt8    // transition time in 10ms units (e.g. 20 = 200ms)
}

/// One entry in the room map built during the initial sweep.
struct SubjectMapEntry: Identifiable {
    let id = UUID()
    let speakerNumber: Int
    /// Approximate absolute gimbal angle (degrees) when this person was first detected.
    var approximateYaw: Double
    var approximatePitch: Double
    /// Optional user-assigned label (e.g. "Alice", "Presenter").
    var name: String? = nil
}

enum RoomSweepState {
    case idle
    case sweeping   // initial room scan in progress
    case ready      // sweep done, map populated — tracking active
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
    @Published var isScanning = false
    /// True while an open-palm gesture is actively guiding the gimbal.
    @Published var palmGestureActive = false
    /// True while a thumbs-up has locked the gimbal in place (even during follow mode).
    /// Show another thumbs-up or open palm to unlock.
    @Published var followLocked = false
    /// True while a pointing gesture is actively driving a seek-and-return.
    @Published var pointingGestureActive = false

    // ── Point-and-seek state ────────────────────────────────────────
    /// Phase of the current pointing-driven search.
    private enum PointSeekPhase { case idle, rotating, searching, returning }
    private var pointSeekPhase: PointSeekPhase = .idle
    /// Yaw/pitch the gimbal was at when seek started — restored on failure.
    private var pointSeekHomeYaw:   Double = 0
    private var pointSeekHomePitch: Double = 0
    private var pointSeekPhaseStart: Date?
    private var pointSeekTimer:     Timer?
    /// Whether follow was active before seek (so we can restore it on failure).
    private var pointSeekWasFollowing: Bool = false
    /// Synthetic bbox derived from the latest palm position; overrides face bbox in the
    /// follow loop so the gimbal steers toward whoever is waving their hand.
    /// Cleared automatically once face detection locks onto the new subject.
    private var palmGuideBbox: CGRect? = nil

    /// All subjects detected in the latest frame; drives the visual overlay.
    @Published var allSubjects: [DetectedSubject] = []

    // MARK: - Room sweep / subject map
    @Published var roomSweepState: RoomSweepState = .idle
    /// Persistent map of everyone detected during the initial sweep.
    @Published var subjectMap: [SubjectMapEntry] = []
    /// Current gimbal position during sweep — drives the splat-map cursor.
    @Published var sweepCurrentYaw: Double = 0
    @Published var sweepCurrentPitch: Double = 0

    // MARK: - Panorama
    let panoramaBuilder = PanoramaBuilder()
    /// Frames captured during the most recent sweep (MainActor-only).
    private var capturedScanFrames: [CapturedFrame] = []
    /// Guards latestPixelBuffer against concurrent write (camera queue) + read (MainActor).
    private let pixelBufferLock = NSLock()
    /// Last pixel buffer from the camera (written on camera queue, read on MainActor).
    nonisolated(unsafe) private var latestPixelBuffer: CVPixelBuffer? = nil
    /// CIContext for MainActor-only frame captures (journal / captureCurrentFrame).
    /// NOT shared with background tasks — CIContext is not concurrent-safe.
    private let ciCtxMain = CIContext(options: [.useSoftwareRenderer: false])
    /// Serial queue + dedicated CIContext for panorama background tasks.
    private let panoramaQueue = DispatchQueue(label: "com.gimbal.panorama", qos: .utility)
    nonisolated(unsafe) private let ciCtxPanorama = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Point-and-go navigation
    /// True while a tap-to-navigate move is in progress.
    @Published var isNavigating: Bool = false
    private var navTarget: (yaw: Double, pitch: Double)? = nil
    private var navTimer: Timer? = nil
    private var navStartTime: Date = .distantPast
    /// Degrees within target before we declare arrival.
    private let navArrivalDeg: Double = 8.0
    /// Hard upper bound — prevents indefinite navigation when BLE position is stale.
    private let navTimeoutSeconds: TimeInterval = 5.0

    private var sweepTimer: Timer?
    private var autoFollowAfterSweep: Bool = true
    private var sweepPhaseStart: Date = Date()
    private var sweepLastCollectTime: Date?

    // MARK: Column-first sweep config

    /// 7 columns, 45° apart — wide enough spacing to not get stuck navigating.
    private let sweepColumnYaws: [Double] = [-135, -90, -45, 0, 45, 90, 135]
    private let sweepPitchTop:    Double =  28    // top of scan range
    private let sweepPitchBottom: Double = -28    // bottom of scan range
    private var sweepCurrentCol:  Int    = 0

    private enum SweepPhase { case sprintToStart, sweepColumn, stepToNextColumn, returning, done }
    private var sweepPhase: SweepPhase = .done

    /// Wait after speed-command sprint to first column.
    private let sweepSprintDuration:     TimeInterval = 2.0
    /// Time to tilt through the full ±28° pitch range.
    private let sweepColumnDuration:     TimeInterval = 5.5
    /// Wait after speed-command step to next column (45° at sweepYawFast).
    private let sweepColumnStepDuration: TimeInterval = 0.6
    private let sweepCollectInterval:    TimeInterval = 0.35  // frame capture cadence

    /// Speed constants used only for the slow column pitch sweep.
    private let sweepYawFast:   Double = 900    // retained for legacy scan / voice search
    private let sweepPitchFast: Double = 300    // retained for legacy scan
    private let sweepPitchSlow: Double = 75     // slow tilt during column scan

    /// Dead-reckoned position estimate — updated at each phase transition so panorama
    /// frames have correct angular tags even when BLE position replies are stale.
    private var deadReckonYaw:   Double = 0
    private var deadReckonPitch: Double = 0

    /// Estimated camera horizontal FOV in degrees (used for world-position estimation).
    private let cameraFOVDeg: Double = 65

    /// Called by GimbalService so we can request a fresh position before each snapshot.
    var onRequestPosition: (() -> Void)?

    // MARK: - Speaker follow
    @Published var speakerFollowEnabled = false {
        didSet {
            bgSpeakerFollowEnabled = speakerFollowEnabled
            if speakerFollowEnabled {
                speakerManager.onSpeechStateChanged = { [weak self] active in
                    self?.bgSpeechActive = active
                }
                transcriber.activeSpeakerProvider = { [weak self] in self?.activeSpeakerLabel }
                speakerManager.start()
                if isRunning { startRoomSweep() }
            } else {
                speakerManager.onSpeechStateChanged = nil
                speakerManager.stop()
                bgSpeechActive = false
                faceSlots = []
                nextSpeakerNumber = 1
                voiceNoSpeakerFrames = 0
                lastSpeakingDate = nil
                allSubjects = []
                activeSpeakerLabel = nil
                cancelRoomSweep()
                subjectMap = []
                roomSweepState = .idle
            }
        }
    }

    /// Sub-components for speaker detection, transcription, and AI journaling.
    let speakerManager    = SpeakerFollowManager()
    let transcriber       = WhisperTranscriber()
    let journalAnalyzer   = JournalAnalyzer()
    let claudeAgent       = ClaudeAgent()
    let faceRecognizer    = FaceRecognizer()

    nonisolated(unsafe) private var bgSpeakerFollowEnabled: Bool = false
    /// Mirrors SpeakerFollowManager.isSpeechDetected for reading on the camera queue.
    nonisolated(unsafe) private var bgSpeechActive: Bool = false

    // MARK: - Per-face diarization state (background thread only)
    nonisolated(unsafe) private var faceSlots: [FaceSlot] = []
    nonisolated(unsafe) private var nextSpeakerNumber: Int = 1

    // MARK: - Voice-triggered search state (background thread only)
    /// Consecutive frames where speech is active but no face shows speaking confidence.
    /// When this exceeds the trigger threshold the bbox is withheld → follow loop scans.
    nonisolated(unsafe) private var voiceNoSpeakerFrames: Int = 0
    /// ~1.5 s at 30 fps before a voice-triggered scan fires.
    private nonisolated(unsafe) static let voiceSearchTriggerFrames = 45

    /// Timestamp of the last frame where a speaker was positively identified.
    /// Used to hold the tracked bbox for a few seconds after speech pauses so the
    /// gimbal doesn't snap away on brief silences between sentences.
    nonisolated(unsafe) private var lastSpeakingDate: Date? = nil
    /// How long to hold on a speaker after they go silent (seconds).
    private nonisolated(unsafe) static let speakerHoldSeconds: Double = 2.5

    // MARK: - Active-speaker label (published to WhisperTranscriber for attribution)
    /// Set to the label of whoever is currently speaking; nil when nobody is.
    @Published var activeSpeakerLabel: String? = nil

    // MARK: - Capture state
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastPhotoURL: URL?
    @Published var lastVideoURL: URL?

    /// True while a timelapse capture is in progress.
    @Published var isTimelapsing = false
    /// Number of frames written to the current timelapse so far.
    @Published var timelapseFrameCount: Int = 0
    /// Wall-clock seconds elapsed since timelapse started.
    @Published var timelapseDuration: TimeInterval = 0
    /// Capture interval for new timelapses, in seconds. Adjustable via Settings.
    @Published var timelapseInterval: TimeInterval = 2.0
    /// Output playback frame rate for the encoded timelapse video.
    private let timelapseOutputFPS: Int32 = 24

    // Capture outputs (strong refs; nil when camera is stopped)
    private var photoOutput: AVCapturePhotoOutput?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var recordingTimer: Timer?

    // Timelapse encoder state
    private var tlWriter:    AVAssetWriter?
    private var tlInput:     AVAssetWriterInput?
    private var tlAdaptor:   AVAssetWriterInputPixelBufferAdaptor?
    private var tlTimer:     Timer?
    private var tlURL:       URL?
    private var tlStartDate: Date?

    /// Set by GimbalService to receive speed commands from the follow loop.
    var onSpeedCommand: ((_ yaw: Double, _ pitch: Double) -> Void)?

    /// Set by GimbalService to send absolute angle commands for scan waypoints.
    var onAbsoluteMove: ((_ yaw: Double, _ pitch: Double, _ time: UInt8) -> Void)?

    /// Set by GimbalService so we can read current gimbal position.
    var getCurrentPosition: (() -> GimbalPosition)?

    private(set) var captureSession: AVCaptureSession?
    private var followTimer: Timer?
    private var frameCount = 0
    private var lastFrameTime: Date?
    private let logger = Logger(subsystem: "com.gimbal.controller", category: "Camera")
    nonisolated(unsafe) private var bgTrackingType: TrackingType = .face
    nonisolated(unsafe) private var bgPalmFrameCount: Int = 0
    nonisolated(unsafe) private var bgThumbsUpFrameCount: Int = 0
    nonisolated(unsafe) private var bgPointingFrameCount: Int = 0
    private let palmConfirmFrames: Int = 20  // ~0.67 s at 30 fps
    private let thumbsUpConfirmFrames: Int = 15   // ~0.5 s
    private let pointingConfirmFrames: Int = 12   // ~0.4 s

    // --- Smoothed output (EMA filter — kills oscillation at any gain) ---
    private var smoothedYaw: Double = 0
    private var smoothedPitch: Double = 0
    private let smoothing: Double = 0.15

    // --- Serpentine scan state ---
    private var lastExitSide: Double = 0
    private var lastExitPitch: Double = 0
    private var lostFaceTime: Date?
    private var scanWaypoints: [ScanWaypoint] = []
    private var scanWaypointIndex: Int = 0
    private var lastWaypointSentTime: Date?
    private let scanTimeout: TimeInterval = 12.0

    // --- Reacquisition debounce (prevent scan reset from flicker) ---
    private var consecutiveDetections: Int = 0
    private let reacquireThreshold: Int = 5  // need 5 consecutive frames (~170ms) to confirm

    // Gimbal mechanical limits (degrees)
    private let yawMin: Double = -160
    private let yawMax: Double = 160
    private let pitchMin: Double = -35
    private let pitchMax: Double = 35
    // Scan grid parameters
    private let scanPitchStep: Double = 15    // degrees between rows
    private let scanTransitTime: UInt8 = 15   // 150ms per waypoint transition
    private let scanDwellTime: TimeInterval = 1.8  // seconds to hold each sweep endpoint (face scan)
    private let voiceSearchDwellTime: TimeInterval = 0.7  // faster dwell for voice-triggered sweep

    /// Dwell time used for the current scan — short when actively chasing a voice.
    private var activeDwellTime: TimeInterval {
        speakerFollowEnabled && speakerManager.isSpeechDetected ? voiceSearchDwellTime : scanDwellTime
    }

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

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.gimbal.camera"))
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        let photo = AVCapturePhotoOutput()
        if session.canAddOutput(photo) {
            session.addOutput(photo)
            photoOutput = photo
        }

        let movie = AVCaptureMovieFileOutput()
        if session.canAddOutput(movie) {
            session.addOutput(movie)
            movieOutput = movie
        }

        captureSession = session
        session.startRunning()
        isRunning = true
        logger.info("Camera started: \(camera.localizedName)")
    }

    func stopCamera() {
        if isRecording { stopRecording() }
        if isTimelapsing { stopTimelapse() }
        cancelRoomSweep()
        if speakerFollowEnabled { speakerFollowEnabled = false }
        if transcriber.isTranscribing { transcriber.stop() }
        stopFollow()
        captureSession?.stopRunning()
        captureSession = nil
        photoOutput = nil
        movieOutput = nil
        isRunning = false
        detectedBbox = nil
    }

    // MARK: - Photo Capture

    func capturePhoto() {
        guard let output = photoOutput, isRunning else { return }
        let settings: AVCapturePhotoSettings
        if output.availablePhotoCodecTypes.contains(.jpeg) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else {
            settings = AVCapturePhotoSettings()
        }
        output.capturePhoto(with: settings, delegate: self)
        logger.info("Photo capture triggered")
    }

    // MARK: - Video Recording

    func startRecording() {
        guard let output = movieOutput, isRunning, !isRecording else { return }
        let dir = gimbalCapturesDir.appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = dir.appendingPathComponent("gimbal_\(formatter.string(from: Date())).mov")
        output.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recordingDuration += 1 }
        }
        logger.info("Video recording started → \(url.lastPathComponent)")
    }

    func stopRecording() {
        guard isRecording else { return }
        movieOutput?.stopRecording()
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false
        logger.info("Video recording stopped")
    }

    // MARK: - Timelapse
    //
    // Captures a frame every `timelapseInterval` seconds via captureCurrentFrame()
    // and feeds it into an AVAssetWriter at `timelapseOutputFPS` (24fps).
    // Result: at interval=2s, every 1 hour of real time = 75s of playback.

    func startTimelapse() {
        guard isRunning, !isTimelapsing else { return }

        // Need at least one frame to determine output dimensions
        guard let firstFrame = captureCurrentFrame() else {
            logger.error("Timelapse: no frame available — start camera first")
            return
        }
        // H.264 requires even dimensions. Odd → silently corrupted file (QuickTime
        // refuses to open). Round down to nearest even number.
        let w = firstFrame.width  - (firstFrame.width  % 2)
        let h = firstFrame.height - (firstFrame.height % 2)
        guard w >= 16, h >= 16 else {
            logger.error("Timelapse: source frame too small \(w)×\(h)")
            return
        }

        let dir = gimbalCapturesDir.appendingPathComponent("Timelapses", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        // .mov container — QuickTime native, more forgiving than .mp4 for AVAssetWriter output.
        let url = dir.appendingPathComponent("timelapse_\(fmt.string(from: Date())).mov")
        // Pre-emptively delete any stale file at the same path (writer refuses to overwrite).
        try? FileManager.default.removeItem(at: url)

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            // Periodic moov-atom fragments → file is playable even mid-write or on crash.
            writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey:  AVVideoCodecType.h264,
                AVVideoWidthKey:  w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey:           8_000_000,
                    AVVideoExpectedSourceFrameRateKey:  timelapseOutputFPS,
                    AVVideoMaxKeyFrameIntervalKey:      Int(timelapseOutputFPS),  // 1s GOP
                    AVVideoProfileLevelKey:             AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey  as String: w,
                    kCVPixelBufferHeightKey as String: h
                ]
            )
            guard writer.canAdd(input) else {
                logger.error("Timelapse: writer can't add input")
                return
            }
            writer.add(input)
            guard writer.startWriting() else {
                logger.error("Timelapse: startWriting failed: \(writer.error?.localizedDescription ?? "?")")
                return
            }
            writer.startSession(atSourceTime: .zero)

            tlWriter      = writer
            tlInput       = input
            tlAdaptor     = adaptor
            tlURL         = url
            tlStartDate   = Date()
            timelapseFrameCount = 0
            timelapseDuration   = 0
            isTimelapsing       = true
        } catch {
            logger.error("Timelapse: AVAssetWriter init failed: \(error.localizedDescription)")
            return
        }

        // Capture frame 0 immediately so the output is non-empty even on quick stops
        appendTimelapseFrame()

        let interval = timelapseInterval
        tlTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appendTimelapseFrame()
                if let start = self.tlStartDate {
                    self.timelapseDuration = Date().timeIntervalSince(start)
                }
            }
        }
        logger.info("Timelapse started → \(url.lastPathComponent), every \(interval)s, target \(self.timelapseOutputFPS) fps playback")
    }

    func stopTimelapse() {
        guard isTimelapsing else { return }
        tlTimer?.invalidate(); tlTimer = nil

        let writer  = tlWriter
        let input   = tlInput
        let url     = tlURL
        let frames  = timelapseFrameCount

        input?.markAsFinished()
        writer?.finishWriting { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = writer?.status ?? .unknown
                let err    = writer?.error
                if status == .completed, let url {
                    self.lastVideoURL = url
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
                    self.logger.info("Timelapse finalized: \(frames) frames, \(size) bytes → \(url.lastPathComponent, privacy: .public)")
                } else {
                    let statusName: String
                    switch status {
                    case .unknown:    statusName = "unknown"
                    case .writing:    statusName = "writing"
                    case .completed:  statusName = "completed"
                    case .failed:     statusName = "failed"
                    case .cancelled:  statusName = "cancelled"
                    @unknown default: statusName = "?"
                    }
                    self.logger.error("Timelapse finalize: status=\(statusName, privacy: .public) frames=\(frames) error=\(err?.localizedDescription ?? "nil", privacy: .public)")
                }
            }
        }

        tlWriter      = nil
        tlInput       = nil
        tlAdaptor     = nil
        tlURL         = nil
        tlStartDate   = nil
        isTimelapsing = false
    }

    private func appendTimelapseFrame() {
        guard let adaptor = tlAdaptor,
              let input   = tlInput,
              let writer  = tlWriter,
              let cgImage = captureCurrentFrame()
        else { return }
        guard writer.status == .writing else {
            logger.error("Timelapse: writer status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "nil") — stopping")
            stopTimelapse()
            return
        }
        guard input.isReadyForMoreMediaData else { return }

        guard let pb = Self.pixelBufferFromCGImage(cgImage, pool: adaptor.pixelBufferPool) else {
            logger.error("Timelapse: pixel buffer creation failed")
            return
        }

        let pts = CMTime(value: Int64(timelapseFrameCount), timescale: timelapseOutputFPS)
        let ok = adaptor.append(pb, withPresentationTime: pts)
        if !ok {
            logger.error("Timelapse: append failed at frame \(self.timelapseFrameCount): \(writer.error?.localizedDescription ?? "?")")
            return
        }
        timelapseFrameCount += 1
    }

    /// Renders a CGImage into a CVPixelBuffer, preferring the writer's pool when available.
    private static func pixelBufferFromCGImage(_ image: CGImage, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        let w = image.width, h = image.height
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        }
        if buffer == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String:        true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
            CVPixelBufferCreate(
                kCFAllocatorDefault, w, h,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary, &buffer
            )
        }
        guard let pb = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width:  CVPixelBufferGetWidth(pb),
            height: CVPixelBufferGetHeight(pb),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(
            x: 0, y: 0,
            width: CGFloat(CVPixelBufferGetWidth(pb)),
            height: CGFloat(CVPixelBufferGetHeight(pb))
        ))
        return pb
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
                // Room sweep and point-and-go navigation have exclusive gimbal control
                guard self.roomSweepState != .sweeping else { return }
                guard !self.isNavigating else { return }
                // Thumbs-up lock — hold position, send zero speed
                if self.followLocked {
                    self.onSpeedCommand?(0, 0)
                    return
                }
                logTick += 1
                let shouldLog = (logTick % 15 == 0)

                // Palm guide takes priority over face detection bbox
                let activeBbox = self.palmGuideBbox ?? self.detectedBbox
                if let bbox = activeBbox {
                    if self.isScanning {
                        // Mid-scan: require sustained detection before aborting scan
                        self.consecutiveDetections += 1
                        if self.consecutiveDetections >= self.reacquireThreshold {
                            self.logger.error("FOLLOW: face confirmed after \(self.consecutiveDetections, privacy: .public) frames — resuming track")
                            self.resetSearchState()
                            self.trackFace(bbox, shouldLog: shouldLog)
                        }
                        // Still scanning — don't send speed commands, just wait
                    } else {
                        self.trackFace(bbox, shouldLog: shouldLog)
                    }
                } else {
                    self.consecutiveDetections = 0
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
        stopNavigation()
    }

    // MARK: - Point-and-go navigation

    /// Navigate gimbal to the given absolute (yaw, pitch) using speed commands,
    /// polling the current position every 100 ms until arrival.
    func navigateTo(yaw: Double, pitch: Double) {
        stopNavigation()
        navTarget = (yaw: yaw, pitch: pitch)
        navStartTime = Date()
        isNavigating = true
        navTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.navTick() }
        }
        onRequestPosition?()
        logger.info("NAV: → yaw=\(String(format: "%.0f", yaw))° pitch=\(String(format: "%.0f", pitch))°")
    }

    private func navTick() {
        // Hard timeout prevents infinite navigation when BLE position data is stale
        if Date().timeIntervalSince(navStartTime) > navTimeoutSeconds {
            onSpeedCommand?(0, 0)
            stopNavigation()
            logger.warning("NAV: timeout — stopping")
            return
        }

        guard let target = navTarget,
              let pos = getCurrentPosition?() else { return }
        onRequestPosition?()

        let dyaw   = target.yaw   - pos.yaw
        let dpitch = target.pitch - pos.pitch

        if abs(dyaw) < navArrivalDeg && abs(dpitch) < navArrivalDeg {
            onSpeedCommand?(0, 0)
            stopNavigation()
            logger.info("NAV: arrived")
            return
        }

        let yawSpeed   = abs(dyaw)   < navArrivalDeg ? 0.0 : (dyaw   > 0 ? sweepYawFast   : -sweepYawFast)
        let pitchSpeed = abs(dpitch) < navArrivalDeg ? 0.0 : (dpitch > 0 ? sweepPitchFast : -sweepPitchFast)
        onSpeedCommand?(yawSpeed, pitchSpeed)
    }

    private func stopNavigation() {
        navTimer?.invalidate()
        navTimer = nil
        navTarget = nil
        isNavigating = false
    }

    // MARK: - Room sweep

    /// Standalone serpentine room scan — 3 pitch rows, full yaw range each,
    /// returns gimbal to centre when done.
    func scanRoom() {
        guard isRunning else { return }
        startRoomSweep(autoFollow: false)
    }

    private func startRoomSweep(autoFollow: Bool = true) {
        cancelRoomSweep()
        resetSearchState()
        subjectMap = []
        capturedScanFrames = []
        faceSlots = []
        nextSpeakerNumber = 1
        voiceNoSpeakerFrames = 0
        autoFollowAfterSweep = autoFollow
        sweepCurrentCol = 0

        roomSweepState = .sweeping
        sweepPhase = .sprintToStart
        sweepPhaseStart = Date()
        sweepLastCollectTime = nil
        sweepCurrentYaw = sweepColumnYaws[0]
        sweepCurrentPitch = sweepPitchTop
        deadReckonYaw   = sweepColumnYaws[0]
        deadReckonPitch = sweepPitchTop

        // Speed command to sprint to top-left corner
        onSpeedCommand?(-sweepYawFast, sweepPitchFast)

        sweepTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sweepTick() }
        }
        logger.info("SWEEP: column-first started — \(self.sweepColumnYaws.count) columns, autoFollow=\(autoFollow)")
    }

    private func sweepTick() {
        guard roomSweepState == .sweeping else { return }
        onRequestPosition?()   // keep position data fresh for face mapping

        let now = Date()
        let elapsed = now.timeIntervalSince(sweepPhaseStart)

        switch sweepPhase {

        case .sprintToStart:
            // Reached top-left corner — begin first column scan
            if elapsed >= sweepSprintDuration {
                beginColumnSweep(at: now)
            }

        case .sweepColumn:
            // Live cursor update
            if let pos = getCurrentPosition?() {
                sweepCurrentYaw   = pos.yaw
                sweepCurrentPitch = pos.pitch
            }

            // Collect faces regularly
            if let last = sweepLastCollectTime,
               now.timeIntervalSince(last) >= sweepCollectInterval {
                collectFacesForMap()
                sweepLastCollectTime = now
            }

            if elapsed >= sweepColumnDuration {
                sweepCurrentCol += 1
                onSpeedCommand?(0, 0)
                if sweepCurrentCol < sweepColumnYaws.count {
                    beginColumnStep(at: now)
                } else {
                    beginReturn(at: now)
                }
            }

        case .stepToNextColumn:
            if elapsed >= sweepColumnStepDuration {
                beginColumnSweep(at: now)
            }

        case .returning:
            if let pos = getCurrentPosition?() {
                if abs(pos.yaw) < 12 && abs(pos.pitch) < 8 {
                    onSpeedCommand?(0, 0)
                    finishRoomSweep()
                }
            }
            if elapsed >= 3.0 {
                onSpeedCommand?(0, 0)
                finishRoomSweep()
            }

        case .done:
            break
        }
    }

    // MARK: Sweep phase helpers

    private func beginColumnSweep(at now: Date) {
        sweepPhase = .sweepColumn
        sweepPhaseStart = now
        sweepLastCollectTime = now
        // Even columns scan top→bottom, odd columns scan bottom→top (less repositioning)
        let pitchDir: Double = sweepCurrentCol % 2 == 0 ? -1 : 1
        onSpeedCommand?(0, pitchDir * sweepPitchSlow)
        let colYaw = sweepColumnYaws[min(sweepCurrentCol, sweepColumnYaws.count - 1)]
        // Update dead-reckoned start: we've stepped to this column's yaw; pitch is at top or bottom
        deadReckonYaw   = colYaw
        deadReckonPitch = pitchDir > 0 ? sweepPitchBottom : sweepPitchTop   // we start at the far end
        logger.info("SWEEP: column \(self.sweepCurrentCol) at yaw≈\(String(format: "%.0f", colYaw))°, dir \(pitchDir > 0 ? "↑" : "↓")")
    }

    private func beginColumnStep(at now: Date) {
        sweepPhase = .stepToNextColumn
        sweepPhaseStart = now
        onSpeedCommand?(sweepYawFast, 0)
        logger.info("SWEEP: stepping to column \(self.sweepCurrentCol)")
    }

    private func beginReturn(at now: Date) {
        sweepPhase = .returning
        sweepPhaseStart = now
        let pos = getCurrentPosition?() ?? GimbalPosition()
        let yawSpeed   = pos.yaw   > 0 ? -sweepYawFast   :  sweepYawFast
        let pitchSpeed = pos.pitch < 0 ?  sweepPitchFast : -sweepPitchFast
        onSpeedCommand?(yawSpeed, pitchSpeed)
        logger.info("SWEEP: returning to centre from yaw=\(String(format: "%.0f", pos.yaw))° pitch=\(String(format: "%.0f", pos.pitch))°")
    }

    /// Snapshot any subjects currently in frame: update the subject map + capture a frame for panorama.
    private func collectFacesForMap() {
        // Prefer BLE position; fall back to dead-reckoned estimate when BLE returns (0,0).
        // During movement the gimbal often doesn't respond to position polls quickly enough,
        // so dead-reckoning prevents all frames from landing at the canvas origin.
        let blePos = getCurrentPosition?() ?? GimbalPosition()
        let useBLE = abs(blePos.yaw) > 2.0 || abs(blePos.pitch) > 2.0

        let estimatedPitch: Double
        if sweepPhase == .sweepColumn {
            let elapsed = Date().timeIntervalSince(sweepPhaseStart)
            let frac    = min(elapsed / sweepColumnDuration, 1.0)
            let pitchDir: Double = sweepCurrentCol % 2 == 0 ? -1 : 1
            let startP = pitchDir > 0 ? sweepPitchBottom : sweepPitchTop
            let endP   = pitchDir > 0 ? sweepPitchTop    : sweepPitchBottom
            estimatedPitch = startP + (endP - startP) * frac
        } else {
            estimatedPitch = deadReckonPitch
        }

        let pos = useBLE ? blePos
                         : GimbalPosition(yaw: deadReckonYaw, pitch: estimatedPitch, roll: 0)

        if !useBLE {
            logger.debug("SWEEP: BLE position stale — using dead-reckoned yaw=\(String(format:"%.0f",pos.yaw))° pitch=\(String(format:"%.0f",pos.pitch))°")
        }

        // ── Face map ──────────────────────────────────────────────────────────
        for subject in allSubjects {
            let faceOffsetYaw   = (Double(subject.bbox.midX) - 0.5) * cameraFOVDeg
            let faceOffsetPitch = (0.5 - Double(subject.bbox.midY)) * (cameraFOVDeg * 0.75)
            let absYaw   = clampYaw(pos.yaw   + faceOffsetYaw)
            let absPitch = clampPitch(pos.pitch + faceOffsetPitch)

            // Merge radius 40° — same person detected across multiple rows averages into one dot.
            if let idx = subjectMap.firstIndex(where: { e in
                let dy = e.approximateYaw   - absYaw
                let dp = e.approximatePitch - absPitch
                return (dy * dy + dp * dp) < 40 * 40
            }) {
                // Refine position with weighted running average (70% old, 30% new detection)
                subjectMap[idx].approximateYaw   = 0.7 * subjectMap[idx].approximateYaw   + 0.3 * absYaw
                subjectMap[idx].approximatePitch = 0.7 * subjectMap[idx].approximatePitch + 0.3 * absPitch
                continue
            }

            let entry = SubjectMapEntry(
                speakerNumber: nextSpeakerNumber,
                approximateYaw: absYaw,
                approximatePitch: absPitch
            )
            subjectMap.append(entry)
            nextSpeakerNumber += 1
            logger.info("SWEEP: person \(entry.speakerNumber) at yaw=\(String(format: "%.0f", absYaw))° pitch=\(String(format: "%.0f", absPitch))°")
        }

        // ── Panorama frame capture ─────────────────────────────────────────────
        captureFrameForPanorama(yaw: pos.yaw, pitch: pos.pitch)
    }

    /// Synchronously grabs the current camera frame as a CGImage for external analysis.
    /// Runs on MainActor — uses the MainActor-only CIContext.
    func captureCurrentFrame() -> CGImage? {
        pixelBufferLock.lock()
        let pb = latestPixelBuffer
        pixelBufferLock.unlock()
        guard let pb else { return nil }
        let ci    = CIImage(cvPixelBuffer: pb)
        let scale = min(1.0, 512.0 / ci.extent.width)
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciCtxMain.createCGImage(small, from: small.extent)
    }

    private func captureFrameForPanorama(yaw: Double, pitch: Double) {
        pixelBufferLock.lock()
        let pb = latestPixelBuffer
        pixelBufferLock.unlock()
        guard let pb else { return }

        // Hold onto local copies; run on the serial panoramaQueue so the dedicated
        // ciCtxPanorama is never used concurrently (CIContext is not concurrent-safe).
        let localBuffer  = pb
        let localContext = ciCtxPanorama
        panoramaQueue.async { [weak self] in
            let ci    = CIImage(cvPixelBuffer: localBuffer)
            let scale = min(1.0, 480.0 / ci.extent.width)
            let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = localContext.createCGImage(small, from: small.extent) else { return }
            let frame = CapturedFrame(image: cg, yaw: yaw, pitch: pitch)
            DispatchQueue.main.async { [weak self] in
                self?.capturedScanFrames.append(frame)
            }
        }
    }

    private func finishRoomSweep() {
        sweepPhase = .done
        cancelRoomSweep()
        roomSweepState = .ready

        // Wait for any in-flight panorama frame tasks to finish before building
        panoramaQueue.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                logger.info("SWEEP: complete — \(self.subjectMap.count) person(s) mapped, \(self.capturedScanFrames.count) frames captured")
                let frames = self.capturedScanFrames
                if !frames.isEmpty {
                    self.panoramaBuilder.build(from: frames)
                } else {
                    logger.error("SWEEP: no panorama frames — camera may not have been active or position data was unavailable")
                }
                let faceSlotsCopy = self.subjectMap.map { FaceSlot(center: .zero, confidence: 0, speakerNumber: $0.speakerNumber) }
                self.faceSlots = faceSlotsCopy

                // Auto-start journal after scan completes
                if !self.journalAnalyzer.isAnalyzing {
                    self.journalAnalyzer.start(tracker: self, transcriber: self.transcriber)
                }

                guard self.autoFollowAfterSweep else { return }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard let self, self.isRunning, !self.isFollowing else { return }
                    self.startFollow()
                }
            }
        }
    }

    private func cancelRoomSweep() {
        sweepTimer?.invalidate()
        sweepTimer = nil
        sweepPhase = .done
        onSpeedCommand?(0, 0)
        stopNavigation()
        if roomSweepState == .sweeping { roomSweepState = .idle }
    }

    // MARK: - Tracking (proportional + EMA smoothing)

    private func trackFace(_ bbox: CGRect, shouldLog: Bool) {
        if lostFaceTime != nil {
            logger.info("FOLLOW: face reacquired!")
            resetSearchState()
        }

        let ex = bbox.midX - 0.5
        let ey = bbox.midY - 0.5

        let dx = abs(ex) < deadZone ? 0.0 : ex
        let dy = abs(ey) < deadZone ? 0.0 : ey

        let rawYaw   = Self.powerScale(dx) * gain * 1500
        let rawPitch = Self.powerScale(dy) * gain * 1500

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
            self.logger.info("FOLLOW: face=(\(String(format: "%.2f", bbox.midX), privacy: .public),\(String(format: "%.2f", bbox.midY), privacy: .public)) err=(\(String(format: "%+.3f", dx), privacy: .public),\(String(format: "%+.3f", dy), privacy: .public)) out=(\(String(format: "%+.0f", self.smoothedYaw), privacy: .public),\(String(format: "%+.0f", self.smoothedPitch), privacy: .public))")
        }
        onSpeedCommand?(smoothedYaw, smoothedPitch)
    }

    // MARK: - Position-aware serpentine scan

    private func searchForFace(shouldLog: Bool) {
        // First frame lost — stop speed control and choose a scan strategy
        if lostFaceTime == nil {
            lostFaceTime = Date()
            onSpeedCommand?(0, 0)  // stop speed mode before switching to absolute
            if speakerFollowEnabled && speakerManager.isSpeechDetected {
                buildVoiceSearchGrid()
                logger.error("FOLLOW: voice search started (speech active, speaker out of frame)")
            } else {
                buildScanGrid()
                logger.error("FOLLOW: face lost — built \(self.scanWaypoints.count, privacy: .public) waypoints")
            }
            isScanning = true
        }

        let elapsed = Date().timeIntervalSince(lostFaceTime!)

        guard elapsed < scanTimeout, scanWaypointIndex < scanWaypoints.count else {
            // If speaker follow is on and someone is still talking, keep searching.
            // Rebuild the grid from the current gimbal position so the scan covers
            // fresh ground rather than re-tracing the same path.
            if speakerFollowEnabled && speakerManager.isSpeechDetected {
                logger.error("FOLLOW: scan complete, voice still active — repeating voice search")
                lostFaceTime = Date()
                buildVoiceSearchGrid()
                return
            }
            if shouldLog {
                logger.error("FOLLOW: scan complete — stopping")
            }
            isScanning = false
            onSpeedCommand?(0, 0)
            return
        }

        // IMPORTANT: don't send any speed commands while scanning —
        // absolute angle commands would be immediately overridden by the
        // speed timer in GimbalService. Just send waypoints.

        let shouldAdvance: Bool
        if let lastSent = lastWaypointSentTime {
            shouldAdvance = Date().timeIntervalSince(lastSent) >= activeDwellTime
        } else {
            shouldAdvance = true
        }

        if shouldAdvance {
            let wp = scanWaypoints[scanWaypointIndex]
            onAbsoluteMove?(wp.yaw, wp.pitch, wp.time)
            lastWaypointSentTime = Date()

            logger.error("FOLLOW: scan waypoint \(self.scanWaypointIndex, privacy: .public)/\(self.scanWaypoints.count, privacy: .public) → yaw=\(String(format: "%.0f", wp.yaw), privacy: .public)° pitch=\(String(format: "%.0f", wp.pitch), privacy: .public)°")
            scanWaypointIndex += 1
        }
    }

    /// Build a serpentine scan grid based on current gimbal position.
    ///
    /// The scan starts from where the face was lost, coasts in the exit direction,
    /// then sweeps yaw fully in one direction, steps pitch, sweeps back, steps pitch, etc.
    ///
    /// ```
    /// (start) ━━━━━━━━━━━━━━━━━━▶ (yaw limit)
    ///                              ↓ (pitch step)
    ///         ◀━━━━━━━━━━━━━━━━━━ (sweep back)
    ///         ↓ (pitch step)
    ///         ━━━━━━━━━━━━━━━━━━▶
    ///                              ↓
    ///         ◀━━━━━━━━━━━━━━━━━━
    /// ```
    private func buildScanGrid() {
        scanWaypoints = []
        scanWaypointIndex = 0
        lastWaypointSentTime = nil

        let pos = getCurrentPosition?() ?? GimbalPosition()
        let currentYaw = pos.yaw
        let currentPitch = pos.pitch

        logger.info("FOLLOW: building scan from yaw=\(String(format: "%.0f", currentYaw), privacy: .public)° pitch=\(String(format: "%.0f", currentPitch), privacy: .public)° exit=(\(self.lastExitSide > 0 ? "R" : self.lastExitSide < 0 ? "L" : "?", privacy: .public),\(self.lastExitPitch > 0 ? "U" : self.lastExitPitch < 0 ? "D" : "?", privacy: .public))")

        // Step 1: Coast — one waypoint in the exit direction
        let coastYaw = clampYaw(currentYaw + lastExitSide * 40)
        let coastPitch = clampPitch(currentPitch + lastExitPitch * 10)
        scanWaypoints.append(ScanWaypoint(yaw: coastYaw, pitch: coastPitch, time: 12))

        // Step 2: Build row endpoints for serpentine
        // Determine sweep direction: first sweep goes in exit direction
        let sweepFirst: Double  // yaw limit to sweep toward first
        let sweepSecond: Double // yaw limit to sweep back to
        if lastExitSide >= 0 {
            sweepFirst = yawMax
            sweepSecond = yawMin
        } else {
            sweepFirst = yawMin
            sweepSecond = yawMax
        }

        // Determine pitch scanning direction: scan opposite to exit (cover unseen area)
        // If exited up, scan downward from current; if exited down, scan upward
        let pitchDir: Double = (lastExitPitch > 0) ? -1.0 : 1.0
        // But also include rows above and below the lost position
        let startPitch = coastPitch

        // Build rows: start from coast position, step pitch each row
        var currentRowPitch = startPitch
        var goingToFirst = true  // alternate sweep direction

        for _ in 0..<6 {
            let rowPitch = clampPitch(currentRowPitch)

            if goingToFirst {
                // Sweep to first limit
                scanWaypoints.append(ScanWaypoint(yaw: sweepFirst, pitch: rowPitch, time: scanTransitTime))
            } else {
                // Sweep back to second limit
                scanWaypoints.append(ScanWaypoint(yaw: sweepSecond, pitch: rowPitch, time: scanTransitTime))
            }
            goingToFirst.toggle()

            // Step pitch for next row
            currentRowPitch += pitchDir * scanPitchStep

            // If we hit a pitch limit, reverse direction
            if currentRowPitch > pitchMax {
                currentRowPitch = pitchMax
                break
            }
            if currentRowPitch < pitchMin {
                currentRowPitch = pitchMin
                break
            }
        }

        // Final waypoint: return to where we started
        scanWaypoints.append(ScanWaypoint(yaw: currentYaw, pitch: currentPitch, time: 20))
    }

    /// Fast left-right sweep used when a speaker is out of frame.
    ///
    /// Instead of the full serpentine (which wastes time on pitch rows), this just
    /// hammers the gimbal to its yaw limits and back at the current pitch so it
    /// covers the widest possible horizontal range as quickly as possible.
    /// Each sweep cycle takes ~3 × dwell (≈ 2.1 s), then repeats while voice is active.
    private func buildVoiceSearchGrid() {
        scanWaypoints = []
        scanWaypointIndex = 0
        lastWaypointSentTime = nil

        let pos = getCurrentPosition?() ?? GimbalPosition()
        let pitch = clampPitch(pos.pitch)

        // Determine sweep start direction from last exit side (or default left)
        // Use time:200 (2000 ms) — large enough for the gimbal to complete a full
        // ±160° rotation (max speed ~120°/s → 1.33 s for 160°).
        if lastExitSide >= 0 {
            scanWaypoints = [
                ScanWaypoint(yaw: yawMax, pitch: pitch, time: 200), // right limit
                ScanWaypoint(yaw: yawMin, pitch: pitch, time: 200), // left limit
                ScanWaypoint(yaw: 0,      pitch: pitch, time: 200), // center
            ]
        } else {
            scanWaypoints = [
                ScanWaypoint(yaw: yawMin, pitch: pitch, time: 200), // left limit
                ScanWaypoint(yaw: yawMax, pitch: pitch, time: 200), // right limit
                ScanWaypoint(yaw: 0,      pitch: pitch, time: 200), // center
            ]
        }
        isScanning = true
        logger.error("FOLLOW: voice search grid — 3 waypoints at pitch=\(String(format: "%.0f", pitch))°")
    }

    private func clampYaw(_ v: Double) -> Double {
        min(max(v, yawMin), yawMax)
    }

    private func clampPitch(_ v: Double) -> Double {
        min(max(v, pitchMin), pitchMax)
    }

    private func resetSearchState() {
        lostFaceTime = nil
        lastExitSide = 0
        lastExitPitch = 0
        scanWaypoints = []
        scanWaypointIndex = 0
        lastWaypointSentTime = nil
        isScanning = false
        consecutiveDetections = 0
    }

    // MARK: - Helpers

    private static func powerScale(_ x: Double) -> Double {
        guard x != 0 else { return 0 }
        return (x < 0 ? -1 : 1) * pow(abs(x), 0.7)
    }
}

// MARK: - Photo capture delegate

extension CameraTracker: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishProcessingPhoto photo: AVCapturePhoto,
                                  error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            Logger(subsystem: "com.gimbal.controller", category: "Camera")
                .error("Photo capture failed: \(error?.localizedDescription ?? "no data")")
            return
        }
        let dir = gimbalCapturesDir.appendingPathComponent("Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = dir.appendingPathComponent("gimbal_\(formatter.string(from: Date())).jpg")
        do {
            try data.write(to: url)
            Task { @MainActor [weak self] in self?.lastPhotoURL = url }
        } catch {
            Logger(subsystem: "com.gimbal.controller", category: "Camera")
                .error("Failed to save photo: \(error.localizedDescription)")
        }
    }
}

// MARK: - Movie recording delegate

extension CameraTracker: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                 didFinishRecordingTo outputFileURL: URL,
                                 from connections: [AVCaptureConnection],
                                 error: Error?) {
        if let error {
            Logger(subsystem: "com.gimbal.controller", category: "Camera")
                .error("Recording finished with error: \(error.localizedDescription)")
        }
        Task { @MainActor [weak self] in self?.lastVideoURL = outputFileURL }
    }
}

// MARK: - Sample buffer delegate (background thread)

extension CameraTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Store for panorama frame capture (read on MainActor in collectFacesForMap)
        pixelBufferLock.lock()
        latestPixelBuffer = pixelBuffer
        pixelBufferLock.unlock()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)

        // Hand pose runs in every mode so open-palm gesture always works
        let handRequest = VNDetectHumanHandPoseRequest { [weak self] req, _ in
            guard let self else { return }
            let obs = (req.results as? [VNHumanHandPoseObservation]) ?? []
            self.processPalmGesture(obs)
        }
        handRequest.maximumHandCount = 2

        if bgSpeakerFollowEnabled {
            // Speaker follow: detect ALL faces with landmarks; tag the speaking one.
            let request = VNDetectFaceLandmarksRequest { [weak self] req, _ in
                guard let self else { return }
                let faces = (req.results as? [VNFaceObservation]) ?? []
                let result = self.buildSpeakerSubjects(faces)
                Task { @MainActor [weak self] in
                    self?.allSubjects = result.subjects
                    self?.updateBbox(result.trackedBbox)
                }
            }
            try? handler.perform([request, handRequest])
        } else {
            // Auto mode: prefer faces, fall back to full-body when no faces detected
            let faceReq = VNDetectFaceRectanglesRequest()
            let bodyReq = VNDetectHumanRectanglesRequest()
            try? handler.perform([faceReq, bodyReq, handRequest])

            let faces   = (faceReq.results as? [VNFaceObservation])   ?? []
            let persons = (bodyReq.results as? [VNHumanObservation])  ?? []

            if !faces.isEmpty {
                let sorted  = faces.sorted { $0.boundingBox.width > $1.boundingBox.width }
                let tracked = sorted.first?.boundingBox
                let subjects = sorted.enumerated().map { idx, f in
                    DetectedSubject(bbox: f.boundingBox, isSpeaking: false, isTracked: idx == 0, speakerLabel: nil)
                }
                Task { @MainActor [weak self] in
                    self?.allSubjects = subjects
                    self?.updateBbox(tracked)
                }
            } else if !persons.isEmpty {
                let sorted  = persons.sorted { $0.boundingBox.width > $1.boundingBox.width }
                let tracked = sorted.first?.boundingBox
                let subjects = sorted.enumerated().map { idx, p in
                    DetectedSubject(bbox: p.boundingBox, isSpeaking: false, isTracked: idx == 0, speakerLabel: nil)
                }
                Task { @MainActor [weak self] in
                    self?.allSubjects = subjects
                    self?.updateBbox(tracked)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.allSubjects = []
                    self?.updateBbox(nil)
                }
            }
        }
    }

    /// Diarization pipeline: fuses VAD + mouth-movement + persistent speaker numbers.
    ///
    /// **How speaker numbers are assigned:**
    /// Confidence for each face accumulates only while VAD is active AND that face
    /// has a high mouth-aspect-ratio (open mouth + audio = likely speaking).
    /// When a face slot's confidence crosses 0.15 for the first time, it is assigned
    /// the next available speaker number (1, 2, 3 …).  That number persists for as
    /// long as the face remains in frame.  When speakers leave and return, new numbers
    /// are issued — this is equivalent to what basic diarization systems do before
    /// building long-term voice embeddings.
    nonisolated private func buildSpeakerSubjects(_ faces: [VNFaceObservation])
        -> (subjects: [DetectedSubject], trackedBbox: CGRect?) {

        guard !faces.isEmpty else {
            faceSlots = faceSlots.map {
                FaceSlot(center: $0.center,
                         confidence: $0.confidence * 0.85,
                         speakerNumber: $0.speakerNumber)
            }.filter { $0.confidence > 0.02 }
            // No face in frame — if speech is active, count toward voice-triggered search
            if bgSpeakerFollowEnabled && bgSpeechActive {
                voiceNoSpeakerFrames += 1
            } else {
                voiceNoSpeakerFrames = 0
            }
            Task { @MainActor [weak self] in self?.activeSpeakerLabel = nil }
            return ([], nil)
        }

        let speechOn = bgSpeechActive

        // ── Pass 1: match faces → slots, update confidence ────────────────────
        var updated: [FaceSlot] = []
        for face in faces {
            let centre = CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)
            let mouth  = Float(mouthAspectRatio(face))

            var matched: FaceSlot? = nil
            var best = CGFloat.infinity
            for slot in faceSlots {
                let dx = slot.center.x - centre.x
                let dy = slot.center.y - centre.y
                let d  = sqrt(dx * dx + dy * dy)
                if d < best { best = d; if d < 0.20 { matched = slot } }
            }

            var conf   = matched?.confidence    ?? 0
            let number = matched?.speakerNumber // carry forward existing number

            if speechOn {
                let target = min(mouth * 4.0, 1.0)
                conf = 0.35 * target + 0.65 * conf   // fast attack while speaking
            } else {
                conf = 0.92 * conf                    // slow decay while silent
            }

            updated.append(FaceSlot(center: centre, confidence: conf, speakerNumber: number))
        }

        // ── Pass 2: assign speaker numbers to newly-confirmed faces ───────────
        // A face earns a number the first time its confidence exceeds the threshold.
        for idx in updated.indices where updated[idx].speakerNumber == nil {
            if updated[idx].confidence > 0.15 {
                updated[idx].speakerNumber = nextSpeakerNumber
                nextSpeakerNumber += 1
            }
        }
        faceSlots = updated

        // ── Pass 3: pick the active speaker ───────────────────────────────────
        let trackedIdx = updated.indices.max(by: {
            updated[$0].confidence < updated[$1].confidence
        }) ?? 0

        let isSpeakingNow = speechOn && updated[trackedIdx].confidence > 0.08

        let subjects = faces.enumerated().map { idx, face in
            let label = updated[idx].speakerNumber.map { "Speaker \($0)" }
            return DetectedSubject(
                bbox: face.boundingBox,
                isSpeaking: isSpeakingNow && idx == trackedIdx,
                isTracked:  idx == trackedIdx,
                speakerLabel: label
            )
        }

        // ── Voice-triggered search ────────────────────────────────────────────
        // If speech is active but no face has enough confidence to be the speaker,
        // count frames.  After ~1.5 s, return nil so the follow loop scans for the
        // off-camera speaker.
        let maxConf = updated.max(by: { $0.confidence < $1.confidence })?.confidence ?? 0
        if bgSpeakerFollowEnabled && speechOn && maxConf < 0.06 {
            voiceNoSpeakerFrames += 1
        } else {
            voiceNoSpeakerFrames = 0
        }

        // Publish active speaker for transcript attribution
        let speakerLabel = isSpeakingNow ? updated[trackedIdx].speakerNumber.map { "Speaker \($0)" } : nil
        Task { @MainActor [weak self] in self?.activeSpeakerLabel = speakerLabel }

        if bgSpeakerFollowEnabled && voiceNoSpeakerFrames >= Self.voiceSearchTriggerFrames {
            // Voice search: nobody in frame is speaking — let the scan kick in
            return (subjects, nil)
        }

        // Only track someone when they are (or recently were) speaking.
        // This prevents the gimbal from fixating on a silent person.
        if isSpeakingNow {
            lastSpeakingDate = Date()
            return (subjects, faces[trackedIdx].boundingBox)
        } else if let last = lastSpeakingDate,
                  Date().timeIntervalSince(last) < Self.speakerHoldSeconds {
            // Brief pause — hold on the last speaker a little longer
            return (subjects, faces[trackedIdx].boundingBox)
        } else {
            // Nobody has spoken recently — stay put
            return (subjects, nil)
        }
    }

    // MARK: - Palm gesture detection

    /// Updates the palm guide bbox in real-time while an open palm is held up.
    ///
    /// While the palm is confirmed the follow loop steers toward the hand position
    /// instead of the current face bbox, causing the camera to reframe onto the
    /// person waving their hand.  When the palm drops the guide holds for ~1 s then
    /// clears; as soon as face detection locks onto the new subject it clears early.
    nonisolated private func processPalmGesture(_ observations: [VNHumanHandPoseObservation]) {
        guard let obs = observations.first else {
            // No hands — clear all counters and any active guides
            let wasPalm    = bgPalmFrameCount    >= palmConfirmFrames
            let wasPointing = bgPointingFrameCount >= pointingConfirmFrames
            bgPalmFrameCount     = 0
            bgThumbsUpFrameCount = 0
            bgPointingFrameCount = 0
            if wasPalm || wasPointing {
                Task { @MainActor [weak self] in
                    if self?.pointingGestureActive == true {
                        self?.pointingGestureActive = false
                    }
                    if wasPalm {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        self?.palmGuideBbox    = nil
                        self?.palmGestureActive = false
                    }
                }
            }
            return
        }

        // ── Thumbs-up: lock/unlock ────────────────────────────────────────────
        if isThumbsUp(obs) {
            bgThumbsUpFrameCount = min(bgThumbsUpFrameCount + 1, thumbsUpConfirmFrames + 1)
            bgPalmFrameCount     = 0
            bgPointingFrameCount = 0
            if bgThumbsUpFrameCount == thumbsUpConfirmFrames {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.followLocked.toggle()
                    self.palmGestureActive    = false
                    self.pointingGestureActive = false
                    self.palmGuideBbox        = nil
                    self.logger.info("GESTURE: followLocked=\(self.followLocked)")
                }
            }
            return
        }
        bgThumbsUpFrameCount = 0

        // ── Pointing: rotate toward pointed direction, search for subject ─────
        if let tipPos = pointingTip(obs),
           let pts    = try? obs.recognizedPoints(.all),
           let wrist  = pts[.wrist], wrist.confidence > 0.5
        {
            bgPointingFrameCount = min(bgPointingFrameCount + 1, pointingConfirmFrames + 1)
            bgPalmFrameCount     = 0
            if bgPointingFrameCount >= pointingConfirmFrames {
                // Direction vector in image-normalised coords (Vision: y up, x right)
                let dx = tipPos.x - wrist.location.x
                let dy = tipPos.y - wrist.location.y
                bgPointingFrameCount = 0   // reset so subsequent points trigger again
                Task { @MainActor [weak self] in
                    self?.startPointSeek(dx: dx, dy: dy)
                }
            }
            return
        }
        bgPointingFrameCount = 0

        // ── Open palm: redirect follow (existing behaviour) ───────────────────
        guard isOpenPalm(obs),
              let points = try? obs.recognizedPoints(.all),
              let wrist  = points[.wrist], wrist.confidence > 0.5 else {
            let wasGuiding = bgPalmFrameCount >= palmConfirmFrames
            bgPalmFrameCount = 0
            if wasGuiding {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self?.palmGuideBbox    = nil
                    self?.palmGestureActive = false
                    // Open palm after lock = unlock
                    self?.followLocked     = false
                }
            }
            return
        }

        bgPalmFrameCount = min(bgPalmFrameCount + 1, palmConfirmFrames + 1)
        guard bgPalmFrameCount >= palmConfirmFrames else { return }

        let cx = wrist.location.x
        let cy = wrist.location.y
        let size: CGFloat = 0.08
        let synthBbox = CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)

        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.palmGuideBbox        = synthBbox
            self.palmGestureActive    = true
            self.pointingGestureActive = false
            self.followLocked         = false
            if !self.isFollowing { self.startFollow() }
        }
    }

    // MARK: - Point-and-seek state machine
    //
    // Triggered when the user holds a pointing gesture for ≥pointingConfirmFrames.
    //   1. Translate the (tip - wrist) vector into a yaw/pitch delta and rotate
    //      the gimbal toward that direction.
    //   2. After arriving (~700 ms), watch for a face/body for up to 2.5 s.
    //   3. If a subject appears → start follow on it.
    //   4. If nothing appears in time → rotate back to the original position
    //      and restore the prior follow state.

    /// Maximum yaw swing for a full-image-width finger vector (degrees).
    private static let pointSeekYawScale:   Double = 90
    private static let pointSeekPitchScale: Double = 45
    /// How long to wait at the destination before giving up (seconds).
    private static let pointSeekSearchSec:  TimeInterval = 2.5
    /// Approximate rotate-arrival delay so we don't try to detect faces mid-swing.
    private static let pointSeekArrivalSec: TimeInterval = 0.75
    /// Time the rotate-home animation takes before we declare seek complete.
    private static let pointSeekReturnSec:  TimeInterval = 0.75

    @MainActor
    func startPointSeek(dx: CGFloat, dy: CGFloat) {
        guard isRunning, pointSeekPhase == .idle else { return }

        // Need a meaningful direction — ignore tiny vectors (false positives).
        let mag = sqrt(dx * dx + dy * dy)
        guard mag > 0.10 else { return }

        // Snapshot current gimbal position to restore on failure
        let cur = getCurrentPosition?() ?? GimbalPosition()
        pointSeekHomeYaw      = cur.yaw
        pointSeekHomePitch    = cur.pitch
        pointSeekWasFollowing = isFollowing
        pointingGestureActive = true
        pointSeekPhase        = .rotating
        pointSeekPhaseStart   = Date()

        // Convert finger vector → yaw/pitch delta. Vision X: 0→1 left→right.
        // Vision Y: 0→1 bottom→top → positive dy = up = positive pitch.
        let yawDelta   = Double(dx) * Self.pointSeekYawScale
        let pitchDelta = Double(dy) * Self.pointSeekPitchScale
        let targetYaw   = max(-160, min(160, cur.yaw   + yawDelta))
        let targetPitch = max(-35,  min(35,  cur.pitch + pitchDelta))

        // Pause active follow while seek runs
        if isFollowing { stopFollow() }
        followLocked = false

        logger.info("POINT-SEEK: home=\(cur.yaw)°,\(cur.pitch)° → \(targetYaw)°,\(targetPitch)° (dx=\(dx) dy=\(dy))")
        // time=70 → ~700 ms gimbal-side animation; sim respects this directly.
        onAbsoluteMove?(targetYaw, targetPitch, 70)

        // Drive the phase machine at 5 Hz
        pointSeekTimer?.invalidate()
        pointSeekTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickPointSeek() }
        }
    }

    @MainActor
    private func tickPointSeek() {
        guard pointSeekPhase != .idle, let start = pointSeekPhaseStart else { return }
        let elapsed = Date().timeIntervalSince(start)

        switch pointSeekPhase {
        case .rotating:
            if elapsed >= Self.pointSeekArrivalSec {
                pointSeekPhase      = .searching
                pointSeekPhaseStart = Date()
                logger.info("POINT-SEEK: arrived, searching for subject")
            }

        case .searching:
            // Subject appeared? Lock onto it.
            let foundSubject = !allSubjects.isEmpty || detectedBbox != nil
            if foundSubject {
                logger.info("POINT-SEEK: subject found — starting follow")
                cleanupPointSeek()
                if !isFollowing { startFollow() }
                return
            }
            // Time's up — go home.
            if elapsed >= Self.pointSeekSearchSec {
                logger.info("POINT-SEEK: nothing found → returning to \(self.pointSeekHomeYaw)°,\(self.pointSeekHomePitch)°")
                pointSeekPhase      = .returning
                pointSeekPhaseStart = Date()
                onAbsoluteMove?(pointSeekHomeYaw, pointSeekHomePitch, 70)
            }

        case .returning:
            if elapsed >= Self.pointSeekReturnSec {
                let restoreFollow = pointSeekWasFollowing
                cleanupPointSeek()
                if restoreFollow { startFollow() }
            }

        case .idle:
            break
        }
    }

    @MainActor
    private func cleanupPointSeek() {
        pointSeekTimer?.invalidate()
        pointSeekTimer        = nil
        pointSeekPhase        = .idle
        pointSeekPhaseStart   = nil
        pointSeekWasFollowing = false
        pointingGestureActive = false
    }

    /// Returns true when the hand looks like a thumbs-up:
    /// thumb tip clearly above wrist, all other fingertips folded near the wrist.
    nonisolated private func isThumbsUp(_ obs: VNHumanHandPoseObservation) -> Bool {
        guard let points   = try? obs.recognizedPoints(.all) else { return false }
        guard let wrist    = points[.wrist],    wrist.confidence    > 0.5 else { return false }
        guard let thumbTip = points[.thumbTip], thumbTip.confidence > 0.5 else { return false }

        // Thumb must point clearly upward (Vision Y: 0=bottom, 1=top)
        guard thumbTip.location.y > wrist.location.y + 0.12 else { return false }

        // Other fingertips must be folded (close to wrist)
        let others: [VNHumanHandPoseObservation.JointName] = [.indexTip, .middleTip, .ringTip, .littleTip]
        var folded = 0
        for joint in others {
            guard let tip = points[joint], tip.confidence > 0.5 else { folded += 1; continue }
            let dx = tip.location.x - wrist.location.x
            let dy = tip.location.y - wrist.location.y
            if sqrt(dx * dx + dy * dy) < 0.15 { folded += 1 }
        }
        return folded >= 3
    }

    /// Returns the index fingertip position (Vision coords) when the hand is pointing
    /// (index extended, middle/ring/little folded).  Returns nil otherwise.
    nonisolated private func pointingTip(_ obs: VNHumanHandPoseObservation) -> CGPoint? {
        guard let points   = try? obs.recognizedPoints(.all) else { return nil }
        guard let wrist    = points[.wrist],    wrist.confidence    > 0.5 else { return nil }
        guard let indexTip = points[.indexTip], indexTip.confidence > 0.5 else { return nil }

        // Index must be extended
        let idx_dx = indexTip.location.x - wrist.location.x
        let idx_dy = indexTip.location.y - wrist.location.y
        guard sqrt(idx_dx * idx_dx + idx_dy * idx_dy) > 0.14 else { return nil }

        // Middle, ring, little must be folded
        let others: [VNHumanHandPoseObservation.JointName] = [.middleTip, .ringTip, .littleTip]
        var folded = 0
        for joint in others {
            guard let tip = points[joint], tip.confidence > 0.4 else { folded += 1; continue }
            let dx = tip.location.x - wrist.location.x
            let dy = tip.location.y - wrist.location.y
            if sqrt(dx * dx + dy * dy) < 0.14 { folded += 1 }
        }
        guard folded >= 2 else { return nil }

        return indexTip.location
    }

    /// Returns true if the observation looks like an open palm:
    /// at least 4 of 5 fingertips detected with high confidence AND
    /// each fingertip is far enough from the wrist that the finger is clearly extended.
    nonisolated private func isOpenPalm(_ obs: VNHumanHandPoseObservation) -> Bool {
        guard let points = try? obs.recognizedPoints(.all) else { return false }
        guard let wrist = points[.wrist], wrist.confidence > 0.5 else { return false }

        let tipJoints: [VNHumanHandPoseObservation.JointName] = [
            .thumbTip, .indexTip, .middleTip, .ringTip, .littleTip
        ]
        var extendedCount = 0
        for joint in tipJoints {
            guard let tip = points[joint], tip.confidence > 0.5 else { continue }
            let dx = tip.location.x - wrist.location.x
            let dy = tip.location.y - wrist.location.y
            if sqrt(dx * dx + dy * dy) > 0.12 { extendedCount += 1 }
        }
        return extendedCount >= 4
    }

    /// Mouth openness = vertical lip span ÷ face bounding-box height.
    /// Scale-invariant: a wide-open mouth ≈ 0.15–0.25; closed ≈ 0.01–0.04.
    nonisolated private func mouthAspectRatio(_ face: VNFaceObservation) -> CGFloat {
        guard let lips = face.landmarks?.outerLips else { return 0 }
        let pts = lips.normalizedPoints
        guard pts.count >= 2 else { return 0 }
        let ys = pts.map { $0.y }
        let span = (ys.max() ?? 0) - (ys.min() ?? 0)
        return span / max(face.boundingBox.height, 0.001)
    }

    private func updateBbox(_ box: CGRect?) {
        detectedBbox = box
        if box != nil {
            // Only hand off to face detection once the palm gesture has finished.
            // While palmGestureActive, keep the palm guide alive so speaker-follow's
            // VAD-driven bbox doesn't immediately override the reframe target.
            if !palmGestureActive { palmGuideBbox = nil }
            bumpFPS()
        }
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
