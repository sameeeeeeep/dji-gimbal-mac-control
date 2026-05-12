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

    // ── Pipeline visualization (consumed by the operator console pipeline strip) ──
    /// Live mirror of the ring buffer thumbnails (oldest → newest), updated each
    /// time a frame is captured. UI shows these as the "next-grid" preview.
    @Published var bufferThumbs: [CGImage] = []
    /// Composed 2×2 grid currently being analyzed by the VLM, or nil if idle.
    @Published var inflightGrid:      CGImage? = nil
    /// When the in-flight request started — used to render an elapsed-time pill.
    @Published var inflightStartedAt: Date?    = nil
    /// Number of beats that were skipped because a previous one was still in-flight.
    /// (Currently we serialize so this stays at 0; reserved for future parallelism.)
    @Published var queuedCount: Int = 0

    var frameInterval: TimeInterval = 4.0
    var writeCooldown: TimeInterval = 45.0

    private weak var tracker:    CameraTracker?
    private weak var transcriber: WhisperTranscriber?
    private var captureTimer: Timer?

    private let visionQueue = DispatchQueue(label: "com.gimbal.vision", qos: .utility)
    private var visionBusy  = false
    private let embeddingGate = EmbeddingGate()

    // Change detection state
    private var prevFaceCount     = -1
    private var prevBodyActivity  = ""
    private var prevHandGestures  = Set<String>()
    private var prevOCRSnapshot   = Set<String>()
    private var lastWriteTime     = Date.distantPast
    private var heartbeatTimer:   Timer?
    private var lastHeartbeat     = Date.distantPast
    private let heartbeatInterval: TimeInterval = 180.0
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
    /// Ring buffer of the last 16 captured frames (oldest first). Composited into a
    /// 4×4 temporal sprite sheet before being sent to the VLM so one inference call
    /// covers ~60s of context instead of ~12s — lets us throttle Gemma harder.
    private var frameBuffer: [(image: CGImage, timestamp: Date)] = []
    private let frameBufferCapacity = 16
    private let gridCols = 4
    private let gridRows = 4

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

        // Scene-change gate: skip frames that look identical to the last fired
        // frame. This is cheap (single feature print) and lets us throttle the
        // VLM hard when nothing's happening.
        let gate = embeddingGate.shouldFire(image)
        if !gate.fire {
            logger.debug("gate: skip frame (dist \(gate.distance, privacy: .public))")
            return
        }

        visionBusy = true

        // Push into the temporal ring buffer (used to build the 2×2 grid for VLM)
        frameBuffer.append((image: image, timestamp: Date()))
        if frameBuffer.count > frameBufferCapacity {
            frameBuffer.removeFirst(frameBuffer.count - frameBufferCapacity)
        }
        // Mirror to UI for the pipeline strip (oldest → newest)
        bufferThumbs = frameBuffer.map { $0.image }

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

        // Build the temporal 2×2 composite from the ring buffer + a full-res
        // latest frame. We deliberately send ONLY ONE image to the VLM:
        // sending two (grid + full-res) blew out Metal's command buffer and
        // crashed the python process with kIOGPUCommandBufferCallbackErrorOutOfMemory.
        // The bottom-right cell of the grid IS the newest frame, so the grid
        // alone carries both temporal context and "what's happening now".
        let bufferSnapshot = frameBuffer
        let composite = Self.composeTemporalGrid(buffer: bufferSnapshot, cols: gridCols, rows: gridRows)
        let latestFrame = bufferSnapshot.last?.image ?? tracker?.captureCurrentFrame()
        if let composite { Self.writeDebugComposite(composite) }
        var vlmImages: [CGImage] = []
        if let composite, bufferSnapshot.count >= 2 {
            vlmImages.append(composite)
        } else if let latestFrame {
            // First few frames before the grid is populated — send the single
            // full-res frame so we get a beat right away.
            vlmImages.append(latestFrame)
        }

        let oneLiner = obs.oneLiner
        let recentSpeech = transcriber.flatMap { t -> String? in
            let words = t.transcript.split(separator: " ").suffix(30)
            return words.isEmpty ? nil : words.joined(separator: " ")
        }
        let frameCount = bufferSnapshot.count
        let spanSec: Int = bufferSnapshot.count >= 2
            ? max(1, Int(bufferSnapshot.last!.timestamp.timeIntervalSince(bufferSnapshot.first!.timestamp)))
            : 0
        let vlmPrompt = buildVLMDescriptionPrompt(frameCount: frameCount, spanSec: spanSec, cols: gridCols, rows: gridRows)

        // Snapshot needed context before going off-actor
        let beatsForContext = recentBeats
        let visionFacts    = Self.buildVisionFacts(obs)
        let claudeAgent    = tracker?.claudeAgent
        let useClaudeSynth = claudeAgent?.isConfigured == true
        let rawObsSnapshot = rawObservations

        // Identity context — embed the latest frame against known places, and
        // crop+embed each detected face against known people. Done on MainActor
        // before going off-actor so the store is touched safely.
        let identityFacts: String = {
            guard let tracker, let frame = latestFrame else { return "" }
            return Self.buildIdentityFacts(frame: frame,
                                           subjects: obs.subjects,
                                           store: tracker.identityStore,
                                           gate: embeddingGate)
        }()

        // Publish in-flight grid for the pipeline strip BEFORE going off-actor.
        let inflightGridForUI = composite
        let inflightStart = Date()
        self.inflightGrid      = inflightGridForUI
        self.inflightStartedAt = inflightStart

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                // ── Step 1: local VLM produces a raw description ──
                let raw: String = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await self.runner.query(vlmPrompt, images: vlmImages, maxTokens: 60) }
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
                        recentBeats:     beatsForContext,
                        gridImage:       inflightGridForUI,
                        identityContext: identityFacts.isEmpty ? nil : identityFacts
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
                        self.inflightGrid      = nil
                        self.inflightStartedAt = nil
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
                    self.inflightGrid      = nil
                    self.inflightStartedAt = nil
                    let synthTag = usedClaude ? "claude" : "vlm-only"
                    self.logger.info("Beat[\(finalMode.rawValue, privacy: .public)/\(synthTag, privacy: .public)] \(finalSentence, privacy: .public) | raw: \(rawDesc, privacy: .public)")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isWriting   = false
                    self?.modelStatus = "Running"
                    self?.inflightGrid      = nil
                    self?.inflightStartedAt = nil
                    self?.logger.error("Beat pipeline failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Embeds the full frame against known places and each face crop against
    /// known people, returning a single line for the Claude synth prompt.
    /// Format: "seen: Sameep (0.05), unknown · place: desk (0.10)".
    /// Empty string when nothing matches and there are no faces to report.
    @MainActor
    static func buildIdentityFacts(frame: CGImage,
                                   subjects: [DetectedSubject],
                                   store: IdentityStore,
                                   gate: EmbeddingGate) -> String {
        var parts: [String] = []

        // People — embed each face crop and look it up.
        var peopleTokens: [String] = []
        for subj in subjects.prefix(4) {
            guard let crop = cropImage(frame, normalisedBbox: subj.bbox) else { continue }
            guard let obs = gate.embed(crop) else { continue }
            if let (hit, dist) = store.matchFace(obs) {
                let name = hit.name ?? "person"
                peopleTokens.append(String(format: "%@ (%.2f)", name, dist))
            } else {
                peopleTokens.append("unknown")
            }
        }
        if !peopleTokens.isEmpty {
            parts.append("seen: " + peopleTokens.joined(separator: ", "))
        }

        // Place — embed full frame.
        if let obs = gate.embed(frame),
           let (hit, dist) = store.matchPlace(obs) {
            let name = hit.name ?? "place"
            parts.append(String(format: "place: %@ (%.2f)", name, dist))
        }

        return parts.joined(separator: " · ")
    }

    /// Vision bboxes are bottom-left origin, normalised [0,1]. CGImage.cropping
    /// uses a pixel rect in image-internal (top-left origin) coords. Convert.
    nonisolated static func cropImage(_ image: CGImage, normalisedBbox bbox: CGRect) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pxX = bbox.origin.x * w
        let pxW = bbox.width * w
        let pxH = bbox.height * h
        // Flip y: Vision y=0 at bottom; CGImage cropping y=0 at top.
        let pxY = (1.0 - bbox.origin.y - bbox.height) * h
        let rect = CGRect(x: pxX, y: pxY, width: pxW, height: pxH).integral
        guard rect.width > 4, rect.height > 4,
              rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= w, rect.maxY <= h else { return nil }
        return image.cropping(to: rect)
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
    private func buildVLMDescriptionPrompt(frameCount: Int, spanSec: Int, cols: Int, rows: Int) -> String {
        // The small VLM's failure mode is filler ("pale walls, soft lighting,
        // a serene atmosphere"). We force it onto specifics: who is present,
        // what their hands/gaze are doing, what objects they're touching or
        // looking at, and the inferred activity. Lighting/walls/atmosphere
        // are explicitly forbidden unless they ARE the subject of the frame.
        let base = """
        You are the eye of a memory device. Report what is happening — not how it looks.

        Output ONE sentence, max 30 words, with these elements in order:
          1. PEOPLE: count + role if obvious (e.g. "a woman at a desk", "two people facing each other")
          2. ACTION: what their hands / posture / gaze are doing right now (specific verbs: typing, pointing, holding a mug, looking at a phone, leaning forward)
          3. OBJECTS: the 1–3 things they are interacting with or looking at (laptop, notebook, mug, phone, another person)
          4. PLACE: one short tag only if clearly identifiable (kitchen, desk, sidewalk, bedroom). Skip if generic.

        HARD RULES:
          • Do NOT describe lighting, wall color, mood, atmosphere, or aesthetic.
          • Do NOT use words like "serene", "cozy", "warm light", "pale", "soft", "minimal".
          • If the frame shows nothing meaningful happening, say exactly: "Nothing notable — empty room." and stop.
          • No advice, no coaching, no questions, no second person. Third-person factual only.

        Good: "A man at a desk types on a laptop while glancing at a phone beside the keyboard."
        Bad:  "A peaceful workspace with soft natural light and a sense of calm focus."
        """
        if frameCount >= 2 {
            return base + "\n\nThe image you are seeing is a \(cols)×\(rows) sprite sheet of \(frameCount) frames of the same scene in chronological order (top-left = oldest, bottom-right = newest, span ≈ \(spanSec)s). Focus your description on the bottom-right cell — that is what is happening RIGHT NOW. If a hand/gaze/object position changed across the sheet, append a short clause (4–6 words) naming the change."
        }
        return base
    }

    // MARK: - Temporal grid composer (Path A + C)

    /// Composites up to 4 frames into a clean 2×2 grid (no annotations).
    /// The model is told via the prompt that frames are in chronological order
    /// (top-left oldest → bottom-right newest); we trust it to read order from
    /// content rather than overlaying borders or diff highlights, which add
    /// pixel noise and bias small VLMs toward describing the markings.
    nonisolated static func composeTemporalGrid(
        buffer: [(image: CGImage, timestamp: Date)],
        cols: Int = 2,
        rows: Int = 2
    ) -> CGImage? {
        guard !buffer.isEmpty, cols > 0, rows > 0 else { return nil }

        // Cap the composite around 448px wide — larger composites blow out
        // Gemma 4's vision-encoder peak memory on 8GB Macs (kIOGPUCommand-
        // BufferCallbackErrorOutOfMemory). The encoder downsamples to its
        // patch grid anyway, so feeding it more pixels gains nothing.
        let cellW = max(96, 448 / cols)
        let cellH = cellW * 9 / 16
        let gridW = cellW * cols, gridH = cellH * rows
        let capacity = cols * rows

        guard let ctx = CGContext(
            data: nil,
            width: gridW, height: gridH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        ) else { return nil }

        ctx.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: gridW, height: gridH))
        ctx.interpolationQuality = .medium

        // CGContext y is bottom-up. We want chronological order top-left → bottom-right,
        // so index i maps to row (i / cols) from the top, col (i % cols) from the left.
        for (i, item) in buffer.enumerated() {
            guard i < capacity else { break }
            let row = i / cols       // 0 = top
            let col = i % cols       // 0 = left
            let x = col * cellW
            let y = (rows - 1 - row) * cellH  // flip for bottom-up coords
            let cellRect = CGRect(x: x, y: y, width: cellW, height: cellH)
            ctx.saveGState()
            ctx.clip(to: cellRect)
            ctx.draw(item.image, in: cellRect)
            ctx.restoreGState()
        }

        // Thin neutral dividers so adjacent cells don't blur into each other.
        ctx.setStrokeColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.4))
        ctx.setLineWidth(1)
        for c in 1..<cols {
            let x = c * cellW
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: gridH))
        }
        for r in 1..<rows {
            let y = r * cellH
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: gridW, y: y))
        }
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
