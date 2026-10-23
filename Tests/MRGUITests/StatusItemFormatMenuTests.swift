import XCTest
import AppKit
import MRCore
@testable import MRGUI
import MRSession

/// 状态栏菜单里的两个「录音格式」开关：16 位录音、单声道 24 kHz。
///
/// 为什么单独钉：每个开关都有**两个入口**——录音栏的复选框和状态栏菜单的勾选项。
/// 复选框那条由 `MeetingWorkspaceTests` 覆盖（本质就是给 `workspace.pcm16Recording`
/// 赋值），但「菜单项有没有接对动作」「勾选状态跟不跟偏好走」只有在这里验得了。
/// 这两件事坏掉时屏幕上都看不出异常：勾没变化，或者点了不生效——
/// 而用户会以为「已经开了」，直到磁盘占用纹丝不动。
///
/// 实测：把 `format.state = workspace.pcm16Recording ? .on : .off` 改成恒 `.off`，
/// 整个 GUI 测试套件仍然全绿。这一组就是补上来的。单声道那一项同理。
///
/// 与「静默录制」那一组（`StatusItemConcealTests`）同构：菜单每次弹出前重建，
/// 所以勾选状态必须在 `menuNeedsUpdate` 里现读 `workspace`，而不是建菜单时抄一份。
@MainActor
final class StatusItemFormatMenuTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var workspace: MeetingWorkspace!
    private var controller: StatusItemController!

    override func setUp() async throws {
        _ = NSApplication.shared

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-format-menu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 偏好跑在自己的 suite 里，绝不碰 `.standard`：那是测试进程的偏好域，
        // 写进去会跨用例残留，于是「默认是关的」这种断言第二次跑就不成立。
        suiteName = "mr-format-menu-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        // 这一组不驱动录音，所以不需要假引擎：默认工厂在 `startRecording` 之前不会被调用。
        workspace = MeetingWorkspace(
            root: root, preferences: RecorderPreferences(defaults: defaults))
        controller = StatusItemController(
            workspace: workspace, hotKeyFailures: [], onShowWindow: {})
    }

    override func tearDown() async throws {
        controller = nil
        workspace = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    func testMenuCarriesTheFormatToggleAndShowsItsCurrentState() {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        let item = mrFindMenuItem(in: menu, title: StatusItemController.formatMenuTitle)
        XCTAssertNotNil(item, "状态栏菜单里必须有这个开关，实际只有：\(mrFlattenMenuTitles(menu))")
        XCTAssertEqual(item?.state, .off, "默认不勾——默认是 32 位浮点无损录制")

        workspace.pcm16Recording = true
        let reopened = NSMenu()
        controller.menuNeedsUpdate(reopened)
        XCTAssertEqual(
            mrFindMenuItem(in: reopened, title: StatusItemController.formatMenuTitle)?.state,
            .on,
            "打开之后菜单上必须勾上——不然用户没有任何地方能知道它开着")
    }

    /// 走真实的 target/action，不是直接把属性设成 true。
    /// 后者证明不了菜单项接对了——而「菜单点了没反应」正是这里唯一会坏的形态。
    func testClickingTheFormatMenuToggleFlipsTheSetting() throws {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(
            mrFindMenuItem(in: menu, title: StatusItemController.formatMenuTitle))
        let action = try XCTUnwrap(item.action, "菜单项没有接动作")
        XCTAssertNotNil(item.target, "菜单项没有 target，点了不会有反应")

        _ = NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertTrue(workspace.pcm16Recording, "点一下应当打开 16 位")

        _ = NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertFalse(workspace.pcm16Recording, "再点一下应当关掉")
    }

    // MARK: - 单声道 24 kHz

    /// 菜单里必须有这一项，且勾选状态跟着偏好走。
    func testMenuCarriesTheMono24kToggleAndShowsItsCurrentState() {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        let item = mrFindMenuItem(in: menu, title: StatusItemController.mono24kMenuTitle)
        XCTAssertNotNil(item, "状态栏菜单里必须有这个开关，实际只有：\(mrFlattenMenuTitles(menu))")
        XCTAssertEqual(item?.state, .off, "默认不勾——默认保留源采样率与声道数")

        workspace.mono24kRecording = true
        let reopened = NSMenu()
        controller.menuNeedsUpdate(reopened)
        XCTAssertEqual(
            mrFindMenuItem(in: reopened, title: StatusItemController.mono24kMenuTitle)?.state,
            .on,
            "打开之后菜单上必须勾上——不然用户没有任何地方能知道它开着")
    }

    /// 走真实的 target/action，不是直接把属性设成 true。
    /// 后者证明不了菜单项接对了——而「菜单点了没反应」正是这里唯一会坏的形态。
    func testClickingTheMono24kToggleFlipsTheSetting() throws {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(
            mrFindMenuItem(in: menu, title: StatusItemController.mono24kMenuTitle))
        let action = try XCTUnwrap(item.action, "菜单项没有接动作")
        XCTAssertNotNil(item.target, "菜单项没有 target，点了不会有反应")

        _ = NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertTrue(workspace.mono24kRecording, "点一下应当打开单声道 24 kHz")

        // 关键：它不能顺手把位深那一项也改了——两个开关是独立的两个维度
        XCTAssertFalse(workspace.pcm16Recording, "点带宽开关不该把 16 位也打开")

        _ = NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertFalse(workspace.mono24kRecording, "再点一下应当关掉")
    }

    /// 两项**同时**在菜单里，且各自的标题与动作互不串。
    ///
    /// 这条挡的是「新加的项复用了旧项的 action」——那种实现下两个菜单项
    /// 点哪个都只改同一个偏好，而单项测试（上面两条）各自都还是绿的。
    func testTheTwoFormatItemsAreIndependent() throws {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        let pcm = try XCTUnwrap(mrFindMenuItem(in: menu, title: StatusItemController.formatMenuTitle))
        let mono = try XCTUnwrap(mrFindMenuItem(in: menu, title: StatusItemController.mono24kMenuTitle))
        XCTAssertNotEqual(pcm.title, mono.title, "两项标题必须不同")
        XCTAssertNotEqual(pcm.action, mono.action, "两项必须各接各的动作")

        _ = NSApp.sendAction(try XCTUnwrap(pcm.action), to: pcm.target, from: pcm)
        XCTAssertTrue(workspace.pcm16Recording)
        XCTAssertFalse(workspace.mono24kRecording, "点 16 位不该动到带宽开关")

        _ = NSApp.sendAction(try XCTUnwrap(mono.action), to: mono.target, from: mono)
        XCTAssertTrue(workspace.pcm16Recording, "点带宽开关不该动到位深")
        XCTAssertTrue(workspace.mono24kRecording)
    }
}

