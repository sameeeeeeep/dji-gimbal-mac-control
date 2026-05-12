import Foundation
import AppKit

// Standalone copy of the synthesizeBeat() pathway from
// Sources/AI/ClaudeAgent.swift. We re-implement just enough to spawn the
// `claude` CLI with the same arguments and parse the same JSON shape. The
// prompt is held verbatim from ClaudeAgent so harness output is comparable.

enum HarnessClaudeError: Error, CustomStringConvertible {
    case binaryNotFound
    case processFailed(Int32, String)
    case parseFailed(String)

    var description: String {
        switch self {
        case .binaryNotFound: return "claude CLI not found"
        case .processFailed(let c, let s): return "claude exited \(c): \(s.prefix(220))"
        case .parseFailed(let s): return "Could not parse JSON: \(s.prefix(200))"
        }
    }
}

enum HarnessObservationMode: String { case shot, presence, moment }

final class HarnessClaudeAgent {

    private let cachedBinary: String?

    init() {
        self.cachedBinary = Self.findClaudeBinary()
    }

    var isConfigured: Bool { cachedBinary != nil }
    var binaryPath: String? { cachedBinary }

    /// Mirrors ClaudeAgent.synthesizeBeat. Same prompt, same CLI flags.
    /// Returns (mode, sentence) or nil on parse failure.
    func synthesizeBeat(
        rawDescriptions: [(text: String, secondsAgo: Int)],
        visionFacts: String,
        recentTranscript: String?,
        recentBeats: [(mode: HarnessObservationMode, sentence: String)],
        gridImage: CGImage?
    ) async -> (mode: HarnessObservationMode, sentence: String)? {
        guard let binary = cachedBinary else { return nil }

        var imagePath: URL?
        if let grid = gridImage, let url = Self.writeTempJPEG(grid) {
            imagePath = url
        }
        defer {
            if let p = imagePath { try? FileManager.default.removeItem(at: p) }
        }

        let descLines = rawDescriptions.suffix(5).map { item in
            let label = item.secondsAgo == 0 ? "now" : "\(item.secondsAgo)s ago"
            return "  - [\(label)] \(item.text)"
        }.joined(separator: "\n")

        let beatLines = recentBeats.suffix(3).map { "  - [\($0.mode.rawValue)] \($0.sentence)" }
            .joined(separator: "\n")

        let speechLine: String = (recentTranscript?.isEmpty == false)
            ? "Recent speech: \"\(recentTranscript!)\"\n"
            : ""

        let imageBlock: String
        if let imagePath {
            imageBlock = """
            You are watching a director's monitor for someone being filmed. You CAN see the camera feed: the attached image is a temporal sprite-sheet of recent frames (top-left = oldest, bottom-right = newest). Use what you see directly. The dumb-eye descriptions below are extra context only.

            @\(imagePath.path)

            Dumb-eye descriptions of the same frames:
            \(descLines)
            """
        } else {
            imageBlock = """
            You are watching a director's monitor for someone being filmed. You can't see the image - you only have these raw visual descriptions from a small vision model that just looked at recent frames:

            \(descLines)
            """
        }

        let synthUser = """
        \(imageBlock)

        \(visionFacts.isEmpty ? "" : "Apple Vision facts: \(visionFacts)\n")\(speechLine)\(beatLines.isEmpty ? "" : "Your previous beats (do NOT repeat these - say something different):\n\(beatLines)\n")
        Write ONE OBSERVATIONAL sentence. Strict rules:
          - It must DESCRIBE what's concretely visible - the room, the person, what they're doing, what just changed.
          - NO advice. NO coaching. NO aphorisms or prescriptions. NO "you should" / "let X settle Y".
          - Address the user as "you" but in a documentary-narrator voice - what they ARE, not what they should do.
          - 14 words max. Be specific. Concrete nouns, concrete verbs.

        Pick the lens that fits best:
          - shot     -> the room/scene/composition: where you are, what's around, framing
          - presence -> your posture/expression/state right now (descriptive, not evaluative)
          - moment   -> a specific concrete action or change in the last few seconds

        GOOD examples (observational, concrete):
          {"mode":"shot","sentence":"You're in a dim wood-paneled room, framed against a bookshelf."}
          {"mode":"presence","sentence":"You're hunched into the laptop, chin propped on your left fist."}
          {"mode":"moment","sentence":"You glanced off-camera, then your eyebrows lifted as you turned back."}

        Output ONLY this JSON, nothing else:
        {"mode":"shot|presence|moment","sentence":"<your observation>"}
        """

        do {
            let raw = try await spawnClaudeRaw(binary: binary, userPrompt: synthUser)
            guard let obj = Self.extractJSON(from: raw),
                  let modeRaw = obj["mode"] as? String,
                  let sentence = obj["sentence"] as? String,
                  !sentence.isEmpty
            else { return nil }
            let mode: HarnessObservationMode
            switch modeRaw.lowercased() {
            case "shot": mode = .shot
            case "presence": mode = .presence
            case "moment": mode = .moment
            default: mode = .moment
            }
            return (mode, sentence)
        } catch {
            FileHandle.standardError.write(Data("[harness] Claude synth failed: \(error)\n".utf8))
            return nil
        }
    }

