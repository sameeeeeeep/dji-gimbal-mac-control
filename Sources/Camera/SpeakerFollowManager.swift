import AVFoundation
import os

/// Lightweight real-time Voice Activity Detector using AVAudioEngine.
///
/// Continuously measures RMS amplitude from the default microphone. When the
/// smoothed level crosses `threshold`, `speechActive` is set true so the
/// camera background thread can pick the speaking face without crossing actor
/// boundaries.
@MainActor
final class SpeakerFollowManager: ObservableObject {
    // MARK: - Published state

    @Published var isSpeechDetected = false
    /// 0–1 normalised level for UI meter display.
    @Published var audioLevel: Float = 0
    @Published var threshold: Float = 0.018 {
        didSet { bgThreshold = threshold }
    }

    // MARK: - Background-thread readable (nonisolated)

    /// Mirrored copy of `isSpeechDetected` safe to read from any thread.
    nonisolated(unsafe) var speechActive: Bool = false

    /// Called on the main actor whenever speech detection state flips.
    /// Use this to update a `nonisolated(unsafe)` mirror on the subscriber
    /// so the camera background queue can read it without crossing actor boundaries.
    var onSpeechStateChanged: ((Bool) -> Void)?

    // MARK: - Private

    private var audioEngine: AVAudioEngine?
    private var smoothedLevel: Float = 0
    nonisolated(unsafe) private var bgThreshold: Float = 0.018

    private let logger = Logger(subsystem: "com.gimbal.controller", category: "SpeakerVAD")

    // MARK: - Lifecycle

    func start() {
        guard audioEngine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }
        do {
            try engine.start()
            audioEngine = engine
            logger.info("VAD audio engine started")
        } catch {
            logger.error("VAD start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isSpeechDetected = false
        speechActive = false
        audioLevel = 0
        smoothedLevel = 0
        logger.info("VAD stopped")
    }

    // MARK: - Audio processing (called on CoreAudio thread)

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frameLen = Int(buffer.frameLength)
        guard frameLen > 0 else { return }

        // RMS across all channels
        let channelCount = Int(buffer.format.channelCount)
        var sum: Float = 0
        for ch in 0..<channelCount {
            let ch_data = data[ch]
            for i in 0..<frameLen { sum += ch_data[i] * ch_data[i] }
        }
        let rms = sqrt(sum / Float(frameLen * channelCount))

        // Update on main actor — one hop is fine; camera thread reads `speechActive`
        // which is updated synchronously after this.
        Task { @MainActor [weak self] in
            guard let self else { return }
            // EMA smoothing: fast attack (0.25), slow release (0.92)
            let alpha: Float = rms > self.smoothedLevel ? 0.25 : 0.08
            self.smoothedLevel = alpha * rms + (1.0 - alpha) * self.smoothedLevel
            self.audioLevel = min(1.0, self.smoothedLevel * 50)
            let active = self.smoothedLevel > self.bgThreshold
            if active != self.isSpeechDetected {
                self.onSpeechStateChanged?(active)
            }
            self.isSpeechDetected = active
            self.speechActive = active
        }
    }
}
