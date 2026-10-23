import Foundation

/// 双轨合并成一个可播放的文件。
///
/// ## 为什么要做这个
///
/// 会议录音分成两轨（麦克风 / 系统音频）是对的：说话人分得清、可以分别调音量。
/// 但要把会议**发给别人**时，对方要的是「一个文件」，不是两个。
/// 现状下唯一的办法是自己拼：拖进音频编辑器、手工对齐、导出——
/// 而「对齐」这一步最容易出错，出错的后果（两人声音错开几十毫秒）听的人未必能立刻发现。
///
/// ## 为什么默认是「立体声左右分置」而不是「混成单声道」
///
/// 默认把**麦克风放左声道、系统音频放右声道**，而不是平均成单声道：
///
/// - **不丢信息**。平均之后两人同时说话就会互相掩盖，且不可逆。
/// - 收听方用耳机可以分开听两个人，用音箱也能听清（左右各归其位）。
/// - 想听单声道的人，任何播放器的「下混」都能做，不必由我们替他决定。
///
/// `Mode.monoMix` 保留给「确实要混成一路」的场景（比如塞进只支持单声道的设备）。
///
/// ## 为什么必须做偏移对齐
///
/// 两轨的起点**不在同一时刻**（实测首帧 `hostTime` 相差 1～10 ms；
/// 系统音频 tap 冷启动慢的那几场能到 1 秒以上，方向随设备与时序而异）。
/// 合并若不补偿，对方的话会整体早/晚一个可听的量——听起来像「回声」或「抢话」。
///
/// 偏移取自 `manifest` 的 `firstHostTime`，与转写归并时间轴用的是**同一份逻辑**
/// （`TrackAlignment`），所以「听到的」与「文稿里的」必然对齐。
///
/// 保留偏移（而不是把晚开始的那轨拉到 0 秒）是刻意的：那一段本来就没人说话，
/// 抹平它会让合并结果与文稿时间轴对不上。
public enum AudioTrackMerger {

    // MARK: - 输出形态

    /// 合并方式。
    public enum Mode: String, CaseIterable, Sendable {
        /// 立体声：第 1 轨 → 左，第 2 轨 → 右（默认）
        case stereoSplit
        /// 单声道：所有轨平均混成一路
        case monoMix

        public var displayName: String {
            switch self {
            case .stereoSplit: return "立体声分置（我=左 / 对方=右）"
            case .monoMix: return "单声道混合（所有人混成一路）"
            }
        }

        public var hint: String {
            switch self {
            case .stereoSplit:
                return "不丢信息。耳机里能分开听两个人说话。"
            case .monoMix:
                return "两人同时说话会互相掩盖，且**不可逆**。只推荐在确实只支持单声道时用。"
            }
        }
    }

    /// 输出位深。
    public enum OutputFormat: String, CaseIterable, Sendable {
        /// 16 位整数 PCM。发给别人时的默认选择：任何设备都能播，体积减半。
        case pcm16
        /// 32 位浮点无损。体积是 16 位的两倍。
        case float32

        public var sampleFormat: WAVSampleFormat {
            switch self {
            case .pcm16: return .pcm16
            case .float32: return .float32
            }
        }
    }

    /// 一条输入轨。
    public struct Input: Equatable, Sendable {
        public var url: URL
        public var header: WAVHeaderInfo
        public var format: WAVSampleFormat
        /// 相对会话基准的偏移（秒）。正数 = 这一轨比基准晚开始。
        public var offsetSeconds: Double
        /// 展示名（报错与报告用）
        public var label: String

        public init(url: URL, header: WAVHeaderInfo, format: WAVSampleFormat,
                    offsetSeconds: Double, label: String) {
            self.url = url
            self.header = header
            self.format = format
            self.offsetSeconds = offsetSeconds
            self.label = label
        }
    }

    /// 一次合并的结果账。
    public struct Result: Equatable, Sendable {
        public var framesWritten: Int
        public var sampleRate: Double
        public var channels: Int
        /// 输出文件里的最大绝对采样值（按写盘后实际生效的值算）。
        public var peakAmplitude: Float
        /// 各输入轨单独的平均绝对值。**用来发现「有一轨其实没录到」**——
        /// 合并后总体有声音，不代表每轨都有声音（本机真实会议库里就有 3 场是空的）。
        public var perTrackRMS: [Float]
        public var labels: [String]

        public var duration: Double {
            sampleRate > 0 ? Double(framesWritten) / sampleRate : 0
        }

