import Foundation
import CoreGraphics
import AppKit
import Vision
import os

private let logger = Logger(subsystem: "com.gimbal.controller", category: "Panorama")

/// A single camera frame captured during the room scan, tagged with gimbal angles.
struct CapturedFrame {
    let image: CGImage
    let yaw: Double    // gimbal yaw in degrees when captured (used as fallback hint only)
    let pitch: Double  // gimbal pitch in degrees when captured
}

/// Stitches captured frames into a flat panorama using Vision image registration.
///
/// Algorithm: VNTranslationalImageRegistrationRequest chains consecutive frame pairs
/// to compute relative pixel offsets without relying on gimbal angle data (which is
/// often stale/zero during sweeps).  The accumulated offsets place each frame on a
/// shared canvas; frames are drawn in order with blending so overlapping regions average
/// out naturally.
///
/// Fallback: if Vision registration fails (e.g. featureless frames), the builder falls
/// back to the original gimbal-angle equirectangular approach so the panorama never
/// appears completely blank.
@MainActor
final class PanoramaBuilder: ObservableObject {
    @Published var panorama: NSImage? = nil
    @Published var isBuilding = false

    let canvasWidth  = 2048
    let canvasHeight = 1024

    /// Horizontal FOV of the capture camera (degrees) — used by equirectangular fallback.
    nonisolated static let hFOV: Double = 65.0

    // MARK: - Public API

