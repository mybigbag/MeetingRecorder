import Foundation
import MRCore

/// 「一个音频文件 → 一组 `TranscriptSegment`」的完整实现。
///
/// 独立成一层（而不是塞进 `SenseVoiceTranscriptionEngine`）的理由：这里是可以
/// **在没有资产、没有网络**的环境里被完整测到的部分——把子进程换成假对象，
/// 参数拼装、退出码判定、SRT 映射、清洗、诊断信息全都跑得起来。
/// 引擎那一层剩下的只是「资产就绪与否」的门槛判断。
public struct SenseVoiceInference {

    public struct Outcome: Sendable {
        public var segments: [TranscriptSegment]
        /// 逐轨诊断信息。会流到 CLI 的输出与 GUI 的日志里——
        /// 「有哪些段落被丢了、有几条可疑短段」必须说出来，不能安静地少几条。
        public var notes: [String]
    }

    public let paths: SenseVoicePaths
    private let runner: any SenseVoiceProcessRunning
    private let environment: [String: String]
    private let bundle: Bundle

    public init(
        paths: SenseVoicePaths = SenseVoicePaths(),
        runner: any SenseVoiceProcessRunning = SenseVoiceProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) {
        self.paths = paths
        self.runner = runner
        self.environment = environment
        self.bundle = bundle
    }

    /// 转写一个音频文件。
    ///
    /// - 退出码非 0 → 抛错（信息里带 runtime 的 stderr 尾部）
    /// - 退出码 0 + 空输出 → **返回空数组**。真机实测：整段静音时运行时就是
    ///   exit 0 + 0 字节，这不是失败，是「确实没有语音」。
    ///   把这两种情况混为一谈，会让一场安静的会议显示成「转写失败」。
    public func transcribe(
        fileURL: URL,
        trackID: String,
        speaker: String
    ) async throws -> Outcome {

        let asset = SenseVoiceAssets.runtime
        guard let runtime = paths.resolveRuntimeBinary(
            environment: environment, bundle: bundle) else {
            throw MRError.transcription(
                reason: "找不到推理运行时（\(asset.fileName)，\(asset.humanSize)）。"
                    + "请先执行 `meeting-recorder model install-runtime`"
                    + "（可用仓库内副本，通常不需要联网），"
                    + "或用环境变量 \(SenseVoicePaths.runtimeOverrideKey) 指定一个。")
        }

        let modelURL = paths.url(for: SenseVoiceAssets.model)
        let vadURL = paths.url(for: SenseVoiceAssets.vad)
        for required in [modelURL, vadURL] {
            guard SenseVoiceModelStore.fileExists(at: required) else {
                throw MRError.transcription(
                    reason: "缺少模型资产：\(required.path)。"
                        + "请先执行 `meeting-recorder model download`"
                        + "（约 \(String(format: "%.0f", Double(SenseVoiceAssets.downloadableByteCount) / 1_048_576)) MiB）。")
            }
        }

        // 参数顺序无关紧要，但**必须全部是绝对路径**：子进程的工作目录不由我们决定，
        // 相对路径会解析到别的地方去。
        let arguments = [
            "-m", modelURL.path,
            "--vad", vadURL.path,
            "--srt",
            "-a", fileURL.path,
        ]

        let result = try await runner.run(executable: runtime, arguments: arguments)
        var notes: [String] = []

        if let vadSegments = Self.vadSegmentCount(in: result.standardError) {
            notes.append("SenseVoice：VAD 切出 \(vadSegments) 段")
        }
        if let seconds = Self.elapsedSeconds(in: result.standardError) {
            notes.append("SenseVoice 推理耗时 \(seconds)s")
        }

        guard result.exitCode == 0 else {
            let detail = Self.tail(of: result.standardError, lines: 4)
            throw MRError.transcription(
                reason: "SenseVoice 退出码 \(result.exitCode)"
                    + (result.terminatedBySignal ? "（被信号终止）" : "")
                    + (detail.isEmpty ? "，且没有输出诊断信息" : "：\n\(detail)"))
        }

        let parsed = SenseVoiceSRTParser.parse(result.standardOutput)
        if parsed.skippedBlocks > 0 {
            notes.append("跳过 \(parsed.skippedBlocks) 个无法解析的字幕块（缺时间码）")
        }
        if parsed.invertedTimestamps > 0 {
            notes.append("\(parsed.invertedTimestamps) 条字幕的时间码倒挂，已把结束时间夹到开始时间")
        }

        let cleanup = SenseVoiceCaptionFilter.clean(parsed.captions)
        if cleanup.droppedEmpty > 0 {
            notes.append("丢弃 \(cleanup.droppedEmpty) 条纯标点空段（无实义字符）")
        }
        if cleanup.suspiciouslyShort > 0 {
            notes.append("可疑短段 \(cleanup.suspiciouslyShort) 条（多出现在非语音段，已保留未删除）")
        }
        // 整轨「只有极短文本」时再补一句，把成因讲清楚：否则用户看到几行 `He.` / `い。`
        // 只会以为软件坏了，或者以为这就是录音内容。
        if let note = Self.shortOnlyNote(
            kept: cleanup.captions.count, short: cleanup.suspiciouslyShort) {
            notes.append(note)
        }

        let segments = cleanup.captions.map { caption in
            TranscriptSegment(
                start: caption.start,
                end: max(caption.start, caption.end),
                text: caption.text,
                track: trackID,
                speaker: speaker)
        }
        return Outcome(segments: segments, notes: notes)
    }

