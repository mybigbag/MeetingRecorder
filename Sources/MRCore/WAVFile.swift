import Foundation

/// WAV 采样格式
public enum WAVSampleFormat: String, Codable, CaseIterable, Sendable {
    /// 16-bit 整数 PCM，格式码 1。兼容性最好，体积最小。
    case pcm16
    /// 32-bit IEEE 浮点，格式码 3。录制时无精度损失，无需 clamp。
    case float32

    public var audioFormatID: UInt16 {
        switch self {
        case .pcm16: return 1
        case .float32: return 3
        }
    }

    public var bitsPerSample: Int {
        switch self {
        case .pcm16: return 16
        case .float32: return 32
        }
    }

    public var bytesPerSample: Int { bitsPerSample / 8 }

    /// 完整中文名，用于告警与 CLI 日志。**用户可见的名字只此一处**——
    /// 界面文案和运行期告警各写一套的话，改一处就会让两处对同一件事说不同的话。
    public var displayName: String {
        switch self {
        case .float32: return "32 位浮点"
        case .pcm16:   return "16 位整数 PCM"
        }
    }

    /// 详情页那种「采样率 · 声道 · 位深 · 设备名」挤在一行里的地方用的短名。
    /// 完整名会把这一行顶到截断（`lineLimit(1)`）。
    public var shortDisplayName: String {
        switch self {
        case .float32: return "32 位浮点"
        case .pcm16:   return "16 位"
        }
    }

    /// 从 WAV 头的格式码还原类型。未知码返回 nil，**由调用方决定回落策略**
    /// （读路径应当抛错，算账路径应当回落到 float32）。
    public static func fromAudioFormatID(_ id: UInt16) -> WAVSampleFormat? {
        switch id {
        case 1: return .pcm16
        case 3: return .float32
        default: return nil
        }
    }
}

/// 从 WAV 文件头解析出的信息
///
/// `Sendable`：字段全是值类型，跨线程传它没有别名风险。
/// 加上这个是为了让 `AudioTrackMerger.Input` 能作为 `Sendable` 参与并发编排。
public struct WAVHeaderInfo: Equatable, Sendable {
    public var audioFormatID: UInt16
    public var channels: Int
    public var sampleRate: Double
    public var bitsPerSample: Int
    public var dataSize: Int
    public var dataOffset: Int
    public var fileSize: Int

    public var bytesPerFrame: Int { max(1, channels * (bitsPerSample / 8)) }

    public var frameCount: Int { dataSize / bytesPerFrame }

    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    /// 头部声明的 data 长度与实际文件剩余长度是否一致
    public var isConsistent: Bool {
        dataOffset + dataSize == fileSize
    }
}

/// 流式 WAV 写入器。
///
/// 两个刻意的设计：
/// 1. **录制过程中持续写盘**，不做内存缓冲。会议录音丢一次就再没人用了。
/// 2. **头部长度最后回填**（`finalize()`）。因此崩溃时头部声明的 data 长度会是 0 或过期值，
///    需要用 `repairHeader` 按文件实际大小重建——这是崩溃恢复能成立的前提。
public final class WAVWriter {

    /// 标准 44 字节 RIFF/WAVE 头（fmt chunk 16 字节，不写可选 fact chunk）
    public static let headerSize = 44

    /// 单个 WAV 文件能容纳的最大 data 字节数。
    ///
    /// 这不是随便定的：RIFF 里 `data` chunk 的长度字段只有 4 字节（UInt32），
    /// 且 `RIFF` 总长字段 = 36 + dataSize 也必须落在 UInt32 内。
    /// 一旦越界，`UInt32(dataSize)` 会直接 **trap**——实测进程以 SIGTRAP(133) 崩溃，
    /// 不是写出个坏文件那么温和。
    ///
    /// 换算成时长（两种位深都列出来，因为位深是用户可切换的，
    /// 只写 float32 的数会在 16 位下说少一半）：
    /// - 48kHz 立体声（系统音频轨）：float32 ≈ **3.11 小时**，pcm16 ≈ **6.21 小时**
    /// - 48kHz 单声道（麦克风轨）：float32 ≈ **6.21 小时**，pcm16 ≈ **12.43 小时**
    ///
    /// 此处只作说明，真正对外报的数由 `maxDurationHours(...)` 现算——
    /// GUI 帮助文案与运行期告警共用那一处，不再各写一份。
    ///
    /// 会议通常远达不到，但"录一整天的会议"这种用法会踩到，所以这里显式设限：
    /// 到顶就停止写入并置位 `didReachSizeLimit`，让上层能报警，而不是崩掉。
    public static let maxDataBytes = Int(UInt32.max) - 4096

