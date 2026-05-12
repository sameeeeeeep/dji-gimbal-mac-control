import Foundation
import AppKit

// Standalone, non-UI mirror of Sources/Camera/MLXRunner.swift. Uses the SAME
// JSON-line protocol on stdin/stdout, the SAME model tag, and the SAME embedded
// python script — so the harness output is directly comparable to what the
// live app produces. Kept as a separate copy because the Swift module split
// from the live app is non-trivial and the parallel-edit constraints forbid
// touching the original file.

private let mlxServerScript = """
#!/usr/bin/env python3
# Gimbal MLX VLM inference server - JSON-lines protocol on stdin/stdout
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
            "message": f"Missing dependency: {e} - run: pip install mlx-vlm Pillow"
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

enum HarnessMLXError: Error, CustomStringConvertible {
    case noPython
    case scriptWriteFailed
    case launchFailed(String)
    case loadFailed(String)
    case notReady
    case inference(String)

    var description: String {
        switch self {
        case .noPython: return "python3 not found - install via Homebrew or python.org"
        case .scriptWriteFailed: return "Cannot write inference script to disk"
        case .launchFailed(let s): return "Failed to launch python3: \(s)"
        case .loadFailed(let s): return "MLX model load failed: \(s)"
        case .notReady: return "Model not ready"
        case .inference(let s): return "Inference failed: \(s)"
        }
    }
}

/// Non-actor variant of MLXRunner suitable for command-line use. Same JSON-line
/// protocol; the readability handlers run on background queues and the request
/// dispatch is serialized through a single dispatch queue.
final class HarnessMLXRunner {

    /// Default model tag matches the live app (Sources/Camera/MLXRunner.swift).
    var modelTag = "mlx-community/gemma-3-4b-it-4bit"

    private(set) var isReady: Bool = false
    private(set) var lastError: String?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var dataBuffer = Data()

    private let lock = NSLock()
    private var pending: [String: (Result<String, Error>) -> Void] = [:]

    func start() throws {
        guard let pythonPath = Self.findPython() else { throw HarnessMLXError.noPython }
        guard let scriptURL = Self.writeScript() else { throw HarnessMLXError.scriptWriteFailed }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptURL.path, modelTag]

        let stdinPipe  = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput  = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe

        // Drain stderr so the python pipe buffer never fills (matches live app).
        stderrPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty { fh.readabilityHandler = nil; return }
            if let s = String(data: chunk, encoding: .utf8) {
                FileHandle.standardError.write(Data("[mlx-stderr] \(s)".utf8))
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            if chunk.isEmpty { fh.readabilityHandler = nil; return }
            self?.ingest(chunk)
        }

        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let conts = self.pending
            self.pending.removeAll()
            self.lock.unlock()
            for (_, c) in conts { c(.failure(HarnessMLXError.inference("Process exited"))) }
            self.isReady = false
        }

        do {
            try proc.run()
        } catch {
            throw HarnessMLXError.launchFailed(error.localizedDescription)
        }
        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
    }

    func stop() {
        process?.terminate()
        process = nil
        stdinHandle = nil
    }

    /// Send prompt + images. Caller must ensure `isReady == true` first.
    func query(_ prompt: String, images: [CGImage], maxTokens: Int = 100) async throws -> String {
        guard isReady else { throw HarnessMLXError.notReady }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.lock.lock()
            self.pending[id] = { result in
                switch result {
                case .success(let s): cont.resume(returning: s)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            self.lock.unlock()

            var body: [String: Any] = ["id": id, "prompt": prompt, "max_tokens": min(maxTokens, 200)]
            let encoded = images.compactMap { Self.encodeJPEG($0) }
            if encoded.count == 1 {
                body["image_b64"] = encoded[0]
            } else if encoded.count > 1 {
                body["images_b64"] = encoded
            }
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                self.lock.lock()
                let c = self.pending.removeValue(forKey: id)
                self.lock.unlock()
                c?(.failure(HarnessMLXError.inference("Serialization failed")))
                return
            }
            self.stdinHandle?.write(data + Data("\n".utf8))
        }
    }

    // MARK: - Stdout processing

    private func ingest(_ chunk: Data) {
        // ingest is called from a background pipe queue; mutate buffer under lock
        lock.lock()
        dataBuffer.append(chunk)
        var lines: [String] = []
        while let nl = dataBuffer.range(of: Data("\n".utf8)) {
            let lineData = dataBuffer[dataBuffer.startIndex..<nl.lowerBound]
            dataBuffer.removeSubrange(dataBuffer.startIndex...nl.upperBound - 1)
            if let s = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                lines.append(s)
            }
        }
        lock.unlock()
        for line in lines { handleLine(line) }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let status = obj["status"] as? String {
            switch status {
            case "loading":
                FileHandle.standardError.write(Data("[harness] MLX loading: \(obj["model"] as? String ?? modelTag)\n".utf8))
            case "ready":
                isReady = true
                FileHandle.standardError.write(Data("[harness] MLX ready\n".utf8))
            case "error":
                let msg = obj["message"] as? String ?? "unknown"
                lastError = msg
                FileHandle.standardError.write(Data("[harness] MLX error: \(msg)\n".utf8))
                lock.lock()
                let conts = pending
                pending.removeAll()
                lock.unlock()
                for (_, c) in conts { c(.failure(HarnessMLXError.loadFailed(msg))) }
            default: break
            }
            return
        }

        guard let id = obj["id"] as? String else { return }
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        guard let cont else { return }
        if let resp = obj["response"] as? String {
            cont(.success(resp))
        } else {
            cont(.failure(HarnessMLXError.inference(obj["error"] as? String ?? "empty")))
        }
    }

    // MARK: - Helpers

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
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let resized = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: resized)
        guard let data = rep.representation(using: .jpeg,
                                            properties: [.compressionFactor: 0.7]) else {
            return nil
        }
        return data.base64EncodedString()
    }

    private static func writeScript() -> URL? {
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
            return nil
        }
    }

    private static func findPython() -> String? {
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
