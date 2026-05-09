import Foundation
import AppKit
import Vision
import os

// MARK: - Data model

/// The lens through which the VLM is asked to observe the scene.
enum ObservationMode: String, CaseIterable {
    case shot     = "SHOT"      // cinematographer — framing, light, composition
    case presence = "PRESENCE"  // media coach — expression, posture, energy
    case moment   = "MOMENT"    // documentary eye — what's specific/unique right now
}

struct NarrativeBeat: Identifiable {
    let id        = UUID()
    let timestamp = Date()
    let sentence:  String
    let trigger:   String
    let mode:      ObservationMode
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
        // Only include meaningful gestures — skip fist/open-hand (too noisy)
        let meaningfulGestures = handGestures.filter { $0 == "pointing" || $0 == "thumbs up" || $0 == "raised open hand" }
        if !meaningfulGestures.isEmpty { parts.append(meaningfulGestures.joined(separator: ", ")) }

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
    @Published var latestBeat: NarrativeBeat? = nil
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
    private var heartbeatTimer:   Timer?
    private var lastHeartbeat     = Date.distantPast
    private let heartbeatInterval: TimeInterval = 60.0
    private var lastBeatOneLiner  = ""
    /// Last 3 beat sentences for similarity deduplication AND for cross-beat context.
    private var recentBeatSentences: [String] = []
    /// Last 3 (mode, sentence) tuples — Claude synthesizer sees these so it picks a
    /// different lens or angle than the previous beat.
    private var recentBeats: [(mode: ObservationMode, sentence: String)] = []
    /// Ring buffer of raw VLM descriptions ("dumb eye" output). Claude reads the
    /// last few of these when synthesizing a polished beat.
    private var rawObservations: [(text: String, ts: Date)] = []
    private let rawObsCapacity = 8
    /// Ring buffer of the last 4 captured frames (oldest first). Composited into a
    /// 2×2 temporal grid before being sent to the VLM so it can see motion + change
    /// instead of receiving isolated snapshots.
    private var frameBuffer: [(image: CGImage, timestamp: Date)] = []
    private let frameBufferCapacity = 4

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
            Task { @MainActor in self?.captureAndObserve() }
        }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fireHeartbeat() }
        }
        modelStatus = runner.isReady ? "Running" : "Waiting for MLX…"
    }

    func stop() {
        guard isAnalyzing else { return }
        captureTimer?.invalidate(); captureTimer = nil
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        isAnalyzing = false
        modelStatus = "Stopped"
    }

    // MARK: - Frame capture + Vision

    private func captureAndObserve() {
        guard let tracker, let image = tracker.captureCurrentFrame() else { return }
        guard !visionBusy else { return }
        visionBusy = true

        // Push into the temporal ring buffer (used to build the 2×2 grid for VLM)
        frameBuffer.append((image: image, timestamp: Date()))
        if frameBuffer.count > frameBufferCapacity {
            frameBuffer.removeFirst(frameBuffer.count - frameBufferCapacity)
        }

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
        let faceCount = max(obs.faceCount, obs.subjects.count)

        // Initial observation — fire a beat on first frame with any content
        if prevFaceCount == -1 {
            prevFaceCount    = faceCount
            prevBodyActivity = obs.bodyActivities.first ?? ""
            prevHandGestures = Set(obs.handGestures)
            prevOCRSnapshot  = Set(obs.visibleText.prefix(10))
            if faceCount > 0 || !obs.bodyActivities.isEmpty || !obs.sceneLabels.isEmpty {
                lastWriteTime = Date()
                appendNarrativeBeat(change: "scene begins", obs: obs)
            }
            return
        }

        // Person count change
        if faceCount != prevFaceCount {
            let delta = faceCount - prevFaceCount
            changes.append(delta > 0
                ? "\(abs(delta)) person\(abs(delta) == 1 ? "" : "s") entered"
                : "\(abs(delta)) person\(abs(delta) == 1 ? "" : "s") left")
        }

        // Body activity change
        let activity = obs.bodyActivities.first ?? ""
        if !activity.isEmpty, activity != prevBodyActivity {
            changes.append("activity: \(activity)")
        }

        // New meaningful hand gesture (exclude "fist"/"open hand" — too noisy at rest)
        let meaningfulGestures: Set<String> = ["pointing", "thumbs up", "raised open hand"]
        let currentGestures = Set(obs.handGestures).intersection(meaningfulGestures)
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
        // Only update gesture memory when meaningful gestures are actively seen
        if !currentGestures.isEmpty { prevHandGestures = currentGestures }
        prevOCRSnapshot  = Set(obs.visibleText.prefix(10))

        guard !changes.isEmpty else { return }

        lastWriteTime = Date()
        appendNarrativeBeat(change: changes.joined(separator: "; "), obs: obs)
    }

    private func fireHeartbeat() {
        guard runner.isReady, !isWriting, isAnalyzing else { return }
        guard Date().timeIntervalSince(lastHeartbeat) >= heartbeatInterval else { return }
        guard let obs = latestObservation else { return }
        // Skip heartbeat if scene hasn't changed since last beat
        guard obs.oneLiner != lastBeatOneLiner || lastBeatOneLiner.isEmpty else { return }
        lastHeartbeat = Date()
        lastWriteTime = Date()
        appendNarrativeBeat(change: "periodic observation", obs: obs)
    }

    // MARK: - Narrative append

    private func appendNarrativeBeat(change: String, obs: SceneObservation) {
        isWriting = true
        modelStatus = "Looking…"

        // Build the temporal 2×2 composite from the ring buffer.
        let bufferSnapshot = frameBuffer
        let composite = Self.composeTemporalGrid(buffer: bufferSnapshot)
        let frame: CGImage? = composite ?? tracker?.captureCurrentFrame()
        if let composite { Self.writeDebugComposite(composite) }

        let oneLiner = obs.oneLiner
        let recentSpeech = transcriber.flatMap { t -> String? in
            let words = t.transcript.split(separator: " ").suffix(30)
            return words.isEmpty ? nil : words.joined(separator: " ")
        }
        let frameCount = bufferSnapshot.count
        let spanSec: Int = bufferSnapshot.count >= 2
            ? max(1, Int(bufferSnapshot.last!.timestamp.timeIntervalSince(bufferSnapshot.first!.timestamp)))
            : 0
        let vlmPrompt = buildVLMDescriptionPrompt(frameCount: frameCount, spanSec: spanSec)

        // Snapshot needed context before going off-actor
        let beatsForContext = recentBeats
        let visionFacts    = Self.buildVisionFacts(obs)
        let claudeAgent    = tracker?.claudeAgent
        let useClaudeSynth = claudeAgent?.isConfigured == true
        let rawObsSnapshot = rawObservations

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                // ── Step 1: local VLM produces a raw description ──
                let raw: String = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await self.runner.query(vlmPrompt, image: frame, maxTokens: 60) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 45_000_000_000)
                        throw MLXError.inferenceError("Timeout")
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                let rawDesc = Self.cleanRawDescription(raw)

                // Push raw to the ring buffer (used by both UI debug and Claude synth)
                let nowDate = Date()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.rawObservations.append((text: rawDesc, ts: nowDate))
                    if self.rawObservations.count > self.rawObsCapacity {
                        self.rawObservations.removeFirst(self.rawObservations.count - self.rawObsCapacity)
                    }
                    self.modelStatus = useClaudeSynth ? "Synthesizing…" : "Running"
                }

                // ── Step 2: Claude synthesizes a polished beat (or fall back) ──
                var finalMode: ObservationMode = .moment
                var finalSentence: String      = rawDesc
                var usedClaude                 = false
                if useClaudeSynth, let agent = claudeAgent {
                    // Build description history with secondsAgo
                    var history: [(text: String, secondsAgo: Int)] =
                        rawObsSnapshot.map { item in
                            (text: item.text, secondsAgo: max(0, Int(nowDate.timeIntervalSince(item.ts))))
                        }
                    history.append((text: rawDesc, secondsAgo: 0))

                    let synth = await agent.synthesizeBeat(
                        rawDescriptions: history,
                        visionFacts:     visionFacts,
                        recentTranscript: recentSpeech,
                        recentBeats:     beatsForContext
                    )
                    if let s = synth {
                        finalMode     = s.mode
                        finalSentence = Self.firstSentence(s.sentence)
                        usedClaude    = true
                    }
                }
                if !usedClaude {
                    // Claude unavailable — use the raw VLM output as-is, post-processed.
                    finalSentence = Self.firstSentence(rawDesc)
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // De-dup against recent beats
                    if Self.tooSimilarToRecent(finalSentence, recent: self.recentBeatSentences) {
                        self.isWriting   = false
                        self.modelStatus = "Running"
                        return
                    }
                    let beat = NarrativeBeat(sentence: finalSentence, trigger: change, mode: finalMode)
                    self.beats.append(beat)
                    self.latestBeat = beat
                    self.recentBeatSentences.append(finalSentence)
                    if self.recentBeatSentences.count > 3 { self.recentBeatSentences.removeFirst() }
                    self.recentBeats.append((mode: finalMode, sentence: finalSentence))
                    if self.recentBeats.count > 3 { self.recentBeats.removeFirst() }
                    self.lastBeatOneLiner = oneLiner
                    self.narrative = self.beats.map { $0.sentence }.joined(separator: " ")
                    self.appendBeatToDisk(beat)
                    self.isWriting   = false
                    self.modelStatus = "Running"
                    let synthTag = usedClaude ? "claude" : "vlm-only"
                    self.logger.info("Beat[\(finalMode.rawValue, privacy: .public)/\(synthTag, privacy: .public)] \(finalSentence, privacy: .public) | raw: \(rawDesc, privacy: .public)")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isWriting   = false
                    self?.modelStatus = "Running"
                    self?.logger.error("Beat pipeline failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Builds a compact comma-separated string of Apple Vision-derived scene facts
    /// for the Claude synthesizer. (The Claude synth doesn't see the image directly.)
    nonisolated static func buildVisionFacts(_ obs: SceneObservation) -> String {
        var parts: [String] = []
        if !obs.subjects.isEmpty       { parts.append("\(obs.subjects.count) face(s)") }
        else if obs.faceCount > 0      { parts.append("\(obs.faceCount) face(s)") }
        if !obs.bodyActivities.isEmpty { parts.append(obs.bodyActivities.prefix(2).joined(separator: ", ")) }
        let meaningfulGestures = obs.handGestures.filter {
            ["pointing","thumbs up","raised open hand"].contains($0)
        }
        if !meaningfulGestures.isEmpty { parts.append("hand: \(meaningfulGestures.joined(separator: ", "))") }
        let labels = obs.sceneLabels.prefix(3).map { $0.label }
        if !labels.isEmpty             { parts.append(labels.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// Light cleanup on raw VLM output before storing/displaying.
    nonisolated static func cleanRawDescription(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "```", with: "")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\t*`"))
        // Hard cap at 28 words for raw — Claude synth wants concise input.
        let words = s.split(separator: " ", omittingEmptySubsequences: true)
        if words.count > 28 {
            s = words.prefix(28).joined(separator: " ") + "…"
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // (Mode rotation removed: Claude now picks the most useful lens per beat.)

    /// The VLM is now used as a DUMB DESCRIPTIVE EYE. We don't ask it to be a
    /// cinematographer or media coach — small models parrot keywords. We ask for
    /// a plain CONCRETE description: room, person, posture, action. Claude then
    /// synthesizes the polished beat downstream.
    private func buildVLMDescriptionPrompt(frameCount: Int, spanSec: Int) -> String {
        let base = """
        Describe what you see in ONE concrete sentence (max 25 words). Cover:
          • the room/setting (lighting, walls, objects visible)
          • the person (posture, clothing, expression)
          • what they're physically doing right now
        Be observational and factual. NO advice, NO coaching, NO interpretation.
        """
        if frameCount >= 2 {
            return base + "\n\nThese frames span the last \(spanSec)s, oldest on the left, latest on the right (yellow border). If anything changed across them, mention the change."
        }
        return base
    }

    // MARK: - Temporal grid composer (Path A + C)

    /// Composites up to 4 frames into a 2×2 grid. The newest frame (bottom-right)
    /// carries a translucent red diff overlay marking pixels that changed since the
    /// previous frame, giving the VLM explicit visual attention cues for motion.
    nonisolated static func composeTemporalGrid(
        buffer: [(image: CGImage, timestamp: Date)]
    ) -> CGImage? {
        guard !buffer.isEmpty else { return nil }

        // 2×2 grid of 320×180 cells → 640×360 total (fits well within VLM input limits)
        let cellW = 320, cellH = 180
        let gridW = cellW * 2, gridH = cellH * 2

        guard let ctx = CGContext(
            data: nil,
            width: gridW, height: gridH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        ) else { return nil }

        // Dark background for empty cells
        ctx.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: gridW, height: gridH))
        ctx.interpolationQuality = .medium

        // CGContext y is bottom-up. Visually: top-left = oldest, bottom-right = newest.
        //   index 0 → top-left     (x=0,     y=cellH)
        //   index 1 → top-right    (x=cellW, y=cellH)
        //   index 2 → bottom-left  (x=0,     y=0)
        //   index 3 → bottom-right (x=cellW, y=0)
        let cellOrigins: [CGPoint] = [
            CGPoint(x: 0,     y: cellH),
            CGPoint(x: cellW, y: cellH),
            CGPoint(x: 0,     y: 0),
            CGPoint(x: cellW, y: 0)
        ]

        for (i, item) in buffer.enumerated() {
            guard i < 4 else { break }
            let origin = cellOrigins[i]
            let cellRect = CGRect(x: origin.x, y: origin.y, width: CGFloat(cellW), height: CGFloat(cellH))

            ctx.saveGState()
            ctx.clip(to: cellRect)
            ctx.draw(item.image, in: cellRect)
            ctx.restoreGState()

            // Red diff overlay on the NEWEST cell (only if we have a previous frame)
            if i == buffer.count - 1, i > 0 {
                let prev = buffer[i - 1].image
                if let overlay = computeDiffOverlay(prev: prev, curr: item.image, w: cellW, h: cellH) {
                    ctx.saveGState()
                    ctx.draw(overlay, in: cellRect)
                    ctx.restoreGState()
                }
            }

            // Yellow border on the NEWEST cell to make "now" obvious to the VLM
            if i == buffer.count - 1 {
                ctx.setStrokeColor(CGColor(red: 1.0, green: 0.9, blue: 0.0, alpha: 0.85))
                ctx.setLineWidth(3)
                ctx.stroke(cellRect.insetBy(dx: 1.5, dy: 1.5))
            }
        }

        // Thin divider lines between cells
        ctx.setStrokeColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.4))
        ctx.setLineWidth(1)
        ctx.move(to:    CGPoint(x: cellW,        y: 0))
        ctx.addLine(to: CGPoint(x: cellW,        y: gridH))
        ctx.move(to:    CGPoint(x: 0,            y: cellH))
        ctx.addLine(to: CGPoint(x: gridW,        y: cellH))
        ctx.strokePath()

        return ctx.makeImage()
    }

    /// Saves the most recent composite to disk for visual debugging — overwrites
    /// each tick so the file always reflects the latest VLM input.
    nonisolated static func writeDebugComposite(_ image: CGImage) {
        let dir = gimbalCapturesDir.appendingPathComponent("Journal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("debug-composite.jpg")
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return }
        try? data.write(to: url)
    }

    /// Per-pixel max-channel absolute difference between two frames. Returns a
    /// transparent RGBA overlay where motion regions are tinted red, alpha scaled
    /// by motion magnitude. Returns nil if no significant change is detected.
    nonisolated static func computeDiffOverlay(
        prev: CGImage, curr: CGImage, w: Int, h: Int
    ) -> CGImage? {
        func render(_ image: CGImage) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let ok = bytes.withUnsafeMutableBufferPointer { buf -> Bool in
                guard let c = CGContext(
                    data: buf.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                c.interpolationQuality = .medium
                c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            return ok ? bytes : nil
        }

        guard let p = render(prev), let c = render(curr) else { return nil }

        var out = [UInt8](repeating: 0, count: w * h * 4)
        var movedPixels = 0
        let threshold = 30
        for i in 0..<(w * h) {
            let dr = abs(Int(p[i*4])   - Int(c[i*4]))
            let dg = abs(Int(p[i*4+1]) - Int(c[i*4+1]))
            let db = abs(Int(p[i*4+2]) - Int(c[i*4+2]))
            let d  = max(dr, max(dg, db))
            if d > threshold {
                let alpha = UInt8(min(170, d * 2))
                // Premultiplied red — alpha is already baked into the channels
                out[i*4]   = UInt8((255 * Int(alpha)) / 255) // R · α
                out[i*4+1] = UInt8((40  * Int(alpha)) / 255) // G · α
                out[i*4+2] = UInt8((40  * Int(alpha)) / 255) // B · α
                out[i*4+3] = alpha
                movedPixels += 1
            }
        }
        // Skip overlay if essentially nothing changed (< 0.5% of pixels)
        guard movedPixels > (w * h) / 200 else { return nil }

        guard let cf = out.withUnsafeBufferPointer({ CFDataCreate(nil, $0.baseAddress, $0.count) }),
              let provider = CGDataProvider(data: cf)
        else { return nil }

        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: - Vision pipeline

    private nonisolated static func runVisionSync(on image: CGImage,
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
    private nonisolated static func bodyActivityHint(_ pose: VNHumanBodyPoseObservation) -> String? {
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

    private nonisolated static func armHint(
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
    private nonisolated static func handGestureHint(_ pose: VNHumanHandPoseObservation) -> String? {
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

    /// Returns true if `candidate` shares more than 60% of its words with any recent beat.
    private nonisolated static func tooSimilarToRecent(_ candidate: String, recent: [String]) -> Bool {
        guard !recent.isEmpty else { return false }
        let newWords = Set(candidate.lowercased().components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 3 })
        guard newWords.count > 3 else { return false }
        for old in recent {
            let oldWords = Set(old.lowercased().components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count > 3 })
            let overlap = Double(newWords.intersection(oldWords).count) / Double(newWords.count)
            if overlap > 0.60 { return true }
        }
        return false
    }

    private nonisolated static func firstSentence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip Markdown / quote characters small models love to wrap in.
        s = s.replacingOccurrences(of: "```", with: "")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\t*`"))

        // Take only the first sentence (up to . ! ?)
        if let range = s.range(of: "[.!?](?:\\s|$)", options: .regularExpression) {
            s = String(s[s.startIndex...range.lowerBound])
        }

        // Hard cap at 16 words — the small VLM tends to ramble past this even when asked.
        let words = s.split(separator: " ", omittingEmptySubsequences: true)
        if words.count > 16 {
            s = words.prefix(16).joined(separator: " ") + "…"
        } else {
            s = words.joined(separator: " ")
        }

        // Force "you" voice. The prompts ask for it but small models slip into 3rd person.
        s = s
            .replacingOccurrences(of: "the person's",  with: "your",     options: .caseInsensitive)
            .replacingOccurrences(of: "the subject's", with: "your",     options: .caseInsensitive)
            .replacingOccurrences(of: "the person",    with: "you",      options: .caseInsensitive)
            .replacingOccurrences(of: "the subject",   with: "you",      options: .caseInsensitive)
            .replacingOccurrences(of: "this person",   with: "you",      options: .caseInsensitive)

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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
