// 转码速度与正确性探针。
//
// ## 为什么要有这一步
//
// C 档要把存量 3.28 GiB 全部转一遍。在此之前必须先知道两件事，而且必须是**实测**：
//
// 1. **跑不跑得完**——`WAVReader.decode` 是逐字节组装（刻意不用 `bindMemory`，
//    因为 `Data` 不保证对齐），129 抽头 FIR 又是每输出样本 129 次乘加。
//    这两段都是 interpreted Swift 的循环，快不起来。不测就不知道 3.28 GiB 是
//    「几分钟」还是「两小时」——而这两个数字对应完全不同的产品决策。
// 2. **转完的东西对不对**——时长是否守住（24k/48k 写反会让时长正好差一倍）、
//    体积是否等于 `44 + 帧数 × 声道 × 位深`、峰值是否还非零。
//
// 走**生产同款链路**（`AudioTranscoder` → `TrackSamplePipeline` → `WAVWriter`），
// 不能另写简化版：那只能证明算术，证明不了实现。
//
// ## 编译与运行
//
//   cd meeting-recorder
//   swift build -c release --disable-sandbox          ← **必须 release**
//   swiftc -O -I .build/release -o /tmp/mr-transcode-speed \
//     scripts/probes/transcode-speed/main.swift .build/release/MRCore.o
//   /tmp/mr-transcode-speed [--preset lossless32|pcm16|bTier] <wav> [wav...]
//
// 产物写在 /tmp/mr-transcode-speed-out/，跑完打印耗时与核对表。
//
// ### ⚠️ 必须链 release，链接 debug 会让性能结论失真 100 倍
//
// 这不是小事：本探针**第一版就链了 `.build/debug/MRCore.o`**，于是同一段 60 秒音频
// 报出「27.1 秒、0.8 MiB/s」，按这个数 extrapolate 出去是「3.28 GiB 要 69 分钟」，
// 差点得出「转码不可行」的错误结论。换成 release 后同一段是 **0.2 秒、91.6 MiB/s**
// ——**差 115 倍**。
//
// `AudioResampler.value(centeredAt:)` 每个输出样本要开两个嵌套 `withUnsafeBufferPointer`，
// 未优化时每次都有 exclusivity 检查与 retain/release；129 抽头内层循环里还有
// 逐抽头的边界判断。这些在 `-Onone` 下被放大到不可接受，在 `-O` 下基本免费。
//
// **教训**：凡是量时间/吞吐的探针，先确认被测模块是 release 构建。
// 同目录下 `b-tier-size` 探针也链 debug，但它只数字节数、不看时间，所以没受影响——
// 这也说明「链接错配置」是否致命，取决于探针在量什么。
import Foundation
import MRCore

setvbuf(stdout, nil, _IONBF, 0)

let outDir = URL(fileURLWithPath: "/tmp/mr-transcode-speed-out")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func bytes(_ n: Int) -> String {
    let f = Double(n)
    if f >= 2 * 2 * 2 * 1024 { return String(format: "%.2f GiB", f / 1073741824) }
    if f >= 1024 * 1024 { return String(format: "%.1f MiB", f / 1048576) }
    return "\(n) B"
}

struct Row {
    var name: String
    var source: URL
    var result: AudioTranscoder.TranscodeResult
    var elapsed: Double
    var outputBytes: Int
    var headerFrames: Int
    var headerRate: Double
    var headerChannels: Int
    var headerFormat: UInt16
}

func transcodeOne(_ name: String, _ source: URL,
                   preset: AudioTranscoder.Preset) throws -> Row {
    let dst = outDir.appendingPathComponent("\(name).wav")
    try? FileManager.default.removeItem(at: dst)

    let t0 = Date()
    let r = try AudioTranscoder.transcode(source: source, destination: dst, preset: preset)
    let dt = Date().timeIntervalSince(t0)

    let h = try WAVWriter.readHeader(at: dst)
    let size = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
    return Row(name: name, source: source, result: r, elapsed: dt,
               outputBytes: size, headerFrames: h.frameCount,
               headerRate: h.sampleRate, headerChannels: h.channels,
               headerFormat: h.audioFormatID)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法：mr-transcode-speed <wav> [wav...]")
    exit(2)
}

