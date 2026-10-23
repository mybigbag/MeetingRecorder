import XCTest
@testable import MRCore

/// 重采样核与降混的纯逻辑。
///
/// 这是本轮唯一要动采集关键路径的那段代码，而它**没法靠真机录制测**：
/// 真机只能告诉你「录出了个文件」，说不清 15 kHz 是被压了 60 dB 还是根本没压。
/// 所以判据全部落在纯函数上——它同时也是「抗混叠到底有没有做」的唯一证据。
final class AudioResamplerTests: XCTestCase {

    // MARK: - 夹具

    private func sine(
        frames: Int, hz: Double, rate: Double, amplitude: Double = 0.5
    ) -> [Float] {
        (0..<frames).map {
            Float(amplitude * sin(2 * Double.pi * hz * Double($0) / rate))
        }
    }

    /// 稳态区间：去掉头部的启动瞬态与尾部的**渐隐**。
    ///
    /// 尾部渐隐是零相位 FIR 在边界上的固有行为，不是缺陷：输出第 m 个样本要用到
    /// 输入的第 m±64 个样本，而文件末尾之后没有样本，只能按零处理，
    /// 于是最后约 64 个输出样本会逐渐衰减到零。48 kHz 下这约 1.3 ms。
    ///
    /// 断言「直流输入必须原样输出」「同相双声道平均后仍是 0.4」这类**稳态性质**时
    /// 必须把它排除，否则测的就变成了边界行为、而不是滤波器本身。
    private func steady(_ x: [Float], skip: Int = 200, tail: Int = 100) -> ArraySlice<Float> {
        let end = max(skip, x.count - tail)
        return x[skip..<end]
    }

    /// 稳态 RMS，跳过启动瞬态——滤波器左侧是零填充，前 `halfWidth` 个输出本来就不代表稳态。
    private func steadyRMS(_ x: [Float], skip: Int = 500, take: Int = 20000) -> Double {
        let window = x.dropFirst(skip).prefix(take)
        guard !window.isEmpty else { return 0 }
        return (window.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(window.count)).squareRoot()
    }

    /// 用正向过零点数估频（对单音足够准，且不依赖 FFT）
    private func estimateFrequency(_ x: [Float], rate: Double) -> Double {
        guard x.count > 2 else { return 0 }
        var crossings = 0
        for i in 1..<x.count where x[i - 1] <= 0 && x[i] > 0 { crossings += 1 }
        let seconds = Double(x.count) / rate
        return seconds > 0 ? Double(crossings) / seconds : 0
    }

    private func decibels(_ value: Double, relativeTo reference: Double) -> Double {
        20 * log10(max(value, 1e-12) / max(reference, 1e-12))
    }

    // MARK: - B20-01 同采样率：完全透传

    /// 采样率相同时必须**逐样本相等**，一个采样都不许动。
    ///
    /// 这条是「不开省空间开关时行为与改动前一字不差」的最底层保证：管线在恒等情况下
    /// 把数组原样交出去，不经过任何滤波与插值。
    ///
    /// 退化示例：把 `process` 开头的 `if isPassthrough` 删掉，让 1:1 也走一遍
    /// 居中相关——首位样本会被左侧零填充污染，本用例立刻变红。
    func testSameRateIsExactPassthrough() {
        var resampler = AudioResampler(sourceSampleRate: 48000, targetSampleRate: 48000)
        XCTAssertTrue(resampler.isPassthrough)
        XCTAssertEqual(resampler.taps, 0, "同采样率不该装滤波器")

        let input = sine(frames: 1000, hz: 440, rate: 48000)
        XCTAssertEqual(resampler.process(input), input, "必须逐样本相等，不是近似")
        XCTAssertEqual(resampler.flush(), [], "恒等路径没有尾部要排空")
    }

    // MARK: - B20-02 直流增益为 1

