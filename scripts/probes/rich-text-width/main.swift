// 探针：纪要卡片里的那段富文本，**有没有撑满卡片宽度**。
//
// ## 为什么要有这个探针
//
// 2026-10-22 反馈：纪要内容偏左，右侧一片空白（截图里正文只占卡片约七成宽）。
// 这件事**渲染图看不出来**——`meeting-detail-render` 那份 760 宽的图是正常的，
// 因为它是「一次性按最终宽度布局」；而 App 里的窗口是先出现、再被拖动改宽的。
// 断言 `frame.width > 0` 更测不出来：窄也是 > 0。
//
// 判据必须是**可数的整数**：文本视图的宽度 vs 卡片内边距算出来的应有宽度。
// 差得超过 4 pt 就是「没撑满」，不是「字号不一样」。
//
// ## 阴性对照内建在这一份里
//
// 第一屏（按最终宽度一次性布局）**现在是通过的**——它证明「测量方法本身能测出
// 撑满的样子」。只有这样才能说后面几屏的窄是真窄，而不是量错了。
//
// ## 用法
//
//   swift build --disable-sandbox
//   ./scripts/probes/rich-text-width/run.sh
//
// 结论行：`CONCLUSION: FILL` / `CONCLUSION: NARROW` / `CONCLUSION: INCONCLUSIVE`
import AppKit
import SwiftUI
@testable import MRGUI
import MRCore
import MRMinutes
import MRSession

/// 与主窗口一致：左栏定宽 300、右栏撑满（见 `MeetingRecorderRootView`）。
private let sidebarWidth: CGFloat = 300
/// 详情页外层留白（`MeetingDetailView.detail` 里 `.padding(18)`）。
private let panePadding: CGFloat = 18
/// 卡片内边距（`minutesCard` 里 `.padding(12)`）。
private let cardPadding: CGFloat = 12
/// 分隔线宽度。
private let dividerWidth: CGFloat = 1

private func makeMinutes() -> MinutesResult {
    MinutesResult(
        blocks: [],
        blockSummaries: [],
        minutes: MeetingMinutes(
            summary: "会议确定了帮助中心改版的三项排期、搜索重排的灰度节奏与详情页性能修复的分工，"
                + "并同步了旧文档迁移和评论区改造的推进安排。"
                + "改版从下周起按新模板编写页面，历史页面在迁移前保持原样。",
            topics: [
                MeetingTopic(
                    title: "搜索重排与详情页性能",
                    conclusion: "搜索重排保留灰度，本周先修详情页多出来的二百毫秒加载",
                    details: ["评论区头像仍在源站取，改走 CDN 之后重测首屏时间",
                              "灰度范围维持百分之五，修复上线后按周对比命中率与跳出率"]),
                MeetingTopic(
                    title: "帮助中心改版排期",
                    conclusion: "排期确定且不能再往后调：本周出文案终稿，两周后进入开发，下月底全量上线",
                    details: []),
                MeetingTopic(
                    title: "旧文档迁移方案",
                    conclusion: "未定：需要先核清旧页面的数量与失效比例，下周更新迁移清单",
                    details: ["迁移只搬正文与目录结构，历史评论打包归档，不随页面一起搬"]),
            ],
            decisions: ["详情页的图片与头像统一走 CDN",
                        "改版文案由产品侧终审后不再变更"],
            actionItems: [ActionItem(task: "核清旧页面数量与失效比例，输出迁移清单",
                                     owner: "内容组", due: "下周一")],
            openIssues: ["评论区改造先在一个栏目试点，具体选哪个栏目未定"]),
        polishedTranscript: "",
        generatedByModel: true,
        generatorName: "DeepSeek")
}

