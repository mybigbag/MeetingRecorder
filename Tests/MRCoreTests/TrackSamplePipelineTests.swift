import XCTest
@testable import MRCore

/// 写前变换管线：降混 → 重采样。
///
/// 这一层是 `TrackRecorder.handle()` 里唯一与格式有关的东西——所以它被整段抽出来，
/// 让「采集关键路径」上剩下的代码只是「加锁 → 交给管线 → 交给 writer」。
final class TrackSamplePipelineTests: XCTestCase {

    private func stereoInterleaved(frames: Int, left: Float, right: Float) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            out[i * 2] = left
            out[i * 2 + 1] = right
        }
        return out
    }

    /// 稳态区间：去掉头部启动瞬态与尾部渐隐。
    ///
    /// 尾部渐隐来自零相位滤波器在边界上的固有假设（文件末尾之后没有样本，只能按零处理），
    /// 48 kHz 下约 1.3 ms。断言稳态值时必须排除它，否则测的是边界行为而不是管线本身。
    private func steadyRegion(_ x: [Float], skip: Int = 200, tail: Int = 100) -> ArraySlice<Float> {
        let end = max(skip, x.count - tail)
        return x[skip..<end]
    }

    // MARK: - B20-23 无变换时逐样本不动

    /// 源格式 == 写入格式时，输出必须与输入**完全一致**。
    ///
    /// 这是「不勾开关的用户，录出来的文件与改动前一字不差」在管线层的落点。
    ///
    /// 退化示例：去掉 `if isIdentity { return interleaved }` 的短路，
    /// 让 1:1 也走一遍重采样——本用例变红，且多出来的滤波还会改动历史录音的采样值。
    func testIdentityPipelinePassesSamplesUntouched() {
        var pipeline = TrackSamplePipeline(
            sourceSampleRate: 48000,
            sourceChannels: 2,
            writeFormat: TrackWriteFormat(sampleRate: 48000, channels: 2))
        XCTAssertTrue(pipeline.isIdentity)

        let input: [Float] = [0.1, -0.2, 0.3, -0.4, 0.5, -0.6]
        XCTAssertEqual(pipeline.process(input), input, "必须逐样本相等")
        XCTAssertEqual(pipeline.flush(), [], "恒等管线没有尾部")
    }

    /// 单声道源 + 同采样率也是恒等（麦克风轨在开关关闭时的形态）。
    ///
    /// ⚠️ 这条**不能**当作「恒等逐样本不变」的证据：单声道源本来就有一条
    /// `sourceChannels == 1` 的透传分支，再经 1:1 的 passthrough 也返回原值，
    /// 所以即使把 `if isIdentity { return interleaved }` 整段删掉，它照样绿
    /// （交叉审查用变异验证坐实过）。真正有牙齿的是**立体声**那条
    /// `testIdentityPipelinePassesSamplesUntouched`——删掉短路后它的值会变成
    /// `[-0.05, …]`（FIR 把交替的两个值平均掉了）。
    ///
    /// 这条锁的是 `isIdentity` 的**判定**：单声道源 + 同采样率必须被判成恒等。
    func testMonoIdentityPipelinePassesSamplesUntouched() {
        var pipeline = TrackSamplePipeline(
            sourceSampleRate: 48000,
            sourceChannels: 1,
            writeFormat: TrackWriteFormat(sampleRate: 48000, channels: 1))
        XCTAssertTrue(pipeline.isIdentity)

        let input: [Float] = [0.1, -0.2, 0.3]
        XCTAssertEqual(pipeline.process(input), input)
    }

    // MARK: - B20-24 长度

    /// 立体声 48 kHz → 单声道 24 kHz：输出样本数 ≈ 输入**帧数** / 2。
    ///
    /// 注意分母是帧数不是采样数——立体声的交错数组长度是帧数的两倍，
    /// 把这两个混起来会让体积与时长都算错一倍。
    func testStereoToMono24kHalvesTheFrameCount() {
        let frames = 9600
        var pipeline = TrackSamplePipeline(
            sourceSampleRate: 48000,
            sourceChannels: 2,
            writeFormat: TrackWriteFormat(sampleRate: 24000, channels: 1))
        XCTAssertFalse(pipeline.isIdentity)

        var out = pipeline.process(stereoInterleaved(frames: frames, left: 0.25, right: 0.25))
        out += pipeline.flush()

        XCTAssertLessThanOrEqual(
            abs(Double(out.count) - Double(frames) / 2), 2,
            "得到 \(out.count) 个样本，期望约 \(frames / 2)")
    }

    // MARK: - B20-25 交错次序与降混值

    /// 左右声道同值 → 单声道输出每个样本都是那个值（不衰减）。
    ///
    /// 注意这条验的是**降混值**，不是通道次序：`.average` 下 L/R 可交换，
    /// 同值输入对次序完全不敏感。真正能区分「降混到底做没做」的是
    /// `testDownmixHalvesASingleSidedSignal`。
    func testEqualChannelsProduceTheSameLevel() {
        var pipeline = TrackSamplePipeline(
            sourceSampleRate: 48000,
            sourceChannels: 2,
            writeFormat: TrackWriteFormat(sampleRate: 24000, channels: 1))

        var out = pipeline.process(stereoInterleaved(frames: 4800, left: 0.4, right: 0.4))
        out += pipeline.flush()

        let region = steadyRegion(out)
        XCTAssertFalse(region.isEmpty)
        for v in region {
            XCTAssertEqual(Double(v), 0.4, accuracy: 1e-4, "同相双声道平均后仍是 0.4")
        }
    }

    /// 左右不同 → 输出是两者平均。
    ///
    /// ⚠️ 这条**不能**用来验「降混有没有做」，交叉审查已用变异验证坐实：
    /// 把管线里的降混整段删掉（`let mono = interleaved`），它**照样绿**——
    /// 因为 48 kHz → 24 kHz 的抗混叠 FIR 本身就会把交错的 0.6 / 0.2 低通成 0.4，
    /// 恰好等于期望值。能抓住「降混没做」的是长度断言（输出帧数会翻倍）
    /// 与 `testDownmixHalvesASingleSidedSignal`。
    ///
    /// 它也**不能**验通道次序——`.average` 是可交换的，L/R 对调结果不变。
    func testDifferentChannelsAreAveraged() {
        // **显式**传 `.average`（不靠默认值）：本用例测的就是 average 本身的行为。
        // 生产默认值已改成 `firstChannel`（真机实测：average 在反相内容上会整轨
        // 抵消成静音），若这里跟着默认值走，用例会变成在测 firstChannel ——
        // 名字与断言全对不上，绿了也证明不了任何事。
        var pipeline = TrackSamplePipeline(
            sourceSampleRate: 48000,
            sourceChannels: 2,
            writeFormat: TrackWriteFormat(sampleRate: 24000, channels: 1),
            downmixStrategy: .average)

        // L = 0.6, R = 0.2 → 平均 0.4
        var out = pipeline.process(stereoInterleaved(frames: 4800, left: 0.6, right: 0.2))
        out += pipeline.flush()

        let region = steadyRegion(out)
        let mean = region.reduce(0.0) { $0 + Double($1) } / Double(region.count)
        XCTAssertEqual(mean, 0.4, accuracy: 1e-4)
    }

    /// **能区分「降混」与「不降混」**的一条：左声道有信号、右声道全静音。
    ///
    /// 上面两条用的是常量输入，而 FIR 会把交错的 0.6/0.2 低通成 0.4 —— 所以它们
    /// 抓不到「降混被删掉」。换成一侧静音就区分得开：
    /// - 正确：输出 = `(L + 0) / 2` 的低通，峰值是 L 的一半（0.4 → 0.2）；
    /// - 跳过降混：交错的 `[L, 0, L, 0, …]` 被当成单声道送进重采样器，
    ///   输出帧数直接翻倍、峰值也不再是 L 的一半。
    ///
    /// 退化示例：管线里把 `MonoDownmix.mix(...)` 换成 `interleaved`，本用例两条断言同时红。
    func testDownmixHalvesASingleSidedSignal() {
        let frames = 4800
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            // 1 kHz 正弦放在左声道，右声道留零
            interleaved[i * 2] = 0.4 * Float(sin(2 * Double.pi * 1000 * Double(i) / 48000))
        }

        // **显式**传 `.average`（不靠默认值）：本用例测的就是 average 本身的行为。
        // 生产默认值已改成 `firstChannel`（真机实测：average 在反相内容上会整轨
        // 抵消成静音），若这里跟着默认值走，用例会变成在测 firstChannel ——
        // 名字与断言全对不上，绿了也证明不了任何事。
        var pipeline = TrackSamplePipeline(
            sourceSampleRate: 48000,
            sourceChannels: 2,
            writeFormat: TrackWriteFormat(sampleRate: 24000, channels: 1),
            downmixStrategy: .average)
        var out = pipeline.process(interleaved)
        out += pipeline.flush()

        // ① 长度：4800 源帧 → 2400 输出帧（± 几个样本的边界余量）。
        //    降混没做的话这里会是 4800 上下——一倍的差距。
        XCTAssertEqual(Double(out.count), Double(frames) / 2, accuracy: 6,
                       "输出帧数应是源帧数的一半；不等于说明降混没生效")

        // ② 峰值：L 幅度 0.4，两声道平均后是 0.2。
        let peak = out.map { abs(Double($0)) }.max() ?? 0
        XCTAssertEqual(peak, 0.2, accuracy: 0.02,
                       "左右平均后峰值应是 L 的一半（0.4 → 0.2）")
    }

    // MARK: - B20-26 分块等价

    /// 按真实回调的粒度分块送入，结果必须与一次性送入逐样本相等。
    ///
    /// 这条把「管线是有状态的」这件事钉在**管线这一层**（重采样核那一层也有一条）。
    /// 两层都测不是重复：管线多了一步降混，而「降混是否每次重置状态」是这条路径
    /// 独有的退化方式。
    func testChunkedPipelineMatchesSinglePass() {
        let frames = 20000
        let input = stereoInterleaved(frames: frames, left: 0.3, right: 0.1)

        var once = TrackSamplePipeline(
            sourceSampleRate: 48000, sourceChannels: 2,
            writeFormat: TrackWriteFormat(sampleRate: 24000, channels: 1))
        var single = once.process(input)
        single += once.flush()

        var chunked = TrackSamplePipeline(
            sourceSampleRate: 48000, sourceChannels: 2,
            writeFormat: TrackWriteFormat(sampleRate: 24000, channels: 1))
        var piecewise: [Float] = []
        var index = 0
        let chunkFrames = 512
        while index < frames {
            let n = min(chunkFrames, frames - index)
            let slice = Array(input[(index * 2)..<((index + n) * 2)])
            piecewise += chunked.process(slice)
            index += n
        }
        piecewise += chunked.flush()

        XCTAssertEqual(single.count, piecewise.count)
        let common = min(single.count, piecewise.count)
        XCTAssertGreaterThan(common, 9000)
        for i in 0..<common {
            XCTAssertEqual(
                Double(single[i]), Double(piecewise[i]), accuracy: 1e-6,
                "第 \(i) 个样本在分块后变了")
        }
    }

    // MARK: - B20-27 排空幂等

    /// `flush()` 重复调用不该产出第二份尾部。
    ///
    /// 退化示例：把 `drained` 标志删掉，第二次 `flush()` 又会补一段零进去，
    /// 文件尾部凭空多出约半个窗宽的静音，且 `framesWritten` 与采集帧数不再自洽。
    func testFlushIsIdempotent() {
        var pipeline = TrackSamplePipeline(
            sourceSampleRate: 48000, sourceChannels: 2,
            writeFormat: TrackWriteFormat(sampleRate: 24000, channels: 1))

        _ = pipeline.process(stereoInterleaved(frames: 2400, left: 0.2, right: 0.2))
        let first = pipeline.flush()
        XCTAssertFalse(first.isEmpty, "第一次排空应当有尾部（否则这条用例说明不了什么）")

        XCTAssertEqual(pipeline.flush(), [], "第二次排空必须为空")
        XCTAssertEqual(pipeline.process([0.1, 0.1]), [], "排空之后再送数据也不该再产出")
    }

    // MARK: - B20-28 量化不在管线里

    /// 管线的产物仍是**未经量化**的浮点。
    ///
    /// pcm16 的量化只允许发生在 `WAVWriter` 一处。两处都做一次的话，
    /// `TrackRecorder.effectiveSample` 的峰值判据（它假设「写入后生效的值」只被影响一次）
    /// 会失准，而且误差会累积。
    ///
    /// 判据用「与 pcm16 网格的距离」：若管线量化过，输出必然落在
    /// `n / 32767` 这些点上，与真值会差约 1.1e-5，超出 1e-6 的容差。
    ///
    /// 退化示例：在 `process` 里对结果套一次 `WAVWriter.quantizeToInt16`，
    /// 本用例变红。
    func testPipelineDoesNotQuantise() {
        // 这个值刻意选在 pcm16 两个网格点的正中间附近
        let exact: Float = 0.1234567
        let gridPoint = Float(WAVWriter.quantizeToInt16(exact)) / 32768.0
        XCTAssertGreaterThan(abs(Double(exact) - Double(gridPoint)), 1e-5,
                             "夹具本身要能区分「量化过」与「没量化」")

        var pipeline = TrackSamplePipeline(
            sourceSampleRate: 48000, sourceChannels: 2,
            writeFormat: TrackWriteFormat(sampleRate: 24000, channels: 1))
        var out = pipeline.process(stereoInterleaved(frames: 4800, left: exact, right: exact))
        out += pipeline.flush()

        let region = steadyRegion(out)
        XCTAssertFalse(region.isEmpty)
        for v in region {
            XCTAssertEqual(Double(v), Double(exact), accuracy: 1e-6,
                           "管线不该做量化——量化只属于 WAVWriter")
        }
    }

    // MARK: - 单声道源只降采样

    /// 单声道源在开关打开时只降采样，不走降混。
    func testMonoSourceOnlyGetsResampled() {
        var pipeline = TrackSamplePipeline(
            sourceSampleRate: 48000, sourceChannels: 1,
            writeFormat: TrackWriteFormat(sampleRate: 24000, channels: 1))
        XCTAssertFalse(pipeline.isIdentity)

        var out = pipeline.process([Float](repeating: 0.35, count: 4800))
        out += pipeline.flush()

        XCTAssertLessThanOrEqual(abs(Double(out.count) - 2400), 2)
        for v in steadyRegion(out) {
            XCTAssertEqual(Double(v), 0.35, accuracy: 1e-4)
        }
    }
}
