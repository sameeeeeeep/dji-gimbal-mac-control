import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.gimbal.controller", category: "ClaudeAgent")

// MARK: - Chat message (UI-facing)

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    let timestamp = Date()
    var toolCalls: [String] = []
    var isError: Bool = false

    enum Role { case user, assistant, system }
}

// MARK: - Errors

enum ClaudeAgentError: LocalizedError {
    case binaryNotFound
    case processFailed(Int32, String)
    case parseFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:           return "claude CLI not found — install with `npm install -g @anthropic-ai/claude-code`"
        case .processFailed(let c, let s): return "claude exited \(c): \(s.prefix(220))"
        case .parseFailed(let s):       return "Bad response: \(s.prefix(160))"
        case .notConnected:             return "Agent not connected to gimbal/tracker"
        }
    }
}

// MARK: - Embedded instructions (system prompt)

/// Written to ~/Library/Application Support/GimbalController/gimbal-instructions.md
/// on first start. Edit here to change the agent's behavior.
private let gimbalInstructions = """
# Gimbal Controller AI

You are the natural-language brain for a DJI gimbal mounted on a camera. The user types short commands. You translate them into a sequence of tool calls executed by a Swift harness.

## Strict output format

Respond with **ONLY a single JSON object**. No preamble, no markdown fences, no prose outside the JSON. Plain JSON.

Schema:
```
{
  "actions": [
    {"tool": "<name>", "args": {<key>: <value>}}
  ],
  "say": "<one short confirmation sentence>"
}
```

If the user asks a question (e.g. "what do you see?"), include a query tool like `get_observation` in actions — the harness shows that result to the user.

## Hardware

- Yaw  -160°…+160° (negative = left, 0° = forward, positive = right)
- Pitch -35°…+35°  (negative = down, 0° = level, positive = up)
- Gimbal must be BLE-connected for motion tools.
- Camera must be running for capture/follow tools.

## Tool catalog

### Motion
- `look_at({"yaw": <deg>, "pitch": <deg>})` — absolute angles
- `rotate_by({"delta_yaw": <deg>, "delta_pitch": <deg>})` — relative
- `recenter()` — back to 0°,0°
- `stop_all()` — halt all motion + unfollow + unlock

### Tracking
- `follow({"start": true|false})` — auto-track subject in frame
- `lock()` / `unlock()` — pin gimbal even during follow
- `set_gain({"value": 0.0–1.0})` — follow aggressiveness

### Mapping
- `scan_room()` — sweep room, detect all people
- `list_people()` — query: list mapped people with angles
- `navigate_to_person({"name_or_number": "<name or speaker number>"})`

### Capture
- `take_photo()`
- `record({"start": true|false})`

### Vision analysis
- `analyze({"start": true|false})` — start/stop SHOT/PRESENCE/MOMENT observations
- `get_observation()` — query: read latest scene description

## Examples

User: "rotate 30 degrees left and take a photo"
Output: `{"actions":[{"tool":"rotate_by","args":{"delta_yaw":-30}},{"tool":"take_photo"}],"say":"Rotated left and captured"}`

User: "look at alice"
Output: `{"actions":[{"tool":"list_people"},{"tool":"navigate_to_person","args":{"name_or_number":"alice"}}],"say":"Looking at Alice"}`

User: "what's happening right now?"
Output: `{"actions":[{"tool":"get_observation"}],"say":""}`

User: "scan room then follow whoever is talking"
Output: `{"actions":[{"tool":"scan_room"},{"tool":"follow","args":{"start":true}}],"say":"Scanning then following"}`

User: "stop"
Output: `{"actions":[{"tool":"stop_all"}],"say":"Stopped"}`

User: "go up a bit"
Output: `{"actions":[{"tool":"rotate_by","args":{"delta_pitch":10}}],"say":"Tilted up"}`

User: "lock here"
Output: `{"actions":[{"tool":"lock"}],"say":"Locked"}`

## Rules

1. Output JSON only. Nothing else. No code fences.
2. `say` is at most one short sentence — terse confirmation, no filler.
3. Do NOT use any built-in tools (Bash, Read, Write, Edit, Web*, Task). Only emit the action JSON.
4. Chain multiple actions when the request is multi-step.
5. If the request is genuinely unclear, output `{"actions":[],"say":"Clarify: <what you need>"}`.
6. Negative yaw = LEFT. Positive yaw = RIGHT. Don't get this wrong.
"""

