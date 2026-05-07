import Foundation
import AppKit
import Vision
import os

// MARK: - Data model

struct NarrativeBeat: Identifiable {
    let id        = UUID()
    let timestamp = Date()
    let sentence: String
    let trigger:  String
}

/// Vision-derived snapshot of a single camera frame.
struct SceneObservation {
    let timestamp: Date
    let sceneLabels: [(label: String, confidence: Float)]
    let visibleText: [String]
    let subjects: [DetectedSubject]   // from CameraTracker — positioned, speaker-labelled
    let faceCount: Int                // fallback when tracker subjects unavailable
    let bodyActivities: [String]      // per-person: "standing", "seated", "arms raised", etc.
    let handGestures: [String]        // per-hand: "open palm", "pointing", "thumbs up", "fist"

    var oneLiner: String {
        var parts: [String] = []

        // Describe people by screen position if we have subject data
        if !subjects.isEmpty {
            let descs = subjects.prefix(3).map { s -> String in
                let side = s.bbox.midX < 0.35 ? "left" :
                           s.bbox.midX > 0.65 ? "right" : "center"
                let label = s.speakerLabel ?? "person"
                return "\(label) (\(side))"
            }
            parts.append(descs.joined(separator: ", "))
        } else if faceCount > 0 {
            parts.append("\(faceCount) person\(faceCount == 1 ? "" : "s")")
        }

        if !bodyActivities.isEmpty { parts.append(bodyActivities.prefix(2).joined(separator: ", ")) }
        if !handGestures.isEmpty   { parts.append(handGestures.joined(separator: ", ")) }

        if !sceneLabels.isEmpty {
            parts.append(sceneLabels.prefix(2).map { $0.label }.joined(separator: ", "))
        }
        if !visibleText.isEmpty { parts.append("\"\(visibleText[0])\"") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - JournalAnalyzer

@MainActor
final class JournalAnalyzer: ObservableObject {

    let runner = MLXRunner()

    @Published var beats: [NarrativeBeat] = []
    @Published var narrative = ""
    @Published var isAnalyzing    = false
    @Published var modelStatus    = "Idle"
    @Published var currentSessionPath: URL? = nil
    @Published var latestObservation: SceneObservation? = nil
    @Published var isWriting = false

    var frameInterval: TimeInterval = 3.0
    var writeCooldown: TimeInterval = 20.0

    private weak var tracker:    CameraTracker?
    private weak var transcriber: WhisperTranscriber?
    private var captureTimer: Timer?

    private let visionQueue = DispatchQueue(label: "com.gimbal.vision", qos: .utility)
    private var visionBusy  = false

    // Change detection state
    private var prevFaceCount     = -1
    private var prevBodyActivity  = ""
    private var prevHandGestures  = Set<String>()
    private var prevOCRSnapshot   = Set<String>()
    private var lastWriteTime     = Date.distantPast

    private var sessionStart = Date()
    private let logger = Logger(subsystem: "com.gimbal.controller", category: "JournalAnalyzer")

    var journalDir: URL {
        gimbalCapturesDir.appendingPathComponent("Journal", isDirectory: true)
    }

    // MARK: - Lifecycle

    func start(tracker: CameraTracker, transcriber: WhisperTranscriber) {
        guard !isAnalyzing else { return }
        self.tracker     = tracker
        self.transcriber = transcriber
        sessionStart     = Date()
        prevFaceCount    = -1
        prevBodyActivity = ""
        prevHandGestures = []
        prevOCRSnapshot  = []
        lastWriteTime    = .distantPast
        isAnalyzing      = true

        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd_HHmmss"
        currentSessionPath = journalDir
            .appendingPathComponent("session_\(fmt.string(from: sessionStart)).md")
        writeSessionHeader()

        captureTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.captureAndObserve() }
        }
        modelStatus = runner.isReady ? "Running" : "Waiting for MLX…"
    }

    func stop() {
        guard isAnalyzing else { return }
        captureTimer?.invalidate(); captureTimer = nil
        isAnalyzing = false
        modelStatus = "Stopped"
    }

    // MARK: - Frame capture + Vision

    private func captureAndObserve() {
        guard let tracker, let image = tracker.captureCurrentFrame() else { return }
        guard !visionBusy else { return }
        visionBusy = true

        // Capture subject positions on MainActor before going to the background queue
        let subjects = tracker.allSubjects

        visionQueue.async { [weak self] in
            let obs = Self.runVisionSync(on: image, subjects: subjects)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.visionBusy        = false
                self.latestObservation = obs
                self.detectChange(obs)
            }
        }
    }

    // MARK: - Change detection

