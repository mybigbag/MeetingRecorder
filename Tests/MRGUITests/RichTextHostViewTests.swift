import XCTest
import AppKit
@testable import MRGUI

/// 承载纪要富文本的宿主视图。
///
/// ## 这一组要钉住的是什么
///
/// 2026-10-22 报「纪要内容偏左、右边一片空白」。根因不是排版算错，
/// 而是 **量高度的函数顺手改了视图状态**：SwiftUI 会用好几个不同的
/// 提议宽度反复问同一个视图要多高（实测 `0 → ∞ → 702 → 582 → nil → 306 → 449`），
/// 上一版每次都把文本视图的 frame 改成那个提议宽度，于是**最后问的 449
/// 留在了界面上**，而卡片本身是 702 宽。
///
/// 所以这里断言的是**分离**：量高度只许算，不许动视图；
/// 排版只许在 `layout()` 里按真实宽度做。
final class RichTextHostViewTests: XCTestCase {

    private func makeLongText() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(
            string: Array(repeating: "这一行用来把文本撑过好几行，以便比较不同宽度下的高度差。",
                          count: 6).joined(separator: "\n"),
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .paragraphStyle: paragraph])
    }

    private func makeHost(width: CGFloat = 400) -> RichTextHostView {
        let host = RichTextHostView(attributed: makeLongText())
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        return host
    }

    /// 宽度越窄，行越多，高度越大——这条是下面几条判据的基准。
    func testNarrowerWidthNeedsMoreHeight() {
        let host = makeHost()
        let wide = host.height(forWidth: 600)
        let narrow = host.height(forWidth: 200)
        XCTAssertGreaterThan(narrow, wide,
                             "200 pt 宽应该比 600 pt 宽更高；相等说明量高度根本没按宽度算")
        XCTAssertGreaterThan(wide, 0)
    }

    /// **核心**：量高度不许改任何视图状态。
    ///
    /// 把 `height(forWidth:)` 改回「顺手 setFrameSize / containerSize」，
    /// 这条立刻红——那正是右侧留白的来源。
    func testMeasuringHeightDoesNotTouchTheView() {
        let host = makeHost(width: 500)
        host.layoutSubtreeIfNeeded()
        let hostFrameBefore = host.frame
        let textFrameBefore = host.textView.frame
        let containerSizeBefore = host.textView.textContainer?.containerSize

        // 故意用两个和真实宽度都不一样的宽度量一遍（就像 SwiftUI 干的那样）
        _ = host.height(forWidth: 123)
        _ = host.height(forWidth: 987)

        XCTAssertEqual(host.frame, hostFrameBefore, "量高度改了宿主尺寸")
        XCTAssertEqual(host.textView.frame, textFrameBefore, "量高度改了文本视图尺寸")
        XCTAssertEqual(host.textView.textContainer?.containerSize, containerSizeBefore,
                       "量高度改了文本容器尺寸")
    }

    /// 排版后文本视图的宽度必须等于宿主的真实宽度。
    func testLayoutFillsHostWidth() {
        let host = makeHost(width: 500)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.textView.frame.width, 500, accuracy: 0.5)

        // 宿主变窄（窗口被拖小）后，文本视图跟着变窄，行数变多、高度变大。
        let heightBefore = host.textView.frame.height
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.textView.frame.width, 260, accuracy: 0.5, "拖窄后没跟着变窄")
        XCTAssertGreaterThan(host.textView.frame.height, heightBefore, "变窄了高度却没变，说明没重排")
    }

    /// 内容换了之后高度缓存要作废，否则新内容会被裁掉或留一大块空白。
    func testContentChangeInvalidatesHeight() {
        let host = makeHost()
        let short = host.height(forWidth: 400)
        host.replaceContent(with: NSAttributedString(
            string: Array(repeating: "补一行", count: 40).joined(separator: "\n"),
            attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        let tall = host.height(forWidth: 400)
        XCTAssertGreaterThan(tall, short, "换内容之后高度没重算（缓存没作废）")
    }

    /// 同样的内容重复换，不该被当成「内容变了」——那会清掉用户正在拖的选区。
    func testSameContentDoesNotResetSelection() {
        let host = makeHost()
        host.layoutSubtreeIfNeeded()
        host.textView.setSelectedRange(NSRange(location: 2, length: 6))
        host.replaceContent(with: makeLongText())
        XCTAssertEqual(host.textView.selectedRange(), NSRange(location: 2, length: 6),
                       "内容没变却重置了选区——用户拖到一半的选区会被清掉")
    }
}
