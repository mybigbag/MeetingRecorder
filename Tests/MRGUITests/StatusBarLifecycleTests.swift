import XCTest
import AppKit
import Carbon
import MRCore
@testable import MRGUI

/// 状态栏常驻 + 关窗不退出 + 全局快捷键。
///
/// 这三件事的共同点是：**界面看起来对，功能可能是全坏的**。
/// 状态栏图标没挂上，窗口里一切正常；快捷键静默失效，连报错都没有。
/// 所以这里不截屏目测，全部走可编程探测。
///
/// ## 有哪些是这里验不了、必须靠独立探针的
///
/// 「按键真的按下去了」这一段验不了：真实按键要经 WindowServer，
/// 而 `CGEvent` 投递需要「辅助功能」授权（用户拒绝后静默失效）。
/// 所以注入从 `kEventHotKeyPressed` 事件开始，覆盖「事件 → handler → 动作」，
/// 缺的那一段需要人打开 App 按一次真快捷键，只能靠人工冒烟，不写成「已验证」。
///
/// 「关窗之后系统会不会把进程收掉」也验不了：它要靠真 `NSApplication.run()`
/// 才能走到（手工 pump `nextEvent`/`sendEvent` 走不到——阳性对照也不触发，
/// 见 `scripts/probes/terminate-policy/`），而测试进程不能交给一个阻塞的 `run()`。
/// 这里只钉住策略方法的返回值。
@MainActor
final class StatusBarLifecycleTests: XCTestCase {