    /// 常数输入必须原样输出。
    ///
    /// 它验的是「滤波器直流增益归一化」这一步。少写这一步的症状是**整体音量变了**——
    /// 「开了省空间之后录音变小/变大」是用户会注意到、但很难归因到重采样上的一类问题。
    ///
    /// 退化示例：删掉 `designLowpass` 末尾的归一化循环，本用例变红。
    func testConstantInputKeepsItsLevel() {
        var resampler = AudioResampler(sourceSampleRate: 48000, targetSampleRate: 24000)
        var out = resampler.process([Float](repeating: 0.5, count: 4800))
        out += resampler.flush()

        let window = steady(out)
        XCTAssertFalse(window.isEmpty)
        for (i, v) in window.enumerated() {
            XCTAssertEqual(Double(v), 0.5, accuracy: 1e-4, "稳态第 \(i) 个样本不是 0.5")
        }

        // 边界效应**有界**：只该出现在最后约半个窗宽里。
        // 这条挡的是「把边界处理改坏、渐隐蔓延到整条音频」那种退化。
        XCTAssertEqual(
            Double(out[out.count - 200]), 0.5, accuracy: 1e-4,
            "倒数第 200 个样本仍应处于稳态——渐隐只该发生在最后约 64 个样本内")
    }

    // MARK: - B20-03 音调频率与电平保持

    /// 1 kHz 正弦降到 24 kHz 之后，频率不变、峰值基本不变。
    ///
    /// 退化示例：把 `step` 写成 `dst/src`（方向反了），频率会变成 4 kHz，本用例变红。
    func testToneFrequencyAndLevelSurvive() {
        let rate = 48000.0, target = 24000.0, hz = 1000.0
        var resampler = AudioResampler(sourceSampleRate: rate, targetSampleRate: target)
        var out = resampler.process(sine(frames: 48000, hz: hz, rate: rate))
        out += resampler.flush()

        let steady = Array(out.dropFirst(1000).prefix(20000))
        let peak = Double(steady.map { abs($0) }.max() ?? 0)
        XCTAssertEqual(peak, 0.5, accuracy: 0.03, "1 kHz 在通带里，峰值不该被削")

        let measured = estimateFrequency(steady, rate: target)
        XCTAssertEqual(measured, hz, accuracy: 20, "频率必须保持 1 kHz，实测 \(measured) Hz")
    }

    // MARK: - B20-04 长度

    /// 输出长度 ≈ 输入长度 / 步长，容差 ±2（含排空与块边界取整）。
    ///
    /// 退化示例：把 `flush()` 改成空实现，尾部约半个窗宽不再产出，长度会偏小并越界。
    func testOutputLengthFollowsTheRatio() {
        for n in [4800, 4801, 1000, 12345, 48000] {
            var resampler = AudioResampler(sourceSampleRate: 48000, targetSampleRate: 24000)
            var out = resampler.process(sine(frames: n, hz: 500, rate: 48000))
            out += resampler.flush()

            let expected = Double(n) / 2
            XCTAssertLessThanOrEqual(
                abs(Double(out.count) - expected), 2,
                "n = \(n) 时得到 \(out.count) 个样本，期望约 \(expected)")
        }
    }

    // MARK: - B20-05 流式连续性（本文件最重要的一条）

