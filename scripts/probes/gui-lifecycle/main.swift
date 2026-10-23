// 图形界面的生命周期探针：在**真实的 `NSApplication.run()` 循环**里驱动**真实的
// `AppDelegate`**，逐条验证用户提的几件事——
//
//   1) 录音标题自动带上时间序号（会议202607271624 这种）
//   2) 关掉窗口不退出、状态栏常驻小工具、全局快捷键能起/停/暂停录音
//   3) 录制中可以把状态栏上的计时/录音标识关掉（「静默录制」），
//      且**菜单仍然如实**、录音本身不受影响
//
// ## 为什么必须写成独立探针，而不是单元测试
//
// 这几条都要真 `run()` 才成立。手工 pump `nextEvent`/`sendEvent` 走不到
// 「最后一个窗口关闭」那条分支（阳性对照也不触发，见 ../terminate-policy/），
// 而测试进程不能交给一个永不返回的 `run()`。
//
// UI 自动化也用不了：`osascript`/`System Events` 在本机被 TCC 拦住（-10004）；
// `CGEvent` 投递需要「辅助功能」授权，被拒后静默失效。
// 所以按键从 `kEventHotKeyPressed` 事件开始注入——跳过「物理按键 → WindowServer」，
// 覆盖「事件 → Carbon handler → 动作 → 状态机 → 界面 → 落盘」这整段。
//
// ## 编排方式：轮询，不是固定 sleep
//
// 所有等待都写成「轮询到条件成立，超时才算失败」。固定 sleep 会犯两种错：
// 开始时设备没就绪（按了暂停但相位还是 .preparing，而暂停按设计只在 .recording
// 生效，于是被忽略）；结尾时文件还没 finalize（断言检查到半成品）。
// 这两种都是**夹具在骗人**——第一版就是栽在这里，报出两条假失败。
//
// ## 编译与运行
//
//   cd meeting-recorder
//   swift build --disable-sandbox
//   swiftc -O -I .build/debug -o /tmp/mr-gui-probe scripts/probes/gui-lifecycle/main.swift \
//     .build/debug/MRCore.o .build/debug/MRCapture.o .build/debug/MRTranscribe.o \
//     .build/debug/MRSession.o .build/debug/MRGUI.o
//
//   ROOT=$(mktemp -d) MEETING_RECORDER_ROOT=$ROOT /tmp/mr-gui-probe
//   ROOT=$(mktemp -d) MEETING_RECORDER_ROOT=$ROOT /tmp/mr-gui-probe --control-terminate
//   ROOT=$(mktemp -d) MEETING_RECORDER_ROOT=$ROOT /tmp/mr-gui-probe --slow   # 留出截图时间
//
// ## ⚠️ 上面这条编译命令在 2026-09-29 的 Xcode/SDK 上已经失效（别照抄）
//
// 实测它现在必然以链接错误收场：
//   ld: warning: cannot link directly with 'SwiftUICore' because product being built
//       is not an allowed client of it
//   clang: error: linker command failed with exit code 1
// （`swift build` / `swift test` 不受影响——它们走 SwiftPM 自己的链接路径。）
//
// 在本环境下可用的替代做法：把要验的东西写成 `Tests/MRGUITests/` 里的一个用例。
// `@testable import MRGUI` 拿得到同一批 internal 对象（`AppDelegate`、`window`、
// `statusItem`、`SenseVoiceAssetsModel`…），用
//   swift test --disable-sandbox --filter <用例名>
// 跑。2026-09-29 用此法量到真实 `AppDelegate.window.frame = (295, 192, 1120, 752)`、
// `isVisible = true`，与本文档描述的窗口尺寸一致。
//
// 另：`screencapture` 的 `-R`（区域）与 `-l`（按窗口 id）在本机当前权限下会分别报
// 「could not create image from rect / from window」，只有整屏能截且内容近似壁纸——
// 也就是说**自动化进程拿不到屏幕录制授权**。界面级证据改走 `ImageRenderer`
// 渲染（见 `Tests/MRGUITests/SenseVoiceAssetsViewTests.swift`），产出的是
// 纯应用界面位图，不含桌面其它内容。
//
// `--control-terminate` 是**阳性对照**：它主动调用 `NSApp.terminate`，
// 必须导致 RESULT 打不出来。对照立不住，正文的「应用还在运行」就毫无信息量。
// `--slow` 会在两个截图点各停 6 秒，配合外面的 `screencapture` 用。
import AppKit
import Carbon
// 探针与 MRGUI 是两个模块，被验证的东西（AppDelegate / StatusItemController /
// GlobalHotKeys）都是 internal 的。SwiftPM 的 debug 构建带 `-enable-testing`，
// `@testable` 能把它们露出来——探针由此驱动的是**真实对象**而不是仿制品。
@testable import MRGUI
import MRSession
import MRCore

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - 记录与断言

