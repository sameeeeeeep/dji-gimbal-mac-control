import Foundation
import Vision
import AppKit
import os

// MARK: - Data model

struct KnownFace: Codable {
    let id: UUID
    var name: String
    /// NSKeyedArchiver-encoded VNFeaturePrintObservation
    var featurePrintData: Data
}

// MARK: - FaceRecognizer

/// Stores and recognises named faces using Vision feature prints.
/// Usage:
///   1. When an unknown face is detected, call `tag(crop:name:)` to store it.
///   2. On each frame, call `recognize(crop:)` to get a name (or nil if unknown).
@MainActor
final class FaceRecognizer: ObservableObject {

    @Published var knownFaces: [KnownFace] = []

    private let storageURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("GimbalController", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("known_faces.json")
    }()

    private let logger = Logger(subsystem: "com.gimbal.controller", category: "FaceRecognizer")
    /// Recognition distance threshold — lower = stricter.  0.8 works well for VNFeaturePrintObservation.
    private let distanceThreshold: Float = 0.80

    init() { load() }

    // MARK: - Tag (store new face)

    /// Capture a feature print for `crop` and associate it with `name`.
    /// Replaces an existing entry with the same name if present.
    func tag(crop: CGImage, name: String) {
        guard let print = featurePrint(for: crop) else {
            logger.error("FaceRecognizer: failed to generate feature print for '\(name)'")
            return
        }
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: print,
                                                            requiringSecureCoding: true) else {
            logger.error("FaceRecognizer: failed to archive feature print for '\(name)'")
            return
        }
        let face = KnownFace(id: UUID(), name: name, featurePrintData: data)
        if let idx = knownFaces.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            knownFaces[idx] = face
        } else {
            knownFaces.append(face)
        }
        save()
        logger.info("FaceRecognizer: tagged '\(name)' — \(self.knownFaces.count) known faces total")
    }

    // MARK: - Recognize

    /// Returns the name of the closest matching known face, or nil if no match is close enough.
    /// Call this on a background thread — feature print generation is CPU-bound.
    nonisolated func recognize(crop: CGImage) -> String? {
        guard let newPrint = featurePrint(for: crop) else { return nil }
        var bestName: String? = nil
        var bestDist: Float  = .greatestFiniteMagnitude

        // Take a snapshot to avoid data-races; knownFaces only grows/mutates on MainActor
        let snapshot: [KnownFace] = DispatchQueue.main.sync { knownFaces }

        for face in snapshot {
            guard let stored = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self,
                from: face.featurePrintData
            ) else { continue }
            var dist: Float = 0
            if (try? newPrint.computeDistance(&dist, to: stored)) != nil, dist < bestDist {
                bestDist = dist
                bestName = face.name
            }
        }
        return (bestDist < distanceThreshold) ? bestName : nil
    }

    // MARK: - Face crop utility

    /// Crops a face from the full camera frame given a Vision bounding box.
    /// Vision bbox: origin bottom-left, normalised [0,1].  CGImage origin: top-left.
    static func cropFace(from image: CGImage, bbox: CGRect) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        // Flip Y and expand slightly for a generous crop
        let pad: CGFloat = 0.15
        let expandedBox = bbox.insetBy(dx: -bbox.width * pad, dy: -bbox.height * pad)
        let cropRect = CGRect(
            x:      clamp(expandedBox.minX, 0, 1) * w,
            y:      (1 - clamp(expandedBox.maxY, 0, 1)) * h,
            width:  clamp(expandedBox.width,  0, 1 - expandedBox.minX) * w,
            height: clamp(expandedBox.height, 0, 1 - (1 - expandedBox.maxY)) * h
        )
        guard cropRect.width > 20, cropRect.height > 20 else { return nil }
        return image.cropping(to: cropRect)
    }

    // MARK: - Persistence

    func removeFace(id: UUID) {
        knownFaces.removeAll { $0.id == id }
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(knownFaces)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            logger.error("FaceRecognizer: save failed: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        do {
            knownFaces = try JSONDecoder().decode([KnownFace].self, from: data)
            logger.info("FaceRecognizer: loaded \(self.knownFaces.count) known face(s)")
        } catch {
            logger.error("FaceRecognizer: load failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private nonisolated func featurePrint(for image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .centerCrop
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return request.results?.first
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }
}