// MARK: - 降混策略子菜单

/// 「降混策略」子菜单（#28）。
///
/// 单独一组的原因与上面两个开关不同：它是**子菜单 + 单选**，不是勾选项。
/// 坏掉时的症状也独有——子菜单建不出来、或者勾选状态永远停在第一项，
/// 屏幕上看不出任何异常，而用户以为策略已经切了。
@MainActor
extension StatusItemFormatMenuTests {

    private func downmixEntry(in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(
            mrFindMenuItem(in: menu, titleHasPrefix: StatusItemController.downmixMenuTitle),
            "状态栏菜单里必须有降混策略子菜单，实际只有：\(mrFlattenMenuTitles(menu))")
    }

    /// 入口必须**常驻**，标题里带当前策略。
    func testDownmixSubmenuIsPresentAndShowsTheCurrentStrategy() throws {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let entry = try downmixEntry(in: menu)

        XCTAssertNotNil(entry.submenu, "这一项必须带子菜单")
        XCTAssertTrue(entry.title.contains(MonoDownmixStrategy.firstChannel.displayName),
                      "标题应显示当前策略（默认 firstChannel）：\(entry.title)")
    }

    /// 子菜单里两种策略都在，且**恰好当前那个被打勾**。
    func testDownmixSubmenuListsBothStrategiesAndTicksTheCurrentOne() throws {
        for strategy in MonoDownmixStrategy.allCases {
            workspace.downmixStrategy = strategy
            let menu = NSMenu()
            controller.menuNeedsUpdate(menu)
            let sub = try XCTUnwrap(try downmixEntry(in: menu).submenu)

            XCTAssertEqual(sub.items.count, MonoDownmixStrategy.allCases.count,
                           "两种策略都必须列出来")
            for s in MonoDownmixStrategy.allCases {
                let item = try XCTUnwrap(
                    sub.items.first { $0.title == s.displayName },
                    "子菜单里必须有「\(s.displayName)」")
                XCTAssertEqual(item.state, s == strategy ? .on : .off,
                               "「\(s.displayName)」的勾选状态不对（当前 \(strategy)）")
            }
        }
    }

