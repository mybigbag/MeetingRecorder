import Foundation

/// 流式静音检测。
///
/// 为什么需要它：分段器（`Segmenter`）要求在**静音处**切，否则会把一个词切成两半。
/// 而"哪里是静音"必须从音频本身算出来——这是分段能真正落地的前提。
///
/// 设计上两点考虑：
/// 1. **流式**：按块喂入，内部只保留窗口级的能量，内存占用与音频长度无关。
///    一小时会议不会因为检测静音而多吃几十 MB。
/// 2. **按窗口判定 + 最短长度过滤**：单个 20ms 的低声窗口不等于静音
///    （说话人换气、词间停顿都会产生），只有**持续**超过阈值时长才算。
public final class SilenceDetector {

    /// 判定参数
    public struct Settings {
        /// 能量窗口长度（秒）。太短会被单个爆破音干扰，太长会把短静音吞掉。
        public var windowSeconds: Double
        /// 静音阈值（dBFS，满刻度 0）。低于此值判为静音。
        public var thresholdDB: Double
        /// 最短静音时长（秒）。短于此长度的静音不作为切点。
        public var minSilenceSeconds: Double
        /// 区间两端各收缩多少秒。留出安全边距，避免切点咬到语音的第一个/最后一个音素。
        public var edgeTrimSeconds: Double

        public init(
            windowSeconds: Double = 0.02,
            thresholdDB: Double = -45,
            minSilenceSeconds: Double = 0.35,
            edgeTrimSeconds: Double = 0.05
        ) {
            self.windowSeconds = windowSeconds
            self.thresholdDB = thresholdDB
            self.minSilenceSeconds = minSilenceSeconds
            self.edgeTrimSeconds = edgeTrimSeconds
        }
    }

    public let settings: Settings
    public let sampleRate: Double
    public let channels: Int

    /// 一个窗口的帧数（至少 1）
    private let windowFrames: Int
    /// 当前窗口已累计的平方和与帧数
    private var windowEnergy = 0.0
    private var windowFilled = 0
    /// 已完成窗口的序号（用于把窗口换算成秒）
    private var windowIndex = 0
    /// 当前连续静音段的起点（窗口序号）；nil 表示当前不在静音中
    private var silenceRunStart: Int?
    /// 已确认的静音区间（秒，相对本轨起点）
    private var silences: [ClosedRange<Double>] = []

    public init(sampleRate: Double, channels: Int, settings: Settings = Settings()) {
        self.sampleRate = max(1, sampleRate)
        self.channels = max(1, channels)
        self.settings = settings
        self.windowFrames = max(1, Int((settings.windowSeconds * sampleRate).rounded()))
    }

    /// 喂入一块音频（交错 Float 采样）。可分多次调用，长度任意。
    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let perWindow = windowFrames * channels
        var i = 0
        while i < samples.count {
            let take = min(perWindow - windowFilled * channels, samples.count - i)
            for j in 0..<take {
                let v = Double(samples[i + j])
                windowEnergy += v * v
            }
            windowFilled += take / channels
            i += take

            if windowFilled >= windowFrames {
                closeCurrentWindow()
            }
        }
    }

    /// 结束喂入，返回**已按最短长度过滤并收缩边缘**的静音区间（秒，升序）。
    ///
    /// 幂等：重复调用返回相同结果，不会因为二次处理而重复累积。
    @discardableResult
    public func finish() -> [ClosedRange<Double>] {
        // 尾部不足一个窗口的残料也要参与判定，否则音频末尾的长静音会被漏掉
        if windowFilled > 0 { closeCurrentWindow() }
        // 收尾时仍在静音中 → 关掉这一段
        closeSilenceRun(endingAtWindow: windowIndex)
        return silences
    }

    /// 只读快照：当前已确认的静音区间（不含未收尾的活跃段）
    public var confirmedSilences: [ClosedRange<Double>] { silences }

    // MARK: - 内部

    private func closeCurrentWindow() {
        let sampleCount = windowFilled * channels
        // RMS = sqrt(mean(x^2))。用窗口实际帧数除，尾部短窗口才不会因为分母偏大被判成静音。
        let rms = sampleCount > 0 ? (windowEnergy / Double(sampleCount)).squareRoot() : 0
        let isSilent = Self.dbFS(rms) < settings.thresholdDB

        if isSilent {
            if silenceRunStart == nil { silenceRunStart = windowIndex }
        } else {
            closeSilenceRun(endingAtWindow: windowIndex)
        }

        windowIndex += 1
        windowEnergy = 0
        windowFilled = 0
    }

    /// 结束一段连续静音（endWindow 为开区间，即静音段之后的第一个窗口）
    private func closeSilenceRun(endingAtWindow endWindow: Int) {
        guard let start = silenceRunStart else { return }
        silenceRunStart = nil

        let windowDuration = Double(windowFrames) / sampleRate
        var lo = Double(start) * windowDuration
        var hi = Double(endWindow) * windowDuration

        // 过滤：不足最短时长的静音不是切点
        guard hi - lo >= settings.minSilenceSeconds else { return }

        // 边缘收缩：只在收缩后仍为正长度时应用
        lo += settings.edgeTrimSeconds
        hi -= settings.edgeTrimSeconds
        guard hi > lo else { return }

        silences.append(lo...hi)
    }

    /// 线性幅度 → dBFS（满刻度为 0 dB）。极小值兜底到 -160，避免 log(0) 得 -inf。
    static func dbFS(_ amplitude: Double) -> Double {
        guard amplitude > 0 else { return -160 }
        return 20 * log10(min(amplitude, 1.0))
    }
}
