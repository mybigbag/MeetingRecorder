import Foundation

/// 分段规划：把「音频文件」直接变成「切点列表」。
///
/// `Segmenter` 本身是纯函数（只吃时长和静音区间），便于测试；
/// 但真正用起来需要的是一条完整链路：读文件 → 扫静音 → 算切点。
/// 这层负责把三者串起来，调用方拿到的就是可以直接切的段。
///
/// 内存特性：全程流式。一小时音频在这里的峰值内存约为
/// `chunkFrames × channels × 4` 字节（默认约 0.4 MB）。
public struct SegmentPlan {

    public struct Outcome {
        /// 切出的段（相对该轨道起点，秒）
        public var segments: [Segmenter.Segment]
        /// 检测到的静音区间（已过滤/收缩），保留用于排查"为什么切在这里"
        public var silences: [ClosedRange<Double>]
        /// 音频总时长
        public var duration: Double
        /// 是否真的需要分段
        public var didSegment: Bool
    }

    public var segmenter: Segmenter
    public var silenceSettings: SilenceDetector.Settings
    /// 扫描静音时的块大小（帧）
    public var chunkFrames: Int

    public init(
        segmenter: Segmenter = Segmenter(),
        silenceSettings: SilenceDetector.Settings = SilenceDetector.Settings(),
        chunkFrames: Int = 48000
    ) {
        self.segmenter = segmenter
        self.silenceSettings = silenceSettings
        self.chunkFrames = chunkFrames
    }

    /// 扫描音频文件并规划切点
    public func plan(forFileAt url: URL) throws -> Outcome {
        let reader = try WAVReader(url: url)
        defer { reader.close() }
        return try plan(reader: reader)
    }

    /// 用已有的 reader 规划（避免二次打开文件）
    public func plan(reader: WAVReader) throws -> Outcome {
        let duration = reader.duration
        guard duration > 0 else {
            return Outcome(segments: [], silences: [], duration: 0, didSegment: false)
        }

        // 短音频不必扫静音——省掉一次全文件读取
        guard duration > segmenter.maxSegment else {
            return Outcome(
                segments: [Segmenter.Segment(start: 0, end: duration)],
                silences: [], duration: duration, didSegment: false)
        }

        let detector = SilenceDetector(
            sampleRate: reader.sampleRate,
            channels: reader.channels,
            settings: silenceSettings)

        try reader.forEachChunk(chunkFrames: chunkFrames) { samples, _, _ in
            detector.append(samples)
            return true
        }
        let silences = detector.finish()

        let segments = segmenter.segment(duration: duration, silences: silences)
        return Outcome(
            segments: segments, silences: silences,
            duration: duration, didSegment: segments.count > 1)
    }
}
