// 探针：把**生产代码里的**会议详情右栏渲染成 PNG，供人眼复核排版。
//
// ## 为什么要有这个探针
//
// 详情页的折叠能力覆盖三栏（音轨 / 会议纪要 / 转写稿），
// 每栏各有「操作按钮必须留在折叠之外」的约束。
// 这些约束**编译与单测都证明不了排版**：
//
// - 折了音轨而把播放控制条也藏了，断言照样全绿，
//   而用户会发现音频还在放却找不到暂停；
// - 折了纪要而把「复制」藏了，等于为折叠砍掉了纪要的主要用途；
// - 折了转写稿而把「重新转写」「单轨转写」藏了，用户没法重新转写；
// - 三处折叠按钮的箭头方向与位置不一致，用户会以为是三个不同的功能；
// - 折叠态那一行提示如果没写清楚「折的是什么、还剩什么」，
//   用户会以为整栏都没了。
//
// 只跑「渲染宽度 > 400」这类断言会全绿却什么也没验到。这里走
// **真实窗口**（NSHostingView 装进 NSWindow，系统完成一次真正的布局），
// 再用 `contentView.cacheDisplay(in:to:)` 抓位图。
// 这条路径不需要屏幕录制权限，也不需要用户点开 App。
//
// ## 为什么不是一条单元测试
//
// 渲染含 `TextField` / `SecureField` 的视图会打出 SwiftUI 的 FocusState 警告，
// 而项目守 0 warning，所以它不能待在 `swift test` 的输出里。
// （既有的 `RecordingBarViewRenderTests` 只渲染选择器、不渲染输入框，
// 那条注释写的就是这个原因。）
//
// ## 为什么不用 ImageRenderer
//
// `ImageRenderer` 渲染不出输入控件的真实样子，而且含 ScrollView 的视图
// 离屏不布局——会画出一整块空白，而断言照样全绿（设置窗口那次就踩过）。
//
// ## 它验证的是生产视图本身
//
// `@testable import MRGUI` 直接用生产类型：既没有骨架副本带来的漂移，
// 也没有可见性妥协。
//
// ## 用法
//
//   swift build                       # 先构建出 .o 与 .swiftmodule
//   ./scripts/probes/meeting-detail-render/run.sh
//   open /tmp/mr-ui-preview/detail-*.png
//
// ## 证据边界
//
// 它证明的是**这个进程里、这个主题下的排版**。真实窗口受用户的动态字体、
// 外观（深色模式）与显示缩放影响，那些不在这里——真窗口仍要人打开 App 看。
import AppKit
import SwiftUI
@testable import MRGUI
import MRCore
import MRMinutes
import MRSession

/// 各区块的折叠状态（通过 `initialCollapse` 注入）。
private struct Scene {
    var name: String
    /// 折了哪几栏。**三栏各自独立**，所以用集合而不是一个 Bool。
    var collapsed: Set<DetailSection>
    /// 有没有纪要（`minutes.json`）。nil = 不写文件，走空态。
    var minutes: MinutesResult?
    /// 转写稿是否处于编辑态（通过 `initialEditingTranscript` 注入）。
    var editing: Bool = false
    /// 是否伪造「稿子比纪要新」（把 transcript.json 的 mtime 拨到纪要之后）。
    var staleMinutes: Bool = false
    /// 是否**不注入**折叠状态、直接用视图自己的默认值。
    ///
    /// 2026-10-22 起默认是「音轨与转写稿折着、纪要展开」。
    /// 其余各屏都要**显式**指定三栏状态，否则它们会静默变成新的默认态，
    /// 图上看起来「折叠坏了」而其实是探针没注入。
    var usesDefaults: Bool = false

    /// 这一屏折的是哪一栏——探针在日志里说清楚，避免「忘注入了」被当成「折叠坏了」。
    var collapsedNames: String {
        collapsed.isEmpty
            ? "（无）"
            : collapsed.map(\.rawValue).sorted().joined(separator: "+")
    }
}

