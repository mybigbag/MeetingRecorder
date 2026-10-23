import Foundation
import Speech
import AVFoundation
import CoreMedia
import MRCore

/// 苹果原生本地转写（macOS 26 `SpeechAnalyzer` / `SpeechTranscriber`）。
///
/// 实测特性：
/// - **零模型下载**：zh-CN 的语言资产随系统提供，`AssetInventory` 按需拉取
/// - **极快**：258 秒音频耗时 1.6 秒（约 160 倍实时），走神经引擎
/// - **不请求 volatile 结果**：批处理只要稳定的 FINAL 段落，一次拿到带时间范围的完整句段
///
/// 已知限制（如实记录，不粉饰）：
/// - 对音色敏感。实测同一句中文，Tingting 合成语音识别完全正确，
///   而 Eddy 合成语音整段识别失败。真人语音通常更好，但口音重、环境吵会掉分。
/// - 无法喂术语表/热词，标点与大小写不可调。
public final class AppleSpeechTranscriber {

    public struct Options {
        /// BCP-47 语言标识，如 zh-CN / zh-TW / yue-CN
        public var language: String
        /// 转写前是否确保语言资产已安装
        public var ensureAssets: Bool

        public init(language: String = "zh-CN", ensureAssets: Bool = true) {
            self.language = language
            self.ensureAssets = ensureAssets
        }
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - 能力查询

    public static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 引擎支持的语言（实测 30 种）
    public static func supportedLanguages() async -> [String] {
        guard #available(macOS 26.0, *) else { return [] }
        return await SpeechTranscriber.supportedLocales
            .map { $0.identifier(.bcp47) }
            .sorted()
    }

    /// 本机已安装语言资产
    public static func installedLanguages() async -> [String] {
        guard #available(macOS 26.0, *) else { return [] }
        return await SpeechTranscriber.installedLocales
            .map { $0.identifier(.bcp47) }
            .sorted()
    }

    /// 语言是否受支持（不一定已安装）
    public static func isLanguageSupported(_ language: String) async -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        let target = Locale(identifier: language).identifier(.bcp47)
        return await SpeechTranscriber.supportedLocales
            .contains { $0.identifier(.bcp47) == target }
    }

    @available(macOS 26.0, *)
    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: Locale(identifier: options.language),
            // 批处理场景不需要 volatile（临时累积结果），只要最终稳定段落
            transcriptionOptions: [],
            reportingOptions: [],
            // 必须开 audioTimeRange，否则拿不到时间戳
            attributeOptions: [.audioTimeRange])
    }

    /// 确保该语言的资产已就绪（首次调用可能触发一次性下载）
    public func prepare() async throws {
        guard #available(macOS 26.0, *) else {
            throw MRError.transcription(reason: "需要 macOS 26 或更高版本")
        }
        let t = makeTranscriber()
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw MRError.transcription(reason: "语言资产安装失败（\(options.language)）：\(error)")
        }
    }

    // MARK: - 转写

    /// 转写单个音频文件
    /// - Parameters:
    ///   - fileURL: 待转写的音频（WAV / AIFF / m4a 等 AVAudioFile 可读格式）
    ///   - trackID: 轨道标识，写进 segment.track
    ///   - speaker: 说话人显示名（双轨方案下即轨角色），写进 segment.speaker
    public func transcribe(
        fileURL: URL,
        trackID: String,
        speaker: String
    ) async throws -> [TranscriptSegment] {
        guard #available(macOS 26.0, *) else {
            throw MRError.transcription(reason: "需要 macOS 26 或更高版本")
        }
        if options.ensureAssets { try await prepare() }

        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // 必须先让结果消费端就位，再启动分析——否则分析可能在订阅建立前就跑完
        async let collected = Self.collect(transcriber, trackID: trackID, speaker: speaker)

        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: fileURL) }
        catch { throw MRError.transcription(reason: "无法读取音频 \(fileURL.lastPathComponent)：\(error)") }

        do {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        } catch {
            throw MRError.transcription(reason: "分析器启动失败：\(error)")
        }

        return try await collected
    }

    /// 消费结果流，抽出「文本 + 音频时间范围」
    @available(macOS 26.0, *)
    private static func collect(
        _ transcriber: SpeechTranscriber,
        trackID: String,
        speaker: String
    ) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for try await result in transcriber.results {
            guard result.isFinal else { continue }

            var text = ""
            var lo = Double.nan
            var hi = Double.nan

            // 文本与时间范围都藏在 AttributedString 的 runs 里
            for run in result.text.runs {
                text += String(result.text[run.range].characters)
                guard let range = run.audioTimeRange else { continue }
                let a = CMTimeGetSeconds(range.start)
                let b = CMTimeGetSeconds(range.end)
                guard a.isFinite, b.isFinite else { continue }
                if lo.isNaN || a < lo { lo = a }
                if hi.isNaN || b > hi { hi = b }
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // 极端情况下引擎不给时间范围：退化为顺序排列，仍保留文本
            let start = lo.isNaN ? (segments.last?.end ?? 0) : lo
            let end = hi.isNaN ? start : max(start, hi)

            segments.append(TranscriptSegment(
                start: start, end: end, text: trimmed,
                track: trackID, speaker: speaker))
        }
        return segments
    }
}
