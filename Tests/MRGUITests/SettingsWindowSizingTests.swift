import XCTest
import AppKit
import SwiftUI
import MRCore
@testable import MRGUI
import MRSession

/// 设置窗口的尺寸：**必须跟着内容走**。
///
/// 这一组守的是一次真实事故（2026-10-21）：窗口高度写死 660，而「云端模型 API」
/// 那一屏的真实内容是 746——窗口不滚，多出来的部分**不会报错、不会提示**，
/// 只是消失：标题「设置」与模型层第一组被顶出可视区。
/// 而所有既有断言、渲染探针、编译都是绿的。
///
/// 所以这里不去量视图的 `fittingSize`（那只能证明「视图想多高」），
/// 而是量**窗口自己的内容尺寸**——窗口写死高度时，这条一定会红。
@MainActor
final class SettingsWindowSizingTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var workspace: MeetingWorkspace!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-settings-sizing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "mr-settings-sizing-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        workspace = MeetingWorkspace(
            root: root, preferences: RecorderPreferences(defaults: defaults))
    }

    override func tearDown() async throws {
        SettingsWindowController.shared.closeForTesting()
        workspace = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    /// 本地档窗口必须**明显矮于**云端档：两者相差一整组字段（URL / 模型名 / 密钥）。
    ///
    /// 判据用「矮多少」而不是固定数值：文案改一行、间距调两格都会让绝对值变，
    /// 但「云端比本地高一整组字段」这条关系不该变。
    ///
    /// **2026-10-22 起必须先切到「会议纪要」页**：设置窗口分了三页，
    /// 而默认停在录音页——录音页的高度与 provider 无关，不切页就只会
    /// 量到「390 == 390」，看上去是「窗口没跟着内容长」，其实是没切页。
    func testWindowHeightFollowsTheProvider() throws {
        workspace.minutesProvider = .local
        let controller = SettingsWindowController.shared
        controller.show(workspace: workspace)

        let model = try XCTUnwrap(controller.modelForTesting, "设置窗口没建起来")
        model.tab = .minutes
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let local = try XCTUnwrap(controller.contentSizeForTesting,
                                  "设置窗口没建起来")
        XCTAssertEqual(local.width, SettingsLayout.width, accuracy: 0.5,
                       "窗口宽度必须与内容的宽度一致，否则会横向裁切：\(local)")

        workspace.minutesProvider = .cloudAPI
        // 控制器在 provider 变化后的下一个主队列周期里重新量高度，
        // 这里把那个周期跑完，否则量到的还是切换前的尺寸。
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let cloud = try XCTUnwrap(controller.contentSizeForTesting)
        XCTAssertGreaterThan(
            cloud.height, local.height + 150,
            "切到云端档后窗口没有长高——多出来的字段会被裁掉。本地 \(local.height)，云端 \(cloud.height)")
    }

    /// **切页也要让窗口跟着变高，而且上边缘不许跳。**
    ///
    /// 分页带来的新失效点：录音页 390、云端纪要页 617。窗口停在 390 的话，
    /// 下半页被静默裁掉——与当年「高度写死 660」是同一种错，触发器从
    /// 「切档位」换成了「切页」。
    ///
    /// ## 这条量的是**结果**，不是某一段代码
    ///
    /// 让窗口跟着内容走有两条路：`NSHostingView` 自己会改窗（本机实测有效），
    /// 以及 `SettingsWindowController` 里显式的 `fitWindowToContent()`。
    /// 注释掉后者、甚至把内容尺寸写死成 660，这条仍然绿——**这不是测试没牙**，
    /// 而是它守的本来就不是「某条订阅在不在」，而是「用户会不会被裁掉内容」。
    ///
    /// 真正有牙的前提是下一条：`contentView` 必须就是 hosting 本身。
    /// 一旦有人把它包进普通容器，自动改窗就没了，这两条立刻变成
    /// 「靠手工量」——那时它们才会真的红。
    func testWindowHeightFollowsTheTab() throws {
        workspace.minutesProvider = .cloudAPI
        let controller = SettingsWindowController.shared
        controller.show(workspace: workspace)

        let model = try XCTUnwrap(controller.modelForTesting, "设置窗口没建起来")
        model.tab = .recording
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let recording = try XCTUnwrap(controller.contentSizeForTesting)
        let recordingTop = try XCTUnwrap(controller.frameForTesting).maxY

        model.tab = .minutes
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let minutes = try XCTUnwrap(controller.contentSizeForTesting)
        let minutesTop = try XCTUnwrap(controller.frameForTesting).maxY

        XCTAssertGreaterThan(
            minutes.height, recording.height + 100,
            "切到会议纪要页后窗口没有长高，下半页会被裁掉。录音 \(recording.height)，纪要 \(minutes.height)")
        // 长高时**上边缘不动**：设置窗口是居中的，跟着左下角长高会让窗口
        // 每切一次页就往上蹿一截，用户会以为窗口在乱跑。
        XCTAssertEqual(
            minutesTop, recordingTop, accuracy: 0.5,
            "切页长高时上边缘动了：\(recordingTop) → \(minutesTop)")
    }

    /// **窗口的 `contentView` 必须就是 hosting 本身。**
    ///
    /// 这条是上两条的前提，也是唯一能被证伪的那一条：
    ///
    /// `NSHostingView` 当窗口的 `contentView` 时**自己**就会把窗口改成内容尺寸，
    /// 并且上边缘不动。本机实测：把 `fitWindowToContent` 换成写死 660、
    /// 或整条订阅删掉，窗口照样从 390 长到 617——也就是说，
    /// 上面那两条尺寸断言测量的是**这份隐式行为**。
    ///
    /// 一旦有人把 hosting 包进一个普通 `NSView` 容器（这是很自然的一步：
    /// 「加个背景」「加个边距」），隐式改窗立刻消失，窗口退回「只有手工量」。
    /// 那就是 2026-10-21 那次 bug 的形状：高度停在 660，标题被顶出可视区，
    /// 而所有断言、编译、渲染探针全绿。
    ///
    /// 所以这里不测「有没有调用某个函数」，只钉这个前提。真要换容器，
    /// 这条会红，提醒改的人自己去补尺寸逻辑（或干脆别换）。
    func testContentViewIsTheHostingViewItself() throws {
        let controller = SettingsWindowController.shared
        controller.show(workspace: workspace)
        let content = try XCTUnwrap(controller.contentViewForTesting)
        XCTAssertTrue(
            content is NSHostingView<MinutesSettingsView>,
            "设置窗口的 contentView 变成了 \(type(of: content))。"
                + "它不是 NSHostingView 时，「窗口按内容自适应」这份隐式行为就没了，"
                + "切页/切档位会裁掉下半页（2026-10-21 那次 bug 的形状）。")
    }

    /// 窗口高度必须**至少装得下内容**：即等于内容自然高度，而不是某个写死的数。
    ///
    /// 这条和上一条是不同的失效方式：上一条抓「切换时不长高」，
    /// 这条抓「从来没按内容量过」（比如一开始就写死一个碰巧够大的值，
    /// 将来内容再长一截就又裁掉）。
    func testWindowIsNeverShorterThanItsContent() throws {
        workspace.minutesProvider = .cloudAPI
        let controller = SettingsWindowController.shared
        controller.show(workspace: workspace)

        // 拿**最高的一页**来量：云端纪要页是内容最多的一屏，
        // 它装得下，其它页自然也装得下。
        let model = try XCTUnwrap(controller.modelForTesting, "设置窗口没建起来")
        model.tab = .minutes
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let size = try XCTUnwrap(controller.contentSizeForTesting)
        let comparison = MinutesSettingsModel(workspace: workspace)
        comparison.tab = .minutes
        let hosting = try XCTUnwrap(
            NSHostingView(rootView: MinutesSettingsView(model: comparison)))
        let ideal = try XCTUnwrap(SettingsLayout.contentSize(for: hosting))
        // **等于**，不是「不矮于」：只判「不矮于」的话，写死 660 恰好大于
        // 云端页那 655.5 也能蒙过去（本机实测过，它真的蒙过去了）。
        // 窗口高出一截同样是问题——底下会多出一条空白，用户以为内容没加载完。
        XCTAssertEqual(
            size.height, ideal.height, accuracy: 1,
            "窗口高 \(size.height)，内容高 \(ideal.height)——两者必须一致")
    }
}
