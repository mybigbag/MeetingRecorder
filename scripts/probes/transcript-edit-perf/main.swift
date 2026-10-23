// 探针：**1375 段**的一场会议，详情页首屏与「进编辑态」到底要画多久。
//
// ## 为什么不能只靠「感觉快了」
//
// 反馈的是「编辑转写稿一直卡顿」。改法有三层（草稿簿、`LazyVStack`、
// 防抖写盘），每一层都能讲出一套道理——但道理不能当证据。
// 这里量的是**真实视图在真实窗口里的首屏耗时**：
//
//   read   ：阅读态首屏（1375 段文本）
//   edit   ：编辑态首屏（**一次性要建出可见的那十几行输入框**）
//
// 其中 `edit` 是上限：进编辑态的这个动作，比「在新窗口里冷起一份编辑态」要便宜。
// 所以它慢 = 一定卡；它快 = 这条路上没有秒级的坑。
//
// ## 为什么阈值写得这么松
//
// 这台机器上没有基线（旧实现已经删了），而且 SwiftUI 的首帧受字体缓存、
// 窗口层级、主题影响。所以这里只判「有没有量级问题」——
// 超过 3 秒直接红（那不是卡顿，是假死），超过 1.2 秒打警告（值得再查）。
// 具体快慢看打印出来的毫秒数，别把阈值当成验收线。
//
// ## 用法
//
//   swift build
//   ./scripts/probes/transcript-edit-perf/run.sh
import AppKit
import SwiftUI
@testable import MRGUI
import MRCore
import MRMinutes
import MRSession

setvbuf(stdout, nil, _IONBF, 0)

private let sessionID = "2026-10-22-101500-千段会议性能"

/// 量首屏时要的状态：**三栏全展开**。
///
/// 2026-10-22 起转写稿默认是折叠的，而本探针量的正是那几百行的渲染成本——
/// 用默认值会量到一个空壳（0 个输入框），然后报「测不出」。
private var expandedAllSections: DetailCollapseState {
    var state = DetailCollapseState()
    for section in DetailSection.allCases {
        state.setCollapsed(false, for: section, in: sessionID)
    }
    return state
}

/// 1375 段、每段约 60 字：本机真实存在的那场会就是这个量级。
private func makeLongTranscript() -> TranscriptDocument {
    TranscriptDocument(
        sessionID: sessionID,
        title: "千段会议性能",
        language: "zh-CN",
        engine: "apple",
        segments: (0..<1375).map { index in
            TranscriptSegment(
                start: Double(index) * 4,
                end: Double(index) * 4 + 3.5,
                text: "第 \(index + 1) 段：这次版本下线我们先把灰度范围收窄到一个部门，"
                    + "观察两天的支付成功率与崩溃率，没有异常再放全量，"
                    + "回滚演练和帮助文档要在这周内补上。",
                track: index.isMultiple(of: 2) ? "mic" : "system",
                speaker: index.isMultiple(of: 2) ? "我" : "对方")
        })
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url)
}

@MainActor
private func descendantCount(_ view: NSView) -> (total: Int, fields: Int) {
    var total = 0, fields = 0
    func walk(_ v: NSView) {
        total += 1
        // 只数**可编辑**的输入框：`NSTextField` 这个类在读态也会出现
        // （标题、滑块旁的读数都可能是它），数它会把两态混成一件事。
        if let field = v as? NSTextField, field.isEditable { fields += 1 }
        v.subviews.forEach(walk)
    }
    walk(view)
    return (total, fields)
}