    public let url: URL
    public let sampleRate: Double
    public let channels: Int
    public let format: WAVSampleFormat
    /// 本文件允许写入的最大 data 字节数（默认 `maxDataBytes`，测试可下调）
    public let dataByteLimit: Int

    private var handle: FileHandle?
    private var dataBytesWritten = 0
    private var finalized = false
    /// 是否因触达 4 GiB 上限而停止写入（此时录制仍在继续，但此后音频已丢弃）
    public private(set) var didReachSizeLimit = false

    public var framesWritten: Int {
        dataBytesWritten / max(1, channels * format.bytesPerSample)
    }

    public var bytesWritten: Int { dataBytesWritten }

    // MARK: - 格式换算

    /// 浮点 → 16 位整数的**唯一**换算处。
    ///
    /// 两处必须共用：`append` 用它写盘，`TrackRecorder` 用同一个函数算「写入后实际生效的
    /// 峰值」。各写一遍的话，「自检说非零、盘上其实是零」这类偏差会悄悄回来。
    ///
    /// NaN / ±∞ 在这里**当静音丢掉**，不依赖 `min`/`max` 的语义：
    /// Swift 的 `min(1.0, .nan)` 返回 `1.0`（不是 NaN），于是 NaN 会被钳成 +1.0 满量程，
    /// 量化成 `Int16(32767)`——听感上是一记爆音，而 32 位浮点路径是原样保留。
    /// 这是 16 位**独有**的失真，必须在入口拦掉。
    public static func quantizeToInt16(_ v: Float) -> Int16 {
        guard v.isFinite else { return 0 }
        let clamped = max(-1.0, min(1.0, v))
        return Int16((clamped * 32767.0).rounded())
    }

    /// 一个采样写进 16 位文件后、**读回来**会是多少（`WAVReader` 按 ÷32768 还原）。
    ///
    /// 自检的峰值判据要用它，否则「整段被量化成 0」的录音会被判成有内容。
    public static func effectiveAfterQuantisation(_ v: Float) -> Float {
        Float(quantizeToInt16(v)) / 32768.0
    }

    /// 按给定参数，单个 WAV 文件最多能录多少小时。
    ///
    /// 参数化而不是写死「约 3.1 小时」：位深是用户可切换的，写死的数在 16 位下会
    /// **说少一半**。而触顶告警是用户判断「还要不要分段」的唯一依据，
    /// GUI 帮助文案与运行期告警共用这一处。
    public static func maxDurationHours(
        sampleRate: Double,
        channels: Int,
        format: WAVSampleFormat,
        dataByteLimit: Int = WAVWriter.maxDataBytes
    ) -> Double {
        let bytesPerSecond = sampleRate * Double(channels) * Double(format.bytesPerSample)
        guard bytesPerSecond > 0 else { return 0 }
        return Double(dataByteLimit) / bytesPerSecond / 3600
    }

    /// 本文件（按自己的采样率/声道/位深/上限）最多能录多少小时
    public var maxDurationHours: Double {
        Self.maxDurationHours(sampleRate: sampleRate, channels: channels,
                              format: format, dataByteLimit: dataByteLimit)
    }