    /// 每一项都必须带 `representedObject`，否则点了之后无从知道选了哪个。
    ///
    /// 退化示例：把 `item.representedObject = strategy.rawValue` 删掉，
    /// 菜单仍建得出来、勾选也正确，但点击静默无效——屏幕上看不出任何异常。
    func testEveryStrategyItemCarriesItsRawValue() throws {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let sub = try XCTUnwrap(try downmixEntry(in: menu).submenu)
        for s in MonoDownmixStrategy.allCases {
            let item = try XCTUnwrap(sub.items.first { $0.title == s.displayName })
            XCTAssertEqual(item.representedObject as? String, s.rawValue,
                           "「\(s.displayName)」没带 rawValue，点击后会静默无效")
        }
    }

    /// 真的能点：点「各声道平均」之后偏好与 workspace 都变了。
    func testClickingAStrategyActuallyChangesThePreference() throws {
        XCTAssertEqual(workspace.downmixStrategy, .firstChannel)
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let sub = try XCTUnwrap(try downmixEntry(in: menu).submenu)
        let average = try XCTUnwrap(
            sub.items.first { $0.title == MonoDownmixStrategy.average.displayName })

        _ = NSApp.sendAction(try XCTUnwrap(average.action), to: average.target, from: average)

        XCTAssertEqual(workspace.downmixStrategy, .average, "点了必须真的改")
        XCTAssertEqual(
            RecorderPreferences(defaults: defaults).downmixStrategy, .average,
            "必须落盘，否则下一场录制还用旧策略")
    }

    /// **入口不跟着 mono24k 一起灰掉。**
    ///
    /// 灰掉看着更「合理」（源是单声道时它确实不生效），但用户的路径恰恰是
    /// 「先开 mono24k → 录完发现声音不对 → 回头找这个开关」。
    /// 入口跟着一起灰掉就等于把排查路径堵在门外。
    func testDownmixEntryStaysEnabledEvenWithoutMono24k() throws {
        XCTAssertFalse(workspace.mono24kRecording)
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let entry = try downmixEntry(in: menu)
        XCTAssertTrue(entry.isEnabled, "没开 mono24k 时这一项也必须可点")
        XCTAssertNotNil(entry.submenu, "子菜单仍要建得出来")
    }

    /// **两项策略的取舍没有丢，只是搬了家。**
    ///
    /// 2026-10-22 之前这段说明挂在菜单项的 `toolTip` 上，一悬停就弹出一块多行浮层，
    /// 正好盖住下面几条——原话是「hover 说明还会遮挡设置项」。
    /// 现在菜单里没有浮层，取舍写在设置窗口那一行的「说明」里（唯一出处 `SettingsCopy`）。
    ///
    /// 两条一起钉：**浮层不在了**（`testMenuItemsCarryNoTooltips`），
    /// **文案还在**（这一条）——只钉前者会让人以为「删掉浮层 = 删掉信息」。
    func testDownmixTradeoffsStillExplainedInTheSettingsWindow() {
        let details = SettingsCopy.downmixDetails(
            .firstChannel, allCases: MonoDownmixStrategy.allCases)
        for strategy in MonoDownmixStrategy.allCases {
            XCTAssertTrue(details.contains(strategy.displayName),
                          "「\(strategy.displayName)」必须出现在说明里")
            XCTAssertTrue(details.contains(strategy.menuHelp),
                          "「\(strategy.displayName)」的取舍必须原样保留：\(details)")
        }
        // 「什么时候才生效」这条最容易漏：源本来是单声道时它完全不参与。
        XCTAssertTrue(details.contains("单声道 24 kHz"),
                      "说明要指出它依赖哪个开关：\(details)")
    }
}
