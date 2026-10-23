// B 档（单声道 24 kHz）体积实测探针。
//
// ## 为什么要有这一步
//
// 「降到 1/3」「两条一起降到 1/6」在方案文档里是**算术题**：字节数 = 采样率 × 声道 ×
// 位深 ÷ 8 × 秒数。算术不会错，但**实现有没有真的按目标格式写**是另一件事。
// 采样率与声道数一旦在「WAV 头 / 写入器 / manifest」三者之间错配，文件体积会立刻偏离
// 预期，而文件本身仍然能播、仍然「看起来正常」——没有任何地方会报错。
//
// 所以这道核对必须落在**实际写出的文件字节数**上，且必须走**生产同款链路**
// （`TrackWriteFormat.resolve` 决定格式 → `TrackSamplePipeline` 做变换 → `WAVWriter` 落盘），
// 不能另写一个简化版——那只能证明算术，证明不了实现。
//
// ## 口径
//
// 取真实录音的**前 60 秒**（与方案文档第二节的切片口径一致），双轨分别测，
// 折算成「双轨合计每小时」。四种配置就是两个开关的四种组合：
//
//   关 / 关 → f32 · 48k · sys2ch + mic1ch   （现状）
//   开 / 关 → pcm16 · 48k · sys2ch + mic1ch （A 档）
//   关 / 开 → f32 · 24k · 单声道            （B 档）
//   开 / 开 → pcm16 · 24k · 单声道          （A+B）
//
// ## 编译与运行
//
//   cd meeting-recorder
//   swift build --disable-sandbox
//   swiftc -O -I .build/debug -o /tmp/mr-b-tier-size \
//     scripts/probes/b-tier-size/main.swift .build/debug/MRCore.o
//   /tmp/mr-b-tier-size <system.wav> <mic.wav>
//
// 产物写在 /tmp/mr-b-tier-size/，跑完会打印一张表。
import Foundation
import MRCore

setvbuf(stdout, nil, _IONBF, 0)

/// 切片时长。与方案文档第二节取同一口径，结果才能直接对照。
let sliceSeconds: Double = 60

/// 模拟真实采集回调的块大小。真实回调每秒约 94 次、每次约 512 帧——
/// 按单块一次性喂进去会漏掉「流式状态跨块保持」这一层，量出来的体积会偏乐观。
let chunkFrames = 512

/// 产物目录。**不要**与可执行文件名相同——同名时 `createDirectory` 会静默失败，
/// 症状是写文件时抛「无法创建文件」，排查方向会被带到权限上去。
let outDir = URL(fileURLWithPath: "/tmp/mr-b-tier-size-out")

// MARK: - 读源文件

/// 读前 `sliceSeconds` 秒的 float32 交错采样。
func readSource(_ url: URL) throws -> (header: WAVHeaderInfo, samples: [Float]) {
    let info = try WAVWriter.readHeader(at: url)
    guard info.audioFormatID == WAVSampleFormat.float32.audioFormatID else {
        throw MRError.invalidWAV(
            path: url.path,
            reason: "源文件不是 float32（audioFormatID=\(info.audioFormatID)），本探针只吃现状格式")
    }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)

    let wanted = Int(info.sampleRate * sliceSeconds)
    let frames = min(wanted, info.frameCount)
    let byteCount = frames * info.bytesPerFrame
    guard info.dataOffset + byteCount <= data.count else {
        throw MRError.invalidWAV(path: url.path, reason: "data 段长度与头部声明不符")
    }

    var out = [Float](repeating: 0, count: frames * info.channels)
    _ = out.withUnsafeMutableBytes { dst in
        data.copyBytes(to: dst, from: info.dataOffset..<(info.dataOffset + byteCount))
    }
    return (info, out)
}

// MARK: - 走生产管线写一份文件

struct Measurement {
    let mono24k: Bool
    let pcm16: Bool
    let writeFormat: TrackWriteFormat
    let bytes: Int
    let seconds: Double
}

func measure(
    _ source: [Float],
    header: WAVHeaderInfo,
    into url: URL,
    mono24k: Bool,
    format: WAVSampleFormat
) throws -> Measurement {
    // 格式决策用的是生产代码，不是这里另写的一份规则
    let write = TrackWriteFormat.resolve(
        sourceSampleRate: header.sampleRate,
        sourceChannels: header.channels,
        mono24k: mono24k)

    let writer = try WAVWriter(
        url: url,
        sampleRate: write.sampleRate,
        channels: write.channels,
        format: format)

    var pipeline = TrackSamplePipeline(
        sourceSampleRate: header.sampleRate,
        sourceChannels: header.channels,
        writeFormat: write)

    let totalFrames = source.count / header.channels
    var cursor = 0
    while cursor < totalFrames {
        let n = min(chunkFrames, totalFrames - cursor)
        let chunk = Array(source[(cursor * header.channels)..<((cursor + n) * header.channels)])
        let produced = pipeline.process(chunk)
        if !produced.isEmpty { try writer.append(produced) }
        cursor += n
    }
    let tail = pipeline.flush()
    if !tail.isEmpty { try writer.append(tail) }
    try writer.finalize()

    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    let written = try WAVWriter.readHeader(at: url)
    return Measurement(
        mono24k: mono24k,
        pcm16: format == .pcm16,
        writeFormat: write,
        bytes: size,
        seconds: written.duration)
}

