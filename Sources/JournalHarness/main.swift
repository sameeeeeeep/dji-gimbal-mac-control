import Foundation
import AVFoundation
import CoreGraphics
import AppKit

// CLI entrypoint: extract frames from a video at a configurable rate, run the
// same VLM + Claude pipeline the live journal uses, and write a side-by-side
// CSV. Useful for prompt / model / grid-size iteration without flashing the
// SwiftUI app onto a real gimbal.
//
// Usage:
//   journal-harness <video> [--output <csv>] [--fps <hz>] [--max-frames <N>] [--no-claude]

struct HarnessOptions {
    var videoPath: String
    var outputPath: String = "./harness-output.csv"
    var fps: Double = 0.25
    var maxFrames: Int? = nil
    var skipClaude: Bool = false
}

enum HarnessArgError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self { case .usage(let s): return s }
    }
}

func parseArgs(_ argv: [String]) throws -> HarnessOptions {
    var args = Array(argv.dropFirst())
    guard !args.isEmpty else {
        throw HarnessArgError.usage("Usage: journal-harness <video-path> [--output <csv>] [--fps <hz>] [--max-frames <N>] [--no-claude]")
    }
    let videoPath = args.removeFirst()
    if videoPath.hasPrefix("--") {
        throw HarnessArgError.usage("First positional argument must be a video path")
    }
    var opts = HarnessOptions(videoPath: videoPath)
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--output":
            guard i + 1 < args.count else { throw HarnessArgError.usage("--output requires a value") }
            opts.outputPath = args[i + 1]; i += 2
        case "--fps":
            guard i + 1 < args.count, let v = Double(args[i + 1]) else {
                throw HarnessArgError.usage("--fps requires a numeric value")
            }
            if v <= 0 { throw HarnessArgError.usage("--fps must be positive") }
            opts.fps = v; i += 2
        case "--max-frames":
            guard i + 1 < args.count, let v = Int(args[i + 1]), v > 0 else {
                throw HarnessArgError.usage("--max-frames requires a positive int")
            }
            opts.maxFrames = v; i += 2
        case "--no-claude":
            opts.skipClaude = true; i += 1
        default:
            throw HarnessArgError.usage("Unknown argument: \(a)")
        }
    }
    return opts
}

// CSV-quote a single field per RFC 4180-lite: wrap in quotes if it contains
// comma / quote / newline; double any embedded quote.
func csvQuote(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return s
}

func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func computeFrameStamps(videoURL: URL, fps: Double, maxFrames: Int?) throws -> [Double] {
    let asset = AVURLAsset(url: videoURL)
    let durationCM = asset.duration
    guard durationCM.isValid && !durationCM.isIndefinite else {
        throw HarnessArgError.usage("Could not read video duration: \(videoURL.path)")
    }
    let durationSec = CMTimeGetSeconds(durationCM)
    guard durationSec > 0 else {
        throw HarnessArgError.usage("Video has zero / negative duration: \(videoURL.path)")
    }
    let step = 1.0 / fps
    var t = 0.0
    var stamps: [Double] = []
    while t < durationSec {
        stamps.append(t)
        if let m = maxFrames, stamps.count >= m { break }
        t += step
    }
    return stamps
}

