import WhisperKit
import SpeakerKit
import AVFoundation
import os

/// On-device live speech transcription + speaker diarization.
///
/// Uses WhisperKit (Whisper CoreML) for transcription and SpeakerKit
/// (pyannote CoreML: segmenter + embedder + PLDA clusterer) for speaker
/// attribution.  Audio is captured at 16 kHz mono and processed in 30-second
/// rolling chunks so each chunk gets a full diarization pass.
///
/// Transcript lines are formatted as "Speaker N: <text>".
@MainActor
final class WhisperTranscriber: ObservableObject {
    // MARK: - Published state

    @Published var transcript = ""
    @Published var isTranscribing = false
    /// True once both Whisper and SpeakerKit models are ready.
    @Published var isModelLoaded = false
    @Published var loadingStatus = "Not loaded"

    // MARK: - Background-thread readable (API compatibility)

    nonisolated(unsafe) var bgCurrentSpeakerLabel: String? = nil
    var onSpeakerLabelChanged: ((String?) -> Void)?
    /// Kept for compatibility — speaker identity now comes from SpeakerKit, not visual tracking.
    var activeSpeakerProvider: (() -> String?)? = nil

    // MARK: - Private

    private var whisperKit: WhisperKit?
    private var speakerKit: SpeakerKit?
    private var audioEngine: AVAudioEngine?
    /// 16 kHz mono samples accumulated from the mic tap.
    private var audioBuffer: [Float] = []
    private var transcribeLoop: Task<Void, Never>?
    private var committedText = ""

    /// Maps SpeakerKit's per-chunk 0-based IDs → persistent 1-based session IDs.
    ///
    /// SpeakerKit re-numbers speakers from 0 every chunk, so without this map
    /// "Speaker 0 chunk 1" and "Speaker 0 chunk 2" might be different people.
    /// We assign a new persistent ID the first time we see each per-chunk ID and
    /// try to carry it forward using order-of-first-appearance as a heuristic.
    private var speakerRegistry: [Int: Int] = [:]
    private var nextPersistentId: Int = 1

    private let targetSampleRate: Double = 16_000
    /// 30 s chunks give pyannote enough context for reliable speaker clustering.
    private let chunkSeconds: Double = 30
    /// Cap at 2 minutes to prevent unbounded growth.
    private var maxBufferSamples: Int { Int(targetSampleRate * 120) }

    private let logger = Logger(subsystem: "com.gimbal.controller", category: "WhisperTranscriber")

    // MARK: - Model loading

