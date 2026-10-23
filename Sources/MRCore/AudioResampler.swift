import Foundation

// MARK: - 降混

/// 多声道 → 单声道的策略。
///
/// **默认 `.firstChannel`，不是 `.average`** —— 这个默认值改过，依据是真机实测：
/// `average` 在**反相内容**（L = −R）上会把整轨**抵消成静音**且不报错，
/// 在**单边有声**上掉 6.02 dB。详见 `RecorderPreferences.downmixStrategy`。
///
/// 两种策略各自的代价（都是真的，别只说其中一面）：
/// - `average`：保留全部声道信息，代价是单边有声掉 6.02 dB、**反相内容归零**。
/// - `firstChannel`：电平永不掉、绝不抵消，代价是丢掉第 2 声道的内容
///   （宽立体声场景下右声道的声音会消失）。
public enum MonoDownmixStrategy: String, Codable, CaseIterable, Sendable {
    /// 各声道算术平均。**不再是默认**（见类型注释）。
    case average
    /// 只取第 1 个声道。**默认**。躲开相位抵消与 6 dB 损失，代价是丢掉其余声道。
    case firstChannel

    /// 供 CLI `config set downmix` 复用的解析：认识 `first-channel` 这类带连字符的写法。
    ///
    /// 认不出的值返回 `nil` 而不是回退某个默认值 —— **让调用方决定怎么报错**。
    /// 静默回退到「会丢数据的那一侧」是最坏的组合。
    public init?(resolving raw: String?) {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch key {
        case "average", "avg", "平均": self = .average
        case "firstchannel", "first", "左声道", "第1声道": self = .firstChannel
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .average: return "多声道平均"
        case .firstChannel: return "只取第 1 声道"
        }
    }

    /// 菜单项的说明文字。**必须说清代价**——只写「多声道平均」会让人以为它没有副作用。
    public var menuHelp: String {
        switch self {
        case .average:
            return "两声道求平均：保留全部信息，但单边有声时掉 6 dB、反相内容会抵消成静音"
        case .firstChannel:
            return "只取第 1 声道：电平不掉、绝不抵消，代价是丢掉第 2 声道内容（默认）"
        }
    }
}

/// 交错多声道 → 单声道。**降混的唯一实现**。
///
/// 不放在 `AudioInterleaver` 里：那个类型在 `MRC Capture`，而写前变换管线在 `MRCore`，
/// 依赖方向不允许反向引用。原 `AudioInterleaver.mixToMono` 已删除——它没有任何调用方，
/// 留着就会变成「两份降混实现，将来只改一份」。
public enum MonoDownmix {

    /// - Parameter interleaved: 交错排列的采样（L R L R …）
    /// - Returns: 单声道采样。单声道输入原样返回（不做无意义的拷贝）
    public static func mix(
        _ interleaved: [Float],
        channels: Int,
        strategy: MonoDownmixStrategy = .firstChannel
    ) -> [Float] {
        guard channels > 0 else { return [] }
        // 单声道没什么可混的。**原样返回**，不走一遍乘法——
        // 走一遍就可能引入「除以 1」之外的误差，而且白抄一份数组。
        guard channels > 1 else { return interleaved }

        let frames = interleaved.count / channels
        guard frames > 0 else { return [] }

        var out = [Float](repeating: 0, count: frames)
        switch strategy {
        case .average:
            // 除以声道数，不是求和：求和会让音量按声道数翻倍，
            // 而「开了省空间之后录音变响了/削顶了」是最难追的一类症状。
            let scale = 1.0 / Float(channels)
            for i in 0..<frames {
                let base = i * channels
                var sum: Float = 0
                for c in 0..<channels { sum += interleaved[base + c] }
                out[i] = sum * scale
            }
        case .firstChannel:
            for i in 0..<frames { out[i] = interleaved[i * channels] }
        }
        return out
    }

    /// 判据阈值（线性幅度），**低于**它就算「这一段等于没有声音」。
    ///
    /// 定 `1e-6`（约 −120 dBFS）而不是 0，是**必须的**：反相抵消的产物并不是
    /// 精确的 0 —— 浮点求和不精确，实测落在 1e-9 上下。判据写成「== 0」的话，
    /// 真实数据上永远不成立，这条告警等于没有。
    ///
    /// 代价是「低于阈值但非零」也会被报成抵消。这个误报可以接受：
    /// −120 dBFS 以下的内容用户一样听不见，「输出低到听不见」与「输出为零」
    /// 对他没有区别；而漏报（真抵消了却不说）才是不可接受的。
    public static let cancellationFloor: Float = 1e-6

