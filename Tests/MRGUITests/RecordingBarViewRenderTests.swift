import XCTest
import SwiftUI
@testable import MRGUI
import MRSession
import MRCore

/// 全局转写引擎选择器的渲染冒烟。
///
/// SwiftUI 控件出问题最常见的方式**不是**编译失败，而是**渲染出一个空控件**——
/// 断言不到、截图才发现。所以这里把选择器真的渲染成位图，保证它在两种引擎取值下
/// 都画得出来（不为空、不崩）。
///
/// 只做冒烟、不做像素判据：这里要防的是「控件整个没了」这类粗粒度回归。
/// 真正管引擎选择的是 `MeetingWorkspaceTests` 里那几条功能用例。
///
/// 刻意只渲染 `TranscriptionEnginePicker` 本身，而不是整条顶栏：顶栏里的标题输入框
/// 在被 `ImageRenderer` 离屏渲染时会触发「Accessing FocusState's value outside of
/// the body of a View」警告，那是输入框的产物，与本控件无关，不混进来。
@MainActor
final class RecordingBarViewRenderTests: XCTestCase {

    private func render(_ engine: Binding<TranscriptionEngine>) throws -> CGImage {
        let view = TranscriptionEnginePicker(engine: engine)
            .padding(8)
            .frame(width: 220, height: 40)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage, "选择器渲染失败（可能整个控件都没画出来）")
    }

    func testPickerRendersForEachEngine() throws {
        for engine in TranscriptionEngine.allCases {
            let image = try render(.constant(engine))
            XCTAssertGreaterThan(image.width, 0, "引擎 \(engine.rawValue) 下渲染宽度为 0")
            XCTAssertGreaterThan(image.height, 0, "引擎 \(engine.rawValue) 下渲染高度为 0")
        }
    }
}