    private func detectChange(_ obs: SceneObservation) {
        guard runner.isReady, !isWriting else { return }
        guard Date().timeIntervalSince(lastWriteTime) >= writeCooldown else { return }

        var changes: [String] = []

        // Person count change
        let faceCount = max(obs.faceCount, obs.subjects.count)
        if prevFaceCount >= 0, faceCount != prevFaceCount {
            let delta = faceCount - prevFaceCount
            changes.append(delta > 0
                ? "\(abs(delta)) person\(abs(delta) == 1 ? "" : "s") entered"
                : "\(abs(delta)) person\(abs(delta) == 1 ? "" : "s") left")
        }

        // Body activity change (standing/seated/arms raised)
        let activity = obs.bodyActivities.first ?? ""
        if !activity.isEmpty, activity != prevBodyActivity, !prevBodyActivity.isEmpty {
            changes.append("activity: \(activity)")
        }

        // New hand gesture
        let currentGestures = Set(obs.handGestures)
        let newGestures = currentGestures.subtracting(prevHandGestures)
        if !newGestures.isEmpty {
            changes.append("gesture: \(newGestures.sorted().joined(separator: ", "))")
        }

        // New visible text
        let newOCR = Set(obs.visibleText).subtracting(prevOCRSnapshot)
        if !newOCR.isEmpty, !obs.visibleText.isEmpty {
            changes.append("text appeared: \"\(newOCR.prefix(2).joined(separator: ", "))\"")
        }

        // Update state
        prevFaceCount    = faceCount
        if !activity.isEmpty { prevBodyActivity = activity }
        prevHandGestures = currentGestures
        prevOCRSnapshot  = Set(obs.visibleText.prefix(10))

        guard !changes.isEmpty else { return }

        lastWriteTime = Date()
        appendNarrativeBeat(change: changes.joined(separator: "; "), obs: obs)
    }

    // MARK: - Narrative append