    /// 分块处理必须与一次性处理**逐样本相等**。
    ///
    /// 真实采集每秒进来约 94 次、每次 512 帧左右。实现若把重采样器当无状态的用
    /// （每次重建相位与滤波器历史），块边界处会周期性出现咔哒声——
    /// 而那在录音回听里听起来像「环境噪音」，很难归因到代码上。
    ///
    /// 退化示例：把 `pending` / `position` / `nextCenter` 在每次 `process` 开头重置，
    /// 本用例立刻变红（分块版本每个块的开头都会重新起振）。
    func testChunkedProcessingMatchesSinglePass() {
        let input = sine(frames: 12345, hz: 700, rate: 48000)

        var once = AudioResampler(sourceSampleRate: 48000, targetSampleRate: 24000)
        var single = once.process(input)
        single += once.flush()

        var chunked = AudioResampler(sourceSampleRate: 48000, targetSampleRate: 24000)
        var piecewise: [Float] = []
        let sizes = [512, 1024, 37, 2048, 1, 300]
        var index = 0
        var sizeIndex = 0
        while index < input.count {
            let n = min(sizes[sizeIndex % sizes.count], input.count - index)
            piecewise += chunked.process(Array(input[index..<(index + n)]))
            index += n
            sizeIndex += 1
        }
        piecewise += chunked.flush()

        XCTAssertEqual(single.count, piecewise.count, "分块不该改变输出长度")
        let common = min(single.count, piecewise.count)
        XCTAssertGreaterThan(common, 6000, "样本太少的话这条断言说明不了什么")
        for i in 0..<common {
            XCTAssertEqual(
                Double(single[i]), Double(piecewise[i]), accuracy: 1e-6,
                "第 \(i) 个样本在分块后变了——说明重采样状态没有跨块保存")
        }
    }

    // MARK: - B20-06 抗混叠（区分「真重采样」与「直接抽样」的那条）

    /// 15 kHz 高于目标奈奎斯特（12 kHz），必须被明显压下去。
    ///
    /// 这条是**「有没有做抗混叠」的唯一直接证据**。不装低通直接隔点取值的话，
    /// 15 kHz 会混叠成 9 kHz 并且**幅度几乎不变**（0 dB 量级），
    /// 听感上是凭空冒出来的金属声，转写引擎收到的是不存在的频率成分。
    ///
    /// 方案文档里 24k 档「99.7% 相似度」是用 ffmpeg 生成的变体测的，
    /// 而 ffmpeg 会做抗混叠——所以那个结论只有在低通真的存在时才搬得过来。
    ///
    /// 退化示例：把 `init` 里 `if dst < src` 的滤波分支改成不装系数（`coefficients = []`），
    /// 本用例变红（衰减从约 −60 dB 掉到约 −1 dB）。
    func testAboveNyquistToneIsRejected() {
        let rate = 48000.0, hz = 15000.0
        var resampler = AudioResampler(sourceSampleRate: rate, targetSampleRate: 24000)
        var out = resampler.process(sine(frames: 48000, hz: hz, rate: rate))
        out += resampler.flush()

        let measured = decibels(steadyRMS(out), relativeTo: 0.5 / 2.0.squareRoot())
        XCTAssertLessThan(
            measured, -40,
            "15 kHz 在目标奈奎斯特之上，必须被压 40 dB 以上，实测 \(measured) dB")
    }

    // MARK: - B20-07 通带保真

    /// 3 kHz 在通带里，不该被动。
    ///
    /// 与上一条互为对照：只有两条一起在，才能区分「低通设计得对」与
    /// 「低通截止点压得极低」（后者会把语音里的高频线索一起削掉，
    /// 转写质量下降却看不出原因）。
    func testPassbandToneIsNotAttenuated() {
        var resampler = AudioResampler(sourceSampleRate: 48000, targetSampleRate: 24000)
        var out = resampler.process(sine(frames: 48000, hz: 3000, rate: 48000))
        out += resampler.flush()

        let measured = decibels(steadyRMS(out), relativeTo: 0.5 / 2.0.squareRoot())
        XCTAssertGreaterThan(measured, -0.5, "3 kHz 在通带里，衰减不该超过 0.5 dB，实测 \(measured) dB")
    }

    // MARK: - B20-08 非整数比

    /// 44.1 kHz → 24 kHz（步长 1.8375，不是整数抽取）。
    ///
    /// 只实现「整数倍抽取」的话，长度与频率都会错。macOS 上 44.1 kHz 的设备并不罕见
    /// （很多 USB 声卡与虚拟声卡默认就是），所以这条不是纸上场景。
    func testNonIntegerRatioResamplesCorrectly() {
        var resampler = AudioResampler(sourceSampleRate: 44100, targetSampleRate: 24000)
        var out = resampler.process(sine(frames: 44100, hz: 1000, rate: 44100))
        out += resampler.flush()

        XCTAssertLessThanOrEqual(abs(Double(out.count) - 24000), 4, "得到 \(out.count) 个样本")
        let measured = estimateFrequency(Array(out.dropFirst(1000).prefix(20000)), rate: 24000)
        XCTAssertEqual(measured, 1000, accuracy: 25, "实测 \(measured) Hz")
    }

