import XCTest
import AppKit
import MRCore
@testable import MRGUI
import MRSession

/// 设置项**归类**后的结构断言（2026-10-14）。
///
/// ## 这一组要挡住什么
///
/// 归类是一次产品决定，而**决定会被下一次「顺手加一项」推翻**：
/// 新增一个设置时，直接 `menu.addItem(...)` 追加到顶层是最省事的写法，
/// 而屏幕上不会出任何异常——菜单照常弹出、项照常能点，只是又平铺回去了。
///
/// 所以这里钉的不是「有几项」，而是**三条结构性不变量**：
///
/// 1. 高频命令（开始/暂停/停止/显示窗口/退出）留在**顶层**，
///    因为它们要随时够得着，收进子菜单等于多加一次点击；
/// 2. 设置项**不留在顶层**——它们改一次长期生效，平铺会让人误以为
///    每场录制前都要过一遍；
/// 3. 折叠入口**必须带当前取值摘要**——折叠不等于丢信息，
///    用户不点开也应该知道现在是什么。
///
/// 以及一条**边界纪律**：会删数据的「存储与清理」必须独立成组，
/// 不能与日常开关混在一起（混了，那个不可逆的授权就被稀释掉了）。
@MainActor
final class SettingsGroupingTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var workspace: MeetingWorkspace!
    private var controller: StatusItemController!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-grouping-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "mr-grouping-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
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

    private func topLevelMenu() -> NSMenu {
        let m = NSMenu()
        controller.menuNeedsUpdate(m)
        return m
    }

    // MARK: - 不变量 1：高频命令留在顶层

    /// 五个高频命令必须**直接**在顶层，不能被埋进任何子菜单。
    ///
    /// 退化示例：把「开始录制」收进「录音」子菜单，菜单照常能用，
    /// 而点开状态栏图标后要多一次悬停才能开始录音——
    /// 这是「会议正在别的应用里开」时最常走的路径。
    func testFrequentCommandsStayAtTheTopLevel() throws {
        let menu = topLevelMenu()
        let topTitles = Set(menu.items.map(\.title))

        for title in ["开始录制", "暂停录制", "停止录制", "显示主窗口", "退出会议录音器"] {
            XCTAssertTrue(topTitles.contains(title),
                          "「\(title)」必须在顶层，实际顶层只有：\(topTitles.sorted())")
            XCTAssertNil(menu.items.first { $0.title == title }?.submenu,
                         "「\(title)」不该带子菜单——它是一个动作，不是一组")
        }
    }

    // MARK: - 不变量 2：设置项不留在顶层

    /// 七个设置项**一个都不许留在顶层**。
    ///
    /// 这是整套归类的核心断言：平铺的代价不是「不好看」，而是让设置
    /// 看上去与「开始录制」同等重要、同等高频。
    ///
    /// 「菜单栏图标」这一项是**这条纪律的考试题**：它太像一句普通的话了，
    /// 顺手 `menu.addItem` 平铺出去最省事——而屏幕上没有任何异常。
    func testNoSettingItemIsLeftFlatAtTheTopLevel() {
        let menu = topLevelMenu()
        let settingsTitles = [
            StatusItemController.formatMenuTitle,
            StatusItemController.mono24kMenuTitle,
            StatusItemController.concealMenuTitle,
            StatusItemController.statusIconMenuTitle,
            StatusItemController.downmixMenuTitle,
            StatusItemController.retentionMenuTitle,
            StatusItemController.pruneMenuTitle,
            StatusItemController.autoPruneMenuTitle,
        ]
        for title in settingsTitles {
            XCTAssertNil(
                menu.items.first { $0.title == title }
                    ?? menu.items.first { $0.title.hasPrefix(title) },
                "「\(title)」不该留在顶层——它应该收进分组子菜单。"
                    + "实际顶层：\(menu.items.map(\.title))")
        }
    }

    /// 但**收进子菜单不等于消失**：每一项都还要找得到。
    ///
    /// 这一条与上面那条成对：上面挡「平铺」，这条挡「顺手收进子菜单时手滑删了」。
    /// 两者一起，「分组」才不是「隐藏」。
    func testEverySettingItemIsStillReachableSomewhere() throws {
        let menu = topLevelMenu()
        for title in [
            StatusItemController.formatMenuTitle,
            StatusItemController.mono24kMenuTitle,
            StatusItemController.concealMenuTitle,
            StatusItemController.statusIconMenuTitle,
            StatusItemController.pruneMenuTitle,
            StatusItemController.autoPruneMenuTitle,
        ] {
            XCTAssertNotNil(mrFindMenuItem(in: menu, title: title),
                            "「\(title)」既不在顶层、也找不到——不能只是被藏起来。"
                                + "实际菜单树：\(mrFlattenMenuTitles(menu))")
        }
    }

    /// 四个分组子菜单都要建得出来，且标题就是那四个名字。
    ///
    /// 「菜单栏」这一组只有一项，与「隐私」同一条理由：入口必须留着。
    /// 它的处境更特殊——关掉图标之后**这份菜单本身就没了**，
    /// 所以恢复路径靠另外两个入口（设置窗口、顶栏面板），这一点
    /// 写进了每一项的说明文案里（`statusIconHelp` 有断言钉着）。
    func testTheGroupsArePresentAsSubmenus() throws {
        let menu = topLevelMenu()
        for title in [
            StatusItemController.recordingSettingsMenuTitle,
            StatusItemController.storageMenuTitle,
            StatusItemController.privacyMenuTitle,
            StatusItemController.menuBarMenuTitle,
        ] {
            let entry = try XCTUnwrap(
                mrFindMenuItem(in: menu, titleHasPrefix: title),
                "缺少分组「\(title)」，实际菜单树：\(mrFlattenMenuTitles(menu))")
            XCTAssertNotNil(entry.submenu, "「\(title)」必须带子菜单")
            XCTAssertFalse(entry.submenu?.items.isEmpty ?? true,
                           "「\(title)」的子菜单不能是空的")
        }
    }

    // MARK: - 不变量 3：折叠入口带当前取值

    /// 「录音设置」入口标题里必须带**当前取值**。
    ///
    /// 折叠的代价是「不点开就看不到里面」，所以入口标题就是补偿——
    /// 用户扫一眼菜单栏就该知道现在录出来是什么规格。
    /// 少了这一截，「折叠」就退化成了「把信息藏起来」。
    func testRecordingSettingsEntryShowsTheCurrentSpec() throws {
        XCTAssertEqual(workspace.pcm16Recording, false)
        XCTAssertEqual(workspace.mono24kRecording, false)

        let entry = try XCTUnwrap(
            mrFindMenuItem(in: topLevelMenu(),
                           titleHasPrefix: StatusItemController.recordingSettingsMenuTitle))
        XCTAssertEqual(
            entry.title,
            "\(StatusItemController.recordingSettingsMenuTitle)：源采样率 · 32 位浮点 · 苹果原生",
            "默认（无损、源采样率、苹果引擎）的入口标题不对")

        // 改偏好，标题必须跟着变——这一条挡的是「标题在构造时被抄了一份」，
        // 而菜单是每次弹出前重建的，所以它本该自动跟上。
        workspace.pcm16Recording = true
        workspace.mono24kRecording = true
        workspace.transcriptionEngine = .senseVoice
        let changedEntry = try XCTUnwrap(
            mrFindMenuItem(in: topLevelMenu(),
                           titleHasPrefix: StatusItemController.recordingSettingsMenuTitle))
        XCTAssertEqual(
            changedEntry.title,
            "\(StatusItemController.recordingSettingsMenuTitle)：24 kHz 单声道 · 16 位 · SenseVoice",
            "偏好改了之后入口标题必须跟着变")
    }

    /// 「存储与清理」入口同样带当前档位。
    func testStorageEntryShowsTheCurrentRetentionTier() throws {
        let menu = topLevelMenu()
        let entry = try XCTUnwrap(
            mrFindMenuItem(in: menu, titleHasPrefix: StatusItemController.storageMenuTitle))
        XCTAssertTrue(
            entry.title.contains(workspace.retentionPolicy.displayName),
            "入口标题应显示当前档位（默认「关闭（永久保留）」）：\(entry.title)")
    }

    // MARK: - 边界纪律：会删数据的独立成组

    /// 「存储与清理」必须**独立成组**，不能混进「录音设置」。
    ///
    /// 这一条不是洁癖：档案位、立即清理、每天自动清理这三项的期望是
    /// 「以后按这个规则办」与「帮我清一批」，与「16 位录音」这种日常开关
    /// 根本不同类。混在一组里，用户点「每天自动清理」前不会意识到
    /// 自己正在授权一件不可逆的事。
    func testStorageIsItsOwnGroupNotMixedIntoRecordingSettings() throws {
        let menu = topLevelMenu()
        let recording = try XCTUnwrap(
            mrFindMenuItem(in: menu,
                           titleHasPrefix: StatusItemController.recordingSettingsMenuTitle))
        let recordingTitles = (recording.submenu?.items.map(\.title)) ?? []
        for dangerous in [StatusItemController.pruneMenuTitle,
                          StatusItemController.autoPruneMenuTitle] {
            XCTAssertFalse(recordingTitles.contains(dangerous),
                           "「\(dangerous)」会删数据，不该在「录音设置」组里")
        }
        // 保留策略同样属于存储组——它决定的是「什么时候有人来删」。
        XCTAssertFalse(
            recordingTitles.contains { $0.hasPrefix(StatusItemController.retentionMenuTitle) },
            "保留策略属于「存储与清理」，不该在「录音设置」组里")

        let storage = try XCTUnwrap(
            mrFindMenuItem(in: menu, titleHasPrefix: StatusItemController.storageMenuTitle))
        let storageTitles = (storage.submenu?.items.map(\.title)) ?? []
        XCTAssertTrue(
            storageTitles.contains { $0.hasPrefix(StatusItemController.retentionMenuTitle) },
            "保留策略必须在「存储与清理」组里，实际：\(storageTitles)")
    }

    /// 组内顺序：档位 → 立即清理 → 自动清理，**先规则、后执行**。
    ///
    /// 用户照着从上往下点，天然是「先决定按什么规则，再决定要不要现在执行」。
    func testStorageGroupPutsTheRuleBeforeTheExecution() throws {
        let menu = topLevelMenu()
        let storage = try XCTUnwrap(
            mrFindMenuItem(in: menu, titleHasPrefix: StatusItemController.storageMenuTitle))
        let titles = (storage.submenu?.items.map(\.title)) ?? []

        let ruleIndex = titles.firstIndex {
            $0.hasPrefix(StatusItemController.retentionMenuTitle)
        }
        let pruneIndex = titles.firstIndex { $0 == StatusItemController.pruneMenuTitle }
        XCTAssertNotNil(ruleIndex, "组内必须有保留策略，实际：\(titles)")
        XCTAssertNotNil(pruneIndex, "组内必须有立即清理，实际：\(titles)")
        XCTAssertLessThan(ruleIndex!, pruneIndex!,
                          "档位（规则）必须在立即清理（执行）之前")
    }

    /// 「自动清理开着、档位却没设」时给出提示。
    ///
    /// 那是唯一一种「开了等于没开」的状态，而且是**静默**的：
    /// 没有这一行，用户会以为每天在清，实际一件都没删。
    func testEnablingAutoPruneWithNoTierShowsAWarning() throws {
        workspace.autoPruneEnabled = true
        workspace.retentionPolicy = .off
        let menu = topLevelMenu()
        let storage = try XCTUnwrap(
            mrFindMenuItem(in: menu, titleHasPrefix: StatusItemController.storageMenuTitle))
        let titles = (storage.submenu?.items.map(\.title)) ?? []
        XCTAssertTrue(
            titles.contains { $0.contains("不会执行") || $0.contains("先") },
            "自动清理开着但档位没设时必须提示，实际：\(titles)")
    }

    /// 两个都是关闭时**不提示**——那是默认状态，提示就是纯噪音。
    func testNoWarningWhenBothAutoPruneAndTierAreOff() throws {
        XCTAssertFalse(workspace.autoPruneEnabled)
        let menu = topLevelMenu()
        let storage = try XCTUnwrap(
            mrFindMenuItem(in: menu, titleHasPrefix: StatusItemController.storageMenuTitle))
        let titles = (storage.submenu?.items.map(\.title)) ?? []
        XCTAssertFalse(
            titles.contains { $0.contains("不会执行") },
            "默认状态（自动清理关）不该出现警告行，实际：\(titles)")
    }

    // MARK: - 引擎：菜单栏这条路径原本是断的

    /// 引擎切换此前**只有主窗口顶栏一个入口**，而顶栏那三个开关只在 idle 时显示
    /// ——也就是说菜单栏这条路完全不通。归类顺手补上，这里钉住。
    func testEngineIsSelectableFromTheMenuBar() throws {
        XCTAssertEqual(workspace.transcriptionEngine, .apple)
        let menu = topLevelMenu()
        let recording = try XCTUnwrap(
            mrFindMenuItem(in: menu,
                           titleHasPrefix: StatusItemController.recordingSettingsMenuTitle))
        let sub = try XCTUnwrap(recording.submenu)

        let engineEntry = try XCTUnwrap(
            sub.items.first { $0.title.hasPrefix(StatusItemController.engineMenuTitle) },
            "「录音设置」组里必须有引擎子菜单，实际：\(sub.items.map(\.title))")
        let engineSub = try XCTUnwrap(engineEntry.submenu)

        for candidate in TranscriptionEngine.allCases {
            let item = try XCTUnwrap(
                engineSub.items.first { $0.title == candidate.displayName },
                "引擎子菜单里必须有「\(candidate.displayName)」")
            XCTAssertEqual(item.state, candidate == .apple ? .on : .off,
                           "「\(candidate.displayName)」的勾选状态不对")
        }

        let senseVoice = try XCTUnwrap(
            engineSub.items.first { $0.title == TranscriptionEngine.senseVoice.displayName })
        _ = NSApp.sendAction(try XCTUnwrap(senseVoice.action),
                             to: senseVoice.target, from: senseVoice)
        XCTAssertEqual(workspace.transcriptionEngine, .senseVoice, "点一下必须真的切")
        XCTAssertEqual(RecorderPreferences(defaults: defaults).transcriptionEngine, .senseVoice,
                       "必须落盘，否则下一场还用旧引擎")
    }

    /// 每个引擎项都要带 `representedObject`，否则点击后无从知道选了哪个。
    func testEveryEngineItemCarriesItsRawValue() throws {
        let menu = topLevelMenu()
        let recording = try XCTUnwrap(
            mrFindMenuItem(in: menu,
                           titleHasPrefix: StatusItemController.recordingSettingsMenuTitle))
        let sub = try XCTUnwrap(recording.submenu)
        let engineEntry = try XCTUnwrap(
            sub.items.first { $0.title.hasPrefix(StatusItemController.engineMenuTitle) })
        for candidate in TranscriptionEngine.allCases {
            let item = try XCTUnwrap(
                engineEntry.submenu?.items.first { $0.title == candidate.displayName })
            XCTAssertEqual(item.representedObject as? String, candidate.rawValue,
                           "「\(candidate.displayName)」没带 rawValue，点击后会静默无效")
        }
    }
}