    /// 降混是否发生了**相位抵消**——`average` 独有的失效模式。
    ///
    /// 症状：两个声道各自都有能量（反相的立体声内容，L = +x、R = −x），
    /// 求平均之后整段变成静音。**录音看起来完全成功**：帧数正常、时长正常、
    /// manifest 正常，没有任何地方会报错——用户拿到的是一条纯静音轨。
    ///
    /// 判据是「源峰值 > 0 且结果峰值 ≤ 阈值」，与 `AudioTranscoder.lostSignal`
    /// 同一条纪律：**源本身全静音不算抵消**，那是采集没起来，是另一件事、另一条提示。
    ///
    /// - Parameter strategy: 实际使用的策略。`firstChannel` 是逐样本拷贝，
    ///   恒不抵消，直接返回 false —— 查它没有意义还会白花一遍遍历。
    public static func isPhaseCancelled(
        source: [Float],
        mixed: [Float],
        channels: Int,
        strategy: MonoDownmixStrategy
    ) -> Bool {
        guard channels > 1, strategy == .average else { return false }
        let sourcePeak = source.reduce(Float(0)) { a, v in max(a, abs(v)) }
        guard sourcePeak > cancellationFloor else { return false }
        let mixedPeak = mixed.reduce(Float(0)) { a, v in max(a, abs(v)) }
        return mixedPeak <= cancellationFloor
    }
}

// MARK: - 重采样

/// 流式重采样器：带抗混叠低通的分数延迟线性插值。
///
/// **为什么不用 `AVAudioConverter`。** 它质量很好，但（1）是 Objective-C 类、
/// 每次调用分配 buffer，要跑在实时采集回调里；（2）是拉取式（输入块）而采集回调是推入式，
/// 中间要再搭一层缓冲；（3）它的行为不透明，单测没法断言「15 kHz 被压了多少 dB」。
/// 这里自己实现，换来的是**每一步都能被单测钉住**：滤波器系数、延迟、长度、抗混叠。
///
/// **为什么必须有低通。** 48 kHz 降到 24 kHz 时，12~24 kHz 的内容会**折叠**回 0~12 kHz
/// （混叠）。方案文档里 24k 档的转写质量（99.7%）是用 ffmpeg 生成的变体测的，
/// 而 ffmpeg 会做抗混叠——直接抽样是丢掉了这一步，质量结论不能平移过来。
///
/// 三个刻意的设计：
/// 1. **零相位（居中）相关，而不是因果卷积。** 输出第 `m` 个样本对应输入第 `m` 个样本的
///    时刻（对称窗的中心），所以重采样**不引入整段延迟**。否则两条轨一旦只有一条被重采样，
///    就会出现相对时间偏移。
/// 2. **状态跨块保存**（原始样本尾巴、输出流、小数位置）。每次回调 512 帧、每秒 94 次，
///    无状态实现会在每个块边界制造一次咔哒声。
/// 3. **只在降采样时上低通。** 升采样不需要抗混叠，加了反而削掉源信号近奈奎斯特的部分。
///    （`TrackWriteFormat.resolve` 本身不会升采样，这里是给直接构造留的正确行为。）
public struct AudioResampler: Sendable {

    /// 默认抽头数。129 抽头 + Blackman 窗 ≈ 5.5/129 = 0.043 的过渡带（归一化），
    /// 对 48k→24k 来说阻带从约 11.1 kHz 开始、12.1 kHz 起 60 dB 以下——
    /// 足够把 12~24 kHz 折回来的成分压到听不见，也不会啃到 10 kHz 以下的语音。
    public static let defaultTaps = 129

    public let sourceSampleRate: Double
    public let targetSampleRate: Double
    /// 实际使用的抽头数（不滤波时为 0）
    public let taps: Int

    /// 源率与目标率相同 → 完全透传，一个样本都不动
    public var isPassthrough: Bool { sourceSampleRate == targetSampleRate }

    /// 每产出一个样本要前进多少个**输入**样本
    private let step: Double
    /// 低通系数（对称、直流增益已归一化为 1）。不滤波时为空
    private let coefficients: [Float]
    /// 对称窗的半宽（= (taps-1)/2）。输出第 m 个样本的窗口是 [m-g, m+g]
    private let halfWidth: Int

