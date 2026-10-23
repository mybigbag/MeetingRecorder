import Foundation

/// 离线把已录好的 WAV 转成另一种格式（降位深 / 降采样 / 降声道）。
///
/// ## 为什么复用 `TrackSamplePipeline` 而不是 `AVAudioConverter`
///
/// 这是本文件最重要的一个决定。转码与实时录制**走同一条 DSP**
/// （`MonoDownmix` → `AudioResampler` → `WAVWriter`），于是有一件事从「需要验证」
/// 变成「结构上不可能出错」：
///
/// > 「用 `transcode` 转出来的文件，和当初开着 B 档实时录出来的文件，
///  是不是同一种格式、同一套数字？」
///
/// 答案不再取决于两条代码路径是否恰好一致，而是它们**本来就是同一段代码**。
/// 换成 `AVAudioConverter` 就会多出一条独立实现，anti-aliasing 参数、声道混合公式、
/// 位深舍入三处都可能与实时路径不同，而这类差异只在真机上才暴露。
///
/// ## 为什么不整文件读进内存
///
/// 一小时双轨录音约 1.4 GB，存量 22 场合计 3.28 GiB。这里按固定块流式处理，
/// 峰值内存约 `chunkFrames × channels × 4` 字节（默认 0.4 MB），与文件长度无关。
///
/// ## 硬约束
///
/// - **永不升采样**：目标采样率必须 ≤ 源。插值不会凭空造出信息，只会让文件变大。
/// - **源与目标完全相同时拒绝转码**，而不是产出一个逐字节相同的副本——
///   后者会让用户以为「转过了」，而 manifest 里的格式字段其实一个字节都没变。
/// - **量化只在 `WAVWriter` 一处**：管线输出始终是 `Float`，两处都量化会让峰值判据失准。
public enum AudioTranscoder {

    // MARK: - 预设档

    /// 一个预设档。刻意复用 A / B 档的命名，让「录的时候选什么 = 转的时候选什么」。
    public enum Preset: String, CaseIterable, Sendable {
        /// 32 位浮点 + 源采样率与声道数（无损，体积最大）
        case lossless32
        /// 16 位整数 PCM + 源采样率与声道数（A 档）
        case pcm16
        /// 16 位整数 PCM + 单声道 24 kHz（A + B 档叠加）
        case bTier

        public var displayName: String {
            switch self {
            case .lossless32: return "32 位浮点 · 保留源采样率与声道"
            case .pcm16: return "16 位整数 PCM · 保留源采样率与声道（A 档）"
            case .bTier: return "16 位整数 PCM · 单声道 24 kHz（A + B 档）"
            }
        }

        /// 一句话说明收益，**必须带前提**。
        ///
        /// 报数不带前提是本项目已经踩过的坑：6.0× 的成立条件是「两轨源都是 48 kHz」，
        /// 而实测 AirPods 麦克风只给 24 kHz 单声道，双轨只有 4.99×。
        public var hint: String {
            switch self {
            case .lossless32:
                return "体积不会变小，只是把位深写回 32 位（用于还原已转成 16 位的录音）"
            case .pcm16:
                return "体积约减一半，精度减半。实际省多少取决于文件当前已是几位"
            case .bTier:
                return "体积约降至 1/6（源为 48 kHz 立体声时）。"
                    + "若源本来就是 24 kHz 单声道，只省得下位深那一半"
            }
        }
    }

    // MARK: - 目标格式

    /// 转码目标：位深 + 采样率 + 声道数三者齐全。
    public struct Target: Equatable, Sendable {
        public var sampleRate: Double
        public var channels: Int
        public var format: WAVSampleFormat

        public init(sampleRate: Double, channels: Int, format: WAVSampleFormat) {
            self.sampleRate = max(1, sampleRate)
            self.channels = max(1, channels)
            self.format = format
        }

        public var writeFormat: TrackWriteFormat {
            TrackWriteFormat(sampleRate: sampleRate, channels: channels)
        }

        /// `16 位 · 24000 Hz · 单声道` 这种写法，给 CLI 与 manifest 报错信息用。
        public var shortName: String {
            "\(format.shortDisplayName) · \(Int(sampleRate)) Hz · "
                + (channels == 1 ? "单声道" : "\(channels) 声道")
        }