    // MARK: - B20-09 低采样率源

    /// 16 kHz → 24 kHz：长度按比例增加，档次不变，且**不加低通**。
    ///
    /// 升采样不需要抗混叠；加了反而把源信号近奈奎斯特的部分（6.4~8 kHz）白削掉。
    /// 注意 `TrackWriteFormat.resolve` 本身不会升采样（它取 min），
    /// 这条验的是「万一有人直接构造，行为也是对的」。
    func testUpsamplingScalesLengthWithoutFiltering() {
        var resampler = AudioResampler(sourceSampleRate: 16000, targetSampleRate: 24000)
        XCTAssertEqual(resampler.taps, 0, "升采样不该装低通")

        var out = resampler.process([Float](repeating: 0.5, count: 16000))
        out += resampler.flush()

        XCTAssertLessThanOrEqual(abs(Double(out.count) - 24000), 4, "得到 \(out.count) 个样本")
        // 线性插值在常数序列上仍是同一个常数，幅度不该变
        let steady = out.dropFirst(10)
        for (i, v) in steady.enumerated() {
            XCTAssertEqual(Double(v), 0.5, accuracy: 1e-5, "第 \(i + 10) 个样本被改动了")
        }
    }

    // MARK: - B20-10 静音

    /// 全零输入必须全零输出。
    ///
    /// 这条挡的是「滤波器带直流偏移」：输出被抬出一个极小常数的话，
    /// `RecordingSanity.isAllZero`（判 `frames > 0 && peakAmplitude == 0`）
    /// 会认为「这一轨录到东西了」，于是「系统音频权限没生效」被静默掩盖——
    /// 那正是本项目最看重的那类「数字看着对、含义全错」。
    func testSilenceStaysSilent() {
        var resampler = AudioResampler(sourceSampleRate: 48000, targetSampleRate: 24000)
        var out = resampler.process([Float](repeating: 0, count: 4800))
        out += resampler.flush()

        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { $0 == 0 }, "全零输入不该产生任何非零输出")
    }

    // MARK: - B20-11 非有限值

    /// 混进来的 NaN / ±∞ 不许扩散。
    ///
    /// FIR 会把**一个**输入样本摊到整个窗宽上，129 抽头意味着一个 NaN 能污染
    /// 129 个输出样本，还会进历史往后每块再扩散。所以入口就按静音拦掉。
    ///
    /// **覆盖范围要说清楚**：清洗只在**真的做了变换**的路径上（`dst != src`）。
    /// `isPassthrough` 与 `TrackSamplePipeline` 的 `isIdentity` 短路都在清洗之前返回，
    /// 32 位浮点路径**原样保留** NaN —— 那是改动前就有的行为，本轮刻意不动它：
    /// 本轮的硬承诺是「不开开关时输出与改动前逐字节一致」，顺手把 NaN 也清掉
    /// 会让这条承诺失效。恒等路径的行为另由 `testPassthroughKeepsNonFiniteSamplesAsIs` 钉住。
    ///
    /// 退化示例：删掉 `process` 里的 `allSatisfy { $0.isFinite }` 清洗，
    /// 本用例变红（输出里会出现 NaN，且持续约 129 个样本）。
    func testNonFiniteSamplesAreContained() {
        var input = sine(frames: 4800, hz: 500, rate: 48000)
        input[2400] = .nan
        input[2401] = .infinity

        var resampler = AudioResampler(sourceSampleRate: 48000, targetSampleRate: 24000)
        var out = resampler.process(input)
        out += resampler.flush()

        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { $0.isFinite }, "输出里不该有 NaN / ∞ 残留")
        // 坏样本之外的内容仍应正常，而不是被整体清零
        XCTAssertGreaterThan(steadyRMS(out, skip: 100, take: 100), 0.1, "除坏样本外的内容不该被一起抹掉")
    }

    /// 恒等（passthrough）路径**原样保留** NaN——这是既有契约，不是疏漏。
    ///
    /// 为什么不清洗：本轮的硬承诺是「开关关闭时，录出来的文件与改动前逐字节一致」。
    /// 顺手把 NaN 清零会让这条承诺失效，而且是在用户没要求的情况下改动了既有路径的行为。
    /// 代价是 32 位浮点文件里可能有 NaN（16 位路径另有入口清洗，
    /// 见 `WAVWriter.quantizeToInt16` 的约定）。
    ///
    /// 写这条的目的，是把**隐式行为变成显式契约**：将来谁为了「统一清洗」顺手改了这里，
    /// 会立刻变红，从而逼他先想清楚那个逐字节承诺怎么办。
    func testPassthroughKeepsNonFiniteSamplesAsIs() {
        var input = sine(frames: 100, hz: 500, rate: 48000)
        input[50] = .nan

        var resampler = AudioResampler(sourceSampleRate: 48000, targetSampleRate: 48000)
        XCTAssertTrue(resampler.isPassthrough, "同采样率必须判成透传")

        let out = resampler.process(input)
        XCTAssertEqual(out.count, input.count, "透传不该改变长度")
        XCTAssertEqual(out[0], input[0])
        XCTAssertTrue(out[50].isNaN,
                      "透传路径刻意不改动采样值（含 NaN）——保住「不开开关时逐字节不变」")
    }

    // MARK: - 滤波器设计本身

    /// 系数必须对称、直流增益为 1、且为奇数长度。
    ///
    /// 对称性是「零相位」的前提（否则会引入整段延迟，两条轨只有一条被重采样时
    /// 就会出现相对时间偏移）；直流增益为 1 是音量不变的前提。
    func testLowpassDesignIsSymmetricAndUnityGain() {
        let h = AudioResampler.designLowpass(cutoffNormalized: 0.21, taps: 129)
        XCTAssertEqual(h.count, 129)
        XCTAssertEqual(h.count % 2, 1, "对称窗需要唯一中心抽头")

        for i in 0..<h.count {
            XCTAssertEqual(Double(h[i]), Double(h[h.count - 1 - i]), accuracy: 1e-7,
                           "第 \(i) 个系数与镜像位置不等——窗函数不对称")
        }
        let sum = h.reduce(0.0) { $0 + Double($1) }
        XCTAssertEqual(sum, 1.0, accuracy: 1e-6, "直流增益必须归一化为 1")
    }

    /// 偶数抽头会被抬成奇数，而不是原样使用。
    func testEvenTapCountIsRoundedUpToOdd() {
        XCTAssertEqual(AudioResampler.designLowpass(cutoffNormalized: 0.2, taps: 128).count, 129)
        XCTAssertEqual(AudioResampler.designLowpass(cutoffNormalized: 0.2, taps: 129).count, 129)
    }

    // MARK: - 降混（B20-12 ~ B20-16）

    /// 同相双声道取平均 → 幅度**不衰减**。
    ///
    /// 退化示例：把 `sum * scale` 写成 `sum`，输出变成 0.6，本用例变红。
    func testAverageDownmixKeepsLevelForCorrelatedChannels() {
        let interleaved: [Float] = [0.3, 0.3, -0.2, -0.2, 0.1, 0.1]
        let mono = MonoDownmix.mix(interleaved, channels: 2, strategy: .average)
        XCTAssertEqual(mono.count, 3)
        XCTAssertEqual(Double(mono[0]), 0.3, accuracy: 1e-6)
        XCTAssertEqual(Double(mono[1]), -0.2, accuracy: 1e-6)
        XCTAssertEqual(Double(mono[2]), 0.1, accuracy: 1e-6)
    }

    /// 反相双声道取平均 → 互相抵消，输出≈0。
    ///
    /// **这条钉的是「行为」，不是「保证它不发生」。** 相位抵消是方案文档第六节点名
    /// 登记的已知风险，而本次对照样本里没有「对方在放立体声音乐」这类真实场景，
    /// 所以没法判断它实际会不会发生。用例把它如实记录下来，
    /// 将来真遇到时这里会是一条已经写好的、能立刻复现的证据。
    func testAverageDownmixCancelsAntiPhaseChannels() {
        let interleaved: [Float] = [0.3, -0.3, 0.25, -0.25]
        let mono = MonoDownmix.mix(interleaved, channels: 2, strategy: .average)
        XCTAssertEqual(mono.count, 2)
        XCTAssertEqual(Double(mono[0]), 0.0, accuracy: 1e-6, "反相成分会被平均掉——这是登记在案的已知风险")
        XCTAssertEqual(Double(mono[1]), 0.0, accuracy: 1e-6)
    }

    /// 备选策略「只取第 1 声道」确实能躲开相位抵消。
    ///
    /// 这条同时是「备选策略真的存在、不是文档里的一句话」的证明。
    /// 退化示例：把 `.firstChannel` 分支写成与 `.average` 相同，本用例变红。
    func testFirstChannelDownmixAvoidsCancellation() {
        let interleaved: [Float] = [0.3, -0.3, 0.25, -0.25]
        let mono = MonoDownmix.mix(interleaved, channels: 2, strategy: .firstChannel)
        XCTAssertEqual(Double(mono[0]), 0.3, accuracy: 1e-6)
        XCTAssertEqual(Double(mono[1]), 0.25, accuracy: 1e-6)
    }

    /// 单声道输入原样返回。
    ///
    /// 判据锁的是「单声道不做无谓变换」这个契约：去掉
    /// `guard channels > 1 else { return interleaved }` 让单声道也走一遍 `× 1/1`，
    /// 数值上仍等价（所以这条抓不到那种退化）；但换成按声道数铺开、或改长度，它会红。
    ///
    /// 这里**不写**「输入数组本身没被改动」那种断言：`[Float]` 是值类型、`mix` 按值收参，
    /// 结构上就不可能改动调用方的数组——那种断言永远为真，没有任何牙齿。
    func testMonoInputPassesThroughUnchanged() {
        let interleaved: [Float] = [0.1, -0.2, 0.3]
        let mono = MonoDownmix.mix(interleaved, channels: 1, strategy: .average)
        XCTAssertEqual(mono, interleaved, "单声道输入必须逐样本原样返回")
        XCTAssertEqual(mono.count, interleaved.count, "长度不能变")
    }

    /// 多于两个声道时按**全部**声道平均，不是只取前两个。
    ///
    /// 退化示例：把循环上界写成 `min(channels, 2)`，本用例变红。
    func testMultiChannelDownmixAveragesEveryChannel() {
        // 4 声道：(0.4, 0.4, 0.4, 0.4) → 平均仍是 0.4
        let all: [Float] = [0.4, 0.4, 0.4, 0.4, -0.8, -0.8, -0.8, -0.8]
        let mono = MonoDownmix.mix(all, channels: 4, strategy: .average)
        XCTAssertEqual(mono.count, 2)
        XCTAssertEqual(Double(mono[0]), 0.4, accuracy: 1e-6)
        XCTAssertEqual(Double(mono[1]), -0.8, accuracy: 1e-6)

        // 只有一个声道有信号时，平均会把幅度按声道数摊薄——这是「平均」的定义，
        // 不是 bug。写出来是为了让这个语义有据可查。
        let oneLoud: [Float] = [0.8, 0, 0, 0]
        let diluted = MonoDownmix.mix(oneLoud, channels: 4, strategy: .average)
        XCTAssertEqual(Double(diluted[0]), 0.2, accuracy: 1e-6)
    }
}
