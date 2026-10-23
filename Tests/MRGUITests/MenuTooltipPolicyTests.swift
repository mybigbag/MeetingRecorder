import XCTest
import AppKit
import MRCore
@testable import MRGUI
import MRSession

/// **菜单里不许有任何浮层（`toolTip`）。**
///
/// ## 为什么需要一条专门的守卫
///
/// 2026-10-22 之前，状态栏菜单里每一项设置都挂着一整段说明：
/// 「录音设置」入口六七行、「存储与清理」入口六七行、每条策略一条……
/// 反馈是「**特别是鼠标 hover 时的说明文案问题更严重，还会遮挡设置项**」。
///
/// 这不是审美问题：macOS 的菜单浮层就贴在光标右下、压在菜单上，
/// 用户想点的下一条被自己刚触发的说明挡住，还得先移开鼠标。
///
/// 改法是把信息搬到两个**不需要悬停**的地方：
/// - 标题：分组入口写成「录音设置：24 kHz 单声道 · 32 位浮点 · 苹果原生」；
/// - 设置窗口 / 顶栏面板：每项常驻一行说明，长的收进「说明」就地展开。
///
/// ## 为什么必须有一条测试
///
/// 浮层**不在任何截图里**（静态图拍不到 hover），也不是编译错误，
/// 更不会让任何行为断言变红。没有这条，下一个人加一句 `item.toolTip = …`
/// 是完全无声的回归。
@MainActor
final class MenuTooltipPolicyTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var workspace: MeetingWorkspace!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-menu-tip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "mr-menu-tip-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        workspace = MeetingWorkspace(
            root: root, preferences: RecorderPreferences(defaults: defaults))
    }

    override func tearDown() async throws {
        workspace = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    /// 建一棵菜单树并递归检查。**覆盖四种状态组合**：
    /// 默认态、全开态、云端缺项（那一条会多出一个「打开设置补全配置…」）、
    /// 图标隐藏。少一种就少一条逃逸路径。
    func testNoMenuItemCarriesATooltipInAnyState() {
        let controller = StatusItemController(
            workspace: workspace, hotKeyFailures: [], onShowWindow: {})

        var states: [(String, () -> Void)] = [
            ("默认态", {}),
        ]
        states.append(("全开态", {
            self.workspace.pcm16Recording = true
            self.workspace.mono24kRecording = true
            self.workspace.hidesStatusBarCountdown = true
            self.workspace.autoPruneEnabled = true
            self.workspace.retentionPolicy = .days(7)
        }))
        states.append(("云端缺项", {
            self.workspace.minutesProvider = .cloudAPI
            self.workspace.minutesAPIKey = ""
            self.workspace.minutesAPIBaseURL = ""
            self.workspace.minutesModelName = ""
        }))
        states.append(("云端配齐 + 图标隐藏", {
            self.workspace.minutesAPIBaseURL = "https://api.deepseek.com/v1"
            self.workspace.minutesModelName = "deepseek-chat"
            self.workspace.minutesAPIKey = "sk-test"
            self.workspace.showsStatusBarIcon = false
        }))

        for (name, mutate) in states {
            mutate()
            let menu = NSMenu()
            controller.menuNeedsUpdate(menu)
            let offenders = mrCollectTooltips(in: menu)
            XCTAssertTrue(
                offenders.isEmpty,
                "\(name)的菜单里有浮层，悬停时会盖住下面的条目：\(offenders)")
        }
    }

    /// 信息没有因为「删浮层」而丢：四个分组入口都**把当前取值写进标题**。
    ///
    /// 这是删掉浮层之后唯一还看得见「现在是什么」的地方——
    /// 少了它，用户点开菜单只会看到「录音设置」四个字，得再进去翻一遍才知道当前规格。
    func testGroupEntriesCarryTheirCurrentStateInTheTitle() throws {
        let controller = StatusItemController(
            workspace: workspace, hotKeyFailures: [], onShowWindow: {})
        workspace.pcm16Recording = true
        workspace.mono24kRecording = false
        workspace.hidesStatusBarCountdown = true
        workspace.showsStatusBarIcon = false
        workspace.retentionPolicy = .days(30)

        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        let expected: [(String, String)] = [
            (StatusItemController.recordingSettingsMenuTitle, "16 位"),
            (StatusItemController.storageMenuTitle, "30 天"),
            (StatusItemController.privacyMenuTitle, StatusItemController.privacyStateText(workspace)),
            (StatusItemController.menuBarMenuTitle, "已隐藏"),
        ]
        for (prefix, fragment) in expected {
            let entry = try XCTUnwrap(
                mrFindMenuItem(in: menu, titleHasPrefix: "\(prefix)："),
                "「\(prefix)」入口必须把当前状态写进标题。实际菜单：\(mrFlattenMenuTitles(menu))")
            XCTAssertTrue(
                entry.title.contains(fragment),
                "「\(prefix)」的标题里看不到「\(fragment)」：\(entry.title)")
            XCTAssertNotNil(entry.submenu, "入口必须还点得开")
        }
    }
}

/// 递归收集菜单树里所有非空 `toolTip`，连同它所在的条目标题一起返回。
///
/// 只返回 `[String]` 而不是 `Bool`：失败时要能一眼看出是**哪一条**挂了，
/// 「有浮层」这句话本身没有定位价值。
func mrCollectTooltips(in menu: NSMenu, depth: Int = 8) -> [String] {
    var out: [String] = []
    func walk(_ m: NSMenu, _ d: Int) {
        for item in m.items {
            if let tip = item.toolTip, !tip.isEmpty {
                out.append("「\(item.title)」→ \(tip.prefix(24))…")
            }
            if d > 0, let sub = item.submenu { walk(sub, d - 1) }
        }
    }
    walk(menu, depth)
    return out
}