/// 一份够长的转写稿：段数与单段长度都贴近真实会议，
/// 段太短的话折叠/展开的差别在图上几乎看不出来。
private func makeTranscript() -> TranscriptDocument {
    TranscriptDocument(
        sessionID: "2026-10-19-143012-版本下线评审",
        title: "版本下线评审",
        language: "zh-CN",
        engine: "apple",
        segments: (0..<12).map { index in
            // 第 3 段模拟「人工修正」、第 4 段模拟「人工清空」：
            // 阅读态要不要显示标记、编辑态能不能恢复原文，都只能靠眼睛看。
            let corrected = index == 2
            let cleared = index == 3
            return TranscriptSegment(
                start: Double(index) * 120, end: Double(index) * 120 + 118,
                text: cleared
                    ? ""
                    : (corrected
                        ? "这是第 3 段：灰度到 50%，指标无异常再全量。"
                        : "这是第 \(index + 1) 段转写内容，用来占位以贴近真实会议的转写稿长度与排版效果。"),
                track: index.isMultiple(of: 2) ? "mic" : "system",
                speaker: index.isMultiple(of: 2) ? "我" : "对方",
                manualEdit: corrected ? .corrected : (cleared ? .cleared : nil),
                originalText: corrected ? "这是第 3 段：回度到 50%，指标无异常再全量。"
                            : (cleared ? "嗯，那个，这个，就是……" : nil))
        })
}

private func makeMinutes(degraded: Bool) -> MinutesResult {
    MinutesResult(
        blocks: [],
        blockSummaries: [],
        minutes: degraded
            ? MeetingMinutes(summary: "")
            // 2026-10-21 起纪要改「议题 → 结论」结构。样例必须跟着改，
            // 否则图上测的是一份已经不存在的旧版式。
            : MeetingMinutes(
                summary: "评审了 3.2 版本下线方案，确定 10 月 20 日下线，"
                    + "全量前先灰度 50% 观察两天。回滚演练与文档更新尚未完成，"
                    + "客服通知时间待运营确认。",
                topics: [
                    MeetingTopic(
                        title: "下线时间与灰度",
                        conclusion: "10-20 下线，灰度 50% 观察两天，指标无异常再全量",
                        details: ["灰度期间盯支付成功率与崩溃率",
                                 "支付网关的投诉集中在高峰期"]),
                    MeetingTopic(
                        title: "回滚预案",
                        conclusion: "方案已写，演练还没做",
                        details: ["演练安排在 10-19 上午"]),
                    MeetingTopic(
                        title: "文档与客服",
                        conclusion: "帮助文档随版本更新，客服通知时间未定",
                        details: []),
                ],
                decisions: ["下线日期定为 10-20",
                            "本次不发布 3.3，挪到下个迭代"],
                actionItems: [
                    ActionItem(task: "写回滚脚本并演练一次", owner: "老王", due: "10-19"),
                    ActionItem(task: "更新帮助文档", owner: "小林", due: "10-18"),
                    ActionItem(task: "通知客服", owner: "", due: ""),
                ],
                openIssues: ["是否提前通知客服未定，等运营确认",
                             "3.3 的排期尚未评估"]),
        polishedTranscript: degraded
            ? makeTranscript().segments.map(\.text).joined(separator: "\n")
            : "（略）",
        generatedByModel: !degraded,
        generatorName: degraded ? "" : "云端 API（deepseek-chat @ api.deepseek.com）",
        // 勘误表默认收起，只在图上占一行——这一屏要确认的是
        // 「它占了一行、没有被挤掉」。
        corrections: degraded ? [] : [
            TranscriptCorrection(original: "支付光关", corrected: "支付网关",
                                 reason: "后文出现正确写法"),
            TranscriptCorrection(original: "回度", corrected: "灰度"),
        ])
}