    private func appendNarrativeBeat(change: String, obs: SceneObservation) {
        isWriting = true
        modelStatus = "Writing…"

        let context    = beats.suffix(4).map { $0.sentence }.joined(separator: " ")
        let transcript = transcriber.flatMap { t -> String? in
            let words = t.transcript.split(separator: " ").suffix(40)
            return words.isEmpty ? nil : "Heard: \"\(words.joined(separator: " "))\""
        }

        let prompt = buildPrompt(context: context, change: change,
                                 scene: obs.oneLiner, transcript: transcript)

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let raw      = try await self.runner.query(prompt, maxTokens: 60)
                let sentence = Self.firstSentence(raw)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let beat = NarrativeBeat(sentence: sentence, trigger: change)
                    self.beats.append(beat)
                    self.narrative = self.beats.map { $0.sentence }.joined(separator: " ")
                    self.appendBeatToDisk(beat)
                    self.isWriting   = false
                    self.modelStatus = "Running"
                    self.logger.info("Beat: \(sentence)")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isWriting   = false
                    self?.modelStatus = "Running"
                }
            }
        }
    }

    private func buildPrompt(context: String, change: String,
                             scene: String, transcript: String?) -> String {
        var lines = ["A camera is observing a scene. Based only on what the camera can detect, describe what is happening."]
        if !context.isEmpty  { lines.append("So far: \(context)") }
        lines.append("Detected: \(scene)")
        if let t = transcript { lines.append(t) }
        lines.append("New: \(change)")
        lines.append("")
        lines.append("Write ONE present-tense sentence (max 20 words) describing only what is visible. No emotions, no inner states.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Vision pipeline

    private static func runVisionSync(on image: CGImage,
                                      subjects: [DetectedSubject]) -> SceneObservation {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        // Scene classification
        var sceneLabels: [(String, Float)] = []
        let classifyReq = VNClassifyImageRequest()
        if (try? handler.perform([classifyReq])) != nil {
            sceneLabels = (classifyReq.results ?? [])
                .filter { $0.confidence > 0.08 }.prefix(5)
                .map { ($0.identifier.replacingOccurrences(of: "_", with: " "), $0.confidence) }
        }

        // OCR
        var visibleText: [String] = []
        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLevel = .fast
        textReq.minimumTextHeight = 0.04
        if (try? handler.perform([textReq])) != nil {
            visibleText = (textReq.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .filter { $0.count > 2 }.prefix(6).map { $0 }
        }

        // Face count (fallback when no tracker subjects)
        var faceCount = 0
        if subjects.isEmpty {
            let faceReq = VNDetectFaceRectanglesRequest()
            if (try? handler.perform([faceReq])) != nil { faceCount = faceReq.results?.count ?? 0 }
        }

        // Body pose — richer activity hints
        var bodyActivities: [String] = []
        let poseReq = VNDetectHumanBodyPoseRequest()
        if (try? handler.perform([poseReq])) != nil {
            for pose in (poseReq.results ?? []).prefix(3) {
                if let hint = bodyActivityHint(pose) { bodyActivities.append(hint) }
            }
        }

        // Hand gestures — NEW
        var handGestures: [String] = []
        let handReq = VNDetectHumanHandPoseRequest()
        handReq.maximumHandCount = 2
        if (try? handler.perform([handReq])) != nil {
            for pose in (handReq.results ?? []).prefix(2) {
                if let hint = handGestureHint(pose) { handGestures.append(hint) }
            }
        }

        return SceneObservation(
            timestamp: Date(),
            sceneLabels: sceneLabels,
            visibleText: visibleText,
            subjects: subjects,
            faceCount: faceCount,
            bodyActivities: bodyActivities,
            handGestures: handGestures
        )
    }

    /// Describes what a person's body is doing beyond just standing/seated.
    private static func bodyActivityHint(_ pose: VNHumanBodyPoseObservation) -> String? {
        var hints: [String] = []

        // Standing vs seated
        if let headY = try? pose.recognizedPoint(.nose).location.y,
           let hipY  = try? pose.recognizedPoint(.rightHip).location.y {
            hints.append(headY > hipY + 0.2 ? "standing" : "seated")
        }

        // Arms raised — wrist above shoulder
        let leftArm  = armHint(pose, wrist: .leftWrist,  shoulder: .leftShoulder,  side: "left")
        let rightArm = armHint(pose, wrist: .rightWrist, shoulder: .rightShoulder, side: "right")
        if let l = leftArm  { hints.append(l) }
        if let r = rightArm { hints.append(r) }

        return hints.isEmpty ? nil : hints.joined(separator: ", ")
    }

    private static func armHint(
        _ pose: VNHumanBodyPoseObservation,
        wrist: VNHumanBodyPoseObservation.JointName,
        shoulder: VNHumanBodyPoseObservation.JointName,
        side: String
    ) -> String? {
        guard let wristPt    = try? pose.recognizedPoint(wrist),    wristPt.confidence > 0.5,
              let shoulderPt = try? pose.recognizedPoint(shoulder), shoulderPt.confidence > 0.5
        else { return nil }
        // Vision y: 0 = bottom, 1 = top — so higher y = higher in image
        if wristPt.location.y > shoulderPt.location.y + 0.08 {
            return "\(side) arm raised"
        }
        // Arm extended horizontally
        let dx = abs(wristPt.location.x - shoulderPt.location.x)
        if dx > 0.15 {
            return "\(side) arm extended"
        }
        return nil
    }

    /// Classifies hand pose into a descriptive gesture string.
    private static func handGestureHint(_ pose: VNHumanHandPoseObservation) -> String? {
        guard let points  = try? pose.recognizedPoints(.all),
              let wrist   = points[.wrist], wrist.confidence > 0.5 else { return nil }

        let tipJoints: [(VNHumanHandPoseObservation.JointName, String)] = [
            (.thumbTip, "thumb"), (.indexTip, "index"), (.middleTip, "middle"),
            (.ringTip, "ring"),   (.littleTip, "little")
        ]

        var extended: Set<String> = []
        for (joint, name) in tipJoints {
            guard let tip = points[joint], tip.confidence > 0.5 else { continue }
            let dx = tip.location.x - wrist.location.x
            let dy = tip.location.y - wrist.location.y
            if sqrt(dx * dx + dy * dy) > 0.12 { extended.insert(name) }
        }

        switch extended.count {
        case 4...:
            // All fingers out — raised if wrist is in the upper half of frame
            return wrist.location.y > 0.5 ? "raised open hand" : "open hand"
        case 1 where extended.contains("index"):
            return "pointing"
        case 1 where extended.contains("thumb"):
            // Thumb tip above wrist = thumbs up
            if let thumbTip = points[.thumbTip],
               thumbTip.confidence > 0.5,
               thumbTip.location.y > wrist.location.y + 0.05 {
                return "thumbs up"
            }
            return nil
        case 0:
            return "fist"
        default:
            return nil
        }
    }

    // MARK: - Helpers

    private nonisolated static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "[.!?](?:\\s|$)", options: .regularExpression) {
            return String(trimmed[trimmed.startIndex...range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.split(separator: " ").prefix(30).joined(separator: " ")
    }

    // MARK: - On-disk journal

    private func writeSessionHeader() {
        guard let path = currentSessionPath else { return }
        let fmt = DateFormatter(); fmt.dateStyle = .full; fmt.timeStyle = .short
        let header = "# Journal — \(fmt.string(from: sessionStart))\n\n> Model: \(runner.modelTag) · Apple Vision · continuous narrative\n\n---\n\n"
        try? header.write(to: path, atomically: true, encoding: .utf8)
        updateIndex()
    }

    private func appendBeatToDisk(_ beat: NarrativeBeat) {
        guard let path = currentSessionPath else { return }
        if let handle = try? FileHandle(forWritingTo: path) {
            handle.seekToEndOfFile()
            handle.write((beat.sentence + " ").data(using: .utf8) ?? Data())
            handle.closeFile()
        }
    }

    private func updateIndex() {
        let indexPath = journalDir.appendingPathComponent("index.md")
        let existing  = (try? String(contentsOf: indexPath)) ?? "# Journal Index\n\n"
        guard let p = currentSessionPath else { return }
        let link = "- [\(p.lastPathComponent)](\(p.lastPathComponent))\n"
        if !existing.contains(link) {
            try? (existing + link).write(to: indexPath, atomically: true, encoding: .utf8)
        }
    }
}
