// 标点补救方案的**前提验证**探针：字与字之间的时间间隔，到底是不是真的
// 携带「人在哪儿停顿」的信息？
//
// ## 为什么必须先验这一步
//
// 「保留 run 级时间戳 → 按间隔补标点」这条路只有在**间隔确实不均、且大间隔
// 落在真实停顿上**时才成立。有另一种可能：引擎根本就是把整段时长平均分摊给
// 每个字（那间隔全相等，一个信号都没有）。这两种情况从代码上看不出来，
// 只能拿真实录音对账。先把地基验了，再动生产代码。
//
// ## 怎么验：拿音频本身当裁判
//
// 停顿不在文本里，在**波形**里。所以：
//   1. 用 `SilenceDetector`（跟分段器同一个，-45 dBFS / 0.25 秒）扫出真实静音区间；
//   2. 用生产同款配置转写，把 run 摊平成「每个字的起止时刻」；
//   3. 把每个「真实静音」落到它跨越的那个字缝上，看那个字缝宽不宽。
//
// 判据：
//   - **分离度**：停顿处字缝 vs 非停顿处字缝，中位数要拉开数量级；
//   - **阈值扫描**：给定一个阈值 T，看它命中多少真停顿（召回）、误炸多少
//     普通字缝（误报）。T 就从这个表里选，不拍脑袋。
//
// ## 编译与运行
//
//   cd meeting-recorder
//   swift build --disable-sandbox
//   swiftc -O -I .build/debug -o /tmp/mr-punct-gap scripts/probes/punctuation-gap/main.swift \
//     .build/debug/MRCore.o
//   /tmp/mr-punct-gap
import Foundation
import Speech
import AVFoundation
import CoreMedia
import MRCore

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - 把 AttributedString 摊平成逐字时间

/// 一个字符 + 它在音频里的起止秒数
struct Timed {
    var chars: [Character] = []
    var starts: [Double] = []
    var ends: [Double] = []
}

/// 未经任何加工的原始 run（用于诊断「引擎到底给没给缝隙」）
struct RawRun {
    let text: String
    let start: Double
    let end: Double
}

/// 结果流的落点。用引用类型而不是捕获局部 var——后者在并发闭包里是数据竞争，
/// Swift 6 会直接判成错误。
final class Sink: @unchecked Sendable {
    var texts: [AttributedString] = []
    var raw: [[RawRun]] = []
}

/// 复刻生产代码 `AppleSpeechTranscriber.collect` 的取数方式。
///
/// 一个 run 可能覆盖多个字符——那样就只能把该 run 的时长按字符数**线性摊开**，
/// 摊开出来的内部间隔恒为 0，不会假装有停顿。（实测绝大多数 run 就是一个字。）
func flatten(_ text: AttributedString) -> Timed {
    var t = Timed()
    for run in text.runs {
        let s = String(text[run.range].characters)
        guard !s.isEmpty else { continue }
        guard let tr = run.audioTimeRange else {
            for ch in s { t.chars.append(ch); t.starts.append(.nan); t.ends.append(.nan) }
            continue
        }
        let a = CMTimeGetSeconds(tr.start)
        let b = CMTimeGetSeconds(tr.end)
        guard a.isFinite, b.isFinite, b >= a else {
            for ch in s { t.chars.append(ch); t.starts.append(.nan); t.ends.append(.nan) }
            continue
        }
        let n = Double(s.count)
        let step = (b - a) / n
        for (k, ch) in s.enumerated() {
            t.chars.append(ch)
            t.starts.append(a + step * Double(k))
            t.ends.append(a + step * Double(k + 1))
        }
    }
    return t
}

/// 相邻两字之间的空隙（秒）。跳过含 NaN 的边界。
struct Gap {
    /// 左字下标
    let index: Int
    /// 空隙中点（音频秒数）
    let center: Double
    let seconds: Double
}

func gaps(_ t: Timed) -> [Gap] {
    var out: [Gap] = []
    guard t.chars.count >= 2 else { return out }
    for i in 0..<(t.chars.count - 1) {
        let a = t.ends[i], b = t.starts[i + 1]
        guard a.isFinite, b.isFinite else { continue }
        out.append(Gap(index: i, center: (a + b) / 2, seconds: b - a))
    }
    return out
}

// MARK: - 标点计数