        public func isSameFormat(asSourceRate sourceRate: Double,
                                 sourceChannels: Int,
                                 sourceFormat: WAVSampleFormat) -> Bool {
            sampleRate == sourceRate && channels == sourceChannels && format == sourceFormat
        }
    }

    /// 由预设 + 源格式推出目标。纯函数，可单测。
    public static func target(for preset: Preset, source: WAVHeaderInfo) -> Target {
        switch preset {
        case .lossless32:
            return Target(sampleRate: source.sampleRate,
                          channels: source.channels, format: .float32)
        case .pcm16:
            return Target(sampleRate: source.sampleRate,
                          channels: source.channels, format: .pcm16)
        case .bTier:
            // 与实时录制走同一个决策函数，所以「转码出来的格式」与
            // 「开着 B 档录出来的格式」不可能不一致。
            let write = TrackWriteFormat.resolve(sourceSampleRate: source.sampleRate,
                                                 sourceChannels: source.channels,
                                                 mono24k: true)
            return Target(sampleRate: write.sampleRate, channels: write.channels, format: .pcm16)
        }
    }

    /// 从 WAV 头的格式码取位深。
    ///
    /// 认不出的码**回落到 `.float32`** 而不是抛错，理由与 `TrackManifest` 的容错解码
    /// 同一句：宁可按最可能的那个解释，也不要让整场会议读不出来。
    /// 真要严格校验，`WAVReader.init` 已经在解析时抛过错了——那是「读」路径的事；
    /// 这里服务的是「读一个头部来算账」的路径，抛错会让批量预估整体失败。
    public static func sourceFormat(of header: WAVHeaderInfo) -> WAVSampleFormat {
        WAVSampleFormat.fromAudioFormatID(header.audioFormatID) ?? .float32
    }

    // MARK: - 结果

    /// 一次转码的完整账：既是校验依据，也是 CLI 汇报的数据来源。
    public struct TranscodeResult: Equatable, Sendable {
        /// 走预设进来时是那个预设；通过显式 `Target` 入口进来时为 nil
        /// （此时只有目标格式是真的，preset 只是个名字，硬填一个反而会说谎）。
        public var preset: Preset?
        public var sourceSampleRate: Double
        public var sourceChannels: Int
        public var sourceFormat: WAVSampleFormat
        public var target: Target
        public var sourceFrames: Int
        public var targetFrames: Int
        /// 目标文件里的最大绝对采样值（按写盘后实际生效的值算，16 位考虑量化）。
        public var peakAmplitude: Float
        /// 源文件里的最大绝对采样值。
        ///
        /// **必须有它，否则「源本来就是静音」会被误判成「转码坏了」**——
        /// 判据只能是 `源有声音 且 目标全零` 才算故障。本项目真实会议库里就有 3 条
        /// 100% 静音轨（系统音频采集没起来留下的空轨），只判目标峰值的话，
        /// 它们永远转不了、每次批量都报错，而实际上转成什么格式都一样（全零）。
        public var sourcePeakAmplitude: Float
        public var downmix: MonoDownmixStrategy

        public init(
            preset: Preset?,
            sourceSampleRate: Double,
            sourceChannels: Int,
            sourceFormat: WAVSampleFormat,
            target: Target,
            sourceFrames: Int,
            targetFrames: Int,
            peakAmplitude: Float,
            downmix: MonoDownmixStrategy,
            sourcePeakAmplitude: Float = 0
        ) {
            self.preset = preset
            self.sourceSampleRate = sourceSampleRate
            self.sourceChannels = sourceChannels
            self.sourceFormat = sourceFormat
            self.target = target
            self.sourceFrames = sourceFrames
            self.targetFrames = targetFrames
            self.peakAmplitude = peakAmplitude
            self.downmix = downmix
            self.sourcePeakAmplitude = sourcePeakAmplitude
        }

        /// 「转码把声音弄丢了」——**唯一的判据**。
        ///
        /// 曾经写成 `peakAmplitude <= 0 && sourceFrames > 0`，那会在源本身全静音时报成故障，
        /// 而 E 档整库实跑时被 3 条真实静音轨当场打脸。源有内容而目标全零才是坏。
        public var lostSignal: Bool {
            sourceFrames > 0 && sourcePeakAmplitude > 0 && peakAmplitude <= 0
        }