    // MARK: - 整轨判据

    /// 某轨「只有极短文本、没有任何成句内容」时给出的一条注记；否则 `nil`。
    ///
    /// **为什么是注记而不是丢弃**——这是量出来的，不是想出来的。真机实测两场录音
    /// （`docs/接入-SenseVoice推理.md` §五）：
    ///
    /// | | 段 | RMS |
    /// |---|---|---|
    /// | 无语音录音上的幻觉 | `He.` / `い。` / `一。` | **-41.4 ~ -55.6 dBFS** |
    /// | 真实会议里最静的真实短句 | `然后。` / `啊。` / `Oh.` / `好。` | **-40.7 ~ -52.5 dBFS** |
    ///
    /// 两者**几乎完全重叠**：任何「按能量丢段」的阈值都会同时删掉真话。
    /// 而「被删掉的那句用户永远不会知道」比多几行噪声严重得多，所以清洗层
    /// 一条不删（见 `SenseVoiceCaptionFilter`）。
    ///
    /// 能安全说的是**事实层面**的东西：「该轨只检出 N 条极短文本、没有任何成句内容」
    /// 是可验证的描述，不是猜测；成因（近静音/非语音上的模型幻觉）是本项目实测过的
    /// 已知现象，这里如实讲出来，但**断言权交给用户**——让他去对照录音。
    static func shortOnlyNote(kept: Int, short: Int) -> String? {
        guard kept > 0, kept == short else { return nil }
        return "该轨只检出 \(kept) 条极短文本、没有任何成句内容"
            + "——近静音或非语音输入上 SenseVoice 会产出这类幻觉文本，请对照录音确认"
    }

    // MARK: - stderr 诊断提取

    /// 从 `[sensevoice] 140 vad segments` 这一行取出 `140`。
    ///
    /// 手写而不用正则：输入形态固定，而正则在格式稍有变化时会**静默地什么都不匹配**——
    /// 诊断信息本身不该是一个会悄悄失效的东西。取**最后**一次出现是因为长音频会分段
    /// 处理，末尾那条才是全量统计。
    static func vadSegmentCount(in stderr: String) -> Int? {
        for line in stderr.split(separator: "\n").reversed() {
            guard let range = line.range(of: " vad segments") else { continue }
            let head = String(line[line.startIndex..<range.lowerBound])
            guard let token = head.split(separator: " ").last, let value = Int(token) else { continue }
            return value
        }
        return nil
    }

    /// 从 `[sensevoice] done 10.48s` 取出 `10.48`（原样字符串，不做数值化）。
    static func elapsedSeconds(in stderr: String) -> String? {
        for line in stderr.split(separator: "\n").reversed() {
            guard let range = line.range(of: "done ") else { continue }
            let tail = line[range.upperBound...]
            guard let seconds = tail.split(separator: "s").first, Double(seconds) != nil else { continue }
            return String(seconds)
        }
        return nil
    }

    /// stderr 的最后几行非空内容，用于错误信息。
    ///
    /// 取尾部而不是头部：运行时把「模型加载 → VAD → 构图 → 计算」按顺序打出来，
    /// 真正失败的那一步永远是最后一条。
    static func tail(of text: String, lines: Int) -> String {
        let nonEmpty = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return "" }
        return nonEmpty.suffix(lines).joined(separator: "\n")
    }
}