/// 这个 run 是不是「标点占位 run」——即引擎自己插的标点。
///
/// 这是**天然的真值**：引擎在有标点的段里，是它自己决定在哪儿断句的。
/// 我们的规则只要拿它当答案对，就能算出准确率与召回率。
func isPunctRun(_ s: String) -> Bool {
    guard !s.isEmpty else { return false }
    let set = CharacterSet.punctuationCharacters
        .union(.symbols).union(.whitespaces)
    return s.unicodeScalars.allSatisfy { set.contains($0) }
}

/// 与 `TranscriptDocument.normalized` 同口径：标点 + 符号
func punctuationCount(_ s: String) -> Int {
    let set = CharacterSet.punctuationCharacters.union(.symbols)
    return s.unicodeScalars.filter { set.contains($0) }.count
}

// MARK: - 统计小工具

func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    let m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    let idx = Int((Double(s.count - 1) * p).rounded())
    return s[max(0, min(s.count - 1, idx))]
}

func f(_ v: Double, _ digits: Int = 3) -> String {
    v.isNaN ? "  n/a" : String(format: "%.\(digits)f", v)
}

// MARK: - 扫真实静音

/// 直接测一段音频的 dBFS 序列。判静音不能只信一个阈值——
/// 会议录音有底噪，-45 dBFS 可能永远够不着。先把真实电平打出来再说。
func dbSeries(_ url: URL, start: Double, end: Double,
              step: Double = 0.1) throws -> [(Double, Double)] {
    let reader = try WAVReader(url: url)
    defer { reader.close() }
    let samples = try reader.read(start: start, end: end)
    let ch = max(1, reader.channels)
    let per = max(1, Int((step * reader.sampleRate).rounded()))
    var out: [(Double, Double)] = []
    var i = 0
    var t = start
    while i + per * ch <= samples.count {
        var sum = 0.0
        for j in 0..<(per * ch) {
            let v = Double(samples[i + j])
            sum += v * v
        }
        let rms = (sum / Double(per * ch)).squareRoot()
        out.append((t, rms > 0 ? 20 * log10(min(rms, 1)) : -160))
        i += per * ch
        t += step
    }
    return out
}

/// 用生产同款的静音判定（-45 dBFS），但最短时长放宽到 0.25 秒——
/// 我们要的是「人在哪儿换气」，比「能安全切片的点」更宽松。
func detectSilences(_ url: URL) throws -> [ClosedRange<Double>] {
    let reader = try WAVReader(url: url)
    let det = SilenceDetector(
        sampleRate: reader.sampleRate,
        channels: reader.channels,
        settings: .init(windowSeconds: 0.02, thresholdDB: -45,
                        minSilenceSeconds: 0.25, edgeTrimSeconds: 0))
    try reader.forEachChunk(chunkFrames: 1 << 16) { samples, _, _ in
        det.append(samples)
        return true
    }
    reader.close()
    return det.finish()
}

// MARK: - 主流程

let root = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Documents/MeetingRecorder")

var files: [(session: String, track: String, url: URL)] = []
if let dirs = try? FileManager.default.contentsOfDirectory(
    at: root, includingPropertiesForKeys: nil) {
    for d in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        for track in ["mic", "system"] {
            let u = d.appendingPathComponent("\(track).wav")
            if FileManager.default.fileExists(atPath: u.path) {
                files.append((d.lastPathComponent, track, u))
            }
        }
    }
}

print("扫到 \(files.count) 条轨\n")

// 累积桶
var pauseGaps: [Double] = []     // 落在真实停顿上的字缝
var normalGaps: [Double] = []    // 其余字缝
var segCount = 0
var longSegCount = 0
var longZeroPunctCount = 0
var segSpans: [(chars: Int, punctuation: Int, seconds: Double)] = []
var examples: [String] = []
var allRunDurations: [Double] = []
var segEdges: [String: [(Double, Double)]] = [:]
var rawExample = ""
/// 「单个 run 的时长」× 「该 run 内部是否真的含静音」→ 时长样本
var runBuckets: [String: [Double]] = [:]
/// 含静音的 run 实例，带上下文，供肉眼核对语义
var silenceRunExamples: [String] = []
/// 静音落在该字内部的相对位置（0=字首，1=字尾）。决定标点插字前还是字后。
var silenceRelPos: [Double] = []

