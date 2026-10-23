import Foundation

/// 按时间范围从 WAV 中切出片段，写成独立 WAV。
///
/// 为什么需要它：转写引擎只接受**文件**（`start(inputAudioFile:)`），
/// 所以要分段转写就必须把每一段真正落成文件。切片是分段链路里
/// 唯一不可省的 IO 环节。
///
/// 实现上按块搬运而非整段读入：一段 5 分钟的 48kHz 立体声 float32 约 115 MB，
/// 分块处理让内存峰值与段长无关。
public enum AudioSlicer {

    /// 把 `source` 的 `[start, end)` 秒区间写到 `destination`。
    ///
    /// - Returns: 切片后的头部信息（可用 `frameCount` / `duration` 校验）
    @discardableResult
    public static func slice(
        source: URL,
        to destination: URL,
        start: Double,
        end: Double,
        chunkFrames: Int = 48000
    ) throws -> WAVHeaderInfo {
        let reader = try WAVReader(url: source)
        defer { reader.close() }

        let fromFrame = reader.frameIndex(forSeconds: start)
        let toFrame = max(fromFrame, reader.frameIndex(forSeconds: end))
        let total = toFrame - fromFrame

        let writer = try WAVWriter(
            url: destination,
            sampleRate: reader.sampleRate,
            channels: reader.channels,
            format: reader.format)

        var cursor = 0
        while cursor < total {
            let want = min(chunkFrames, total - cursor)
            let samples = try reader.readFrames(startingAt: fromFrame + cursor, count: want)
            guard !samples.isEmpty else { break }
            try writer.append(samples)
            cursor += samples.count / max(1, reader.channels)
        }
        try writer.finalize()
        writer.close()

        return try WAVWriter.readHeader(at: destination)
    }

    /// 从文件解析出的可切分信息（供调用方决定要不要分段，不必再开一次 reader）
    public struct SourceInfo: Equatable {
        public var duration: Double
        public var sampleRate: Double
        public var channels: Int
        public var format: WAVSampleFormat

        public init(duration: Double, sampleRate: Double, channels: Int, format: WAVSampleFormat) {
            self.duration = duration
            self.sampleRate = sampleRate
            self.channels = channels
            self.format = format
        }
    }

    public static func inspect(_ url: URL) throws -> SourceInfo {
        let reader = try WAVReader(url: url)
        defer { reader.close() }
        return SourceInfo(
            duration: reader.duration,
            sampleRate: reader.sampleRate,
            channels: reader.channels,
            format: reader.format)
    }
}