var failures: [String] = []
var notes: [String] = []

func check(_ condition: Bool, _ description: String) {
    if condition {
        print("  ✅ \(description)")
    } else {
        print("  ❌ \(description)")
        failures.append(description)
    }
}

func note(_ line: String) {
    notes.append(line)
    print("  · \(line)")
}

func section(_ title: String) {
    print("\n\(title)")
}

// MARK: - 主流程

@MainActor
final class Probe: NSObject, NSApplicationDelegate {

    let isControl: Bool
    /// `--slow`：在两个关键时刻各停几秒，好让外面用 `screencapture` 拍下
    /// 「计时在 / 计时没了」这两帧。
    ///
    /// 为什么需要它：断言能证明按钮的**属性**对了，证明不了屏幕上那 32 点宽的图标
    /// 到底长什么样。而这个功能的失败形态恰恰是「属性都对、屏幕上还红着」——
    /// 比如图标名字打错一个字母，`NSImage(systemSymbolName:)` 会返回 nil，
    /// 于是按钮上只剩计时、没有图标，而所有关于 `symbolName` 的断言照样绿。
    let isSlow: Bool
    var window: NSWindow?
    var statusItem: StatusItemController?
    var hotKeys: GlobalHotKeys?
    private var appDelegate: AppDelegate?

    // 轮询状态
    private var pollCondition: (() -> Bool)?
    private var pollOnSuccess: (() -> Void)?
    private var pollOnTimeout: (() -> Void)?
    private var pollDeadline = Date()

    init(control: Bool, slow: Bool) {
        self.isControl = control
        self.isSlow = slow
    }

    /// 让出主线程几秒，**但保持事件循环活着**。
    ///
    /// 刻意不用 `Thread.sleep`：那会把主线程连同绘制一起冻住，
    /// 拍到的可能是一帧没画完的菜单栏。`RunLoop.run(until:)` 里定时器照跑、
    /// 重绘照做，只是我们不去推进探针的下一步。
    private func hold(_ seconds: TimeInterval) {
        guard isSlow else { return }
        note("（--slow）停 \(Int(seconds)) 秒，留出截图时间")
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private var app: NSApplication { NSApplication.shared }

    /// 状态栏菜单首行——它就是「用户此刻看到的状态」。
    /// 刻意从这里读相位，而不是去掏 `RecordingController` 的内部属性：
    /// 掏内部状态只能证明「状态机对了」，看菜单才能证明「用户看到的对了」。
    private var header: String {
        guard let statusItem else { return "<没有状态栏项>" }
        let menu = NSMenu()
        statusItem.menuNeedsUpdate(menu)
        return menu.items.first?.title ?? ""
    }

    /// 菜单里所有项的标题，**含子菜单**。
    ///
    /// 2026-10-14 起设置项被收进「录音设置 / 存储与清理 / 隐私」三个子菜单，
    /// 所以这里必须递归摊平。只打顶层的话，探针的输出里会看不到
    /// 「16 位录音」这些项，于是**一次归类改动看起来就像「功能被删了」**——
    /// 而实际上它们只是往下挪了一层。
    private func menuTitles() -> [String] {
        guard let statusItem else { return [] }
        let menu = NSMenu()
        statusItem.menuNeedsUpdate(menu)
        return flatten(menu, depth: 8).map(\.title)
    }

    /// 递归摊平菜单树。写成嵌套函数而不是 `let walk = { … walk(…) }`：
    /// 后者会捕获自己，Swift 不允许在声明处引用尚未初始化的局部变量。
    private func flatten(_ menu: NSMenu, depth: Int) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        func walk(_ m: NSMenu, _ d: Int) {
            for item in m.items {
                out.append(item)
                if d > 0, let sub = item.submenu { walk(sub, d - 1) }
            }
        }
        walk(menu, depth)
        return out
    }

    /// 在整棵菜单树里按标题找一项。
    ///
    /// 递归的理由与 `Tests/MRGUITests/MenuLookup.swift` 完全一样：
    /// 「这个开关还在、还接对动作」是不变量，「它在一级还是三级」是产品决定。
    /// 把查找写成递归，将来再调层级不必回来改这里。
    private func menuItem(_ title: String) -> NSMenuItem? {
        guard let statusItem else { return nil }
        let menu = NSMenu()
        statusItem.menuNeedsUpdate(menu)
        return flatten(menu, depth: 8).first { $0.title == title }
    }

