// 探针：把**生产代码里的**「设置」界面渲染成 PNG，供人眼复核排版。
// （设置窗口按三页分页逐屏拍 + 组件图 + 顶栏「录音设置」面板两屏。）
//
// ## 为什么要有这个探针
//
// 2026-10-19 这次，编译通过、全部单测通过，界面却是**中间一整块空白**：
// 设置界面用了 `ScrollView`，而离屏渲染路径不布局它的内容。
// 只跑断言（「渲染宽度 > 400」）会全绿——它证明不了「三行字段有没有挤成一团」
// 「橙色提示会不会被裁掉」。这个探针就是那一眼。
//
// ## 为什么不是一条单元测试
//
// 渲染含 `TextField` / `SecureField` 的视图会打出 SwiftUI 的 FocusState 警告，
// 而项目守 0 warning，所以它不能待在 `swift test` 的输出里。
// （既有的 `RecordingBarViewRenderTests` 只渲染选择器、不渲染输入框，
// 那条注释写的就是这个原因。）
//
// ## 为什么不用 `ImageRenderer`
//
// `ImageRenderer` 渲染不出输入控件的真实样子（而且 ScrollView 那次直接空白）。
// 这里走**真实窗口**：`NSHostingView` 装进 `NSWindow`，让系统完成一次真正的布局，
// 再用 `contentView.cacheDisplay(in:to:)` 抓位图——这条路径不需要屏幕录制权限，
// 也不需要用户点开 App。
//
// ## 它验证的是生产视图本身
//
// 早先的版本在探针里复制了一份视图骨架，结果既跟编译器打架（`==` 匹配到了
// SwiftUI 的 CoordinateSpace 重载），又天然会与生产代码漂移。现在 `@testable
// import MRGUI` 直接用生产类型：既没有漂移，也没有可见性妥协。
//
// ## 用法
//
//   swift build                       # 先构建出 .o 与 .swiftmodule
//   ./scripts/probes/settings-window-render/run.sh
//   open /tmp/mr-ui-preview/settings-cloud-ok.png
//
// ## 证据边界
//
// 它证明的是**这个进程里、这个主题下的排版**。真实窗口受用户的动态字体设置、
// 外观（深色模式）与显示缩放影响，那些不在这里——真窗口仍要人打开 App 看。
import AppKit
import SwiftUI
@testable import MRGUI
import MRCore
import MRMinutes
import MRSession

/// 一屏设置窗口。
///
/// 2026-10-22 起设置窗口是**三页分页**（录音 / 会议纪要 / 通用），
/// 所以「一屏」多了 `tab` 这一维：同一份配置要按页各拍一张，
/// 否则「云端那页只剩三个输入框、说明跑到别的页去了」这种错看不出来。
private struct Scene {
    var name: String
    var tab: SettingsTab
    var provider: MinutesProvider = .local
    var baseURL: String = ""
    var model: String = ""
    var key: String = ""
    /// 假探测器的返回：nil = 不测（配置不全，界面不给结论）。
    var probe: MinutesAPIProbe.Outcome?
    var preset: MinutesServicePreset?
    /// 菜单栏图标是否显示。默认 true——与生产默认值一致。
    var showsStatusBarIcon: Bool = true
    /// 「单声道 24 kHz」是否打开：决定「降混策略」那一行出不出现。
    var mono24k: Bool = false
}

