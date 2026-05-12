import XCTest
import CoreGraphics
@testable import GimbalController

final class TemporalGridTests: XCTestCase {

    /// Build a synthetic CGImage of the given size filled with a single grey value.
    private func makeFrame(_ shade: CGFloat, w: Int = 320, h: Int = 180) -> CGImage {
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        )!
        ctx.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func buffer(count: Int) -> [(image: CGImage, timestamp: Date)] {
        let now = Date()
        return (0..<count).map { i in
            (image: makeFrame(CGFloat(i) / CGFloat(max(count - 1, 1))),
             timestamp: now.addingTimeInterval(TimeInterval(i)))
        }
    }

    func test_4x4_grid_dimensions() {
        let grid = JournalAnalyzer.composeTemporalGrid(buffer: buffer(count: 16), cols: 4, rows: 4)
        XCTAssertNotNil(grid)
        // cellW = max(96, 448/4) = 112; cellH = 112 * 9 / 16 = 63
        XCTAssertEqual(grid?.width, 448)
        XCTAssertEqual(grid?.height, 252)
    }

    func test_2x2_grid_default_dimensions() {
        let grid = JournalAnalyzer.composeTemporalGrid(buffer: buffer(count: 4))
        XCTAssertNotNil(grid)
        // cellW = max(96, 448/2) = 224; cellH = 224 * 9 / 16 = 126
        XCTAssertEqual(grid?.width, 448)
        XCTAssertEqual(grid?.height, 252)
    }

    func test_3x3_grid_dimensions() {
        let grid = JournalAnalyzer.composeTemporalGrid(buffer: buffer(count: 9), cols: 3, rows: 3)
        XCTAssertNotNil(grid)
        // cellW = max(96, 448/3) = 149; cellH = 149 * 9 / 16 = 83
        XCTAssertEqual(grid?.width, 149 * 3)
        XCTAssertEqual(grid?.height, 83 * 3)
    }

    func test_partial_buffer_does_not_crash_4x4() {
        // Only 5 frames into a 16-cell grid — remaining 11 cells stay dark.
        let grid = JournalAnalyzer.composeTemporalGrid(buffer: buffer(count: 5), cols: 4, rows: 4)
        XCTAssertNotNil(grid)
        XCTAssertEqual(grid?.width, 448)
    }

    func test_overflow_buffer_truncates_to_capacity() {
        // 20 frames into a 4×4 grid — only first 16 should be drawn, no crash.
        let grid = JournalAnalyzer.composeTemporalGrid(buffer: buffer(count: 20), cols: 4, rows: 4)
        XCTAssertNotNil(grid)
    }

    func test_empty_buffer_returns_nil() {
        let grid = JournalAnalyzer.composeTemporalGrid(buffer: [], cols: 4, rows: 4)
        XCTAssertNil(grid)
    }

    func test_zero_cols_returns_nil() {
        let grid = JournalAnalyzer.composeTemporalGrid(buffer: buffer(count: 4), cols: 0, rows: 4)
        XCTAssertNil(grid)
    }

    /// Chronological ordering: index 0 must land in the top-left cell, last index in
    /// bottom-right. We verify by sampling pixel shade in each corner — frame 0 is
    /// shade 0.0 (black), frame 15 is shade 1.0 (white).
    func test_chronological_ordering_top_left_to_bottom_right() throws {
        let grid = try XCTUnwrap(
            JournalAnalyzer.composeTemporalGrid(buffer: buffer(count: 16), cols: 4, rows: 4)
        )

        // CGImage origin is bottom-left in CG-space. The composer flips so that
        // visually (when displayed top-down) index 0 is top-left.
        // 4×4 grid is 448×252; each cell is ~112×63. Sample well inside the
        // top-left cell (oldest, darkest) and the bottom-right cell (newest,
        // brightest).
        let topLeft     = sampleShade(grid, x: 30,  yFromTop: 20)
        let bottomRight = sampleShade(grid, x: 420, yFromTop: 230)

        XCTAssertLessThan(topLeft, 0.2,    "top-left should be the oldest (darkest) frame")
        XCTAssertGreaterThan(bottomRight, 0.8, "bottom-right should be the newest (brightest) frame")
    }

    /// Reads one pixel's red channel (0–1) at the given coordinate, where y is
    /// measured from the TOP of the image (intuitive screen coords).
    private func sampleShade(_ image: CGImage, x: Int, yFromTop: Int) -> CGFloat {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let ctx = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        )!
        ctx.draw(image,
                 in: CGRect(x: -x, y: -(image.height - yFromTop - 1),
                            width: image.width, height: image.height))
        return CGFloat(pixel[0]) / 255.0
    }
}
