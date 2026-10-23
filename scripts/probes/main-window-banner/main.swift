// 探针：把**生产代码里的**主窗口渲染成 PNG，复核「菜单栏图标已隐藏」横幅。
//
// ## 为什么要有这个探针
//
// 横幅是 2026-10-20 那一轮的真实事故催生的：用户关掉菜单栏图标后
// 「退出重开」想恢复默认，而重启后主窗口上**没有任何东西**告诉他
// 图标是自己关的、该去哪开回来。横幅就是为这个场景加的——
// 它必须出现在用户重启后第一眼看到的位置（顶栏正下方）。
//
// 而「忘了挂」「挂反了条件」「挂在了被折叠/滚动出屏的位置」这类问题
// 编译与单测全都合法：单测只渲染横幅本身（`StatusItemIconVisibilityTests`），
// 证明不了它在主窗口里的**位置与挤占效果**。判据只能是人眼看：
//
// - 横幅必须在顶栏下方、列表上方，不需要滚动就看得见；
// - 出现时不许把顶栏或列表顶挤出屏/压扁；
// - 图标恢复正常时横幅必须消失（不留一条橙色带子）。
//
// 这里走**真实窗口**（NSHostingView 装进 NSWindow，系统完成一次真正的布局），
// 再用 `contentView.cacheDisplay(in:to:)` 抓位图，不需要屏幕录制权限。
// 不用 ImageRenderer：主窗口含 ScrollView，离屏不布局会画出整块空白
// 而颜色数断言照样绿（设置窗口那次踩过的坑）。
//
// ## 用法
//
//   swift build
//   ./scripts/probes/main-window-banner/run.sh
//   open /tmp/mr-ui-preview/window-banner-*.png
import AppKit
import SwiftUI
@testable import MRGUI
import MRCore
import MRMinutes
import MRSession

@MainActor
private func renderScenes(to directory: URL) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mr-window-preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "mr-window-preview-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw ProbeError("建不出独立的 UserDefaults suite")
    }
    let workspace = MeetingWorkspace(
        root: root, preferences: RecorderPreferences(defaults: defaults))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    // 三屏：图标开着（横幅与提示都不该出现）/ 图标关着（横幅该在）/
    // **系统没登记这个菜单栏项**（提示该在，且**不给**「把窗口移过去」的动作）。
    //
    // 第三屏的语义在 2026-10-20 变过一次：原来叫「跨屏」，说「图标在另一块屏上」
    // 并给一个搬窗口的按钮。**那个前提已被证伪**——状态栏项在每块屏的菜单栏上
    // 各有一份、始终同步，「只在另一块屏上」这个状态不存在；而那个按钮
    // 只会擅自搬走用户自己的窗口。现在提示只回答「系统有没有登记这个项」。
    //
    // 刻意用同一个 workspace 连续渲染：横幅与提示的出现与消失都由
    // `workspace` 上的 @Published 驱动，屏与屏之间只翻这几个值，
    // 与用户在主窗口里点「恢复图标」后看到的是同一条路径。
    let scenes: [(name: String, showsIcon: Bool, screenHint: String?, relocate: UInt32?)] = [
        ("window-banner-on", true, nil, nil),
        ("window-banner-off", false, nil, nil),
        ("window-icon-not-registered", true,
         "系统没有把这个应用登记进菜单栏——所以菜单栏上找不到它的图标。"
            + "退出应用后从访达双击重新打开即可（直接运行 .app 里的二进制会让系统"
            + "永久拒绝登记本应用，图标就再也出不来了）。录音与快捷键不受影响。",
         nil),
    ]

    for scene in scenes {
        workspace.showsStatusBarIcon = scene.showsIcon
        workspace.statusIconScreenHint = scene.screenHint
        workspace.statusIconRelocateScreenID = scene.relocate
        print("— \(scene.name)：图标\(scene.showsIcon ? "开" : "关")"
            + "，提示\(scene.screenHint == nil ? "无" : "有")")
        try write(view: MeetingRecorderRootView(workspace: workspace),
                  named: scene.name, to: directory)
    }
}

/// 一个真实窗口 → 完成布局 → 抓位图。
@MainActor
private func write(view: some View, named name: String, to directory: URL) throws {
    // 与主窗口的 `.frame(minWidth: 960, minHeight: 620)` 一致。
    let size = NSSize(width: 960, height: 620)
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.contentView = hosting
    // 必须真的显示一次，SwiftUI 才会跑完布局。
    window.orderFront(nil)
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))

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

/// 粗略统计不同像素值的个数，用来识别「整块纯色」。
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

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let output = URL(fileURLWithPath: "/tmp/mr-ui-preview")
try MainActor.assumeIsolated {
    try renderScenes(to: output)
}
print("\n看一眼：open \(output.path)/window-banner-*.png")
