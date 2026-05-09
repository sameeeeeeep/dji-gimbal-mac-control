import Speech
import AVFoundation
import os

/// On-device live speech transcription.
///
/// Uses `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`, which
/// runs Apple's on-device ASR (a Whisper-equivalent transformer model) — no
/// network required, fully offline.
///
/// Automatically restarts recognition in a rolling window so transcription
/// remains continuous for long recordings.
@MainActor
final class LiveTranscriber: ObservableObject {
    // MARK: - Published state

    @Published var transcript = ""
    @Published var isTranscribing = false
    /// True when on-device recognition is available for the current locale.
    @Published var isOnDeviceAvailable = false
    /// The speaker label from the most recent transcription segment (e.g. "0", "1", "2").
    /// Nil when recognition hasn't identified a speaker yet.
    @Published var activeSpeakerLabel: String? = nil
    /// Available microphone inputs, including Continuity Camera (iPhone) mics.
    @Published var availableMicrophones: [AVCaptureDevice] = []
    /// Currently selected microphone (nil = system default).
    @Published var selectedMicrophone: AVCaptureDevice? = nil

    // MARK: - Background-thread readable

    /// Mirrored copy of `activeSpeakerLabel` safe to read from any thread.
    nonisolated(unsafe) var bgCurrentSpeakerLabel: String? = nil
    /// Called on main actor when the active speaker changes.
    var onSpeakerLabelChanged: ((String?) -> Void)?

    // MARK: - Private

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var engine: AVAudioEngine?
    /// Accumulated text from previous rolling windows.
    private var committedText = ""
    private var shouldRestart = false

    private let logger = Logger(subsystem: "com.gimbal.controller", category: "Transcriber")

    // MARK: - Init

    init() {
        let rec = SFSpeechRecognizer(locale: .current)
        recognizer = rec
        isOnDeviceAvailable = rec?.supportsOnDeviceRecognition ?? false

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOnDeviceAvailable = (status == .authorized)
                    && (self.recognizer?.supportsOnDeviceRecognition ?? false)
                self.logger.info("Speech auth: \(status.rawValue) onDevice=\(self.isOnDeviceAvailable)")
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard isOnDeviceAvailable, !isTranscribing else { return }
        committedText = ""
        transcript = ""
        shouldRestart = true
        isTranscribing = true
        beginWindow()
    }

    func stop() {
        shouldRestart = false
        isTranscribing = false
        activeSpeakerLabel    = nil
        bgCurrentSpeakerLabel = nil
        onSpeakerLabelChanged?(nil)
        tearDown()
    }

    func refreshMicrophones() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .external, .continuityCamera],
            mediaType: .audio,
            position: .unspecified
        )
        availableMicrophones = session.devices
    }

    // MARK: - Rolling recognition window

    /// A single SFSpeechRecognitionTask runs for at most ~60 s before the OS
    /// cuts it. We restart proactively every 30 s to stay within that limit and
    /// carry committed text forward.
    private func beginWindow() {
        guard isTranscribing else { return }
        tearDown()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.taskHint = .dictation

        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let fmt = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.request?.append(buf)
        }

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = self.committedText
                        + (self.committedText.isEmpty ? "" : " ")
                        + result.bestTranscription.formattedString

                    // NOTE: SFTranscriptionSegment.speakerLabel is not exposed
                    // on macOS in the current SDK. Speaker identity is instead
                    // derived visually via the diarization pipeline in CameraTracker.
                }
                let finished = result?.isFinal == true || error != nil
                if finished {
                    if let result, !result.bestTranscription.formattedString.isEmpty {
                        let seg = result.bestTranscription.formattedString
                        self.committedText += (self.committedText.isEmpty ? "" : " ") + seg
                    }
                    if self.shouldRestart {
                        self.beginWindow()
                    } else {
                        self.isTranscribing = false
                    }
                }
            }
        }

        do {
            try eng.start()
            engine = eng
            request = req
        } catch {
            logger.error("Transcriber engine start failed: \(error.localizedDescription)")
            isTranscribing = false
        }
    }

    private func tearDown() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