        /// 源本身一条样本都没有。
        public var sourceIsEmpty: Bool { sourceFrames <= 0 }

        /// 源本身是全静音（但有帧）。转码结果也必然是静音——**这是正常结果**。
        public var sourceIsSilent: Bool {
            sourceFrames > 0 && sourcePeakAmplitude <= 0
        }

        public var sourceBytes: Int {
            WAVWriter.headerSize + sourceFrames * sourceChannels * sourceFormat.bytesPerSample
        }

        public var targetBytes: Int {
            WAVWriter.headerSize + targetFrames * target.channels * target.format.bytesPerSample
        }

        /// 目标 / 源。0.167 ≈ 1/6。
        public var sizeFactor: Double {
            guard sourceBytes > 0 else { return 1 }
            return Double(targetBytes) / Double(sourceBytes)
        }

        public var savedBytes: Int { max(0, sourceBytes - targetBytes) }

        public var sourceDuration: Double {
            sourceSampleRate > 0 ? Double(sourceFrames) / sourceSampleRate : 0
        }

        public var targetDuration: Double {
            target.sampleRate > 0 ? Double(targetFrames) / target.sampleRate : 0
        }

        /// 时长差（目标 − 源，秒）。转码**必须**保持时长。
        /// 24k/48k 写反会让它正好差一倍——这是最容易验也最容易出错的一项。
        public var durationDelta: Double { targetDuration - sourceDuration }

        /// 降采样是否发生了（只降位深 / 只降声道时为 false）。
        public var isResampled: Bool { target.sampleRate != sourceSampleRate }

        public var sourceFormatName: String {
            "\(sourceFormat.shortDisplayName) · \(Int(sourceSampleRate)) Hz · "
                + (sourceChannels == 1 ? "单声道" : "\(sourceChannels) 声道")
        }
    }

    // MARK: - 预估（一个字节都不写）

    /// 「转完能省多少」——**只算不读**。
    ///
    /// 批量迁移必须先能便宜地把账算清楚：存量 3.28 GiB，逐场真转一遍再发现不划算就太晚了。
    /// 体积只由格式决定（`44 + 帧数 × 声道 × 位深`），所以这里不碰音频内容就能给出准确字节数。
    public static func estimate(source: WAVHeaderInfo,
                                preset: Preset,
                                sourceFormat: WAVSampleFormat) -> TranscodeResult {
        let target = target(for: preset, source: source)
        // 帧数比 = 采样率比（降声道只影响每帧字节数，不影响帧数）
        let ratio = source.sampleRate > 0 ? target.sampleRate / source.sampleRate : 1
        let targetFrames = max(0, Int((Double(source.frameCount) * ratio).rounded()))
        // 零相位 FIR 会在尾部多补约半个窗宽（129 抽头 → 64 源样本），
        // 这里刻意**不算**它：预估要往小了报，那几十个样本留给真实转码去补。
        return TranscodeResult(
            preset: preset,
            sourceSampleRate: source.sampleRate,
            sourceChannels: source.channels,
            sourceFormat: sourceFormat,
            target: target,
            sourceFrames: source.frameCount,
            targetFrames: targetFrames,
            peakAmplitude: 0,
            downmix: .average)
    }

    // MARK: - 执行

    /// 转码一个文件。`destination` 必须**不存在**（调用方负责先写临时名、再原子替换）。
    ///
    /// - Parameter chunkFrames: 每次读多少**帧**。默认 48000 帧 ≈ 1 秒，
    ///   峰值内存约 `48000 × channels × 4` 字节（立体声约 0.4 MB），与文件长度无关。
    @discardableResult
    public static func transcode(
        source sourceURL: URL,
        destination: URL,
        preset: Preset,
        downmix: MonoDownmixStrategy = .firstChannel,
        chunkFrames: Int = 48000
    ) throws -> TranscodeResult {
        let reader = try WAVReader(url: sourceURL)
        defer { reader.close() }
        return try transcode(
            reader: reader,
            sourceSampleRate: reader.info.sampleRate,
            sourceChannels: reader.info.channels,
            sourceFormat: reader.format,
            sourceFrames: reader.info.frameCount,
            destination: destination,
            target: target(for: preset, source: reader.info),
            downmix: downmix,
            chunkFrames: chunkFrames)
    }

