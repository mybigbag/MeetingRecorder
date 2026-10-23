import Foundation
import MRCore

/// 整场会议导出成一个可播放的文件。
///
/// ## 为什么不直接让 CLI 调 `AudioTrackMerger`
///
/// 因为「把两轨对成一个文件」有三件事只有在**整场**层面才知道，
/// 而它们恰好都是这个功能最容易做错的地方：
///
/// 1. **偏移从 manifest 来，不是从文件名或采样点数来。**
///    两轨采样点数对不上（各自采集起止不同），但 `firstHostTime` 是同一个时钟，
///    一减就得到真实偏移。用采样点数推算会得到「差了几百毫秒」的错位结果。
/// 2. **合并结果不能被当成第三条轨。** 目录里多一个 `.wav` 就可能被用户或工具
///    当成音频轨，所以文件名与落盘位置都要明确，且**不写进 manifest**。
/// 3. **「有一轨其实没录到」必须说出来。** 本机真实会议库里有 3 场的 system 轨
///    是 100% 静音（当时系统音频采集没起来）。合并后总体有声音，
///    用户不会发现对方那一路是空的——直到需要回听对方说了什么。
public struct SessionAudioExporter {

    public let store: SessionStore

    /// 合并结果的默认文件名后缀。
    ///
    /// 带 `merged` 字样而不是中文「合并」：这个名字会出现在 Finder、
    /// 可能被脚本按 `*.wav` 收集，ASCII 更安全，且一眼能看出是产物而不是原始录音。
    public static let mergedFileSuffix = "-merged"

    public init(store: SessionStore) {
        self.store = store
    }

    /// 合并前的账。**一个字节都不写。**
    public struct Plan: Equatable, Sendable {
        public var sessionID: String
        public var title: String
        public var inputs: [AudioTrackMerger.Input]
        public var missingTracks: [String]
        public var outputName: String
        public var mode: AudioTrackMerger.Mode
        public var format: AudioTrackMerger.OutputFormat
        public var destination: URL
        public var outputSampleRate: Double
        public var outputChannels: Int
        public var duration: Double
        /// 输入各轨的字节数合计（估体积用）
        public var sourceBytes: Int
        /// 预计输出字节数
        public var estimatedBytes: Int

        /// 少于两轨 → 合并没有意义（用户要的就是「把两条并成一条」）
        public var isNotApplicable: Bool { inputs.count < 2 }
    }

    /// 算一遍「合并后会怎样」，不写任何字节。
    public func plan(sessionID: String,
                     mode: AudioTrackMerger.Mode = .stereoSplit,
                     format: AudioTrackMerger.OutputFormat = .pcm16,
                     destination override: URL? = nil) throws -> Plan {
        let manifest = try store.loadManifest(forSessionID: sessionID)
        let dir = store.directory(forSessionID: sessionID)
        let sessionBase = TrackAlignment.sessionBase(hostTimes: manifest.tracks.map(\.firstHostTime))

        var inputs: [AudioTrackMerger.Input] = []
        var missing: [String] = []
        for t in manifest.tracks {
            let file = store.trackURL(sessionDirectory: dir, fileName: t.fileName)
            guard FileManager.default.fileExists(atPath: file.path) else {
                missing.append(t.id)
                continue
            }
            let header = try WAVWriter.readHeader(at: file)
            let sourceFormat = AudioTranscoder.sourceFormat(of: header)
            inputs.append(AudioTrackMerger.Input(
                url: file,
                header: header,
                format: sourceFormat,
                offsetSeconds: TrackAlignment.offset(trackFirstHostTime: t.firstHostTime,
                                                     sessionBase: sessionBase),
                label: t.id))
        }

        let outRate = AudioTrackMerger.resolveOutputSampleRate(inputs)
        let outChannels = AudioTrackMerger.resolveOutputChannels(mode: mode,
                                                                  trackCount: inputs.count)
        let duration = AudioTrackMerger.resolveDuration(outputSampleRate: outRate,
                                                        inputs: inputs, mode: mode)
        let name = Self.mergedFileName(title: manifest.title)
        let dest = override ?? dir.appendingPathComponent(name)
        let frames = Int((duration * outRate).rounded())
        let sourceBytes = inputs.reduce(0) {
            $0 + $1.header.fileSize
        }

        return Plan(sessionID: sessionID, title: manifest.title, inputs: inputs,
                    missingTracks: missing, outputName: name, mode: mode, format: format,
                    destination: dest, outputSampleRate: outRate,
                    outputChannels: outChannels, duration: duration,
                    sourceBytes: sourceBytes,
                    estimatedBytes: WAVWriter.headerSize + frames * outChannels
                        * format.sampleFormat.bytesPerSample)
    }

