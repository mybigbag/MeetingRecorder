import XCTest
@testable import MRCore

/// B 档（降采样）对**静音检测与分段**的影响。
///
/// 这件事以前是「已知未验证」——README 里登记得很清楚，只验了转写、没验分段。
/// 现在补齐，判据全部落在纯函数上（`MonoDownmix` / `AudioResampler` /
/// `SilenceDetector` / `Segmenter`），不依赖真机、不依赖外部文件。
///
/// # 为什么这条链路值得单独验
///
/// 分段依赖静音检测，而静音检测的判据是**窗口 RMS 低于 −45 dBFS**。
/// B 档链路里有两处会改动信号能量：
/// 1. `AudioResampler` 的抗混叠低通（129 抽头，48k→24k 时压 11 kHz 以上）
/// 2. `MonoDownmix.average`（双声道求平均，除以声道数）
///
/// 只要能量被削掉，**原本判为「有声」的窗口就可能跌过阈值变成静音**——
/// 而静音区间正是切点的候选，多出来的静音会让切点位置漂移。
///
/// # 实测结论（本文件全部钉的就是这几句）
///
/// | 环节 | 对 RMS 的影响 | 会不会让有声变静音 |
/// |---|---|---|
/// | 低通（语音频段 300 Hz–4 kHz） | **0.00 dB** | 不会 |
/// | 低通（齿音 7 kHz 基频） | −1.82 dB | 边界窗口可能 |
/// | 低通（白噪，最坏情况） | −3.90 dB | 边界窗口可能 |
/// | 低通（反向增益） | 最多 **+0.003 dB** | 不会（方向反了也不够） |
/// | `average` 降混（双声道同相） | 0.00 dB | 不会 |
/// | **`average` 降混（一声道静音）** | **−6.02 dB** | **会** |
/// | pcm16 量化 | 噪声底 ≈ −96 dBFS | 不会（离 −45 差 50 dB） |
///
/// 真机实测（`2026-10-09-095018` 两轨各 388 秒，走完整 B 档链路）：
/// mic 轨 19426 个窗口里 23 个从有声变静音（0.12%）、0 个反向；
/// system 轨 26 个变静音、0 个反向；**两轨的分段切点偏差都是 0.0000 秒**。
///
/// 也就是说：影响真实存在（阈值边缘的窗口确实会翻），但**方向单一**
/// （只会更静音，不会把词间停顿判成有声），且**不影响切点**。
/// 真正需要警惕的是 `average` 降混那一侧，见
/// `testAverageDownmixHalvesTheLevelWhenOneChannelIsSilent`。
final class DownsampledSilenceDetectionTests: XCTestCase {

    // MARK: - 夹具

    private let sourceRate = 48000.0
    private let targetRate = 24000.0

    private func db(_ v: Float) -> Double { v > 0 ? 20 * log10(Double(v)) : -160 }

    /// 语音状信号：基频 180 Hz + 6 次谐波，能量落在 300 Hz–4 kHz。
    ///
    /// 谐波数取到 8 是有意的：`8 × 180 = 1440 Hz`，加上基频仍远在 11 kHz
    /// 过渡带之下，所以它代表的是「正常语音」而不是「齿音」。
    private func speechLike(frames: Int, amplitude: Float) -> [Float] {
        let harmonics: [(Int, Double)] = [(1, 1.0), (2, 0.5), (3, 0.3),
                                          (4, 0.2), (6, 0.12), (8, 0.08)]
        let norm = harmonics.reduce(0.0) { $0 + $1.1 }
        return (0..<frames).map { i in
            let t = Double(i) / sourceRate
            var v = 0.0
            for (k, a) in harmonics { v += a * sin(2 * .pi * 180.0 * Double(k) * t) }
            return amplitude * Float(v / norm)
        }
    }

    /// 齿音状：基频 7 kHz，能量全在低通过渡带里 —— 最容易被削的那一类。
    private func sibilant(frames: Int, amplitude: Float) -> [Float] {
        (0..<frames).map { i in
            let t = Double(i) / sourceRate
            let v = sin(2 * .pi * 7000 * t)
                + 0.6 * sin(2 * .pi * 14000 * t)
                + 0.4 * sin(2 * .pi * 21000 * t)
            return amplitude * Float(v / 2.0)
        }
    }