    public init(
        url: URL,
        sampleRate: Double,
        channels: Int,
        format: WAVSampleFormat = .float32,
        dataByteLimit: Int = WAVWriter.maxDataBytes
    ) throws {
        guard sampleRate > 0 else {
            throw MRError.invalidWAV(path: url.path, reason: "采样率必须为正数，收到 \(sampleRate)")
        }
        guard channels > 0 else {
            throw MRError.invalidWAV(path: url.path, reason: "通道数必须为正数，收到 \(channels)")
        }

        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        self.format = format
        self.dataByteLimit = max(0, min(dataByteLimit, Self.maxDataBytes))

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw MRError.io(path: url.path, reason: "无法创建文件")
            }
        }
        do {
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: 0)
            try h.write(contentsOf: Self.makeHeader(
                sampleRate: sampleRate,
                channels: channels,
                format: format,
                dataSize: 0))
            self.handle = h
        } catch let e as MRError {
            throw e
        } catch {
            throw MRError.io(path: url.path, reason: error.localizedDescription)
        }
    }

    // MARK: - 写入

    /// 追加浮点采样。交错（interleaved）顺序：L R L R ...
    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        try samples.withUnsafeBufferPointer { try append($0.baseAddress!, count: $0.count) }
    }

    /// 追加浮点采样（裸指针，避免额外拷贝——采集回调里每秒会走 48 次）
    ///
    /// 触达 4 GiB 上限时**截断写入并置位**，绝不越过——越界会让收尾时的
    /// `UInt32(dataSize)` 直接崩溃。
    public func append(_ samples: UnsafePointer<Float>, count: Int) throws {
        guard count > 0, let handle else { return }

        let bytesPerSample = format.bytesPerSample
        let room = dataByteLimit - dataBytesWritten
        guard room > 0 else {
            didReachSizeLimit = true
            return
        }

        // 可用空间按采样对齐（不足一个采样的尾巴丢弃）
        let maxSamples = room / bytesPerSample
        let effectiveCount = min(count, maxSamples)
        if effectiveCount < count { didReachSizeLimit = true }
        guard effectiveCount > 0 else { return }

        let data: Data
        switch format {
        case .float32:
            data = Data(bytes: samples, count: effectiveCount * bytesPerSample)
        case .pcm16:
            var converted = [Int16](repeating: 0, count: effectiveCount)
            for i in 0..<effectiveCount {
                converted[i] = Self.quantizeToInt16(samples[i])
            }
            data = converted.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        do {
            try handle.write(contentsOf: data)
            dataBytesWritten += data.count
        } catch {
            throw MRError.io(path: url.path, reason: error.localizedDescription)
        }
    }

    /// 回填头部真实长度并落盘。正常结束必须调用。
    public func finalize() throws {
        guard !finalized, let handle else { return }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.makeHeader(
                sampleRate: sampleRate,
                channels: channels,
                format: format,
                dataSize: dataBytesWritten))
            try handle.synchronize()
            finalized = true
        } catch {
            throw MRError.io(path: url.path, reason: error.localizedDescription)
        }
    }

    public func close() {
        try? finalize()
        try? handle?.close()
        handle = nil
    }

    /// 放弃收尾：关闭句柄但**不回填头部**，刻意留下「头是空的、数据是全的」现场。
    /// 用于模拟进程被杀，也用于录制失败时保留原始数据待恢复。
    public func abort() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        finalized = true
    }

    deinit { close() }

    // MARK: - 头部

    public static func makeHeader(
        sampleRate: Double,
        channels: Int,
        format: WAVSampleFormat,
        dataSize: Int
    ) -> Data {
        // 防御性夹取：UInt32 越界会 trap，宁可写一个被截断的头也不要崩。
        // 正常情况下 append 已保证不会越界，这里是最后一道闸。
        let safeDataSize = max(0, min(dataSize, maxDataBytes))
        let byteRate = Int(sampleRate) * channels * format.bytesPerSample
        let blockAlign = channels * format.bytesPerSample
        var d = Data()

        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        d.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(headerSize - 8 + safeDataSize))   // RIFF chunk size = 总长 - 8
        d.append(contentsOf: Array("WAVE".utf8))

        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)                                     // PCM 子块固定 16 字节
        u16(format.audioFormatID)
        u16(UInt16(clamping: channels))
        u32(UInt32(clamping: Int(sampleRate)))
        u32(UInt32(clamping: byteRate))
        u16(UInt16(clamping: blockAlign))
        u16(UInt16(format.bitsPerSample))

        d.append(contentsOf: Array("data".utf8))
        u32(UInt32(safeDataSize))

        return d
    }

    // MARK: - 读取与修复

    public static func readHeader(at url: URL) throws -> WAVHeaderInfo {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw MRError.io(path: url.path, reason: error.localizedDescription) }

        guard data.count >= headerSize else {
            throw MRError.invalidWAV(path: url.path, reason: "文件不足 \(headerSize) 字节（实际 \(data.count)）")
        }
        guard data[0..<4].elementsEqual(Array("RIFF".utf8)),
              data[8..<12].elementsEqual(Array("WAVE".utf8)) else {
            throw MRError.invalidWAV(path: url.path, reason: "缺少 RIFF/WAVE 标识")
        }

        func u32(_ offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        func u16(_ offset: Int) -> UInt16 {
            data[offset..<(offset + 2)].reversed().reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        }

        // 遍历 chunk 找 fmt 和 data（容忍可选 fact / LIST chunk）
        var cursor = 12
        var fmtFound = false
        var info = WAVHeaderInfo(
            audioFormatID: 0, channels: 0, sampleRate: 0, bitsPerSample: 0,
            dataSize: 0, dataOffset: headerSize, fileSize: data.count)

        while cursor + 8 <= data.count {
            let id = String(bytes: data[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
            let size = Int(u32(cursor + 4))
            let body = cursor + 8
            if id == "fmt ", body + 16 <= data.count {
                info.audioFormatID = u16(body)
                info.channels = Int(u16(body + 2))
                info.sampleRate = Double(u32(body + 4))
                info.bitsPerSample = Int(u16(body + 14))
                fmtFound = true
            } else if id == "data" {
                info.dataOffset = body
                // 声明的长度若超过实际剩余，按实际剩余截断（崩溃场景）
                info.dataSize = min(size, max(0, data.count - body))
            }
            cursor = body + size + (size % 2)   // chunk 按偶数字节对齐
        }

        guard fmtFound else {
            throw MRError.invalidWAV(path: url.path, reason: "缺少 fmt chunk")
        }
        return info
    }

    /// 崩溃后修复：按文件实际长度重算 data 长度并回填头部。
    /// 返回修复后的头信息。
    @discardableResult
    public static func repairHeader(at url: URL) throws -> WAVHeaderInfo {
        var info = try readHeader(at: url)
        let actualDataSize = max(0, info.fileSize - info.dataOffset)
        guard actualDataSize != info.dataSize else { return info }   // 头本来就对

        info.dataSize = actualDataSize

        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: url) }
        catch { throw MRError.io(path: url.path, reason: error.localizedDescription) }

        defer { try? handle.close() }
        do {
            // 定位 data chunk 的长度字段：dataOffset - 4 处起 4 字节
            try handle.seek(toOffset: UInt64(info.dataOffset - 4))
            // 用 clamping 而非直接转换：损坏文件的实际长度可能超过 UInt32，
            // 直接转会 trap，而修复流程本身不该崩。
            var le = UInt32(clamping: actualDataSize).littleEndian
            try handle.write(contentsOf: withUnsafeBytes(of: &le) { Data($0) })
            // RIFF 总长 = 文件长度 - 8
            try handle.seek(toOffset: 4)
            var riff = UInt32(clamping: info.fileSize - 8).littleEndian
            try handle.write(contentsOf: withUnsafeBytes(of: &riff) { Data($0) })
            try handle.synchronize()
        } catch {
            throw MRError.io(path: url.path, reason: error.localizedDescription)
        }
        return info
    }
}
