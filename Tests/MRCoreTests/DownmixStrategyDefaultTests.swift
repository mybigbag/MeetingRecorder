import XCTest
@testable import MRCore

/// 降混策略的默认值、`average` 的相位抵消失效。
///
/// **这组判据全部来自真机实测**，不是推理。样本：本机系统音频 tap（2 声道 48 kHz），
/// 播放四种构造信号后录回来，逐样本量电平。四种工况是「能把 `average` 的代价
/// 逼到极端」的那些，不是随手挑的：
///
/// | 源的两声道内容 | `average` | `firstChannel` |
/// |---|---|---|
/// | 同相（L = R） | 0.00 dB | 0.00 dB |
/// | 单边（仅 L 有声） | **−6.02 dB** | 0.00 dB |
/// | **反相（L = −R）** | **全静音（−∞ dB）** | 0.00 dB |
/// | 宽立体声（440 / 880 Hz） | −3.01 dB | 0.00 dB（但丢掉右声道内容） |
///
/// 决定性的是第三行：`average` 遇到反相内容会把整轨**抵消成静音**，而录音看起来
/// 完全成功——帧数正常、时长正常、manifest 正常，没有任何地方会报错。
/// 所以默认策略是 `firstChannel`。
///
/// 这就是**默认值为什么必须实测**：改之前它写的是「理论上可能相位抵消」，
/// 一个「可能」不足以支撑换一个默认值；实测拿到「−∞ dB」才够。
final class DownmixStrategyDefaultTests: XCTestCase {

    private let sourceRate = 48000.0