@MainActor
private func renderScenes(to directory: URL) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mr-detail-preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "mr-detail-preview-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw ProbeError("建不出独立的 UserDefaults suite")
    }
    let workspace = MeetingWorkspace(
        root: root, preferences: RecorderPreferences(defaults: defaults))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    // 一场**真实存在**的会议：先在盘上造出 manifest 与转写稿，
    // 让工作区能选中它。这样渲染的是与用户实际看到同一条路径，
    // 而不是给视图塞几个假对象。
    let meetingID = "2026-10-19-143012-版本下线评审"
    let directory_ = root.appendingPathComponent(meetingID, isDirectory: true)
    try FileManager.default.createDirectory(at: directory_, withIntermediateDirectories: true)
    try writeJSON(makeManifest(sessionID: meetingID, title: "版本下线评审"), to:
        directory_.appendingPathComponent(SessionStore.manifestFileName))
    try writeJSON(makeTranscript(), to:
        directory_.appendingPathComponent(SessionStore.transcriptJSONName))

    let scenes = [
        // 基准态：三栏全展开、纪要还没生成。用户第一次打开一场会议看到的就是它，
        // 而它必须**不被任何默认折叠污染**。
        Scene(name: "detail-all-expanded", collapsed: [], minutes: nil),
        // 折转写稿：这是上一轮就有的能力，保留一屏做对照基准。
        // 「折叠后重新转写/单轨转写还在不在」只能靠眼睛看——
        // 按钮被藏起来时界面上没有任何报错。
        Scene(name: "detail-transcript-collapsed", collapsed: [.transcript], minutes: nil),
        // 折音轨：**播放控制条必须还在**（播放/停止/进度条）。
        // 折叠它不是为了省那点波形空间，而是「音频在放而界面上一个活控件都不剩」
        // 是一个会让人以为播放器坏了的状态。
        Scene(name: "detail-tracks-collapsed", collapsed: [.tracks], minutes: nil),
        // 折纪要（还没有纪要）：标题行的「复制」本就不该出现（没内容可复制），
        // 而「生成纪要」必须在——否则用户只能先展开才能生成。
        Scene(name: "detail-minutes-collapsed-empty",
              collapsed: [.minutes], minutes: nil),
        // 折纪要（正常稿）：**「复制」必须在折叠之外**。
        // 纪要的新价值是粘给别人，为折叠把它藏掉等于砍掉主要用途。
        Scene(name: "detail-minutes-collapsed",
              collapsed: [.minutes], minutes: makeMinutes(degraded: false)),
        // 折纪要（降级稿）：折叠后看不到橙色警告了，
        // 所以「已折叠 ⚠️ 这是降级稿」这行字必须自己说清楚——
        // 而降级稿是本机（无 Apple Intelligence）**默认会看到**的那一份。
        Scene(name: "detail-degraded-collapsed",
              collapsed: [.minutes], minutes: makeMinutes(degraded: true)),
        // 三栏全折：一次只核对一个数字时的真实状态。
        // 这一屏会暴露「三处折叠按钮的箭头方向/位置是否一致」——
        // 不一致的话用户会觉得是三个不同的功能。
        Scene(name: "detail-all-collapsed",
              collapsed: [.tracks, .minutes, .transcript],
              minutes: makeMinutes(degraded: false)),
        // **用户打开一场会议时的第一屏**（2026-10-22 起音轨与转写稿默认折叠）。
        // 这一屏不注入任何折叠状态，测的就是视图自己的默认值。
        Scene(name: "detail-default-open",
              collapsed: [], minutes: makeMinutes(degraded: false), usesDefaults: true),
        // 基准：全展开 + 有纪要。用来与折叠各屏逐栏对照。
        Scene(name: "detail-all-expanded-with-minutes",
              collapsed: [], minutes: makeMinutes(degraded: false)),
        // 阅读态（音轨与纪要折起来，把转写稿顶到第一屏）：
        // 人工改过/清空的段要各自带一个标记，否则这份稿子看起来和引擎原稿一样。
        Scene(name: "detail-transcript-edited",
              collapsed: [.tracks, .minutes], minutes: makeMinutes(degraded: false)),
        // 编辑态：每段一个输入框 + 「清空」，改过的段带「已修正 / 恢复原文」，
        // 清空的段显示占位提示。这一屏要确认的是**编辑入口与只读态长得不一样**，
        // 以及时间戳/说话人仍然是文本（不是输入框）——它们不该被改。
        Scene(name: "detail-transcript-editing",
              collapsed: [.tracks, .minutes], minutes: makeMinutes(degraded: false),
              editing: true),
        // 「稿子改过、纪要没重跑」：卡片顶部的橙色提示必须在，且要占满一行
        // 而不是被压成半截——这条提示不亮的话，用户会拿一份基于旧稿的结论去开会。
        Scene(name: "detail-minutes-stale",
              collapsed: [.tracks, .transcript], minutes: makeMinutes(degraded: false),
              staleMinutes: true),
    ]

    for scene in scenes {
        // 纪要只能通过**盘上文件**驱动：`minutesResult` 是 `@Published private(set)`，
        // 视图层塞不进去，而工作区的 `loadSelectedMeeting()` 会自己读 `minutes.json`。
        // 上一屏若有纪要，这一屏必须删掉文件，否则会串场。
        let minutesURL = directory_.appendingPathComponent(MinutesService.minutesJSONName)
        if let minutes = scene.minutes {
            try writeJSON(minutes, to: minutesURL)
        } else {
            try? FileManager.default.removeItem(at: minutesURL)
        }
        // 「稿子比纪要新」只能靠文件 mtime 造：工作区就是这么判的
        // （见 `SessionLibrary.transcriptIsNewerThanMinutes`）。
        let transcriptURL = directory_.appendingPathComponent(SessionStore.transcriptJSONName)
        let bump: TimeInterval = scene.staleMinutes ? 120 : -120
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(bump)],
            ofItemAtPath: transcriptURL.path)

        workspace.refresh()
        guard workspace.meetings.contains(where: { $0.id == meetingID }) else {
            throw ProbeError("工作区里找不到刚造的会议")
        }
        // `select` 的详情加载走 `Task`（后台读盘），
        // 这里必须把 runloop 排空一次，等它回来——否则渲染的是
        // `transcript == nil` 的空壳，四屏全都一个样。
        workspace.select(meetingID)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        // 折叠状态通过 `initialCollapse` 注入（视图私有的 `@State` 无法从外部设置）。
        // **每一屏都重建视图**：SwiftUI 的 `@State` 只在视图身份变化时重置，
        // 复用同一个视图实例的话上一屏的折叠状态会渗进下一屏。
        var collapse = DetailCollapseState()
        if scene.usesDefaults {
            // 不注入：这就是用户打开一场会议时真正看到的第一屏。
        } else {
            // **三栏逐一显式设置**（展开也要写出来）：默认值已经变了，
            // 只把「要折的」设进去，剩下那栏就会漂到新默认态上。
            for section in DetailSection.allCases {
                collapse.setCollapsed(scene.collapsed.contains(section),
                                      for: section, in: meetingID)
            }
        }
        print("— 折叠：\(scene.usesDefaults ? "（视图默认值）" : scene.collapsedNames)")
        print("— 编辑态：\(scene.editing)")
        try write(view: MeetingDetailView(workspace: workspace, player: TrackPlayer(),
                                          initialCollapse: collapse,
                                          initialEditingTranscript: scene.editing),
                  named: scene.name, to: directory)
    }
}

private func makeManifest(sessionID: String, title: String) -> RecordingManifest {
    RecordingManifest(
        version: 1,
        sessionID: sessionID,
        title: title,
        startedAt: Date(),
        tracks: [TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                               sampleRate: 48000, channels: 1, sampleFormat: .pcm16,
                               deviceName: "MacBook 麦克风")])
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url)
}

/// 一个真实窗口 → 完成布局 → 抓位图。
@MainActor
private func write(view: some View, named name: String, to directory: URL) throws {
    // 详情页在主窗口的右栏，与主窗口同宽同高（1120×720）。
    let size = NSSize(width: 760, height: 720)
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
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))

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
///
/// 界面空白时 PNG 照样有正常尺寸，「文件生成了」本身证明不了任何东西——
/// 这正是本项目在设置窗口那次学到的（ScrollView 离屏不布局，
/// 渲染出整块空白而断言全绿）。
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

    // 抗锯齿会让每个字边缘产生几十种灰阶，所以按 7×7 的格子**量化**
    // （每格中心像素 >>4，即 16 级）后再统计：粗体/普通、抗锯齿这些噪声
    // 都被抹掉，剩下的就是真正的颜色块数量。
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
print("\n看一眼：open \(output.path)/detail-*.png")