        /// RMS 低于这个值基本等于静音。0.0005 ≈ -66 dBFS。
        public static let silenceRMSThreshold: Float = 0.0005

        /// 哪些轨实际上是静音的。
        public func silentTracks() -> [String] {
            labels.enumerated().compactMap { i, name in
                perTrackRMS[i] < Self.silenceRMSThreshold ? name : nil
            }
        }
    }

    // MARK: - 决策（纯函数，可单测）

    /// 输出采样率。
    ///
    /// 取各轨的**最小值**——与 `TrackWriteFormat.resolve` 同一条纪律：**绝不升采样**。
    /// 本项目里麦克风常是 24 kHz、系统音频是 48 kHz；升到 48 k 不会多出任何信息，
    /// 只会让文件变大、并让本已占带宽的麦克风轨凭空多出一半数据。
    public static func resolveOutputSampleRate(_ inputs: [Input]) -> Double {
        inputs.map(\.header.sampleRate).min() ?? 48000
    }

    /// 输出声道数。
    public static func resolveOutputChannels(mode: Mode, trackCount: Int) -> Int {
        switch mode {
        case .stereoSplit: return min(2, max(1, trackCount))
        case .monoMix: return 1
        }
    }

    /// 合并结果的时长（秒）。
    ///
    /// 取「所有轨里最晚结束的那个」：`offset + duration` 的最大值。
    /// 不是取最长音频那条——一条轨既短又晚结束时，会议的**结束时刻**由它决定。
    /// 两种模式都按这个算：偏移是要保留的，抹平它会让结果与文稿时间轴对不上。
    public static func resolveDuration(outputSampleRate: Double,
                                       inputs: [Input],
                                       mode: Mode) -> Double {
        inputs.map { $0.offsetSeconds + $0.header.duration }.max() ?? 0
    }

    /// 某一轨在输出文件里占据的帧区间。
    ///
    /// 抽成纯函数是因为「偏移 → 帧」是最容易取整出错的一处，
    /// 而它错了的后果是整轨错位几十毫秒——听起来像回声，却没人能指出是哪一步错的。
    public static func frameRange(of input: Input,
                                  outputSampleRate: Double,
                                  mode: Mode) -> (start: Int, end: Int) {
        let ratio = outputSampleRate / max(1, input.header.sampleRate)
        // 该轨在输出率下能产出的帧数（不含重采样尾部，尾部单独补）
        let frames = Int((Double(input.header.frameCount) * ratio).rounded(.down))
        let start = max(0, Int((input.offsetSeconds * outputSampleRate).rounded()))
        return (start, start + frames)
    }

    // MARK: - 合并

