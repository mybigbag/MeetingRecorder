// 引擎对照探针：把**生产同款**的苹果转写器跑在指定的音频切片上，逐段落盘。
//
// ## 为什么需要它
//
// 评估「换一个 ASR 引擎会怎样」时，最容易出错的地方是**两边听到的不是同一段音频**。
// 上一轮评估（`docs/评估-whisper引擎可行性.md`）只能拿整场的 `transcript.json`
// 去和「whisper 的前 70 秒」比，靠截取来对齐——两端口径不同，结论虽然成立，
// 但对齐这件事本身是手工的、说不清误差。
//
// 这个探针把苹果侧也拉进「同一批 70 秒切片」里：喂进去什么音频，就转写什么音频，
// 与 `ffmpeg -t 70 -ar 16000 -ac 1` 切出来的文件是同一份输入。
// 于是「苹果 vs whisper vs SenseVoice」三方可以在**同一条音频**上比较。
//
// ## 输出
//
//   <outdir>/<name>.txt   —— 每段一行，供 `scripts/punct-stats.py` 直接吃
//
// 段的定义与生产一致：`SpeechTranscriber` 的一个 FINAL 结果 = 一段。
//
// ## 编译与运行
//
//   cd meeting-recorder
//   swift build --disable-sandbox
//   swiftc -O -I .build/debug -o /tmp/mr-engine-compare \
//     scripts/probes/engine-compare/main.swift \
//     .build/debug/MRTranscribe.o .build/debug/MRCore.o
//   /tmp/mr-engine-compare <outdir> <a.wav> [b.wav ...]
//
// ## 已知边界
//
// - 需要 macOS 26 的语音引擎；首次调用可能触发一次性语言资产下载。
// - 只做「文件 → 文本」，不写任何生产数据目录。
// - 段的时间戳没有输出：本探针只关心文本层面的标点与字数，与生产时间轴无关。
import Foundation
import MRCore
import MRTranscribe

setvbuf(stdout, nil, _IONBF, 0)

let argv = Array(CommandLine.arguments.dropFirst())
guard argv.count >= 2 else {
    FileHandle.standardError.write(
        "usage: engine-compare <outdir> <wav> [wav ...]\n".data(using: .utf8)!)
    exit(2)
}

let outDir = URL(fileURLWithPath: argv[0])
let inputs = argv.dropFirst().map { URL(fileURLWithPath: $0) }
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let engine = AppleSpeechTranscriber(
    options: .init(language: "zh-CN", ensureAssets: true))

do {
    try await engine.prepare()
} catch {
    print("语言资产准备失败：\(error)")
    exit(1)
}

var totalSegments = 0
var totalSeconds = 0.0

for url in inputs {
    let name = url.deletingPathExtension().lastPathComponent
    let t0 = Date()
    do {
        let segments = try await engine.transcribe(
            fileURL: url, trackID: name, speaker: name)
        let dt = Date().timeIntervalSince(t0)
        totalSegments += segments.count
        totalSeconds += dt

        let body = segments.map(\.text).joined(separator: "\n")
        try body.write(
            to: outDir.appendingPathComponent("\(name).txt"),
            atomically: true, encoding: .utf8)

        print(String(format: "  %-18@ %3d 段  %3d 字  %6.2fs",
                     name as NSString, segments.count,
                     segments.map { $0.text.count }.reduce(0, +), dt))
    } catch {
        print("  \(name) 失败：\(error)")
    }
}

print(String(format: "\n合计 %d 段，耗时 %.2fs（%d 条音频）",
             totalSegments, totalSeconds, inputs.count))
print("DONE")