// MARK: - 折叠摘要的文案

/// 顶栏那个折叠标签的文案断言。
///
/// 单独一组，因为**折叠态那一行写的是什么就是用户读到的规格**——
/// 它不是装饰，也不能靠截图目测。
@MainActor
final class RecordingSettingSummaryTests: XCTestCase {

    /// 默认状态：源采样率 + 32 位浮点 + 苹果原生。
    func testDefaultSummaryIsLosslessSourceRate() {
        let s = RecordingSettingSummary.summary(
            pcm16: false, mono24k: false, engine: .apple, hidesCountdown: false)
        XCTAssertEqual(s.format, "源采样率 · 32 位浮点")
        XCTAssertEqual(s.engine, "苹果原生")
        XCTAssertEqual(s.labelText, "源采样率 · 32 位浮点 · 苹果原生")
        XCTAssertFalse(s.isConcealed)
    }

    /// **「源采样率」不是占位符，是在不说谎。**
    ///
    /// 省多少完全取决于设备给的格式：有些麦克风（如 AirPods）本身就只给
    /// 24 kHz 单声道，那时「我」轨没有采样率可降。写死「48 kHz 立体声」
    /// 会在 AirPods 上变成一句假话——而这种错用户自己发现不了，
    /// 因为他只会看到界面上写着一个很具体的数字。
    func testSourceRateIsNotHardcodedWhenDownsamplingIsOff() {
        let s = RecordingSettingSummary.formatText(pcm16: false, mono24k: false)
        XCTAssertFalse(s.contains("48"), "采样率不能写死——实际取决于设备给的格式：\(s)")
        XCTAssertTrue(s.contains("源采样率"))
    }