// 预设档。`pcm16` 档不做任何重采样（源 == 目标采样率与声道 → 恒等短路），
// 所以它的时间**几乎全是「读字节 + 写字节」**；与 `bTier` 一减，就知道 FIR 占了多少。
var preset: AudioTranscoder.Preset = .bTier
var files: [String] = []
var i = 1
while i < args.count {
    if args[i] == "--preset", i + 1 < args.count {
        guard let p = AudioTranscoder.Preset(rawValue: args[i + 1]) else {
            print("未知档位 \(args[i + 1])，可选："
                + AudioTranscoder.Preset.allCases.map(\.rawValue).joined(separator: " | "))
            exit(2)
        }
        preset = p
        i += 2
        continue
    }
    files.append(args[i])
    i += 1
}

guard !files.isEmpty else {
    print("用法：mr-transcode-speed [--preset lossless32|pcm16|bTier] <wav> [wav...]")
    exit(2)
}

var rows: [Row] = []
var totalIn: Int = 0
var totalOut: Int = 0
var totalTime: Double = 0

for path in files {
    let src = URL(fileURLWithPath: path)
    let name = src.deletingPathExtension().lastPathComponent
    totalIn += (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    let r = try transcodeOne(name, src, preset: preset)
    rows.append(r); totalOut += r.outputBytes; totalTime += r.elapsed
    print("· \(name) 转码完成（\(String(format: "%.1f", r.elapsed)) s，档位 \(preset.rawValue)）")
}

print("")
print(String(format: "%-10s %-34s %-34s %10s %10s %8s", "轨", "源格式", "目标格式",
             "源体积", "目标体积", "耗时"))
for r in rows {
    print(String(format: "%-10@ %-34@ %-34@ %10@ %10@ %7.1fs",
                 r.name as NSString,
                 r.result.sourceFormatName as NSString,
                 r.result.target.shortName as NSString,
                 bytes(r.result.sourceBytes) as NSString,
                 bytes(r.outputBytes) as NSString,
                 r.elapsed))
}

print("\n=== 核对（每一项都必须 ✓）===")
var allOK = true
func check(_ label: String, _ ok: Bool, _ detail: String) {
    if !ok { allOK = false }
    print("  \(ok ? "✓" : "✗") \(label)：\(detail)")
}

for r in rows {
    print("\n[\(r.name)]")
    let res = r.result
    check("WAV 头格式 == 目标格式",
          r.headerRate == res.target.sampleRate
            && r.headerChannels == res.target.channels
            && r.headerFormat == res.target.format.audioFormatID,
          "头 \(Int(r.headerRate))Hz/\(r.headerChannels)ch/格式码 \(r.headerFormat)"
            + " vs 目标 \(res.target.shortName)")
    check("头帧数 == 写入帧数", r.headerFrames == res.targetFrames,
          "\(r.headerFrames) vs \(res.targetFrames)")
    let expect = WAVWriter.headerSize + r.headerFrames * r.headerChannels
        * (r.headerFormat == 1 ? 2 : 4)
    check("字节数 == 44 + 帧数×声道×位深", r.outputBytes == expect,
          "\(bytes(r.outputBytes)) vs 期望 \(bytes(expect))")
    // 零相位 FIR 的尾部会多补约半个窗宽（129 抽头 → 64 源样本 → 32 输出样本），
    // 所以时长差应当是**亚毫秒级**，而不是「小于 5%」这种放任的判据。
    let dt = abs(res.durationDelta)
    check("时长守住（|Δ| < 5 ms）", dt < 0.005,
          String(format: "源 %.4f s → 目标 %.4f s，Δ %+.2f ms",
                 res.sourceDuration, res.targetDuration, res.durationDelta * 1000))
    check("峰值非零（转码没把内容洗掉）", res.peakAmplitude > 0,
          String(format: "%.5f", res.peakAmplitude))
    check("体积确实变小", res.sizeFactor < 1,
          String(format: "×%.4f（省 %@）", res.sizeFactor, bytes(res.savedBytes)))
}

print("\n=== 速度 ===")
print(String(format: "  读入 %@ → 写出 %@，耗时 %.1f s",
             bytes(totalIn) as NSString, bytes(totalOut) as NSString, totalTime))
if totalOut > 0 {
    let mibPerSec = (Double(totalIn) / 1048576) / max(0.001, totalTime)
    print(String(format: "  吞吐 %.1f MiB/s（源侧）", mibPerSec))
    print(String(format: "  按此速度，3.28 GiB 存量约需 %.0f 分钟",
                 3359.0 / max(0.001, mibPerSec) / 60))
}

print(allOK ? "\n✅ 全部核对通过" : "\n❌ 有核对项未通过")
exit(allOK ? 0 : 1)