    /// 交错双声道：生成器签名带**声道下标**。
    ///
    /// 曾经写成 `(Int) -> Float`，于是每个声道拿到同一个值——
    /// 那样构造出来的「双声道夹具」左右完全相同，反相工况根本造不出来。
    /// 这已是本项目第五次因为夹具表达力不足导致假绿/无效用例。
    private func interleaved(frames: Int, gen: (Int, Int) -> Float) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(frames * 2)
        for f in 0..<frames {
            out.append(gen(f, 0))
            out.append(gen(f, 1))
        }
        return out
    }

    private func tone(frames: Int, hz: Double, amp: Float = 0.3) -> [Float] {
        (0..<frames).map { f in
            amp * Float(sin(2 * .pi * hz * Double(f) / sourceRate))
        }
    }

    private func db(_ v: Float) -> Float {
        v > 0 ? 20 * log10(v) : -.infinity
    }

    private func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var s: Float = 0
        for v in x { s += v * v }
        return (s / Float(x.count)).squareRoot()
    }

    // MARK: - 四种工况

    /// 同相：`average` 与 `firstChannel` **等价**。
    ///
    /// 这一条是「改默认值不会让正常内容变差」的唯一保证。
    /// 本机实测同相内容占绝大多数（播 `say` 语音时两声道完全相同，差值 RMS 为 −∞）。
    func testInPhaseContentIsIdenticalUnderBothStrategies() {
        let n = 48000
        let t = tone(frames: n, hz: 440)
        let src = interleaved(frames: n) { f, _ in t[f] }

        let avg = MonoDownmix.mix(src, channels: 2, strategy: .average)
        let first = MonoDownmix.mix(src, channels: 2, strategy: .firstChannel)

        XCTAssertEqual(db(rms(avg)), db(rms(first)), accuracy: 0.01,
                       "同相内容下两种策略电平应相同")
        XCTAssertEqual(db(rms(avg)), db(rms(t)), accuracy: 0.01,
                       "同相内容下 average 不该掉电平（实测 0.00 dB）")
    }

    /// 单边有声：`average` 掉 **6.02 dB**，`firstChannel` 不掉。
    ///
    /// 6 dB 正好是一半功率——这让上一轮量到的「降采样对静音检测的影响」
    /// 有了来源：语音掉 6 dB 后距 −45 dBFS 阈值只剩 8.65 dB 余量。
    func testSingleSidedContentLosesSixDecibelsUnderAverage() {
        let n = 48000
        let t = tone(frames: n, hz: 440)
        let src = interleaved(frames: n) { f, c in c == 0 ? t[f] : 0 }

        let avg = MonoDownmix.mix(src, channels: 2, strategy: .average)
        let first = MonoDownmix.mix(src, channels: 2, strategy: .firstChannel)

        XCTAssertEqual(db(rms(avg)) - db(rms(t)), -6.02, accuracy: 0.02,
                       "average 在单边有声时掉 6.02 dB")
        XCTAssertEqual(db(rms(first)) - db(rms(t)), 0, accuracy: 0.01,
                       "firstChannel 在单边有声时不掉电平")
    }

    /// **反相内容：`average` 整轨抵消成静音。** 这是改默认值的决定性依据。
    ///
    /// 症状最恶劣的地方不是「听不见」，而是**录音看起来完全成功**：
    /// 帧数正常、时长正常、manifest 正常，没有任何地方会报错。
    /// 用户拿到的是一条纯静音轨，而界面显示一切正常。
    func testInvertedContentBecomesSilentUnderAverage() {
        let n = 48000
        let t = tone(frames: n, hz: 440)
        let src = interleaved(frames: n) { f, c in c == 0 ? t[f] : -t[f] }

        let avg = MonoDownmix.mix(src, channels: 2, strategy: .average)
        let first = MonoDownmix.mix(src, channels: 2, strategy: .firstChannel)

        XCTAssertEqual(rms(avg), 0, accuracy: 1e-7,
                       "反相内容经 average 必须归零——这正是要改默认值的原因")
        XCTAssertEqual(db(rms(avg)), -.infinity)
        // 源确实有能量，否则「归零」就只是「本来就没声音」，不是抵消。
        XCTAssertGreaterThan(rms(t), 0.2, "夹具失效：源本身必须有能量")
        // firstChannel 是逐样本拷贝，一个采样都不该变。
        for (i, v) in first.enumerated() {
            XCTAssertEqual(v, t[i], accuracy: 1e-7, "第 \(i) 个采样被改动了")
            if i > 2000 { break }
        }
    }

    /// 宽立体声：两种策略**各有损失**，方向相反。
    ///
    /// 这条是给「改默认值」的成本留账：选 `firstChannel` 确实会丢掉右声道的内容。
    /// 不写这条的话，文档里就成了「firstChannel 全面更好」的错误印象。
    func testWideStereoTradesOffInTheOppositeDirection() {
        let n = 48000
        let low = tone(frames: n, hz: 440)
        let high = tone(frames: n, hz: 880)
        let src = interleaved(frames: n) { f, c in c == 0 ? low[f] : high[f] }

        let avg = MonoDownmix.mix(src, channels: 2, strategy: .average)
        let first = MonoDownmix.mix(src, channels: 2, strategy: .firstChannel)

        // 两个不同频率正交 → average 后功率减半（−3.01 dB）
        XCTAssertEqual(db(rms(avg)) - db(rms(low)), -3.01, accuracy: 0.05,
                       "不同频率的两声道求平均会掉 3.01 dB")
        // firstChannel 保住左声道，但右声道（880 Hz）整个没了。
        // 判据用「与源左声道逐样本相同」而不是「电平差多少」——
        // 后者在 880 Hz 混叠到别的频点时会有假阳性。
        for (i, v) in first.enumerated() {
            XCTAssertEqual(v, low[i], accuracy: 1e-7,
                           "firstChannel 应逐样本保留第 1 声道")
            if i > 2000 { break }
        }
        // 反过来 average 一定不等于源左声道（否则就是「保留了低频、只是电平小」）
        var differs = false
        for i in 0..<min(n, 4000) where abs(avg[i] - low[i]) > 1e-6 {
            differs = true
            break
        }
        XCTAssertTrue(differs, "average 后应混入了右声道的内容（880 Hz）")
    }

    // MARK: - 默认值

    /// 默认策略是 `firstChannel`，**不是** `average`。
    ///
    /// 判据是「不传参数时 `mix` 用的哪个」——直接打生产默认值的实际行为，
    /// 而不是断言某个常量或某段文档。默认值这种事最容易被改回去，
    /// 而改回去不会有任何编译错误。
    func testDefaultStrategyIsFirstChannelNotAverage() {
        let n = 4800
        let t = tone(frames: n, hz: 440)
        // 构造一个只有 `average` 会丢信息的夹具：反相
        let src = interleaved(frames: n) { f, c in c == 0 ? t[f] : -t[f] }

        // 不传 strategy —— 用生产默认值
        let byDefault = MonoDownmix.mix(src, channels: 2)
        let explicitFirst = MonoDownmix.mix(src, channels: 2, strategy: .firstChannel)
        let explicitAverage = MonoDownmix.mix(src, channels: 2, strategy: .average)

        XCTAssertEqual(byDefault.count, explicitFirst.count)
        XCTAssertGreaterThan(rms(byDefault), 0.1,
                             "默认策略把反相内容抵消成静音了 —— 默认值被改回 average 了？")
        XCTAssertEqual(rms(byDefault), rms(explicitFirst), accuracy: 1e-7)
        XCTAssertNotEqual(rms(byDefault), rms(explicitAverage), accuracy: 1e-6)
    }

    /// 偏好层的默认值同样是 `firstChannel`，且**读的时候不写键**。
    ///
    /// 「读不写键」是本项目的既有纪律：不写键，「缺失时返回默认值」这个断言
    /// 第二次跑才不会因为键已存在而不成立。
    func testPreferenceDefaultsToFirstChannelAndDoesNotWriteOnRead() {
        let suite = "DownmixStrategyDefaultTests.\(name.hashValue)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = RecorderPreferences(defaults: defaults)

        XCTAssertEqual(prefs.downmixStrategy, .firstChannel, "偏好默认值必须是 firstChannel")
        XCTAssertNil(defaults.string(forKey: RecorderPreferences.downmixStrategyKey),
                     "读一次偏好不该把默认值写进 UserDefaults")

        prefs.downmixStrategy = .average
        XCTAssertEqual(prefs.downmixStrategy, .average)
        XCTAssertEqual(defaults.string(forKey: RecorderPreferences.downmixStrategyKey),
                       MonoDownmixStrategy.average.rawValue)

        // 存了不认识的名字必须回退默认，**不能**回退到会丢数据的那一侧
        defaults.set("average2", forKey: RecorderPreferences.downmixStrategyKey)
        XCTAssertEqual(prefs.downmixStrategy, .firstChannel,
                       "不认识的策略名应回退到安全的默认值")
    }

    /// `resolving` 认得几套写法，认不出的返回 `nil`。
    ///
    /// **认不出时必须返回 `nil` 而不是某个默认值** —— 让调用方决定怎么报错。
    /// 静默回退到 `average` 是最坏的组合：用户以为切了策略，其实没有。
    func testResolvingAcceptsSpellingsAndRejectsUnknownOnes() {
        XCTAssertEqual(MonoDownmixStrategy(resolving: "first-channel"), .firstChannel)
        XCTAssertEqual(MonoDownmixStrategy(resolving: "firstchannel"), .firstChannel)
        XCTAssertEqual(MonoDownmixStrategy(resolving: "first_channel"), .firstChannel)
        XCTAssertEqual(MonoDownmixStrategy(resolving: "FIRST-CHANNEL"), .firstChannel)
        XCTAssertEqual(MonoDownmixStrategy(resolving: " first "), .firstChannel)
        XCTAssertEqual(MonoDownmixStrategy(resolving: "average"), .average)
        XCTAssertEqual(MonoDownmixStrategy(resolving: "AVG"), .average)
        XCTAssertNil(MonoDownmixStrategy(resolving: "mix"))
        XCTAssertNil(MonoDownmixStrategy(resolving: ""))
        XCTAssertNil(MonoDownmixStrategy(resolving: nil))
    }

    /// 两种策略的说明文字都必须**说清代价**，不能只报好处。
    ///
    /// 菜单与 CLI 都直接把这些文案显示给用户。只写好处的说明等于隐瞒。
    func testBothStrategiesDocumentTheirOwnCost() {
        XCTAssertTrue(MonoDownmixStrategy.average.menuHelp.contains("6"),
                      "average 的说明必须提到 6 dB 损失")
        XCTAssertTrue(MonoDownmixStrategy.average.menuHelp.contains("静音"),
                      "average 的说明必须提到反相抵消成静音")
        XCTAssertTrue(MonoDownmixStrategy.firstChannel.menuHelp.contains("丢掉"),
                      "firstChannel 的说明必须承认它会丢掉声道内容")
        for s in MonoDownmixStrategy.allCases {
            XCTAssertFalse(s.menuHelp.isEmpty, "\(s) 缺说明文字")
            XCTAssertFalse(s.displayName.isEmpty, "\(s) 缺显示名")
        }
    }

    // MARK: - 相位抵消检测

    /// 检测判据：源有能量、结果为静音、`average` → 判为抵消。
    func testPhaseCancellationIsDetectedForInvertedContentUnderAverage() {
        let n = 4800
        let t = tone(frames: n, hz: 440)
        let src = interleaved(frames: n) { f, c in c == 0 ? t[f] : -t[f] }
        let mixed = MonoDownmix.mix(src, channels: 2, strategy: .average)

        XCTAssertTrue(MonoDownmix.isPhaseCancelled(
            source: src, mixed: mixed, channels: 2, strategy: .average))
    }

    /// `firstChannel` 永不抵消 —— 判据对它必须恒为 false。
    ///
    /// 不查是对的（逐样本拷贝不可能抵消），但如果实现里忘了判策略，
    /// 这条会红。
    func testPhaseCancellationIsNeverReportedForFirstChannel() {
        let n = 4800
        let t = tone(frames: n, hz: 440)
        let src = interleaved(frames: n) { f, c in c == 0 ? t[f] : -t[f] }
        // 故意把「结果」也传成静音的那份 —— 判据仍必须为 false
        let silent = MonoDownmix.mix(src, channels: 2, strategy: .average)
        XCTAssertFalse(MonoDownmix.isPhaseCancelled(
            source: src, mixed: silent, channels: 2, strategy: .firstChannel))
    }

    /// **源本身全静音不算抵消。**
    ///
    /// 这条是 E 档踩过的坑的翻版：当时「源全静 → 报转码失败」把 3 条真实静音轨
    /// 全判成了故障。采集没起来是另一件事、另一条提示，不能混进「降混抵消」。
    func testSilentSourceIsNotReportedAsPhaseCancellation() {
        let n = 4800
        let src = [Float](repeating: 0, count: n * 2)
        let mixed = MonoDownmix.mix(src, channels: 2, strategy: .average)
        XCTAssertFalse(MonoDownmix.isPhaseCancelled(
            source: src, mixed: mixed, channels: 2, strategy: .average),
            "源本来就是静音的，采集没起来 —— 不是降混抵消")
    }

    /// 单声道不查抵消：没有「多个声道」可抵消。
    func testSingleChannelSourceIsNeverPhaseCancellation() {
        let t = tone(frames: 4800, hz: 440)
        let src = [Float](repeating: 0, count: 4800 * 2)
        XCTAssertFalse(MonoDownmix.isPhaseCancelled(
            source: src, mixed: t, channels: 1, strategy: .average))
    }

    /// 阈值把「低到听不见」与「完全归零」当成同一件事 —— 这是**有意的取舍**。
    ///
    /// 反相抵消的产物并不是精确的 0（浮点求和不精确），实测落在 1e-9 上下；
    /// 而 1e-9（−180 dBFS）用户一样听不见。所以判据用「峰值低于 1e-6」
    /// 而不是「== 0」—— 后者在真实数据上**永远不成立**，告警等于没有。
    ///
    /// 代价要写清楚：一个 −120 dBFS 以下但非零的输出也会被报成抵消。
    /// 本场景下这个误报是**可以接受**的，因为「输出低到听不见」对用户来说
    /// 与「输出为零」没有区别，而漏报才是不可接受的。
    func testAnythingBelowTheAudibleFloorCountsAsCancellation() {
        let n = 4800
        let t = tone(frames: n, hz: 440)
        let src = interleaved(frames: n) { f, c in c == 0 ? t[f] : -t[f] }

        // 远低于阈值（模拟浮点求和的残留）
        XCTAssertTrue(MonoDownmix.isPhaseCancelled(
            source: src, mixed: [Float](repeating: 1e-9, count: n),
            channels: 2, strategy: .average),
            "反相抵消的产物就是 1e-9 量级，判据必须能抓住它")

        // 恰好在阈值上：`<=` 所以也算静音
        XCTAssertTrue(MonoDownmix.isPhaseCancelled(
            source: src, mixed: [Float](repeating: MonoDownmix.cancellationFloor, count: n),
            channels: 2, strategy: .average),
            "判据是 <=，恰好等于阈值算静音")

        // 高于阈值 → 不报
        let audible = MonoDownmix.cancellationFloor * 10
        XCTAssertFalse(MonoDownmix.isPhaseCancelled(
            source: src, mixed: [Float](repeating: audible, count: n),
            channels: 2, strategy: .average),
            "\(audible) 已高于阈值，不该报成抵消")
    }
}