/// 卡片本体：**与 `MeetingDetailView.minutesCard` 同一套容器修饰**。
///
/// 这里没有 import 那个私有方法（它是 `private`），所以容器链是手抄的；
/// 抄的部分只有 padding/frame 两个修饰符，被验的对象
/// （`SelectableRichText` + `MinutesCardText.render`）是生产代码本身。
private struct Card: View {
    let result: MinutesResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SelectableRichText(attributed: MinutesCardText.render(
                result, transcriptChanged: false, showsCorrections: false))
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 与主窗口同构的容器：左栏定宽 + 分隔线 + 右栏 `ScrollView`。
private struct Scene: View {
    let result: MinutesResult

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: sidebarWidth)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Card(result: result)
                }
                .padding(panePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private func allTextViews(in view: NSView) -> [NSTextView] {
    var found: [NSTextView] = []
    func walk(_ v: NSView) {
        if let text = v as? NSTextView { found.append(text) }
        v.subviews.forEach(walk)
    }
    walk(view)
    return found
}

/// 文本视图所在的滚动内容宽度。
///
/// **不能按窗口宽度推算**：真 App 里 `NSScrollView` 的竖直滚动条会吃掉宽度
/// （实测 779 → 762，差 17 pt），按窗口算出来的「应有宽度」会比真值大 17，
/// 于是明明撑满了也会被判成窄——那正是我第一版踩的坑。
@MainActor
private func scrollContentWidth(for view: NSView) -> CGFloat? {
    var node: NSView? = view
    while let current = node {
        if let scrollView = current as? NSScrollView, let document = scrollView.documentView {
            return document.frame.width
        }
        node = current.superview
    }
    return nil
}

/// 量一屏：文本视图的实际宽度 vs 它「应该」撑满的宽度。
@MainActor
private func measure(_ window: NSWindow, hosting: NSHostingView<Scene>,
                     label: String) -> (actual: CGFloat, expected: CGFloat)? {
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    hosting.layoutSubtreeIfNeeded()

    let textViews = allTextViews(in: hosting)
    guard let text = textViews.max(by: { $0.frame.width < $1.frame.width }) else { return nil }
    let actual = text.frame.width
    let content = scrollContentWidth(for: text)
        ?? (window.contentLayoutRect.width - sidebarWidth - dividerWidth)
    let expected = content - panePadding * 2 - cardPadding * 2
    print(String(format: "  %@：滚动内容宽 %.0f，文本视图宽 %.1f，应有 %.1f（差 %.1f）",
                 label, content, actual, expected, expected - actual))
    if textViews.count != 1 {
        // 多一份少一份都说明树长歪了，数字不该拿来用。
        print("  ⚠️ 找到 \(textViews.count) 个 NSTextView（应有 1 个），这次测量作废")
        return nil
    }
    return (actual, expected)
}

private let tolerance: CGFloat = 4

// MARK: - 第二段：整个主窗口（含顶栏、左栏、真实工作区）

/// 真窗口 + 真工作区 + 真 `minutes.json`。
///
/// 为什么要多这一段：第一段是**手抄的容器链**，它能证明 `SelectableRichText`
/// 本身会撑满；但用户看到的那一屏在**整个 App 里**（顶栏 + 左栏 + 右栏），
/// 两者的差别正是「只在真 App 里才犯的毛病」可能出现的地方。
/// 判据仍旧是同一个整数：文本视图宽度 vs 卡片应有宽度。
@MainActor
private func measureRootView() -> Bool? {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mr-width-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "mr-width-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
    let workspace = MeetingWorkspace(root: root,
                                     preferences: RecorderPreferences(defaults: defaults))

    let meetingID = "2026-10-22-141500-宽度验收"
    let directory = root.appendingPathComponent(meetingID, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifest = RecordingManifest(
        version: 1, sessionID: meetingID, title: "宽度验收", startedAt: Date(),
        tracks: [TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                               sampleRate: 48000, channels: 1, sampleFormat: .pcm16,
                               deviceName: "MacBook 麦克风")])
    let transcript = TranscriptDocument(
        sessionID: meetingID, title: "宽度验收", language: "zh-CN", engine: "apple",
        segments: (0..<8).map { index in
            TranscriptSegment(start: Double(index) * 30, end: Double(index) * 30 + 28,
                              text: "这是第 \(index + 1) 段转写内容，用来把详情页撑得足够长。",
                              track: index.isMultiple(of: 2) ? "mic" : "system",
                              speaker: index.isMultiple(of: 2) ? "我" : "对方")
        })
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try? encoder.encode(manifest)
        .write(to: directory.appendingPathComponent(SessionStore.manifestFileName))
    try? encoder.encode(transcript)
        .write(to: directory.appendingPathComponent(SessionStore.transcriptJSONName))
    try? encoder.encode(makeMinutes())
        .write(to: directory.appendingPathComponent(MinutesService.minutesJSONName))

    workspace.refresh()
    workspace.select(meetingID)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))

    let size = NSSize(width: 1080, height: 724)
    let hosting = NSHostingView(rootView: MeetingRecorderRootView(workspace: workspace))
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFront(nil)
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    // `.task { await workspace.refreshAsync() }` 是异步的，要给它时间回来。
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    hosting.layoutSubtreeIfNeeded()

    let textViews = allTextViews(in: hosting)
    guard let text = textViews.max(by: { $0.frame.width < $1.frame.width }) else {
        print("❌ 整窗口里没找到 NSTextView（纪要卡片没渲染出来），测不出")
        return nil
    }
    let content = scrollContentWidth(for: text) ?? window.contentLayoutRect.width
    let expected = content - panePadding * 2 - cardPadding * 2
    let width = text.frame.width
    print(String(format: "  整窗口 1080×724：滚动内容宽 %.0f，文本视图宽 %.1f，应有 %.1f（差 %.1f）",
                 content, width, expected, expected - width))
    if textViews.count != 1 {
        print("  ⚠️ 找到 \(textViews.count) 个 NSTextView（应有 1 个），这次测量作废")
        return nil
    }
    // 顺手把这一屏抓成图：数字说撑满了，眼睛也要看得见（本项目的老规矩）。
    let out = URL(fileURLWithPath: "/tmp/mr-ui-preview")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            let url = out.appendingPathComponent("root-window-width.png")
            try? png.write(to: url)
            print("  📷 \(url.path)（\(rep.pixelsWide)×\(rep.pixelsHigh)）")
        }
    }

    if expected - width > tolerance {
        print("❌ 整窗口里没撑满——用户看到的留白就是这个")
        // 窄在哪一层：把从文本视图往上到 hosting 的每一层宽度打出来。
        // 「差 270」这种数字单独看没有意义，必须知道是哪一层先窄的。
        var node: NSView? = text
        var depth = 0
        while let view = node, depth < 14 {
            let indent = String(repeating: "  ", count: depth + 1)
            print(String(format: "%@%@ 宽 %.1f  origin.x %.1f",
                         indent, String(describing: type(of: view)),
                         view.frame.width, view.frame.origin.x))
            node = view.superview
            depth += 1
        }
        return false
    }
    print("✅ 整窗口里撑满")
    return true
}

