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
    /// Yaw angle the gimbal is currently sweeping toward — drives the splat-map cursor.
    @Published var sweepCurrentYaw: Double = 0

    private var sweepTimer: Timer?
    private var sweepWaypoints: [ScanWaypoint] = []
    private var sweepWaypointIndex: Int = 0
    private var lastSweepWaypointTime: Date?
    private var autoFollowAfterSweep: Bool = true
    /// Seconds to dwell at each sweep position.
    /// Must be > max gimbal transit time: 160° at ~120°/s ≈ 1.3 s, so 3 s is safe.
    private let sweepDwellTime: TimeInterval = 3.0
    /// Settling period after a waypoint is sent before we start collecting faces.
    private let sweepSettleTime: TimeInterval = 1.5
    /// Estimated camera horizontal FOV in degrees (used for world-position estimation).
    private let cameraFOVDeg: Double = 65

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

    /// Sub-components for speaker detection and transcription.
    let speakerManager = SpeakerFollowManager()
    let transcriber = WhisperTranscriber()

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

    // Capture outputs (strong refs; nil when camera is stopped)
    private var photoOutput: AVCapturePhotoOutput?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var recordingTimer: Timer?

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
    private let palmConfirmFrames: Int = 20  // ~0.67 s at 30 fps

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
                // Room sweep has exclusive gimbal control — don't compete with it
                guard self.roomSweepState != .sweeping else { return }
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
    }

    // MARK: - Room sweep

    /// Standalone room scan — sweeps the full yaw range, detects all people,
    /// and builds the splat map. Does NOT auto-start follow when done.
    /// Works with whatever tracking mode is currently selected (face / person).
    func scanRoom() {
        guard isRunning else { return }
        startRoomSweep(autoFollow: false)
    }

    /// Internal sweep used by speaker-follow (auto-starts follow when done).
    private func startRoomSweep(autoFollow: Bool = true) {
        cancelRoomSweep()
        resetSearchState()
        subjectMap = []
        faceSlots = []
        nextSpeakerNumber = 1
        voiceNoSpeakerFrames = 0
        autoFollowAfterSweep = autoFollow

        let pos = getCurrentPosition?() ?? GimbalPosition()

        // Two-row serpentine: scan at a slightly-tilted-up row first so faces at
        // different heights are both covered, then come back across at level.
        // Each full-width move takes ≤ 1.33 s; time=200 (2 s) is a safe budget.
        let pitchHigh = clampPitch(pos.pitch + 10)   // slightly up — catches standing people
        let pitchLow  = clampPitch(pos.pitch - 5)    // slightly down — catches seated people
        let yawStops: [Double] = [yawMin, yawMin / 2, 0, yawMax / 2, yawMax]

        sweepWaypoints =
            yawStops.map { y in ScanWaypoint(yaw: y, pitch: pitchHigh, time: 200) } +
            yawStops.reversed().map { y in ScanWaypoint(yaw: y, pitch: pitchLow,  time: 200) }

        sweepWaypointIndex = 0
        lastSweepWaypointTime = nil
        roomSweepState = .sweeping

        let first = sweepWaypoints[0]
        sweepCurrentYaw = first.yaw
        onAbsoluteMove?(first.yaw, first.pitch, first.time)
        lastSweepWaypointTime = Date()

        sweepTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sweepTick() }
        }
        logger.info("SWEEP: starting \(self.sweepWaypoints.count)-stop scan, autoFollow=\(autoFollow)")
    }

    private func sweepTick() {
        guard roomSweepState == .sweeping,
              let lastTime = lastSweepWaypointTime else { return }

        let elapsed = Date().timeIntervalSince(lastTime)

        if elapsed >= sweepSettleTime {
            collectFacesForMap()
        }

        guard elapsed >= sweepDwellTime else { return }

        sweepWaypointIndex += 1
        if sweepWaypointIndex < sweepWaypoints.count {
            let wp = sweepWaypoints[sweepWaypointIndex]
            onAbsoluteMove?(wp.yaw, wp.pitch, wp.time)
            sweepCurrentYaw = wp.yaw
            lastSweepWaypointTime = Date()
            logger.info("SWEEP: → \(self.sweepWaypointIndex)/\(self.sweepWaypoints.count) yaw=\(String(format: "%.0f", wp.yaw))° pitch=\(String(format: "%.0f", wp.pitch))°")
        } else {
            finishRoomSweep()
        }
    }

    /// Snapshot any subjects currently in frame and add new ones to the subject map.
    private func collectFacesForMap() {
        guard let pos = getCurrentPosition?() else { return }
        for subject in allSubjects {
            let faceOffsetYaw   = (Double(subject.bbox.midX) - 0.5) * cameraFOVDeg
            let faceOffsetPitch = (0.5 - Double(subject.bbox.midY)) * (cameraFOVDeg * 0.75)
            let absYaw   = clampYaw(pos.yaw   + faceOffsetYaw)
            let absPitch = clampPitch(pos.pitch + faceOffsetPitch)

            let alreadyMapped = subjectMap.contains { e in
                let dy = e.approximateYaw   - absYaw
                let dp = e.approximatePitch - absPitch
                return (dy * dy + dp * dp) < 25 * 25
            }
            guard !alreadyMapped else { continue }

            let entry = SubjectMapEntry(
                speakerNumber: nextSpeakerNumber,
                approximateYaw: absYaw,
                approximatePitch: absPitch
            )
            subjectMap.append(entry)
            nextSpeakerNumber += 1
            logger.info("SWEEP: mapped person \(entry.speakerNumber) at yaw=\(String(format: "%.0f", absYaw))° pitch=\(String(format: "%.0f", absPitch))°")
        }
    }

    private func finishRoomSweep() {
        cancelRoomSweep()
        roomSweepState = .ready
        logger.info("SWEEP: complete — \(self.subjectMap.count) person(s) mapped")
        faceSlots = subjectMap.map { entry in
            FaceSlot(center: .zero, confidence: 0, speakerNumber: entry.speakerNumber)
        }
        onAbsoluteMove?(0, 0, 60)
        guard autoFollowAfterSweep else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.isRunning, !self.isFollowing else { return }
            self.startFollow()
        }
    }

    private func cancelRoomSweep() {
        sweepTimer?.invalidate()
        sweepTimer = nil
        sweepWaypoints = []
        sweepWaypointIndex = 0
        lastSweepWaypointTime = nil
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
            switch bgTrackingType {
            case .face:
                let request = VNDetectFaceRectanglesRequest { [weak self] req, _ in
                    let faces = (req.results as? [VNFaceObservation]) ?? []
                    // Sort largest-first so index-0 is the primary track target
                    let sorted = faces.sorted { $0.boundingBox.width > $1.boundingBox.width }
                    let tracked = sorted.first?.boundingBox
                    let subjects = sorted.enumerated().map { idx, f in
                        DetectedSubject(bbox: f.boundingBox, isSpeaking: false, isTracked: idx == 0, speakerLabel: nil)
                    }
                    Task { @MainActor [weak self] in
                        self?.allSubjects = subjects
                        self?.updateBbox(tracked)
                    }
                }
                try? handler.perform([request, handRequest])
            case .person:
                let request = VNDetectHumanRectanglesRequest { [weak self] req, _ in
                    let persons = (req.results as? [VNHumanObservation]) ?? []
                    let sorted = persons.sorted { $0.boundingBox.width > $1.boundingBox.width }
                    let tracked = sorted.first?.boundingBox
                    let subjects = sorted.enumerated().map { idx, p in
                        DetectedSubject(bbox: p.boundingBox, isSpeaking: false, isTracked: idx == 0, speakerLabel: nil)
                    }
                    Task { @MainActor [weak self] in
                        self?.allSubjects = subjects
                        self?.updateBbox(tracked)
                    }
                }
                try? handler.perform([request, handRequest])
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
        guard let palmObs = observations.first(where: { isOpenPalm($0) }),
              let points = try? palmObs.recognizedPoints(.all),
              let wrist = points[.wrist], wrist.confidence > 0.5 else {
            let wasGuiding = bgPalmFrameCount >= palmConfirmFrames
            bgPalmFrameCount = 0
            if wasGuiding {
                // Palm dropped — hold the last aim point briefly then clear
                Task { @MainActor [weak self] in
                    self?.palmGestureActive = false
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self?.palmGuideBbox = nil
                }
            }
            return
        }

        bgPalmFrameCount = min(bgPalmFrameCount + 1, palmConfirmFrames + 1)
        guard bgPalmFrameCount >= palmConfirmFrames else { return }

        // Build a small synthetic bbox centered on the wrist (palm anchor point).
        // Vision coords: origin bottom-left, Y increasing upward — same as detectedBbox.
        let cx = wrist.location.x
        let cy = wrist.location.y
        let size: CGFloat = 0.08
        let synthBbox = CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)

        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.palmGuideBbox = synthBbox
            self.palmGestureActive = true
            // If follow isn't running, start it so the gimbal actually moves
            if !self.isFollowing { self.startFollow() }
        }
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
            // Face detection locked on — release palm guide so normal tracking resumes
            palmGuideBbox = nil
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