/// 交叉验证的绝对阈值档位
let thresholds: [Double] = [0.30, 0.35, 0.40, 0.45, 0.50, 0.60, 0.70]
/// 命中判定窗口（秒）：预测点与真标点的时间距离在此之内算命中。
/// 放宽到 1.0 秒——宁可给规则最宽的条件，也不能因为窗口太窄而误杀它。
let hitWindow = 1.0
/// 策略名 → 预测断点数 / 命中数 / 真标点数 / 被找到数
var stratOrder: [String] = []
var stratCand: [String: Int] = [:]
var stratCandHit: [String: Int] = [:]
var stratTrue: [String: Int] = [:]
var stratTrueHit: [String: Int] = [:]
/// 长且零标点段里，超长 run 与普通 run 的清单
var detailExample = ""

for item in files {
    let silences: [ClosedRange<Double>]
    do { silences = try detectSilences(item.url) }
    catch { print("⚠️  \(item.session)/\(item.track) 读音频失败：\(error)"); continue }

    let transcriber = SpeechTranscriber(
        locale: Locale(identifier: "zh-CN"),
        transcriptionOptions: [], reportingOptions: [],
        attributeOptions: [.audioTimeRange])
    let analyzer = SpeechAnalyzer(modules: [transcriber])

    let sink = Sink()
    async let pump: Void = {
        for try await r in transcriber.results where r.isFinal {
            sink.texts.append(r.text)
            var runs: [RawRun] = []
            for run in r.text.runs {
                let s = String(r.text[run.range].characters)
                let tr = run.audioTimeRange
                runs.append(RawRun(
                    text: s,
                    start: tr.map { CMTimeGetSeconds($0.start) } ?? .nan,
                    end: tr.map { CMTimeGetSeconds($0.end) } ?? .nan))
            }
            sink.raw.append(runs)
        }
    }()

    do {
        let file = try AVAudioFile(forReading: item.url)
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        try await pump
    } catch {
        print("⚠️  \(item.session)/\(item.track) 转写失败：\(error)")
        continue
    }

    var fileSilenceHits = 0
    var filePauseGapSum = 0.0

    for (i, text) in sink.texts.enumerated() {
        let plain = String(text.characters)
        segCount += 1
        let t = flatten(text)
        let g = gaps(t)
        guard let lo = t.starts.first(where: { $0.isFinite }),
              let hi = t.ends.last(where: { $0.isFinite }) else { continue }

        let punct = punctuationCount(plain)
        segSpans.append((t.chars.count, punct, hi - lo))

        let rawRuns = i < sink.raw.count ? sink.raw[i] : []
        segEdges[item.session + "/" + item.track, default: []].append((lo, hi))

        // 判据换位：不看「字与字之间的缝」（已证恒为 0），改看「单个字自己的时长」。
        // 若引擎把停顿算进了相邻那个字的时长里，那么超长的 run 内部应该**真的含静音**。
        // 这是一次可证伪的检验：含静音的 run 如果不集中在长时长档，信号就不成立。
        for (k, r) in rawRuns.enumerated() where r.start.isFinite && r.end.isFinite {
            let dur = r.end - r.start
            allRunDurations.append(dur)

            let margin = min(0.15, dur * 0.25)
            let innerLo = r.start + margin
            let innerHi = r.end - margin
            guard innerLo < innerHi else { continue }
            let hits = silences.filter {
                $0.lowerBound < innerHi && $0.upperBound > innerLo
            }
            let hasSilence = !hits.isEmpty
            runBuckets[hasSilence ? "含停顿" : "无停顿", default: []].append(dur)

            if let h = hits.first {
                let lo = max(h.lowerBound, innerLo)
                let hi = min(h.upperBound, innerHi)
                silenceRelPos.append(((lo + hi) / 2 - r.start) / dur)
            }

            if hasSilence && silenceRunExamples.count < 16 {
                let prev = k > 0 ? rawRuns[k - 1].text : "·"
                let next = k + 1 < rawRuns.count ? rawRuns[k + 1].text : "·"
                silenceRunExamples.append(String(
                    format: "    %@｜长 %.2fs 的「%@」　上下文：…%@【%@】%@…",
                    item.track as NSString, dur, r.text as NSString,
                    prev as NSString, r.text as NSString, next as NSString))
            }
        }

        // 交叉验证：在**长段**上，用「超长 run 的位置」预测断点，
        // 拿引擎自己插的标点当答案，算准/召。（只统计 ≥40 字的段，
        // 因为我们的规则也只作用在这一档。）
        if t.chars.count >= 40 {
            let punctSpans: [(Double, Double)] = rawRuns
                .filter { isPunctRun($0.text) && $0.start.isFinite && $0.end.isFinite }
                .map { ($0.start, $0.end) }

            // 段内 run，排除段首那个字——它长是因为夹着段与段之间的停顿，
            // 不代表句内断点。
            let inner: [(start: Double, dur: Double)] = rawRuns.enumerated().compactMap { k, r in
                guard k > 0, r.start.isFinite, r.end.isFinite else { return nil }
                return (r.start, r.end - r.start)
            }
            let med = median(inner.map(\.dur))
            let base = med.isFinite && med > 0 ? med : 0.18

            // 三类策略一起比：绝对阈值 / 相对阈值（跟本段语速比）/ 每段只取最长的 N 个
            var strategies: [(String, [Double])] = []
            for T in thresholds {
                strategies.append((String(format: "绝对 %.2fs", T),
                                   inner.filter { $0.dur >= T }.map(\.start)))
            }
            for k in [2.0, 2.5, 3.0] {
                let T = max(0.25, base * k)
                strategies.append((String(format: "相对 中位×%.1f = %.2fs", k, T),
                                   inner.filter { $0.dur >= T }.map(\.start)))
            }
            for n in [1, 2, 3] {
                strategies.append(("每段最长 \(n) 个",
                                   inner.sorted { $0.dur > $1.dur }.prefix(n).map(\.start)))
            }

            for (name, cands) in strategies {
                if stratCand[name] == nil { stratOrder.append(name) }
                stratCand[name, default: 0] += cands.count
                stratTrue[name, default: 0] += punctSpans.count
                for c in cands where punctSpans.contains(where: {
                    abs($0.0 - c) <= hitWindow || abs($0.1 - c) <= hitWindow
                }) {
                    stratCandHit[name, default: 0] += 1
                }
                for p in punctSpans where cands.contains(where: {
                    abs($0 - p.0) <= hitWindow || abs($0 - p.1) <= hitWindow
                }) {
                    stratTrueHit[name, default: 0] += 1
                }
            }
        }

        // 把一个长且零标点的段完整摊开，看超长 run 落在句子的什么位置
        if t.chars.count >= 40 && punct == 0 && detailExample.isEmpty {
            var s = ""
            for (k, r) in rawRuns.enumerated() {
                let dur = r.end - r.start
                let margin = min(0.15, dur * 0.25)
                let innerLo = r.start + margin, innerHi = r.end - margin
                var note = ""
                if innerLo < innerHi {
                    for h in silences where h.lowerBound < innerHi && h.upperBound > innerLo {
                        let lo = max(h.lowerBound, innerLo), hi = min(h.upperBound, innerHi)
                        let rel = ((lo + hi) / 2 - r.start) / dur
                        note += String(format: "   ←静音 %.2f–%.2fs(在该字 %.0f%% 处)",
                                       lo, hi, rel * 100)
                    }
                }
                let mark = dur >= 0.40 ? "  ◀◀ 超长" : (dur >= 0.30 ? "  ◀ 偏长" : "")
                s += String(format: "      [%2d] 「%@」%7.3f → %7.3f  (%.2fs)%@%@\n",
                            k, r.text as NSString, r.start, r.end, dur,
                            mark as NSString, note as NSString)
            }
            // 把这一段的真实电平也打出来：超长 run 里到底是有声音，还是真的安静？
            var level = "\n      该段真实电平（每 0.1 秒一格，单位 dBFS）：\n"
            if let series = try? dbSeries(item.url, start: lo, end: hi) {
                var line = ""
                for (idx, pair) in series.enumerated() {
                    if idx % 10 == 0 { line += String(format: "      %6.1fs │", pair.0) }
                    line += String(format: "%5.0f", pair.1)
                    if idx % 10 == 9 { line += "\n" }
                }
                if series.count % 10 != 0 { line += "\n" }
                level += line
            }
            detailExample = "▸ \(item.session)/\(item.track) 第 \(i + 1) 段（\(t.chars.count) 字，0 标点）：\n\(s)\(level)"
        }

        // 留一段原始 run 序列：不做任何加工，直接看引擎给的是什么
        if t.chars.count >= 40 && punct == 0 && rawExample.isEmpty {
            var s = ""
            for (k, r) in rawRuns.prefix(24).enumerated() {
                s += String(format: "      run[%2d] 「%@」%8.3f → %8.3f\n",
                            k, r.text as NSString, r.start, r.end)
            }
            rawExample = """
            ▸ \(item.session)/\(item.track) 第 \(i + 1) 段（\(t.chars.count) 字，0 标点）
              原始 run 序列（前 24 条，未经任何加工）：
            \(s)
            """
        }

        if t.chars.count >= 40 {
            longSegCount += 1
            if punct == 0 { longZeroPunctCount += 1 }
        }

        // 这个 final 结果的时间跨度内，有哪些真实停顿
        let inner = silences.filter { $0.lowerBound < hi && $0.upperBound > lo }

        // 把每段停顿钉到「跨越它的那个字缝」上
        var pauseIdx = Set<Int>()
        for s in inner {
            let mid = (s.lowerBound + s.upperBound) / 2
            guard let best = g.min(by: { abs($0.center - mid) < abs($1.center - mid) }) else { continue }
            // 中点要真的靠近这段停顿，否则说明这段停顿落在段首/段尾外
            guard abs(best.center - mid) <= max(0.5, (s.upperBound - s.lowerBound)) else { continue }
            pauseIdx.insert(best.index)
            fileSilenceHits += 1
            filePauseGapSum += best.seconds
        }

        for gap in g {
            if pauseIdx.contains(gap.index) { pauseGaps.append(gap.seconds) }
            else { normalGaps.append(gap.seconds) }
        }

        // 留一条「长且零标点」的实例，打印字缝序列供肉眼核对
        if t.chars.count >= 40 && punct == 0 && examples.count < 3 {
            var line = ""
            for gap in g where gap.seconds >= 0.25 {
                line += String(format: "  第 %d 字后：%.2fs  「…%@|%@…」\n",
                               gap.index + 1, gap.seconds,
                               String(t.chars[max(0, gap.index - 5)...gap.index]),
                               String(t.chars[(gap.index + 1)...min(t.chars.count - 1, gap.index + 6)]))
            }
            if !line.isEmpty {
                examples.append("""
                ▸ \(item.session)/\(item.track) 第 \(i + 1) 段（\(t.chars.count) 字，0 标点）
                  文本：\(plain.prefix(60))…
                  宽度 ≥0.25s 的字缝：
                \(line)
                """)
            }
        }
    }

    if fileSilenceHits > 0 {
        print(String(format: "  %@/%@：%d 段，命中 %d 处真实停顿，停顿字缝均值 %.3fs",
                     item.session, item.track, sink.texts.count, fileSilenceHits,
                     filePauseGapSum / Double(fileSilenceHits)))
    } else {
        print("  \(item.session)/\(item.track)：\(sink.texts.count) 段，无停顿对齐样本")
    }
}