    // MARK: - 主窗口里「用户看得见的东西」

    /// **这一段为什么最后落在了位图对比上，记一笔。**
    ///
    /// 最初想走无障碍树把窗口里的文字抓出来断言。实测 `windowStrings()` 恒为空——
    /// SwiftUI 的内容挂在 `NSHostingView` 上，而本机的探针进程没有「辅助功能」授权，
    /// 无障碍树根本铺不开。这不是产品的问题，是取证手段在本机走不通
    /// （和 `osascript`/System Events 被 TCC 拦掉是同一件事）。
    ///
    /// 于是判据换成与单元测试同一套的「窗口真的重绘了」：
    /// 状态变化前后各取一张位图，逐字节比较。它证明的是「窗口跟着状态变了」，
    /// **证明不了**窗口里写的是哪几个字——那部分由截图承担
    /// （`captureWindow` 的 backing store 截图 + 外部 `screencapture` 的真实屏幕截图），
    /// 两者分开记账，谁也不冒充谁。
    private var lastWindowShot: Data?

    /// 主窗口此刻的像素（走窗口自己的 backing store）。
    private func windowShot() -> Data? {
        guard let view = window?.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// 断言主窗口在状态变化之后真的重绘了。
    ///
    /// **这条判据有已知的弱面，写在这里而不是藏在注释里**：任何一次重绘都会让
    /// 位图不同，所以「列表刷新」这类无关变化也能让它通过。补救靠两件事：
    /// 截图存档人工可查（见上），以及同一条链路在单元测试里已经有更细的断言。
    /// 这里要抓的正是单元测试抓不到的那一段——AppDelegate 建出来的**真窗口**。
    private func checkWindowRepaints(_ label: String) {
        // SwiftUI 收到变化后不是同步重绘，得让它走完一个显示周期
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let shot = windowShot() else {
            check(false, "\(label)：取不到主窗口的位图")
            return
        }
        check(shot != lastWindowShot,
              label + "（位图字节数 \(shot.count)）")
        lastWindowShot = shot
    }

    private func captureWindow(named name: String) {
        guard let window, let view = window.contentView else { return }
        let url = Probe.docsDirectory.appendingPathComponent(name)

        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            note("⚠️ 没能拍下窗口：\(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            note("⚠️ 窗口截图转不出 PNG：\(name)")
            return
        }
        do {
            try png.write(to: url)
            note("已存窗口截图 \(name)（来源：窗口 backing store，非 WindowServer）")
        } catch {
            note("⚠️ 窗口截图写盘失败：\(error)")
        }
    }

    /// 把窗口号写出去，好让外面用 `screencapture -l` 拍一张真的屏幕截图。
    ///
    /// `screencapture` 走 WindowServer，拍的是屏幕上真有的像素；它与
    /// `captureWindow` 的 backing store 截图是**两种不同强度的证据**，
    /// 上一轮靠这个差别抓出了一个真缺陷。两者缺一不可。
    private func writeWindowIDForExternalCapture(_ label: String) {
        guard let window else { return }
        let marker = Probe.docsDirectory.deletingLastPathComponent()
            .appendingPathComponent(".probe-window-id")
        try? "\(window.windowNumber)".write(to: marker, atomically: true, encoding: .utf8)
        note("窗口号 \(window.windowNumber) 已写出（\(label)），"
             + "外面可用 screencapture -l 拍真实屏幕")
    }

    private static var docsDirectory: URL {
        // 探针从仓库根跑，docs 与它同级
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 用真实的 AppDelegate——不是仿制品。它自己会建窗口、状态栏项、热键。
        //
        // ⚠️ 必须显式把启动通知转发给它：`NSApp.delegate` 只有一个（探针自己），
        // 内层的 AppDelegate 只是个普通对象，不会自动收到 `didFinishLaunching`。
        // 少了这一行，窗口/状态栏/热键全是 nil，看起来像产品坏了，其实是探针没启动应用。
        let delegate = AppDelegate()
        appDelegate = delegate
        delegate.applicationDidFinishLaunching(notification)
        window = delegate.window
        statusItem = delegate.statusItem
        hotKeys = delegate.hotKeys

        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
            MainActor.assumeIsolated { self.startupChecks() }
        }
        Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { _ in
            MainActor.assumeIsolated { self.closeWindowStep() }
        }
    }

