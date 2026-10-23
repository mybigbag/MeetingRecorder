import Foundation

/// 一条音轨的累计统计。
///
/// ⚠️ 这里有一个踩过的坑，必须显式建模：
/// Core Audio 非交错（non-interleaved）格式下，`AudioBufferList` 里**每个 buffer 是一个通道**，
/// `mDataByteSize / 4` 得到的是**该通道的采样数**。各 buffer 相加得到的是采样总数，
/// 必须再除以通道数才是**帧数**。
///
/// 时长 = 帧数 / 采样率。直接拿采样点数除采样率，在立体声轨上会得出两倍时长。
public struct TrackStats: Equatable, Codable, Sendable {

    public var sampleRate: Double
    public var channels: Int

    /// 累计音频帧数（一帧 = 所有通道在同一时刻的一个采样）
    public var frames: Int

    /// 累计采样总数（各通道相加），仅用于查丢帧，不参与时间换算
    public var totalSamples: Int

    /// 首个 buffer 的起始 hostTime
    public var firstHostTime: UInt64

    /// 最后一个 buffer 的**结束** hostTime
    public var lastHostTime: UInt64

    /// 暂停造成的时钟空档（秒）。
    ///
    /// **必须有这个字段。** 暂停期间不写盘，于是恢复后 `lastHostTime - firstHostTime`
    /// 会比真实录到的内容长出一整段暂停。不扣掉的话：
    /// 「录 5 分钟、中途暂停 10 分钟」会算出 15 分钟时长，`drift` 变成 −600 秒，
    /// 漂移告警直接误报——而这正是本项目最看重的那类「数字看着对、含义全错」。
    public var pausedSeconds: Double

    public init(
        sampleRate: Double,
        channels: Int,
        frames: Int = 0,
        totalSamples: Int = 0,
        firstHostTime: UInt64 = 0,
        lastHostTime: UInt64 = 0,
        pausedSeconds: Double = 0
    ) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.frames = frames
        self.totalSamples = totalSamples
        self.firstHostTime = firstHostTime
        self.lastHostTime = lastHostTime
        self.pausedSeconds = pausedSeconds
    }

    /// 容忍字段缺失，理由同 `TrackManifest.init(from:)`——
    /// 这是会落盘的类型，将来加字段不能让旧文件读不出来。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 48000
        channels = max(1, try c.decodeIfPresent(Int.self, forKey: .channels) ?? 1)
        frames = try c.decodeIfPresent(Int.self, forKey: .frames) ?? 0
        totalSamples = try c.decodeIfPresent(Int.self, forKey: .totalSamples) ?? 0
        firstHostTime = try c.decodeIfPresent(UInt64.self, forKey: .firstHostTime) ?? 0
        lastHostTime = try c.decodeIfPresent(UInt64.self, forKey: .lastHostTime) ?? 0
        pausedSeconds = try c.decodeIfPresent(Double.self, forKey: .pausedSeconds) ?? 0
    }

    /// 字节数 + 通道数 → 帧数
    public static func frames(fromByteCount bytes: Int, channels: Int) -> Int {
        guard channels > 0, bytes > 0 else { return 0 }
        return bytes / MemoryLayout<Float>.size / channels
    }

    /// 按采样点数推算的时长——**只用于比对，不作为时间轴**
    public var sampleDerivedDuration: Double {
        sampleRate > 0 ? Double(frames) / sampleRate : 0
    }

    /// 按 hostTime 推算的**原始时钟跨度**（含暂停空档）。
    ///
    /// 它表示的是「这段录制在墙上时钟里横跨了多久」，不是「录到了多久」。
    /// 判断时间轴、对齐、转写一律用 `clockDuration`。
    public var spanDuration: Double {
        HostClock.secondsBetween(firstHostTime, lastHostTime)
    }

    /// 真正录到的时长（= 音频内容时长）——**这才是时间轴**。
    ///
    /// 等于 `spanDuration` 扣掉暂停空档。暂停期间不写盘，所以音频文件里的
    /// 内容时长就是它，播放、波形、转写稿的秒数全部以此为准。
    ///
    /// 两处夹取都是必要的：`pausedSeconds` 是落盘字段，被手改坏（负数、
    /// 或者大于跨度）时不能让它把内容时长**放大**上去——那会让界面显示的时长
    /// 超过音频本身的长度，且完全看不出是数据坏了。
    public var clockDuration: Double {
        max(0, spanDuration - max(0, pausedSeconds))
    }

    /// 漂移（秒）= 采样推算 − 时钟。正值表示采样比真实时间"多"。
    /// 因为 `clockDuration` 已扣除暂停，暂停本身**不会**污染这个值。
    public var drift: Double { sampleDerivedDuration - clockDuration }

    /// 漂移率（相对时钟时长）。0.002 即 0.2%
    public var driftRatio: Double { clockDuration > 0 ? drift / clockDuration : 0 }

    /// 是否已经有有效数据
    public var isEmpty: Bool { frames == 0 }

    /// 累计一个 buffer
    /// - Parameters:
    ///   - channelByteCounts: 每个 buffer（通道）的字节数
    ///   - startHostTime: 该 buffer 起始 hostTime（来自 AudioTimeStamp.mHostTime）
    public mutating func accumulate(channelByteCounts: [Int], startHostTime: UInt64) {
        guard let first = channelByteCounts.first else { return }
        let frameCount = first / MemoryLayout<Float>.size
        let sampleCount = channelByteCounts.reduce(0) { $0 + $1 / MemoryLayout<Float>.size }
        accumulate(frameCount: frameCount, totalSampleCount: sampleCount, startHostTime: startHostTime)
    }

    /// 直接用帧数累计（采集回调里已经交错化完成时走这条）
    public mutating func accumulate(frameCount: Int, startHostTime: UInt64) {
        accumulate(frameCount: frameCount, totalSampleCount: frameCount * channels,
                   startHostTime: startHostTime)
    }

    private mutating func accumulate(frameCount: Int, totalSampleCount: Int, startHostTime: UInt64) {
        guard frameCount > 0 else { return }

        if frames == 0 { firstHostTime = startHostTime }
        frames += frameCount
        totalSamples += totalSampleCount

        // buffer 结束时刻 = 起始时刻 + 本 buffer 时长
        let bufferSeconds = sampleRate > 0 ? Double(frameCount) / sampleRate : 0
        let tickSeconds = HostClock.nanosecondsPerTick / 1_000_000_000
        let deltaTicks = UInt64((bufferSeconds / max(tickSeconds, .leastNonzeroMagnitude)).rounded())
        lastHostTime = startHostTime &+ deltaTicks
    }
}

