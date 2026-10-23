// 探针：给 README 拍图。产出 `docs/screenshots/` 下的两张界面图。
//
// ## 为什么单独做一个探针
//
// 之前 `docs/` 里那二十几张贴图是开发过程中随手截的屏，里面带着**真实的会议
// 标题、设备名与转写内容**。那份东西不能进公开仓库——不是「不好看」，是
// 别人的会议记录。所以 README 用的图必须由**合成数据**重新渲染，
// 而且要能重跑：图与代码一起演进，不会出现「图里是三个开关、代码里已是四个」。
//
// ## 它与另外两个探针的关系
//
// - `meeting-detail-render`：只拍详情右栏，用于逐栏核对折叠/编辑态；
// - `main-window-banner`：拍整个主窗口，但工作区是空的（只看横幅位置）；
// - 本探针：拍**有内容的整个主窗口** + **设置窗口**，只服务文档。
//
// 数据全部在临时目录里现造，跑完即删；不碰真实会议库，也不碰真实偏好域。
//
// 用法：
//   swift build
//   ./scripts/probes/readme-shots/run.sh
//   open docs/screenshots/main-window.png
import AppKit
import SwiftUI
@testable import MRGUI
import MRCore
import MRMinutes
import MRSession

// MARK: - 合成数据
//
// 内容刻意平庸且显而易见是编的（帮助中心改版、评论头像走 CDN）。
// 用真实会议内容拍图，等于把别人的会议记录一起发出去。

private let sessionIDs = [
    "2026-10-19-143012-示例会议",
    "2026-10-19-101530-周会",
    "2026-10-18-164500-需求澄清",
]

private let titles = [
    "示例会议：帮助中心改版评审",
    "周会：本周进度与下周排期",
    "需求澄清：搜索结果排序",
]

private func makeManifest(sessionID: String, title: String,
                          startedAt: Date,
                          framesWritten: Int,
                          seconds: Double) -> RecordingManifest {
    RecordingManifest(
        version: 1,
        sessionID: sessionID,
        title: title,
        startedAt: startedAt,
        // 不写 state 时默认是 .recording：详情页会挂一个「录制中」徽标，
        // 而这份稿子明明已经转完了——图上的状态与内容互相矛盾。
        endedAt: startedAt.addingTimeInterval(seconds),
        state: .transcribed,
        tracks: [
            TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                          sampleRate: 48000, channels: 1, sampleFormat: .pcm16,
                          framesWritten: framesWritten,
                          deviceName: "内置麦克风"),
            TrackManifest(id: "system", role: .systemAudio, fileName: "system.wav",
                          sampleRate: 48000, channels: 2, sampleFormat: .pcm16,
                          framesWritten: framesWritten,
                          deviceName: "系统音频输出"),
        ])
}

/// 一段够长的转写稿：段数太少的话，详情页看上去像「没转出来」。
private func makeTranscript(sessionID: String, title: String) -> TranscriptDocument {
    let lines: [(String, String, String)] = [
        ("我", "mic", "今天主要对一下帮助中心改版的排期，先看搜索这块的进度。"),
        ("对方", "system", "搜索的重排已经灰度上线了，命中率大概提升六个点，"
            + "但文章详情页的加载慢了二百毫秒。"),
        ("我", "mic", "二百毫秒有点大，先确认是不是图片没走 CDN。"),
        ("对方", "system", "查过了，是评论区的头像还在源站取，改成 CDN 之后应该能回来。"),
        ("我", "mic", "那就这周修掉，下周再看一次数据，别的先不动。"),
        ("对方", "system", "好，我周五前给结论。"),
    ]
    return TranscriptDocument(
        sessionID: sessionID,
        title: title,
        language: "zh-CN",
        engine: "apple-speech",
        segments: lines.enumerated().map { index, line in
            TranscriptSegment(
                // 段落跨度必须落在合成音频的时长（62 秒）之内，
                // 否则播放进度与文稿时间戳对不上，图上看着像「时间轴错位」。
                start: Double(index) * 10.0,
                end: Double(index) * 10.0 + 9.2,
                text: line.2,
                track: line.1,
                speaker: line.0,
                // 第 3 段做成「人工修正」：详情页上的修正标记是这一版才有的，
                // 图里不带一段就永远看不到它长什么样。
                manualEdit: index == 2 ? .corrected : nil,
                originalText: index == 2 ? "二百毫秒有点大，先看是不是图片没走 CDN。" : nil)
        })
}