    // MARK: 阶段 1 —— 启动后的初始状态

    func startupChecks() {
        section("[1] 启动后的初始状态")

        guard let statusItem else {
            check(false, "AppDelegate 应当持有一个状态栏项")
            finish()
            return
        }
        check(true, "AppDelegate 持有一个状态栏项")

        if let frame = statusItem.buttonWindowFrame {
            note("状态栏按钮 frame = \(frame)（屏幕 \(NSScreen.main?.frame.size ?? .zero)）")
            // 真 run() 里菜单栏**会**布局它。这是与单元测试最大的区别：
            // 测试进程里量到的是 (0, 0, 32, 0)，高度为 0，什么都证明不了。
            check(frame.height > 0, "状态栏按钮已被菜单栏布局（高度 > 0）")
            if let screen = NSScreen.main {
                check(frame.maxY > screen.frame.maxY - 60,
                      "状态栏图标贴在屏幕顶端菜单栏区域，实测 maxY=\(frame.maxY)")
                check(frame.midX > screen.frame.midX,
                      "状态栏图标在屏幕右半边（菜单栏图标区），实测 midX=\(frame.midX)")
            }
        } else {
            check(false, "状态栏按钮窗口不存在——图标根本没挂上菜单栏")
        }

        check(hotKeys?.failures.isEmpty ?? false,
              "四组全局快捷键全部注册成功（失败项：\(hotKeys?.failures ?? ["没有 hotKeys"])）")
        check(window?.isVisible ?? false, "主窗口应当可见")
        note("状态栏菜单：\(menuTitles())")

        // 留一张**空闲态**的窗口位图当基线。后面 [3.7] 要拿它证明「开始录制之后
        // 窗口真的变了」——没有基线，那条「重绘了」就是空话。
        lastWindowShot = windowShot()
        note("已留存空闲态窗口位图（\(lastWindowShot?.count ?? 0) 字节）作为重绘对比基线")
    }

    // MARK: 阶段 2 —— 关窗不退出

    func closeWindowStep() {
        guard statusItem != nil else { return }

        if isControl {
            section("[2] 阳性对照：直接让应用终止")
            note("调用 NSApp.terminate。若 run() 真的会被打断，下面的 RESULT 就不该出现")
            app.terminate(nil)
            return
        }

        section("[2] 关掉主窗口（需求：关闭窗口后不直接退出）")
        check(window?.isVisible ?? false, "关窗前窗口可见")
        window?.close()
        note("已调用 window.close()，这是真实的关窗路径")

        check(window?.isVisible == false, "关窗后窗口已收起")
        check(window != nil, "窗口对象仍然存活（没被关窗动作连带释放）")
        check(statusItem?.buttonWindowFrame != nil, "关窗后状态栏图标仍在")
        check(app.isRunning, "关窗后应用仍在运行 —— 这就是「不直接退出」")

        let titles = menuTitles()
        check(titles.contains("开始录制"), "关窗后状态栏菜单仍能重建出操作项")
        check(titles.contains("显示主窗口"), "菜单里保留「显示主窗口」")

        // 关窗之后才是真正的考验：录音只能靠快捷键起，键盘上什么都没有。
        section("[3] 关窗之后用全局快捷键开始录音")
        pressHotKey(id: 1, "⌥⌘R")

        poll(until: { self.header.contains("录制中") },
             timeout: 15, interval: 0.4,
             onSuccess: {
                 check(true, "⌥⌘R 之后进入了录制态，首行「\(self.header)」")
                 self.concealStep()
             },
             onTimeout: {
                 check(false, "⌥⌘R 之后 15 秒内没进入录制态，首行停在「\(self.header)」。"
                       + "最可能是这个探针进程没有麦克风授权"
                       + "（TCC 按 bundle 身份记账，命令行可执行文件不是 .app）")
                 self.stopStep(expectPause: false)
             })
    }

    // MARK: 阶段 3.5 —— 静默录制：录制期间菜单栏上不留录音痕迹