    func loadModel() {
        guard !isModelLoaded, whisperKit == nil else { return }
        Task {
            do {
                loadingStatus = "Loading Whisper…"
                let wkit = try await WhisperKit(model: "openai_whisper-base.en")

                loadingStatus = "Loading speaker models…"
                // download: true  → fetch from HF on first use (cached after that)
                // load: true      → load into ANE/GPU memory now so first chunk is fast
                let skit = try await SpeakerKit(PyannoteConfig(download: true, load: true, verbose: false))

                whisperKit = wkit
                speakerKit = skit
                isModelLoaded = true
                loadingStatus = "Ready"
                logger.info("WhisperKit + SpeakerKit ready")
            } catch {
                loadingStatus = "Load failed"
                logger.error("Model load failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard isModelLoaded, !isTranscribing else { return }
        committedText = ""
        transcript = ""
        audioBuffer = []
        speakerRegistry = [:]
        nextPersistentId = 1
        isTranscribing = true
        beginCapture()
        beginTranscribeLoop()
    }

    func stop() {
        isTranscribing = false
        transcribeLoop?.cancel()
        transcribeLoop = nil
        endCapture()
        bgCurrentSpeakerLabel = nil
        onSpeakerLabelChanged?(nil)
    }

    // MARK: - Audio capture

    private func beginCapture() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFmt = inputNode.outputFormat(forBus: 0)

        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: targetSampleRate,
                                          channels: 1,
                                          interleaved: false),
              let conv = AVAudioConverter(from: inputFmt, to: outFmt) else {
            logger.error("Could not create 16 kHz audio converter")
            isTranscribing = false
            return
        }

        let sr = targetSampleRate
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFmt) { [weak self, weak conv] buf, _ in
            guard let conv else { return }
            let ratio = sr / buf.format.sampleRate
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 1)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
            var inputDone = false
            conv.convert(to: outBuf, error: nil) { _, status in
                if inputDone { status.pointee = .noDataNow; return nil }
                inputDone = true
                status.pointee = .haveData
                return buf
            }
            guard let ch = outBuf.floatChannelData else { return }
            let count = Int(outBuf.frameLength)
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: count))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioBuffer.append(contentsOf: samples)
                if self.audioBuffer.count > self.maxBufferSamples {
                    self.audioBuffer.removeFirst(self.audioBuffer.count - self.maxBufferSamples)
                }
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            logger.info("WhisperTranscriber capture started")
        } catch {
            logger.error("Capture engine start failed: \(error.localizedDescription)")
            isTranscribing = false
        }
    }

    private func endCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    // MARK: - Transcription loop

    private func beginTranscribeLoop() {
        transcribeLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 s
                guard !Task.isCancelled else { break }
                await self?.flushChunk()
            }
        }
    }

    private func flushChunk() async {
        let minSamples = Int(targetSampleRate * 3) // need at least 3 s
        guard audioBuffer.count >= minSamples, let wkit = whisperKit else { return }

        let chunkSize = Int(targetSampleRate * chunkSeconds)
        let chunk: [Float]
        if audioBuffer.count >= chunkSize {
            chunk = Array(audioBuffer.prefix(chunkSize))
            audioBuffer.removeFirst(chunkSize)
        } else {
            chunk = audioBuffer
            audioBuffer = []
        }

        // Capture speakerKit reference while still on main actor
        let skit = speakerKit

        do {
            // Run transcription and diarization concurrently on separate tasks
            let decodeOptions = DecodingOptions(wordTimestamps: true)
            let transcribeTask = Task { try await wkit.transcribe(audioArray: chunk, decodeOptions: decodeOptions) }
            let diarizeTask = Task<DiarizationResult?, Never> {
                guard let skit else { return nil }
                return try? await skit.diarize(audioArray: chunk)
            }

            let transcription = try await transcribeTask.value
            let diarization = await diarizeTask.value

            let attributed: String
            if let diarization, !transcription.isEmpty {
                let segments = diarization.addSpeakerInfo(to: transcription, strategy: .subsegment)
                attributed = buildAttributedText(from: segments)
            } else {
                // Fallback: no diarization — plain transcript
                attributed = transcription.map { $0.text }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if !attributed.isEmpty {
                committedText += (committedText.isEmpty ? "" : "\n") + attributed
                transcript = committedText
                logger.debug("Chunk: \(attributed)")
            }
        } catch {
            logger.error("Transcription error: \(error.localizedDescription)")
        }
    }

    // MARK: - Speaker attribution formatting

    /// Groups consecutive speaker-attributed words into labelled lines.
    ///
    ///     Speaker 1: Hey, how's it going?
    ///     Speaker 2: Pretty good, thanks!
    private func buildAttributedText(from segments: [[SpeakerSegment]]) -> String {
        var lines: [String] = []
        var currentLabel: String? = nil
        var currentWords: [String] = []

        func flush() {
            guard let label = currentLabel, !currentWords.isEmpty else { return }
            let text = currentWords.joined().trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { lines.append("\(label): \(text)") }
        }

        for segmentGroup in segments {
            for segment in segmentGroup {
                let label: String
                switch segment.speaker {
                case .speakerId(let id):
                    // Resolve per-chunk ID → persistent session ID
                    if let existing = speakerRegistry[id] {
                        label = "Speaker \(existing)"
                    } else {
                        speakerRegistry[id] = nextPersistentId
                        label = "Speaker \(nextPersistentId)"
                        nextPersistentId += 1
                    }
                case .multiple:  label = "Multiple"
                case .noMatch:   label = "Unknown"
                }
                let words = segment.speakerWords.map { $0.wordTiming.word }
                if label == currentLabel {
                    currentWords.append(contentsOf: words)
                } else {
                    flush()
                    currentLabel = label
                    currentWords = words
                }
            }
        }
        flush()
        return lines.joined(separator: "\n")
    }
}
