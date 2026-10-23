import XCTest
import SwiftUI
import CoreGraphics
@testable import MRGUI

/// 波形渲染出来的**横向位置**。
///
/// 这一层之前没有测过，而它恰恰是「波形图看着对、其实是错」的高发区：
/// 柱子的高低错了肉眼还能看出来，但**柱子画在哪个时间点上**错了，
/// 波形照样长得像波形——只是所有发言都平移了位置，没人会发现。
///
/// 所以这里不靠截图目测，直接把视图渲染成位图，按像素断言每个峰落在哪一列。
@MainActor
final class WaveformViewRenderTests: XCTestCase {

    private let renderWidth = 400
    private let renderHeight = 40

    /// 渲染视图，返回「该列含波形条（不含中轴）的像素数」。
    ///
    /// 中轴是 `primary@0.10`、波形条是 `primary@0.18` 起，
    /// 所以用 alpha 阈值把两者分开：中轴只有约 25，波形条至少 46。
    private func columnHeights(of view: some View) throws -> [Int] {
        let renderer = ImageRenderer(
            content: view.frame(width: CGFloat(renderWidth), height: CGFloat(renderHeight)))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "视图渲染失败")

        let width = image.width
        let height = image.height
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let pointer = try XCTUnwrap(context.data)
        let buffer = pointer.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var counts = [Int](repeating: 0, count: width)
        for x in 0..<width {
            for y in 0..<height {
                let offset = (y * width + x) * 4
                // 抗锯齿后的边缘 alpha 会衰减，取 32 作界限：
                // 中轴（0.10 → 25.5）被排除，波形条（0.18 → 45.9）被计入。
                if buffer[offset + 3] > 32 { counts[x] += 1 }
            }
        }
        return counts
    }

    /// 找出有内容的列区间。
    private func contentRanges(_ counts: [Int]) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        var start: Int?
        for (index, count) in counts.enumerated() {
            if count > 0, start == nil { start = index }
            if count == 0, let begin = start {
                ranges.append(begin...max(begin, index - 1))
                start = nil
            }
        }
        if let begin = start { ranges.append(begin...counts.count - 1) }
        return ranges
    }

    func testEmptyPeaksDrawNothingButTheAxis() throws {
        let counts = try columnHeights(
            of: WaveformView(peaks: [Float](repeating: 0, count: 100),
                             progress: nil, height: CGFloat(renderHeight)))

        XCTAssertTrue(contentRanges(counts).isEmpty,
                      "全零波形只该有一条中轴，不该有任何柱体。实际列高：\(counts.max() ?? 0)")
    }

    func testSinglePeakLandsAtItsTimePosition() throws {
        // 100 个桶，只有第 10 个有内容 → 横轴应当是 10/100 = 10% 处
        var peaks = [Float](repeating: 0, count: 100)
        peaks[10] = 1.0
        let counts = try columnHeights(
            of: WaveformView(peaks: peaks, progress: nil, height: CGFloat(renderHeight)))

        let ranges = contentRanges(counts)
        XCTAssertEqual(ranges.count, 1, "只该有一根柱子，实际 \(ranges.count) 根")

        let expected = Double(renderWidth) * 10.0 / 100.0    // 40
        let center = Double(ranges[0].lowerBound + ranges[0].upperBound) / 2
        XCTAssertEqual(center, expected, accuracy: 3,
                       "柱子画在 x=\(center)，应该是 x=\(expected)——横向位置错了，"
                       + "波形看着还是波形，但所有内容都整体平移了")
    }

    func testPeaksKeepRelativeOrderAndSpacing() throws {
        // 三个峰分别在 10% / 50% / 90%
        var peaks = [Float](repeating: 0, count: 100)
        for index in [10, 50, 90] { peaks[index] = 1.0 }
        let counts = try columnHeights(
            of: WaveformView(peaks: peaks, progress: nil, height: CGFloat(renderHeight)))

        let ranges = contentRanges(counts)
        XCTAssertEqual(ranges.count, 3, "三个峰应该画出三根柱子")

        let centers = ranges.map { Double($0.lowerBound + $0.upperBound) / 2 }
        let expected = [40.0, 200.0, 360.0]
        for (index, center) in centers.enumerated() {
            XCTAssertEqual(center, expected[index], accuracy: 3,
                           "第 \(index + 1) 根柱子位置偏了：实际 \(center)，应为 \(expected[index])")
        }
    }

    func testPlayedPortionIsDrawnDarkerThanTheRest() throws {
        // 桶 0-49 已播放、50-99 未播放，两段都要有柱体，但深浅不同。
        let peaks = [Float](repeating: 1.0, count: 100)
        let view = WaveformView(peaks: peaks, progress: 0.5, height: CGFloat(renderHeight))

        let renderer = ImageRenderer(
            content: view.frame(width: CGFloat(renderWidth), height: CGFloat(renderHeight)))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pointer = try XCTUnwrap(context.data)
        let buffer = pointer.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)

        func maxAlpha(inX range: Range<Int>) -> UInt8 {
            var peak: UInt8 = 0
            // 只看中间几行，避开上下边缘的抗锯齿
            for y in (image.height / 2 - 2)...(image.height / 2 + 2) {
                for x in range {
                    let alpha = buffer[(y * image.width + x) * 4 + 3]
                    if alpha > peak { peak = alpha }
                }
            }
            return peak
        }

        let played = maxAlpha(inX: 0..<100)
        let upcoming = maxAlpha(inX: 300..<400)
        XCTAssertGreaterThan(played, upcoming + 40,
                             "已播放部分必须明显更深（0.55 vs 0.18），"
                             + "实测 \(played) 与 \(upcoming)")
    }

    func testSeekFractionMapsEdgesAndCenter() {
        // 手势映射是「点哪儿跳哪儿」的全部依据，错一点就是全程错位。
        XCTAssertEqual(WaveformView.fraction(atX: 0, width: 400), 0)
        XCTAssertEqual(WaveformView.fraction(atX: 200, width: 400), 0.5)
        XCTAssertEqual(WaveformView.fraction(atX: 400, width: 400), 1)
    }

    func testSeekFractionClampsOutOfBounds() {
        XCTAssertEqual(WaveformView.fraction(atX: -20, width: 400), 0, "拖到左边外面要夹回 0")
        XCTAssertEqual(WaveformView.fraction(atX: 900, width: 400), 1, "拖到右边外面要夹回 1")
    }

    func testSeekFractionRejectsDegenerateWidth() {
        XCTAssertNil(WaveformView.fraction(atX: 10, width: 0), "宽度为 0 时算不出比例")
        XCTAssertNil(WaveformView.fraction(atX: 10, width: .nan))
    }
}