    /// 需求 3：录制过程中可以关掉状态栏上的计时/录音标识。
    ///
    /// 为什么这条非要在真 `run()` 里过一遍：`StatusItemController` 的初始化里
    /// 有一段**跳一个主 actor 回合**再刷新的写法（`@Published` 是在 `willSet` 里
    /// 发值的，同步刷新画的是上一帧）。那一段在单元测试里能验，但「真的挂在菜单栏上
    /// 的那个按钮」会不会跟着变，只有在菜单栏真的布局过、定时器真的在跑的进程里
    /// 才有意义。
    func concealStep() {
        section("[3.5] 录制中打开「静默录制」，菜单栏上不该再有任何录音痕迹")

        guard let statusItem else {
            check(false, "没有状态栏项，无法验证")
            pauseStep()
            return
        }

        // 上一次跑挂了可能把它留在「已打开」，先复位。探针要能反复跑，
        // 不然第二次运行会红在一个跟产品无关的地方——那种红会训练人忽略探针。
        if let item = menuItem(StatusItemController.concealMenuTitle),
           item.state == .on, let action = item.action {
            _ = NSApp.sendAction(action, to: item.target, from: item)
            note("上一次运行把它留在「已打开」了，先复位")
        }

        let titleBefore = statusItem.buttonTitle ?? ""
        check(!titleBefore.isEmpty, "前置条件：此刻菜单栏上有计时（实测「\(titleBefore)」）")
        let shapeBefore = statusItem.lastAppearance?.symbolName ?? "?"
        hold(6)   // 截图点 ①：标准模式下「计时在」

        guard let item = menuItem(StatusItemController.concealMenuTitle) else {
            check(false, "状态栏菜单里找不到「\(StatusItemController.concealMenuTitle)」，"
                  + "实际只有：\(menuTitles())")
            pauseStep()
            return
        }
        guard let action = item.action, item.target != nil else {
            check(false, "「\(StatusItemController.concealMenuTitle)」没接动作或没接 target，点了不会有反应")
            pauseStep()
            return
        }
        _ = NSApp.sendAction(action, to: item.target, from: item)
        note("从菜单点了「\(StatusItemController.concealMenuTitle)」，"
             + "菜单项状态 \(item.state == .on ? "已勾上" : "未勾")")

        // 这里等的是「计时器刷新过之后仍然没有字」，而不是「某一刻恰好没字」：
        // 录音中 `elapsed` 每 0.5 秒发布一次，每次都会重画按钮。
        poll(until: { (statusItem.buttonTitle ?? "").isEmpty },
             timeout: 4, interval: 0.2,
             onSuccess: {
                 check(true, "菜单栏上的计时消失了（图标 \(shapeBefore) → "
                       + "\(statusItem.lastAppearance?.symbolName ?? "?")，文字「\(titleBefore)」→ 空）")
                 check(statusItem.lastAppearance == StatusItemController.concealedAppearance,
                       "外观整份换成了中性值：\(String(describing: statusItem.lastAppearance))")
                 // 菜单是**主动点开**才看得见的，藏的是被动可见的那部分。
                 // 连菜单也藏掉，用户就彻底失去「有没有在录」的答案了。
                 check(self.header.contains("录制中"),
                       "菜单首行仍如实显示「\(self.header)」")
                 self.hold(6)   // 截图点 ②：隐藏模式下「计时没了」
                 self.concealCanBeTurnedOffStep()
             },
             onTimeout: {
                 check(false, "4 秒内计时没消失，按钮上仍写着「\(statusItem.buttonTitle ?? "")」")
                 self.concealCanBeTurnedOffStep()
             })
    }

    /// 关得回去，而且**录音本身没被动过**。
    ///
    /// 少了这一步，一个「打开之后再也回不来」的实现也能让上面全绿；
    /// 而「开关会不会把录音一起关掉」是这个功能唯一危险的失效方式。
    func concealCanBeTurnedOffStep() {
        guard let statusItem, let item = menuItem(StatusItemController.concealMenuTitle),
              let action = item.action else {
            check(false, "拿不到菜单项，无法关闭开关")
            pauseStep()
            return
        }
        check(item.state == .on, "菜单上那一项已经勾上（用户下次点开能看到）")
        _ = NSApp.sendAction(action, to: item.target, from: item)

        poll(until: { (statusItem.buttonTitle ?? "").isEmpty == false },
             timeout: 4, interval: 0.2,
             onSuccess: {
                 check(true, "关掉开关后计时回来了（「\(statusItem.buttonTitle ?? "")」）")
                 check(statusItem.lastAppearance?.tint == .some(.red),
                       "图标回到红色录制标识，实测 \(String(describing: statusItem.lastAppearance?.tint))")
                 self.windowFollowsStateStep()
             },
             onTimeout: {
                 check(false, "关掉开关之后计时没回来")
                 self.windowFollowsStateStep()
             })
    }

    // MARK: 阶段 3.7 —— 主窗口必须跟着状态机走（需求 2）

