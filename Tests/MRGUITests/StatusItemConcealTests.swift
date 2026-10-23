import XCTest
import AppKit
import MRCapture
import MRCore
@testable import MRGUI
import MRSession

/// 「静默录制」——录制期间不把「正在录」这件事摆在菜单栏上。
///
/// ## 为什么这一组值得写
///
/// 这个开关失效时的表现是**屏幕上什么异常都没有**：该消失的计时还留着，
/// 图标还红着，鼠标移上去还写着「录制中」。没有崩溃、没有报错、没有断言，
/// 只有一类用户会发现——就是那些**因为不想被人看见才打开它的人**，
/// 而他们发现的时候已经晚了。所以判断必须钉死，不能靠盯截图。
///
/// ## 为什么这里能测到「真按钮」
///
/// 「开关一拨，菜单栏上的字就没了」中间隔着 Combine 订阅那一层，
/// 而 `@Published` 是在 `willSet` 里发值的（属性从 0 改成 7，sink 里同步读回 0，
/// 实测）。少了「跳一个回合再刷新」这一步，同步刷新画的就是**上一帧的状态**——
/// 录制中恰好每 0.5 秒有一次计时刷新把它盖住，只有空闲时切换才稳定暴露。
/// 这类错只有把真 `NSStatusBarButton` 拿来看才能发现，所以下面有一组
/// 用假引擎把状态机推到 `.recording` 的用例。
///
/// ## 有哪些是这里验不了、必须靠探针的
///
/// 「`NSStatusBar` 真的把按钮画到了屏幕右上角那个像素上」这里验不了——
/// 测试进程没有 bundle，菜单栏从不布局（见 `StatusBarLifecycleTests`）。
/// 那一段由 `scripts/probes/gui-lifecycle/` 在真 `run()` 里覆盖。
@MainActor
final class StatusItemConcealTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var engine: StubEngine!
    private var workspace: MeetingWorkspace!
    private var controller: StatusItemController!

    override func setUp() async throws {
        _ = NSApplication.shared

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-conceal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 偏好跑在自己的 suite 里，**绝不碰 `.standard`**：
        // 那是测试进程的偏好域，写进去会跨用例残留，
        // 于是「默认是关的」这种断言第二次跑就不成立——而且取决于执行顺序。
        suiteName = "mr-conceal-tests-\(UUID().uuidString)"
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

    /// 只够把状态机推到 `.recording` / `.paused` 的假引擎。
    ///
    /// 真录音要「麦克风」+「系统音频录制」两项 TCC 授权，无头环境给不了；
    /// 而「相位变了 → 状态栏按钮跟着变」这条链路恰恰是这个开关的失效点。
    private final class StubEngine: RecordingEngine, @unchecked Sendable {
        let sessionID = "2026-09-27-120000-静默测试"
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
                    sessionID: sessionID, title: "静默测试", state: .finalized),
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
                guard running, paused else { return false }
                paused = false
                return true
            }
        }
    }

    /// 轮询到条件成立，超时直接判失败。
    ///
    /// 不用固定 `sleep`：`beginRecording` 是在一个 detached task 里回到主 actor 的，
    /// 耗时不确定。固定睡眠要么偶发假失败，要么被逼着写成一个大得离谱的值，
    /// 把整个套件拖慢。
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

    /// 把状态机推到 `.recording`，并等到状态栏上真的出现计时。
    private func startAndWaitForTheClock(
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        workspace.startRecording(titleBase: "")
        await waitUntil("状态机进入 .recording", file: file, line: line) {
            self.workspace.recorder.phase == .recording
        }
        await waitUntil("状态栏上出现计时", file: file, line: line) {
            (self.controller.buttonTitle ?? "").isEmpty == false
        }
    }

    // MARK: - 一、外观判断（纯函数）

    /// 会泄露「正在录」的四个相位：准备、录制、暂停、收尾。
    private static let leakingPhases: [RecordingController.Phase] = [
        .preparing, .recording, .paused, .stopping,
    ]

    /// 隐藏模式下，四个相位必须**一模一样**——不是「都藏了计时」，
    /// 而是整份换成同一份中性外观：同一个图标、无色、无字、提示语不提任何状态。
    ///
    /// 为什么用「相等」而不逐项断言：逐项断言只保护我今天想到的那几项，
    /// 将来给 `Appearance` 加字段（比如「正在录几条轨」）就漏了。
    /// 相等关系是结构性的，新字段压根不在被比较的那一份里。
    func testConcealedModeCollapsesEveryRecordingPhaseToTheSameNeutralLook() {
        for phase in Self.leakingPhases {
            let hidden = StatusItemController.appearance(
                for: phase, elapsed: 754, hidesCountdown: true)
            XCTAssertEqual(
                hidden, StatusItemController.concealedAppearance,
                "\(phase) 在隐藏模式下必须换成那一份中性外观，实际 \(hidden)")
        }
    }

    /// 上面那条如果被一个「永远返回中性外观」的实现满足，就等于没测。
    /// 这一条是它的阳性对照：标准模式下四个相位必须**互不相同**，
    /// 而且每个都跟中性外观不一样。
    func testStandardModeGivesEveryRecordingPhaseItsOwnLook() {
        var seen: [StatusItemController.Appearance] = []
        for phase in Self.leakingPhases {
            let shown = StatusItemController.appearance(
                for: phase, elapsed: 754, hidesCountdown: false)
            XCTAssertNotEqual(
                shown, StatusItemController.concealedAppearance,
                "\(phase) 在标准模式下不该等于中性外观")
            XCTAssertFalse(
                seen.contains(shown),
                "\(phase) 在标准模式下的外观与另一个相位撞了：\(shown)")
            seen.append(shown)
        }
    }

    /// 中性外观本身要真的是「没什么可看」：没有秒数、没有颜色、提示语不表态。
    /// 把它单独钉一条，是因为上面那条相等断言里，两边是同一个常量——
    /// 常量如果哪天被改成红色带计时，相等断言照样绿。
    func testTheNeutralLookItselfCarriesNoSignal() {
        let hidden = StatusItemController.concealedAppearance

        XCTAssertEqual(hidden.symbolName, "waveform", "隐藏模式必须回到中性的波形图标")
        XCTAssertEqual(hidden.tint, .none, "隐藏模式不能有颜色——红色圆点是最显眼的那个信号")
        XCTAssertTrue(hidden.title.isEmpty, "隐藏模式下按钮上不能有字")

        // 提示语是鼠标一放上去就出现的东西，也算被动可见。
        //
        // 判据是「**只允许是应用名本身**」，不是「不许出现某几个字」。
        // 第一版写的就是后者，结果被自己抓到：应用名「会议录音器」里就有一个「录」字，
        // 于是断言红在了一个完全正确的实现上。**判据太粗会制造假失败**，
        // 而假失败比不测更糟——它会训练人忽略红色。
        XCTAssertEqual(
            hidden.tooltip, "会议录音器",
            "隐藏模式的提示语只能是不带状态的图标名，多一个字都可能是在表态")
    }

    /// 标准模式下录制中**必须**有计时和红色标识——这是「默认看得见」的那一半。
    /// 少了它，「隐藏模式」和「干脆不显示任何状态」就分不开了。
    func testStandardModeStillShowsTheCountdownAndTheRedDot() {
        let shown = StatusItemController.appearance(
            for: .recording, elapsed: 754, hidesCountdown: false)

        XCTAssertEqual(shown.title, " 12:34", "标准模式下录制中要显示 mm:ss")
        XCTAssertEqual(shown.tint, .red)
        XCTAssertEqual(shown.symbolName, "record.circle.fill")
        XCTAssertTrue(shown.tooltip.contains("录制中"))
    }

    /// 暂停在标准模式下与录制中必须看得出区别——暂停期间的声音是真的没了。
    func testStandardModeDistinguishesPausedFromRecording() {
        let recording = StatusItemController.appearance(
            for: .recording, elapsed: 60, hidesCountdown: false)
        let paused = StatusItemController.appearance(
            for: .paused, elapsed: 60, hidesCountdown: false)

        XCTAssertEqual(paused.tint, .orange)
        XCTAssertNotEqual(paused, recording)
        XCTAssertTrue(paused.tooltip.contains("已暂停"))
    }

    /// **失败不许被藏起来。** 这个开关藏的是「正在录」，不是「录坏了」。
    /// 把「麦克风没授权」也一起藏掉，用户会以为录上了——那比被看见严重得多。
    func testConcealedModeStillReportsFailures() {
        let failed = StatusItemController.appearance(
            for: .failed(message: "麦克风没有授权"), elapsed: 0, hidesCountdown: true)

        XCTAssertTrue(
            failed.tooltip.contains("麦克风没有授权"),
            "出错必须照实说，实际「\(failed.tooltip)」")
        XCTAssertNotEqual(failed, StatusItemController.concealedAppearance)
    }

    /// 开关不该改变本来就不泄露录音的那几个相位。
    /// 变了就说明实现是「无差别屏蔽」，那会把「已保存 xxx」这种有效信息一起吞掉。
    func testConcealFlagLeavesIdleAndFinishedUntouched() {
        for phase in [RecordingController.Phase.idle, .finished(sessionID: "2026-09-27-120000-会议")] {
            XCTAssertEqual(
                StatusItemController.appearance(for: phase, elapsed: 0, hidesCountdown: true),
                StatusItemController.appearance(for: phase, elapsed: 0, hidesCountdown: false),
                "\(phase) 不泄露录音，开关不该影响它")
        }
    }

    /// `leaksRecording` 是上面所有断言的分类依据，单独钉住它的边界。
    func testLeakClassificationBoundary() {
        for phase in Self.leakingPhases {
            XCTAssertTrue(StatusItemController.leaksRecording(phase), "\(phase) 会泄露正在录音")
        }
        XCTAssertFalse(StatusItemController.leaksRecording(.idle))
        XCTAssertFalse(StatusItemController.leaksRecording(.finished(sessionID: "x")))
        XCTAssertFalse(StatusItemController.leaksRecording(.failed(message: "x")))
    }

    // MARK: - 三、真按钮（这才是这个开关的失效点）

    /// 阳性对照：默认状态下录制中，真 `NSStatusBarButton` 上必须**有**字。
    /// 没有它，下面那条「打开开关后没有字」在「按钮压根没被刷新过」时也会绿。
    func testTheRealButtonCarriesTheClockWhileRecording() async {
        await startAndWaitForTheClock()

        XCTAssertEqual(controller.buttonTitle, " 00:00")
        XCTAssertEqual(controller.lastAppearance?.tint, .red)
        XCTAssertEqual(controller.lastAppearance?.symbolName, "record.circle.fill")
    }

    /// 让主 actor 跑几跳，但**远不到录音计时器 0.5 秒的周期**。
    private func settleWithoutLettingTheTimerFire() async {
        for _ in 0..<10 { await Task.yield() }
    }

    /// 核心用例：录制**过程中**打开开关，菜单栏上的计时必须**立刻**消失，
    /// 不依赖任何相位变化、也不依赖下一次计时刷新。
    ///
    /// 两条都是这个套件的关键，说清楚免得后来的人把它放宽：
    ///
    /// - **不能用 `waitUntil` 等它消失。** 录音时 `elapsed` 每 0.5 秒发布一次，
    ///   每次都重画按钮。任何「等几秒再看看」的写法都会在某个时刻变成绿的，
    ///   于是「订阅漏了」「`@Published` 时序错了」这两类 bug 全能蒙混过关。
    /// - **不能只看最后是不是空的。** 必须是「拨了之后立刻就是空的」。
    ///
    /// 实测两条防线的价值：把 init 里的 `Task { @MainActor in }` 换成同步调用、
    /// 以及删掉 `subscribe(workspace.$hidesStatusBarCountdown)`，这一条都会红。
    func testTurningTheSettingOnClearsTheClockImmediately() async {
        await startAndWaitForTheClock()
        XCTAssertFalse((controller.buttonTitle ?? "").isEmpty, "前置条件：此刻有计时")

        workspace.hidesStatusBarCountdown = true
        await settleWithoutLettingTheTimerFire()

        XCTAssertEqual(controller.buttonTitle, "", "开关一拨，计时必须立刻消失")
        XCTAssertEqual(controller.lastAppearance, StatusItemController.concealedAppearance)
        // 写全 `Tint.none`：`Optional<...>` 也有一个 `.none`，
        // 省略写法会被推断成「可选值为空」，两个含义完全不同却都编译得过。
        XCTAssertEqual(controller.lastAppearance?.tint, StatusItemController.Appearance.Tint.none)
        XCTAssertEqual(controller.lastAppearance?.symbolName, "waveform")

        // 关键区分：藏的是**显示**，不是录音本身。
        XCTAssertEqual(workspace.recorder.phase, .recording, "开关不该动到录音本身")
        XCTAssertTrue(workspace.recorder.isActive)
    }

    /// 关回去要能恢复。只写不读（或只单向生效）的实现在这里会红。
    func testTurningTheSettingOffBringsTheClockBack() async {
        await startAndWaitForTheClock()

        workspace.hidesStatusBarCountdown = true
        await waitUntil("计时消失") { (self.controller.buttonTitle ?? "").isEmpty }

        workspace.hidesStatusBarCountdown = false
        await waitUntil("计时恢复") { (self.controller.buttonTitle ?? "").isEmpty == false }
        XCTAssertEqual(controller.lastAppearance?.tint, .red)
    }

    /// 暂停态也要藏。暂停在标准模式下是橙色的暂停图标——
    /// 那同样在说「有个录音正在这儿」。
    func testConcealedModeAlsoHidesThePausedIndicator() async {
        await startAndWaitForTheClock()
        workspace.hidesStatusBarCountdown = true
        await waitUntil("计时消失") { (self.controller.buttonTitle ?? "").isEmpty }

        workspace.recorder.pause()
        await waitUntil("状态机进入 .paused") { self.workspace.recorder.phase == .paused }
        // 再等一拍，确认不是「还没刷新」而是「刷新了也没东西」
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(controller.lastAppearance, StatusItemController.concealedAppearance)
        XCTAssertEqual(controller.buttonTitle, "")
    }

    // MARK: - 五、图标真的被染上了颜色

    /// `contentTintColor` 在 `NSStatusBarButton` 上**不生效**——实测它会让模板图
    /// 回落成符号自带的黑色，红色和橙色都变成黑的，连按钮文字也从白变黑。
    /// 所以「录制中变红」这件事只能靠**画出来的像素**来证明，
    /// 不能靠「我们设了红色」来证明：上面那些 `Appearance.tint == .red` 的断言
    /// 在渲染全错的情况下照样全绿（它们当初就是这么全绿的）。
    func testRecordingIconIsActuallyDrawnRed() throws {
        let appearance = StatusItemController.appearance(
            for: .recording, elapsed: 0, hidesCountdown: false)
        let image = try XCTUnwrap(StatusItemController.image(for: appearance))

        XCTAssertEqual(
            image.isTemplate, false,
            "上色的图标不能是模板图——模板会被菜单栏前景色整个盖掉")
        XCTAssertGreaterThan(
            pixels(in: image) { $0.redComponent > 0.55 && $0.greenComponent < 0.45 && $0.blueComponent < 0.45 },
            0, "把图标画出来数一遍，一个红像素都没有——「录制中变红」并没有成立")
    }

    /// 暂停是橙色的。这条与上一条分开写：只测红色的话，
    /// 一个「所有颜色都画成红」的实现也能过。
    func testPausedIconIsActuallyDrawnOrange() throws {
        let appearance = StatusItemController.appearance(
            for: .paused, elapsed: 0, hidesCountdown: false)
        let image = try XCTUnwrap(StatusItemController.image(for: appearance))

        XCTAssertGreaterThan(
            pixels(in: image) { $0.redComponent > 0.7 && (0.3...0.8).contains($0.greenComponent)
                && $0.blueComponent < 0.35 },
            0, "暂停的图标应当是橙的")
    }

    /// 中性图标必须**留在模板里**：模板会跟随菜单栏明暗自动反色，
    /// 而写死的颜色在浅色菜单栏上会消失。这条同时挡住「顺手给中性图标也上了色」。
    func testNeutralIconStaysATemplateAndCarriesNoColor() throws {
        let image = try XCTUnwrap(
            StatusItemController.image(for: StatusItemController.concealedAppearance))

        XCTAssertTrue(image.isTemplate, "中性图标必须是模板图，才能跟随菜单栏明暗")
        XCTAssertEqual(
            pixels(in: image) { $0.redComponent > 0.55 && $0.greenComponent < 0.45 && $0.blueComponent < 0.45 },
            0, "隐藏模式的图标不该带任何颜色")
    }

    /// 把图按 32×32 画出来，数满足条件的像素个数。
    ///
    /// 用「有多少个」而不是「中心那一个是什么颜色」：符号的边缘有抗锯齿，
    /// 取中心点是碰运气，而数个数对渲染尺寸和描边粗细都不敏感。
    ///
    /// **证据边界，别读多**：这一组证明的是 `image(for:)` 产出的位图里真有红色。
    /// 它证明不了「菜单栏最后把它画成了红的」——`NSImage.draw` 走的是我们自己的
    /// 绘制上下文，而 `contentTintColor` 那个坑恰好发生在菜单栏自己的渲染管线里
    /// （同一份代码在测试里能画出红色，在真菜单栏上却是黑的）。
    /// 那一段只能靠人眼看真菜单栏：录制时那个圆点是不是红的。
    private func pixels(in image: NSImage, _ isMatch: (NSColor) -> Bool) -> Int {
        let side = 32
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return 0 }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var count = 0
        for x in 0..<side {
            for y in 0..<side {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                guard color.alphaComponent > 0.5 else { continue }
                if isMatch(color) { count += 1 }
            }
        }
        return count
    }

    // MARK: - 六、开关的入口

    func testMenuCarriesTheToggleAndShowsItsCurrentState() {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        let item = mrFindMenuItem(in: menu, title: StatusItemController.concealMenuTitle)
        XCTAssertNotNil(item, "状态栏菜单里必须有这个开关，实际只有：\(mrFlattenMenuTitles(menu))")
        XCTAssertEqual(item?.state, .off, "默认不勾")

        workspace.hidesStatusBarCountdown = true
        let reopened = NSMenu()
        controller.menuNeedsUpdate(reopened)
        XCTAssertEqual(
            mrFindMenuItem(in: reopened, title: StatusItemController.concealMenuTitle)?.state,
            .on,
            "打开之后菜单上必须勾上——不然用户没有任何地方能知道它开着")
    }

    /// 走真实的 target/action，不是直接把属性设成 true。
    /// 后者证明不了菜单项接对了——而「菜单点了没反应」正是这里唯一会坏的形态。
    func testClickingTheMenuToggleFlipsTheSetting() throws {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(
            mrFindMenuItem(in: menu, title: StatusItemController.concealMenuTitle))
        let action = try XCTUnwrap(item.action, "菜单项没有接动作")
        XCTAssertNotNil(item.target, "菜单项没有 target，点了不会有反应")

        _ = NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertTrue(workspace.hidesStatusBarCountdown, "点一下应当打开")

        _ = NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertFalse(workspace.hidesStatusBarCountdown, "再点一下应当关掉")
    }

    /// **菜单首行始终如实。** 藏的是菜单栏上那个被动可见的图标，
    /// 不是「主动点开菜单之后你看到的东西」。
    ///
    /// 少了这一条，用户会彻底失去「现在到底录着没有」的答案——
    /// 那会直接导致「以为自己没在录，又开了一场」或「录完忘了停」。
    func testTheMenuStillTellsTheTruthWhileConcealed() async {
        await startAndWaitForTheClock()
        workspace.hidesStatusBarCountdown = true
        await waitUntil("计时消失") { (self.controller.buttonTitle ?? "").isEmpty }

        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(
            menu.items.first?.title, "录制中 00:00",
            "菜单首行必须仍然如实显示状态，实际「\(menu.items.first?.title ?? "")」")
    }
}
