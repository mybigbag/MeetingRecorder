import Foundation

/// 采集回调里「写盘之前」那一段变换：**降混 → 重采样**。
///
/// 单独抽成一个值类型，是为了把本轮**唯一要动采集关键路径**的逻辑从实时回调里搬出来，
/// 变成可单测的纯逻辑。`TrackRecorder.handle()` 现在只剩三件事：
/// 加锁、把交错缓冲交给本管线、把管线产物交给 writer——不含任何格式判断。
///
/// 放在 `MRCore` 而不是 `MRC Capture`：它不依赖 CoreAudio、不依赖设备，
/// 是纯 DSP，应该能和别的纯类型一起被无头环境测到。
///
/// **量化不在这里。** 管线输出始终是 `Float`；pcm16 的量化留在 `WAVWriter`。
/// 两处都做一次量化会让 `TrackRecorder.effectiveSample` 的峰值判据失准
/// （它假设「写入后实际生效的值」只被量化影响一次）。
public struct TrackSamplePipeline: Sendable {

    /// 源（设备）采样率
    public let sourceSampleRate: Double
    /// 源（设备）声道数
    public let sourceChannels: Int
    /// 写进文件的格式
    public let writeFormat: TrackWriteFormat
    public let downmixStrategy: MonoDownmixStrategy

    private var resampler: AudioResampler

    /// **源格式与写入格式完全相同**——此时 `process` 原样返回输入，一个采样都不动。
    ///
    /// 这是「不开开关时行为与改动前逐字节一致」的落点：管线参与进来但不产生任何影响。
    /// 不这么写的话（比如无条件走一遍重采样），即使比例是 1:1 也会因为
    /// 各处的取整与浮点往返引入误差，`WAVFileTests` 里那些逐样本往返断言会集体变红。
    public var isIdentity: Bool {
        sourceChannels == writeFormat.channels && sourceSampleRate == writeFormat.sampleRate
    }

    /// - Note: 本管线只实现「**合并到单声道 + 重采样**」一种变换，以及「不变换」。
    ///   这是 `TrackWriteFormat.resolve` 实际能产出的全部组合：开关打开必然落到单声道，
    ///   开关关闭则与源格式完全相同。`TrackRecorder.init` 会对不在此列的组合直接抛错，
    ///   而不是让这里静默按单声道写出去。
    public init(
        sourceSampleRate: Double,
        sourceChannels: Int,
        writeFormat: TrackWriteFormat,
        downmixStrategy: MonoDownmixStrategy = .firstChannel
    ) {
        self.sourceSampleRate = sourceSampleRate
        self.sourceChannels = max(1, sourceChannels)
        self.writeFormat = writeFormat
        self.downmixStrategy = downmixStrategy
        self.resampler = AudioResampler(
            sourceSampleRate: sourceSampleRate,
            targetSampleRate: writeFormat.sampleRate)
    }

    /// 推入一段**源格式**的交错采样，取出该写盘的**写入格式**交错采样。
    public mutating func process(_ interleaved: [Float]) -> [Float] {
        guard !interleaved.isEmpty else { return [] }
        if isIdentity { return interleaved }

        // 源已经是单声道时不做降混——`MonoDownmix.mix` 也短路返回原数组，
        // 这里的判断是为了让「有没有走过降混」在代码上看得见。
        let mono = sourceChannels == 1
            ? interleaved
            : MonoDownmix.mix(interleaved, channels: sourceChannels, strategy: downmixStrategy)

        // **相位抵消必须在这里查，而不是等录完再看文件。**
        // 症状是 `average` 遇到反相内容（某些播放器的输出就是 L = −R）时
        // 整段变静音，而帧数、时长、manifest 全部正常 —— 事后没有任何线索能指向原因。
        // 实时路径上唯一能救的就是当场记下来、收尾时报出去。
        if MonoDownmix.isPhaseCancelled(
            source: interleaved, mixed: mono,
            channels: sourceChannels, strategy: downmixStrategy) {
            didCancel = true
        }

        // 写入为单声道时，重采样后的结果本身就是交错结果
        return resampler.process(mono)
    }

    /// 本管线是否**发生过相位抵消**。
    ///
    /// 单向：一旦为 true 就永远是 true（不试图「恢复」）。
    /// 判一次就够 —— 抵消是内容固有的属性而不是偶发事件，
    /// 反复上报同一条只会把别的告警淹掉。
    public private(set) var didCancel = false

    /// 排空重采样器的尾部。`TrackRecorder.stop()` 在回填 WAV 头之前调用。
    ///
    /// 不调用的话文件尾部会短掉约半个窗宽的源样本（48 kHz 下约 0.67 ms），
    /// 表现为「文件时长比采集时长少一丁点」，核对时间轴时要多花一轮去排除它。
    public mutating func flush() -> [Float] {
        isIdentity ? [] : resampler.flush()
    }
}