    /// 需求 2：开始 / 暂停 / 停止之后，App 界面上必须实时更新状态。
    ///
    /// 这一段**非得在真 `run()` 里跑不可**。单元测试里那个窗口是我们自己 new 的
    /// `NSWindow`；这里是 AppDelegate 建出来的真窗口。两者的 SwiftUI 更新机制
    /// 是不是同一套、订阅有没有真的接上，只有把真的跑起来才知道——
    /// 上一轮那个「所有属性都对、屏幕上却是黑的」的坑就是这么挖出来的。
    func windowFollowsStateStep() {
        section("[3.7] 把窗口叫回来，看它是不是跟着状态机走")

        // 阶段 2 关掉窗口之后就再没回来过，先用 ⌥⌘M 叫它回来
        pressHotKey(id: 4, "⌥⌘M")

        poll(until: { self.window?.isVisible ?? false },
             timeout: 5, interval: 0.2,
             onSuccess: {
                 check(true, "⌥⌘M 之后主窗口可见")
                 self.checkWindowRepaints("""
                     状态机已在录制中，主窗口也跟着变了——这就是「界面实时更新」（需求 2）。
                     窗口里此刻写着什么由下面的截图承担，位图对比只证明它重绘了
                     """)
                 self.captureWindow(named: "gui-13-录制中-窗口实时显示录制中.png")
                 self.pauseStep()
             },
             onTimeout: {
                 check(false, "⌥⌘M 之后 5 秒内主窗口没回来，无法检查界面")
                 self.pauseStep()
             })
    }

    // MARK: 阶段 4 —— 暂停 / 继续

    func pauseStep() {
        section("[4] 用快捷键暂停")
        pressHotKey(id: 2, "⌥⌘P")

        poll(until: { self.header.contains("已暂停") },
             timeout: 6, interval: 0.2,
             onSuccess: {
                 check(true, "⌥⌘P 之后进入暂停态，首行「\(self.header)」")
                 check(self.menuItem("继续录制") != nil,
                            "暂停后菜单里出现「继续录制」（而不是还写着「暂停录制」）")

                 // 用户报的第 1 条就在这里：界面上如果还停在「录制中 + 暂停按钮」，
                 // 那个「暂停」按下去没有任何反应（状态机只在 .recording 生效），
                 // 于是唯一还能按的只剩「停止」。
                 self.checkWindowRepaints("""
                     暂停之后主窗口重绘了——不是还停在「录制中 + 暂停按钮」。
                     窗口此刻应写着「已暂停」并出现「继续」按钮，由下面的截图承担
                     """)
                 self.captureWindow(named: "gui-14-暂停后-窗口显示已暂停与继续.png")
                 // 停一会儿并交出窗口号：外面用 `screencapture -l` 拍一张走 WindowServer 的
                 self.writeWindowIDForExternalCapture("已暂停这一帧")
                 self.hold(8)
                 self.resumeStep()
             },
             onTimeout: {
                 check(false, "⌥⌘P 之后 6 秒内没进入暂停态，首行停在「\(self.header)」")
                 self.stopStep(expectPause: false)
             })
    }

    func resumeStep() {
        pressHotKey(id: 2, "⌥⌘P")
        poll(until: { self.header.contains("录制中") },
             timeout: 6, interval: 0.2,
             onSuccess: {
                 check(true, "再按一次回到录制态，首行「\(self.header)」")
                 self.checkWindowRepaints("主窗口跟着回到「录制中」——这就是「暂停之后还能继续」")
                 self.stopStep(expectPause: true)
             },
             onTimeout: {
                 check(false, "继续之后 6 秒内没回到录制态，首行「\(self.header)」")
                 self.stopStep(expectPause: false)
             })
    }

    // MARK: 阶段 5 —— 停止并检查落盘

    func stopStep(expectPause: Bool) {
        section("[5] 用快捷键停止，然后检查真的落了盘")
        pressHotKey(id: 3, "⌥⌘S")

        let root = SessionStore.defaultRoot()
        poll(until: { Probe.finalizedSession(in: root) != nil },
             timeout: 25, interval: 0.4,
             onSuccess: {
                 guard let url = Probe.finalizedSession(in: root) else { return }
                 check(true, "会议已落盘并 finalize：\(url.lastPathComponent)")
                 self.checkAutoTitle(url)
                 self.checkManifest(url, expectPause: expectPause)
                 self.windowToggleStep()
             },
             onTimeout: {
                 check(false, "25 秒内 \(root.path) 里没有出现已 finalize 的会议")
                 self.windowToggleStep()
             })
    }