// MARK: - 结论

print("\n" + String(repeating: "=", count: 72))
print("字缝分布")
print(String(repeating: "=", count: 72))
print("""
段落总数：\(segCount)
长段（≥40 字）：\(longSegCount)，其中**零标点**：\(longZeroPunctCount)

非停顿字缝：\(normalGaps.count) 个　中位 \(f(median(normalGaps)))s　\
p90 \(f(percentile(normalGaps, 0.9)))s　p99 \(f(percentile(normalGaps, 0.99)))s　\
最大 \(f(normalGaps.max() ?? .nan))s

停顿处字缝：\(pauseGaps.count) 个　中位 \(f(median(pauseGaps)))s　\
p10 \(f(percentile(pauseGaps, 0.1)))s　p90 \(f(percentile(pauseGaps, 0.9)))s　\
最小 \(f(pauseGaps.min() ?? .nan))s
""")

if let a = pauseGaps.min(), let b = normalGaps.max() {
    print("分离度：停顿字缝最小 \(f(a))s　vs　非停顿字缝最大 \(f(b))s")
}

print("\n阈值扫描（用真实停顿当标注）")
print("   阈值T     命中停顿      误标非停顿    准确率")
for T in [0.20, 0.25, 0.30, 0.35, 0.40, 0.50, 0.60] {
    let hit = pauseGaps.filter { $0 >= T }.count
    let fp = normalGaps.filter { $0 >= T }.count
    let prec = (hit + fp) > 0 ? Double(hit) / Double(hit + fp) : .nan
    let recall = pauseGaps.isEmpty ? Double.nan : Double(hit) / Double(pauseGaps.count)
    print(String(format: "    %.2fs    %4d/%-4d(%.0f%%)    %4d/%-4d       %.0f%%",
                 T, hit, pauseGaps.count, recall * 100,
                 fp, normalGaps.count, prec * 100))
}

