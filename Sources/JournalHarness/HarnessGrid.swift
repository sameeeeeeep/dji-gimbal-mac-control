import Foundation
import CoreGraphics
import AppKit

// Verbatim copy of JournalAnalyzer.composeTemporalGrid from
// Sources/Camera/JournalAnalyzer.swift (~line 491). Kept here so the harness
// builds without depending on the GimbalController target. If the live
// composer changes, mirror the change here so harness output stays
// representative.

enum HarnessGrid {

    static func composeTemporalGrid(
        buffer: [(image: CGImage, timestamp: Date)],
        cols: Int = 4,
        rows: Int = 4
    ) -> CGImage? {
        guard !buffer.isEmpty, cols > 0, rows > 0 else { return nil }

        let cellW = max(96, 448 / cols)
        let cellH = cellW * 9 / 16
        let gridW = cellW * cols, gridH = cellH * rows
        let capacity = cols * rows

        guard let ctx = CGContext(
            data: nil,
            width: gridW, height: gridH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        ) else { return nil }

        ctx.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: gridW, height: gridH))
        ctx.interpolationQuality = .medium

        for (i, item) in buffer.enumerated() {
            guard i < capacity else { break }
            let row = i / cols
            let col = i % cols
            let x = col * cellW
            let y = (rows - 1 - row) * cellH
            let cellRect = CGRect(x: x, y: y, width: cellW, height: cellH)
            ctx.saveGState()
            ctx.clip(to: cellRect)
            ctx.draw(item.image, in: cellRect)
            ctx.restoreGState()
        }

        ctx.setStrokeColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.4))
        ctx.setLineWidth(1)
        for c in 1..<cols {
            let x = c * cellW
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: gridH))
        }
        for r in 1..<rows {
            let y = r * cellH
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: gridW, y: y))
        }
        ctx.strokePath()

        return ctx.makeImage()
    }

    /// Build the same VLM prompt the live app uses
    /// (Sources/Camera/JournalAnalyzer.swift buildVLMDescriptionPrompt).
    static func buildVLMDescriptionPrompt(frameCount: Int, spanSec: Int, cols: Int, rows: Int) -> String {
        let base = """
        You are the eye of a memory device. Report what is happening - not how it looks.

        Output ONE sentence, max 30 words, with these elements in order:
          1. PEOPLE: count + role if obvious (e.g. "a woman at a desk", "two people facing each other")
          2. ACTION: what their hands / posture / gaze are doing right now (specific verbs: typing, pointing, holding a mug, looking at a phone, leaning forward)
          3. OBJECTS: the 1-3 things they are interacting with or looking at (laptop, notebook, mug, phone, another person)
          4. PLACE: one short tag only if clearly identifiable (kitchen, desk, sidewalk, bedroom). Skip if generic.

        HARD RULES:
          - Do NOT describe lighting, wall color, mood, atmosphere, or aesthetic.
          - Do NOT use words like "serene", "cozy", "warm light", "pale", "soft", "minimal".
          - If the frame shows nothing meaningful happening, say exactly: "Nothing notable - empty room." and stop.
          - No advice, no coaching, no questions, no second person. Third-person factual only.

        Good: "A man at a desk types on a laptop while glancing at a phone beside the keyboard."
        Bad:  "A peaceful workspace with soft natural light and a sense of calm focus."
        """
        if frameCount >= 2 {
            return base + "\n\nThe image you are seeing is a \(cols)x\(rows) sprite sheet of \(frameCount) frames of the same scene in chronological order (top-left = oldest, bottom-right = newest, span ~ \(spanSec)s). Focus your description on the bottom-right cell - that is what is happening RIGHT NOW. If a hand/gaze/object position changed across the sheet, append a short clause (4-6 words) naming the change."
        }
        return base
    }

    /// Save a CGImage as JPEG to disk.
    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg,
                                            properties: [.compressionFactor: NSNumber(value: quality)])
        else { return false }
        do { try data.write(to: url); return true } catch { return false }
    }
}