@MainActor
private func renderScenes(to directory: URL) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mr-settings-preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "mr-settings-preview-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw ProbeError("建不出独立的 UserDefaults suite")
    }
    let workspace = MeetingWorkspace(
        root: root, preferences: RecorderPreferences(defaults: defaults))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    let scenes = [
        // 录音页：默认（两项都关）与打开单声道（多出降混策略一行）。
        Scene(name: "settings-recording", tab: .recording),
        Scene(name: "settings-recording-mono", tab: .recording, mono24k: true),
        // 纪要页：本地档、云端配齐并测通、云端缺项、密钥错。
        Scene(name: "settings-minutes-local", tab: .minutes),
        Scene(name: "settings-minutes-cloud-ok", tab: .minutes, provider: .cloudAPI,
              baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
              key: "sk-probe-placeholder-0000",
              probe: .ok(model: "deepseek-chat", latencyMs: 412, reply: "就绪"),
              preset: .deepSeek),
        Scene(name: "settings-minutes-cloud-incomplete", tab: .minutes, provider: .cloudAPI,
              probe: nil, preset: nil),
        // 配齐了但密钥是错的：按钮可点、结论行是红的。
        // 早先把这屏写成「全空 + 一条失败结论」，结果是界面正确地不给结论
        // （配置不全时不测），于是这一屏根本没画出失败态——它才是用户最常遇到的一屏。
        Scene(name: "settings-minutes-cloud-401", tab: .minutes, provider: .cloudAPI,
              baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
              key: "sk-wrong-key",
              probe: .failed(reason: "密钥无效或没有该模型的权限（HTTP 401）。"
                                   + "检查 API Key 是否填对、是否过期、是否有权限访问模型"),
              preset: .deepSeek),
        // 通用页：图标显示中 / 已隐藏（说明那一行两种态文案不同，排版也不同）。
        Scene(name: "settings-general", tab: .general),
        Scene(name: "settings-general-icon-hidden", tab: .general,
              showsStatusBarIcon: false),
    ]

    for scene in scenes {
        // 每屏重设配置，避免上一屏的残留影响下一屏
        workspace.minutesProvider = scene.provider
        workspace.minutesAPIBaseURL = scene.baseURL
        workspace.minutesModelName = scene.model
        workspace.minutesAPIKey = scene.key
        workspace.showsStatusBarIcon = scene.showsStatusBarIcon
        workspace.mono24kRecording = scene.mono24k

        let probe = scene.probe
        let model = MinutesSettingsModel(workspace: workspace) { _ in
            probe ?? .failed(reason: "未测")
        }
        // 分页也要显式注入：`@Published` 的默认值是 `.recording`，
        // 不设的话所有屏都会拍成录音页——而 PNG 尺寸完全正常。
        model.tab = scene.tab
        if let preset = scene.preset { model.apply(preset: preset) }
        if probe != nil {
            model.runProbe()
            // 让 Task 里的假探测器跑完，截图上才是「刚测完」那一屏
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        // 版本号取**打包产物里的真实值**：探针进程自己没有 Info.plist，
        // `AppVersion.display()` 会如实返回「未知（裸二进制，未经打包）」——
        // 那行字在真实包里不会出现。写死一个字符串又会让图上的版本号与包脱节
        // （拿图当交付证据时会撒谎），所以直接读 .app 里的 plist。
        try writeSizedToContent(
            view: MinutesSettingsView(model: model, versionText: packedVersionText()),
            named: scene.name, to: directory)
    }

    // 组件图：**「说明」就地展开之后长什么样**。
    //
    // 展开态是这一轮才有的排版（原本是 hover 浮层，浮层根本画不进静态图）。
    // `SettingsRow` 的私有 `@State` 靠 `initiallyShowsDetails` 注入；
    // 这里直接用生产组件搭一小组，验证的是**组件本身**，
    // 而「窗口里点开说明会不会把整页顶出可视区」仍要靠窗口那几屏看。
    try writeSizedToContent(
        view: VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "音频格式（说明已展开）") {
                SettingsRow(title: SettingsCopy.mono24kTitle,
                            subtitle: SettingsCopy.mono24kOneLine,
                            details: SettingsCopy.mono24kDetails,
                            initiallyShowsDetails: true) {
                    Toggle("", isOn: .constant(false))
                        .toggleStyle(.switch).labelsHidden()
                }
                SettingsRowDivider()
                SettingsRow(title: SettingsCopy.pcm16Title,
                            subtitle: SettingsCopy.pcm16OneLine,
                            details: SettingsCopy.pcm16Details) {
                    Toggle("", isOn: .constant(true))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
        }
        // 宽度必须**显式限死**成窗口宽度：不限的话 `maxWidth: .infinity`
        // 会按不可达的提议宽度撑开（实测量出 1298 宽、4936 高，图被拉成一长条），
        // 而那张图看上去只是「很长」，不像错。
        .frame(width: SettingsLayout.width)
        .padding(16),
        named: "settings-row-expanded", to: directory)

    // 顶栏「录音设置」面板：420 宽，是全套零件里最窄的一处，排版要单独看一眼。
    workspace.minutesProvider = .local
    workspace.showsStatusBarIcon = true
    try writePopover(
        view: RecordingSettingsPanel(workspace: workspace),
        named: "settings-popover-icon-on", to: directory)
    workspace.showsStatusBarIcon = false
    try writePopover(
        view: RecordingSettingsPanel(workspace: workspace),
        named: "settings-popover-icon-off", to: directory)
}

/// 打包产物里印的版本号（`v2.…`）。读不到就给「未知」，不编一个出来。
private func packedVersionText() -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // main.swift → settings-window-render
        .deletingLastPathComponent()   // → probes
        .deletingLastPathComponent()   // → scripts
        .deletingLastPathComponent()   // → 仓库根（少删一层就会读不到 plist）
    let plist = root.appendingPathComponent("MeetingRecorder.app/Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
          let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let info = obj as? [String: Any] else { return "（未打包）" }
    return AppVersion.display(shortVersion: AppVersion.shortVersion(from: info),
                              build: AppVersion.build(from: info))
}

/// 设置窗口专用：宽度按生产常量，高度**按内容**。
///
/// 判据与 `SettingsWindowController.fitWindowToContent()` 同一个（`fittingSize`）。
/// 这里绝不能写死高度：2026-10-21 就是窗口写死 660、云端那一屏真实 746，
/// 标题被顶出可视区，而 PNG 尺寸看上去完全正常——图是「对的」，内容是缺的。
@MainActor
private func writeSizedToContent(
    view: some View, named name: String, to directory: URL
) throws {
    let width = SettingsLayout.width
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 2000))
    // **调生产代码里的同一份判据**，不在这里另写一遍「按内容高度」：
    // 探针自己算高度，验证的就是探针自己。
    guard let size = SettingsLayout.contentSize(for: hosting) else {
        throw ProbeError("量不出设置窗口内容的自然高度")
    }
    try write(view: view, named: name, to: directory, size: size)
}