    /// 合并到 `destination`。流式，峰值内存与音频长度无关。
    ///
    /// - Parameter downmix: 多声道输入降成一路时用哪种策略。
    public static func merge(inputs: [Input],
                             destination: URL,
                             mode: Mode = .stereoSplit,
                             format: OutputFormat = .pcm16,
                             downmix: MonoDownmixStrategy = .firstChannel,
                             chunkFrames: Int = 48000) throws -> Result {
        guard !inputs.isEmpty else {
            throw MRError.invalidArgument("没有可合并的音轨")
        }
        for input in inputs where input.header.frameCount == 0 {
            throw MRError.invalidWAV(
                path: input.url.path,
                reason: "\(input.label) 这条轨一帧都没有（文件只有 44 字节头）")
        }

        let outRate = resolveOutputSampleRate(inputs)
        let outChannels = resolveOutputChannels(mode: mode, trackCount: inputs.count)
        let sampleFormat = format.sampleFormat

        // 这里**不需要**「拒绝升采样」那道 guard（`AudioTranscoder` 里有一道）：
        // `outRate` 是所有轨的最小值，所以「某轨采样率 > outRate」在本模块里
        // 是**常态**（48 kHz 的系统轨 + 24 kHz 的麦克风轨 → outRate=24000，
        // 那条 48 kHz 轨当然「高于」输出，正是要降下去的那一条）。
        // 写这种 guard 会把正常路径判成错误——实测第一次就是这么把
        // `testMixedSourceSampleRatesBothLandAtTheCommonRate` 顶红的。
        // 升采样的纪律由 `resolveOutputSampleRate` 取最小值这一处保证。

        let duration = resolveDuration(outputSampleRate: outRate, inputs: inputs, mode: mode)
        let totalFrames = Int((duration * outRate).rounded())
        guard totalFrames > 0 else {
            throw MRError.invalidArgument("合并后长度为 0 秒，没有可写的内容")
        }

        let ranges = inputs.map {
            frameRange(of: $0, outputSampleRate: outRate, mode: mode)
        }
        // 每条轨写进哪个输出声道，以及该声道分摊到几轨（求和会削顶，必须平均）。
        let placement = inputs.indices.map { i -> (channel: Int, shares: Int) in
            guard outChannels > 1 else { return (0, inputs.count) }
            let side = i % 2
            let shares = inputs.indices.filter { $0 % 2 == side }.count
            return (side, shares)
        }

        let writer = try WAVWriter(url: destination, sampleRate: outRate,
                                   channels: outChannels, format: sampleFormat)

        var readers: [WAVReader] = []
        do {
            for input in inputs { readers.append(try WAVReader(url: input.url)) }
        } catch {
            writer.abort()
            throw error
        }

        var streams = inputs.indices.map { i -> TrackStream in
            TrackStream(input: inputs[i],
                        reader: readers[i],
                        downmix: downmix,
                        targetSampleRate: outRate)
        }

        var peak: Float = 0
        var written = 0

        do {
            while written < totalFrames {
                let want = min(chunkFrames, totalFrames - written)
                var block = [Float](repeating: 0, count: want * outChannels)

                for i in streams.indices {
                    // 本块内该轨占据的输出帧区间
                    let from = max(ranges[i].start, written)
                    let to = min(ranges[i].end, written + want)
                    guard to > from else { continue }
                    let usable = to - from

                    let samples = try streams[i].pull(outputFrames: usable,
                                                      startOffset: from - ranges[i].start)
                    guard !samples.isEmpty else { continue }

                    let channel = placement[i].channel
                    let share = Float(placement[i].shares)
                    for (n, s) in samples.enumerated() {
                        // 峰值按「写进 16 位文件后读回来会是多少」算，
                        // 这样报告的峰值与盘上真实内容一致（否则整段被量化成 0
                        // 的素材会报出一个源里才有的假峰值）。
                        if sampleFormat == .pcm16 {
                            let e = WAVWriter.effectiveAfterQuantisation(s)
                            let a = e < 0 ? -e : e
                            if a > peak { peak = a }
                        } else {
                            let a = s < 0 ? -s : s
                            if a > peak { peak = a }
                        }
                        // ⚠️ 写进 `block` 的必须是**原始浮点** `s`，不是量化后的值。
                        // `writer.append` 内部本来就会调 `quantizeToInt16`，
                        // 这里再先量化一次就成了**双重量化**：每次各丢 1 LSB，
                        // pcm16 源的样本会被啃掉 2 LSB。
                        // 实测（真实会议库 2026-09-27-202956，24 kHz pcm16 双轨合并）
                        // 145 万样本里 6235 个（0.44%）与源差 ±2，就是这么来的。
                        // 「量化后读回」只用于**测量**，不用于**写入**。
                        let base = (from - written + n) * outChannels + channel
                        guard base < block.count else { break }
                        // 单声道混合必须**累加**，各轨写的是同一格。
                        // 写成覆盖（`=`）的话后一轨会抹掉前一轨，
                        // 结果既不是混合、也只剩一半音量——实测 0.8 + 0.8 出来 0.4。
                        if share > 1 { block[base] += s / share } else { block[base] = s }
                    }
                }
                try writer.append(block)
                written += want
            }

            // 尾部：把各轨重采样器的余量排空。零相位 FIR 的尾部约半个窗宽
            // （48k→24k 约 0.67 ms），不排的话最后半个字会被切掉。
                var leftovers: [[Float]] = []
                for i in streams.indices { leftovers.append(streams[i].drain()) }
                if !leftovers.allSatisfy(\.isEmpty) {
                    let extra = leftovers.map(\.count).max() ?? 0
                    var tail = [Float](repeating: 0, count: extra * outChannels)
                    for (i, samples) in leftovers.enumerated() {
                        let channel = placement[i].channel
                        let share = Float(placement[i].shares)
                        for (n, s) in samples.enumerated() {
                            // 与主循环同一道纪律：峰值按量化后算（与盘上内容一致），
                            // 写入用原始浮点（`append` 内部会量化一次，重复量化会啃样本）。
                            if sampleFormat == .pcm16 {
                                let e = WAVWriter.effectiveAfterQuantisation(s)
                                let a = e < 0 ? -e : e
                                if a > peak { peak = a }
                            } else {
                                let a = s < 0 ? -s : s
                                if a > peak { peak = a }
                            }
                            // 与主循环同一道纪律：单声道下必须累加，不是覆盖。
                            let base = n * outChannels + channel
                            if share > 1 { tail[base] += s / share } else { tail[base] = s }
                        }
                    }
                    try writer.append(tail)
                }

            try writer.finalize()
        } catch {
            writer.abort()
            throw error
        }

        return Result(framesWritten: writer.framesWritten,
                      sampleRate: outRate,
                      channels: outChannels,
                      peakAmplitude: peak,
                      perTrackRMS: streams.map { $0.rootMeanSquare },
                      labels: inputs.map(\.label))
    }