    private func spawnClaudeRaw(binary: String, userPrompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binary)
            proc.arguments = [
                "-p", userPrompt,
                "--output-format", "text",
                "--model", "claude-haiku-4-5",
                "--disallowedTools",
                "Bash,Edit,Write,Read,WebFetch,WebSearch,Task,NotebookEdit,Grep,Glob"
            ]

            var env = ProcessInfo.processInfo.environment
            let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["PATH"] = (env["PATH"].map { "\($0):\(extraPath)" }) ?? extraPath
            for k in [
                "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
                "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
                "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST", "CLAUDE_CODE_ENTRYPOINT",
                "CLAUDE_CODE_PROXY_API_KEY", "CLAUDE_CODE_USE_BEDROCK",
                "CLAUDE_CODE_USE_VERTEX", "CLAUDE_AGENT_SDK_VERSION",
            ] { env.removeValue(forKey: k) }
            proc.environment = env

            let stdoutPipe = Pipe(); let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe
            proc.standardInput = FileHandle.nullDevice

            var resumed = false
            proc.terminationHandler = { p in
                guard !resumed else { return }
                resumed = true
                let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                let out = String(data: outData ?? Data(), encoding: .utf8) ?? ""
                let err = String(data: errData ?? Data(), encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    cont.resume(returning: out)
                } else {
                    cont.resume(throwing: HarnessClaudeError.processFailed(p.terminationStatus, err.isEmpty ? out : err))
                }
            }
            do { try proc.run() } catch {
                if !resumed { resumed = true; cont.resume(throwing: error) }
            }
        }
    }

    private static func writeTempJPEG(_ image: CGImage) -> URL? {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("harness-beat-\(UUID().uuidString).jpg")
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg,
                                            properties: [.compressionFactor: 0.85])
        else { return nil }
        do { try data.write(to: url); return url } catch { return nil }
    }

    private static func findClaudeBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // Fall back to PATH lookup via /usr/bin/which
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", "claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0,
               let data = try? pipe.fileHandleForReading.readToEnd(),
               let s = String(data: data ?? Data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty,
               FileManager.default.isExecutableFile(atPath: s) {
                return s
            }
        } catch {}
        return nil
    }

    private static func extractJSON(from text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        if let r = trimmed.range(of: "```json"),
           let end = trimmed.range(of: "```", range: r.upperBound..<trimmed.endIndex) {
            let inner = String(trimmed[r.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = inner.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }
        guard let start = trimmed.firstIndex(of: "{") else { return nil }
        var depth = 0
        var endIdx: String.Index? = nil
        var inStr = false
        var esc = false
        for idx in trimmed[start...].indices {
            let c = trimmed[idx]
            if esc { esc = false; continue }
            if c == "\\" { esc = true; continue }
            if c == "\"" { inStr.toggle(); continue }
            if inStr { continue }
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { endIdx = idx; break }
            }
        }
        guard let e = endIdx else { return nil }
        let blob = String(trimmed[start...e])
        if let data = blob.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        return nil
    }
}