print("\n" + String(repeating: "=", count: 72))
print("核心检验：单个 run 的时长 × 该 run 内部是否真的含静音")
print(String(repeating: "=", count: 72))
print("""
run 总数：\(allRunDurations.count)
单个 run 时长：中位 \(f(median(allRunDurations)))s　\
p10 \(f(percentile(allRunDurations, 0.1)))s　\
p90 \(f(percentile(allRunDurations, 0.9)))s　\
p99 \(f(percentile(allRunDurations, 0.99)))s　\
最大 \(f(allRunDurations.max() ?? .nan))s
""")

let withS = runBuckets["含停顿"] ?? []
let without = runBuckets["无停顿"] ?? []
print("含静音的 run ：\(withS.count) 个　时长中位 \(f(median(withS)))s")
print("不含静音的 run：\(without.count) 个　时长中位 \(f(median(without)))s")
print("\n按时长分档，看含静音的 run 集中在哪（这是判据成立与否的判决书）：")
print("   时长档        样本数    含静音数    含静音比例")
for (lo, hi) in [(0.0, 0.2), (0.2, 0.3), (0.3, 0.4), (0.4, 0.6), (0.6, 1.0), (1.0, 99.0)] {
    let inBand = allRunDurations.filter { $0 >= lo && $0 < hi }
    let sil = withS.filter { $0 >= lo && $0 < hi }
    guard !inBand.isEmpty else { continue }
    print(String(format: "   %.1f–%.1fs    %5d      %4d        %5.0f%%",
                 lo, hi, inBand.count, sil.count,
                 100 * Double(sil.count) / Double(inBand.count)))
}