    /// 每轨的流式读取状态。
    ///
    /// 重采样器是**推入式且有状态**的，所以不能随机取源区间——
    /// 必须按时间顺序推。因此这里维护一个「已重采样但还没写出去」的缓冲 `pending`，
    /// 由 `pull` 按需求量续推。
    private struct TrackStream {
        let input: Input
        let reader: WAVReader
        let downmix: MonoDownmixStrategy
        let targetSampleRate: Double
        var resampler: AudioResampler
        var sourceCursor = 0
        var pending: [Float] = []
        var pendingOffset = 0
        var sumSquares: Double = 0
        var sampleCount = 0

        init(input: Input, reader: WAVReader, downmix: MonoDownmixStrategy,
             targetSampleRate: Double) {
            self.input = input
            self.reader = reader
            self.downmix = downmix
            self.targetSampleRate = targetSampleRate
            self.resampler = AudioResampler(
                sourceSampleRate: input.header.sampleRate,
                targetSampleRate: targetSampleRate)
        }

        var rootMeanSquare: Float {
            sampleCount > 0 ? Float((sumSquares / Double(sampleCount)).squareRoot()) : 0
        }

        /// 取 `count` 个输出采样，从该轨自己的第 `startOffset` 个输出采样开始。
        ///
        /// - Returns: 能给的都给；源已排空时返回空数组，调用方写静音。
        ///   **不会**为了凑满 `count` 而编造采样。
        mutating func pull(outputFrames count: Int, startOffset: Int) throws -> [Float] {
            // 跳到请求位置之前的内容必须先算出来（重采样器不能跳着走）
            //
            // `refill()` 返回 false 表示源已排空。这个判断**不能省**：
            // 源读完后再调 `refill()` 不会往 pending 里加任何东西，
            // 循环条件永远为真 → 死循环（本模块第一版就挂在这里，
            // 被 24 kHz + 48 kHz 那条真实混合采样率的用例当场抓出来）。
            while pendingOffset + pending.count < startOffset + count {
                guard try refill() else { break }
            }
            let from = startOffset - pendingOffset
            guard from >= 0, from < pending.count else {
                // 源已排空：返回能给的，剩下的留空（调用方写静音）
                return []
            }
            let n = min(count, pending.count - from)
            let slice = Array(pending[from..<(from + n)])
            pending.removeFirst(from + n)
            pendingOffset += from + n
            for s in slice {
                sumSquares += Double(s) * Double(s)
                sampleCount += 1
            }
            return slice
        }

        /// 排空重采样器尾部。幂等。
        mutating func drain() -> [Float] {
            let tail = resampler.flush()
            guard !tail.isEmpty else { return [] }
            for s in tail {
                sumSquares += Double(s) * Double(s)
                sampleCount += 1
            }
            return tail
        }

        /// 再取一批源样本推进重采样器。
        ///
        /// - Returns: `false` 表示**源已排空**，调用方必须停止再试
        ///   （`resampler.process` 在没有新输入时不会产出任何东西，
        ///   不看这个返回值就会变成死循环）。
        private mutating func refill() throws -> Bool {
            let remaining = reader.frameCount - sourceCursor
            guard remaining > 0 else { return false }
            let want = min(48000, remaining)
            let raw = try reader.readFrames(startingAt: sourceCursor, count: want)
            guard !raw.isEmpty else {
                sourceCursor = reader.frameCount
                return false
            }
            sourceCursor += want
            let mono = reader.channels == 1
                ? raw
                : MonoDownmix.mix(raw, channels: reader.channels, strategy: downmix)
            pending.append(contentsOf: resampler.process(mono))
            return true
        }
    }
}