    /// 临时会议库根目录。
    ///
    /// **必须换掉**：`MeetingWorkspace` 默认指向真实的会议库，建窗口会触发一次
    /// 真实扫描，还可能去读真录音算波形。测试不该碰用户的资料。
    /// `SessionStore.defaultRoot()` 是调用时才读环境变量，所以在构造 delegate 前
    /// 设好就有效。这里是 MRGUITests 自己的进程，不会影响别的测试目标。
    private var temporaryRoot: URL!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-statusbar-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoot = root
        setenv(SessionStore.rootEnvironmentKey, root.path, 1)
    }

    override func tearDown() {
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
        unsetenv(SessionStore.rootEnvironmentKey)
        super.tearDown()
    }

    // MARK: - 夹具

    /// 起一套真实的 `AppDelegate`：真窗口 + 真状态栏项 + 真全局热键。
    private func makeLaunchedDelegate() -> AppDelegate {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification))
        return delegate
    }

    /// 收干净。**热键是跨进程独占的**，不清掉的话下一个用例注册同一组 ⌥⌘
    /// 会直接失败，测试之间就开始互相污染——那种失败看起来像产品坏了，其实是夹具脏了。
    private func dispose(_ delegate: AppDelegate) {
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification))
        delegate.window?.close()
    }

    /// 向应用事件目标注入一次「热键被按下」。
    ///
    /// 跳过的是「物理按键 → 事件」；覆盖的是「事件 → Carbon handler → 动作」，
    /// 也就是我们自己写的那一整段。
    @discardableResult
    private func injectHotKey(
        id: UInt32,
        signature: OSType = GlobalHotKeys.signature,
        file: StaticString = #filePath, line: UInt = #line
    ) -> OSStatus {
        var event: EventRef?
        let created = CreateEvent(
            nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event)
        guard created == noErr, let event else {
            XCTFail("构造热键事件失败，OSStatus=\(created)", file: file, line: line)
            return created
        }
        var hotKeyID = EventHotKeyID(signature: signature, id: id)
        SetEventParameter(
            event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        let sent = SendEventToEventTarget(event, GetApplicationEventTarget())
        ReleaseEvent(event)
        // 刻意不在这里断言「投递成功」：事件没人认领时返回的就是
        // `eventNotHandledErr`(-9874)，那是有意义的结论而不是失败。
        // 统一交给调用点判断。
        return sent
    }

    /// 注册失败时的提示。
    ///
    /// 刻意**不**写「先退出正在运行的 MeetingRecorder.app」——实测过：本应用正在运行时，
    /// 另一个进程注册同样的 ⌥⌘R 仍然返回 `noErr`，说明同一组合在两进程间并不必然互斥。
    /// 把没验证过的因果写进错误提示，会把排查引到错地方。
    private static let registrationHint =
        "⌥⌘ 组合注册失败。可能是本机别的程序占着这组快捷键，或系统把它当作保留组合。"

    // MARK: - 状态栏项真的建出来了

    /// 这里只断言「状态栏项连着一个真实的按钮窗口」。
    ///
    /// **不断言高度和屏幕位置**——不是不想，是这里量不到：测试进程没有 bundle、
    /// 也不会跑真 `NSApplication.run()`，菜单栏**根本不会给它布局**。
    /// 实测这一层能读到的 frame 是 `(0, 0, 32, 0)`，高度为 0。
    /// 按「真 run() 里也应该是 39」去断言，测的是测试环境而不是产品。
    ///
    /// 「图标真的落在屏幕右上角的菜单栏里」由 `scripts/probes/gui-lifecycle/`
    /// 在真 run() 里验证（实测 `(1137, 1073, 32, 39)`，屏幕 `1710×1112`）。
    func testStatusItemAttachesARealButtonWindow() throws {
        let delegate = makeLaunchedDelegate()
        defer { dispose(delegate) }

        _ = try XCTUnwrap(delegate.statusItem, "启动后必须持有一个状态栏项")
        let frame = try XCTUnwrap(
            delegate.statusItem?.buttonWindowFrame,
            "状态栏项建出来了，但按钮窗口不在——图标根本没挂上去")

        XCTAssertGreaterThan(frame.width, 0, "状态栏按钮宽度为 0，屏幕上什么都看不到")

        // 探针读到的完整 frame 记在这里，出问题时好对照是环境差异还是真退化了
        print("状态栏按钮 frame（测试进程内，菜单栏未布局）= \(frame)")
    }

    // MARK: - 「图标到底在不在菜单栏上」的判据

    /// 这一组测的是 `StatusItemController.isPlaced`——**按按钮窗口高度**判的纯函数。
    ///
    /// 它的存在理由是一次真实故障：在 macOS 26.6.2 上，某个 bundle ID 的状态栏项
    /// 会被系统整个拒绝登记，而 `NSStatusItem.isVisible` **照样读回 `true`**。
    /// 只看那个属性，「图标不见了」这件事永远发现不了。
    /// （完整复现过程：`scripts/probes/status-item-identity/`。）
    ///
    /// ## 为什么判「高度」而不是「位置」
    ///
    /// 旧判据是几何位置（「`maxY` 落在屏幕上沿 60pt 内」），它有**假阳性**：
    /// 系统完全没登记时，按钮窗口的 frame 仍可能是 `(1826, 2242, 32, 22)`，
    /// 那个 `maxY` 恰好落进某块屏的上沿带，几何算出来是 `true`，
    /// 而屏幕上根本没有图标。**几何与登记状态是脱钩的。**
    ///
    /// 新判据量的是**高度**：系统真登记了才会把按钮窗口拉到菜单栏那么高
    /// （内置屏 39pt、外接屏 30pt）；没被登记时它保持 AppKit 默认的 22pt。
    /// 下面四条用例用的都是 2026-10-20 在真机上量到的**真实值**。

    /// 内置屏的菜单栏高度（实测 39pt）。
    private static let builtinMenuBarHeight: CGFloat = 39

    /// 外接屏的菜单栏高度（实测 30pt）。
    private static let externalMenuBarHeight: CGFloat = 30

    /// 本机两块屏的菜单栏高度（内置 39 / 外接 30）。
    private static let bothMenuBarHeights: [CGFloat] = [39, 30]

    /// 故障现场量到的真实值：系统没登记时按钮窗口停在默认高度 22pt。
    /// 它就是那个把 `isVisible == true` 拆穿的反例——必须判成「没放上去」。
    func testPlacementRejectsTheDefaultHeightFrame() {
        XCTAssertFalse(StatusItemController.isPlaced(
            buttonFrame: NSRect(x: 0, y: -22, width: 32, height: 22),
            menuBarHeights: Self.bothMenuBarHeights))
    }

    /// 对照组：探针在真 `run()` 里量到的 `(1116, 1073, 32, 39)`，必须判成「放上去了」。
    /// 少了这一条，一个永远返回 `false` 的实现也能让上面那条绿。
    func testPlacementAcceptsTheFrameTheProbeMeasured() {
        XCTAssertTrue(StatusItemController.isPlaced(
            buttonFrame: NSRect(x: 1116, y: 1073, width: 32, height: 39),
            menuBarHeights: Self.bothMenuBarHeights))
    }

    /// 外接屏那条带上的项高度是 30pt（内置屏那条是 39pt）。
    /// 判据是「**有没有哪一块屏**的菜单栏高度对得上」，
    /// 所以排在矮屏上时也必须判成「放上去了」。
    ///
    /// 这条用例曾经红过：判据当时写的是「等于所有屏里**最大**的高度」，
    /// 于是排在 30pt 的外接屏上的项被误判成「没登记」。
    /// 差别很细，但方向正好是「把正常的判成故障」。
    func testPlacementAcceptsTheShorterMenuBarOnTheExternalScreen() {
        XCTAssertTrue(StatusItemController.isPlaced(
            buttonFrame: NSRect(x: 1262, y: -1152, width: 32, height: 30),
            menuBarHeights: Self.bothMenuBarHeights))
        // 只给外接屏的高度（30）时也该认——判据不能依赖「恰好还有另一块屏」。
        XCTAssertTrue(StatusItemController.isPlaced(
            buttonFrame: NSRect(x: 1262, y: -1152, width: 32, height: 30),
            menuBarHeights: [Self.externalMenuBarHeight]))
    }

    func testPlacementRejectsMissingWindowOrUnknownMenuBarHeight() {
        XCTAssertFalse(StatusItemController.isPlaced(
            buttonFrame: nil, menuBarHeights: Self.bothMenuBarHeights))
        XCTAssertFalse(StatusItemController.isPlaced(
            buttonFrame: NSRect(x: 1116, y: 1073, width: 32, height: 39), menuBarHeights: []))
    }

    /// 高度为 0 的按钮窗口画不出任何东西，高度再接近也不算「放上去了」。
    func testPlacementRejectsAZeroHeightButton() {
        XCTAssertFalse(StatusItemController.isPlaced(
            buttonFrame: NSRect(x: 1116, y: 1112, width: 32, height: 0),
            menuBarHeights: Self.bothMenuBarHeights))
    }

    /// 「已登记」与「未登记」两种状态的**高度差**必须真的能区分开。
    ///
    /// 2026-10-20 的实测对照（同一份探针、同一台机器）：
    /// - LaunchServices 启动（已登记）：`(1116, 1073, 32, 39)` → 高度 39
    /// - 直接执行（未登记）：    `(1678, 1090, 32, 22)` → 高度 22
    /// - 被毒化后 `open -a`：   `(0, -22, 32, 22)`    → 高度 22
    ///
    /// 三个真实值都拿来做断言，判据就不可能是碰巧对的。
    func testPlacementSeparatesRegisteredFromUnregisteredHeights() {
        let registered = NSRect(x: 1116, y: 1073, width: 32, height: 39)
        let directExec = NSRect(x: 1678, y: 1090, width: 32, height: 22)
        let poisoned = NSRect(x: 0, y: -22, width: 32, height: 22)

        XCTAssertTrue(StatusItemController.isPlaced(
            buttonFrame: registered, menuBarHeights: Self.bothMenuBarHeights))
        XCTAssertFalse(StatusItemController.isPlaced(
            buttonFrame: directExec, menuBarHeights: Self.bothMenuBarHeights))
        XCTAssertFalse(StatusItemController.isPlaced(
            buttonFrame: poisoned, menuBarHeights: Self.bothMenuBarHeights))
    }

    /// 高度判据对**真实状态栏项**也要成立：`isPlaced` 得真的去读按钮窗口的高度，
    /// 而不是闭着眼睛返回一个常量。
    ///
    /// 这里不让测试去规定「测试进程里应该是 true 还是 false」——那取决于有没有 bundle、
    /// 菜单栏有没有布局，是环境决定的。只要求两者一致。
    func testPlacementOfTheRealStatusItemMatchesItsOwnFrame() throws {
        let delegate = makeLaunchedDelegate()
        defer { dispose(delegate) }

        let item = try XCTUnwrap(delegate.statusItem)
        let window = item.rawButtonWindow
        let expected = StatusItemController.isPlaced(
            buttonFrame: window?.frame,
            menuBarHeights: StatusItemController.menuBarHeights)
        XCTAssertEqual(item.isPlaced, expected,
                       "isPlaced 必须由按钮窗口的真实高度算出来")
    }

    // MARK: - 关窗不退出

    func testClosingTheWindowKeepsWindowObjectStatusItemAndMenuAlive() throws {
        let app = NSApplication.shared
        let delegate = makeLaunchedDelegate()
        defer { dispose(delegate) }

        let window = try XCTUnwrap(delegate.window)
        let statusItem = try XCTUnwrap(delegate.statusItem)
        XCTAssertTrue(window.isVisible, "启动后主窗口应当是可见的")

        // ⚠️ 这条断言**必须在 close() 之前**，否则它是空的。
        // AppKit 在 `close()` 里会把 `isReleasedWhenClosed` 复位成 false
        // （实测：设为 true → 读到 true → close() 之后读到 false）。
        // 放在关窗后读，无论原来设成什么都会得到 false——断言恒真，挡不住任何回归。
        //
        // 另外，这是**标志位断言，不是行为证明**：在 macOS 26.6.2 上实测，
        // true/false 观测不到任何差异（NSWindow 被内部视图树间接持有，
        // 引用计数 700 上下，单发一次 release 落不到 0），跑真事件循环排空
        // autorelease pool 也一样。见 scripts/probes/window-release/。
        XCTAssertFalse(
            window.isReleasedWhenClosed,
            "窗口不该在关闭时自己释放自己（语义纠正；行为差异观测不到，故只能这样钉）")

        window.close()

        XCTAssertFalse(window.isVisible, "关窗后主窗口应当收起来")
        XCTAssertNotNil(delegate.window, "窗口对象必须还活着")

        XCTAssertFalse(
            delegate.applicationShouldTerminateAfterLastWindowClosed(app),
            "关掉窗口不能让程序退出——录音要在状态栏里继续")

        let frameAfterClose = try XCTUnwrap(
            statusItem.buttonWindowFrame, "关窗后状态栏图标不能跟着消失")
        XCTAssertGreaterThan(frameAfterClose.width, 0)

        // 关窗之后再点状态栏：菜单重建必须不炸，而且还能给出操作项。
        // 「关掉窗口之后程序没反应」这类故障就出在这条路径上。
        let menu = NSMenu()
        statusItem.menuNeedsUpdate(menu)
        XCTAssertTrue(
            menu.items.contains { $0.title == "开始录制" },
            "关窗后状态栏菜单应当仍能重建出操作项，实际只有：\(menu.items.map(\.title))")
    }

    func testReopenAfterCloseActuallyBringsTheWindowBack() throws {
        let app = NSApplication.shared
        let delegate = makeLaunchedDelegate()
        defer { dispose(delegate) }

        let window = try XCTUnwrap(delegate.window)
        window.close()
        XCTAssertFalse(window.isVisible)

        // 点 Dock 图标。只返回 true 而窗口不回来，用户会觉得程序已经退出了。
        _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false)
        XCTAssertTrue(window.isVisible, "重开时必须把窗口真的放回屏幕上")
    }

    // MARK: - 快捷键

    func testLaunchRegistersAllFourHotKeys() throws {
        let delegate = makeLaunchedDelegate()
        defer { dispose(delegate) }

        let hotKeys = try XCTUnwrap(delegate.hotKeys, "启动时必须装上全局热键")
        XCTAssertEqual(hotKeys.failures, [], Self.registrationHint)
    }

    func testInjectedHotKeyEventsReachTheBoundActions() {
        var fired: [UInt32] = []
        let hotKeys = GlobalHotKeys(bindings: [
            .init(name: "一", display: "⌥⌘R",
                  keyCode: GlobalHotKeys.keyR, modifiers: GlobalHotKeys.commandOption) {
                fired.append(1)
            },
            .init(name: "二", display: "⌥⌘P",
                  keyCode: GlobalHotKeys.keyP, modifiers: GlobalHotKeys.commandOption) {
                fired.append(2)
            },
        ])
        defer { hotKeys.invalidate() }
        XCTAssertEqual(hotKeys.failures, [], Self.registrationHint)

        XCTAssertEqual(injectHotKey(id: 1), noErr)
        XCTAssertEqual(injectHotKey(id: 2), noErr)
        XCTAssertEqual(fired, [1, 2], "热键事件必须按 id 派发到对应的动作上")
    }

    func testHotKeyWithUnknownIDTriggersNothing() {
        var fired = 0
        let hotKeys = GlobalHotKeys(bindings: [
            .init(name: "一", display: "⌥⌘R",
                  keyCode: GlobalHotKeys.keyR, modifiers: GlobalHotKeys.commandOption) {
                fired += 1
            },
        ])
        defer { hotKeys.invalidate() }

        _ = injectHotKey(id: 99)          // 我们没注册过这个 id
        XCTAssertEqual(fired, 0, "没注册过的 id 不能触发任何动作")
    }

    /// 同进程里别的组件也会把热键事件投到同一个事件目标上。
    /// 不校验签名的话，对方 id 撞上 1 就会误触发我们的「开始录制」。
    func testHotKeyWithForeignSignatureIsIgnored() {
        var fired = 0
        let hotKeys = GlobalHotKeys(bindings: [
            .init(name: "一", display: "⌥⌘R",
                  keyCode: GlobalHotKeys.keyR, modifiers: GlobalHotKeys.commandOption) {
                fired += 1
            },
        ])
        defer { hotKeys.invalidate() }

        // 外来签名的 id 故意撞成 1，也就是我们「开始录制」的 id。
        // 返回 `eventNotHandledErr` 说明 handler 把它退回去了、没人认领——
        // 比只看计数器更有力：计数器为 0 也可能是因为事件根没送到。
        let foreignStatus = injectHotKey(id: 1, signature: 0x5858_5858)   // 'XXXX'
        XCTAssertEqual(foreignStatus, OSStatus(eventNotHandledErr),
                       "外来签名的热键必须被退回（没人认领）")
        XCTAssertEqual(fired, 0, "外来签名的热键事件不能触发我们的动作")

        let ownStatus = injectHotKey(id: 1)            // 自己的签名仍然要通
        XCTAssertEqual(ownStatus, noErr)
        XCTAssertEqual(fired, 1, "自己的签名必须能触发——否则上面那条是假通过")
    }

    /// 端到端：真 `AppDelegate` 的绑定顺序是 R / P / S / M，
    /// 第 4 个（id=4）是「显示/隐藏窗口」——它不需要麦克风权限，
    /// 是四个动作里唯一能在测试里安全观察的一个。
    func testRealDelegatesFourthBindingTogglesTheWindow() throws {
        let delegate = makeLaunchedDelegate()
        defer { dispose(delegate) }

        let window = try XCTUnwrap(delegate.window)
        XCTAssertTrue(window.isVisible)

        // `toggleWindow` 的分支条件是「可见 **且** 是 key 窗口」才收起。
        // 测试进程不是个真 bundle，拿不拿得到 key 状态不一定，所以两个分支
        // 各自钉一条明确的行——不留「怎么都对」的空断言。
        let wasKey = window.isKeyWindow
        _ = injectHotKey(id: 4)

        if wasKey {
            XCTAssertFalse(window.isVisible, "窗口可见且是 key 时，⌥⌘M 应当把它收起来")
        } else {
            XCTAssertTrue(
                window.isVisible,
                "窗口不是 key 时，⌥⌘M 只该把它叫到前台，不该把可见的窗口反手藏掉")
        }
    }
}