    /// 已收到但还没法完全定心的原始输入。全局下标从 `pendingStart` 起
    private var pending: [Float]
    private var pendingStart: Int
    /// 下一个要产出的输出下标（= 输入时间轴上的第几个样本）
    private var nextCenter: Int
    /// 迄今为止收到的最大全局输入下标（-1 表示一个都没有）
    private var lastGlobal: Int
    /// 低通后的流（按输出下标排列）；插入输出样本后由此处按小数位置取样
    private var stream: [Float]
    /// 在 `stream` 上的小数读位置
    private var position: Double
    /// 是否已经排空过尾部（`flush()` 幂等）
    private var drained: Bool

    public init(
        sourceSampleRate: Double,
        targetSampleRate: Double,
        taps: Int = AudioResampler.defaultTaps
    ) {
        let src = sourceSampleRate > 0 ? sourceSampleRate : 1
        let dst = targetSampleRate > 0 ? targetSampleRate : 1
        self.sourceSampleRate = src
        self.targetSampleRate = dst
        self.step = src / dst

        if dst < src {
            // 必须是奇数，保证有唯一的中心抽头；否则「居中」这件事没有定义
            let t = max(9, taps | 1)
            self.taps = t
            // 截止频率归一化到**源**采样率。0.42 而不是 0.5：留出过渡带，
            // 让 12 kHz（目标奈奎斯特）落在阻带里，而不是刚好压在拐点上。
            let cutoff = 0.42 * (dst / src)
            self.coefficients = Self.designLowpass(cutoffNormalized: cutoff, taps: t)
            self.halfWidth = (t - 1) / 2
        } else {
            self.taps = 0
            self.coefficients = []
            self.halfWidth = 0
        }

        self.pending = []
        self.pendingStart = 0
        self.nextCenter = 0
        self.lastGlobal = -1
        self.stream = []
        self.position = 0
        self.drained = false
    }

    // MARK: - 主流程

    /// 推入一段源采样，取出能产出的目标采样。
    ///
    /// 产出数量是 `round(n / step)` 量级（`n` 为本次推入的样本数），
    /// 但**块边界处会差 ±1**：定心需要 `halfWidth` 个「未来」样本，
    /// 它们要等下一块到达才能补上——这正是状态必须跨块保存的原因。
    public mutating func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        if isPassthrough { return input }
        guard !drained else { return [] }

        // 非有限值（NaN / ±∞）在这里当**静音**拦掉，不能让它们进滤波器。
        //
        // 单说「一个坏样本」不严重——但 FIR 是把一个输入样本摊到整个窗宽上的，
        // 129 抽头意味着**一个 NaN 会污染 129 个输出样本**，而且它会进
        // `pending` 历史，往后每块都再扩散一次。换成 0 则只损失那一个样本。
        // 这与 `WAVWriter.quantizeToInt16` 对非有限值的处理是同一个约定。
        //
        // 只在真的出现非有限值时才拷贝数组：这是每条采集回调都要走的路径，
        // 常态下不该多分配一次。
        let source = input.allSatisfy { $0.isFinite } ? input : input.map { $0.isFinite ? $0 : 0 }

        let base = lastGlobal + 1
        pending.append(contentsOf: source)
        lastGlobal = base + source.count - 1

        var filtered: [Float] = []
        filtered.reserveCapacity(input.count)
        while nextCenter + halfWidth <= lastGlobal {
            filtered.append(value(centeredAt: nextCenter))
            nextCenter += 1
        }
        stream.append(contentsOf: filtered)

        // 丢掉再也不会用到的前缀：下一个定心的窗口左端是 nextCenter - halfWidth
        let keepFrom = nextCenter - halfWidth
        if keepFrom > pendingStart {
            let drop = min(keepFrom - pendingStart, pending.count)
            pending.removeFirst(drop)
            pendingStart += drop
        }