// MARK: - 主流程

let args = CommandLine.arguments.dropFirst()
guard args.count == 2 else {
    print("用法：/tmp/mr-b-tier-size <system.wav> <mic.wav>")
    exit(2)
}

let urls = args.map { URL(fileURLWithPath: String($0)) }
for u in urls where !FileManager.default.fileExists(atPath: u.path) {
    print("文件不存在：\(u.path)")
    exit(2)
}

do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
} catch {
    // 不吞掉：目录建不出来的话后面每条都会失败，但报的是「无法创建文件」，指不到根因
    print("无法创建产物目录 \(outDir.path)：\(error.localizedDescription)")
    exit(1)
}

print("B 档体积实测　切片 \(Int(sliceSeconds))s　块大小 \(chunkFrames) 帧　双轨")

// 四种配置：(开关 mono24k, 位深)
let configs: [(mono24k: Bool, format: WAVSampleFormat, label: String)] = [
    (false, .float32, "现状 f32·48k·原声道"),
    (false, .pcm16,   "A 档 p16·48k·原声道"),
    (true,  .float32, "B 档 f32·24k·单声道"),
    (true,  .pcm16,   "A+B  p16·24k·单声道"),
]

var perConfigTrackBytes: [Int: [Int]] = [:]   // 配置下标 → 各轨字节数
var perConfigSeconds: [Int: Double] = [:]
var trackNames: [String] = []
var sourceBytes = 0

for (ti, url) in urls.enumerated() {
    let (header, samples) = try readSource(url)
    trackNames.append("\(url.lastPathComponent)（\(Int(header.sampleRate))Hz \(header.channels)ch \(header.frameCount) 帧）")
    // 源文件前 60 秒的理论字节数，作为「现状」基线
    let sliceBytes = Int(header.sampleRate * sliceSeconds) * header.bytesPerFrame
    sourceBytes += min(sliceBytes, header.dataSize)

    for (ci, cfg) in configs.enumerated() {
        let name = "t\(ti)-\(cfg.mono24k ? "mono24k" : "src")-\(cfg.format.rawValue).wav"
        let m = try measure(
            samples, header: header,
            into: outDir.appendingPathComponent(name),
            mono24k: cfg.mono24k, format: cfg.format)
        perConfigTrackBytes[ci, default: []].append(m.bytes)
        perConfigSeconds[ci] = m.seconds
    }
}

func mib(_ bytes: Int) -> Double { Double(bytes) / 1048576 }

print(String(repeating: "-", count: 78))
for n in trackNames { print("源：\(n)") }
print(String(repeating: "-", count: 78))

let baselineBytes = perConfigTrackBytes[0]!.reduce(0, +)
print(String(format: "%-26@ %10@ %10@ %10@ %8@",
             "配置" as NSString, "60s 双轨" as NSString, "折算每小时" as NSString, "压缩比" as NSString, "写入格式" as NSString))
for (ci, cfg) in configs.enumerated() {
    let bytes = perConfigTrackBytes[ci]!.reduce(0, +)
    let hourly = Double(bytes) * (3600 / sliceSeconds)
    let ratio = Double(baselineBytes) / Double(bytes)
    let fmt = TrackWriteFormat.resolve(
        sourceSampleRate: 48000, sourceChannels: 2, mono24k: cfg.mono24k)
    print(String(format: "%-26@ %8.2f MiB %8.1f MiB/h %7.2f× %10@",
                 cfg.label as NSString,
                 mib(bytes),
                 mib(Int(hourly)),
                 ratio,
                 cfg.mono24k ? "24k 1ch" : "48k 同源" as NSString))
    _ = fmt
}

print(String(repeating: "-", count: 78))

// 算术核对：实测字节数应与「采样率 × 声道 × 位深」成正比，且与头部声明自洽
print("自洽核对：")
for (ci, cfg) in configs.enumerated() {
    let write = TrackWriteFormat.resolve(sourceSampleRate: 48000, sourceChannels: 2, mono24k: cfg.mono24k)
    let bytesPerSample = cfg.format.bytesPerSample
    for (ti, bytes) in perConfigTrackBytes[ci]!.enumerated() {
        let srcCh = ti == 0 ? 2 : 1
        let ch = cfg.mono24k ? 1 : srcCh
        let frames = Int(48000.0 * sliceSeconds * (cfg.mono24k ? 0.5 : 1.0))
        let expected = 44 + frames * ch * bytesPerSample
        let delta = abs(bytes - expected)
        // 重采样会带来 ±半个窗宽（约 64 样本）的帧数差，按 1% 容差判
        let ok = Double(delta) < Double(expected) * 0.01
        print(String(format: "  %-22@ 轨%d  实测 %9d  B  预期 %9d B  Δ %5d  %@",
                     cfg.label as NSString, ti,
                     bytes, expected, delta, ok ? "OK" : "偏差过大"))
    }
    _ = write
}

print("DONE")