/// 一个真实窗口 → 完成布局 → 抓位图。
@MainActor
private func write(
    view: some View, named name: String, to directory: URL,
    size: NSSize = NSSize(width: SettingsLayout.width, height: 640)
) throws {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.contentView = hosting
    // 必须真的显示一次，SwiftUI 才会跑完布局。`orderFront` 在 `.accessory`
    // 激活策略下不会把程序抢到前台。
    window.orderFront(nil)
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))

    print("MEASURE \(name) fitting=\(hosting.fittingSize)")
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        throw ProbeError("拿不到缓存用的位图上下文")
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    window.orderOut(nil)

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw ProbeError("PNG 编码失败")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(name).png")
    try png.write(to: url)

    let colors = countDistinctColors(rep)
    print("✅ \(url.path)（\(rep.pixelsWide)×\(rep.pixelsHigh)，\(colors) 种颜色）")
    if colors < 8 {
        print("⚠️  \(name) 只有 \(colors) 种颜色——很可能整块没画出来")
    }
}

/// 顶栏 popover 专用：宽度**也从 `fittingSize` 里读**，不在这里另写一个数。
///
/// 早先这里写死 `380`，面板改成 420 之后探针照样按 380 开窗——
/// 于是它拍出来的是一张**被压窄的**面板：内容折行、控件挤在一起，
/// 而图上完全看不出「这是探针自己的宽度」。生产视图自己带 `.frame(width:)`，
/// 量出来就是它真正的宽度。
///
/// 写死一个高度同样不行：说明文字行数随内容变，写小了会被裁掉，
/// 而「被裁掉的说明」在一张尺寸正常的 PNG 上照样看不出来——
/// 只有按内容高度开窗，裁没裁才在图上留得下。
@MainActor
private func writePopover(
    view: some View, named name: String, to directory: URL
) throws {
    let hosting = NSHostingView(rootView: view)
    // 先给一个足够高的框量一次 fittingSize，再按结果开窗
    hosting.frame = NSRect(origin: .zero, size: NSSize(width: 600, height: 2000))
    hosting.layoutSubtreeIfNeeded()
    let fitted = hosting.fittingSize
    guard fitted.width > 100, fitted.height > 100 else {
        throw ProbeError("量不出面板的自然尺寸：\(fitted)")
    }
    print("MEASURE \(name) popover=\(fitted)")
    try write(view: view, named: name, to: directory, size: fitted)
}

/// 粗略统计不同像素值的个数，用来识别「整块纯色」。
///
/// 这条检查是探针的真正价值所在：界面空白时 PNG 照样有正常尺寸，
/// 「文件生成了」这件事本身证明不了任何东西。
private func countDistinctColors(_ rep: NSBitmapImageRep) -> Int {
    guard let data = rep.representation(using: .png, properties: [:]),
          let image = NSImage(data: data),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let pixels = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return 0 }
    pixels.size = NSSize(width: cg.width, height: cg.height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    }
    NSGraphicsContext.restoreGraphicsState()

    // 抗锯齿会让每个字边缘都产生几十种灰阶，所以这里按 7×7 的格子**量化**
    // （每格取中心像素 >>4，即 16 级）后再统计：粗体/普通、抗锯齿这些噪声
    // 都被抹掉，剩下的就是真正的颜色块数量——三屏的数值才有区分度。
    // 上一版步长 3、上限 240，三屏全部打满同一个数，等于没检查。
    var seen = Set<UInt32>()
    guard let bytes = pixels.bitmapData else { return 0 }
    let rowBytes = pixels.bytesPerRow
    for y in stride(from: 0, to: pixels.pixelsHigh, by: 7) {
        for x in stride(from: 0, to: pixels.pixelsWide, by: 7) {
            let offset = y * rowBytes + x * 4
            let base = bytes.advanced(by: offset)
            let red = UInt32(base[0]) >> 4
            let green = UInt32(base[1]) >> 4
            let blue = UInt32(base[2]) >> 4
            let alpha = UInt32(base[3]) >> 4
            seen.insert((red << 12) | (green << 8) | (blue << 4) | alpha)
        }
    }
    return seen.count
}

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    // `.accessory`：不在 Dock 与菜单栏露面，也不抢前台
    application.setActivationPolicy(.accessory)
    do {
        try renderScenes(to: URL(fileURLWithPath: "/tmp/mr-ui-preview"))
        print("\n看一眼：open /tmp/mr-ui-preview/settings-recording.png")
        print("        open /tmp/mr-ui-preview/settings-minutes-cloud-ok.png")
        print("        open /tmp/mr-ui-preview/settings-general.png")
        print("        open /tmp/mr-ui-preview/settings-row-expanded.png")
        print("        open /tmp/mr-ui-preview/settings-popover-icon-off.png")
    } catch {
        FileHandle.standardError.write(Data("❌ 渲染失败：\(error)\n".utf8))
        exit(1)
    }
    exit(0)
}