// MARK: - ClaudeAgent

/// Spawns `claude -p` as a subprocess per user command, with `gimbal-instructions.md`
/// appended to the system prompt. Parses the model's JSON response and dispatches the
/// action sequence locally against the gimbal + tracker.
///
/// Uses the user's existing Claude Code login — no API key required.
@MainActor
final class ClaudeAgent: ObservableObject {

    // ── Public state ────────────────────────────────────────────────
    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    @Published var lastError: String? = nil

    weak var gimbal:  GimbalService?
    weak var tracker: CameraTracker?

    private var cachedBinary: String? = nil
    private var instructionsURL: URL?

    var binaryPath: String? {
        if let cached = cachedBinary { return cached }
        let p = Self.findClaudeBinary()
        cachedBinary = p
        return p
    }

    var isConfigured: Bool { binaryPath != nil }

    // ── Lifecycle ───────────────────────────────────────────────────
    func connect(gimbal: GimbalService, tracker: CameraTracker) {
        self.gimbal  = gimbal
        self.tracker = tracker
        // Materialise instructions on disk so Claude Code can reference / re-read them.
        instructionsURL = Self.writeInstructionsToDisk()
    }

    func clearHistory() {
        messages = []
        lastError = nil
    }

    // ── Public entry point ──────────────────────────────────────────
    func send(_ userInput: String) {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }
        guard let binary = binaryPath else {
            lastError = ClaudeAgentError.binaryNotFound.errorDescription
            return
        }

