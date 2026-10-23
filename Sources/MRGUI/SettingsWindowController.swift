import AppKit
import Combine
import SwiftUI
import MRSession

/// 设置窗口的宿主。**全进程一个窗口**，三处入口（主菜单 ⌘,、状态栏菜单、
/// 录音面板里的「打开设置…」）都汇到这里。
///
/// ## 为什么单例而不是每次新建
///
/// 设置窗口是「改到满意为止」的地方：用户填一半觉得 Base URL 填错了，
/// 关掉去别处查一眼再回来——这时必须还是上次的那些草稿。要是每次点击都
/// 新建一个窗口，第二次打开又是空白，用户会以为刚才白填了。
///
/// `isReleasedWhenClosed = false` + 持有引用（与主窗口同一理由，见 `GUIRunner`），
/// 复用才成立。
@MainActor
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var model: MinutesSettingsModel?
    private var hosting: NSHostingView<MinutesSettingsView>?
    private var cancellables: Set<AnyCancellable> = []

    /// 显示设置窗口。已开着就把它叫到前面，不重建。
    func show(workspace: MeetingWorkspace) {
        if window == nil {
            build(workspace: workspace)
        }
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        // 尺寸每次打开都重按内容量一次：偏好可能在别处被改过
        // （`config set minutes api` 会把「云端模型服务」整组打开）。
        fitWindowToContent()
        window.makeKeyAndOrderFront(nil)
        // 从状态栏菜单点过来时，程序本身可能还不是前台应用；
        // 不显式激活的话窗口会开在别的应用后面，像「点了没反应」。
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build(workspace: MeetingWorkspace) {
        let model = MinutesSettingsModel(workspace: workspace)
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsLayout.width,
                                height: SettingsLayout.provisionalHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "会议录音器设置"
        let hosting = NSHostingView(rootView: MinutesSettingsView(model: model))
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        self.window = window
        self.hosting = hosting

        fitWindowToContent()
        window.center()

        // 「本地 ↔ 云端」会整组增减字段（高度差约 285），窗口必须跟着长高/收回。
        //
        // 这条订阅是**必须**的：高度曾写死 660，而云端那一屏真实内容是 746——
        // 窗口不滚，多出来的部分不会报错、不会提示，只是**看不见**。
        workspace.$minutesProvider
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // 等 SwiftUI 把这一帧布局做完再量，否则量到的是切换前的高度
                DispatchQueue.main.async { self?.fitWindowToContent() }
            }
            .store(in: &cancellables)

        // **切页同样会整页换内容**（2026-10-22 起设置窗口分三页）。
        // 录音页 390、云端纪要页 617——高度必须跟着变，否则下半页被静默裁掉。
        //
        // ## 这两条订阅其实是「显式兜底」，不是唯一在起作用的东西
        //
        // 本机实测：`NSHostingView` 当窗口的 `contentView` 时，**自己**就会把窗口
        // 改成内容尺寸，并且上边缘不动（把这两条订阅注释掉再量，切页前后
        // 390 → 617、maxY 都是 1884，一模一样）。所以这里不写「必须」——
        // 那是当年写死 660 时的说法，写在这里会误导下一个读代码的人。
        //
        // 保留它们的理由：不依赖那份隐式行为，也不赌它以后的版本不变。
        // 两条路径给出同一个结果；测试量的是**结果**（窗口不矮于内容、
        // 上边缘不动），所以谁在起作用都不影响判定。
        model.$tab
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.fitWindowToContent() }
            }
            .store(in: &cancellables)
    }

    /// 把窗口高度调整到内容高度（宽度固定）。
    ///
    /// 保持**上边缘不动**：设置窗口是居中的，按默认行为改尺寸会以左下角为锚点，
    /// 于是每次切换模型层窗口都往上长一截、关掉再开位置也不一样。
    private func fitWindowToContent() {
        guard let window, let hosting,
              let size = SettingsLayout.contentSize(for: hosting) else { return }
        let current = window.contentLayoutRect.size
        guard abs(current.height - size.height) > 0.5
                || abs(current.width - size.width) > 0.5 else { return }

        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: window.frame.minX,
                                      y: top - window.frame.height))
    }

    /// 关掉窗口（测试与「退出」用）。留着窗口对象，复用语义不变。
    func closeForTesting() {
        window?.orderOut(nil)
        window = nil
        model = nil
        hosting = nil
        cancellables.removeAll()
    }

    /// 测试用：窗口此刻的内容尺寸（`nil` = 还没建窗）。
    ///
    /// 之所以要暴露这个而不是让测试自己量视图：**要验的是「窗口跟着内容走」**
    /// 这件事本身。让测试另去量 `fittingSize`，窗口即使写死 660 也照样通过。
    var contentSizeForTesting: NSSize? { window?.contentLayoutRect.size }

    /// 测试用：窗口背后的模型。切页与切档位都要经过它。
    ///
    /// 不暴露它就测不了「切页之后窗口有没有跟着长高」——那正是分页带来的
    /// 新失效点（切到云端纪要页，窗口还停在录音页的高度）。
    var modelForTesting: MinutesSettingsModel? { model }

    /// 测试用：窗口的整帧（含标题栏）。用来钉「长高时上边缘不动」——
    /// 只量内容尺寸是量不出来的，那是两个独立的事实。
    var frameForTesting: NSRect? { window?.frame }

    /// 测试用：窗口的 `contentView`。见 `SettingsWindowSizingTests`
    /// 里那条「contentView 必须就是 hosting 本身」——那是一条**有牙**的前提。
    var contentViewForTesting: NSView? { window?.contentView }
}