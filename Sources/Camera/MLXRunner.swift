import Foundation
import AppKit
import os

// MARK: - Embedded Python inference server

/// Written to ~/Library/Application Support/GimbalController/mlx_server.py on first start.
/// Requires: pip install mlx-vlm Pillow
private let mlxServerScript = """
#!/usr/bin/env python3
# Gimbal MLX VLM inference server — JSON-lines protocol on stdin/stdout
# Requires: pip install mlx-vlm Pillow  (mlx_vlm >= 0.5)
import sys, json, base64, tempfile, os

def main():
    model_tag = sys.argv[1] if len(sys.argv) > 1 else "mlx-community/Qwen2-VL-2B-Instruct-4bit"
    print(json.dumps({"status": "loading", "model": model_tag}), flush=True)

    try:
        from mlx_vlm import load, generate
        from mlx_vlm.prompt_utils import apply_chat_template
        from mlx_vlm.utils import load_config
    except ImportError as e:
        print(json.dumps({
            "status": "error",
            "message": f"Missing dependency: {e} — run: pip install mlx-vlm Pillow"
        }), flush=True)
        sys.exit(1)

    try:
        model, processor = load(model_tag)
        config = load_config(model_tag)
        print(json.dumps({"status": "ready"}), flush=True)
    except Exception as e:
        print(json.dumps({"status": "error", "message": str(e)}), flush=True)
        sys.exit(1)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req_id = ""
        tmp_paths = []
        try:
            req     = json.loads(line)
            req_id  = req.get("id", "")
            prompt  = req.get("prompt", "Describe in one sentence what is happening.")
            max_tok = int(req.get("max_tokens", 100))

            # Accept either a single `image_b64` (back-compat) or a list `images_b64`
            # for multi-image turns (Gemma 4 supports interleaved multimodal input).
            images_b64 = req.get("images_b64")
            if not images_b64:
                single = req.get("image_b64")
                images_b64 = [single] if single else []

            image_paths = []
            for b64 in images_b64:
                img_data = base64.b64decode(b64)
                tmp = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
                tmp.write(img_data)
                tmp.close()
                tmp_paths.append(tmp.name)
                image_paths.append(tmp.name)
            num_images = len(image_paths)

            messages = [{"role": "user", "content": prompt}]
            formatted = apply_chat_template(
                processor, config, messages, num_images=num_images
            )
            if not isinstance(formatted, str):
                tok = processor.tokenizer if hasattr(processor, "tokenizer") else processor
                formatted = tok.apply_chat_template(
                    formatted if isinstance(formatted, list) else messages,
                    tokenize=False, add_generation_prompt=True
                )

            # mlx-vlm generate() accepts a single path or a list of paths.
            gen_image = None
            if num_images == 1:
                gen_image = image_paths[0]
            elif num_images > 1:
                gen_image = image_paths

            result = generate(
                model, processor,
                prompt=formatted,
                image=gen_image,
                max_tokens=max_tok,
                verbose=False
            )
            response = result.text if hasattr(result, "text") else str(result)
            print(json.dumps({"id": req_id, "response": response}), flush=True)
        except Exception as e:
            print(json.dumps({"id": req_id, "error": str(e)}), flush=True)
        finally:
            for p in tmp_paths:
                try: os.unlink(p)
                except Exception: pass

if __name__ == "__main__":
    main()
"""

// MARK: - Error type

enum MLXError: LocalizedError {
    case notInstalled(String)
    case processError(String)
    case inferenceError(String)
    case notReady

    var errorDescription: String? {
        switch self {
        case .notInstalled(let msg):  return msg
        case .processError(let msg):  return "Process: \(msg)"
        case .inferenceError(let msg): return msg
        case .notReady:               return "Model not ready yet"
        }
    }
}

// MARK: - MLXRunner

/// Manages a long-lived Python mlx-vlm subprocess (SmolVLM by default).
///
/// Protocol (JSON lines on stdin/stdout):
///   → {"id": "uuid", "prompt": "...", "max_tokens": 100, "image_b64": "<opt JPEG>"}
///   ← {"id": "uuid", "response": "..."}   OR  {"id": "uuid", "error": "..."}
///   ← {"status": "loading"|"ready"|"error", "model": "...", "message": "..."}
///
/// The process is kept warm between calls so model weights stay in memory.
/// SmolVLM-4bit (~1.7 GB) loads in ~15 s on M1 Air and generates ~12 tokens/s.
@MainActor
final class MLXRunner: ObservableObject {

