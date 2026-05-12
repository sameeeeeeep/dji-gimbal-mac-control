import Foundation
import CoreGraphics
import Vision
import os

/// Scene-change gate using Apple Vision feature prints. The pipeline calls
/// `shouldFire` each tick and only runs the expensive VLM when the frame has
/// drifted far enough from the last-fired one. Threshold is empirical: feature
/// print distances run 0 (identical) → ~0.5+ (very different).
///
/// Not @MainActor — JournalAnalyzer's vision queue calls this from a background
/// thread. State is guarded by an NSLock.
final class EmbeddingGate {

    private let lock = NSLock()
    private var lastFired: VNFeaturePrintObservation?
    private let logger = Logger(subsystem: "com.gimbal.controller", category: "EmbeddingGate")

    /// Generate a feature print for a single image. Returns nil on Vision failure.
    func embed(_ image: CGImage) -> VNFeaturePrintObservation? {
        let req = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([req])
        } catch {
            logger.error("feature print failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return req.results?.first
    }

    /// Returns (fire, distance). `fire=true` when distance to the last-fired
    /// observation >= threshold. Updates the stored last-fired only on a fire.
    /// First call always fires (distance reported as +infinity).
    func shouldFire(_ image: CGImage, threshold: Float = 0.08) -> (fire: Bool, distance: Float) {
        guard let obs = embed(image) else {
            return (false, 0)
        }
        lock.lock()
        let prev = lastFired
        lock.unlock()

        guard let prev else {
            lock.lock(); lastFired = obs; lock.unlock()
            return (true, .infinity)
        }

        var dist: Float = 0
        do {
            try obs.computeDistance(&dist, to: prev)
        } catch {
            // Observation shape mismatch — treat as a fire and reset.
            lock.lock(); lastFired = obs; lock.unlock()
            return (true, .infinity)
        }

        if dist >= threshold {
            lock.lock(); lastFired = obs; lock.unlock()
            return (true, dist)
        }
        return (false, dist)
    }

    func reset() {
        lock.lock(); lastFired = nil; lock.unlock()
    }
}
