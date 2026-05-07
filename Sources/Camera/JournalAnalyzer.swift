import Foundation
import AppKit
import Vision
import os

// MARK: - Data model

/// A single sentence appended to the running narrative when a scene change is detected.
struct NarrativeBeat: Identifiable {
    let id        = UUID()
    let timestamp = Date()
    let sentence: String
    let trigger:  String   // what change caused it (for debug / tooltips)
}

/// Vision-derived snapshot of a single camera frame.
struct SceneObservation {
    let timestamp: Date
    let sceneLabels: [(label: String, confidence: Float)]
    let visibleText: [String]
    let faceCount: Int
    let activityHints: [String]   // "standing" | "seated"

    var oneLiner: String {
        var parts: [String] = []
        if !sceneLabels.isEmpty {
            parts.append(sceneLabels.prefix(3).map { $0.label }.joined(separator: ", "))
        }
        if faceCount > 0 { parts.append("\(faceCount) person\(faceCount == 1 ? "" : "s")") }
        if let act = activityHints.first { parts.append(act) }
        if !visibleText.isEmpty { parts.append("\"\(visibleText[0])\"") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - JournalAnalyzer

/// Real-time continuous narrative journal, optimised for M1 Air 8 GB.
///
/// Architecture:
///   • Apple Vision (ANE, ~10 ms/frame, always free) — continuous per-frame structure
///   • MLX Qwen2.5-1.5B (~60 tokens ≈ 2 s on M1 Air) — one sentence per scene change
///
/// Every detected change (person enters/leaves, activity shifts, new text on screen)
/// triggers a single-sentence continuation of a running narrative thread.
/// The model receives the last 4 sentences as context so the prose stays coherent.
/// No fixed timer, no batch chunks — the story builds itself in real time.
@MainActor
final class JournalAnalyzer: ObservableObject {

    // MARK: - MLX runner (owned here)
    let runner = MLXRunner()

    // MARK: - Published state

    /// Ordered beats that make up the running narrative.
    @Published var beats: [NarrativeBeat] = []
    /// Full narrative text — the concatenation of all beat sentences.
    @Published var narrative = ""
    @Published var isAnalyzing    = false
    @Published var modelStatus    = "Idle"
    @Published var currentSessionPath: URL? = nil
    @Published var latestObservation: SceneObservation? = nil
    /// True while a sentence is being generated (shows spinner in UI).
    @Published var isWriting = false

    // MARK: - Config

    var frameInterval: TimeInterval = 2.0    // 0.5 fps Vision sampling
    /// Minimum gap between narrative additions — keeps M1 Air cool.
    var writeCooldown: TimeInterval = 15.0

    // MARK: - Private

    private weak var tracker:    CameraTracker?
    private weak var transcriber: WhisperTranscriber?

    private var captureTimer: Timer?

    private let visionQueue = DispatchQueue(label: "com.gimbal.vision", qos: .utility)
    private var visionBusy  = false

    // Change detection
    private var prevFaceCount   = -1
    private var prevActivity    = ""
    private var prevOCRSnapshot = Set<String>()
    private var lastWriteTime   = Date.distantPast

    private var sessionStart = Date()
    private let logger = Logger(subsystem: "com.gimbal.controller", category: "JournalAnalyzer")

    // MARK: - Journal directory

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
        prevActivity     = ""
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
        logger.info("JournalAnalyzer started")
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

        visionQueue.async { [weak self] in
            let obs = Self.runVisionSync(on: image)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.visionBusy      = false
                self.latestObservation = obs
                self.detectChange(obs)
            }
        }
    }

    // MARK: - Change detection → narrative continuation

    private func detectChange(_ obs: SceneObservation) {
        guard runner.isReady, !isWriting else { return }
        guard Date().timeIntervalSince(lastWriteTime) >= writeCooldown else { return }

        var changeDesc: String? = nil

        if prevFaceCount >= 0, obs.faceCount != prevFaceCount {
            let delta = obs.faceCount - prevFaceCount
            changeDesc = delta > 0
                ? "\(abs(delta)) person\(abs(delta) == 1 ? "" : "s") entered"
                : "\(abs(delta)) person\(abs(delta) == 1 ? "" : "s") left"
        }

        let activity = obs.activityHints.first ?? ""
        if !activity.isEmpty, activity != prevActivity, prevActivity != "" {
            let act = "activity shifted to \(activity)"
            changeDesc = changeDesc.map { "\($0); \(act)" } ?? act
        }

        let newOCR = Set(obs.visibleText).subtracting(prevOCRSnapshot)
        if !newOCR.isEmpty, !obs.visibleText.isEmpty {
            let sample = newOCR.prefix(2).joined(separator: ", ")
            let ocrChange = "text appeared: \"\(sample)\""
            changeDesc = changeDesc.map { "\($0); \(ocrChange)" } ?? ocrChange
        }

        prevFaceCount   = obs.faceCount
        if !activity.isEmpty { prevActivity = activity }
        prevOCRSnapshot = Set(obs.visibleText.prefix(10))

        guard let change = changeDesc else { return }

        lastWriteTime = Date()
        appendNarrativeBeat(change: change, obs: obs)
    }

    // MARK: - Narrative append

    private func appendNarrativeBeat(change: String, obs: SceneObservation) {
        isWriting = true
        modelStatus = "Writing…"

        // Last 4 sentences give the model enough thread to continue coherently.
        let context = beats.suffix(4).map { $0.sentence }.joined(separator: " ")
        let transcript = transcriber.map { t in
            let words = t.transcript.split(separator: " ").suffix(40)
            return words.isEmpty ? "" : "Recent speech: \"\(words.joined(separator: " "))\""
        } ?? ""

        let prompt = buildContinuationPrompt(
            context: context, change: change, scene: obs.oneLiner, transcript: transcript
        )

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let raw = try await self.runner.query(prompt, maxTokens: 60)
                // Extract just the first sentence — model sometimes adds extras
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
                    self?.logger.error("Narrative beat failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func buildContinuationPrompt(context: String, change: String,
                                          scene: String, transcript: String) -> String {
        var lines = [String]()
        lines.append("A camera is observing a scene. Based only on what the camera can detect, describe what is happening.")
        if !context.isEmpty {
            lines.append("So far: \(context)")
        }
        lines.append("Detected in frame: \(scene)")
        if !transcript.isEmpty { lines.append(transcript) }
        lines.append("New: \(change)")
        lines.append("")
        lines.append("Write ONE present-tense sentence (max 20 words) describing only what is visible. No emotions, no guessing inner states, no drama.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Vision pipeline

    private static func runVisionSync(on image: CGImage) -> SceneObservation {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        var sceneLabels: [(String, Float)] = []
        let classifyReq = VNClassifyImageRequest()
        if (try? handler.perform([classifyReq])) != nil {
            sceneLabels = (classifyReq.results ?? [])
                .filter { $0.confidence > 0.08 }.prefix(5)
                .map { ($0.identifier.replacingOccurrences(of: "_", with: " "), $0.confidence) }
        }

        var visibleText: [String] = []
        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLevel = .fast
        textReq.minimumTextHeight = 0.04
        if (try? handler.perform([textReq])) != nil {
            visibleText = (textReq.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .filter { $0.count > 2 }.prefix(6).map { $0 }
        }

        var faceCount = 0
        let faceReq = VNDetectFaceRectanglesRequest()
        if (try? handler.perform([faceReq])) != nil { faceCount = faceReq.results?.count ?? 0 }

        var activityHints: [String] = []
        let poseReq = VNDetectHumanBodyPoseRequest()
        if (try? handler.perform([poseReq])) != nil {
            for pose in (poseReq.results ?? []).prefix(3) {
                if let h = bodyPoseHint(pose) { activityHints.append(h) }
            }
        }

        return SceneObservation(timestamp: Date(), sceneLabels: sceneLabels,
                                visibleText: visibleText, faceCount: faceCount,
                                activityHints: activityHints)
    }

    private static func bodyPoseHint(_ pose: VNHumanBodyPoseObservation) -> String? {
        guard let headY = try? pose.recognizedPoint(.nose).location.y,
              let hipY  = try? pose.recognizedPoint(.rightHip).location.y else { return nil }
        return headY > hipY + 0.2 ? "standing" : "seated"
    }

    // MARK: - Helpers

    private nonisolated static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Stop at the first sentence-ending punctuation followed by whitespace or end
        let pattern = "[.!?](?:\\s|$)"
        if let range = trimmed.range(of: pattern, options: .regularExpression) {
            return String(trimmed[trimmed.startIndex...range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // No punctuation found — return first 30 words as a fallback
        let words = trimmed.split(separator: " ").prefix(30)
        return words.joined(separator: " ")
    }

    // MARK: - On-disk journal

    private func writeSessionHeader() {
        guard let path = currentSessionPath else { return }
        let fmt = DateFormatter(); fmt.dateStyle = .full; fmt.timeStyle = .short
        let header = """
        # Journal — \(fmt.string(from: sessionStart))

        > Model: \(runner.modelTag) · Apple Vision · continuous narrative

        ---

        """
        try? header.write(to: path, atomically: true, encoding: .utf8)
        updateIndex()
    }

    private func appendBeatToDisk(_ beat: NarrativeBeat) {
        guard let path = currentSessionPath else { return }
        // Write just the sentence — the file reads like a flowing story
        let text = beat.sentence + " "
        if let handle = try? FileHandle(forWritingTo: path) {
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8) ?? Data())
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
