import Foundation

/// 流式 WAV 读取器。
///
/// 存在的理由是「长会议」：一小时双轨录音约 1.4 GB，任何一次
/// `Data(contentsOf:)` 都是拿内存换方便。这里按帧范围随机读，
/// 调用方用固定大小的块循环，峰值内存与文件长度无关。
///
/// 与 `WAVWriter` 对称：`readFrames` 读回的采样必须与写进去的逐点一致
/// （float32 是精确往返；pcm16 有量化误差，见测试）。
public final class WAVReader {

    public let url: URL
    public let info: WAVHeaderInfo
    public let format: WAVSampleFormat

    private var handle: FileHandle?

    public init(url: URL) throws {
        let header = try WAVWriter.readHeader(at: url)

        let resolved: WAVSampleFormat
        switch header.audioFormatID {
        case 3: resolved = .float32
        case 1: resolved = .pcm16
        default:
            throw MRError.invalidWAV(
                path: url.path,
                reason: "不支持的音频格式码 \(header.audioFormatID)（只支持 1=PCM16 / 3=Float32）")
        }
        guard header.channels > 0, header.sampleRate > 0 else {
            throw MRError.invalidWAV(
                path: url.path,
                reason: "通道数或采样率非法（\(header.channels)ch @ \(header.sampleRate)Hz）")
        }
        // 声明的位数与实际格式码不一致时以格式码为准，但记下来供排查
        guard header.bitsPerSample == resolved.bitsPerSample else {
            throw MRError.invalidWAV(
                path: url.path,
                reason: "格式码 \(header.audioFormatID) 与位深 \(header.bitsPerSample) 不匹配")
        }

        self.url = url
        self.info = header
        self.format = resolved
        do { self.handle = try FileHandle(forReadingFrom: url) }
        catch { throw MRError.io(path: url.path, reason: error.localizedDescription) }
    }

    public var channels: Int { info.channels }
    public var sampleRate: Double { info.sampleRate }
    public var frameCount: Int { info.frameCount }
    public var duration: Double { info.duration }

    /// 秒 → 帧（向下取整，落在文件范围内）
    public func frameIndex(forSeconds seconds: Double) -> Int {
        guard seconds > 0, sampleRate > 0 else { return 0 }
        return max(0, min(frameCount, Int((seconds * sampleRate).rounded(.down))))
    }

    /// 读取 `[startFrame, startFrame + count)` 区间，返回**交错**的 Float 采样。
    /// 请求超出文件尾部时返回实际可读部分（不报错）——分段的最后一段天然会多要一点。
    public func readFrames(startingAt startFrame: Int, count: Int) throws -> [Float] {
        guard count > 0, let handle else { return [] }
        let clampedStart = max(0, min(startFrame, frameCount))
        let available = frameCount - clampedStart
        let actual = min(count, available)
        guard actual > 0 else { return [] }

        let byteOffset = UInt64(info.dataOffset + clampedStart * info.bytesPerFrame)
        let byteCount = actual * info.bytesPerFrame
        do {
            try handle.seek(toOffset: byteOffset)
            guard let data = try handle.read(upToCount: byteCount), !data.isEmpty else {
                return []
            }
            return Self.decode(data, format: format)
        } catch let e as MRError {
            throw e
        } catch {
            throw MRError.io(path: url.path, reason: error.localizedDescription)
        }
    }

    /// 按秒范围读取，返回交错的 Float 采样
    public func read(start: Double, end: Double) throws -> [Float] {
        let from = frameIndex(forSeconds: start)
        let to = max(from, frameIndex(forSeconds: end))
        return try readFrames(startingAt: from, count: to - from)
    }

    /// 按块遍历整个文件。回调返回 `false` 可提前中止。
    ///
    /// 这是给静音检测用的：一小时音频要过一遍能量扫描，
    /// 用块循环的真实内存占用是 `chunkFrames × channels × 4` 字节（默认约 0.4 MB）。
    public func forEachChunk(
        chunkFrames: Int = 48000,
        _ body: (_ frames: [Float], _ frameCount: Int, _ offsetSeconds: Double) throws -> Bool
    ) throws {
        var cursor = 0
        while cursor < frameCount {
            let want = min(chunkFrames, frameCount - cursor)
            let samples = try readFrames(startingAt: cursor, count: want)
            guard !samples.isEmpty else { break }
            let got = samples.count / max(1, channels)
            let offset = sampleRate > 0 ? Double(cursor) / sampleRate : 0
            let keepGoing = try body(samples, got, offset)
            cursor += got
            if !keepGoing { break }
        }
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    deinit { close() }

    // MARK: - 解码

    /// 从原始字节解码成交错 Float。
    ///
    /// 刻意用逐字节组装而不是 `bindMemory`：`Data` 不保证 4 字节对齐，
    /// 直接内存绑定是有崩溃风险的做法。
    static func decode(_ data: Data, format: WAVSampleFormat) -> [Float] {
        switch format {
        case .float32:
            let count = data.count / 4
            guard count > 0 else { return [] }
            var out = [Float](repeating: 0, count: count)
            data.withUnsafeBytes { raw in
                for i in 0..<count {
                    let base = i * 4
                    let bits = UInt32(raw[base])
                        | (UInt32(raw[base + 1]) << 8)
                        | (UInt32(raw[base + 2]) << 16)
                        | (UInt32(raw[base + 3]) << 24)
                    out[i] = Float(bitPattern: bits)
                }
            }
            return out

        case .pcm16:
            let count = data.count / 2
            guard count > 0 else { return [] }
            var out = [Float](repeating: 0, count: count)
            data.withUnsafeBytes { raw in
                for i in 0..<count {
                    let base = i * 2
                    let v = UInt16(raw[base]) | (UInt16(raw[base + 1]) << 8)
                    out[i] = Float(Int16(bitPattern: v)) / 32768.0
                }
            }
            return out
        }
    }
}