@MainActor
private func measure(name: String, editing: Bool,
                     workspace: MeetingWorkspace) -> (ms: Double, total: Int, fields: Int) {
    let player = TrackPlayer()
    let view = MeetingDetailView(
        workspace: workspace, player: player,
        // **必须显式展开转写稿**：它现在是默认折叠的，而本探针量的正是
        // 转写稿那几百行的首屏成本。用默认值会量到一个空壳（0 个输入框）。
        initialCollapse: expandedAllSections,
        initialEditingTranscript: editing)

    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)

    let start = Date()
    // SwiftUI 的内容要等一轮 runloop 才会挂到视图树上；只 `layoutSubtreeIfNeeded()`
    // 的话量到的是空壳（27 ms「很快」），那是假绿——所以先让 runloop 跑一趟。
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    // 布局 → 显示 → 把图层渲到位：只 layout 不 display 会把「画出来」的成本漏掉，
    // 而那正是用户眼睛看到的卡顿。
    hosting.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    if let layer = hosting.layer { layer.displayIfNeeded() }
    let ms = Date().timeIntervalSince(start) * 1000

    let counts = descendantCount(hosting)
    print(String(format: "  %@：%.0f ms（子视图 %d 个，其中 NSTextField %d 个）",
                 name, ms, counts.total, counts.fields))
    window.orderOut(nil)
    window.contentView = nil
    return (ms, counts.total, counts.fields)
}

MainActor.assumeIsolated {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mr-perf-\(UUID().uuidString)", isDirectory: true)
    let suiteName = "mr-perf-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!

    NSApplication.shared.setActivationPolicy(.accessory)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest = RecordingManifest(sessionID: sessionID, title: "千段会议性能",
                                         startedAt: Date(), tracks: [])
        manifest.state = .transcribed
        try writeJSON(manifest, to: dir.appendingPathComponent(SessionStore.manifestFileName))
        try writeJSON(makeLongTranscript(),
                      to: dir.appendingPathComponent(SessionStore.transcriptJSONName))

        let workspace = MeetingWorkspace(
            root: root, preferences: RecorderPreferences(defaults: defaults))
        workspace.refresh()
        workspace.select(sessionID)
        // `select` 的详情加载是异步的，必须排空一次，否则量的是空壳。
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let document = workspace.transcript, document.segments.count > 1000 else {
            print("❌ 夹具没加载出来（transcript 为空或段数不足），测不出结论。")
            exit(2)
        }
        print("=== 详情页首屏耗时（\(document.segments.count) 段）===")

        let read = measure(name: "阅读态首屏", editing: false, workspace: workspace)
        let edit = measure(name: "编辑态首屏（要建输入框）", editing: true, workspace: workspace)

        // 判据先证明「真的画了东西」：空壳也能「很快」，
        // 那种数字就是假绿——宁可报「测不出」。
        // 判据先证明「真的画了东西」：空壳也能「很快」，那种数字就是假绿。
        // 读态：必须有一批子视图，且**不许**有可编辑输入框（正文是只读文本）。
        // 编辑态：必须有若干可编辑输入框（可见的那几行）。
        guard read.total > 30, read.fields == 0 else {
            print("❌ 阅读态的子视图不符合预期（\(read.total) 个，可编辑输入框 \(read.fields) 个）。")
            print("CONCLUSION: INCONCLUSIVE")
            exit(2)
        }
        guard edit.fields >= 3 else {
            print("❌ 编辑态没建出输入框（\(edit.fields) 个），这次测量无效。")
            print("CONCLUSION: INCONCLUSIVE")
            exit(2)
        }

        // **懒加载的硬判据**：只该建出可见的那几行。
        // 1375 段一次性建出上千个输入框，正是「一进编辑就卡死」的原因——
        // 所以这里判的是**上限**，不是下限。
        guard edit.fields < 100 else {
            print("CONCLUSION: EAGER（编辑态建出了 \(edit.fields) 个输入框：整篇都建了，没走懒加载）")
            exit(1)
        }

        print("")
        if edit.ms > 3000 || read.ms > 3000 {
            print("CONCLUSION: SLOW（首屏超过 3 秒，用户会当成假死）")
            exit(1)
        }
        if edit.ms > 1200 || read.ms > 1200 {
            print("CONCLUSION: WARN（首屏超过 1.2 秒，值得再查）")
            exit(0)
        }
        print("CONCLUSION: FAST（阅读 \(Int(read.ms)) ms / 编辑 \(Int(edit.ms)) ms，量级正常）")
    } catch {
        print("❌ 夹具准备失败：\(error)")
        exit(2)
    }
}
