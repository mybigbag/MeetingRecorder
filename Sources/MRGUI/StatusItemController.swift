import AppKit
import Combine
import MRCore
import MRSession

/// 菜单栏上的常驻入口。
///
/// 存在的理由：**录音不该被窗口绑住**。窗口是「翻看会议」的地方，
/// 而开始/暂停/停止是需要随时够得着的动作——尤其当你要录的会议正在别的应用里开。
/// 所以关掉窗口只是收起窗口，录音继续，状态栏上留一个小工具。
///
/// 菜单**每次弹出前重建**（`menuNeedsUpdate`），而不是建好后手工同步每一处状态。
/// 后者要在至少五个地方记得改标题和可用性，漏一处就会出现「明明在录制，
/// 菜单却写着开始录制」这类自相矛盾的界面。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let workspace: MeetingWorkspace
    /// 快捷键注册失败的信息，直接摆进菜单——不能只写进日志
    private let hotKeyFailures: [String]
    private let onShowWindow: () -> Void
    /// 「设置…」要叫起设置窗口。默认空实现——测试里不关心它，
    /// 但给了默认值，既有构造调用点（几十个用例）不用跟着改。
    private let onShowSettings: () -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(
        workspace: MeetingWorkspace,
        hotKeyFailures: [String],
        onShowWindow: @escaping () -> Void,
        onShowSettings: @escaping () -> Void = {}
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.workspace = workspace
        self.hotKeyFailures = hotKeyFailures
        self.onShowWindow = onShowWindow
        self.onShowSettings = onShowSettings
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform", accessibilityDescription: "会议录音器")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.toolTip = "会议录音器"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // 状态一变，图标与时长立刻跟上。用 Combine 而不是自己的定时器：
        // `RecordingController` 本来就每 0.5 秒发布一次 elapsed。
        //
        // ⚠️ 三处都**必须跳一个主 actor 回合**再刷新，不能直接在 sink 里调
        // `refreshButton()`。`@Published` 是在 `willSet` 里发值的：
        //
        //     $value.sink { _ in print(box.value) }   // 打印的是**旧值**
        //
        // 实测（`/tmp` 上一次性的 Combine 探针）：属性从 0 改成 7，sink 里
        // 同步读回的是 0。所以同步刷新等于**用上一帧的状态画这一帧**。
        //
        // 这个偏差一直被 0.5 秒一次的 `elapsed` 计时掩盖着，只有在「不录制」
        // 时才稳定暴露——而「静默录制」这个开关恰好就是空闲时切换的。
        // 表现会是「勾了没反应，要等下一次计时刷新才生效」，最难查的那一类。
        subscribe(workspace.recorder.$phase)
        subscribe(workspace.recorder.$elapsed)
        subscribe(workspace.$hidesStatusBarCountdown)
        // 图标显隐**不能**走上面那个 `subscribe`：那个只重画外观，
        // 而「用户把图标关了」必须真的把状态栏项收起来。漏了这条订阅，
        // 表现是「设置里显示已关、菜单栏上还在」——两处各说各话。
        workspace.$showsStatusBarIcon
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyIconVisibility() }
            }
            .store(in: &cancellables)
        applyIconVisibility()
        refreshButton()
    }

    /// 订阅一个发布者，并在**值落定之后**刷新按钮。见 `init` 里的时序说明。
    private func subscribe<P: Publisher>(_ publisher: P)
    where P.Failure == Never {
        publisher
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshButton() }
            }
            .store(in: &cancellables)
    }

    /// 「菜单栏图标」开关变化后的落点。与 `refreshButton()` 分开：
    /// 一个管**在不在**，一个管**长什么样**。混在一起的话，
    /// 「图标被用户关掉了」会被下一次计时刷新顺手画回来——
    /// 而录制中每 0.5 秒就有一次刷新，等于这个开关永远关不掉。
    private func applyIconVisibility() {
        statusItem.isVisible = workspace.showsStatusBarIcon
    }

    /// 图标此刻是否挂在菜单栏上（用户视角的「在不在」）。
    ///
    /// 给测试与探针用。注意它与 `isPlaced` 回答的不是同一个问题：
    /// `isVisible == false` 是**用户主动关的**，`isPlaced == false` 是
    /// **系统没给位置**（见 `isPlaced` 的说明）——两者的处理方式完全相反。
    var isIconVisible: Bool { statusItem.isVisible }

    private var recorder: RecordingController { workspace.recorder }

    /// 状态栏按钮所在窗口的 frame（图标还没挂上去时为 nil）。
    ///
    /// 「图标真的出现在菜单栏里」这件事没法用 `CGWindowListCopyWindowInfo` 探测：
    /// 状态栏项属于 `NSStatusBar` 的独立窗口，拿到的 `kCGWindowOwnerPID` 不是本进程。
    /// 而 `NSStatusItem.isVisible` 只表示「没被主动隐藏」，说不明图标到底在不在。
    /// 按钮窗口的 frame 是唯一既能读到、又真的对应屏幕上那块区域的证据——
    /// 所以测试靠它来判断，**不是**为了让生产代码好看才加的。
    var buttonWindowFrame: NSRect? { statusItem.button?.window?.frame }

    /// 按钮窗口本身。给测试用：`isPlaced` 的判据依赖它，测试要拿同一个对象去复算。
    var rawButtonWindow: NSWindow? { statusItem.button?.window }

    /// 状态栏项**真的被系统放进了菜单栏**吗？
    ///
    /// `NSStatusItem.isVisible` 回答不了这个问题：它在三种失败状态下**全都**读回
    /// `true`（2026-10-20 实测，见下表）。
    ///
    /// ## 判据：按钮窗口的**高度**等于菜单栏高度
    ///
    /// 系统真正登记这个项时，会把按钮窗口**拉高到菜单栏那么高**（内置屏 39pt、
    /// 外接屏 30pt）；没被登记时它保持 AppKit 的默认高度 **22pt**。
    /// 高度因此是最直接、最不依赖外部信息的证据。
    ///
    /// 实测三种状态（macOS 26.6.2，双屏）：
    ///
    /// | 状态                              | `envCFBundle`   | 按钮窗口 frame          | 高度 | 登记数 |
    /// |-----------------------------------|-----------------|-------------------------|------|--------|
    /// | A 正常（`open -a` 启动）          | == 自己 bundle id | `(1116, 1073, 32, 39)`  | 39   | 11 ✅  |
    /// | B 直接执行 .app 内二进制           | == 父进程 id     | `(1678, 1090, 32, 22)`  | 22   | 10 ❌  |
    /// | C 被毒化后再 `open -a`            | == 自己 bundle id | `(0, -22, 32, 22)`      | 22   | 10 ❌  |
    ///
    /// B 与 C 的 `isVisible` 同样都是 `true`——**属性说「可见」，眼睛说「没有」**。
    /// 高度把这三种状态分得干干净净。
    ///
    /// ## 为什么不用几何位置
    ///
    /// 旧判据是「按钮窗口的 `maxY` 落在屏幕上沿 60pt 内」。它有**假阳性**：
    /// 系统完全没登记时，按钮窗口的 frame 仍可能是 `(1826, 2242, 32, 22)`——
    /// 那个 `maxY` 恰好落进某块屏的上沿带，几何算出来是 `true`，
    /// 而屏幕上根本没有图标。**几何与登记状态是脱钩的**，不能用。
    ///
    /// ## 为什么不用窗口名字
    ///
    /// `CGWindowListCopyWindowInfo` 能看到菜单栏项，但 `kCGWindowName` 在**内置屏**
    /// 那条带上会退化成 `Item-0`（第三方项全部如此，系统项如 WiFi/Clock 名字正常），
    /// 此时「按 bundle id 找」必然是**假阴性**。名字不能作为判据。
    ///
    /// ## 拆成静态函数、只吃数字，是为了能测
    ///
    /// `NSScreen` 在测试里造不出来，但两个矩形和一组高度可以。
    ///
    /// ## 为什么是「一组」高度而不是一个
    ///
    /// 状态栏项可能落在**任意一块屏**上，而不同屏的菜单栏高度不同
    /// （内置屏 39pt、外接屏 30pt，实测）。所以判据是
    /// 「**有没有哪一块屏**的菜单栏高度与按钮窗口高度相符」，
    /// 不是「与最大的那个相符」——后者会把排在矮屏上的项误判成未登记。
    static func isPlaced(buttonFrame: NSRect?, menuBarHeights: [CGFloat]) -> Bool {
        guard let buttonFrame else { return false }
        // 容差 1pt：系统给的高度与实测菜单栏高度可能差一点点（缩放/机型）。
        return menuBarHeights.contains { $0 > 0 && abs(buttonFrame.height - $0) <= 1 }
    }

    /// 见 `isPlaced(buttonFrame:menuBarHeights:)`
    var isPlaced: Bool {
        let window = statusItem.button?.window
        return Self.isPlaced(
            buttonFrame: window?.frame,
            menuBarHeights: Self.menuBarHeights)
    }

    /// 所有屏的菜单栏高度（点）。
    ///
    /// 菜单栏高度取「屏的上沿那条带子的厚度」：一块屏的 `frame.maxY` 到
    /// `visibleFrame.maxY` 的差值，正是菜单栏占掉的高度（`visibleFrame` 扣掉了菜单栏）。
    ///
    /// 返回**全部**屏的高度而不是最大值——状态栏项可能被排在任一块屏上，
    /// 判据要的是「有没有哪一块屏对得上」。
    static var menuBarHeights: [CGFloat] {
        NSScreen.screens.map { screen in
            max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        }.filter { $0 > 0 }
    }

    /// 当前菜单栏的高度（点）。**所有屏里最大的那个**。
    ///
    /// 只给诊断输出用（`diagnosticSnapshot()`）；判据请用 `menuBarHeights`。
    static var menuBarHeight: CGFloat {
        menuBarHeights.max() ?? 0
    }

    /// 状态栏项的内部状态快照。**只给诊断用**，产品逻辑不依赖它。
    ///
    /// 存在的理由：2026-10-20 这一轮里，「图标不显示」的排查卡在了一个
    /// 死结上——`isVisible` 读回 `true`、`isPlaced` 也算 true、系统的
    /// `VisibleCC` 裁决是 `true`，三处都说「在」，可屏幕上就是没有。
    /// 那三处属性都说不出「到底哪儿不对」，所以必须把内部状态原样倒出来：
    /// 按钮窗口的 frame、按钮有没有图、图有多大、落在哪块屏上。
    ///
    /// 只有拿到这些数字才能分辨三种完全不同的故障：
    /// 「按钮窗口在屏幕外」（系统拒绝排位）／「按钮没有图」（自己造的空按钮）／
    /// 「图在另一块屏的菜单栏上」（双屏，盯着主屏看不到）。
    struct DiagnosticSnapshot: CustomStringConvertible {
        var isVisible: Bool
        var isPlaced: Bool
        var buttonWindowFrame: String
        var buttonFrame: String
        var buttonScreen: String
        var buttonIsHidden: Bool
        var imageDescription: String
        var imageSize: String
        var title: String
        var length: Double
        var allScreens: String
        /// 每块屏的菜单栏高度。**判据改成按高度之后，这行是必须有的**：
        /// 光看「按钮窗口 frame」得自己心算高度，再猜它该等于几，
        /// 而 39（内置屏）与 30（外接屏）两个值都可能是对的。
        var menuBarHeights: String
        var screenHint: String
        var windowScreen: String

        var description: String {
            """
            状态栏项诊断：
              isVisible=\(isVisible)  isPlaced=\(isPlaced)
              按钮窗口 frame=\(buttonWindowFrame)
              按钮 frame=\(buttonFrame)
              按钮所在屏=\(buttonScreen)
              按钮 hidden=\(buttonIsHidden)
              图=\(imageDescription)  尺寸=\(imageSize)
              标题="\(title)"  length=\(length)
              全部屏幕=\(allScreens)
              各屏菜单栏高度=\(menuBarHeights)
              窗口所在屏=\(windowScreen)
              跨屏提示=\(screenHint)
            """
        }
    }

    /// 采一份当前状态。见 `DiagnosticSnapshot` 的说明。
    func diagnosticSnapshot() -> DiagnosticSnapshot {
        let button = statusItem.button
        let window = button?.window
        let image = button?.image
        let screens = NSScreen.screens.enumerated().map { index, screen in
            "[\(index)] \(screen.frame)"
        }.joined(separator: " ")
        let heights = NSScreen.screens.enumerated().map { index, screen in
            let height = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
            return "[\(index)] \(height)"
        }.joined(separator: " ")
        return DiagnosticSnapshot(
            isVisible: statusItem.isVisible,
            isPlaced: isPlaced,
            buttonWindowFrame: window.map { "\($0.frame)" } ?? "nil",
            buttonFrame: button.map { "\($0.frame)" } ?? "nil",
            buttonScreen: window?.screen.map { "\($0.frame)" } ?? "nil",
            buttonIsHidden: button?.isHidden ?? false,
            imageDescription: image.map { "有效=\($0.isValid) 名称=\($0.name() ?? "?")" } ?? "nil",
            imageSize: image.map { "\($0.size)" } ?? "nil",
            title: button?.title ?? "",
            length: statusItem.length,
            allScreens: screens,
            menuBarHeights: heights,
            screenHint: workspace.statusIconScreenHint ?? "（无）",
            windowScreen: mainWindow?.screen.map { "\($0.frame)" } ?? "nil")
    }

    /// 主窗口。**只用来判断图标与窗口是不是在同一块屏上**——
    /// 2026-10-20 那次故障里，图标被排到了副屏的菜单栏，而用户在主屏找它。
    /// 由 `GUIRunner` 在建好窗口后赋值。
    ///
    /// ⚠️ 2026-10-20 复核后**这个前提已被证伪**：macOS 26 上状态栏项在
    /// **每一块屏的菜单栏上各有一份**，始终同步（实测：启动后两块屏的菜单栏项数
    /// 同时 +1、退出后同时 -1，宽度签名完全一致）。所以「图标只在另一块屏上」
    /// 这个状态并不存在，`mainWindow` 现在只用于诊断输出。
    weak var mainWindow: NSWindow?

    /// 图标所在屏与主窗口所在屏**错开**时的提示文案。nil = 一致（或只有一块屏）。
    ///
    /// 保留这个函数是为了不破坏既有测试与调用点，但**产品逻辑不再依赖它**——
    /// 见 `mainWindow` 上面的说明：跨屏状态实际不存在。
    ///
    /// 拆成静态函数、只吃两个屏名，是为了能测：`NSScreen` 在测试里造不出来，
    /// 而两个字符串可以（同一个道理，见 `isPlaced(buttonFrame:menuBarHeights:)`）。
    static func screenHint(iconScreen: String?, windowScreen: String?) -> String? {
        guard let iconScreen, let windowScreen, iconScreen != windowScreen else { return nil }
        return "菜单栏图标在「\(iconScreen)」的菜单栏上，而这扇窗口在「\(windowScreen)」——"
            + "两处不是一块屏，所以你在眼前这块屏上找不到它。"
    }

    /// 屏的显示名。内置屏给一个明确的说法（「内置显示器」），
    /// 外接屏用系统给的显示器名——用户认得自己的显示器叫什么。
    static func screenName(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        if let number, CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0 {
            return "内置显示器"
        }
        let name = screen.localizedName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? fallbackScreenName : name
    }

    /// 拿不到显示器名字时的兜底说法。不能是空串——
    /// 「图标在『』的菜单栏上」比不提示还糟。
    static let fallbackScreenName = "另一块显示器"

    /// 「系统没给位置」时的话。
    ///
    /// 2026-10-20 复核后改了说法：原来的「菜单栏放不下」**是错的**——
    /// 实测那块屏的菜单栏还有空位，系统是**根本没登记**这个项。
    /// 说错原因会让用户去腾菜单栏空间，腾完了图标还是不出来。
    ///
    /// 正确的原因与办法：系统拒绝登记本应用的菜单栏项。常见成因是
    /// **这个 bundle id 曾经被直接执行过**（不经 LaunchServices），
    /// 那会把它永久列入拒绝名单，表现为「怎么重开都不出现」。
    /// 办法是退出应用后用 `open -a` 或访达双击启动（已由
    /// `LaunchServicesHandoff` 自动接管，直接执行时它会先交接出去）。
    ///
    /// 话里必须写明：① 原因；② 怎么办；③ **功能没坏**——
    /// 用户看到「图标不见了」的第一反应是「App 坏了」。
    static func noRoomHint() -> String {
        "系统没有把这个应用登记进菜单栏——所以菜单栏上找不到它的图标。"
            + "退出应用后从访达双击重新打开即可（直接运行 .app 里的二进制会让系统"
            + "永久拒绝登记本应用，图标就再也出不来了）。"
            + "录音与快捷键不受影响。"
    }

    /// 屏的显示 ID。用它反查 `NSScreen`（跨层只传基本类型）。
    static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    /// 图标所在屏（按钮窗口所在的屏）。图标没被系统排上时为 nil。
    var iconScreen: NSScreen? { statusItem.button?.window?.screen }

    /// 重算状态栏项的提示，写进工作区。
    ///
    /// 2026-10-20 复核后语义变了。原来这个函数回答的是
    /// 「图标与窗口是不是在同一块屏」（跨屏就提示 + 给一个搬窗口的动作）——
    /// 那个前提已被证伪：**状态栏项在每块屏的菜单栏上各有一份，始终同步**
    /// （实测启动时两块屏项数同时 +1、退出时同时 -1，宽度签名一致）。
    ///
    /// 现在它只回答一个真问题：**系统到底有没有登记这个项**。
    /// 判据是按钮窗口的高度（见 `isPlaced(buttonFrame:menuBarHeights:)`）——
    /// 被登记时它会被拉到菜单栏那么高，没被登记时是默认的 22pt。
    ///
    /// 不再给「把窗口移过去」的动作：跨屏状态不存在，那个动作只会
    /// **擅自搬走用户自己的窗口**——一个建立在错误前提上的有害副作用。
    func updateScreenHint() {
        if isPlaced {
            setHint(nil, relocateScreenID: nil)
            return
        }
        setHint(Self.noRoomHint(), relocateScreenID: nil)
    }

    /// 写提示与它的动作。拆出来是为了让「提示变了」和「动作变了」走同一条路——
    /// 分开写就会出现「提示说在这块屏、动作却把窗口搬去另一块」。
    private func setHint(_ text: String?, relocateScreenID: UInt32?) {
        if workspace.statusIconScreenHint != text {
            workspace.statusIconScreenHint = text
        }
        if workspace.statusIconRelocateScreenID != relocateScreenID {
            workspace.statusIconRelocateScreenID = relocateScreenID
        }
        let iconID = statusItem.button?.window?.screen.flatMap(Self.displayID)
        if workspace.statusIconScreenID != iconID {
            workspace.statusIconScreenID = iconID
        }
    }

    /// 图标与菜单栏上的文字。
    private func refreshButton() {
        guard let button = statusItem.button else { return }

        let appearance = Self.appearance(
            for: recorder.phase,
            elapsed: recorder.elapsed,
            hidesCountdown: workspace.hidesStatusBarCountdown)

        button.image = Self.image(for: appearance)
        button.title = appearance.title
        button.toolTip = appearance.tooltip
        lastAppearance = appearance
    }

    /// 最近一次真的铺到按钮上的外观。
    ///
    /// 给测试与探针用。**不是**为了方便而存：`NSButton.image` 读不出系统符号的名字，
    /// 「图标到底还是不是那个中性的波形」在这里没有别的问法。
    /// 少了它，「隐藏模式生效了」和「按钮根本没刷新」这两件事分不开。
    private(set) var lastAppearance: Appearance?

    /// 按钮上此刻的文字，`""` 表示只有图标。同上，给测试与探针读真实控件。
    var buttonTitle: String? { statusItem.button?.title }

    /// 把一份外观变成真的图标。
    ///
    /// ## 为什么上色不走 `contentTintColor`
    ///
    /// 生产代码原先用的是 `button.contentTintColor = .systemRed`。**它不生效。**
    /// 实测（macOS 26.6.2，五种写法逐一对号，含真 `.app` 复验）：
    /// 给 `NSStatusBarButton` 设了 `contentTintColor` 之后，
    /// 模板图不再按菜单栏前景色渲染，而是**回落成符号自带的黑色**——
    /// 红色和橙色都变成了黑的；连按钮上的文字也从白色变成了黑字
    /// （菜单栏是深色时，那行字几乎是看不见的）。
    /// 也就是说代码注释里那句「录制中变红」从写下来那天起就没成立过。
    ///
    /// 真正有效的是**符号自己的调色板配置**：`withSymbolConfiguration(paletteColors:)`
    /// 并把 `isTemplate` 置 false（同一个实验里唯一渲染出红色的一种写法）。
    ///
    /// 中性外观**仍然走模板图**，因为模板图会跟随菜单栏明暗自动反色，
    /// 而写死的颜色在浅色菜单栏上会消失。
    static func image(for appearance: Appearance) -> NSImage? {
        let symbol = NSImage(
            systemSymbolName: appearance.symbolName, accessibilityDescription: "会议录音器")

        guard let tint = color(appearance.tint) else {
            symbol?.isTemplate = true
            return symbol
        }

        let tinted = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [tint]))
        tinted?.isTemplate = false
        return tinted
    }

    private static func color(_ tint: Appearance.Tint) -> NSColor? {
        switch tint {
        case .none: return nil
        case .red: return .systemRed
        case .orange: return .systemOrange
        }
    }

    // MARK: - 外观

    /// 状态栏按钮「应该长什么样」。
    ///
    /// **纯值，不含任何 AppKit 类型**——这个功能全部的判断都在这里，
    /// 而 `NSImage(systemSymbolName:)` 在无头测试里画不出一条有意义的断言。
    /// 抽成纯值之后，「隐藏模式下状态栏不许泄露正在录音」才能钉成一条真断言，
    /// 而不是靠人肉盯截图。
    struct Appearance: Equatable {
        enum Tint: Equatable { case none, red, orange }
        var symbolName: String
        var tint: Tint
        /// 按钮上的文字，`""` 表示只有图标
        var title: String
        var tooltip: String
    }

    /// 隐藏模式下，录制中一律用这一份外观。
    ///
    /// 两个刻意的选择：
    ///
    /// 1. **整份替换，而不是逐字段屏蔽当前状态。** 逐字段屏蔽的话，将来给
    ///    `Appearance` 加一个新字段（比如「正在录几条轨」），只要忘了在隐藏分支里
    ///    也设一遍，它就漏出去了，而漏出去的那一刻没人会发现。整份替换把这条
    ///    变成结构性的：新字段压根不在这一份里。
    /// 2. **提示语是「会议录音器」，不是「空闲」。** 说「空闲」是在替用户撒谎，
    ///    而需求只是「不泄露」。不声称，也不否认——这才是这个开关该干的事。
    static let concealedAppearance = Appearance(
        symbolName: "waveform", tint: .none, title: "", tooltip: "会议录音器")

    /// 这个相位会不会泄露「正在录音」。
    ///
    /// `.failed` 刻意**不在**其中：出错必须照实说。把「麦克风没起来」也一起藏掉，
    /// 用户会以为录上了——那是这个开关最坏的副作用，比泄露严重得多。
    static func leaksRecording(_ phase: RecordingController.Phase) -> Bool {
        switch phase {
        case .preparing, .recording, .paused, .stopping: return true
        case .idle, .finished, .failed: return false
        }
    }

    /// 录制中额外显示计时——菜单栏是唯一在意「现在到底录着没有」的地方，
    /// 光靠一个图标，用户得点开菜单才知道。暂停时改成橙色：**暂停和录制
    /// 只差一个图标的话，很容易误以为还在录**，而暂停期间的声音是真的没了。
    ///
    /// - Parameter hidesCountdown: 用户开的「静默录制」。只影响**被动可见**的东西；
    ///   菜单那一份（`statusLine`）始终如实——见 `menuNeedsUpdate` 的说明。
    static func appearance(
        for phase: RecordingController.Phase,
        elapsed: Double,
        hidesCountdown: Bool
    ) -> Appearance {
        if hidesCountdown, leaksRecording(phase) { return concealedAppearance }

        switch phase {
        case .idle, .finished, .failed:
            return Appearance(
                symbolName: "waveform", tint: .none, title: "",
                tooltip: standardTooltip(for: phase, elapsed: elapsed))
        case .preparing:
            return Appearance(
                symbolName: "waveform.badge.magnifyingglass", tint: .none, title: "",
                tooltip: standardTooltip(for: phase, elapsed: elapsed))
        case .recording:
            return Appearance(
                symbolName: "record.circle.fill", tint: .red,
                title: " " + clock(elapsed),
                tooltip: standardTooltip(for: phase, elapsed: elapsed))
        case .paused:
            return Appearance(
                symbolName: "pause.circle.fill", tint: .orange,
                title: " " + clock(elapsed),
                tooltip: standardTooltip(for: phase, elapsed: elapsed))
        case .stopping:
            return Appearance(
                symbolName: "waveform", tint: .none, title: "",
                tooltip: standardTooltip(for: phase, elapsed: elapsed))
        }
    }

    /// 标准模式下的鼠标提示。抽出来是为了让 `appearance` 的每个分支都短到
    /// 一眼能看出「这一份会不会泄露状态」。
    private static func standardTooltip(
        for phase: RecordingController.Phase, elapsed: Double
    ) -> String {
        switch phase {
        case .idle: return "会议录音器 · 空闲"
        case .preparing: return "会议录音器 · 正在准备音频设备"
        case .recording: return "会议录音器 · 录制中 \(clock(elapsed))"
        case .paused: return "会议录音器 · 已暂停（这一段不会被录进去）"
        case .stopping: return "会议录音器 · 正在保存"
        case .finished(let id): return "会议录音器 · 已保存 \(id)"
        case .failed(let message): return "会议录音器 · 失败：\(message)"
        }
    }

    // MARK: - 菜单

    /// 「静默录制」那一项的标题。
    ///
    /// 提成常量是因为**探针要按标题把它找出来再点**（见
    /// `scripts/probes/gui-lifecycle/`）：写死两份字符串，改一处就会让探针
    /// 悄悄找不到菜单项、然后以「没有这一项」失败——看起来像功能没了。
    static let concealMenuTitle = "状态栏隐藏录制中的计时"

    /// 「16 位录音」那一项的标题。提成常量的理由同上——探针与测试要按标题找它。
    static let formatMenuTitle = "16 位录音（体积减半）"

    /// 「单声道 24 kHz」那一项的标题。提成常量的理由同上。
    static let mono24kMenuTitle = "单声道 24 kHz（体积再降至 1/3）"

    /// 「降混策略」子菜单的标题。提成常量的理由同上（测试要按标题找它）。
    static let downmixMenuTitle = "降混策略"

    /// 「录音保留策略」子菜单的标题。提成常量的理由同上。
    static let retentionMenuTitle = "保留策略"

    /// 「立即清理旧录音」那一项的标题。提成常量的理由同上。
    static let pruneMenuTitle = "立即清理旧录音…"

    /// 「每天自动清理」那一项的标题。提成常量的理由同上。
    static let autoPruneMenuTitle = "每天自动清理一次"

    // MARK: - 归类：三个分组子菜单的标题

    /// 「录音设置」分组子菜单的标题。
    ///
    /// ## 为什么状态栏菜单要分组，而不只是加两条分隔线
    ///
    /// 改动前这七个设置项与三个录音命令、显示窗口、退出平铺在同一层，
    /// 一眼看过去是十一个并列条目——**每一条看上去同等重要、同样高频**。
    /// 但它们实际分属两类：
    ///
    /// - 录音命令（开始/暂停/停止）与显示窗口、退出：**随时要够得着**，必须平铺；
    /// - 七个设置项：**改一次长期生效**，平铺只会让设置看起来像每场的必做步骤。
    ///
    /// 分隔线只能做视觉分组，点开菜单时它们仍是十一个同级条目；
    /// 收进子菜单才真正改变层级——**菜单结构本身就是优先级声明**。
    static let recordingSettingsMenuTitle = "录音设置"

    /// 「存储与清理」分组子菜单的标题。
    ///
    /// 单独成一组而不是并进「录音设置」：这一组**会删用户数据**。
    /// 放在「录音设置」里，用户会以为它和「16 位录音」是同一类东西——
    /// 而这两个的操作期望根本不同：前者是「以后按这个规则办」，
    /// 后者是「帮我清一批」。混在一组里，那个不可逆的删除授权就被日常设置稀释掉了。
    static let storageMenuTitle = "存储与清理"

    /// 「隐私」分组子菜单的标题。
    static let privacyMenuTitle = "隐私"

    /// 「菜单栏」分组子菜单的标题。提成常量的理由同上（测试要按标题找它）。
    static let menuBarMenuTitle = "菜单栏"

    /// 「在菜单栏显示图标」那一项的标题。提成常量的理由同上——
    /// 探针与测试要按标题把它找出来。
    static let statusIconMenuTitle = "在菜单栏显示图标"

    /// 「转写引擎」分组子菜单的标题。
    static let engineMenuTitle = "转写引擎"

    /// 「会议纪要」分组子菜单的标题。
    static let minutesMenuTitle = "会议纪要"

    // MARK: - 说明文案
    //
    // 2026-10-22：这一段曾把「16 位录音」「单声道 24 kHz」「静默录制」「在菜单栏
    // 显示图标」四段长说明同时挂在菜单项的 `toolTip` 上。反馈是
    // 「hover 说明还会遮挡设置项」——菜单项浮层就贴在菜单里，一大坨多行文
    // 正好盖住下面几条，用户想点的项被自己刚触发的说明挡住。
    //
    // 所以菜单里**不再有任何浮层**。信息改由两处承载：
    //
    // - 标题：分组入口写成「录音设置：24 kHz 单声道 · 16 位浮点 · 苹果原生」，
    //   不点开也知道当前是什么（状态本身就是最常被问的那件事）；
    // - 设置窗口 / 顶栏面板：每一项**常驻一行说明**，长的收进「说明」就地展开
    //   （文案的唯一出处是 `SettingsCopy`）。
    //
    // 菜单不是读文档的地方：它的职责是「列出现在能做什么、现在是什么」。

    /// 关掉图标之后会怎样。**保留**成常量，因为它被弹窗（`hideIconAlertMessage`）
    /// 与设置窗口的 `SettingsCopy.statusIconDetails` 共用——但**不再挂到菜单项上**。
    static let statusIconHelp = SettingsCopy.statusIconDetails

    /// 录制中关掉图标时的确认弹窗标题与正文。**抽成常量**是因为 SwiftUI
    /// 两个入口（设置窗口、顶栏面板）也要用同一份文案——各写一份的话，
    /// 「⌘, 里说快捷键可用、面板里说会停止录音」这种自相矛盾就会出现。
    static let hideIconAlertTitle = "隐藏菜单栏图标？"

    /// 见 `hideIconAlertTitle`。正文只说**这一刻**的代价，不重复 `statusIconHelp`
    /// 里的常驻说明——弹窗该短。
    static let hideIconAlertMessage = """
        正在录制中。隐藏后菜单栏上看不到计时与状态，但录音继续——\
        窗口里仍显示「录制中」，⌥⌘R / ⌥⌘P / ⌥⌘S 仍可用。\
        之后想恢复：设置窗口（⌘,）或主窗口顶栏「录音设置」。
        """

    /// 开关行的常驻说明。**跟着当前状态说人话**：开着的时候讲「关了会怎样」，
    /// 关着的时候讲「怎么恢复」。
    ///
    /// 一份静态文案在这里是不够的：它只能说一半，而用户恰好只会在
    /// 其中一种状态下去读这行字——图标已经没了的人需要知道的是
    /// 「怎么点回来」，不是「点了会发生什么」。
    ///
    /// 2026-10-22：内容挪进 `SettingsCopy.statusIconOneLine`，这里只留一个
    /// 转发入口，好让历史调用点与测试不必改名字。**长度也从「一整段」压到
    /// 一行**——原来那一版在设置窗口里要占三行，是「说明文案杂乱成堆」的一部分。
    static func statusIconCaption(showsIcon: Bool) -> String {
        SettingsCopy.statusIconOneLine(showsIcon: showsIcon)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(command(
            title: "开始录制", shortcut: "r", action: #selector(startRecording),
            enabled: !recorder.phase.isBusy))

        menu.addItem(command(
            title: recorder.isPaused ? "继续录制" : "暂停录制",
            shortcut: "p", action: #selector(togglePause),
            enabled: recorder.phase == .recording || recorder.phase == .paused))

        menu.addItem(command(
            title: recorder.phase == .preparing ? "取消准备" : "停止录制",
            shortcut: "s", action: #selector(stopRecording),
            enabled: recorder.phase.isBusy))

        menu.addItem(.separator())
        menu.addItem(command(
            title: "显示主窗口", shortcut: "m", action: #selector(showWindow), enabled: true))

// ── 设置：收进分组子菜单，不再平铺 ─────────────────────────
        //
        // 三个录音命令与「显示主窗口」保持平铺，因为它们**随时要够得着**。
        // 而下面这些设置项改一次长期生效，平铺会让人误以为每场录制前都要过一遍——
        // 菜单结构本身就是优先级声明（见 `recordingSettingsMenuTitle` 的说明）。
        menu.addItem(.separator())
        menu.addItem(Self.recordingSettingsMenuItem(workspace: workspace, target: self))
        menu.addItem(Self.storageMenuItem(
            workspace: workspace, target: self,
            actions: StorageActions(
                selectRetention: #selector(selectRetention(_:)),
                pruneOldAudio: #selector(pruneOldAudio),
                toggleAutoPrune: #selector(toggleAutoPrune))))
        menu.addItem(Self.privacyMenuItem(
            workspace: workspace, target: self, action: #selector(toggleConceal)))
        menu.addItem(Self.menuBarMenuItem(
            workspace: workspace, target: self, action: #selector(toggleStatusBarIcon)))

        // 「设置…」单独一项，不塞进任何分组：它是**设置界面**的入口，
        // 而上面三个分组是把设置项摊平成菜单项的地方。两件事混在一起的话，
        // 用户点「设置…」却只看到几个勾选项，找不到填 API Key 的地方。
        menu.addItem(.separator())
        menu.addItem(command(
            title: "设置…", shortcut: ",", action: #selector(openSettingsWindow), enabled: true))

        if !hotKeyFailures.isEmpty {
            menu.addItem(.separator())
            // 快捷键没注册上就直说，别让用户自己猜。功能仍可从本菜单点。
            let item = NSMenuItem(
                title: "快捷键不可用：\(hotKeyFailures.joined(separator: "、"))",
                action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            let hint = NSMenuItem(title: "（可能被其它程序占用，可从本菜单操作）", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())
        menu.addItem(command(
            title: "退出会议录音器", shortcut: "q", action: #selector(quit), enabled: true))
    }

    // MARK: - 分组子菜单（抽成静态构造是为了能测）

    /// 一个勾选项。
    ///
    /// 抽出来是因为几个勾选项的构造完全同构，而「`state` 忘了现读 workspace」
    /// 正是这里唯一会坏、且**屏幕上完全看不出的形态**（菜单还照常弹出，
    /// 只是勾的位置永远是错的）。
    ///
    /// **刻意没有 `help` 参数**：菜单项不挂浮层（见上方「说明文案」一节的说明）。
    /// 少一个参数，也就少一条「有人又把长文案塞回菜单」的路。
    static func toggleItem(
        title: String, current: Bool, target: AnyObject, action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.state = current ? .on : .off
        return item
    }

    /// 「录音设置」分组：音量格式三项 + 转写引擎 + 纪要模型层。
    ///
    /// 为什么引擎与格式同组：它们共同决定「录下来是什么」——一份文件的规格，
    /// 以及将来读它时用谁。两者也都是「录之前定好、之后不变」的那一类。
    /// 纪要模型层（本地 / 云端 API）与引擎同纪律：全局配置，改一次长期生效，
    /// 且两个入口（顶栏 popover 与本菜单）改的是同一份偏好。
    static func recordingSettingsMenuItem(
        workspace: MeetingWorkspace, target: AnyObject
    ) -> NSMenuItem {
        let root = NSMenu(title: Self.recordingSettingsMenuTitle)

        // 格式排在前面：它决定的是**这一次录制**的产物，一旦开始录就改不了了。
        // 「静默录制」改的是过程中看得见什么、随时能切，所以不在这一组（在「隐私」）。
        root.addItem(Self.toggleItem(
            title: Self.formatMenuTitle,
            current: workspace.pcm16Recording, target: target,
            action: #selector(toggleFormat)))

        // 单声道 + 24 kHz。与位深**相互独立**，所以是两项而不是一组单选——
        // 两个维度各自都能单独带来体积收益，捆成一项就没法只要其中一个。
        root.addItem(Self.toggleItem(
            title: Self.mono24kMenuTitle,
            current: workspace.mono24kRecording, target: target,
            action: #selector(toggleMono24k)))

        // 降混策略紧跟在格式两项之后——它是「单声道 24 kHz」的子设置，
        // 放在同一组里、紧挨着它的上位开关，比平铺在别处更不容易走丢。
        // 入口**常驻**，不跟着 mono24k 灰掉：灰掉看着更「合理」，但用户的路径
        // 恰恰是「先开 mono24k → 录完发现声音不对 → 回头找这个开关」，
        // 入口跟着一起灰掉就等于把排查路径堵在门外。
        root.addItem(Self.downmixMenuItem(
            current: workspace.downmixStrategy, target: target,
            action: #selector(selectDownmix(_:))))

        root.addItem(.separator())
        root.addItem(Self.engineMenuItem(workspace: workspace, target: target))
        root.addItem(Self.minutesProviderMenuItem(workspace: workspace, target: target))

        let summary = Self.specSummary(workspace)
        let entry = NSMenuItem(
            title: "\(Self.recordingSettingsMenuTitle)：\(summary)",
            action: nil, keyEquivalent: "")
        entry.submenu = root
        // 入口标题带一份当前取值摘要，让用户**不点开也知道现在是什么**——
        // 折叠不等于丢信息，顶栏那个标签也是同一条纪律。
        // 摘要写在标题里、不再挂 tooltip：浮层会盖住下面几条（见「说明文案」一节）。
        return entry
    }

    /// 「转写引擎」子菜单。单选：两个引擎互斥，不是两个能同时开的开关。
    ///
    /// 引擎选择此前**只有主窗口顶栏一个入口**，而顶栏只在 idle 时才显示那三个开关——
    /// 也就是说菜单栏这条路完全不通。收进分组之后两处改的是同一份偏好，
    /// 下一场生效，这与它在 `RecorderPreferences` 里的「全局设置」定义一致。
    static func engineMenuItem(
        workspace: MeetingWorkspace, target: AnyObject
    ) -> NSMenuItem {
        let root = NSMenu(title: Self.engineMenuTitle)
        for candidate in TranscriptionEngine.allCases {
            let item = NSMenuItem(
                title: candidate.displayName,
                action: #selector(selectEngine(_:)), keyEquivalent: "")
            item.target = target
            item.state = candidate == workspace.transcriptionEngine ? .on : .off
            item.representedObject = candidate.rawValue
            root.addItem(item)
        }
        // 两个引擎的取舍（离线 / 要下模型 / 识别更稳）写在设置窗口那一行说明里，
        // 菜单只负责列出来并勾出当前值。
        let entry = NSMenuItem(
            title: "\(Self.engineMenuTitle)：\(workspace.transcriptionEngine.displayName)",
            action: nil, keyEquivalent: "")
        entry.submenu = root
        return entry
    }

    /// 「会议纪要」子菜单。单选：本地 / 云端 API 互斥，与转写引擎同构。
    ///
    /// **为什么这一项必须进状态栏菜单**：纪要的云端配置（Base URL / Key /
    /// 模型名）只能在主窗口顶栏的「录音设置」popover 里填，而主窗口恰好是
    /// 用户「没看到配置入口」时最不可能会去看的地方——症状就是菜单里翻了
    /// 一遍没有纪要，以为功能没上线。状态栏这条路原本完全不通（与引擎此前的
    /// 处境相同），补上之后两处改的是同一份偏好，不存在「哪个是权威」。
    ///
    /// 云端缺项时标题当场写「还缺 X」并给一个跳转动作——只显示「云端 API」
    /// 的话，用户选完发现 `minutes` 报错，感觉像「刚配好又坏了」。
    static func minutesProviderMenuItem(
        workspace: MeetingWorkspace, target: AnyObject
    ) -> NSMenuItem {
        let root = NSMenu(title: Self.minutesMenuTitle)
        for candidate in MinutesProvider.allCases {
            let item = NSMenuItem(
                title: candidate.displayName,
                action: #selector(selectMinutesProvider(_:)), keyEquivalent: "")
            item.target = target
            item.state = candidate == workspace.minutesProvider ? .on : .off
            item.representedObject = candidate.rawValue
            root.addItem(item)
        }

        // 选了云端但没配齐：给一个直达动作。菜单里没法安全地输入密钥
        // （AppKit 菜单没有 SecureField），所以这里只负责「带用户到能填的地方」。
        // **缺哪几项写进标题**，不靠浮层——标题不点开也读得到，浮层要悬停。
        if workspace.minutesProvider == .cloudAPI,
           !workspace.minutesCloudAPIIsComplete {
            root.addItem(.separator())
            let missing = workspace.missingMinutesCloudAPIItems.joined(separator: "、")
            let go = NSMenuItem(
                title: "打开设置补全配置（还缺 \(missing)）…",
                action: #selector(openMinutesCloudSetup), keyEquivalent: "")
            go.target = target
            root.addItem(go)
        }

        let entry = NSMenuItem(
            title: "\(Self.minutesMenuTitle)：\(minutesMenuTitleSuffix(workspace))",
            action: nil, keyEquivalent: "")
        entry.submenu = root
        return entry
    }

    /// 入口标题的当前值部分。缺项时当场写进标题——不点开也知道缺什么。
    static func minutesMenuTitleSuffix(_ workspace: MeetingWorkspace) -> String {
        guard workspace.minutesProvider == .cloudAPI else {
            return MinutesProvider.local.displayName
        }
        guard workspace.minutesCloudAPIIsComplete else {
            let missing = workspace.missingMinutesCloudAPIItems.joined(separator: "、")
            return "云端模型 API（还缺 \(missing)）"
        }
        return MinutesProvider.cloudAPI.displayName
    }

    /// 「存储与清理」组内三个动作各自要接的 selector。
    ///
    /// 静态构造拿不到实例，而把整个控制器改成可注入的代价远大于这一处的参数。
    /// 打包成结构体传，比三个并列参数更容易在调用处核对对错——
    /// 三个并列 selector 里错一个，症状是「点某一项没反应」，极难定位。
    struct StorageActions {
        let selectRetention: Selector
        let pruneOldAudio: Selector
        let toggleAutoPrune: Selector
    }

    /// 「存储与清理」分组。**这一组会删用户数据**，所以独立成组。
    ///
    /// 组内顺序刻意是「档位 → 立即清理 → 自动清理」，也就是**先规则、后执行**：
    /// 用户照着从上往下点，天然是「先决定按什么规则，再决定要不要现在执行」。
    static func storageMenuItem(
        workspace: MeetingWorkspace, target: AnyObject, actions: StorageActions
    ) -> NSMenuItem {
        let root = NSMenu(title: Self.storageMenuTitle)

        // 「设档位」与「执行清理」是两个独立动作——改一个下拉框的期望是
        // 「以后按这个规则办」，不是「帮我清一批」。它们在 GUI 侧同样成立。
        root.addItem(Self.retentionMenuItem(
            current: workspace.retentionPolicy, target: target,
            action: actions.selectRetention))

        let prune = NSMenuItem(
            title: Self.pruneMenuTitle, action: actions.pruneOldAudio, keyEquivalent: "")
        prune.target = target
        // 入口**常驻**，但档位为关闭时禁用（它清不了任何东西）。
        // 不灰掉而藏起来是不行的：用户会以为这个功能不存在，
        // 而他恰恰是在「打开它发现没地方设」时才需要知道它存在。
        prune.isEnabled = workspace.retentionPolicy.isEnabled
        root.addItem(prune)

        // 自动清理。**单独一项，不与档位绑定。**
        //
        // 分开的理由很具体：档位是「按什么规则清」，这一项是「谁去清」。
        // 合成一项的话，用户为了「看看效果」把档位设成 7 天，
        // 几周后老录音自动消失，而他唯一做过的动作是选了个下拉框。
        // 所以**默认关**，要用户自己点头。
        root.addItem(.separator())
        root.addItem(Self.toggleItem(
            title: Self.autoPruneMenuTitle,
            current: workspace.autoPruneEnabled, target: target,
            action: actions.toggleAutoPrune))

        // 只在「自动清理开着、档位却没设」这一种组合下提示——
        // 那是唯一「开了等于没开」的状态，而且是**静默**的：没有这一行，
        // 用户会以为每天在清，实际一件都没删。两个都是关时提示就是纯噪音。
        if workspace.autoPruneEnabled, !workspace.retentionPolicy.isEnabled {
            let warning = NSMenuItem(
                title: "当前保留档位是「\(workspace.retentionPolicy.displayName)」，"
                    + "清理不会执行——先在上面选一个天数",
                action: nil, keyEquivalent: "")
            warning.isEnabled = false
            root.addItem(warning)
        }

        let entry = NSMenuItem(
            title: "\(Self.storageMenuTitle)：\(workspace.retentionPolicy.displayName)",
            action: nil, keyEquivalent: "")
        entry.submenu = root
        return entry
    }

    /// 「立即清理」与「每天自动清理」的说明**不在菜单里**。
    ///
    /// 这两项是**会删数据**的动作，讲清代价的地方应该是「按下确认之前」——
    /// 也就是 `retentionConfirmationText` 与 `toggleAutoPrune` 里那两个
    /// 带场次数、体积的弹窗，而不是菜单项的浮层。原来那两段文案正好挂在
    /// 浮层上，一悬停就盖住「每天自动清理一次」本身。

    /// 「隐私」分组。**只放静默录制**。
    ///
    /// 为什么不给它多留位置：现在只有这一项，为一项建子菜单是纯粹的间接。
    /// 但**入口必须留着**——单选分组并到别处去，将来第二项隐私设置就有地方放，
    /// 而这一项也不必在每次新增设置时被重新安排位置。
    static func privacyMenuItem(
        workspace: MeetingWorkspace, target: AnyObject, action: Selector
    ) -> NSMenuItem {
        let root = NSMenu(title: Self.privacyMenuTitle)
        // 标题与首行一样，始终如实——藏的是菜单栏上那个被动可见的图标，
        // 不是「点开菜单之后你看到的东西」。理由很实际：这份菜单只有在你**主动点开**
        // 时才会出现，而如果连它都不说，用户会彻底失去「现在到底录着没有」的答案——
        // 那会直接导致「以为自己没在录，于是又开了一场」或「录完忘了停」。
        root.addItem(Self.toggleItem(
            title: Self.concealMenuTitle,
            current: workspace.hidesStatusBarCountdown, target: target,
            action: action))

        // 入口标题带当前状态，与另外三个分组同一条纪律：
        // 「隐私」这个词本身什么都不说明，而用户最想知道的是「现在录着能不能被看见」。
        let entry = NSMenuItem(
            title: "\(Self.privacyMenuTitle)：\(Self.privacyStateText(workspace))",
            action: nil, keyEquivalent: "")
        entry.submenu = root
        return entry
    }

    /// 隐私组的当前状态。**纯函数**：它会被断言，也会被探针读。
    static func privacyStateText(_ workspace: MeetingWorkspace) -> String {
        workspace.hidesStatusBarCountdown ? "已隐藏录制痕迹" : "照常显示"
    }

    /// 「菜单栏」分组。**只有图标显隐一项**，与「隐私」同一条理由：
    /// 为一项建子菜单是间接，但入口必须留着——这一组的处境比隐私更微妙，
    /// **关掉图标之后这份菜单本身就没了**（图标没了，菜单无处可点）。
    /// 所以恢复路径只能靠另外两个入口，这一点写进了 `statusIconHelp`
    /// 与每个开关的说明里，不让用户去猜。
    static func menuBarMenuItem(
        workspace: MeetingWorkspace, target: AnyObject, action: Selector
    ) -> NSMenuItem {
        let root = NSMenu(title: Self.menuBarMenuTitle)
        root.addItem(Self.toggleItem(
            title: Self.statusIconMenuTitle,
            current: workspace.showsStatusBarIcon, target: target,
            action: action))

        let entry = NSMenuItem(
            title: "\(Self.menuBarMenuTitle)：\(workspace.showsStatusBarIcon ? "显示中" : "已隐藏")",
            action: nil, keyEquivalent: "")
        entry.submenu = root
        return entry
    }

    /// 录音规格的一行摘要。入口标题与提示语共用这一个出处。
    ///
    /// **「源采样率」不是偷懒的占位符，它是在不说谎**：省多少完全取决于设备给的格式，
    /// 有些麦克风（如 AirPods）本身就只给 24 kHz 单声道。写死「48 kHz 立体声」
    /// 会在 AirPods 上变成一句假话，而这种错用户自己发现不了。
    /// 位深那一截不受设备影响，可以给准数。
    static func specSummary(_ workspace: MeetingWorkspace) -> String {
        RecordingSettingSummary.summary(
            pcm16: workspace.pcm16Recording,
            mono24k: workspace.mono24kRecording,
            engine: workspace.transcriptionEngine,
            hidesCountdown: workspace.hidesStatusBarCountdown
        ).labelText
    }


        private var statusLine: String {
        switch recorder.phase {
        case .idle, .finished, .failed: return "会议录音器"
        case .preparing: return "正在准备音频设备…"
        case .recording: return "录制中 \(Self.clock(recorder.elapsed))"
        case .paused: return "已暂停 \(Self.clock(recorder.elapsed))"
        case .stopping: return "正在保存…"
        }
    }

    private func command(
        title: String, shortcut: String, action: Selector, enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut)
        // 与 Carbon 全局热键用同一套组合。两者不会重复触发：
        // 注册成功的组合会被系统热键拦下，根本到不了菜单的按键处理。
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = self
        item.isEnabled = enabled
        return item
    }

    // MARK: - 动作

    @objc private func startRecording() {
        // 走 workspace 的统一入口，标题的时间序号在那一处生成
        workspace.startRecording(titleBase: "")
    }

    @objc private func togglePause() { recorder.togglePause() }

    @objc private func stopRecording() { recorder.stop() }

    @objc private func showWindow() { onShowWindow() }

    @objc private func toggleConceal() { workspace.hidesStatusBarCountdown.toggle() }

    /// 切换菜单栏图标。**打开永远安全；关闭要在录制中先确认一次。**
    ///
    /// 为什么关闭要确认：关掉它的那一刻，菜单栏上唯一跟着录音走的东西
    /// （计时、红点）会一起消失。录音本身不受影响（快捷键与主窗口都在），
    /// 但「录着录着发现菜单栏什么都没了」足以让人以为录崩了——
    /// 而这个误会只需要一次点击就能避免，所以值得。
    /// 空闲时不需要确认：那时候菜单栏上本来就没有任何状态可看。
    @objc private func toggleStatusBarIcon() {
        // 此刻是关着的 → 打开，永远安全，不需要确认。
        guard workspace.showsStatusBarIcon else {
            workspace.showsStatusBarIcon = true
            return
        }
        // 此刻是开着的 → 关闭。录制中要先说清代价：那一刻菜单栏上
        // 唯一跟着录音走的东西（计时、红点）会一起消失。录音本身不受影响，
        // 但「录着录着发现菜单栏什么都没了」足以让人以为录崩了——
        // 而这个误会只需要一次点击就能避免，所以值得。
        // 空闲时不确认：那时候菜单栏上本来也没有任何状态可看。
        guard Self.shouldConfirmHidingIcon(phase: recorder.phase) else {
            workspace.showsStatusBarIcon = false
            return
        }
        let alert = NSAlert()
        alert.messageText = Self.hideIconAlertTitle
        alert.informativeText = Self.hideIconAlertMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: "隐藏图标")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        workspace.showsStatusBarIcon = false
    }

    /// 关闭图标前要不要先确认。**纯函数**，三个入口（本菜单、顶栏面板、
    /// 设置窗口）的判断都走它——各判一次的话，「菜单里要确认、面板里不确认」
    /// 这种分裂是必然的，而它没有任何理由存在。
    ///
    /// 判据直接复用 `leaksRecording`：会泄露「正在录」的四个相位才需要确认。
    /// `.failed` 刻意不在其中——那时候菜单栏上写着失败原因，
    /// 藏不藏图标都不影响用户得知出了错。
    static func shouldConfirmHidingIcon(phase: RecordingController.Phase) -> Bool {
        leaksRecording(phase)
    }

    /// 切换转写引擎。
    ///
    /// **只落盘，不做任何副作用动作**——不下载模型、不切当前这场。
    /// 与「设保留档位」同一条纪律：用户点这一下时想的是「以后用这个」，
    /// 不是「现在开始下 244 MiB」。资产该下载时，界面上的资产区自己会给入口。
    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let engine = TranscriptionEngine(rawValue: raw) else { return }
        workspace.transcriptionEngine = engine
    }

    @objc private func selectMinutesProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        // 走 `resolving`：历史遗留/陌生值回退本地，绝不静默选中会把数据传出本机的那一档。
        workspace.minutesProvider = MinutesProvider(resolving: raw)
    }

    /// 「打开设置补全配置…」：菜单里没法安全输入密钥，把用户带到能填的地方。
    ///
    /// 2026-10-22 起送去**设置窗口**（⌘,）而不是主窗口顶栏：那三项输入框现在
    /// 是设置窗口「会议纪要」页的正式位置，顶栏 popover 只留「用谁」。
    /// 送错地方的症状很具体——用户被带到主窗口，还得自己猜再点哪个按钮。
    @objc private func openMinutesCloudSetup() {
        onShowSettings()
    }

    /// 「设置…」：打开真正的设置窗口（与 ⌘, 同一个窗口）。
    ///
    /// 动作放在控制器这里而不是直接调 `SettingsWindowController.shared`：
    /// 这样测试能注入假的 `onShowSettings` 验证「点了会叫到设置窗口」，
    /// 而不用去断言一个真实 NSWindow 出现了。
    @objc private func openSettingsWindow() {
        onShowSettings()
    }

    // MARK: - 可测的纯函数

    /// 「降混策略」子菜单。抽成静态函数是为了**能测**：
    /// 菜单项的标题、勾选状态、说明文案必须与 `MonoDownmixStrategy` 逐字一致，
    /// 而真机上验证菜单得点开状态栏图标——那不是单测能做的事。
    ///
    /// `target` / `action` 由调用方传入：静态方法拿不到实例，而把整个
    /// `StatusItemController` 改成可注入的代价远大于这一处的参数。
    static func downmixMenuItem(
        current: MonoDownmixStrategy,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        let root = NSMenu(title: Self.downmixMenuTitle)
        for strategy in MonoDownmixStrategy.allCases {
            let item = NSMenuItem(
                title: strategy.displayName, action: action, keyEquivalent: "")
            item.target = target
            item.state = strategy == current ? .on : .off
            item.representedObject = strategy.rawValue
            root.addItem(item)
        }
        let entry = NSMenuItem(
            title: "\(Self.downmixMenuTitle)：\(current.displayName)",
            action: nil, keyEquivalent: "")
        entry.submenu = root
        return entry
    }

    /// 「保留策略」子菜单。抽成静态函数的理由与 `downmixMenuItem` 完全一样：
    /// 菜单项的标题、勾选状态、说明文案必须与 `RetentionPolicy` 逐字一致，
    /// 而真机上验证菜单得点开状态栏图标——那不是单测能做的事。
    static func retentionMenuItem(
        current: RetentionPolicy,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        let root = NSMenu(title: Self.retentionMenuTitle)
        for policy in RetentionPolicy.selectableCases {
            let item = NSMenuItem(
                title: policy.displayName, action: action, keyEquivalent: "")
            item.target = target
            item.state = policy == current ? .on : .off
            item.representedObject = policy.rawValue
            root.addItem(item)
        }
        let entry = NSMenuItem(
            title: "\(Self.retentionMenuTitle)：\(current.displayName)",
            action: nil, keyEquivalent: "")
        entry.submenu = root
        return entry
    }

    /// 清理前的确认文案。**抽成纯函数**是为了让「不可恢复」「会删几场」这些
    /// 关键事实能被断言——它们只出现在弹窗里，不抽出来就只能靠人眼读。
    static func retentionConfirmationText(plan: SessionRetentionCleaner.Plan) -> String {
        var lines: [String] = []
        if plan.isEmpty {
            let reason = plan.rootNote ?? "按当前档位，没有符合条件的会议。"
            return "没有要清理的内容：\(reason)"
        }
        lines.append("将把 \(plan.sessionCount) 场会议的**音频文件移入废纸篓**，"
            + "共约 \(Self.humanSize(plan.reclaimableBytes))。")
        lines.append("")
        lines.append("保留：转写稿（.md 与 .json）、manifest、会议标题与时长——"
            + "列表里这几场仍会在，只是显示为「0 轨」。")
        lines.append("删除：各场的音频文件（.wav）。**清空废纸篓之后就找不回来了。**")
        if !plan.skipped.isEmpty {
            lines.append("")
            lines.append("跳过 \(plan.skipped.count) 场：")
            for s in plan.skipped.prefix(5) {
                lines.append("· \(s.title)：\(s.skipReason ?? "")")
            }
            if plan.skipped.count > 5 {
                lines.append("…以及另外 \(plan.skipped.count - 5) 场")
            }
        }
        lines.append("")
        // 顺序提醒必须**在确认之前**、并且带数字。
        // 原来这里只有一句「想先压小体积再清理，可以先跑 transcode --all」——
        // 没有场次数、没有能多腾多少，那句话就只是免责声明：用户不知道
        // 按不按它做，差别是 2.4 MiB 还是 14.3 MiB。
        let uncompressed = plan.uncompressedPrunable
        let extra = plan.additionalBytesIfCompressedFirst
        if !uncompressed.isEmpty, extra > 0 {
            lines.append("⚠️ 其中 \(uncompressed.count) 场**还没压过**。"
                + "先 `mr transcode --preset b-tier --all` 再清理，")
            lines.append("　 能多腾约 \(Self.humanSize(extra))"
                + "（这次清掉的是原始体积，删完就压不成了）。")
        } else {
            lines.append("这些场都已经压过了，不用先转码。")
        }
        return lines.joined(separator: "\n")
    }

    static func humanSize(_ bytes: Int) -> String {
        let mib = Double(bytes) / 1_048_576
        return mib >= 1024
            ? String(format: "%.2f GiB", mib / 1024)
            : String(format: "%.1f MiB", mib)
    }

    // MARK: - 动作

    @objc private func selectDownmix(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let strategy = MonoDownmixStrategy(rawValue: raw) else { return }
        workspace.downmixStrategy = strategy
    }

    @objc private func toggleFormat() { workspace.pcm16Recording.toggle() }

    @objc private func toggleMono24k() { workspace.mono24kRecording.toggle() }

    @objc private func selectRetention(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let policy = RetentionPolicy(resolving: raw) else { return }
        // **只落盘，不清理。** 这条纪律在 GUI 侧同样成立：
        // 用户点这一下时想的不是「帮我清一批」。
        workspace.retentionPolicy = policy
    }

    /// 打开自动清理。
    ///
    /// **打开这一项本身不删任何东西**，与「设档位」同一条纪律：
    /// 它只决定「谁去执行」。当天第一次触发点（启动 / 录完 / 转写完成）才真跑。
    ///
    /// 但打开它要先把话说清：这个开关的效果是「以后会在你不在场时删数据」。
    /// 菜单项的 tooltip 讲了，这里再确认一次——因为**不可逆的删除授权
    /// 值得一次额外的点击**，而这与「设档位」不同（那一项的期望本来就是长期的）。
    @objc private func toggleAutoPrune() {
        let enabling = !workspace.autoPruneEnabled
        guard enabling else {
            workspace.autoPruneEnabled = false
            return
        }
        let alert = NSAlert()
        alert.messageText = "打开每天自动清理？"
        alert.alertStyle = .warning
        var lines: [String] = []
        if workspace.retentionPolicy.isEnabled {
            lines.append("之后每天第一次触发时（启动本应用 / 录完一场 / 转写完成），"
                + "会按当前档位「\(workspace.retentionPolicy.displayName)」自动清理一次，"
                + "**不需要你点「立即清理」**。")
        } else {
            lines.append("⚠️ 当前保留档位是「\(workspace.retentionPolicy.displayName)」，"
                + "清不了任何东西——所以打开它现在不会有任何效果。"
                + "要真的自动清理，请先在「保留策略」里选 7 / 30 / 90 天其中一档。")
        }
        lines.append("")
        lines.append("删除走废纸篓，清空废纸篓就没有了。")
        lines.append("转写稿与 manifest 全部保留；没转写过的会议永远不会被自动清理。")
        lines.append("每天至多一次。想关掉随时点这一项即可。")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "打开自动清理")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        workspace.autoPruneEnabled = true
    }

    @objc private func pruneOldAudio() {
        guard let plan = workspace.retentionPlanSafe() else { return }

        let alert = NSAlert()
        alert.messageText = plan.isEmpty ? "没有要清理的内容" : "清理旧录音？"
        alert.informativeText = Self.retentionConfirmationText(plan: plan)
        alert.alertStyle = .warning
        alert.addButton(withTitle: plan.isEmpty ? "好" : "移入废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn, !plan.isEmpty else { return }

        let outcome = workspace.pruneOldAudioSafe()
        guard let outcome else { return }
        reportPruneResult(outcome, plan: plan)
    }

    /// 清理完成后的汇报。**每一项都要有数字**——删了几场、多少钱、
    /// 跳过了几场。「完成」两个字在删数据的操作之后没有任何信息量。
    private func reportPruneResult(_ outcome: SessionRetentionCleaner.Outcome,
                                   plan: SessionRetentionCleaner.Plan) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        if outcome.deleted.isEmpty && outcome.failed.isEmpty {
            alert.messageText = "没有清理任何内容"
            alert.informativeText = "按当前档位（\(workspace.retentionPolicy.displayName)），"
                + "本次没有符合条件的会议。"
        } else {
            alert.messageText = "已清理 \(outcome.deleted.count) 场、"
                + "\(outcome.deletedFileCount) 个音频文件，约 \(Self.humanSize(outcome.freedBytes))"
            var lines = ["转写稿与 manifest 全部保留。"]
            if !outcome.skipped.isEmpty {
                lines.append("跳过 \(outcome.skipped.count) 场（没转写 / 正在录 / 有合并导出文件等）。")
            }
            if !outcome.failed.isEmpty {
                lines.append("⚠️ \(outcome.failed.count) 场没成功："
                    + outcome.failed.map(\.sessionID).joined(separator: "、"))
            }
            lines.append("文件在废纸篓里，清空废纸篓就没有了。")
            alert.informativeText = lines.joined(separator: "\n")
        }
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