private func makeMinutes(degraded: Bool) -> MinutesResult {
    MinutesResult(
        blocks: [],
        blockSummaries: [],
        minutes: degraded
            ? MeetingMinutes(summary: "")
            : MeetingMinutes(
                summary: "评审了帮助中心改版的排期，确定先修 CDN 这一处性能问题，"
                    + "下周复看搜索数据。其余改动本迭代不动。",
                topics: [
                    MeetingTopic(
                        title: "搜索重排的收益",
                        conclusion: "灰度上线，命中率提升约六个点",
                        details: ["文章详情页加载慢了二百毫秒"]),
                    MeetingTopic(
                        title: "详情页变慢的根因",
                        conclusion: "评论头像还在源站取，改走 CDN",
                        details: ["本周修掉，下周复看数据"]),
                ],
                decisions: ["本迭代只修 CDN，其余改动不动"],
                actionItems: [
                    ActionItem(task: "把评论头像迁到 CDN", owner: "示例同事", due: "本周五"),
                    ActionItem(task: "复看搜索命中率与加载耗时", owner: "", due: "下周三"),
                ],
                openIssues: ["改版整体上线时间未定"]),
        polishedTranscript: degraded
            ? makeTranscript(sessionID: sessionIDs[0], title: titles[0])
                .segments.map(\.text).joined(separator: "\n")
            : "（略）",
        generatedByModel: !degraded,
        generatorName: degraded ? "" : "云端 API（示例模型 @ 示例服务）",
        corrections: [])
}

// MARK: - 渲染

@MainActor
private func renderShots(to directory: URL) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mr-readme-shots-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "mr-readme-shots-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw ProbeError("建不出独立的 UserDefaults suite")
    }
    let workspace = MeetingWorkspace(
        root: root, preferences: RecorderPreferences(defaults: defaults))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    // 三场会议：第一场有完整转写稿、纪要与**两份真音频**（就是图里选中的那场），
    // 另两场只有 manifest——列表里既有「已转写」也有「未转写」两种行，
    // 否则看的人会以为这个工具只有一种状态。
    let seconds = 62.0
    for (index, sessionID) in sessionIDs.enumerated() {
        let dir = root.appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeJSON(makeManifest(sessionID: sessionID, title: titles[index],
                                   startedAt: Date().addingTimeInterval(Double(-index) * 3600),
                                   framesWritten: Int(seconds) * 48000,
                                   seconds: seconds),
                      to: dir.appendingPathComponent(SessionStore.manifestFileName))
        guard index == 0 else { continue }
        try writeWAV(to: dir.appendingPathComponent("mic.wav"), seconds: seconds,
                     sampleRate: 48000, channels: 1, seed: 0x5EED_0001)
        try writeWAV(to: dir.appendingPathComponent("system.wav"), seconds: seconds,
                     sampleRate: 48000, channels: 2, seed: 0x5EED_0002)
        try writeJSON(makeTranscript(sessionID: sessionID, title: titles[index]),
                      to: dir.appendingPathComponent(SessionStore.transcriptJSONName))
        try writeJSON(makeMinutes(degraded: false),
                      to: dir.appendingPathComponent(MinutesService.minutesJSONName))
    }

    workspace.refresh()
    guard workspace.meetings.count == sessionIDs.count else {
        throw ProbeError("工作区里应有 \(sessionIDs.count) 场会议，实际 \(workspace.meetings.count)")
    }
    workspace.select(sessionIDs[0])
    // `select` 的详情加载走 Task（后台读盘），必须把 runloop 排空一次，
    // 否则拍到的是 `transcript == nil` 的空壳。
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))

    // 一、主窗口：与生产窗口同尺寸（1120×720）。
    try write(view: MeetingRecorderRootView(workspace: workspace),
              named: "main-window", to: directory,
              // 比生产最小尺寸高一点（窗口可缩放）：720 时最低那行说明
              // 正好被底部工具条压住半行，图看着像「排版坏了」。
              size: NSSize(width: 1120, height: 800))

    // 二、详情页（音轨展开）：双轨波形是这个工具最直观的一点，而主窗口
    // 默认把音轨与转写稿折起来——不带这一屏，README 里就永远看不到波形。
    var collapse = DetailCollapseState()
    for section in DetailSection.allCases {
        // 三栏逐一显式设置：默认值已经变了，只设「要折的」那栏，
        // 其余会漂到新默认态上。
        collapse.setCollapsed(section == .transcript, for: section, in: sessionIDs[0])
    }
    try write(view: MeetingDetailView(workspace: workspace, player: TrackPlayer(),
                                      initialCollapse: collapse),
              named: "detail-tracks", to: directory,
              size: NSSize(width: 760, height: 720),
              // 波形是后台算的：0.5 秒只够拍出「正在计算波形…」，
              // 而那张图会被当成「产品不显示波形」。
              settle: 2.5)

    // 二、设置窗口：宽度按生产常量，高度按内容（判据与生产代码同一份）。
    let model = MinutesSettingsModel(workspace: workspace) { _ in
        .failed(reason: "文档用图不发起真实请求")
    }
    let settingsView = MinutesSettingsView(model: model, versionText: packedVersionText())
    let hosting = NSHostingView(rootView: settingsView)
    hosting.frame = NSRect(origin: .zero, size: NSSize(width: SettingsLayout.width, height: 2000))
    guard let size = SettingsLayout.contentSize(for: hosting) else {
        throw ProbeError("量不出设置窗口内容的自然高度")
    }
    try write(view: settingsView, named: "settings", to: directory, size: size)
}