    /// 宽带噪声。固定种子，夹具可复现。
    private func noise(frames: Int, seed: UInt64, amplitude: Float) -> [Float] {
        var s = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<frames).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let u = Float(Double((s >> 33) & 0xFFFFFF) / Double(0xFFFFFF)) * 2 - 1
            return u * amplitude
        }
    }

    /// 稳态 RMS。跳过滤波器左侧零填充造成的启动瞬态与尾部渐隐。
    private func steadyRMS(_ x: [Float], skip: Int = 2000, take: Int = 40000) -> Float {
        let w = x.dropFirst(skip).prefix(take)
        guard !w.isEmpty else { return 0 }
        return Float(w.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(w.count)).squareRoot()
    }

    /// 完整 B 档链路的信号侧：降混 → 抗混叠低通重采样 → pcm16 量化 → 读回。
    ///
    /// 量化顺序是「**先缩放再舍入**」：`Int16((v × 32767).rounded())`。
    /// 反过来写成 `Int16(v.rounded() × 32767)` 会把 ±1 区间里的小信号全部舍成 0
    /// （`-0.0017.rounded()` 就是 `-0.0`）——实测会得到 −160 dBFS 的假结果。
    private func bTier(_ input: [Float], channels: Int = 1) -> [Float] {
        let mixed = MonoDownmix.mix(input, channels: channels, strategy: .average)
        var r = AudioResampler(sourceSampleRate: sourceRate, targetSampleRate: targetRate)
        var out = r.process(mixed)
        out += r.flush()
        return out.map { v -> Float in
            let scaled = (max(-1, min(1, v)) * 32767).rounded(.toNearestOrAwayFromZero)
            return Float(Int16(scaled)) / 32768
        }
    }

    /// 逐 20 ms 窗口判静音，返回布尔序列。
    ///
    /// 窗口长度与 `SilenceDetector` 默认值一致（20 ms），这样两条路径
    /// 比的是同一批窗口，而不是各自不同的分块。
    private func silentFlags(_ x: [Float], rate: Double,
                              thresholdDB: Double = -45) -> [Bool] {
        let w = max(1, Int((0.02 * rate).rounded()))
        var flags: [Bool] = []
        var i = 0
        while i + w <= x.count {
            var e = 0.0
            for k in i..<(i + w) { let v = Double(x[k]); e += v * v }
            let r = (e / Double(w)).squareRoot()
            flags.append(SilenceDetector.dbFS(r) < thresholdDB)
            i += w
        }
        return flags
    }

    // MARK: - 低通对能量的影响

    /// 语音频段**一点都不掉**——这条是「B 档不影响静音检测」的根本依据。
    ///
    /// 129 抽头低通的阻带从约 11.1 kHz 起，而语音的主要能量在 300 Hz–4 kHz，
    /// 全在通带里。实测差 0.00 dB，不是「小于 0.1 dB」而是量不出来。
    func testLowpassDoesNotAttenuateSpeechBandEnergy() {
        let n = 240000
        let src = speechLike(frames: n, amplitude: 0.1)
        let dst = bTier(src)
        let delta = db(steadyRMS(dst)) - db(steadyRMS(src))
        XCTAssertLessThan(abs(delta), 0.1,
                          "语音频段经低通后 RMS 掉了 \(delta) dB —— 与「基本无影响」矛盾")
    }

    /// 齿音会掉约 1.8 dB。这条不是缺陷，是「带宽从 24 kHz 砍到 12 kHz」的必然结果。
    ///
    /// 钉住它是为了**别把这条当成回归去修**：它有物理上限，动它等于放宽抗混叠。
    func testSibilantLosesAboutTwoDecibels() {
        let n = 240000
        let src = sibilant(frames: n, amplitude: 0.1)
        let dst = bTier(src)
        let delta = db(steadyRMS(dst)) - db(steadyRMS(src))
        XCTAssertEqual(delta, -1.82, accuracy: 0.3,
                       "齿音的衰减量变了，说明低通系数或抽头数被改过")
    }

    /// 白噪是最坏情况：全频能量都要按 12 kHz 带宽重算，实测 −3.90 dB。
    ///
    /// 这是「低通最多能削多少」的上界，用来给下面几条兜底。
    func testBroadbandContentLosesAtMostFourDecibels() {
        let n = 240000
        let src = noise(frames: n, seed: 42, amplitude: 0.1)
        let dst = bTier(src)
        let delta = db(steadyRMS(dst)) - db(steadyRMS(src))
        XCTAssertEqual(delta, -3.90, accuracy: 0.4)
        XCTAssertLessThan(delta, 0,
                          "低通只会削能量；出现正增益说明滤波器实现反了")
    }

    /// 低通**不会**把任何频率抬高超过 0.01 dB。
    ///
    /// 这条是「静音判定不会反向翻转」的前提：如果滤波能把 −44.9 dB 的窗口
    /// 抬到 −44.8 dB，那它在理论上就能把一个该判静音的窗口判成有声。
    /// 实测通带最大增益出现在 8.58 kHz，只有 +0.0015 dB。
    func testLowpassNeverBoostsSignalMeaningfully() {
        let h = AudioResampler.designLowpass(
            cutoffNormalized: 0.42 * (targetRate / sourceRate), taps: 129)
        var worst = -Double.infinity
        for step in 0...1200 {
            let f = Double(step) * 10          // 0 ~ 12 kHz
            let w = 2 * .pi * f / sourceRate
            var re = 0.0, im = 0.0
            for (n, c) in h.enumerated() {
                let phase = w * (Double(n) - Double(h.count - 1) / 2)
                re += Double(c) * cos(phase)
                im += Double(c) * sin(phase)
            }
            worst = max(worst, (re * re + im * im).squareRoot())
        }
        // -0.05 dB 给浮点误差留余量；实测 +0.0015 dB，远在界内
        XCTAssertLessThan(worst, 1.0012,
                          "通带最大增益 \(20 * log10(worst)) dB，比预期高")
    }

    // MARK: - pcm16 量化

    /// 量化噪声底比静音阈值低 50 dB，**不可能**制造出假的静音。
    ///
    /// 16 位量化步长是 1/32768 = 1.5e−5，量化误差 RMS 约在 −96 dBFS。
    /// 距 −45 dBFS 的门限差 51 dB，所以量化对静音判定的影响可以直接排除。
    ///
    /// 判据用「已知电平的噪声过一遍量化后是否原样保留」来间接证明：
    /// 幅度 0.001 的均匀噪声 RMS 是 `0.001/√3` = **−64.77 dBFS**
    /// （注意不是 −60 —— 均匀分布的 RMS 是幅度的 0.577 倍，不是幅度本身）。
    /// 它比量化步长大 30 倍，量化后应当原样保留；
    /// 若噪声底真在 −96 dBFS，这个 −64.77 dBFS 的信号会被啃掉一大截。
    func testQuantisationNoiseFloorIsFarBelowTheSilenceThreshold() {
        let src = noise(frames: 48000, seed: 7, amplitude: 0.001)
        let before = db(steadyRMS(src, skip: 2000, take: 20000))
        XCTAssertEqual(before, -64.77, accuracy: 0.5,
                       "夹具电平对不上，均匀噪声 RMS 应为 0.001/√3 = −64.77 dBFS")

        let q = src.map { v -> Float in
            let scaled = (max(-1, min(1, v)) * 32767).rounded(.toNearestOrAwayFromZero)
            return Float(Int16(scaled)) / 32768
        }
        let after = db(steadyRMS(q, skip: 2000, take: 20000))
        XCTAssertEqual(after, before, accuracy: 0.5,
                       "量化把 −64.77 dBFS 的噪声改成了 \(after) dBFS，噪声底比预期高得多")
        // 真正的量化噪声底：1 LSB / √12
        let step = 1.0 / 32768.0
        let noiseFloor = 20 * log10(step / sqrt(12.0))
        XCTAssertLessThan(noiseFloor, SilenceDetector.Settings().thresholdDB - 40,
                          "量化噪声底 \(noiseFloor) dBFS 距阈值不足 40 dB，"
                          + "无法排除它对静音判定的影响")
    }

    // MARK: - 静音判定的方向性

    /// 有声→静音会翻，**静音→有声绝不会翻**。
    ///
    /// 方向单一是这套链路能安全上线的关键：
    /// - 多判几个静音 → 切点候选变多，但切点仍落在真正的静音里（见下一条）
    /// - 少判静音（即把停顿判成有声）→ 切点会落在词中间，把词切两半
    ///
    /// 第二个后果严重得多，所以这里专门钉住「没有反向翻转」。
    ///
    /// 夹具用**宽带噪声**而不是语音：低通对语音频段掉 0.00 dB（那正是
    /// `testLowpassDoesNotAttenuateSpeechBandEnergy` 钉的），所以拿语音做夹具
    /// 一个窗口都不会翻 —— 而「一个都不翻」证明不了方向性，只证明夹具太弱。
    /// 白噪掉 3.90 dB，是能把窗口推过阈值的那个。
    ///
    /// 量级刻意压得很低（−48 dBFS 上下），对应真机实测的 0.12% 量级；
    /// 第一版把整体音量压到 −45 dBFS 附近，225 个窗口里 147 个翻转（65%），
    /// 那个比例不是真实工况，结论会变成另一回事。
    func testSilenceVerdictOnlyEverMovesTowardSilence() {
        let n = 48000 * 4
        var mix = [Float]()
        // 前两秒 −44 dBFS（阈值附近），后两秒 −52 dBFS（阈值下方）
        mix += noise(frames: n / 2, seed: 11, amplitude: 0.0126)   // ≈ −44 dBFS
        mix += noise(frames: n / 2, seed: 12, amplitude: 0.0025)   // ≈ −52 dBFS

        let src = mix
        let dst = bTier(mix)
        let a = silentFlags(src, rate: sourceRate)
        let b = silentFlags(dst, rate: targetRate)

        let common = min(a.count, b.count)
        var forward = 0, backward = 0
        for i in 0..<common where a[i] != b[i] {
            if a[i] { backward += 1 } else { forward += 1 }
        }
        XCTAssertEqual(backward, 0,
                       "出现了 \(backward) 个「静音→有声」的翻转。"
                       + "低通只会削能量，这个方向不该发生 —— 一旦发生，切点会落进词中间")
        // 正向翻转必须有、且是少数：全 0 说明夹具没触到阈值边缘；
        // 超过 60% 说明夹具整体压在阈值上，测的不是真实工况。
        XCTAssertGreaterThan(forward, 0, "零个翻转 —— 这条用例没触到阈值边缘，等于没测")
        let ratio = Double(forward) / Double(max(1, common))
        XCTAssertLessThan(ratio, 0.60,
                          String(format: "翻转比例 %.1f%% 过高，夹具整体压在阈值上了",
                                 ratio * 100))
        print(String(format: "阈值边缘宽带噪声 %d 窗口：有声→静音 %d (%.1f%%)，静音→有声 %d",
                     common, forward, ratio * 100, backward))
    }

    // MARK: - 分段切点

    /// 降采样前后**切点完全一致**。
    ///
    /// 这是本组用例最终要回答的问题。切点取自静音区间的中点
    /// （`Segmenter` 只往理想切点之前 45 秒内找），而静音边界最多偏移
    /// 一个窗口（20 ms），中点因此只动 10 ms —— 远小于 `minSegment`
    /// 与「必须在静音里」这两个约束能容忍的范围。
    ///
    /// 真机实测（两轨各 388 秒）切点偏差为 0.0000 秒。
    func testSegmentCutPointsAreUnaffectedByDownsampling() {
        // 20 秒：4 段语音 + 4 段静音。让 Segmenter 用 5 秒上限，
        // 真实项目里是 300 秒 —— 但「切点取自静音中点」这条逻辑与上限无关，
        // 用小值只是为了让测试跑得快。
        var src = [Float]()
        var pattern: [(Double, Bool)] = []
        for k in 0..<4 {
            pattern.append((2.0 + Double(k) * 0.4, true))
            pattern.append((1.6, false))
        }
        for (seconds, loud) in pattern {
            let frames = Int(seconds * sourceRate)
            src += loud
                ? speechLike(frames: frames, amplitude: 0.08)
                : [Float](repeating: 0, count: frames)
        }

        let dst = bTier(src)

        func plan(_ x: [Float], rate: Double) -> ([ClosedRange<Double>],
                                                   [Segmenter.Segment]) {
            let d = SilenceDetector(sampleRate: rate, channels: 1)
            var i = 0
            while i < x.count {
                let end = min(i + 512, x.count)
                d.append(Array(x[i..<end]))
                i = end
            }
            let sil = d.finish()
            let seg = Segmenter(maxSegment: 5, minSegment: 1, silenceSearchWindow: 3)
            return (sil, seg.segment(duration: Double(x.count) / rate, silences: sil))
        }

        let (silA, segA) = plan(src, rate: sourceRate)
        let (silB, segB) = plan(dst, rate: targetRate)

        XCTAssertEqual(segA.count, segB.count,
                       "段数变了：原 \(segA.map { String(format: "%.2f", $0.end) }) / "
                       + "B 档 \(segB.map { String(format: "%.2f", $0.end) })")

        guard segA.count == segB.count, !segA.isEmpty else { return }
        var worst = 0.0
        for (x, y) in zip(segA, segB) {
            worst = max(worst, abs(x.end - y.end))
            // 每段时长守恒也要成立：降采样不改变总时长
            XCTAssertEqual(x.duration, y.duration, accuracy: 0.05,
                           "第 \(segA.firstIndex(of: x) ?? 0) 段时长变了")
        }
        XCTAssertLessThanOrEqual(worst, 0.02,
                                 "切点最大偏差 \(worst) 秒，超出一个 20 ms 窗口")
        print("静音区间 原 \(silA.count) / B 档 \(silB.count)；切点最大偏差 \(worst) 秒")
    }

    /// 静音区间的**边界**最多偏移一个窗口。
    ///
    /// 这是「切点只动 10 ms」的上游依据：边界漂移被窗口长度（20 ms）硬性限制住，
    /// 不可能因为滤波器有 129 抽头就漂得更远 —— 抽头数影响的是**过渡带陡峭度**，
    /// 不是**时间定位精度**（零相位相关保证时间对齐）。
    func testSilenceBoundariesShiftByAtMostOneWindow() {
        var src = [Float]()
        for k in 0..<3 {
            let on = Int((1.5 + Double(k) * 0.3) * sourceRate)
            let off = Int(1.2 * sourceRate)
            src += speechLike(frames: on, amplitude: 0.08)
            src += [Float](repeating: 0, count: off)
        }
        let dst = bTier(src)

        func silences(_ x: [Float], rate: Double) -> [ClosedRange<Double>] {
            let d = SilenceDetector(sampleRate: rate, channels: 1)
            var i = 0
            while i < x.count {
                let end = min(i + 512, x.count)
                d.append(Array(x[i..<end]))
                i = end
            }
            return d.finish()
        }

        let a = silences(src, rate: sourceRate)
        let b = silences(dst, rate: targetRate)
        XCTAssertEqual(a.count, b.count, "静音段数变了：原 \(a.count) / B 档 \(b.count)")
        guard a.count == b.count, !a.isEmpty else { return }

        // 逐段比起点（每段静音的**起点**最容易被阈值边缘影响）
        for (i, (x, y)) in zip(a, b).enumerated() {
            let shift = abs(x.lowerBound - y.lowerBound)
            XCTAssertLessThanOrEqual(shift, 0.021,
                                     "第 \(i + 1) 段静音起点偏移 \(shift) 秒，超过一个窗口")
        }
    }

    // MARK: - 真正需要警惕的那一侧

    /// `average` 降混在「一个声道静音」时**掉 6.02 dB**。
    ///
    /// 这是整条链路上最大的一处能量变化，比低通的 3.90 dB 还大，
    /// 而且它**会**让有声窗口跌过 −45 dBFS 判成静音。
    ///
    /// 触发条件：源是双声道，但内容只在一个声道上。
    /// 系统音频 tap 给双声道而应用只往一个声道输出时就会这样。
    ///
    /// 后果可控（多切几个点，不会把停顿判成有声），但**必须知道**：
    /// 同相双声道掉 0.00 dB、单边有声掉 6.02 dB，两者差 6 dB，
    /// 足以让「同一场会议换个机器录」的分段结果不一样。
    func testAverageDownmixHalvesTheLevelWhenOneChannelIsSilent() {
        let n = 120000
        let mono: [Float] = (0..<n).map { i in
            Float(0.1 * sin(2 * .pi * 300 * Double(i) / sourceRate))
        }
        let srcR = steadyRMS(mono, skip: 1000, take: 40000)

        // 同相双声道：average 后不变
        var inPhase = [Float]()
        for v in mono { inPhase.append(v); inPhase.append(v) }
        let sameLevel = steadyRMS(
            MonoDownmix.mix(inPhase, channels: 2, strategy: .average),
            skip: 1000, take: 40000)
        XCTAssertEqual(db(sameLevel) - db(srcR), 0, accuracy: 0.1,
                       "同相双声道 average 后不该有变化")

        // 右声道静音：掉一半功率，即 −6.02 dB
        var halfSilent = [Float]()
        for v in mono { halfSilent.append(v); halfSilent.append(0) }
        let halved = steadyRMS(
            MonoDownmix.mix(halfSilent, channels: 2, strategy: .average),
            skip: 1000, take: 40000)
        XCTAssertEqual(db(halved) - db(srcR), -6.02, accuracy: 0.1,
                       "单边有声时 average 的衰减量变了")
        // 钉住它确实能翻转判定：把电平摆在 −41 dBFS，掉 6 dB 后到 −47 dBFS
        let borderline = mono.map { $0 * 0.089 }   // 约 −41 dBFS
        let lowered = MonoDownmix.mix(
            { var v = [Float](); for x in borderline { v.append(x); v.append(0) }; return v }(),
            channels: 2, strategy: .average)
        XCTAssertFalse(silentFlags(borderline, rate: sourceRate).contains(true),
                       "夹具前提不成立：源本就该判成有声")
        XCTAssertTrue(silentFlags(lowered, rate: sourceRate).contains(true),
                      "掉 6 dB 后就该判成静音了；若仍判有声，说明这条用例测的不是降混")
    }

    /// 语音状内容即使叠加 6 dB 的降混损失，静音判定仍不翻转。
    ///
    /// 这是「6 dB 到底要不要紧」的答案：语音集中在低频，两声道 average
    /// 之后能量分布不变，只是整体降 6 dB。
    ///
    /// 幅度 0.08 的语音状信号 RMS 是 **−30.33 dBFS**（归一化后系数 0.380，
    /// 不是理论上的 0.707 —— 因为 `norm` 用的是谐波**幅度**之和而非均方根），
    /// 掉 6 dB 后 **−36.35 dBFS**，距 −45 dBFS 的门限还有 **8.65 dB 余量**。
    ///
    /// 8.65 dB 不算宽裕，所以本条的结论是「正常会议够用」而不是「安全」：
    /// 危险的是**本来就轻**的内容（远端发言人的尾音、远场麦克风），
    /// 那才是该盯的，见 `testAverageDownmixHalvesTheLevelWhenOneChannelIsSilent`。
    func testSpeechSurvivesTheSixDecibelDownmixLoss() {
        let n = 240000
        let mono = speechLike(frames: n, amplitude: 0.08)
        XCTAssertEqual(db(steadyRMS(mono, skip: 2000, take: 40000)),
                       -30.33, accuracy: 0.5, "夹具电平对不上")

        var inter = [Float]()
        for v in mono { inter.append(v); inter.append(0) }
        let halved = MonoDownmix.mix(inter, channels: 2, strategy: .average)

        let before = steadyRMS(mono, skip: 2000, take: 40000)
        let after = steadyRMS(halved, skip: 2000, take: 40000)
        XCTAssertEqual(db(after) - db(before), -6.02, accuracy: 0.1)
        XCTAssertEqual(db(after), -36.35, accuracy: 0.5)
        XCTAssertGreaterThan(db(after), SilenceDetector.Settings().thresholdDB + 8,
                             "正常语音掉 6 dB 后离静音阈值只剩不到 8 dB 余量")
    }

    /// 真实的语音音量**有包络**，所以必然有窗口落在阈值附近 —— 这一条才是
    /// 「阈值附近掉 6 dB 会不会把词切两半」的正题。
    ///
    /// 上一条（`testSpeechSurvivesTheSixDecibelDownmixLoss`）有个隐含缺陷：
    /// 稳态正弦的每个 20 ms 窗口 RMS 几乎相同，整条信号离阈值 15 dB，
    /// 于是它测的是「**远离**阈值时不受影响」，而不是「阈值附近会怎样」。
    /// 这类用例绿了也不代表结论成立 —— 必须让夹具真的压到边界上。
    ///
    /// 真实语音的动态范围在 **−30 ~ −48 dBFS**（呼吸、字与字之间的衰减），
    /// 这里用两个不同频率的正弦包络近似，中心 −39 dBFS、摆幅 ±9 dB：
    /// 0.25 Hz（呼吸）与 2 Hz（字间）。
    ///
    /// 第一版把中心放在 −31.5 dBFS、摆幅只有 ±4.4 dB，结果谷值只到 −36.9 dBFS，
    /// 一个窗口都碰不到 −45 —— 这条用例当时是**完全无效**的，
    /// 是靠「静音占比 > 5%」这道自检断言把它抓出来的。
    func testSpeechEnvelopeNearTheThresholdOnlyEverMovesTowardSilence() {
        let n = 48000 * 8
        let tone = speechLike(frames: n, amplitude: 1.0)
        var mono = [Float]()
        mono.reserveCapacity(n)
        for i in 0..<n {
            let t = Double(i) / sourceRate
            // 分贝域摆动：−39 ± (9 sin + 3 sin)，范围约 −51 ~ −27 dBFS
            let db = -39.0 + 9.0 * sin(2 * .pi * 0.25 * t) + 3.0 * sin(2 * .pi * 2.0 * t)
            mono.append(tone[i] * Float(pow(10, db / 20)))
        }

        // 夹具有效性：包络必须真的把一部分窗口压到阈值附近
        let flagsBefore = silentFlags(mono, rate: sourceRate)
        let silentShare = Double(flagsBefore.filter { $0 }.count)
            / Double(max(1, flagsBefore.count))
        XCTAssertGreaterThan(silentShare, 0.05,
                             "包络没把任何窗口压到阈值附近（当前 \(silentShare)），夹具无效")
        XCTAssertLessThan(silentShare, 0.60,
                          "过半窗口都是静音，这已经不是「包络起伏」而是断续信号了")

        var inter = [Float]()
        for v in mono { inter.append(v); inter.append(0) }
        let halved = MonoDownmix.mix(inter, channels: 2, strategy: .average)

        let a = silentFlags(mono, rate: sourceRate)
        let b = silentFlags(halved, rate: sourceRate)
        let common = min(a.count, b.count)
        var forward = 0, backward = 0
        for k in 0..<common where a[k] != b[k] {
            if a[k] { backward += 1 } else { forward += 1 }
        }
        // 唯一允许的方向：多判静音。反向会把词中间的响音判成静音区，
        // 切点就会落进词里。
        XCTAssertEqual(backward, 0,
                       "掉 6 dB 之后出现 \(backward) 个「静音→有声」的反向翻转")
        print(String(format: "带包络语音 %d 窗口（原判静音 %.1f%%）：有声→静音 %d，反向 %d",
                     common, silentShare * 100, forward, backward))
    }
}