print("\n静音落在该字内部的相对位置（决定标点插字前还是字后）：")
print("   位置档      样本数    占比")
let bands: [(String, Double, Double)] = [
    ("字首 0–20%", 0, 0.2), ("偏前 20–40%", 0.2, 0.4),
    ("中段 40–60%", 0.4, 0.6), ("偏后 60–80%", 0.6, 0.8),
    ("字尾 80–100%", 0.8, 1.01),
]
for (name, lo, hi) in bands {
    let n = silenceRelPos.filter { $0 >= lo && $0 < hi }.count
    let pct = silenceRelPos.isEmpty ? 0 : 100 * Double(n) / Double(silenceRelPos.count)
    print(String(format: "   %@    %4d      %4.0f%%", name, n, pct))
}

print("\n" + String(repeating: "=", count: 72))
print("含静音的 run 实例（肉眼核对：这些位置是不是真的该断句）")
print(String(repeating: "=", count: 72))
for e in silenceRunExamples { print(e) }

print("\n" + String(repeating: "=", count: 72))
print("段与段之间的间隙（两个 final 结果之间）")
print(String(repeating: "=", count: 72))
for (key, spans) in segEdges.sorted(by: { $0.key < $1.key }) {
    let sorted = spans.sorted { $0.0 < $1.0 }
    guard sorted.count >= 2 else { continue }
    var gs: [Double] = []
    for i in 0..<(sorted.count - 1) { gs.append(sorted[i + 1].0 - sorted[i].1) }
    let big = gs.filter { $0 > 0.05 }
    print(String(format: "  %-44@ %3d 段　%3d 个间隙　>0.05s 的 %3d 个　中位 %6.3fs　最大 %6.3fs",
                 key as NSString, sorted.count, gs.count, big.count,
                 median(gs), gs.max() ?? .nan))
}

print("\n" + String(repeating: "=", count: 72))
print("交叉验证：用「超长 run 的位置」预测断点，拿引擎自己的标点当答案（仅 ≥40 字的段）")
print(String(repeating: "=", count: 72))
print("  策略                        预测     命中     准确率     真标点   找到   召回率")
for name in stratOrder {
    let ct = stratCand[name] ?? 0, ch = stratCandHit[name] ?? 0
    let tt = stratTrue[name] ?? 0, th = stratTrueHit[name] ?? 0
    print(String(format: "  %-24@  %5d    %5d    %5.0f%%    %5d   %4d   %5.0f%%",
                 name as NSString, ct, ch,
                 ct > 0 ? 100 * Double(ch) / Double(ct) : 0,
                 tt, th, tt > 0 ? 100 * Double(th) / Double(tt) : 0))
}
print("\n（准确率 = 我们插的标点里有多少落在引擎真标点附近；召回率 = 引擎的标点里有多少被我们找到）")

print("\n" + String(repeating: "=", count: 72))
print("一个长且零标点的段，逐 run 摊开（超长 run 落在句子的什么位置）")
print(String(repeating: "=", count: 72))
if !detailExample.isEmpty { print(detailExample) }
if !rawExample.isEmpty, detailExample.isEmpty { print(rawExample) }

print("\nDONE")
