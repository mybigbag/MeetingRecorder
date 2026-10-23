import XCTest
@testable import MRCore
import Foundation

/// 双轨合并（`AudioTrackMerger`）的用例。
///
/// ## 这个模块的失败模式都是「听起来不对但看不出哪里错」
///
/// 合并错位 30 毫秒 → 回声；削顶 → 刺耳；把两条轨平均成一个 → 两人同时说话互相掩盖。
/// 这些**没有一个会让文件打不开**。所以这里的断言全部落在「数值关系」上，
/// 而不是「文件存在」「长度对」这种表面检查。
///
/// 最值钱的一条是 `testStereoSplitKeepsBothTracksSeparatelyRecoverable`：
/// 它从合并结果里**把两轨拆回来**，逐样本与原始比对。
/// 合并是**有损**的（16 位量化），所以判据是量化误差界，不是精确相等——
/// 详见该用例注释。
final class AudioTrackMergerTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-merge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// 写一个 WAV 并回读校验过。
    ///
    /// `tone(frame, channel)` 生成该帧该声道的采样。**必须传声道下标**——
    /// 只传帧号的话每个声道拿到同一个值，于是「双声道不等幅」这种夹具根本写不出来，
    /// 而那正是验证降混/分置必须有的形状（本模块第一版就栽在这里：
    /// 一个「左=右」的立体声夹具让 average 与 firstChannel 必然同值，
    /// 于是断言写成「两者必须不同」时，测的其实是夹具而不是代码）。
    @discardableResult
    private func makeWAV(_ name: String, seconds: Double, rate: Double,
                         channels: Int, format: WAVSampleFormat,
                         tone: (Int, Int) -> Float) throws -> URL {
        let target = url(name)
        let writer = try WAVWriter(url: target, sampleRate: rate,
                                   channels: channels, format: format)
        let frames = Int(rate * seconds)
        var block: [Float] = []
        block.reserveCapacity(48000 * channels)
        for f in 0..<frames {
            for c in 0..<channels { block.append(tone(f, c)) }
            if block.count >= 48000 * channels {
                try writer.append(block)
                block.removeAll(keepingCapacity: true)
            }
        }
        if !block.isEmpty { try writer.append(block) }
        try writer.finalize()
        writer.close()
        return target
    }

    /// 各声道**不等幅**的正弦：440 Hz / 0.5 幅、660 Hz / 0.3 幅。
    ///
    /// 刻意不用等幅：等幅素材下「左=轨1、右=轨2」和「左右都=平均」会给出相同结果，
    /// 用它写断言就会得到「删掉合并逻辑照样绿」的假测试——这个坑本项目踩过。
    private func twoTone(_ f: Int, _ channel: Int = 0) -> Float {
        let t = Double(f) / 48000
        return Float(0.5 * sin(2 * .pi * 440 * t))
    }

    private func twoToneRight(_ f: Int, _ channel: Int = 0) -> Float {
        let t = Double(f) / 48000
        return Float(0.3 * sin(2 * .pi * 660 * t))
    }

    /// 按声道给出不同幅度的常量（左 0.5 / 右 0.2）。
    private func stereoAlternating(_ channel: Int) -> Float {
        channel == 0 ? 0.5 : 0.2
    }

    private func input(_ path: URL, offset: Double = 0, label: String = "mic") throws
        -> AudioTrackMerger.Input {
        let header = try WAVWriter.readHeader(at: path)
        return AudioTrackMerger.Input(url: path, header: header,
                                       format: AudioTranscoder.sourceFormat(of: header),
                                       offsetSeconds: offset, label: label)
    }

    private func readMono(_ path: URL) throws -> [Float] {
        let r = try WAVReader(url: path)
        let raw = try r.read(start: 0, end: 3600)
        return r.channels == 1 ? raw : MonoDownmix.mix(raw, channels: r.channels, strategy: .average)
    }

    private func readChannel(_ path: URL, _ channel: Int) throws -> [Float] {
        let r = try WAVReader(url: path)
        let raw = try r.read(start: 0, end: 3600)
        guard r.channels > 1 else { return raw }
        return stride(from: channel, to: raw.count, by: r.channels).map { raw[$0] }
    }

    // MARK: - 决策（纯函数）

    /// 输出采样率取各轨最小值。**绝不升采样**——本项目麦克风常是 24 kHz、
    /// 系统音频 48 kHz，升上去不会多出信息，只会让文件变大。
    func testOutputSampleRateIsTheMinimumOfAllInputs() throws {
        let a = try input(try makeWAV("a.wav", seconds: 0.1, rate: 48000,
                                      channels: 1, format: .float32) { _, _ in 0.3 })
        let b = try input(try makeWAV("b.wav", seconds: 0.1, rate: 24000,
                                      channels: 2, format: .float32) { _, _ in 0.3 })
        XCTAssertEqual(AudioTrackMerger.resolveOutputSampleRate([a, b]), 24000)
        XCTAssertEqual(AudioTrackMerger.resolveOutputSampleRate([b, a]), 24000,
                       "顺序不能影响结果")
    }

    func testOutputChannelsDependOnMode() throws {
        XCTAssertEqual(AudioTrackMerger.resolveOutputChannels(mode: .stereoSplit, trackCount: 2), 2)
        XCTAssertEqual(AudioTrackMerger.resolveOutputChannels(mode: .monoMix, trackCount: 2), 1)
        XCTAssertEqual(AudioTrackMerger.resolveOutputChannels(mode: .stereoSplit, trackCount: 1), 1,
                       "只有一条轨时立体声没有意义，退成单声道")
    }

    /// 时长取「最晚结束的那条轨」，不是「最长的那条」。
    /// 一条轨既短又晚结束时，会议的结束时刻由它决定。
    func testDurationIsTheLatestEndNotTheLongestTrack() throws {
        let long = try input(try makeWAV("long.wav", seconds: 2.0, rate: 48000,
                                          channels: 1, format: .float32) { _, _ in 0.3 })
        let shortLate = try input(try makeWAV("short.wav", seconds: 1.0, rate: 48000,
                                              channels: 1, format: .float32) { _, _ in 0.3 },
                                 offset: 1.5)
        let d = AudioTrackMerger.resolveDuration(outputSampleRate: 48000,
                                                  inputs: [long, shortLate], mode: .stereoSplit)
        XCTAssertEqual(d, 2.5, accuracy: 0.01, "1.5 秒的偏移 + 1 秒内容 = 2.5 秒结束")
        XCTAssertNotEqual(d, 2.0, "不能取最长音频的长度")
    }

    /// **退化示例**：把 `frameRange` 里的偏移取整去掉（`start` 恒为 0），
    /// 本用例与后面所有偏移用例一起变红。
    func testFrameRangePlacesTrackAtItsOffset() throws {
        let a = try input(try makeWAV("a.wav", seconds: 1.0, rate: 48000,
                                      channels: 1, format: .float32) { _, _ in 0.3 },
                          offset: 0.25)
        let r = AudioTrackMerger.frameRange(of: a, outputSampleRate: 48000, mode: .stereoSplit)
        XCTAssertEqual(r.start, 12000, "0.25 秒 @ 48 kHz = 12000 帧")
        XCTAssertEqual(r.end, 12000 + 48000)
    }

    /// 重采样后帧数按比例缩放。48 kHz 1 秒 → 24 kHz 应得 24000 帧。
    func testFrameRangeScalesByResampleRatio() throws {
        let a = try input(try makeWAV("a.wav", seconds: 1.0, rate: 48000,
                                      channels: 1, format: .float32) { _, _ in 0.3 })
        let r = AudioTrackMerger.frameRange(of: a, outputSampleRate: 24000, mode: .stereoSplit)
        XCTAssertEqual(r.end - r.start, 24000)
    }

    // MARK: - 立体声分置

    /// **本文件最重要的一条**。
    ///
    /// 合并后把左/右声道拆回来，与各自的原始轨逐样本比对。
    /// 判据用 16 位量化误差界（`1/32767`）而不是精确相等——
    /// 合并到 pcm16 **必然**引入量化，那不是错误。
    ///
    /// 退化示例：把 `placement` 的 `i % 2` 写成 `0`（两轨都进左声道），
    /// 本用例立刻红；把两轨内容对调，也会红。
    func testStereoSplitKeepsBothTracksSeparatelyRecoverable() throws {
        let mic = try makeWAV("mic.wav", seconds: 1.0, rate: 48000,
                              channels: 1, format: .float32) { f, _ in twoTone(f) }
        let sys = try makeWAV("sys.wav", seconds: 1.0, rate: 48000,
                              channels: 2, format: .float32) { f, _ in twoToneRight(f) }
        let out = url("merged.wav")
        let result = try AudioTrackMerger.merge(
            inputs: [try input(mic, label: "mic"), try input(sys, label: "system")],
            destination: out, mode: .stereoSplit, format: .pcm16)

        XCTAssertEqual(result.channels, 2)
        let tol = Float(1.0 / 32767.0)
        let left = try readChannel(out, 0)
        let right = try readChannel(out, 1)
        let srcMic = try readMono(mic)
        let srcSys = try readMono(sys)

        XCTAssertEqual(left.count, 48000, accuracy: 64)
        XCTAssertEqual(right.count, 48000, accuracy: 64)
        for i in 0..<min(left.count, srcMic.count) {
            XCTAssertEqual(left[i], srcMic[i], accuracy: tol,
                           "左声道第 \(i) 个样本不是麦克风轨")
        }
        for i in 0..<min(right.count, srcSys.count) {
            XCTAssertEqual(right[i], srcSys[i], accuracy: tol,
                           "右声道第 \(i) 个样本不是系统轨")
        }
    }

    /// 左=我、右=对方，**不能对调**。对调了听感上仍然「两个人都在」，
    /// 但用耳机的人会按左边找人——找错人。
    func testLeftIsMicAndRightIsSystem() throws {
        let mic = try makeWAV("mic.wav", seconds: 0.5, rate: 48000, channels: 1,
                              format: .float32) { _, _ in 0.5 }
        let sys = try makeWAV("sys.wav", seconds: 0.5, rate: 48000, channels: 1,
                              format: .float32) { _, _ in -0.5 }
        let out = url("m.wav")
        _ = try AudioTrackMerger.merge(
            inputs: [try input(mic, label: "mic"), try input(sys, label: "system")],
            destination: out, mode: .stereoSplit, format: .float32)
        let left = try readChannel(out, 0)
        let right = try readChannel(out, 1)
        let l = left[1000], r = right[1000]
        XCTAssertGreaterThan(l, 0.2, "左声道应是我（常量 +0.5）")
        XCTAssertLessThan(r, -0.2, "右声道应是对方（常量 -0.5）")
    }

    /// **源已经是 pcm16 时，量化只允许发生一次。**
    ///
    /// 这条用例是被真实数据逼出来的：`testStereoSplitKeepsBothTracksSeparatelyRecoverable`
    /// 的源是 float32，合并器在写盘前多做了一次 `effectiveAfterQuantisation`，
    /// 误差最多 1 LSB（`1/32768` ≈ `0.0000305`），而那条用例的判据是
    /// `1/32767` ≈ `0.0000305`——**刚好卡在界内**，于是缺陷从它下面溜了过去。
    ///
    /// 源换成 pcm16 就露馅了：读出来是 `x/32768`，第一次量化 `-1`，
    /// 写盘再量化一次又 `-1`，实测真实会议库（2026-09-27-202956）里
    /// 145 万样本有 6235 个（0.44%）与源差 ±2。
    ///
    /// 退化示例：把写盘前的 `s` 换回 `WAVWriter.effectiveAfterQuantisation(s)`
    /// （主循环与尾部两处），本用例立刻红。
    func testPCM16SourceIsNotQuantisedTwice() throws {
        // ⚠️ 幅值必须 > 0.5，这是本用例能不能抓住缺陷的**前提**。
        // 推导：读侧 `x/32768`、写侧 `×32767`，量化一次的净效果是 `x → x - x/32768`。
        // `x/32768 < 0.5`（即 x < 16384，幅值 < 0.5）时四舍五入回 x，**误差恰好为 0**；
        // 量化两次也一样是 0 —— 缺陷在这个区间**根本不可见**。
        // 真实会议库那场的 system 轨峰值 32587（幅值 0.99）正好过线，
        // 所以才有 0.44% 的样本差 2。夹具若用 0.4 就会写成一条假绿测试。
        let mic = try makeWAV("mic16.wav", seconds: 0.5, rate: 48000, channels: 1,
                              format: .pcm16) { f, _ in
            Float(0.9 * sin(2 * .pi * 440 * Double(f) / 48000))
        }
        let sys = try makeWAV("sys16.wav", seconds: 0.5, rate: 48000, channels: 1,
                              format: .pcm16) { f, _ in
            Float(-0.95 * sin(2 * .pi * 660 * Double(f) / 48000))
        }
        let out = url("merged16.wav")
        _ = try AudioTrackMerger.merge(
            inputs: [try input(mic, label: "mic"), try input(sys, label: "system")],
            destination: out, mode: .stereoSplit, format: .pcm16)

        // 源本身已经是 16 位整数，回读时必然带着「读侧 ÷32768 / 写侧 ×32767」
        // 这一次 unavoidable 的量化（±1 LSB）。判据就定在 1 LSB：
        // 再多就是被量化了两次。
        let oneLSB = 1.0 / 32767.0
        let left = try readChannel(out, 0)
        let right = try readChannel(out, 1)
        let srcMic = try readMono(mic)
        let srcSys = try readMono(sys)

        var worstMic: Float = 0
        for i in 0..<min(left.count, srcMic.count) {
            worstMic = max(worstMic, abs(left[i] - srcMic[i]))
        }
        var worstSys: Float = 0
        for i in 0..<min(right.count, srcSys.count) {
            worstSys = max(worstSys, abs(right[i] - srcSys[i]))
        }
        XCTAssertLessThanOrEqual(Double(worstMic), Double(oneLSB),
                                 "左声道最大误差 \(worstMic) 超过 1 LSB —— 被量化了不止一次")
        XCTAssertLessThanOrEqual(Double(worstSys), Double(oneLSB),
                                 "右声道最大误差 \(worstSys) 超过 1 LSB —— 被量化了不止一次")
    }

    /// **退化示例**：把 `placement` 的除法 `v / share` 改成直接 `v`，
    /// 两轨相加超过 1.0 → 削顶，本用例红。
    func testMonoMixAveragesInsteadOfSummingSoItCannotClip() throws {
        let a = try makeWAV("a.wav", seconds: 0.5, rate: 48000, channels: 1,
                            format: .float32) { _, _ in 0.8 }
        let b = try makeWAV("b.wav", seconds: 0.5, rate: 48000, channels: 1,
                            format: .float32) { _, _ in 0.8 }
        let out = url("mono.wav")
        let result = try AudioTrackMerger.merge(
            inputs: [try input(a, label: "mic"), try input(b, label: "system")],
            destination: out, mode: .monoMix, format: .float32)
        XCTAssertEqual(result.channels, 1)
        let samples = try readMono(out)
        let peak = samples.reduce(0) { max($0, abs($1)) }
        XCTAssertLessThanOrEqual(peak, 1.0, "两轨各 0.8，求和会到 1.6 → 削顶")
        XCTAssertEqual(peak, 0.8, accuracy: 0.02, "平均后应约等于 0.8")
    }

    // MARK: - 偏移对齐（本功能的灵魂）

    /// 晚开始的那轨必须在**前面留出等量的静音**，而不是从 0 秒就开始。
    ///
    /// 退化示例：把 `frameRange` 的 `start` 去掉偏移（恒为 0），
    /// 本用例红；把偏移符号取反，也红。
    func testLaterTrackIsShiftedByItsOffset() throws {
        let early = try makeWAV("early.wav", seconds: 1.0, rate: 48000, channels: 1,
                                format: .float32) { _, _ in 0.5 }
        let late = try makeWAV("late.wav", seconds: 1.0, rate: 48000, channels: 1,
                               format: .float32) { _, _ in -0.5 }
        let out = url("m.wav")
        _ = try AudioTrackMerger.merge(
            inputs: [try input(early, label: "mic"),
                     try input(late, offset: 0.5, label: "system")],
            destination: out, mode: .stereoSplit, format: .float32)

        let right = try readChannel(out, 1)
        // 0.5 秒之前右声道必须是静音（偏移 0.5 s = 24000 帧）
        XCTAssertEqual(right[24000 - 100], 0, accuracy: 1e-6,
                       "偏移之前右声道不该有声音")
        // 偏移之后才有内容
        let afterOffset = right[24000 + 2400]
        XCTAssertEqual(afterOffset, -0.5, accuracy: 0.02,
                       "偏移 \(24000 + 2400) 帧处应已有对方的声音")
    }

    /// **退化示例**：把偏移对齐去掉（start 恒 0），
    /// 两个人同时说话时差 0.5 秒 —— 听起来像回声。
    /// 这条断言直接测「整体长度」：1.0 秒 + 0.5 秒偏移 = 1.5 秒。
    func testMergedLengthAccountsForOffset() throws {
        let a = try makeWAV("a.wav", seconds: 1.0, rate: 48000, channels: 1,
                            format: .float32) { _, _ in 0.4 }
        let b = try makeWAV("b.wav", seconds: 1.0, rate: 48000, channels: 1,
                            format: .float32) { _, _ in 0.4 }
        let out = url("m.wav")
        let result = try AudioTrackMerger.merge(
            inputs: [try input(a, label: "mic"),
                     try input(b, offset: 0.5, label: "system")],
            destination: out, mode: .stereoSplit, format: .float32)
        XCTAssertEqual(result.duration, 1.5, accuracy: 0.005,
                       "总长必须含偏移，否则末尾 0.5 秒被切掉")
    }

    /// 合并结果的时长（不含 FIR 尾部补零）与理论值的差应在 2 ms 内。
    ///
    /// 退化示例：把 `drain()` 去掉，差值会变成约半个窗宽（48k→24k 约 1.3 ms）——
    /// 仍在 2 ms 内，所以这条单独抓不到，**必须配 `testTailIsDrainedSoLastSampleSurvives`**。
    func testDurationMatchesTheory() throws {
        let a = try makeWAV("a.wav", seconds: 2.0, rate: 48000, channels: 1,
                            format: .float32) { _, _ in 0.4 }
        let b = try makeWAV("b.wav", seconds: 2.0, rate: 48000, channels: 2,
                            format: .float32) { _, _ in 0.3 }
        let out = url("m.wav")
        let result = try AudioTrackMerger.merge(
            inputs: [try input(a, label: "mic"), try input(b, label: "system")],
            destination: out, mode: .stereoSplit, format: .pcm16)
        XCTAssertEqual(result.duration, 2.0, accuracy: 0.002)
    }

    /// **退化示例**：删掉合并末尾的 `drain()` 循环，本用例红。
    ///
    /// 常量输入让这件事特别明显：零相位 FIR 的尾部靠补零才能算出最后那几十个样本，
    /// 不排空就等于把文件的结尾**静默截掉**——听感是「最后一个字没了」。
    func testTailIsDrainedSoLastSampleSurvives() throws {
        // **必须是混合采样率**。同采样率（48k→48k）时重采样器走透传，
        // `flush()` 本来就返回空数组，于是把 `drain()` 整段废掉这条用例照样绿——
        // 这条假绿是实测出来的：变异 M4（`flush()` 改成返回空）打不动它。
        // 48k→24k 才会真正跑 129 抽头 FIR，尾部才有那 32 个输出样本要排空。
        let a = try makeWAV("a.wav", seconds: 2.0, rate: 48000, channels: 1,
                            format: .float32) { _, _ in 0.4 }
        let b = try makeWAV("b.wav", seconds: 2.0, rate: 24000, channels: 1,
                            format: .float32) { _, _ in 0.4 }
        let out = url("m.wav")
        let result = try AudioTrackMerger.merge(
            inputs: [try input(a, label: "mic"), try input(b, label: "system")],
            destination: out, mode: .stereoSplit, format: .float32)
        XCTAssertEqual(result.sampleRate, 24000, "取两轨最小值 → 48k 那条会被降采样")

        let samples = try readChannel(out, 0)
        // 48k 的那条轨（走 FIR）在输出末尾应多出约 32 帧（≈1.33 ms）的尾部。
        // 判据刻意钉在**帧数**而不是「末尾还有多大力」：常量输入经过 FIR 尾部
        // 补零后幅值本来就会衰减，用幅度判据等于在测滤波器系数而不是测 drain。
        let expectedMain = 2.0 * 24000.0  // 48000 帧 / 2 = 24000 输出帧
        let written = Double(result.framesWritten)
        XCTAssertGreaterThan(written, expectedMain,
                             "输出帧数必须多于主循环写入的 \(expectedMain)——"
                             + "多出来的就是 FIR 尾部，缺了它最后几十个样本会被补零静音")
        // 帧数不能多出太多（129 抽头 → 尾部 32 输出样本；给 512 的宽松界）
        XCTAssertLessThan(written, expectedMain + 512.0)
        // 末尾不是静音
        XCTAssertGreaterThan(samples.suffix(32).reduce(0) { max($0, abs($1)) }, 0.05,
                             "文件末尾是静音——drain() 没生效")
    }

    /// **退化示例**：把合并末尾的 `drain()` 循环整个删掉，本用例红。
    /// 这条与 `testTailIsDrainedSoLastSampleSurvives` 互为补充：
    /// 那条测「帧数与末尾非静音」，这条测「尾部样本确实来自 flush()」。
    func testFlushTailIsActuallyWrittenIntoTheOutput() throws {
        let a = try makeWAV("a.wav", seconds: 1.0, rate: 48000, channels: 1,
                            format: .float32) { f, _ in Float(f) * 0 + 0.4 }
        let b = try makeWAV("b.wav", seconds: 1.0, rate: 24000, channels: 1,
                            format: .float32) { _, _ in 0.4 }
        let withDrain = url("drain.wav")
        let result = try AudioTrackMerger.merge(
            inputs: [try input(a, label: "mic"), try input(b, label: "system")],
            destination: withDrain, mode: .stereoSplit, format: .float32)

        // 同一份输入、手工只跑主循环能写出的帧数（= 时长 × 输出率）
        let mainLoopFrames = Int((1.0 * 24000).rounded())
        let tailFrames = result.framesWritten - mainLoopFrames
        XCTAssertGreaterThan(tailFrames, 0,
                             "flush() 的尾部样本没有写进输出——drain() 白调了")
        // 尾部帧数应与 FIR 半宽一致（129 抽头 → 64 输入 → 32 输出）
        XCTAssertLessThanOrEqual(tailFrames, 64,
                                  "尾部远多于一个窗宽，说明不是 FIR 尾部而是重复写了数据")
    }

    // MARK: - 分块不变性

    /// **退化示例**：把 `chunkFrames` 硬编码成一个大数（不读参数），
    /// 本用例红。无状态实现会在每个块边界制造咔哒声。
    func testChunkSizeDoesNotChangeTheOutput() throws {
        let mic = try makeWAV("mic.wav", seconds: 1.0, rate: 48000, channels: 1,
                              format: .float32) { f, _ in twoTone(f) }
        let sys = try makeWAV("sys.wav", seconds: 1.0, rate: 48000, channels: 2,
                              format: .float32) { f, _ in twoToneRight(f) }
        var reference: [Float]?
        for chunk in [1, 7, 512, 48000, 1_000_000] {
            let out = url("chunk-\(chunk).wav")
            _ = try AudioTrackMerger.merge(
                inputs: [try input(mic, label: "mic"), try input(sys, label: "system")],
                destination: out, mode: .stereoSplit, format: .pcm16, chunkFrames: chunk)
            let left = try readChannel(out, 0)
            if let reference {
                XCTAssertEqual(left.count, reference.count,
                               "chunkFrames=\(chunk) 改变了输出长度")
                for i in 0..<min(left.count, reference.count) {
                    XCTAssertEqual(left[i], reference[i],
                                   "chunkFrames=\(chunk) 在第 \(i) 帧产生了不同结果")
                }
            } else {
                reference = left
            }
        }
    }

    /// 不同源采样率的两轨（麦克风 24 kHz + 系统 48 kHz）是**本机的常态**。
    /// 退化示例：不给低采样率那条走重采样，本用例红。
    func testMixedSourceSampleRatesBothLandAtTheCommonRate() throws {
        let mic = try makeWAV("mic.wav", seconds: 1.0, rate: 24000, channels: 1,
                              format: .float32) { _, _ in 0.5 }
        let sys = try makeWAV("sys.wav", seconds: 1.0, rate: 48000, channels: 2,
                              format: .float32) { _, _ in -0.4 }
        let out = url("m.wav")
        let result = try AudioTrackMerger.merge(
            inputs: [try input(mic, label: "mic"), try input(sys, label: "system")],
            destination: out, mode: .stereoSplit, format: .float32)
        XCTAssertEqual(result.sampleRate, 24000, "取两轨最小值，绝不升采样")
        XCTAssertEqual(result.duration, 1.0, accuracy: 0.002)
        let header = try WAVWriter.readHeader(at: out)
        XCTAssertEqual(header.sampleRate, 24000)
        // 低采样率那条不能被「拉高」成多一倍的数据
        XCTAssertLessThan(result.framesWritten, 24000 + 64)
    }

    // MARK: - 静音与体检

    /// **本机真实数据里就有 3 条 100% 静音轨**（当时系统音频采集没起来）。
    /// 合并后总体有声音，用户不会发现对方那一路是空的。
    /// 退化示例：把 `silentTracks()` 的判据去掉（永远返回空），
    /// 本用例红。
    func testSilentTrackIsDetectedInTheResult() throws {
        let mic = try makeWAV("mic.wav", seconds: 0.5, rate: 48000, channels: 1,
                              format: .float32) { _, _ in 0.5 }
        let silent = try makeWAV("silent.wav", seconds: 0.5, rate: 48000, channels: 2,
                                 format: .float32) { _, _ in 0 }
        let out = url("m.wav")
        let result = try AudioTrackMerger.merge(
            inputs: [try input(mic, label: "mic"),
                     try input(silent, label: "system")],
            destination: out, mode: .stereoSplit, format: .pcm16)
        XCTAssertEqual(result.silentTracks(), ["system"],
                       "对方那轨全静音，必须能被指出来")
        XCTAssertGreaterThan(result.peakAmplitude, 0.4,
                             "总体有声音——这正是「用户发现不了」的原因")
    }

    func testNoSilentTracksWhenBothHaveSignal() throws {
        let a = try makeWAV("a.wav", seconds: 0.3, rate: 48000, channels: 1,
                            format: .float32) { _, _ in 0.5 }
        let b = try makeWAV("b.wav", seconds: 0.3, rate: 48000, channels: 1,
                            format: .float32) { _, _ in 0.4 }
        let out = url("m.wav")
        let result = try AudioTrackMerger.merge(
            inputs: [try input(a, label: "mic"), try input(b, label: "system")],
            destination: out, mode: .stereoSplit, format: .pcm16)
        XCTAssertTrue(result.silentTracks().isEmpty)
    }

    // MARK: - 失败路径

    /// **退化示例**：删掉这个 guard，空文件会一路走到 WAVWriter 写出一个 44 字节文件，
    /// 用户拿到的是「0 秒的合并结果」而不是明确报错。
    func testEmptyTrackIsRejectedWithItsName() throws {
        let a = try input(try makeWAV("a.wav", seconds: 0.2, rate: 48000, channels: 1,
                                      format: .float32) { _, _ in 0.3 }, label: "mic")
        let emptyHeader = WAVHeaderInfo(audioFormatID: 3, channels: 1, sampleRate: 48000,
                                         bitsPerSample: 32, dataSize: 0, dataOffset: 44,
                                         fileSize: 44)
        let empty = AudioTrackMerger.Input(url: url("none.wav"), header: emptyHeader,
                                            format: .float32, offsetSeconds: 0,
                                            label: "system")
        XCTAssertThrowsError(try AudioTrackMerger.merge(
            inputs: [a, empty], destination: url("out.wav"))) { error in
            XCTAssertTrue("\(error)".contains("system"),
                          "报错要指明是哪条轨：\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("out.wav").path),
                       "失败不该留下产物")
    }

    func testNoInputsIsRejected() {
        XCTAssertThrowsError(try AudioTrackMerger.merge(
            inputs: [], destination: url("x.wav")))
    }

    /// 合并失败时目标文件必须被删掉（`WAVWriter.abort` 的语义）。
    func testFailureLeavesNoPartialFile() throws {
        let a = try input(try makeWAV("a.wav", seconds: 0.2, rate: 48000, channels: 1,
                                      format: .float32) { _, _ in 0.3 })
        // destination 指向一个不存在的目录 → writer 创建失败
        let bad = dir.appendingPathComponent("no-such-dir/x.wav")
        XCTAssertThrowsError(try AudioTrackMerger.merge(inputs: [a, a], destination: bad))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
    }

    // MARK: - 降混策略贯通

    /// **退化示例**：把 `downmix` 参数从 merge 漏掉（传默认 `.average`），
    /// 本用例红。
    ///
    /// 夹具刻意用**只有一路是多声道**的形状（mic 单声道 0.5、system 双声道 0.5/0.2）：
    /// 这样 average 得到 (0.5+0.2)/2 = 0.35，firstChannel 得到 0.5，两者差得开。
    /// 若两条轨都是等幅单声道，两种策略必然同值——用那种夹具写断言，
    /// 就会得到「删掉 downmix 照样绿」的假测试（本项目踩过同类坑）。
    func testFirstChannelStrategyChangesTheOutput() throws {
        let mono = try makeWAV("mono.wav", seconds: 0.5, rate: 48000, channels: 1,
                               format: .float32) { _, _ in 0.5 }
        // 双声道：左 0.5、右 0.2（不等幅，所以平均与取第 1 声道必然不同）。
        // 显式给两个值而不是用 `twoTone` 换算——换算会把幅度算错，
        // 而「夹具算错」与「被测代码算错」在断言上长得一模一样。
        let stereo = try makeWAV("stereo.wav", seconds: 0.5, rate: 48000, channels: 2,
                                 format: .float32, tone: { _, c in stereoAlternating(c) })
        let outAvg = url("avg.wav")
        let outFirst = url("first.wav")
        _ = try AudioTrackMerger.merge(
            inputs: [try input(mono, label: "mic"), try input(stereo, label: "system")],
            destination: outAvg, mode: .monoMix, format: .float32, downmix: .average)
        _ = try AudioTrackMerger.merge(
            inputs: [try input(mono, label: "mic"), try input(stereo, label: "system")],
            destination: outFirst, mode: .monoMix, format: .float32,
            downmix: .firstChannel)

        // average: (0.5 + 0.35)/2 ≈ 0.425；firstChannel: (0.5 + 0.5)/2 = 0.5
        let avgPeak = try readMono(outAvg).reduce(0) { max($0, abs($1)) }
        let firstPeak = try readMono(outFirst).reduce(0) { max($0, abs($1)) }
        XCTAssertEqual(avgPeak, 0.425, accuracy: 0.03)
        XCTAssertEqual(firstPeak, 0.5, accuracy: 0.03)
        XCTAssertNotEqual(avgPeak, firstPeak, accuracy: 0.02,
                          "两种降混策略给出了相同结果——downmix 没生效")
    }
}