func runHarness() async {
    let opts: HarnessOptions
    do {
        opts = try parseArgs(CommandLine.arguments)
    } catch {
        eprint(String(describing: error))
        exit(2)
    }

    let videoURL = URL(fileURLWithPath: opts.videoPath)
    guard FileManager.default.fileExists(atPath: videoURL.path) else {
        eprint("[harness] error: video file not found: \(videoURL.path)")
        exit(1)
    }

    let stamps: [Double]
    do {
        stamps = try computeFrameStamps(videoURL: videoURL, fps: opts.fps, maxFrames: opts.maxFrames)
    } catch {
        eprint("[harness] error: \(error)")
        exit(1)
    }
    eprint("[harness] Will extract \(stamps.count) frame(s) at \(opts.fps) Hz from \(videoURL.lastPathComponent)")

    // --- Boot MLX ---
    eprint("[harness] Starting MLX runner...")
    let runner = HarnessMLXRunner()
    do {
        try runner.start()
    } catch {
        eprint("[harness] error: \(error)")
        exit(1)
    }
    let waitStart = Date()
    while !runner.isReady {
        if let err = runner.lastError {
            eprint("[harness] error: \(err)")
            exit(1)
        }
        if Date().timeIntervalSince(waitStart) > 90 {
            eprint("[harness] error: MLX did not become ready within 90s")
            exit(1)
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    // --- Claude wiring ---
    let claude = HarnessClaudeAgent()
    let useClaude = !opts.skipClaude && claude.isConfigured
    if !opts.skipClaude && !claude.isConfigured {
        eprint("[harness] note: claude CLI not on PATH - falling back to VLM-only output")
    }

    // --- Output paths ---
    let framesDir = URL(fileURLWithPath: "./harness-frames", isDirectory: true)
    try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

    let csvURL = URL(fileURLWithPath: opts.outputPath)
    FileManager.default.createFile(atPath: csvURL.path, contents: nil)
    guard let csvHandle = try? FileHandle(forWritingTo: csvURL) else {
        eprint("[harness] error: cannot open \(csvURL.path) for writing")
        exit(1)
    }
    try? csvHandle.truncate(atOffset: 0)
    csvHandle.write(Data("timestamp_sec,raw_vlm,raw_latency_ms,claude_mode,claude_sentence,claude_latency_ms,composite_path\n".utf8))
    try? csvHandle.synchronize()

    // --- Image generator ---
    let asset = AVURLAsset(url: videoURL)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero

    // --- SIGINT: flush + exit gracefully ---
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    signal(SIGINT, SIG_IGN)
    sigintSource.setEventHandler {
        try? csvHandle.synchronize()
        try? csvHandle.close()
        eprint("\n[harness] interrupted - partial CSV at \(csvURL.path)")
        runner.stop()
        exit(130)
    }
    sigintSource.resume()

    // --- Rolling buffer of last 16 frames ---
    var buffer: [(image: CGImage, timestamp: Date)] = []
    var written = 0
    var recentBeats: [(mode: HarnessObservationMode, sentence: String)] = []

    for (idx, sec) in stamps.enumerated() {
        let cmTime = CMTime(seconds: sec, preferredTimescale: 600)
        var actual = CMTime.zero
        let cgImage: CGImage
        do {
            cgImage = try gen.copyCGImage(at: cmTime, actualTime: &actual)
        } catch {
            eprint("[harness] frame \(idx) (t=\(String(format: "%.2f", sec))s): seek failed: \(error.localizedDescription)")
            continue
        }

        // Push to rolling buffer (cap at 16, oldest first)
        buffer.append((cgImage, Date(timeIntervalSinceReferenceDate: sec)))
        if buffer.count > 16 { buffer.removeFirst(buffer.count - 16) }

        guard let composite = HarnessGrid.composeTemporalGrid(buffer: buffer, cols: 4, rows: 4) else {
            eprint("[harness] frame \(idx): grid compose failed, skipping")
            continue
        }
        let frameFile = framesDir.appendingPathComponent(String(format: "frame-%04d.jpg", idx))
        _ = HarnessGrid.writeJPEG(composite, to: frameFile)

        let frameCount = buffer.count
        let spanSec = frameCount >= 2
            ? max(1, Int(buffer.last!.timestamp.timeIntervalSince(buffer.first!.timestamp)))
            : 0
        let prompt = HarnessGrid.buildVLMDescriptionPrompt(
            frameCount: frameCount, spanSec: spanSec, cols: 4, rows: 4
        )

        let vlmStart = Date()
        var rawText = ""
        do {
            rawText = try await runner.query(prompt, images: [composite], maxTokens: 60)
            rawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            rawText = "[error] \(error)"
        }
        let vlmMs = Int(Date().timeIntervalSince(vlmStart) * 1000)

        var claudeMode = ""
        var claudeSentence = ""
        var claudeMs = 0
        if useClaude {
            let cStart = Date()
            let result = await claude.synthesizeBeat(
                rawDescriptions: [(rawText, 0)],
                visionFacts: "",
                recentTranscript: nil,
                recentBeats: recentBeats,
                gridImage: composite
            )
            claudeMs = Int(Date().timeIntervalSince(cStart) * 1000)
            if let r = result {
                claudeMode = r.mode.rawValue
                claudeSentence = r.sentence
                recentBeats.append(r)
                if recentBeats.count > 5 { recentBeats.removeFirst(recentBeats.count - 5) }
            }
        }

        let cols: [String] = [
            String(format: "%.3f", sec),
            csvQuote(rawText),
            String(vlmMs),
            csvQuote(claudeMode),
            csvQuote(claudeSentence),
            String(claudeMs),
            csvQuote(frameFile.path),
        ]
        csvHandle.write(Data((cols.joined(separator: ",") + "\n").utf8))
        try? csvHandle.synchronize()
        written += 1

        eprint("[harness] frame \(idx) t=\(String(format: "%.2f", sec))s vlm=\(vlmMs)ms claude=\(claudeMs)ms: \(rawText.prefix(80))")
    }

    try? csvHandle.synchronize()
    try? csvHandle.close()
    runner.stop()
    eprint("[harness] Wrote \(written) frames to \(csvURL.path)")
    exit(0)
}

// Top-level entry — main.swift permits top-level statements.
let _harnessSemaphore = DispatchSemaphore(value: 0)
Task {
    await runHarness()
    _harnessSemaphore.signal()
}
_harnessSemaphore.wait()
