import Foundation

/// 波形包络：把整条音轨压成固定条数的**峰值**，供界面绘制波形。
///
/// 为什么取峰值而不是均值：语音波形大部分时间贴着零，取均值会把整条压成一根平线，
/// 看不出任何结构。峰值保留的正是唯一有用的那点信息——「这个时间窗里有没有声音」。
///
/// 为什么值得单独一个类型：算包络要过一遍整个 WAV，13 分钟的录音就是几百 MB。
/// 调用方必须能在后台线程跑它，且内存占用与文件长度无关（内部走 `WAVReader.forEachChunk` 流式读）。
public enum WaveformEnvelope {

    /// 计算结果。
    ///
    /// `peaks` 已按 `referenceAmplitude` 归一化到 0...1，可以直接拿去画。
    /// `referenceAmplitude` 是归一化**之前**的最大绝对采样值，界面必须把它显示出来：
    /// 否则一条极轻的音轨会被放大到和正常音量一样高，那是视觉上的谎报。
    public struct Envelope: Equatable, Sendable {

        public var peaks: [Float]
        public var referenceAmplitude: Float

        public init(peaks: [Float], referenceAmplitude: Float) {
            self.peaks = peaks
            self.referenceAmplitude = referenceAmplitude
        }

        /// 没有内容的包络（全零音轨、空文件）。授权未生效时录出来的就是这种。
        public static func silent(buckets: Int) -> Envelope {
            Envelope(peaks: [Float](repeating: 0, count: max(0, buckets)), referenceAmplitude: 0)
        }

        /// 整条一条平线，没有任何非零采样。
        public var isSilent: Bool { referenceAmplitude == 0 }
    }

    /// 读一遍 WAV 并算出 `buckets` 个峰值。
    ///
    /// **会碰磁盘，不要在主线程调**。内存占用与文件长度无关。
    /// `buckets` 为 0 或负数时返回空包络；文件没有任何帧时返回全零包络
    /// （而不是空数组——界面拿到固定条数才好直接画）。
    public static func compute(from url: URL, buckets: Int) throws -> Envelope {
        guard buckets > 0 else { return .silent(buckets: 0) }

        let reader = try WAVReader(url: url)
        defer { reader.close() }

        let totalFrames = reader.frameCount
        guard totalFrames > 0 else { return .silent(buckets: buckets) }

        let channels = max(1, reader.channels)
        var peaks = [Float](repeating: 0, count: buckets)
        var reference: Float = 0
        var globalFrame = 0

        try reader.forEachChunk { samples, frameCount, _ in
            for offset in 0..<frameCount {
                let base = offset * channels
                guard base + channels <= samples.count else { break }

                // 多通道取绝对值最大的那个：立体声两通道内容可能不同，
                // 只看 0 通道会漏掉只出现在右声道的声音。
                var magnitude: Float = 0
                for channel in 0..<channels {
                    let value = abs(samples[base + channel])
                    if value > magnitude { magnitude = value }
                }
                if magnitude > reference { reference = magnitude }

                // 整数分桶：`index * buckets / totalFrames` 让各桶首尾相接、不重不漏，
                // 除不尽的余数自然落到最后一个桶里。
                let bucket = (globalFrame + offset) * buckets / totalFrames
                if magnitude > peaks[bucket] { peaks[bucket] = magnitude }
            }
            globalFrame += frameCount
            return true
        }

        // 归一化。`reference` 为 0 时不做除法，直接留全 0——判据与 `RecordingSanity`
        // 一致：那里判「全零」也是严格等于 0，**不用「够不够响」**，
        // 因为对方只敲键盘同样是有效内容，按响度筛会把真实内容判没。
        if reference > 0 {
            for index in peaks.indices { peaks[index] /= reference }
        }
        return Envelope(peaks: peaks, referenceAmplitude: reference)
    }
}