MainActor.assumeIsolated {
    let result = makeMinutes()
    let size = NSSize(width: 1085, height: 724)
    let hosting = NSHostingView(rootView: Scene(result: result))
    hosting.frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFront(nil)
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))

    print("第一屏（一次性按最终宽度布局）——这一屏是**阴性对照**：它必须撑满，")
    print("否则说明测量方法本身有问题，后面的数字全部不可信。")
    guard let first = measure(window, hosting: hosting, label: "1085×724 首次") else {
        print("CONCLUSION: INCONCLUSIVE（没量到文本视图）")
        exit(2)
    }
    guard first.expected - first.actual <= tolerance else {
        print("❌ 首次布局就没撑满——测量方法有问题，后面的数字不可信。")
        print("CONCLUSION: INCONCLUSIVE")
        exit(2)
    }
    print("✅ 首次布局撑满（阴性对照成立：这个方法能测出「撑满」的样子）\n")

    print("第二屏：把窗口拖窄再拖回原宽（App 里窗口是先出现、再被拖动的）")
    var narrow: (actual: CGFloat, expected: CGFloat)?
    var restored: (actual: CGFloat, expected: CGFloat)?

    window.setContentSize(NSSize(width: 820, height: 724))
    narrow = measure(window, hosting: hosting, label: "820×724 拖窄后")
    window.setContentSize(size)
    restored = measure(window, hosting: hosting, label: "1085×724 拖回原宽")

    print("")
    print("第三屏：整个主窗口（顶栏 + 左栏 + 真实工作区 + 盘上的 minutes.json）")
    let rootOK = measureRootView()

    print("")
    var ok = true
    for (label, sample) in [("拖窄后", narrow), ("拖回原宽", restored)] {
        guard let sample else {
            print("❌ \(label)：没量到，测不出")
            ok = false
            continue
        }
        if sample.expected - sample.actual > tolerance {
            print(String(format: "❌ %@：文本视图只有 %.1f 宽，应撑满 %.1f（差 %.1f）——右侧空白就是这么来的",
                         label, sample.actual, sample.expected, sample.expected - sample.actual))
            ok = false
        } else {
            print(String(format: "✅ %@：撑满（%.1f / %.1f）", label, sample.actual, sample.expected))
        }
    }
    if rootOK == nil {
        print("❌ 整窗口那屏没量到，测不出（不算通过）")
        ok = false
    } else if rootOK == false {
        ok = false
    }

    if ok {
        print("CONCLUSION: FILL（三屏都撑满；窗口改宽后文本会跟着重排）")
        exit(0)
    }
    print("CONCLUSION: NARROW（有屏没撑满——右栏留白）")
    exit(1)
}