    /// 需求 1：标题必须自带 `yyyyMMddHHmm` 时间序号。
    ///
    /// 以 **manifest 里的 `title` 字段**为权威值，不去解析目录名：
    /// 目录名是 `<会话ID>`，而会话 ID 本身是 `<日期>-<时间>-<标题>`，
    /// 里面的 `-` 和标题里可能出现的 `-` 混在一起，切出来的是猜测不是事实。
    /// （第一版就是这么错的，把 `170628-会议202609271706` 当成了标题。）
    func checkAutoTitle(_ sessionURL: URL) {
        guard let data = try? Data(contentsOf: sessionURL.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String else {
            check(false, "manifest 里读不到 title")
            return
        }

        let matches = title.range(of: #"^会议\d{12}$"#, options: .regularExpression) != nil
        check(matches,
              "标题形如「会议202607271624」（前缀 + 12 位时间序号），实测「\(title)」")

        guard matches, let digitsRange = title.range(of: #"\d{12}$"#, options: .regularExpression)
        else { return }
        let digits = String(title[digitsRange])
        let now = SessionStore.titleStamp(for: Date())
        let previous = SessionStore.titleStamp(for: Date().addingTimeInterval(-60))
        check(digits == now || digits == previous,
              "序号对应的就是刚才那一刻（现在=\(now)，落盘=\(digits)）")

        check(sessionURL.lastPathComponent.hasSuffix(title),
              "目录名以标题结尾（会话 ID 的格式没变）：\(sessionURL.lastPathComponent)")
    }

    /// 暂停的那一段**不该在音频里**，但**必须记在 manifest 的 pauses 里**。
    func checkManifest(_ sessionURL: URL, expectPause: Bool) {
        guard let data = try? Data(contentsOf: sessionURL.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            check(false, "读不出 manifest.json")
            return
        }

        let pauses = json["pauses"] as? [[String: Any]] ?? []
        let tracks = json["tracks"] as? [[String: Any]] ?? []
        let frames = tracks.compactMap { $0["framesWritten"] as? Int }.max() ?? 0
        let rate = tracks.compactMap { $0["sampleRate"] as? Double }.first ?? 48000
        let contentSeconds = Double(frames) / rate

        note("state=\(json["state"] as? String ?? "?")，title=\(json["title"] as? String ?? "?")")
        note("\(json["startedAt"] as? String ?? "?") → \(json["endedAt"] as? String ?? "?")")
        note("pauses=\(pauses.count) 条，最长轨 \(frames) 帧 ≈ "
             + "\(String(format: "%.2f", contentSeconds)) 秒")

        check(frames > 0, "至少录到了音频（\(frames) 帧）")

        if expectPause {
            check(!pauses.isEmpty,
                  "暂停被记进了 manifest.pauses —— 音频里没有那一段，但时间轴必须记得")
            let total = pauses.reduce(0.0) { $0 + (($1["duration"] as? Double) ?? 0) }
            note("暂停总长 ≈ \(String(format: "%.2f", total)) 秒")
        }
    }

    // MARK: 阶段 6 —— 关着窗口时把窗口叫回来

    func windowToggleStep() {
        section("[6] 关着窗口时用 ⌥⌘M 把窗口叫回来")
        // [3.7] 已经把窗口叫回来过了，所以这里先关掉再按——
        // 否则「⌥⌘M 切换了可见性」这条断言会被前面那一步吃掉。
        window?.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let before = window?.isVisible ?? false
        pressHotKey(id: 4, "⌥⌘M")
        poll(until: { (self.window?.isVisible ?? false) != before },
             timeout: 5, interval: 0.2,
             onSuccess: {
                 check(true, "⌥⌘M 真的切换了窗口可见性（\(before) → \(self.window?.isVisible ?? false)）")
                 self.finish()
             },
             onTimeout: {
                 check(false, "⌥⌘M 之后 5 秒内窗口可见性没变（\(before) → \(self.window?.isVisible ?? false)）")
                 self.finish()
             })
    }

    // MARK: 收尾

    func finish() {
        section("=== RESULT ===")
        print("失败断言：\(failures.count)")
        for failure in failures { print("  ❌ \(failure)") }
        for line in notes { print("  · \(line)") }
        print(failures.isEmpty ? "PROBE_PASS" : "PROBE_FAIL")
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - 轮询

    func poll(
        until condition: @escaping () -> Bool,
        timeout: TimeInterval,
        interval: TimeInterval,
        onSuccess: @escaping () -> Void,
        onTimeout: @escaping () -> Void
    ) {
        pollCondition = condition
        pollOnSuccess = onSuccess
        pollOnTimeout = onTimeout
        pollDeadline = Date().addingTimeInterval(timeout)

        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard let condition = self.pollCondition else { timer.invalidate(); return }
                if condition() {
                    timer.invalidate()
                    let success = self.pollOnSuccess
                    self.clearPoll()
                    success?()
                } else if Date() > self.pollDeadline {
                    timer.invalidate()
                    let failure = self.pollOnTimeout
                    self.clearPoll()
                    failure?()
                }
            }
        }
    }

    private func clearPoll() {
        pollCondition = nil
        pollOnSuccess = nil
        pollOnTimeout = nil
    }

    // MARK: - 热键事件注入

    /// 向应用事件目标注入一次「按下了某个热键」。
    /// 跳过「物理按键 → 事件」（要走 WindowServer / 辅助功能授权），
    /// 覆盖「事件 → Carbon handler → 动作」——我们自己写的那一段。
    func pressHotKey(id: UInt32, _ name: String) {
        var event: EventRef?
        let created = CreateEvent(
            nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event)
        guard created == noErr, let event else {
            check(false, "构造 \(name) 事件失败，OSStatus=\(created)")
            return
        }
        var hotKeyID = EventHotKeyID(signature: GlobalHotKeys.signature, id: id)
        SetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        let sent = SendEventToEventTarget(event, GetApplicationEventTarget())
        ReleaseEvent(event)
        check(sent == noErr, "\(name) 事件被应用事件目标认领")
        note("按下 \(name) → 状态栏首行「\(header)」")
    }

    // MARK: - 落盘查找

    /// 找到已 finalize 的那一场会议。
    static func finalizedSession(in root: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return nil }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifest = entry.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["state"] as? String == "finalized" else { continue }
            return entry
        }
        return nil
    }
}

