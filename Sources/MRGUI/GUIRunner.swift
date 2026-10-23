import AppKit
import SwiftUI
import MRSession

/// 图形界面的宿主。
///
/// 用 AppKit 而不是 SwiftUI 的 `App` protocol，有两个具体原因：
/// 1. `App.main()` 是 `@MainActor` 且永不返回，从顶层同步代码调用会卡住 main actor；
/// 2. 需要精确控制**激活时机**——从终端或 Finder 启动时，不显式
///    `activate(ignoringOtherApps:)` 窗口可能停在后台，看起来就像「没启动」。
public enum GUIRunner {

    /// 跑起来，直到用户退出。**同步阻塞**，由 `main.swift` 调用。
    ///
    /// 整个启动过程必须在主 actor 上：`AppDelegate` 是主 actor 隔离的
    /// （它要建 `MeetingWorkspace`），而 AppKit 的一切也一样。
    /// `main.swift` 的顶层代码本来就跑在主线程上——它是程序入口，
    /// Windows 之外没有第二种可能——但编译器不认这一点。
    ///
    /// 所以这里用 `assumeIsolated` **把「必须在主线程」这件事写明**：
    /// 万一将来有人从别的线程调它，这里会直接断言失败，
    /// 而不是在一个没有主 actor 保护的现场里悄悄铺开整个 AppKit。
    public static func run() {
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            let delegate = AppDelegate()
            // delegate 必须被强引用住：NSApplication.delegate 是 weak，
            // 局部变量出作用域就释放，`applicationDidFinishLaunching` 永远不会被调到。
            GUIRunner.retainedDelegate = delegate
            application.delegate = delegate
            application.setActivationPolicy(.regular)
            // 打开状态栏落位的自检。放在 `run()` 之前：`finishLaunching` 是在
            // `run()` 里触发的，那时再设就晚了。
            AppDelegate.placementWatchEnabled = true
            // 这一行永不返回，直到用户退出
            application.run()
        }
    }

    /// 持有 delegate 的强引用（见上方说明）
    private static var retainedDelegate: AppDelegate?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // `private(set)` 而不是 `private`：这几个东西的「有没有活下来 / 有没有挂上去」
    // 只能从外部观察，测试要拿它们当断言对象（见 `StatusBarLifecycleTests`）。
    // 生产者仍然只有本类，对外不可写。
    private(set) var window: NSWindow?
    /// 整个界面共享的状态中枢。
    ///
    /// **必须建在这里，不能建在视图里。** 状态栏菜单与全局快捷键都要操作同一场录音，
    /// 视图内的 `@StateObject` 对外不可见，外面就只能再建一个——两份状态互不通报。
    private let workspace = MeetingWorkspace()
    private(set) var statusItem: StatusItemController?
    private(set) var hotKeys: GlobalHotKeys?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        buildWindow()
        // 设置窗口的回调先注入：录音面板里的「打开设置…」随时可能被点，
        // 而它拿不到 AppDelegate，只能经 workspace 转一手。
        workspace.onOpenSettings = { [weak self] in
            self?.showSettingsWindow(nil)
        }
        // 顺序要紧：快捷键先装，它的失败列表要喂给状态栏菜单显示。
        // 反过来的话状态栏会永远显示「没有失败」，因为那时 `hotKeys` 还是 nil。
        installHotKeys()
        installStatusItem()
        // 自动清理的三个触发点之一：启动。
        //
        // **放最后是有意的**——它会 `refresh()` 重扫会议库，而那要碰 TCC 保护的目录；
        // 放在窗口与状态栏都建好之后，重扫才有东西可更新。
        //
        // 与「转写完成」那个触发点靠 `RetentionAutoPruner` 的「今天跑过了吗」
        // 去重：同一天里两个触发点都到了，最多也只真删一次。
        workspace.runAutoPruneIfDue()
        reportAutoPruneIfNeeded()
    }

    /// 自动清理真的删了东西时，给一次事后说明。
    ///
    /// 只在**删到了**时才说话。「今天没有需要清理的」不弹窗——
    /// 那是绝大多数启动，用户不需要被告知「今天什么都没发生」。
    private func reportAutoPruneIfNeeded() {
        guard let report = workspace.lastAutoPruneReport,
              report.hasPrefix("已按保留策略清理") else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "已按保留策略清理旧录音"
        alert.informativeText = report
            + "\n\n删除走废纸篓，清空废纸篓就没有了。"
            // 提两条路而不是只提状态栏菜单：用户可能把菜单栏图标关掉了
            // （`showsStatusBarIcon`），那时状态栏菜单这条路根本不存在。
            + "想改成手动：设置窗口（⌘,）→「存储与清理」，"
            + "或状态栏菜单里的「\(StatusItemController.autoPruneMenuTitle)」。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 窗口

    private func buildWindow() {
        let content = NSHostingView(rootView: MeetingRecorderRootView(workspace: workspace))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "会议录音器"
        // 低于这个尺寸三栏就挤成一团了
        window.minSize = NSSize(width: 900, height: 580)
        // 程序化创建的 NSWindow 默认 `isReleasedWhenClosed = true`，意思是关窗时
        // 窗口会自己再发一次 `release`；而我们在 ARC 下还持有强引用，
        // 语义上就不该让窗口自己释放自己。
        //
        // 说清证据边界：在 macOS 26.6.2 上**复现不出**「过度释放导致崩溃」——
        // NSWindow 被内部视图树间接持有，`CFGetRetainCount` 量到 700 上下，
        // 关窗后对象照样存活，跑真事件循环排空 autorelease pool 也一样
        // （见 scripts/probes/window-release/）。所以这一行是**语义纠正 +
        // 防实现细节变化**，不是某个已复现崩溃的补丁。别把它说成后者。
        window.isReleasedWhenClosed = false
        window.contentView = content
        // 显式设一次内容尺寸：NSHostingView 会把 SwiftUI 的 `minHeight`
        // 当成首选高度报告给窗口，结果窗口只长到最小高度，
        // 而不是上面 contentRect 要求的 720。设置 contentView 之后再调一次才生效。
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        // 从终端启动时没有这一步，窗口会在后台，用户以为没反应
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关掉窗口**不退出程序**。
    ///
    /// 录音不能被窗口绑住：会议在别的应用里开着，用户完全可能先把窗口收起来。
    /// 关窗之后程序留在状态栏（`StatusItemController`），随时能按快捷键起停。
    ///
    /// **证据边界，别读错**：在 macOS 26.6.2 上用真 `NSApplication.run()` 实测，
    /// 委托**不实现**这个方法时 AppKit 的默认行为同样是不退出
    /// （三例对照见 `scripts/probes/terminate-policy/`，含阳性对照）。
    /// 所以这一行不是「让程序活下去的原因」，而是把意图写成代码：
    /// 默认行为会随 AppKit 版本、应用类型（文档型应用就不同）改变，
    /// 显式声明才不会哪天被系统悄悄改掉。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点 Dock 图标回到窗口。窗口关着的时候，这是用户最自然的「打开」动作，
    /// 不给回应会让人觉得程序已经退出了。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    private func showWindow() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggleWindow() {
        guard let window else { return }
        if window.isVisible, window.isKeyWindow {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    /// 主菜单里的「设置…」项。抽成静态构造**只为能测接线**。
    ///
    /// 抽出来量的就是三件事：⌘,（macOS 约定键位）、action 指向
    /// `showSettingsWindow`、**显式 target**。最后一条最关键：
    /// 靠响应链派发也能工作，那时能不能找到自定义方法取决于 AppKit 的转发细节，
    /// 而「⌘, 偶尔没反应」正是最难查的那一类症状。
    static func settingsMenuItem(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(
            title: "设置…", action: #selector(AppDelegate.showSettingsWindow(_:)),
            keyEquivalent: ",")
        item.target = target
        return item
    }

    // MARK: - 状态栏与快捷键

    private func installStatusItem() {
        statusItem = StatusItemController(
            workspace: workspace,
            hotKeyFailures: hotKeys?.failures ?? [],
            onShowWindow: { [weak self] in self?.showWindow() },
            onShowSettings: { [weak self] in self?.showSettingsWindow(nil) })
        // 把主窗口交给状态栏控制器：只用于诊断输出。
        //
        // 2026-10-20 复核：原来它是为了判断「图标与窗口是不是在同一块屏」，
        // 那个前提已被证伪——状态栏项在每块屏的菜单栏上各有一份、始终同步。
        statusItem?.mainWindow = window
        // 屏幕配置变化时重算一次提示（外接屏拔了、分辨率变了）。
        // 用 `didChangeScreen` 而不是 `didMove`：后者是用户拖窗口，
        // 而拖窗口不再影响状态栏项的位置，不该再触发重算。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.statusItem?.updateScreenHint() }
            }
        watchStatusItemPlacement()
    }

    /// 打开设置窗口。**⌘,、状态栏菜单、录音面板的「打开设置…」三条路都到这里。**
    ///
    /// `@objc` 是主菜单那条路必须的：菜单项的 target 为 nil 时靠响应链派发，
    /// 走的是 ObjC 运行时，纯 Swift 方法不在其中。
    @objc func showSettingsWindow(_ sender: Any?) {
        SettingsWindowController.shared.show(workspace: workspace)
    }

    /// 图标有没有真的挂到菜单栏上——没挂上就说出来，别静默。
    ///
    /// 这一条是被真实故障逼出来的：macOS 26.6.2 上，若这个 bundle id 被系统
    /// 拒绝登记状态栏项，`NSStatusItem.isVisible` 照样读回 `true`，
    /// 结果就是「双击打开，窗口正常，但菜单栏上什么都没有」。
    /// 复现与根因见 `scripts/probes/status-item-identity/`。
    ///
    /// 所以这里等一个 runloop 周期让菜单栏完成布局，然后量一次**高度**——
    /// 系统真登记了才会把按钮窗口拉到菜单栏那么高（判据见
    /// `StatusItemController.isPlaced(buttonFrame:menuBarHeights:)`）。
    ///
    /// 只在真事件循环里装（`placementWatchEnabled`）：测试进程的菜单栏从不布局，
    /// 量到的必然是「没放上去」，那是测试环境的必然结果、不是产品状态——
    /// 让它在每条测试里刷屏，只会把真正的告警淹掉。
    private func watchStatusItemPlacement() {
        guard AppDelegate.placementWatchEnabled else { return }
        // **用户主动藏掉图标时不告警。** 这一条自检查的是「系统没登记」，
        // 而 `showsStatusBarIcon == false` 是用户自己的选择——两者都会让
        // `isPlaced` 读回 false，但处理方式相反：一个是故障，一个是功能。
        // 少了这一问，用户关掉图标后会每次启动都看到一条吓人的警告。
        guard workspace.showsStatusBarIcon else { return }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let statusItem = self.statusItem else { return }
                // 图标是否真被系统登记——结果写进工作区，界面上的提示条据此显示。
                statusItem.updateScreenHint()
                // 诊断模式：**无论排没排上**都把内部状态倒出来。
                // 2026-10-20 那次卡在三处属性都说「在」而屏幕上没有的死结上，
                // 只有原始数据能分辨是哪一种故障。默认不开——正常用户不该看到这些。
                if ProcessInfo.processInfo.environment["MR_STATUS_ITEM_DEBUG"] != nil {
                    FileHandle.standardError.write(Data(
                        "\(statusItem.diagnosticSnapshot().description)\n".utf8))
                }
                guard !statusItem.isPlaced else { return }
                let frame = statusItem.buttonWindowFrame.map { "\($0)" } ?? "nil"
                FileHandle.standardError.write(Data("""
                ⚠️  系统没有把本应用登记进菜单栏（按钮窗口 = \(frame)），菜单栏上不会有它的图标。
                    快捷键不受影响，仍可用。
                    若反复出现，请退出应用后从访达双击重新打开——
                    直接运行 .app 里的二进制会让系统永久拒绝登记本应用。

                """.utf8))
            }
        }
    }

    /// 见 `watchStatusItemPlacement()`。由 `GUIRunner.run()` 打开。
    static var placementWatchEnabled = false

    /// 全局快捷键。四个动作与状态栏菜单一一对应，用的是同一套组合。
    ///
    /// 动作全部转发到 `workspace` / `recorder`——**不在这一层做任何状态判断**。
    /// 状态机自己知道「准备阶段不能暂停」「空闲时不能停止」，两处都判断早晚会不一致。
    private func installHotKeys() {
        hotKeys = GlobalHotKeys(bindings: [
            .init(name: "开始录制", display: "⌥⌘R",
                  keyCode: GlobalHotKeys.keyR, modifiers: GlobalHotKeys.commandOption) {
                [weak self] in self?.workspace.startRecording(titleBase: "")
            },
            .init(name: "暂停/继续", display: "⌥⌘P",
                  keyCode: GlobalHotKeys.keyP, modifiers: GlobalHotKeys.commandOption) {
                [weak self] in self?.workspace.recorder.togglePause()
            },
            .init(name: "停止录制", display: "⌥⌘S",
                  keyCode: GlobalHotKeys.keyS, modifiers: GlobalHotKeys.commandOption) {
                [weak self] in self?.workspace.recorder.stop()
            },
            .init(name: "显示/隐藏窗口", display: "⌥⌘M",
                  keyCode: GlobalHotKeys.keyM, modifiers: GlobalHotKeys.commandOption) {
                [weak self] in self?.toggleWindow()
            },
        ])

        if let failures = hotKeys?.failures, !failures.isEmpty {
            // 不静默：写日志 + 状态栏菜单里也会列出来。
            // 用户遇到「按了没反应」时，至少有个地方能查到原因。
            FileHandle.standardError.write(
                Data("⚠️  全局快捷键注册失败：\(failures.joined(separator: "、"))\n".utf8))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys?.invalidate()
        // 正在录音时直接退出：放弃收尾，留下可恢复的现场（`.recording` + 未 finalize 的头），
        // 下次启动 `recover` 能把它救回来。反过来若在这里主动 finalize，
        // 反而会把「文件是完整的」这件事写死，丢掉恢复的依据。
        if workspace.recorder.isActive {
            workspace.recorder.abort()
        }
    }

    /// 「编辑」菜单。**这条不是装饰，是粘贴功能唯一的派发通路。**
    ///
    /// ## 少了它会发生什么（2026-10-19 真故障）
    ///
    /// 设置窗口里粘贴 API Key 没反应——⌘V 按下去什么都不发生，
    /// 而输入框能点、能打字、鼠标右键菜单也只有系统自带的「粘贴」可用。
    /// 根因是**主菜单里没有「编辑」这一组菜单项**：
    /// macOS 的 ⌘V 不是直接调 `NSTextField.paste(_:)`，而是先在 `mainMenu`
    /// 里找 keyEquivalent 为 "v" 的菜单项，再由它沿响应链派发。
    /// 菜单里没有这一项，AppKit 连派发对象都找不到——
    /// 于是既不报错、也不执行，看起来就像「这个 App 不支持粘贴」。
    ///
    /// 这也解释了为什么**主窗口的重命名输入框同样中招**：
    /// 它和设置窗口共用同一个 `NSApp.mainMenu`，一个菜单决定全进程。
    /// 只在设置窗口里想办法是治不了的（那层根本没有可派的通路）。
    ///
    /// `target` 全部留空（nil），走响应链到当前 first responder——
    /// 这正是标准 AppKit 菜单的行为，焦点在哪个输入框就作用在哪个输入框上。
    ///
    /// 抽成静态构造是为了能测接线：**「菜单项在不在」是这类故障唯一的证据**，
    /// 而它是编译期看不出来的（#selector 引用合法方法，编译一定通过）。
    static func editMenu() -> NSMenu {
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(
            withTitle: "撤销",
            action: #selector(UndoManager.undo),
            keyEquivalent: "z")
        editMenu.addItem(
            withTitle: "重做",
            action: #selector(UndoManager.redo),
            keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "剪切",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x")
        editMenu.addItem(
            withTitle: "复制",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "粘贴",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "删除",
            action: #selector(NSText.delete(_:)),
            keyEquivalent: "")
        editMenu.addItem(
            withTitle: "全选",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a")
        return editMenu
    }

    /// 没有菜单栏，⌘Q / ⌘W 都不会工作，用户只能去 Dock 上右键退出。
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = "会议录音器"
        appMenu.addItem(
            withTitle: "关于 \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(Self.settingsMenuItem(target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "隐藏 \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = Self.editMenu()
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(
            withTitle: "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "关闭",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