        return drain()
    }

    /// 排空尾部并结束。
    ///
    /// 不排空的话文件会短掉约 `halfWidth` 个**源**样本（48 kHz 下约 0.67 ms）。
    /// 绝对值很小，但「写入时长比采集时长少一点点」会让人在核对时间轴时多一轮怀疑，
    /// 而不排空换来的收益是零。补零排空之后，产出总数约等于 `输入数 / step`。
    ///
    /// ⚠️ 补零的代价是**末尾约 `halfWidth` 个输出样本会渐隐**：零相位滤波器的窗口
    /// 覆盖 `[m-halfWidth, m+halfWidth]`，到文件末尾之后没有样本可用，只能按零处理。
    /// 48 kHz 下这是最后约 1.3 ms，人耳不可闻，也不会影响转写；但它是**边界固有行为**，
    /// 不是可以「修好」的东西——任何流式重采样器面对已然结束的输入都只能做同样的假设。
    ///
    /// 幂等：重复调用第二次返回空。
    public mutating func flush() -> [Float] {
        guard !isPassthrough, !drained else { return [] }
        if coefficients.isEmpty {
            drained = true
            return drain()
        }
        // 补半个窗宽的零，把 `pending` 里最后那些「定不了心」的样本推过边界。
        // 这些零只会参与最末尾几个输出的窗函数内积，不会改变任何已有输出。
        //
        // 注意顺序：`drained` 必须在 `process` **之后**置位——`process` 自己也会
        // 检查这个标志，先置位等于把自己挡在门外，尾部一颗都排不出来。
        let tail = process([Float](repeating: 0, count: halfWidth))
        drained = true
        return tail
    }

    // MARK: - 内部

    /// 第 `center` 个输出（= 输入时间轴上的第 center 个样本时刻）的值。
    ///
    /// 对称 FIR 的**居中相关**：窗口覆盖全局下标 `center-halfWidth … center+halfWidth`，
    /// 落在 `pending` 之外（也就是还没收到的未来，或全局下标为负的过去）按 0 处理。
    /// 全局下标为负的部分是启动瞬态：那一段滤波器历史本来就是零，物理上正确。
    private func value(centeredAt center: Int) -> Float {
        let start = center - halfWidth
        let offset = start - pendingStart

        guard taps > 0 else {
            return sample(atOffset: offset)
        }
        var acc: Float = 0
        coefficients.withUnsafeBufferPointer { h in
            pending.withUnsafeBufferPointer { x in
                for p in 0..<taps {
                    let idx = offset + p
                    // 边界之外是零：左边界（全局 < 0）与右边界（未来样本尚未到达）
                    let v: Float = (idx >= 0 && idx < x.count) ? x[idx] : 0
                    acc += h[p] * v
                }
            }
        }
        return acc
    }

    private func sample(atOffset offset: Int) -> Float {
        (offset >= 0 && offset < pending.count) ? pending[offset] : 0
    }

    /// 从 `stream` 里按 `step` 的小数位置取值（两点线性插值），并丢掉已消耗的前缀。
    private mutating func drain() -> [Float] {
        guard stream.count > 1 else { return [] }
        var out: [Float] = []
        while position + 1 < Double(stream.count) {
            let i = Int(position)
            let frac = Float(position - Double(i))
            let a = stream[i]
            out.append(a + (stream[i + 1] - a) * frac)
            position += step
        }
        // 保留 `floor(position)` 及其后继——下一个输出要用到它们
        let drop = Int(position)
        if drop > 0 {
            let n = min(drop, max(0, stream.count - 1))
            if n > 0 {
                stream.removeFirst(n)
                position -= Double(n)
            }
        }
        return out
    }

    // MARK: - 滤波器设计（纯函数，供测试单独钉住）

    /// Blackman 窗 sinc 低通。**对称**、直流增益归一化为 1。
    ///
    /// - Parameter cutoffNormalized: 截止频率，单位是「周期 / 样本」（0 < f < 0.5）
    /// - Parameter taps: 抽头数；偶数会被抬成奇数（对称窗需要唯一中心）
    public static func designLowpass(cutoffNormalized: Double, taps: Int) -> [Float] {
        let t = max(3, taps | 1)
        let center = Double(t - 1) / 2
        let fc = min(0.499, max(1e-5, cutoffNormalized))
        let denominator = Double(t - 1)

        var h = [Float](repeating: 0, count: t)
        var sum = 0.0
        for i in 0..<t {
            let n = Double(i) - center
            // 归一化 sinc：n = 0 处取极限 2·fc，保证直流附近增益为 1
            let sinc = (n == 0) ? 2 * fc : sin(2 * Double.pi * fc * n) / (Double.pi * n)
            let w = 0.42
                - 0.5 * cos(2 * Double.pi * Double(i) / denominator)
                + 0.08 * cos(4 * Double.pi * Double(i) / denominator)
            let v = sinc * w
            h[i] = Float(v)
            sum += v
        }
        // 归一化到直流增益 1：不做的话常数输入会被整体放大/衰减，
        // 表现为「开了省空间之后录音音量变了」——这正是 B20-02 钉住的东西。
        if abs(sum) > 1e-12 {
            for i in 0..<t { h[i] = Float(Double(h[i]) / sum) }
        }
        return h
    }
}
