// 分轨静音的真机验证探针。
//
// ## 为什么必须是独立可执行文件，而不是 `swift test` 用例
//
// 系统音频 Process Tap 要求发起进程**有 bundle 身份**才能通过 TCC
// （「屏幕与系统音频录制」授权是按 bundle id 记的）。`xctest` 没有 bundle，
// 于是真机用例在 CI / 命令行下会**静默停在权限弹窗**——实测卡了 7 分钟无输出。
// 项目里已有的 `scripts/probes/*` 全部遵守同一条纪律。
//
// 所以这里把探针编译成 `.app` 里的可执行文件复用 `com.pxing.mr` 的授权，
// 由 `scripts/run-mute-probe.sh` 负责放进 bundle 并运行。
//
// ## 它验证什么
//
// 单测与真机用例都证明不了「静音期间写进文件的那段真的是零」——
// manifest 只记录"静音了多久"，对那段时间的文件内容一无所知。
// 这个探针直接把两个 wav 读出来，按静音区间切段、逐采样检查：
//
// 1. **静音区间内必须逐采样为 0**（不是"接近 0"，是真 0）
// 2. **静音区间外必须有非零采样**（证明写入通路本身是通的，不是整轨全零）
// 3. **两轨文件长度必须一致**（回放与按轨对齐转写的前提）
//
// ## 依赖
//
// 需要 `MeetingRecorder.app` 已签名且已获麦克风 + 屏幕与系统音频录制授权。
// 运行时用 `MEETING_RECORDER_ROOT` 覆盖录音目录，避免污染真实会议库。

import Foundation
import MRCore
import MRCapture
import MRSession

// MARK: - 小工具

func say(_ text: String) {
    print(text)
    fflush(stdout)
}

func fail(_ text: String) -> Never {
    say("FAIL: \(text)")
    exit(1)
}

func sleepSeconds(_ seconds: Double) {
    Thread.sleep(forTimeInterval: seconds)
}

/// 读一个 wav 的全部采样（float32 / 原始字节）。
struct Wave {
    let sampleRate: Double
    let channels: Int
    let frames: [Float]
}

func readWave(_ url: URL) throws -> Wave {
    let data = try Data(contentsOf: url)
    guard data.count > 44 else { throw NSError(domain: "probe", code: 1) }
    func u32(_ at: Int) -> Int {
        Int(data[at]) | (Int(data[at + 1]) << 8)
            | (Int(data[at + 2]) << 16) | (Int(data[at + 3]) << 24)
    }
    func u16(_ at: Int) -> Int { Int(data[at]) | (Int(data[at + 1]) << 8) }

    let channels = u16(22)
    let sampleRate = Double(u32(24))
    let bits = u16(34)
    // 只支持本项目实际产出的两种格式，其余一律报错而不是猜
    let formatCode = u16(20)
    guard bits == 32 && formatCode == 3 else {
        throw NSError(domain: "probe", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "探针只处理 32 位 float wav，实际 bits=\(bits) format=\(formatCode)"])
    }

    // 扫 data chunk（不能假设在 44 处——LIST 之类的块会插在中间）
    var offset = 12
    var dataStart = -1
    var dataSize = 0
    while offset + 8 <= data.count {
        let id = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
        let size = u32(offset + 4)
        if id == "data" {
            dataStart = offset + 8
            dataSize = min(size, data.count - dataStart)
            break
        }
        offset += 8 + size + (size % 2)
    }
    guard dataStart >= 0 else { throw NSError(domain: "probe", code: 3) }

    var frames: [Float] = []
    frames.reserveCapacity(dataSize / 4)
    var i = 0
    while i + 4 <= dataSize {
        let bitsValue = UInt32(data[dataStart + i])
            | (UInt32(data[dataStart + i + 1]) << 8)
            | (UInt32(data[dataStart + i + 2]) << 16)
            | (UInt32(data[dataStart + i + 3]) << 24)
        frames.append(Float(bitPattern: bitsValue))
        i += 4
    }
    return Wave(sampleRate: sampleRate, channels: max(1, channels), frames: frames)
}

/// 某段区间内的最大绝对采样值
func peak(in wave: Wave, from startSecond: Double, to endSecond: Double) -> Float {
    let lo = max(0, Int(startSecond * wave.sampleRate))
    let hi = min(wave.frames.count, Int(endSecond * wave.sampleRate))
    guard lo < hi else { return 0 }
    var peak: Float = 0
    for i in lo..<hi {
        let value = abs(wave.frames[i])
        if value > peak { peak = value }
    }
    return peak
}

// MARK: - 主流程

let envRoot = ProcessInfo.processInfo.environment["MEETING_RECORDER_ROOT"]
let root = URL(fileURLWithPath: envRoot ?? NSTemporaryDirectory())
    .appendingPathComponent("mr-mute-probe", isDirectory: true)

try? FileManager.default.removeItem(at: root)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