// MARK: - 最小复现：精确重放 GUIRunner.run() 的启动路径
//
// 用来回答「为什么探针能测到状态栏图标、真应用却看不到」。
// 变量逐个开关，一次只动一个。
@MainActor
func runMinimal() {
    let variant = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "plain"
    let app = NSApplication.shared

    let delegate = AppDelegate()
    // 真应用是把它自己设成 NSApp.delegate；探针默认是外面再包一层。
    if variant == "outer" {
        // 保持 NSApp.delegate 为 nil，手动转发启动通知（探针的默认做法）
    } else {
        app.delegate = delegate
    }
    if variant == "regular" { app.setActivationPolicy(.regular) }
    if variant == "emptymenu" { app.mainMenu = NSMenu() }

    if variant == "outer" {
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
        MainActor.assumeIsolated {
            let frame = delegate.statusItem?.buttonWindowFrame
            print("MINIMAL variant=\(variant) frame=\(String(describing: frame))"
                  + " screens=\(NSScreen.screens.count)"
                  + " mainMenu=\(app.mainMenu?.items.count ?? -1)")
            exit(0)
        }
    }
    app.run()
}

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--minimal") { runMinimal(); return }
    let control = CommandLine.arguments.contains("--control-terminate")
    let slow = CommandLine.arguments.contains("--slow")

    Thread.detachNewThread {
        // 慢速档要多停两次，看门狗跟着放宽
        Thread.sleep(forTimeInterval: slow ? 120 : 60)
        FileHandle.standardError.write(Data("⏱ 看门狗：探针没有在预期时间内结束\n".utf8))
        exit(9)
    }

    let probe = Probe(control: control, slow: slow)
    let app = NSApplication.shared
    app.delegate = probe
    // 激活策略是可切换的：`.accessory`（无 Dock 图标、不抢前台）是探针默认；
    // 真应用走的是 `.regular`。这是探针与真应用之间**唯一**的行为差异，
    // 单独立一个开关，就是为了在「探针能测到图标、真应用看不到图标」时
    // 能一句话把它排除或坐实。
    app.setActivationPolicy(
        CommandLine.arguments.contains("--regular") ? .regular : .accessory)
    app.mainMenu = NSMenu()               // 没有它 ⌘Q 之类不工作，也让菜单栏结构完整

    print("=== 图形界面生命周期探针 ===")
    print("会议库根目录：\(SessionStore.defaultRoot().path)")
    print("模式：\(control ? "阳性对照（应当被终止）" : "正文")")
    app.run()

    // 只有 run() 真的被终止才会走到这里
    print("run() 返回了 → 应用被终止（对照模式下这是预期结果）")
    exit(control ? 0 : 3)
}