    /// 核心实现：**目标格式由调用方显式给出**。
    ///
    /// 之所以把 `Target` 从预设里拆出来单独一层：`Preset` 永远不会产出升采样，
    /// 于是「拒绝升采样」那道 guard 用预设路径**根本测不到**——不可达的分支等于没有分支。
    /// 显式入口让测试能构造出一个升采样的 `Target`，把那道 guard 钉住。
    @discardableResult
    public static func transcode(
        reader: WAVReader,
        sourceSampleRate: Double,
        sourceChannels: Int,
        sourceFormat: WAVSampleFormat,
        sourceFrames: Int,
        destination: URL,
        target: Target,
        downmix: MonoDownmixStrategy = .firstChannel,
        chunkFrames: Int = 48000
    ) throws -> TranscodeResult {
        // 源与目标完全相同 → 拒绝。这不是「转码成功」，是「无事可做」，
        // 产出一个逐字节相同的副本只会让 manifest 看起来更新过了而已。
        if target.isSameFormat(asSourceRate: sourceSampleRate,
                               sourceChannels: sourceChannels,
                               sourceFormat: sourceFormat) {
            throw MRError.invalidArgument(
                "源文件已经是 \(target.shortName)，转码不会有任何变化。"
                + "换个预设，或确认这条轨是否已经转过")
        }
        // 与 `TrackRecorder.init` 的那道 guard 同一条纪律：绝不升采样。
        // 预设路径到不了这里（`TrackWriteFormat.resolve` 取 `min`），所以这道 guard
        // 挡的是「将来有人绕过预设直接构造 Target」——和实时路径同一条理由。
        guard target.sampleRate <= sourceSampleRate else {
            throw MRError.invalidArgument(
                "不支持升采样（源 \(Int(sourceSampleRate)) Hz → 目标 \(Int(target.sampleRate)) Hz）")
        }

        var pipeline = TrackSamplePipeline(
            sourceSampleRate: sourceSampleRate,
            sourceChannels: sourceChannels,
            writeFormat: target.writeFormat,
            downmixStrategy: downmix)

        let writer = try WAVWriter(url: destination,
                                   sampleRate: target.sampleRate,
                                   channels: target.channels,
                                   format: target.format)

        // 峰值按「写盘之后实际生效的值」算（16 位要考虑量化），
        // 否则转码报告里的 peak 与录制时的 peak 口径不同，两处数字没法互相印证。
        var peak: Float = 0
        func trackPeak(_ samples: [Float]) {
            for s in samples {
                let v = target.format == .pcm16 ? WAVWriter.effectiveAfterQuantisation(s) : s
                let m = v < 0 ? -v : v
                if m > peak { peak = m }
            }
        }
        // 源峰值单独记：判据必须是「源有声音而目标全零」才算坏，
        // 否则源本身全静音的轨会被永远判成故障（E 档整库实跑时被真实静音轨打脸）。
        var sourcePeak: Float = 0
        func trackSourcePeak(_ samples: [Float]) {
            for s in samples {
                let m = s < 0 ? -s : s
                if m > sourcePeak { sourcePeak = m }
            }
        }

        do {
            try reader.forEachChunk(chunkFrames: chunkFrames) { samples, _, _ in
                trackSourcePeak(samples)
                let out = pipeline.process(samples)
                if !out.isEmpty {
                    trackPeak(out)
                    try writer.append(out)
                }
                return true
            }
            // 排空 FIR 尾部。不排的话文件尾部会短掉约半个窗宽（48 kHz 下约 0.67 ms），
            // 而「文件时长比源时长少一丁点」会让人在核对时间轴时多花一轮去排除它。
            let tail = pipeline.flush()
            if !tail.isEmpty {
                trackPeak(tail)
                try writer.append(tail)
            }
            try writer.finalize()
        } catch {
            // 失败必须留下「原文件完整、目标文件明确」的状态：
            // `abort()` 让半成品自己删掉自己，调用方只需管好原文件。
            writer.abort()
            throw error
        }

        return TranscodeResult(
            preset: nil,
            sourceSampleRate: sourceSampleRate,
            sourceChannels: sourceChannels,
            sourceFormat: sourceFormat,
            target: target,
            sourceFrames: sourceFrames,
            targetFrames: writer.framesWritten,
            peakAmplitude: peak,
            downmix: downmix,
            sourcePeakAmplitude: sourcePeak)
    }
}