say("根目录：\(root.path)")

let store = SessionStore(root: root)
let recorder = DualTrackRecorder(store: store)

say("启动双轨录制…")
let sessionID: String
do {
    sessionID = try recorder.start(title: "分轨静音探针")
} catch {
    fail("启动失败：\(error)\n提示：系统音频需要「屏幕与系统音频录制」授权，且进程必须有 bundle 身份")
}
guard let dir = recorder.sessionDirectoryURL else { fail("会话目录未创建") }
say("会话：\(sessionID)")

// 录 3 秒正常内容
say("录 3 秒…")
sleepSeconds(3)

// 只静音 mic 轨
say("静音「我」（麦克风）3 秒…")
let muted = recorder.setMuted(true, trackID: "mic")
if !muted { fail("setMuted 返回 false——麦克风轨没有进入静音") }
if recorder.isMuted(trackID: "mic") != true { fail("isMuted(mic) 应为 true") }
if recorder.isMuted(trackID: "system") != false { fail("对方轨不该被静音") }

let muteStart = recorder.elapsed
sleepSeconds(3)
let muteEnd = recorder.elapsed
say("取消静音…")
recorder.setMuted(false, trackID: "mic")

sleepSeconds(2)
say("停止…")
let result: DualTrackRecorder.Result
do {
    result = try recorder.stop()
} catch {
    fail("收尾失败：\(error)")
}

// MARK: - 断言

say("")
say("=== 分轨静音探针结果 ===")

// 1. 记录带上了轨 id
let soloSpans = result.manifest.pauses.filter { $0.trackID == "mic" }
if soloSpans.count != 1 {
    fail("应当正好一条「我轨静音」记录，实际 \(soloSpans.count) 条：\(result.manifest.pauses)")
}
let span = soloSpans[0]
say("静音记录：\(String(format: "%.2f", span.duration))s，起点 \(String(format: "%.2f", span.startedAfter))s")

if abs(span.duration - 3) > 1.0 {
    fail("静音时长 \(span.duration)s 明显不对（预期约 3s）")
}

// 分轨静音不该算成全场暂停
if abs(result.manifest.pausedTotal) > 0.001 {
    fail("分轨静音不该计入 pausedTotal，实际 \(result.manifest.pausedTotal)")
}

// 2 & 3. 两轨等长 + 静音段真的是零
let micURL = dir.appendingPathComponent("mic.wav")
let systemURL = dir.appendingPathComponent("system.wav")

let micWave: Wave
let systemWave: Wave
do {
    micWave = try readWave(micURL)
    systemWave = try readWave(systemURL)
} catch {
    fail("读 wav 失败：\(error)")
}

let micSeconds = Double(micWave.frames.count) / micWave.sampleRate
let systemSeconds = Double(systemWave.frames.count) / systemWave.sampleRate
say("两轨时长：我 \(String(format: "%.2f", micSeconds))s / 对方 \(String(format: "%.2f", systemSeconds))s")

if abs(micSeconds - systemSeconds) > 0.3 {
    fail("两轨长度分叉（\(micSeconds) vs \(systemSeconds)）——静音破坏了等长占位")
}

// 静音区间（用 manifest 记录的墙钟偏移换算成文件内位置）
// 文件从 0 开始就是墙钟 0（静音不掐掉任何长度），所以直接用 startedAfter。
let muteLo = span.startedAfter + 0.3
let muteHi = span.startedAfter + span.duration - 0.3

// 掐头去尾各 0.3 秒：切换边界上那一个 buffer 可能跨在区间两端，
// 判据要留余量，否则测的是切换延迟而不是"静音里有没有声音"。
let mutedPeak = peak(in: micWave, from: muteLo, to: muteHi)
let micBefore = peak(in: micWave, from: 0.5, to: muteLo - 0.5)
let micAfter = peak(in: micWave, from: muteHi + 0.5, to: micSeconds - 0.5)

say("我轨峰值：静音前 \(String(format: "%.6f", micBefore)) / "
    + "静音中 \(String(format: "%.6f", mutedPeak)) / 静音后 \(String(format: "%.6f", micAfter))")

// 判据 1：静音区间必须**逐采样为 0**
if mutedPeak != 0 {
    fail("静音区间峰值是 \(mutedPeak)，不是 0——静音没有真的写静音帧")
}

// 判据 2：静音区间外必须有非零采样。
// 这一条不能省：若整轨本来就是全零（例如权限没拿到），判据 1 会"通过"，
// 而真实原因是根本没录到东西。必须证明写入通路本身是通的。
if micBefore == 0 && micAfter == 0 {
    fail("我轨静音区间外也是全零——这轨压根没录到东西（多半是麦克风权限未授予），"
        + "此时「静音区间为零」不代表静音功能有效")
}

say("")
say("PASS：静音区间逐采样为 0，区间外有真实音频，两轨等长。")
exit(0)