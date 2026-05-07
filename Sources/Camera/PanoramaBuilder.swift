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

/// Pre-processed per-frame data for the stitching kernel.
private struct FrameInfo {
    let bytes: [UInt8]  // RGBA8, row-major, row 0 = image top
    let fw: Int
    let fh: Int
    let cosY: Double, sinY: Double  // precomputed yaw trig
    let cosP: Double, sinP: Double  // precomputed pitch trig
    let f: Double                   // focal length, width-normalised: 0.5/tan(hFOV/2)
}

/// Stitches captured frames into an equirectangular panorama using exact gimbal pose.
///
/// Algorithm: backward projection — for each output pixel, compute its world direction
/// (lon/lat → 3D), apply the inverse gimbal rotation to get camera-space direction,
/// project perspectively to source UV, and accumulate with a cosine edge weight.
/// Overlapping frames blend smoothly because the weight peaks at each frame's centre.
///
/// Output: 2048 × 1024 equirectangular (row 0 = north pole, row H-1 = south pole).
@MainActor
final class PanoramaBuilder: ObservableObject {
    @Published var panorama: NSImage? = nil
    @Published var isBuilding = false

    let canvasWidth  = 2048
    let canvasHeight = 1024

    /// Horizontal FOV of the capture camera (degrees).
    nonisolated static let hFOV: Double = 65.0

    // MARK: - Public API

    func build(from frames: [CapturedFrame]) {
        guard !frames.isEmpty else { return }
        isBuilding = true
        panorama = nil

        let w = canvasWidth, h = canvasHeight
        let framesCopy = frames

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.stitch(frames: framesCopy, width: w, height: h)
            await MainActor.run { [weak self] in
                self?.panorama = result
                self?.isBuilding = false
                logger.info("Panorama built from \(frames.count) frames")
            }
        }
    }

    // MARK: - Stitching kernel (background thread)

    nonisolated private static func stitch(frames: [CapturedFrame], width: Int, height: Int) -> NSImage? {
        let hFOV_rad = hFOV * Double.pi / 180
        let focalLen = 0.5 / tan(hFOV_rad / 2)

        // Pre-extract RGBA bytes for every frame
        var infos: [FrameInfo] = []
        for frame in frames {
            guard let (bytes, fw, fh) = rawRGBA(frame.image) else { continue }
            let θy = frame.yaw   * Double.pi / 180
            let θp = frame.pitch * Double.pi / 180
            infos.append(FrameInfo(
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

        // Each iteration owns a unique row → no write conflicts despite concurrency.
        accR.withUnsafeMutableBufferPointer { rBuf in
        accG.withUnsafeMutableBufferPointer { gBuf in
        accB.withUnsafeMutableBufferPointer { bBuf in
        accW.withUnsafeMutableBufferPointer { wBuf in
            DispatchQueue.concurrentPerform(iterations: height) { py in
                // Latitude: row 0 = north pole (+π/2), row H-1 = south pole (-π/2)
                let lat    = (0.5 - Double(py) / Double(height)) * Double.pi
                let cosLat = cos(lat)
                let sinLat = sin(lat)

                for px in 0..<width {
                    // Longitude: col 0 = -180°, col W-1 ≈ +180°
                    let lon = (Double(px) / Double(width) - 0.5) * 2.0 * Double.pi

                    // Equirectangular → 3D world direction (Z-forward convention)
                    let Xw = cosLat * sin(lon)
                    let Yw = sinLat
                    let Zw = cosLat * cos(lon)

                    let idx = py * width + px

                    for fi in infos {
                        // Inverse gimbal rotation: undo yaw (Y-axis), then pitch (X-axis)
                        // R_y(-yaw): X1 = cosY*Xw - sinY*Zw, Z1 = sinY*Xw + cosY*Zw
                        let X1 = fi.cosY * Xw - fi.sinY * Zw
                        let Y1 = Yw
                        let Z1 = fi.sinY * Xw + fi.cosY * Zw

                        // R_x(-pitch): Yc = cosP*Y1 + sinP*Z1, Zc = -sinP*Y1 + cosP*Z1
                        let Xc =  X1
                        let Yc =  fi.cosP * Y1 + fi.sinP * Z1
                        let Zc = -fi.sinP * Y1 + fi.cosP * Z1

                        guard Zc > 0.001 else { continue }

                        // Perspective projection → normalised UV [0,1]
                        let u =  fi.f * Xc / Zc + 0.5
                        let v = -fi.f * Yc / Zc + 0.5  // negative: up in world = top of frame

                        guard u >= 0, u < 1, v >= 0, v < 1 else { continue }

                        // Cosine blend weight — full at centre, 0 at every edge
                        let wu = cos((u - 0.5) * Double.pi)
                        let wv = cos((v - 0.5) * Double.pi)
                        let w  = Float(wu * wv)
                        guard w > 0.001 else { continue }

                        // Bilinear sample from source frame
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

        // Normalise + compose output bytes (dark background where no frame covers)
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
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    // MARK: - Helpers

    /// Decode a CGImage to packed RGBA8 with row 0 = image top-left.
    nonisolated private static func rawRGBA(_ image: CGImage) -> ([UInt8], Int, Int)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            // Flip so that buffer row 0 corresponds to the image's top row (v=0).
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            return true
        }
        return ok ? (bytes, w, h) : nil
    }

    nonisolated private static func bilerp(
        _ v00: Float, _ v10: Float,
        _ v01: Float, _ v11: Float,
        _ tx: Float,  _ ty: Float
    ) -> Float {
        (v00 + (v10 - v00) * tx) * (1 - ty) + (v01 + (v11 - v01) * tx) * ty
    }
}