    enum State: Equatable {
        case idle
        case loading(String)   // model name being loaded
        case ready
        case error(String)
    }

    @Published var state: State = .idle
    // Gemma 3 4B Instruct 4-bit MLX — ~2.5GB. Sweet spot between Qwen2-VL-2B
    // (too dumb) and Gemma 4 E4B (~5GB, OOMs the Metal command buffer on 8GB
    // Macs). Properly multimodal, follows the "third-person factual" prompt
    // contract much more reliably than the 2B class.
    @Published var modelTag = "mlx-community/gemma-3-4b-it-4bit"

    private var process:     Process?
    private var stdinHandle: FileHandle?
    private var dataBuffer   = Data()
    /// In-flight requests keyed by UUID string.
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private let logger = Logger(subsystem: "com.gimbal.controller", category: "MLX")

    /// Auto-restart bookkeeping: if the python process dies (e.g. Metal OOM),
    /// we kick off a new one rather than leaving the runner permanently in
    /// .error state. Counts unexpected exits in a sliding window so a wedged
    /// install doesn't loop forever.
    private var recentCrashes: [Date] = []
    private let crashWindow: TimeInterval = 120
    private let maxCrashesInWindow: Int = 3

    var isReady: Bool { state == .ready }

    // MARK: - Lifecycle

    func start() {
        guard case .idle = state else { return }

        guard let scriptURL = writeScript() else {
            state = .error("Cannot write inference script to disk")
            return
        }
        guard let pythonPath = findPython() else {
            state = .error("python3 not found — install via Homebrew or python.org")
            return
        }

        state = .loading("Starting…")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments     = [scriptURL.path, modelTag]

        let stdinPipe  = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput  = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe

        // CRITICAL: stderr MUST be drained. Without a reader, the OS pipe
        // buffer (~64KB) fills, the python process blocks on its next write,
        // and all inference freezes — the model loads, then queries time out
        // with no obvious cause. Pipe stderr lines into our logger so we can
        // see actual MLX errors instead of silent hangs.
        let stderrLogger = self.logger
        var stderrBuf = Data()
        stderrPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty { fh.readabilityHandler = nil; return }
            stderrBuf.append(chunk)
            while let nl = stderrBuf.firstIndex(of: 0x0A) {
                let lineData = stderrBuf.subdata(in: stderrBuf.startIndex..<nl)
                stderrBuf.removeSubrange(stderrBuf.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8)?
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                   !line.isEmpty {
                    stderrLogger.info("MLX stderr: \(line, privacy: .public)")
                }
            }
        }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.failAllPending(with: .processError("Process exited unexpectedly"))
                self.process     = nil
                self.stdinHandle = nil

                // Auto-restart on unexpected exit (most commonly Metal OOM
                // from a too-large image payload). Without this, a single
                // crash leaves the journal pipeline silently dead until the
                // user quits and relaunches the whole app.
                let wasReady = (self.state == .ready)
                let now = Date()
                self.recentCrashes.append(now)
                self.recentCrashes.removeAll { now.timeIntervalSince($0) > self.crashWindow }