    func build(from frames: [CapturedFrame]) {
        guard !frames.isEmpty else { return }
        isBuilding = true
        panorama   = nil

        let framesCopy = frames
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.stitchFeatureBased(frames: framesCopy)
            await MainActor.run { [weak self] in
                self?.panorama   = result
                self?.isBuilding = false
                logger.info("Panorama built from \(framesCopy.count) frames (feature-based)")
            }
        }
    }

    // MARK: - Feature-based stitching (Vision registration)

    /// Chain VNTranslationalImageRegistrationRequest across consecutive frames to derive
    /// pixel-accurate offsets, then composite all frames onto a single canvas.
    nonisolated static func stitchFeatureBased(frames: [CapturedFrame]) -> NSImage? {
        guard !frames.isEmpty else { return nil }

        // Thin out to at most 60 frames so registration is fast
        let filtered = stride(from: 0, to: frames.count,
                              by: max(1, frames.count / 60)).map { frames[$0] }

        // ── Phase 1: cumulative translations via Vision ─────────────────────
        // VNTranslationalImageRegistrationRequest is a VNTargetedImageRequest:
        //   target  = reference (frame[i-1])   ← provided at init
        //   handler = floating  (frame[i])      ← provided at perform
        // alignmentTransform: how to shift the floating image to overlap the target.
        var positions: [CGPoint] = [.zero]      // frame 0 anchored at origin
        var cumX: CGFloat = 0
        var cumY: CGFloat = 0
        let refW = CGFloat(filtered[0].image.width)
        let refH = CGFloat(filtered[0].image.height)

        for i in 1..<filtered.count {
            let prevImage = filtered[i - 1].image
            let currImage = filtered[i].image
            let floatHandler = VNImageRequestHandler(cgImage: currImage, options: [:])
            do {
                let req = VNTranslationalImageRegistrationRequest(
                    targetedCGImage: prevImage, options: [:]
                )
                try floatHandler.perform([req])
                if let obs = req.results?.first as? VNImageTranslationAlignmentObservation {
                    // alignmentTransform.tx/ty: normalised shift to overlay curr onto prev.
                    // Camera moved opposite direction → add the transform to get canvas position.
                    cumX += CGFloat(obs.alignmentTransform.tx) * refW
                    cumY += CGFloat(obs.alignmentTransform.ty) * refH
                }
            } catch {
                logger.debug("PANORAMA: registration failed at frame \(i): \(error.localizedDescription)")
            }
            positions.append(CGPoint(x: cumX, y: cumY))
        }

        // ── Phase 2: canvas bounds ──────────────────────────────────────────
        var minX: CGFloat = 0, minY: CGFloat = 0
        var maxX: CGFloat = refW, maxY: CGFloat = refH

        for (i, pos) in positions.enumerated() {
            let w = CGFloat(filtered[i].image.width)
            let h = CGFloat(filtered[i].image.height)
            minX = min(minX, pos.x)
            minY = min(minY, pos.y)
            maxX = max(maxX, pos.x + w)
            maxY = max(maxY, pos.y + h)
        }

        // If registration produced no spread (all zeros), fall back to equirectangular
        let spreadX = maxX - minX - refW
        let spreadY = maxY - minY - refH
        if spreadX < 2 && spreadY < 2 {
            logger.warning("PANORAMA: registration produced no spread — falling back to equirectangular")
            return stitchEquirectangular(frames: frames)
        }

        // Cap canvas to avoid OOM on very long sweeps
        var canvasW = min(Int(maxX - minX), 4096)
        var canvasH = min(Int(maxY - minY), 2048)
        guard canvasW > 10, canvasH > 10 else { return nil }

        let scaleX = CGFloat(canvasW) / (maxX - minX)
        let scaleY = CGFloat(canvasH) / (maxY - minY)

        // ── Phase 3: composite frames into CGContext ────────────────────────
        guard let ctx = CGContext(
            data: nil,
            width: canvasW, height: canvasH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        ) else { return nil }

        // Dark fill for unvisited regions
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        ctx.interpolationQuality = .medium

        // Draw oldest frames first so the most-recent (centre) frame wins on top
        for (i, frame) in filtered.enumerated() {
            let pos   = positions[i]
            let dx    = (pos.x - minX) * scaleX
            // CGContext: y=0 is top-left, increasing downward — same as our accumulated coords
            let dy    = (pos.y - minY) * scaleY
            let dw    = CGFloat(frame.image.width)  * scaleX
            let dh    = CGFloat(frame.image.height) * scaleY
            // Blend successive frames so overlapping regions average out
            ctx.setAlpha(i == 0 ? 1.0 : 0.6)
            ctx.draw(frame.image, in: CGRect(x: dx, y: dy, width: dw, height: dh))
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: canvasW, height: canvasH))
    }

    // MARK: - Equirectangular fallback (original algorithm, used when feature registration fails)

    nonisolated static func stitchEquirectangular(frames: [CapturedFrame]) -> NSImage? {
        let width = 2048, height = 1024
        let hFOV_rad = hFOV * Double.pi / 180
        let focalLen = 0.5 / tan(hFOV_rad / 2)

        var infos: [EqFrameInfo] = []
        for frame in frames {
            guard let (bytes, fw, fh) = rawRGBA(frame.image) else { continue }
            let θy = frame.yaw   * Double.pi / 180
            let θp = frame.pitch * Double.pi / 180
            infos.append(EqFrameInfo(
                bytes: bytes, fw: fw, fh: fh,
                cosY: cos(θy), sinY: sin(θy),
                cosP: cos(θp), sinP: sin(θp),
                f: focalLen
            ))
        }
        guard !infos.isEmpty else { return nil }

        let pixCount = width * height
        var accR = [Float](repeating: 0, count: pixCount)
        var accG = [Float](repeating: 0, count: pixCount)
        var accB = [Float](repeating: 0, count: pixCount)
        var accW = [Float](repeating: 0, count: pixCount)

        accR.withUnsafeMutableBufferPointer { rBuf in
        accG.withUnsafeMutableBufferPointer { gBuf in
        accB.withUnsafeMutableBufferPointer { bBuf in
        accW.withUnsafeMutableBufferPointer { wBuf in
            DispatchQueue.concurrentPerform(iterations: height) { py in
                let lat    = (0.5 - Double(py) / Double(height)) * Double.pi
                let cosLat = cos(lat), sinLat = sin(lat)
                for px in 0..<width {
                    let lon = (Double(px) / Double(width) - 0.5) * 2.0 * Double.pi
                    let Xw = cosLat * sin(lon)
                    let Yw = sinLat
                    let Zw = cosLat * cos(lon)
                    let idx = py * width + px
                    for fi in infos {
                        let X1 = fi.cosY * Xw - fi.sinY * Zw
                        let Y1 = Yw
                        let Z1 = fi.sinY * Xw + fi.cosY * Zw
                        let Xc =  X1
                        let Yc =  fi.cosP * Y1 + fi.sinP * Z1
                        let Zc = -fi.sinP * Y1 + fi.cosP * Z1
                        guard Zc > 0.001 else { continue }
                        let u =  fi.f * Xc / Zc + 0.5
                        let v = -fi.f * Yc / Zc + 0.5
                        guard u >= 0, u < 1, v >= 0, v < 1 else { continue }
                        let wu = cos((u - 0.5) * Double.pi)
                        let wv = cos((v - 0.5) * Double.pi)
                        let w  = Float(wu * wv)
                        guard w > 0.001 else { continue }
                        let sfx = u * Double(fi.fw - 1)
                        let sfy = v * Double(fi.fh - 1)
                        let sx0 = Int(sfx), sy0 = Int(sfy)
                        let tx  = Float(sfx - Double(sx0))
                        let ty  = Float(sfy - Double(sy0))
                        let sx1 = min(sx0 + 1, fi.fw - 1)
                        let sy1 = min(sy0 + 1, fi.fh - 1)
                        let i00 = (sy0 * fi.fw + sx0) &* 4
                        let i10 = (sy0 * fi.fw + sx1) &* 4
                        let i01 = (sy1 * fi.fw + sx0) &* 4
                        let i11 = (sy1 * fi.fw + sx1) &* 4
                        let r = bilerp(Float(fi.bytes[i00]),   Float(fi.bytes[i10]),
                                       Float(fi.bytes[i01]),   Float(fi.bytes[i11]),   tx, ty)
                        let g = bilerp(Float(fi.bytes[i00+1]), Float(fi.bytes[i10+1]),
                                       Float(fi.bytes[i01+1]), Float(fi.bytes[i11+1]), tx, ty)
                        let b = bilerp(Float(fi.bytes[i00+2]), Float(fi.bytes[i10+2]),
                                       Float(fi.bytes[i01+2]), Float(fi.bytes[i11+2]), tx, ty)
                        rBuf[idx] += r * w
                        gBuf[idx] += g * w
                        bBuf[idx] += b * w
                        wBuf[idx] += w
                    }
                }
            }
        }}}}

        var out = [UInt8](repeating: 18, count: pixCount * 4)
        for i in 0..<pixCount {
            out[i*4+3] = 255
            let w = accW[i]
            guard w > 0 else { continue }
            out[i*4]   = UInt8(min(Int(accR[i] / w + 0.5), 255))
            out[i*4+1] = UInt8(min(Int(accG[i] / w + 0.5), 255))
            out[i*4+2] = UInt8(min(Int(accB[i] / w + 0.5), 255))
        }
        let cfData = out.withUnsafeBufferPointer { CFDataCreate(nil, $0.baseAddress, $0.count)! }
        guard let provider = CGDataProvider(data: cfData),
              let cgImage  = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    // MARK: - Shared helpers

    nonisolated static func rawRGBA(_ image: CGImage) -> ([UInt8], Int, Int)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            return true
        }
        return ok ? (bytes, w, h) : nil
    }

    nonisolated static func bilerp(
        _ v00: Float, _ v10: Float,
        _ v01: Float, _ v11: Float,
        _ tx: Float,  _ ty: Float
    ) -> Float {
        (v00 + (v10 - v00) * tx) * (1 - ty) + (v01 + (v11 - v01) * tx) * ty
    }
}

// MARK: - Equirectangular helper struct (private)

private struct EqFrameInfo {
    let bytes: [UInt8]
    let fw: Int, fh: Int
    let cosY: Double, sinY: Double
    let cosP: Double, sinP: Double
    let f: Double
}