        messages.append(ChatMessage(role: .user, text: trimmed))
        isThinking = true
        lastError  = nil
        Task { await runOnce(userInput: trimmed, binary: binary) }
    }

    // MARK: - Subprocess invocation

    private func runOnce(userInput: String, binary: String) async {
        defer { isThinking = false }

        let raw: String
        do {
            raw = try await spawnClaude(binary: binary, userPrompt: userInput)
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .system, text: error.localizedDescription, isError: true))
            logger.error("claude spawn failed: \(error.localizedDescription)")
            return
        }

        // Try to extract JSON from the response.
        guard let plan = Self.extractJSON(from: raw) else {
            // Treat as a free-form reply
            messages.append(ChatMessage(role: .assistant, text: raw.trimmingCharacters(in: .whitespacesAndNewlines)))
            return
        }

        let say     = (plan["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = plan["actions"] as? [[String: Any]] ?? []

        // Execute actions sequentially, gather names + query results
        var toolNames: [String] = []
        var queryResults: [String] = []
        for act in actions {
            let name = act["tool"] as? String ?? ""
            let args = act["args"] as? [String: Any] ?? [:]
            guard !name.isEmpty else { continue }
            let result = await executeTool(name: name, input: args)
            toolNames.append(name)
            // Surface query-style results to the user
            if Self.isQueryTool(name) {
                queryResults.append("[\(name)] \(result)")
            }
            logger.info("action \(name) → \(result.prefix(80))")
        }

        var displayText = say
        if !queryResults.isEmpty {
            if !displayText.isEmpty { displayText += "\n\n" }
            displayText += queryResults.joined(separator: "\n")
        }

        if displayText.isEmpty && toolNames.isEmpty {
            // Empty plan — just dump raw text so user sees something
            displayText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        messages.append(ChatMessage(
            role: .assistant,
            text: displayText,
            toolCalls: toolNames
        ))
    }

    private static func isQueryTool(_ name: String) -> Bool {
        ["list_people", "get_observation"].contains(name)
    }

    // ── Process spawn ───────────────────────────────────────────────
    private func spawnClaude(binary: String, userPrompt: String) async throws -> String {
        let systemPrompt = gimbalInstructions
        // Wrap user input so the FORMAT CONSTRAINT is the last/freshest thing the
        // model sees. Claude Code's default system prompt is conversational, and
        // --append-system-prompt is too easily overridden by it. Forcing the
        // schema into the user message reliably anchors the JSON-only output.
        let wrappedUserPrompt = """
        Translate this command into the gimbal action JSON. Output ONLY the JSON object — no prose, no markdown fences, no greeting.

        COMMAND: \(userPrompt)

        Schema (copy exactly):
        {"actions":[{"tool":"<name>","args":{<key>:<value>}}],"say":"<one short sentence>"}

        Tools available: look_at, rotate_by, recenter, follow, lock, unlock, scan_room, navigate_to_person, list_people, take_photo, record, analyze, get_observation, set_gain, stop_all.

        Reply with the JSON object now:
        """

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binary)
            proc.arguments = [
                "-p", wrappedUserPrompt,
                "--append-system-prompt", systemPrompt,
                "--output-format", "text",
                "--model", "claude-haiku-4-5",
                // Block built-in tools — we want the model to ONLY emit JSON.
                "--disallowedTools",
                "Bash,Edit,Write,Read,WebFetch,WebSearch,Task,NotebookEdit,Grep,Glob"
            ]

            // Give the subprocess a sane PATH so it can find node etc.
            var env = ProcessInfo.processInfo.environment
            let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            if let cur = env["PATH"], !cur.isEmpty { env["PATH"] = "\(cur):\(extraPath)" }
            else                                   { env["PATH"] = extraPath }
            // Force Claude Code to fall back to standard OAuth credentials
            // (~/.claude/.credentials.json) by stripping every env var that could route auth
            // to a host-managed provider (Claude Desktop / Cursor / VSCode extension).
            // Without this strip, CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=1 makes the CLI skip
            // its own credentials file and fail with 401.
            for key in [
                "ANTHROPIC_API_KEY",
                "ANTHROPIC_AUTH_TOKEN",
                "ANTHROPIC_BASE_URL",
                "ANTHROPIC_BEDROCK_BASE_URL",
                "ANTHROPIC_VERTEX_BASE_URL",
                "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST",
                "CLAUDE_CODE_ENTRYPOINT",
                "CLAUDE_CODE_PROXY_API_KEY",
                "CLAUDE_CODE_USE_BEDROCK",
                "CLAUDE_CODE_USE_VERTEX",
                "CLAUDE_AGENT_SDK_VERSION",
            ] {
                env.removeValue(forKey: key)
            }
            proc.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError  = stderrPipe
            proc.standardInput  = FileHandle.nullDevice

            // Single-shot termination handler — collect all output then resume.
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
                    cont.resume(throwing: ClaudeAgentError.processFailed(p.terminationStatus, err.isEmpty ? out : err))
                }
            }

            do {
                try proc.run()
            } catch {
                if !resumed { resumed = true; cont.resume(throwing: error) }
            }
        }
    }

    // ── Beat synthesis (called by JournalAnalyzer) ──
    //
    // Architecture: the local VLM (Qwen-2B / Moondream) produces dumb raw "what
    // I see" sentences every tick. Claude — invoked here — reads a window of
    // those raw observations PLUS Vision facts + transcript + recent beats, and
    // synthesizes ONE polished specialist observation. Local VLM = eyes;
    // Claude = director. Each model does what it's best at.

    /// Synthesizes a single SHOT/PRESENCE/MOMENT beat from a stream of raw VLM
    /// descriptions. Returns nil on auth failure or parse failure (caller falls
    /// back to the raw VLM output so the journal never goes silent).
    func synthesizeBeat(
        rawDescriptions: [(text: String, secondsAgo: Int)],
        visionFacts:     String,
        recentTranscript: String?,
        recentBeats:     [(mode: ObservationMode, sentence: String)]
    ) async -> (mode: ObservationMode, sentence: String)? {
        guard let binary = binaryPath else { return nil }

        // Build the synthesis user prompt
        let descLines = rawDescriptions.suffix(5).map { item in
            let label = item.secondsAgo == 0 ? "now" : "\(item.secondsAgo)s ago"
            return "  - [\(label)] \(item.text)"
        }.joined(separator: "\n")

        let beatLines = recentBeats.suffix(3).map { "  - [\($0.mode.rawValue)] \($0.sentence)" }
            .joined(separator: "\n")

        let speechLine: String = (recentTranscript?.isEmpty == false)
            ? "Recent speech: \"\(recentTranscript!)\"\n"
            : ""

        let synthUser = """
        You are watching a director's monitor for someone being filmed. You can't see the image — you only have these raw visual descriptions from a small vision model that just looked at recent frames:

        \(descLines)

        \(visionFacts.isEmpty ? "" : "Apple Vision facts: \(visionFacts)\n")\(speechLine)\(beatLines.isEmpty ? "" : "Your previous beats (do NOT repeat these — say something different):\n\(beatLines)\n")
        Write ONE OBSERVATIONAL sentence. Strict rules:
          • It must DESCRIBE what's concretely visible — the room, the person, what they're doing, what just changed.
          • NO advice. NO coaching. NO aphorisms or prescriptions. NO "you should" / "let X settle Y".
          • Address the user as "you" but in a documentary-narrator voice — what they ARE, not what they should do.
          • 14 words max. Be specific. Concrete nouns, concrete verbs.

        Pick the lens that fits best:
          - shot     → the room/scene/composition: where you are, what's around, framing
          - presence → your posture/expression/state right now (descriptive, not evaluative)
          - moment   → a specific concrete action or change in the last few seconds

        GOOD examples (observational, concrete):
          {"mode":"shot","sentence":"You're in a dim wood-paneled room, framed against a bookshelf."}
          {"mode":"presence","sentence":"You're hunched into the laptop, chin propped on your left fist."}
          {"mode":"moment","sentence":"You glanced off-camera, then your eyebrows lifted as you turned back."}

        BAD examples (do NOT do this — too abstract or prescriptive):
          {"mode":"presence","sentence":"Your shoulders reveal tension — let the task settle your energy."}  ❌ advice
          {"mode":"shot","sentence":"You look engaged."}  ❌ vague, no concrete detail
          {"mode":"moment","sentence":"You should center yourself in frame."}  ❌ prescription

        Output ONLY this JSON, nothing else:
        {"mode":"shot|presence|moment","sentence":"<your observation>"}
        """

        do {
            let raw = try await spawnClaudeRaw(binary: binary, userPrompt: synthUser, maxTokens: 200)
            guard let obj  = Self.extractJSON(from: raw),
                  let modeRaw  = obj["mode"]     as? String,
                  let sentence = obj["sentence"] as? String,
                  !sentence.isEmpty
            else { return nil }
            let mode: ObservationMode
            switch modeRaw.lowercased() {
            case "shot":     mode = .shot
            case "presence": mode = .presence
            case "moment":   mode = .moment
            default:         mode = .moment
            }
            return (mode, sentence)
        } catch {
            logger.error("synthesizeBeat failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Lower-level spawn used by both the command box and the beat synthesizer.
    /// Doesn't wrap the user prompt — caller is responsible for full prompt content.
    private func spawnClaudeRaw(binary: String, userPrompt: String, maxTokens: Int) async throws -> String {
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
            proc.standardError  = stderrPipe
            proc.standardInput  = FileHandle.nullDevice

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
                    cont.resume(throwing: ClaudeAgentError.processFailed(p.terminationStatus, err.isEmpty ? out : err))
                }
            }
            do { try proc.run() } catch {
                if !resumed { resumed = true; cont.resume(throwing: error) }
            }
        }
    }

    // ── JSON extraction (model sometimes wraps in fences despite asking) ──
    private static func extractJSON(from text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Try parsing whole thing
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        // 2. Try fenced ```json … ```
        if let r = trimmed.range(of: "```json"),
           let end = trimmed.range(of: "```", range: r.upperBound..<trimmed.endIndex) {
            let inner = String(trimmed[r.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = inner.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }
        // 3. First balanced { … }
        guard let start = trimmed.firstIndex(of: "{") else { return nil }
        var depth = 0
        var endIdx: String.Index? = nil
        var inStr = false
        var esc   = false
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

    // MARK: - Tool execution

    private func executeTool(name: String, input: [String: Any]) async -> String {
        guard let tracker, let gimbal else { return "Error: agent not connected" }

        switch name {
        case "look_at":
            let yaw   = (input["yaw"]   as? Double) ?? 0
            let pitch = (input["pitch"] as? Double) ?? 0
            gimbal.absoluteRotate(yaw: yaw, pitch: pitch, time: 30)
            return String(format: "Looking at yaw=%.0f° pitch=%.0f°", yaw, pitch)

        case "rotate_by":
            let dy = (input["delta_yaw"]   as? Double) ?? 0
            let dp = (input["delta_pitch"] as? Double) ?? 0
            let cy = gimbal.state.currentPosition.yaw
            let cp = gimbal.state.currentPosition.pitch
            gimbal.absoluteRotate(yaw: cy + dy, pitch: cp + dp, time: 30)
            return String(format: "Rotated %+.0f°,%+.0f° → now %.0f°,%.0f°", dy, dp, cy + dy, cp + dp)

        case "recenter":
            gimbal.recenter()
            return "Recentered"

        case "follow":
            let start = (input["start"] as? Bool) ?? true
            if start {
                guard gimbal.state.connectionState.isConnected else { return "Gimbal not connected" }
                guard tracker.isRunning else { return "Camera not running" }
                tracker.startFollow()
                return "Following"
            } else {
                tracker.stopFollow()
                return "Stopped following"
            }

        case "lock":
            tracker.followLocked = true
            return "Locked"

        case "unlock":
            tracker.followLocked = false
            return "Unlocked"

        case "scan_room":
            guard tracker.isRunning, gimbal.state.connectionState.isConnected else {
                return "Need camera + gimbal"
            }
            tracker.scanRoom()
            return "Room scan started"

        case "navigate_to_person":
            let q = (input["name_or_number"] as? String ?? "").lowercased()
            if let entry = tracker.subjectMap.first(where: {
                ($0.name?.lowercased() ?? "") == q
            }) {
                tracker.navigateTo(yaw: entry.approximateYaw, pitch: entry.approximatePitch)
                return "Navigating to \(entry.name ?? "P\(entry.speakerNumber)")"
            }
            if let n = Int(q),
               let entry = tracker.subjectMap.first(where: { $0.speakerNumber == n }) {
                tracker.navigateTo(yaw: entry.approximateYaw, pitch: entry.approximatePitch)
                return "Navigating to person \(n)"
            }
            let avail = tracker.subjectMap.map { $0.name ?? "P\($0.speakerNumber)" }
                .joined(separator: ", ")
            return "No match for '\(q)'. Available: \(avail.isEmpty ? "(none — scan first)" : avail)"

        case "list_people":
            if tracker.subjectMap.isEmpty { return "No people mapped — run scan_room first" }
            return tracker.subjectMap.map { e in
                let n = e.name ?? "Person \(e.speakerNumber)"
                return "\(n) at yaw=\(Int(e.approximateYaw))° pitch=\(Int(e.approximatePitch))°"
            }.joined(separator: "; ")

        case "take_photo":
            guard tracker.isRunning else { return "Camera not running" }
            tracker.capturePhoto()
            return "Photo captured"

        case "record":
            let start = (input["start"] as? Bool) ?? true
            if start {
                guard tracker.isRunning else { return "Camera not running" }
                if tracker.isRecording { return "Already recording" }
                tracker.startRecording()
                return "Recording"
            } else {
                guard tracker.isRecording else { return "Not recording" }
                tracker.stopRecording()
                return "Recording stopped"
            }

        case "analyze":
            let start = (input["start"] as? Bool) ?? true
            let j = tracker.journalAnalyzer
            if start {
                guard tracker.isRunning else { return "Camera not running" }
                guard j.runner.isReady else { return "Vision model not loaded" }
                j.start(tracker: tracker, transcriber: tracker.transcriber)
                return "Analysis started"
            } else {
                j.stop()
                return "Analysis stopped"
            }

        case "get_observation":
            if let beat = tracker.journalAnalyzer.latestBeat {
                return "[\(beat.mode.rawValue)] \(beat.sentence)"
            }
            if let obs = tracker.journalAnalyzer.latestObservation {
                return obs.oneLiner
            }
            return "No observation yet"

        case "set_gain":
            let v = (input["value"] as? Double) ?? 0.3
            tracker.gain = max(0, min(1, v))
            return String(format: "Gain → %.2f", tracker.gain)

        case "stop_all":
            tracker.stopFollow()
            tracker.followLocked = false
            gimbal.setSpeed(yaw: 0, pitch: 0, roll: 0)
            return "All motion stopped"

        default:
            return "Unknown tool: \(name)"
        }
    }

    // MARK: - Disk helpers

    private static func writeInstructionsToDisk() -> URL? {
        guard let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = support.appendingPathComponent("GimbalController", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("gimbal-instructions.md")
        try? gimbalInstructions.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Binary discovery

    private static func findClaudeBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            // Claude Code local install (preferred)
            "\(home)/.claude/local/claude",
            // Homebrew-managed
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            // npm global
            "\(home)/.npm-global/bin/claude",
            "\(home)/.local/bin/claude",
            // Volta / fnm / asdf shims fall back to `which`
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Last resort — ask login shell to resolve from PATH
        return resolveViaShell("claude")
    }

    /// Run a login shell to resolve a binary on the user's PATH (handles nvm/asdf/volta).
    private static func resolveViaShell(_ name: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments     = ["-l", "-c", "command -v \(name)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            return nil
        }
        return nil
    }
}