    public static func mergedFileName(title: String) -> String {
        "\(title)\(mergedFileSuffix).wav"
    }

    // MARK: - 执行

    public struct Outcome: Equatable, Sendable {
        public var sessionID: String
        public var destination: URL
        public var result: AudioTrackMerger.Result?
        public var failed: String?
        public var notes: [String]
        /// 合并产物**没有**写进 manifest——它不是一条轨。
        /// 这个字段显式记下来，是为了让「产物不进 manifest」这条纪律可被断言。
        public var manifestTouched: Bool

        public var isSuccess: Bool { result != nil && failed == nil }
    }

    /// 合并一场。
    ///
    /// - Parameter overwrite: 目标已存在时是否覆盖。默认**不覆盖**——
    ///   合并产物可能是用户花时间等出来的，静默覆盖掉别人的成果比报错更糟。
    public func merge(sessionID: String,
                      mode: AudioTrackMerger.Mode = .stereoSplit,
                      format: AudioTrackMerger.OutputFormat = .pcm16,
                      destination override: URL? = nil,
                      overwrite: Bool = false) throws -> Outcome {
        let plan = try plan(sessionID: sessionID, mode: mode, format: format, destination: override)
        var notes: [String] = []

        // 缺轨检查**必须在**「轨数不足」之前。
        //
        // 顺序反了会把「本来有两条、丢了一条」报成「只有一条，合并没有意义」——
        // 用户听到这句话只会以为自己本来就只录了一条，而真实情况是**文件不见了**。
        // 同一个报错句式，两种完全不同的处境，猜错方向就会让人白找半天。
        if !plan.missingTracks.isEmpty {
            throw MRError.io(path: plan.destination.path,
                             reason: "以下音轨的文件不在盘上："
                                + "\(plan.missingTracks.joined(separator: "、"))。"
                                + "缺轨合并出来的文件会让人以为对方那一路没说话。"
                                + "如果音频确实不需要了，用 `transcode --all` 那类"
                                + "接受缺轨的操作，或先删掉 manifest 里那条记录。")
        }
        guard plan.inputs.count >= 2 else {
            throw MRError.invalidArgument(
                "\(plan.sessionID) 只有 \(plan.inputs.count) 条可用音轨，合并没有意义。"
                + "合并是把两条并成一条；只有一条时直接用原文件就好。")
        }

        if FileManager.default.fileExists(atPath: plan.destination.path) {
            guard overwrite else {
                throw MRError.io(
                    path: plan.destination.path,
                    reason: "目标文件已存在。加 --overwrite 覆盖，或换一个输出路径。")
            }
            try FileManager.default.removeItem(at: plan.destination)
        }

        let result = try AudioTrackMerger.merge(
            inputs: plan.inputs,
            destination: plan.destination,
            mode: plan.mode,
            format: plan.format)

        // 「有一轨其实是静音」必须说出来。合并后总体有声音，用户不会自己发现
        // 对方那一路是空的——本机真实会议库里有 3 场正是这种情况。
        let silent = result.silentTracks()
        if !silent.isEmpty {
            notes.append("这些轨在源文件里就是静音的（通常是当时系统音频采集没起来）："
                + silent.joined(separator: "、")
                + "。合并文件里对应的那一路没有声音，不是合并出错。")
        }
        // 偏移补偿的幅度报出来：用户能据此判断「该轨是不是慢了很多」。
        let offsets = zip(plan.inputs, result.labels).map { input, label in
            (label, input.offsetSeconds)
        }
        for (label, offset) in offsets where abs(offset) >= 0.05 {
            notes.append(String(format: "%@ 相对会议起点晚 %.2f 秒，合并时已按 hostTime 对齐",
                                label, offset))
        }
        if FileManager.default.fileExists(
            atPath: store.directory(forSessionID: sessionID)
                .appendingPathComponent(SessionStore.transcriptMarkdownName).path) {
            notes.append("这场已有转写稿。文稿里的时间轴与合并文件同源（都按 hostTime 对齐），"
                + "可以直接对照着听。")
        }

        return Outcome(sessionID: sessionID, destination: plan.destination,
                       result: result, failed: nil, notes: notes,
                       manifestTouched: false)
    }
}