/// 双轨漂移比对报告。录制结束时生成，用于判断时间轴是否可信。
public struct DriftReport: Equatable {

    public struct Track: Equatable {
        public var id: String
        public var stats: TrackStats
        public init(id: String, stats: TrackStats) {
            self.id = id
            self.stats = stats
        }
        public var duration: Double { stats.clockDuration }
    }

    public var tracks: [Track]

    public init(tracks: [Track]) { self.tracks = tracks }

    /// 各轨起始时刻之间的最大偏差（秒）。
    ///
    /// ⚠️ 这个值**大不等于出错**。系统音频轨要通过聚合设备启动，
    /// 会比麦克风晚一点（实测在 20 毫秒以内，两阶段启动压制的结果）。
    /// 关键在于：两条轨的时间戳来自**同一个单调时钟**，所以绝对时间轴是同源的，
    /// 转写时按 `TrackAlignment` 做偏移即可对齐，不存在"错位"。
    /// 这个值正确的解读是「共同覆盖窗口之外，只有单边有声音」。
    public var startSkew: Double {
        let starts = tracks.map(\.stats.firstHostTime).filter { $0 > 0 }
        guard let lo = starts.min(), let hi = starts.max() else { return 0 }
        return HostClock.secondsBetween(lo, hi)
    }

    /// 各轨时钟时长的最大差值（秒）
    public var durationSkew: Double {
        let durations = tracks.map(\.duration)
        guard let lo = durations.min(), let hi = durations.max() else { return 0 }
        return hi - lo
    }

    /// 两轨共同覆盖的时长（秒）。只有这段时间内才谈得上「同时发言」。
    public var overlapDuration: Double {
        let valid = tracks.filter { $0.stats.firstHostTime > 0 && $0.stats.lastHostTime > 0 }
        // 单轨录制：全部时长都算覆盖
        if tracks.count <= 1 { return valid.first?.duration ?? 0 }
        // 多轨但有效轨不足：没有共同窗口（某轨完全没数据，通常是权限问题）
        guard valid.count > 1 else { return 0 }
        let lo = valid.map(\.stats.firstHostTime).max()!
        let hi = valid.map(\.stats.lastHostTime).min()!
        return hi > lo ? HostClock.secondsBetween(lo, hi) : 0
    }

    /// 时间轴是否可用。
    ///
    /// 判定依据不是「起点是否一致」（那取决于设备启动速度），
    /// 而是「各轨是否都产出了有效数据」。只要都有数据，时间轴就是同源可用的。
    public var isUsable: Bool {
        let valid = tracks.filter { !$0.stats.isEmpty && $0.stats.firstHostTime > 0 }
        return valid.count == tracks.count
    }
}

/// 多轨时间对齐。
///
/// 每轨的转写结果是相对于**该轨文件起点**的秒数，而各轨起点并不相同
/// （实测两轨首帧 `hostTime` 相差 1～10 ms 量级，方向随设备与启动时序而定——
/// 不要再写死「系统音频轨更晚」，那个断言与实测相反）。
/// 要归并到同一条时间线，必须用 hostTime 算出各轨相对会话基准的偏移。
///
/// 这正是「不能用采样点数推算时间」的落地价值：两轨采样点数量对不上，
/// 但 hostTime 是同一个时钟，一减就得到真实偏移。
public enum TrackAlignment {

    /// 会话时间基准 = 所有有效轨中最早的 firstHostTime
    public static func sessionBase(hostTimes: [UInt64]) -> UInt64 {
        let valid = hostTimes.filter { $0 > 0 }
        return valid.min() ?? 0
    }

    /// 某轨相对会话基准的偏移（秒）。转写结果加上它即对齐到会话时间轴。
    public static func offset(trackFirstHostTime: UInt64, sessionBase: UInt64) -> Double {
        guard trackFirstHostTime > 0, sessionBase > 0 else { return 0 }
        return HostClock.signedSeconds(from: sessionBase, to: trackFirstHostTime)
    }

    /// 把一条轨上的时间点平移会话时间轴
    public static func shift(_ seconds: Double, by offset: Double) -> Double {
        max(0, seconds + offset)
    }
}
