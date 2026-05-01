import Foundation
import CoreGraphics
import AppKit
import os

private let logger = Logger(subsystem: "com.gimbal.controller", category: "Panorama")

/// A single camera frame captured during the room scan, tagged with gimbal angles.
struct CapturedFrame {
    let image: CGImage
    let yaw: Double    // gimbal yaw in degrees when captured
    let pitch: Double  // gimbal pitch in degrees when captured
}

/// Stitches captured frames into an equirectangular panorama image using known
/// gimbal angles — no feature matching needed because the pose is exact.
///
/// Output: 2048 × 1024 equirectangular image, standard orientation
/// (longitude –180° → +180° left-to-right, latitude +90° → –90° top-to-bottom).
@MainActor
final class PanoramaBuilder: ObservableObject {
    @Published var panorama: NSImage? = nil
    @Published var isBuilding = false

    let canvasWidth  = 2048
    let canvasHeight = 1024

    /// Horizontal FOV of the capture camera (degrees).
    static let hFOV: Double = 65.0

    // MARK: - Public API

    func build(from frames: [CapturedFrame]) {
        guard !frames.isEmpty else { return }
        isBuilding = true
        panorama = nil

        let w = canvasWidth, h = canvasHeight
        let framesCopy = frames   // capture for detached task

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.stitch(frames: framesCopy, width: w, height: h)
            await MainActor.run { [weak self] in
                self?.panorama = result
                self?.isBuilding = false
                logger.info("Panorama built from \(frames.count) frames")
            }
        }
    }

    // MARK: - Stitching (runs on background thread)

    nonisolated private static func stitch(frames: [CapturedFrame], width: Int, height: Int) -> NSImage? {
        // Step 1 — draw frames into a CGContext (bottom-left origin).
        // Latitude +90° (north) → y = height (top of context)
        // Latitude –90° (south) → y = 0     (bottom of context)
        // Longitude –180°       → x = 0
        // Longitude +180°       → x = width
        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // Dark background for areas not covered by the scan
        ctx.setFillColor(CGColor(gray: 0.07, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for frame in frames {
            let aspect = Double(frame.image.height) / Double(frame.image.width)
            let vFOV   = hFOV * aspect

            // Angular extents of this frame on the equirectangular canvas
            let x0 = (frame.yaw  - hFOV / 2 + 180) / 360 * Double(width)
            let x1 = (frame.yaw  + hFOV / 2 + 180) / 360 * Double(width)
            let y0 = (frame.pitch - vFOV / 2 +  90) / 180 * Double(height)  // south edge
            let y1 = (frame.pitch + vFOV / 2 +  90) / 180 * Double(height)  // north edge

            let destRect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            guard destRect.width > 0, destRect.height > 0 else { continue }

            // CGImage row-0 is the top of the captured video (higher pitch).
            // CGContext.draw() would flip it (image top → rect bottom).
            // We correct with a local CTM so image top → rect top (higher y in CGContext).
            ctx.saveGState()
            ctx.translateBy(x: destRect.origin.x, y: destRect.origin.y + destRect.size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(frame.image,
                     in: CGRect(x: 0, y: 0, width: destRect.width, height: destRect.height))
            ctx.restoreGState()
        }

        guard let raw = ctx.makeImage() else { return nil }

        // Step 2 — flip vertically so the result is top-left-origin (Metal/SceneKit V=0 at top).
        // After flip: row-0 = north pole (pitch +90°) ✓
        let flipped = flipVertically(raw, width: width, height: height)
        guard let final = flipped else { return nil }

        return NSImage(cgImage: final, size: NSSize(width: width, height: height))
    }

    nonisolated private static func flipVertically(_ src: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
