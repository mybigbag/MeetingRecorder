import XCTest
import AppKit
import SwiftUI
import MRCapture
import MRCore
@testable import MRGUI
import MRSession

/// 「在菜单栏显示图标」这个开关。
///
/// ## 为什么这一组值得写
///
/// 它的失效形态是**静默的**：偏好写对了、菜单勾选状态也对，但图标还在
/// （或反过来——设置里显示已关、菜单栏上照样在）。没有崩溃、没有报错，
/// 只有一类用户会发现：就是那些**把菜单栏看得干净**的人。
/// 所以「开关 → `NSStatusItem.isVisible`」这最后一跳必须钉死。
///
/// ## 这里验不了、靠探针的
///
/// 「图标真的从屏幕右上角消失/出现」验不了：测试进程没有 bundle，
/// 菜单栏从不布局（同 `StatusItemConcealTests` 的边界说明）。
/// 这里钉的是**同一份偏好、同一个开关、同一条订阅链**上的行为。
@MainActor
final class StatusItemIconVisibilityTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var engine: StubEngine!
    private var workspace: MeetingWorkspace!
    private var controller: StatusItemController!

    override func setUp() async throws {
        _ = NSApplication.shared

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-icon-visibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 偏好跑在自己的 suite 里，**绝不碰 `.standard`**（理由同
        // `StatusItemConcealTests`：写进标准域会跨用例残留）。
        suiteName = "mr-icon-visibility-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        let stub = StubEngine(root: root)
        engine = stub
        workspace = MeetingWorkspace(
            root: root,
            preferences: RecorderPreferences(defaults: defaults),
            makeRecorder: { _, _ in stub })
        controller = StatusItemController(
            workspace: workspace, hotKeyFailures: [], onShowWindow: {})
    }

    override func tearDown() async throws {
        controller = nil
        workspace = nil
        engine = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    // MARK: - 夹具

    /// 只够把状态机推到 `.recording` 的假引擎（与 `StatusItemConcealTests`
    /// 同款：真录音要两项 TCC 授权，无头环境给不了）。
    private final class StubEngine: RecordingEngine, @unchecked Sendable {
        let sessionID = "2026-10-20-110000-图标测试"
        private let root: URL
        private let lock = NSLock()
        private var running = false
        private var paused = false

        init(root: URL) { self.root = root }

        var elapsed: Double { 0 }
        var recordedSeconds: Double { 0 }

        @discardableResult
        func start(title: String) throws -> String {
            let dir = root.appendingPathComponent(sessionID, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            lock.withLock { running = true; paused = false }
            return sessionID
        }

        func stop() throws -> DualTrackRecorder.Result {
            lock.withLock { running = false; paused = false }
            let stats = TrackStats(sampleRate: 48000, channels: 1, frames: 24000)
            return DualTrackRecorder.Result(
                sessionID: sessionID,
                directory: root.appendingPathComponent(sessionID, isDirectory: true),
                manifest: RecordingManifest(
                    sessionID: sessionID, title: "图标测试", state: .finalized),
                drift: DriftReport(tracks: [DriftReport.Track(id: "mic", stats: stats)]))
        }

        func abort() { lock.withLock { running = false; paused = false } }

        var isPaused: Bool { lock.withLock { paused } }

        @discardableResult
        func pause() -> Bool {
            lock.withLock {
                guard running, !paused else { return false }
                paused = true
                return true
            }
        }

        @discardableResult
        func resume() -> Bool {
            lock.withLock {
                guard running, !paused else { return false }
                paused = false
                return true
            }
        }
    }

    /// 轮询到条件成立，超时判失败。同 `StatusItemConcealTests` 的理由：
    /// 订阅走 `Task { @MainActor in }`，耗时不确定，固定 sleep 会偶发假失败。
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待超时（\(timeout) 秒）：\(description)", file: file, line: line)
    }

    // MARK: - 一、默认值与落盘

    /// 全新安装（键不存在）时图标必须是**显示的**。
    ///
    /// 方向与「静默录制」相反：那个默认关，这个默认开。关掉它菜单栏上
    /// 就什么都不剩，「图标不见了」会是开关自己造出来的症状。
    func testFreshLaunchShowsTheIcon() throws {
        XCTAssertTrue(workspace.showsStatusBarIcon)
        XCTAssertTrue(controller.isIconVisible, "没设过偏好时图标必须在菜单栏上")
        XCTAssertNil(
            defaults.object(forKey: RecorderPreferences.showsStatusBarIconKey),
            "读一次偏好不该顺手把它写下来")
    }

    /// 关掉图标：偏好落盘 + 状态栏项真的收起来。
    ///
    /// 两个都验——只验偏好的话，「设置里显示已关、菜单栏上还在」
    /// 这种自相矛盾永远发现不了。
    func testHidingTheIconTakesItOffTheMenuBar() async throws {
        workspace.showsStatusBarIcon = false

        await waitUntil("图标收起") { !self.controller.isIconVisible }
        XCTAssertEqual(
            defaults.object(forKey: RecorderPreferences.showsStatusBarIconKey) as? Bool,
            false, "关掉图标必须写穿到偏好域")
    }

    /// 开得回来。只写不读（或只单向生效）的实现在这里会红。
    func testShowingItAgainBringsTheIconBack() async throws {
        workspace.showsStatusBarIcon = false
        await waitUntil("图标收起") { !self.controller.isIconVisible }

        workspace.showsStatusBarIcon = true
        await waitUntil("图标回来") { self.controller.isIconVisible }
    }

    /// 换一个工作区 + 控制器（= 重启应用）仍读得到关闭状态。
    ///
    /// 这条挡的是「只在内存里生效」：那种实现下用户关掉图标、
    /// 重启应用，图标又回来了——而他什么都没做。
    func testHiddenIconStaysHiddenAfterRestart() throws {
        workspace.showsStatusBarIcon = false

        let reopened = MeetingWorkspace(
            root: root, preferences: RecorderPreferences(defaults: defaults))
        XCTAssertFalse(reopened.showsStatusBarIcon)
        let newController = StatusItemController(
            workspace: reopened, hotKeyFailures: [], onShowWindow: {})
        XCTAssertFalse(newController.isIconVisible, "重启后图标必须保持隐藏")
    }

    // MARK: - 二、与「录制中刷新」的相互作用（本套件的核心）

    /// 录制**过程中**关掉图标，必须保持隐藏——不能被 0.5 秒一次的计时刷新
    /// 顺手画回来。
    ///
    /// 这是把 `applyIconVisibility()` 与 `refreshButton()` 分开的全部理由：
    /// 两者混在一起（或显隐只写在 `refreshButton` 里）时，空闲时测试全绿，
    /// 一录上就失效——因为那时每秒有两次 `elapsed` 发布，每次都重画按钮。
    func testHiddenIconStaysHiddenWhileTheTimerKeepsRefreshing() async throws {
        workspace.startRecording(titleBase: "")
        await waitUntil("状态机进入 .recording") { self.workspace.recorder.phase == .recording }
        await waitUntil("状态栏上出现计时") { (self.controller.buttonTitle ?? "").isEmpty == false }

        workspace.showsStatusBarIcon = false
        await waitUntil("图标收起") { !self.controller.isIconVisible }

        // 刻意等过两个计时周期（0.5 秒一发）：只等一拍的话，
        // 「刷新链路压根没跑」也能让上面那条绿。
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertFalse(controller.isIconVisible, "计时刷新不许把被关掉的图标画回来")
        // 关键区分：藏的是**菜单栏入口**，不是录音本身。
        XCTAssertEqual(workspace.recorder.phase, .recording, "关图标不该动到录音")
        XCTAssertTrue(workspace.recorder.isActive)
        // 按钮外观仍在照实刷新（录制中 = 红点 + 计时）——
        // 证明录音链路没被这个开关碰坏，只是不出现在菜单栏上。
        XCTAssertEqual(controller.lastAppearance?.tint, .red)
    }

    // MARK: - 三、菜单入口

    /// 菜单里必须有这个开关，且默认**勾上**（默认显示）。
    ///
    /// 用 `mrFindMenuItem` 递归找：这个开关在「菜单栏」子菜单里，
    /// 只查顶层的话将来调整归类又会集体变红（`MenuLookup` 的教训）。
    func testMenuCarriesTheIconToggleAndShowsItsCurrentState() {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        let item = mrFindMenuItem(in: menu, title: StatusItemController.statusIconMenuTitle)
        XCTAssertNotNil(item, "状态栏菜单里必须有这个开关，实际只有：\(mrFlattenMenuTitles(menu))")
        XCTAssertEqual(item?.state, .on, "默认显示，菜单上必须勾上")

        // 分组入口的标题要带当前取值——不点开也知道现在是什么
        let entry = mrFindMenuItem(in: menu, titleHasPrefix: StatusItemController.menuBarMenuTitle)
        XCTAssertNotNil(entry, "「菜单栏」分组入口必须存在")
        XCTAssertEqual(entry?.title, "菜单栏：显示中")

        workspace.showsStatusBarIcon = false
        let reopened = NSMenu()
        controller.menuNeedsUpdate(reopened)
        XCTAssertEqual(
            mrFindMenuItem(in: reopened, title: StatusItemController.statusIconMenuTitle)?.state,
            .off,
            "关掉之后菜单上必须取消勾选——不然用户没有任何地方能知道它关着")
        XCTAssertEqual(
            mrFindMenuItem(in: reopened, titleHasPrefix: StatusItemController.menuBarMenuTitle)?.title,
            "菜单栏：已隐藏")
    }

    /// 走真实的 target/action，不是直接把属性设成 false。
    /// 后者证明不了菜单项接对了——而「菜单点了没反应」正是这里唯一会坏的形态。
    ///
    /// 只在**空闲态**点：录制中点击会弹确认框（`runModal` 在测试里会卡住），
    /// 那条路径由 `shouldConfirmHidingIcon` 的纯函数用例覆盖。
    func testClickingTheMenuToggleFlipsTheSetting() throws {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(
            mrFindMenuItem(in: menu, title: StatusItemController.statusIconMenuTitle))
        let action = try XCTUnwrap(item.action, "菜单项没有接动作")
        XCTAssertNotNil(item.target, "菜单项没有 target，点了不会有反应")

        _ = NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertFalse(workspace.showsStatusBarIcon, "点一下应当关掉")

        _ = NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertTrue(workspace.showsStatusBarIcon, "再点一下应当开回来")
    }

    // MARK: - 四、确认时机（纯函数）

    /// 会泄露「正在录」的四个相位：准备、录制、暂停、收尾。
    private static let leakingPhases: [RecordingController.Phase] = [
        .preparing, .recording, .paused, .stopping,
    ]

    /// 只有录制中的四个相位需要确认；空闲 / 已保存 / 失败都不需要。
    ///
    /// 判据复用 `leaksRecording` 而不是另写一套：两套分类法必然漂，
    /// 而漂的方向是「该确认的时候不确认」——用户毫无防备地失去
    /// 菜单栏上唯一的录音指示。
    func testShouldConfirmOnlyWhileRecording() {
        for phase in Self.leakingPhases {
            XCTAssertTrue(
                StatusItemController.shouldConfirmHidingIcon(phase: phase),
                "\(phase) 时关掉图标要先确认")
        }
        XCTAssertFalse(StatusItemController.shouldConfirmHidingIcon(phase: .idle))
        XCTAssertFalse(StatusItemController.shouldConfirmHidingIcon(
            phase: .finished(sessionID: "x")))
        // 失败时刻意**不**确认：那时候菜单栏上写着失败原因，
        // 藏不藏图标都不影响用户得知出了错——为它多弹一次框只是噪音。
        XCTAssertFalse(StatusItemController.shouldConfirmHidingIcon(
            phase: .failed(message: "x")))
    }

    /// 与 `leaksRecording` 的分类必须一致。这条挡的是「两套分类法漂了」——
    /// 单独看每套都像有道理，合在一起就是同一个相位两种待遇。
    func testConfirmationClassificationMatchesLeakClassification() {
        let phases: [RecordingController.Phase] =
            [.idle, .preparing, .recording, .paused, .stopping,
             .finished(sessionID: "x"), .failed(message: "x")]
        for phase in phases {
            XCTAssertEqual(
                StatusItemController.shouldConfirmHidingIcon(phase: phase),
                StatusItemController.leaksRecording(phase),
                "\(phase) 在两种分类下必须同侧")
        }
    }

    // MARK: - 五、文案单一出处

    /// 三个入口共用同一份说明。这条挡的是「复制粘贴出了两份」——
    /// 那种漂移在编译期完全合法，只有用户读着两份不一致的说明时才发现。
    func testHelpTextIsSharedAcrossEntries() {
        XCTAssertFalse(StatusItemController.statusIconHelp.isEmpty)
        // 说明里必须写清两件事：不影响录音、怎么恢复。少任何一件，
        // 用户关掉图标后都会慌——而这两件事正是他被卡住时唯一会去看的地方。
        XCTAssertTrue(
            StatusItemController.statusIconHelp.contains("⌥⌘R"),
            "说明里必须提到快捷键不受影响：\(StatusItemController.statusIconHelp)")
        XCTAssertTrue(
            StatusItemController.statusIconHelp.contains("设置窗口"),
            "说明里必须写清怎么恢复：\(StatusItemController.statusIconHelp)")
        XCTAssertFalse(
            StatusItemController.hideIconAlertMessage.isEmpty, "确认弹窗不能是空的")
    }

    /// 常驻说明必须**跟着当前状态说人话**：开着时讲「关了会怎样」，
    /// 关着时讲「怎么恢复」。一份静态文案在这里是不够的——
    /// 用户恰好只会在其中一种状态下去读这行字。
    func testCaptionFollowsTheCurrentState() {
        let on = StatusItemController.statusIconCaption(showsIcon: true)
        let off = StatusItemController.statusIconCaption(showsIcon: false)

        XCTAssertNotEqual(on, off, "两种状态必须给不同的说明")
        XCTAssertTrue(on.contains("关闭后"), "开着时要讲关了会怎样：\(on)")
        XCTAssertTrue(off.contains("恢复"), "关着时要讲怎么恢复：\(off)")
        // 两态都不许出现 Markdown 记号——`Text` 只认纯文本，
        // 两个星号会被原样印在界面上（渲染图才能看见的那种错）。
        XCTAssertFalse(on.contains("**"), "：\(on)")
        XCTAssertFalse(off.contains("**"), "：\(off)")

        // **一行读完**。2026-10-22 之前这里是三段话、在设置窗口里占三行，
        // 原话是「说明文案杂乱成堆，不简洁清晰」。
        // 长解释搬去了 `SettingsCopy.statusIconDetails`（点「说明」展开），
        // 常驻那一行只留一句。字数上限是排版约束，不是审美偏好。
        for text in [on, off] {
            let length = SettingsCopy.visibleLength(text)
            XCTAssertLessThanOrEqual(
                length, SettingsCopy.oneLineBudget,
                "常驻说明必须在 \(SettingsCopy.oneLineBudget) 个汉字以内，"
                    + "实际 \(length)：「\(text)」")
        }
    }

    // MARK: - 七、图标与窗口不在同一块屏

    /// macOS 26 上每块屏各有菜单栏。**2026-10-20 复核后修正了原来的说法**：
    /// 原来以为「状态栏项跟随 key window 所在屏」，实测**不成立**——
    /// 状态栏项在**每一块屏的菜单栏上各有一份**，始终同步
    /// （启动时两块屏的项数同时 +1，退出时同时 -1，宽度签名完全一致）。
    ///
    /// 所以「图标只在另一块屏上」这个状态并不存在。下面这条测的是
    /// `screenHint` 这个**文案函数**本身的行为（它保留下来是为了不破坏调用点），
    /// 而**产品逻辑不再依赖它**——见 `StatusItemController.updateScreenHint()`。
    func testScreenHintOnlyWhenIconAndWindowAreOnDifferentScreens() {
        XCTAssertNil(
            StatusItemController.screenHint(iconScreen: "内置显示器", windowScreen: "内置显示器"),
            "同一块屏不需要提示")
        XCTAssertNil(
            StatusItemController.screenHint(iconScreen: nil, windowScreen: "内置显示器"),
            "读不到图标所在屏时不提示——那是另一种故障，别混着说")
        XCTAssertNil(
            StatusItemController.screenHint(iconScreen: "内置显示器", windowScreen: nil),
            "读不到窗口所在屏时不提示")

        let hint = StatusItemController.screenHint(
            iconScreen: "外接显示器", windowScreen: "内置显示器")
        XCTAssertNotNil(hint, "两块屏不同时必须给提示")
        // 提示必须**说清图标在哪块屏**——用户要找的是图标，不是「它们不一样」。
        XCTAssertTrue(hint?.contains("外接显示器") == true, "提示里要点名图标所在的屏：\(hint ?? "")")
        XCTAssertTrue(hint?.contains("内置显示器") == true, "提示里要点名窗口所在的屏：\(hint ?? "")")
    }

    /// 提示语里不能出现 Markdown 记号（`Text` 只认纯文本）。
    func testScreenHintHasNoMarkdownMarks() {
        let hint = StatusItemController.screenHint(
            iconScreen: "外接显示器", windowScreen: "内置显示器") ?? ""
        XCTAssertFalse(hint.contains("**"), "：\(hint)")
    }

    /// 「系统没登记」时的提示必须说清三件事：
    /// ① 原因（系统没登记，**不是**菜单栏满了）；② 怎么办；③ **功能没坏**。
    ///
    /// 这条特别挡一种错误说法：原来的文案说「菜单栏放不下，腾出空间就能显示」。
    /// 那是**错的**——实测那块屏的菜单栏还有空位，系统是根本没登记这个项。
    /// 说错原因会让用户去腾菜单栏空间，腾完了图标还是不出来。
    func testNotRegisteredHintExplainsTheRealCauseAndTheFix() {
        let hint = StatusItemController.noRoomHint()

        // ① 原因：说清是「系统没登记」，而不是「菜单栏满了」
        XCTAssertTrue(
            hint.contains("登记"),
            "提示必须说清是系统没登记：\(hint)")
        XCTAssertFalse(
            hint.contains("挤满") || hint.contains("放不下"),
            "不能说成「菜单栏放不下」——实测菜单栏还有空位，说错原因会误导用户：\(hint)")

        // ② 办法：必须给出可执行的出路
        XCTAssertTrue(
            hint.contains("访达") || hint.contains("open -a"),
            "必须给出可执行的办法：\(hint)")

        // ③ 功能没坏
        XCTAssertTrue(
            hint.contains("快捷键") || hint.contains("不受影响"),
            "必须让用户知道功能没坏：\(hint)")
    }

    /// 提示语里不能出现 Markdown 记号（`Text` 只认纯文本）。
    func testNotRegisteredHintHasNoMarkdownMarks() {
        let hint = StatusItemController.noRoomHint()
        XCTAssertFalse(hint.contains("**"), "：\(hint)")
    }

    /// 屏名的来源：内置屏给明确说法，外接屏用系统给的名字。
    ///
    /// 用户找图标时看的是显示器上的标识，不是一句「另一块显示器」——
    /// 他得知道是哪一块。外接屏的名字由系统给（实测是型号名），
    /// 拿不到时退回「另一块显示器」，但不能是空串。
    func testScreenNameNeverEmpty() {
        let fallback = StatusItemController.fallbackScreenName
        XCTAssertFalse(fallback.isEmpty, "兜底名字不能是空的")
    }

    // MARK: - 六、主窗口恢复横幅

    /// 横幅**只在图标关着时出现**。
    ///
    /// 判据用位图颜色数而不是查视图树：SwiftUI 的 `body` 是 opaque 类型，
    /// 从外面断言「里面有没有 HStack」只能靠 Mirror，那种断言改一次
    /// 内部结构就红，而它要防的问题（忘了挂条件、条件写反）反而测不出。
    /// 「画得出东西 / 什么都画不出」才是这个视图真正的失效形态。
    func testBannerOnlyRendersWhileTheIconIsHidden() throws {
        workspace.showsStatusBarIcon = true
        XCTAssertEqual(
            try colorCount(of: StatusBarIconBanner(workspace: workspace)), 0,
            "图标正常显示时横幅必须什么都不画——常驻横幅会变成骚扰")

        workspace.showsStatusBarIcon = false
        let hidden = try colorCount(of: StatusBarIconBanner(workspace: workspace))
        XCTAssertGreaterThan(
            hidden, 3,
            "图标关着时横幅必须画出内容（标题+正文+按钮），实际只有 \(hidden) 种颜色")
    }

    /// 横幅上必须同时写清两件事：**录音没受影响**与**怎么恢复**。
    ///
    /// 这不是文案洁癖：2026-10-20 关掉图标后「退出重开」想恢复默认，
    /// 重启后主窗口上什么都没有——他没有任何可见线索知道图标是自己关的、
    /// 该去哪开回来。横幅的存在理由就是把这两件事放到他第一眼能看到的地方，
    /// 所以少任何一件，横幅就白挂了。
    func testBannerCopyTellsTheUserBothFacts() {
        let text = StatusBarIconBanner.title + StatusBarIconBanner.message
        XCTAssertTrue(
            text.contains("录音不受影响"),
            "横幅必须写明录音没受影响（用户第一反应是「图标没了是不是录崩了」）：\(text)")
        XCTAssertTrue(
            text.contains("快捷键"),
            "横幅要说清录音靠什么继续：\(text)")
        XCTAssertFalse(StatusBarIconBanner.restoreTitle.isEmpty, "恢复按钮不能没有标题")
        // 纯文本渲染，不许 Markdown 记号（同 statusIconCaption 那一课）。
        XCTAssertFalse(text.contains("**"), "：\(text)")
    }

    /// 把视图渲染成 1× 位图，数一数有多少种不同颜色（量化到 16 级/通道）。
    ///
    /// 只回答「空 vs 非空」这一个问题，所以不需要精确：
    /// 全透明像素不计，纯色块（哪怕整屏一种底色）只算一种。
    private func colorCount<V: View>(of view: V) throws -> Int {
        let renderer = ImageRenderer(
            content: view.frame(width: 560, height: 40))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return 0 }
        // 统一转成 RGBA8：ImageRenderer 出来的位图格式不保证
        // （实测是 BGRA 预乘），直接按字节解会红绿颠倒。
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.bitmapData else { return 0 }
        var colors = Set<UInt32>()
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let offset = y * rep.bytesPerRow + x * 4
                let alpha = data[offset + 3]
                guard alpha > 0 else { continue }
                let quantized =
                    (UInt32(data[offset]) / 16) << 8
                    | (UInt32(data[offset + 1]) / 16) << 4
                    | (UInt32(data[offset + 2]) / 16)
                colors.insert(quantized)
            }
        }
        return colors.count
    }
}
