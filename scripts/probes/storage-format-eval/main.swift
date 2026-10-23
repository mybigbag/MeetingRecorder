// 减存储方案的**前提验证**探针：降格式之后，转写结果会不会变差？
//
// ## 为什么要先验这一步
//
// 「把 float32/48k/立体声换成 pcm16/16k/单声道」在体积上一定成立（算术题），
// 但它撞到一个不能靠推理回答的问题：**识别质量会不会掉？** 掉多少？
// 这决定了「降格式」是免费收益还是有代价的取舍。
//
// 更麻烦的是，引擎本身可能有抖动——同一份音频跑两遍结果未必逐字相同。
// 不做对照就无法区分「差异来自降格式」还是「差异来自引擎抖动」。
// 所以这个探针**必须**要求调用方给一组重复样本（同一文件出现两次）。
//
// ## 这个探针只干一件事
//
// 用**生产同款链路**（`AppleSpeechTranscriber`，不是另写一个简化版）把每个
// 文件的转写结果落成 txt，比对交给 python 的 difflib——Swift 里手写 diff
// 容易把「对齐算法的问题」误当成「识别质量的问题」。
//
// ## 编译与运行
//
//   cd meeting-recorder
//   swift build --disable-sandbox
//   swiftc -O -I .build/debug -o /tmp/mr-storage-probe \
//     scripts/probes/storage-format-eval/main.swift \
//     .build/debug/MRCore.o .build/debug/MRTranscribe.o
//   /tmp/mr-storage-probe label=path [label=path ...]
//
// 输出：/tmp/mr-storage-eval/out-<label>.txt
import Foundation
import MRCore
import MRTranscribe

setvbuf(stdout, nil, _IONBF, 0)

struct Sample {
    let label: String
    let url: URL
}

let outDir = URL(fileURLWithPath: "/tmp/mr-storage-eval")

var samples: [Sample] = []
for arg in CommandLine.arguments.dropFirst() {
    let parts = arg.split(separator: "=", maxSplits: 1)
    guard parts.count == 2 else {
        print("参数格式应为 label=path，收到：\(arg)")
        exit(2)
    }
    let url = URL(fileURLWithPath: String(parts[1]))
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("文件不存在：\(url.path)")
        exit(2)
    }
    samples.append(Sample(label: String(parts[0]), url: url))
}

guard !samples.isEmpty else {
    print("用法：mr-storage-probe label=path [label=path ...]")
    exit(2)
}

guard AppleSpeechTranscriber.isAvailable else {
    print("苹果引擎不可用（需要 macOS 26+）")
    exit(1)
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let transcriber = AppleSpeechTranscriber()
try await transcriber.prepare()

print("转写 \(samples.count) 个文件（生产同款配置：SpeechTranscriber / zh-CN / 无标点开关）")
print(String(repeating: "-", count: 78))

for s in samples {
    let t0 = Date()
    do {
        let segments = try await transcriber.transcribe(
            fileURL: s.url, trackID: "probe", speaker: "探针")
        let text = segments.map(\.text).joined(separator: "\n")
        let elapsed = Date().timeIntervalSince(t0)

        // 引擎不给的话就是空转写——那也要落盘，别让「失败」看起来像「没跑」
        let dest = outDir.appendingPathComponent("out-\(s.label).txt")
        try text.write(to: dest, atomically: true, encoding: .utf8)

        let chars = text.filter { !$0.isWhitespace }.count
        print(String(format: "  %-22@ %5d 字　%6.1fs　→ out-%@.txt",
                     s.label as NSString, chars, elapsed, s.label as NSString))
    } catch {
        print("  \(s.label)：转写失败 — \(error)")
        exit(1)
    }
}

print(String(repeating: "-", count: 78))
print("DONE")