/// 打包产物里印的版本号。读不到就写「示例」，不编一个出来——
/// 图里的版本号与包不一致，是一张会撒谎的图。
private func packedVersionText() -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // main.swift → readme-shots
        .deletingLastPathComponent()   // → probes
        .deletingLastPathComponent()   // → scripts
        .deletingLastPathComponent()   // → 仓库根
    let plist = root.appendingPathComponent("MeetingRecorder.app/Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
          let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let info = obj as? [String: Any] else { return "（示例）" }
    return AppVersion.display(shortVersion: AppVersion.shortVersion(from: info),
                              build: AppVersion.build(from: info))
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url)
}

// MARK: - 合成音频
//
// 光有 manifest 没有 .wav 的话，列表会显示「0:00 · 0 轨」、音轨栏写着
// 「这场会议没有可播放的音轨」——那是**探针的缺陷**，不是产品的样子，
// 而它一旦进了 README 就会被当成产品缺陷。
//
// 所以这里写两份真的 WAV：波形是假的（音素级的包络噪声），但文件是真的，
// 时长、帧数、波形、播放都走与真实录音同一条路径。

/// 写一个 16 位 PCM 的 WAV。`channels` 为 2 时左右声道各给不同的包络，
/// 这样双轨波形看上去是两条不同的线，而不是两条一模一样的复印。
private func writeWAV(to url: URL, seconds: Double, sampleRate: Int,
                      channels: Int, seed: UInt64) throws {
    let frameCount = Int(seconds * Double(sampleRate))
    var rng = seed
    func nextUnit() -> Double {
        // 线性同余，够用且与线程调度无关（可复现）。
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Double((rng >> 11) % 1000) / 1000.0
    }

    var samples = [Int16]()
    samples.reserveCapacity(frameCount * channels)
    for frame in 0..<frameCount {
        let t = Double(frame) / Double(sampleRate)
        // 交替的「说话段 / 停顿段」——波形上才有起伏可看。
        // 周期与相位按 seed 稍作变化：两条轨如果完全同形，图上就像同一份
        // 波形复印了两遍，"分轨"这件事反而看不出来。
        let period = 6.8 + Double(seed % 4) * 0.5
        let phase = (t + Double(seed % 6) * 0.7).truncatingRemainder(dividingBy: period)
        let speechEnd = period * 0.78
        let speaking = phase < speechEnd
        let envelope = speaking ? min(1.0, (speechEnd - phase) / 0.4) : 0.02
        for channel in 0..<channels {
            // 两个声道用不同的相位偏移，避免完全同相。
            let carrier = sin(2 * .pi * (220.0 + Double(channel) * 37.0) * t)
            let noise = nextUnit() * 2 - 1
            let value = (carrier * 0.55 + noise * 0.45) * envelope * (channel == 0 ? 0.7 : 0.5)
            samples.append(Int16(max(-1, min(1, value)) * 26000))
        }
    }

    var data = Data()
    func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let byteRate = UInt32(sampleRate * channels * 2)
    data.append(contentsOf: Array("RIFF".utf8))
    append32(UInt32(36 + samples.count * 2))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append32(16)
    append16(1)                                   // PCM
    append16(UInt16(channels))
    append32(UInt32(sampleRate))
    append32(byteRate)
    append16(UInt16(channels * 2))                // blockAlign
    append16(16)                                  // bitsPerSample
    data.append(contentsOf: Array("data".utf8))
    append32(UInt32(samples.count * 2))
    for sample in samples { append16(UInt16(bitPattern: sample)) }
    try data.write(to: url)
}

/// 一个真实窗口 → 完成布局 → `cacheDisplay` 抓位图。
///
/// 不用 `ImageRenderer`：主窗口与设置窗口都含 ScrollView，离屏不布局会画出
/// 整块空白，而尺寸与颜色数断言照样全绿。这条坑本项目踩过两次。
@MainActor
private func write(view: some View, named name: String, to directory: URL,
                   size: NSSize, settle: TimeInterval = 0.5) throws {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFront(nil)
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(settle))

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

/// 粗量化后的颜色数，用来识别「整块纯色」= 没画出来。
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
            let base = bytes.advanced(by: y * rowBytes + x * 4)
            seen.insert((UInt32(base[0]) >> 4) << 12
                        | (UInt32(base[1]) >> 4) << 8
                        | (UInt32(base[2]) >> 4) << 4
                        | (UInt32(base[3]) >> 4))
        }
    }
    return seen.count
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let output = repoRoot.appendingPathComponent("docs/screenshots", isDirectory: true)

try MainActor.assumeIsolated {
    try renderShots(to: output)
}
print("\n这三张图是要提交进仓库的：open \(output.path)")