    /// 四种组合都要说得通。
    func testAllFourCombinations() {
        XCTAssertEqual(
            RecordingSettingSummary.formatText(pcm16: true, mono24k: false),
            "源采样率 · 16 位")
        XCTAssertEqual(
            RecordingSettingSummary.formatText(pcm16: false, mono24k: true),
            "24 kHz 单声道 · 32 位浮点")
        XCTAssertEqual(
            RecordingSettingSummary.formatText(pcm16: true, mono24k: true),
            "24 kHz 单声道 · 16 位")
    }

    /// 静默录制**不写进文字**。
    ///
    /// 一个「静默录制中」的标签恰恰是这个开关要消除的可见性——
    /// 它开着的时候，唯一的提示是一个图标。
    func testConcealmentIsCarriedByAnIconNotByText() {
        let on = RecordingSettingSummary.summary(
            pcm16: false, mono24k: false, engine: .apple, hidesCountdown: true)
        let off = RecordingSettingSummary.summary(
            pcm16: false, mono24k: false, engine: .apple, hidesCountdown: false)
        XCTAssertEqual(on.labelText, off.labelText,
                       "静默录制不该出现在文字里——那正是它要消除的可见性")
        XCTAssertTrue(on.isConcealed, "但图标要知道它开着")
        XCTAssertFalse(off.isConcealed)
    }
}