                if self.recentCrashes.count > self.maxCrashesInWindow {
                    self.logger.error("MLX crashed \(self.recentCrashes.count) times in \(Int(self.crashWindow))s — giving up auto-restart")
                    self.state = .error("MLX repeatedly crashing — check logs")
                    return
                }
                if wasReady {
                    self.logger.warning("MLX exited unexpectedly — restarting (attempt \(self.recentCrashes.count))")
                    self.state = .idle
                    // Small delay so the previous Process object fully drains
                    // its pipes before we reuse the readabilityHandlers.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.start()
                    }
                } else {
                    self.state = .error("Process exited")
                }
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { fh.readabilityHandler = nil; return }
            DispatchQueue.main.async { [weak self] in self?.ingest(chunk) }
        }

        do {
            try proc.run()
        } catch {
            state = .error("Failed to launch python3: \(error.localizedDescription)")
            return
        }

        process     = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        logger.info("MLX process started (pid \(proc.processIdentifier))")
    }

    func stop() {
        process?.terminate()
        process     = nil
        stdinHandle = nil
        dataBuffer  = Data()
        failAllPending(with: .processError("Runner stopped"))
        state = .idle
    }

    // MARK: - Query

    /// Send a prompt (+ optional camera frame) to the VLM and await the response.
    /// Throws if the model is not ready or if inference fails.
    func query(_ prompt: String, image: CGImage? = nil, maxTokens: Int = 100) async throws -> String {
        try await query(prompt, images: image.map { [$0] } ?? [], maxTokens: maxTokens)
    }

    /// Multi-image variant: the VLM sees all images in one turn (Gemma 4 handles
    /// interleaved multimodal input). Order in the array is the order the model
    /// sees them — refer to them as "Image 1", "Image 2", etc. in the prompt.
    func query(_ prompt: String, images: [CGImage], maxTokens: Int = 100) async throws -> String {
        guard case .ready = state else { throw MLXError.notReady }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { [weak self] cont in
            guard let self else {
                cont.resume(throwing: MLXError.processError("Runner deallocated"))
                return
            }
            self.pending[id] = cont
            var body: [String: Any] = ["id": id, "prompt": prompt,
                                       "max_tokens": min(maxTokens, 200)]
            let encoded = images.compactMap { Self.encodeJPEG($0) }
            if encoded.count == 1 {
                body["image_b64"] = encoded[0]
            } else if encoded.count > 1 {
                body["images_b64"] = encoded
            }
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                self.pending.removeValue(forKey: id)
                cont.resume(throwing: MLXError.processError("Serialization failed"))
                return
            }
            self.stdinHandle?.write(data + Data("\n".utf8))
        }
    }

    /// Encode a CGImage as a JPEG for transport to the Python process.
    /// Capped at 512px wide — on 8GB Macs Gemma 4's vision encoder OOMs the
    /// Metal command buffer with larger inputs. The encoder downsamples to
    /// its own patch grid internally, so bigger source images gain no quality.
    private static func encodeJPEG(_ image: CGImage) -> String? {
        let maxW = 512
        let scale = min(1.0, Double(maxW) / Double(image.width))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let resized = { ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.makeImage() }()
        else { return nil }
        let rep = NSBitmapImageRep(cgImage: resized)
        guard let data = rep.representation(using: .jpeg,
                                             properties: [.compressionFactor: 0.7]) else {
            return nil
        }
        return data.base64EncodedString()
    }

    // MARK: - Stdout processing

    private func ingest(_ chunk: Data) {
        dataBuffer.append(chunk)
        while let nl = dataBuffer.range(of: Data("\n".utf8)) {
            let lineData = dataBuffer[dataBuffer.startIndex..<nl.lowerBound]
            dataBuffer.removeSubrange(dataBuffer.startIndex...nl.upperBound - 1)
            if let line = String(data: lineData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                handleLine(line)
            }
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // Status messages from the server
        if let status = obj["status"] as? String {
            switch status {
            case "loading":
                let name = (obj["model"] as? String ?? modelTag)
                    .components(separatedBy: "/").last ?? modelTag
                state = .loading(name)
                logger.info("MLX: loading \(name)")
            case "ready":
                state = .ready
                logger.info("MLX: model ready")
            case "error":
                let msg = obj["message"] as? String ?? "Unknown error"
                state = .error(msg)
                logger.error("MLX: \(msg)")
                failAllPending(with: .notInstalled(msg))
            default: break
            }
            return
        }

        // Response to a query
        guard let id   = obj["id"] as? String,
              let cont = pending.removeValue(forKey: id) else { return }

        if let resp = obj["response"] as? String {
            cont.resume(returning: resp)
        } else {
            let msg = obj["error"] as? String ?? "Empty response"
            cont.resume(throwing: MLXError.inferenceError(msg))
        }
    }

    private func failAllPending(with error: MLXError) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending = [:]
    }

    // MARK: - Helpers

    private func writeScript() -> URL? {
        guard let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = support.appendingPathComponent("GimbalController", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mlx_server.py")
        do {
            try mlxServerScript.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            logger.error("Failed to write MLX script: \(error.localizedDescription)")
            return nil
        }
    }

    private func findPython() -> String? {
        // Prefer the venv we create alongside the script — it has mlx-lm pre-installed
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let venvPython = support?
            .appendingPathComponent("GimbalController/venv/bin/python3").path ?? ""

        let candidates = [
            venvPython,
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
