import Foundation
import MRCore

/// 把全局配置里的 `TranscriptionEngine` 解成具体的转写驱动器。
///
/// 这是「换引擎」唯一的开关位置：`SessionTranscriber` 只调 `driver(for:language:)`，
/// 不认具体引擎类。要加第三个引擎，只在这里加一个 case + 一个实现，上层零改动。
public enum TranscriptionEngineResolver {

    /// 根据配置选择驱动器。语言只用于构造时的默认值透传，
    /// 真正的语言能力查询走 `driver.isLanguageSupported`。
    public static func driver(
        for engine: TranscriptionEngine,
        language: String
    ) -> any TranscriptionEngineDriver {
        switch engine {
        case .apple:
            return AppleSpeechEngineDriver(
                options: .init(language: language, ensureAssets: true))
        case .senseVoice:
            return SenseVoiceTranscriptionEngine(language: language)
        }
    }
}

/// 苹果原生引擎的驱动器包装。
///
/// `AppleSpeechTranscriber` 的能力查询是 **static**（`isLanguageSupported` /
/// `supportedLanguages`），而 `TranscriptionEngineDriver` 要的是**实例方法**，
/// 所以这里包一层，把实例调用转给类方法、把真正的转写转给实例方法。
/// 这样 `SessionTranscriber` 看的是统一协议，而不是苹果类的形状。
public final class AppleSpeechEngineDriver: TranscriptionEngineDriver {

    public let engineID = TranscriptionEngine.apple.driverEngineID

    private let transcriber: AppleSpeechTranscriber

    public init(options: AppleSpeechTranscriber.Options = .init()) {
        self.transcriber = AppleSpeechTranscriber(options: options)
    }

    public func isLanguageSupported(_ language: String) async -> Bool {
        await AppleSpeechTranscriber.isLanguageSupported(language)
    }

    public func supportedLanguages() async -> [String] {
        await AppleSpeechTranscriber.supportedLanguages()
    }

    public func prepare() async throws {
        try await transcriber.prepare()
    }

    public func transcribe(
        fileURL: URL,
        trackID: String,
        speaker: String
    ) async throws -> [TranscriptSegment] {
        try await transcriber.transcribe(
            fileURL: fileURL, trackID: trackID, speaker: speaker)
    }
}

/// SenseVoice 转写引擎（**opt-in**）。
///
/// 链路：**查资产门槛 → 子进程（llama.cpp / GGUF 运行时）→ SRT → 清洗 → `TranscriptSegment`**。
/// 决策依据（模型来源与授权 / 运行时选型 / 下载体积）见 `docs/接入-SenseVoice推理.md`。
///
/// 三条纪律，都来自「半成品不得流入正式链路」这一条：
///
/// 1. **未就绪时在写任何文件之前失败。** `prepare()` 由 `SessionTranscriber` 提到轨循环
///    之前调用，所以缺资产会以非 0 退出码结束、目录里只留 `manifest.json` + `wav`，
///    绝不产出一份空稿（空稿会被下游读成「这场确实没人说话」）。
/// 2. **`prepare()` 不替用户下载 244 MiB。** 一次 `transcribe` 里静默发生两分钟下载，
///    从用户视角与「卡住」无法区分。缺失时抛一条**可照抄执行**的错误。
/// 3. **资产缺失绝不静默回退到苹果引擎。** 那会让用户拿到一份来自另一个引擎的稿子，
///    而稿子上的 `engine` 字段还写着别的名字。
///
/// 启用方式（全局，非每场勾选）：`mr config set engine sensevoice`。
public final class SenseVoiceTranscriptionEngine: TranscriptionEngineDriver,
                                                  TranscriptionEngineDiagnostics {

    public let engineID = TranscriptionEngine.senseVoice.driverEngineID

    /// 构造时透传的语言（默认 zh-CN）。
    public let language: String

    public let paths: SenseVoicePaths

    private let store: SenseVoiceModelStore
    private let inference: SenseVoiceInference
    private let environment: [String: String]
    private let bundle: Bundle

    public init(
        language: String = "zh-CN",
        paths: SenseVoicePaths = SenseVoicePaths(),
        runner: any SenseVoiceProcessRunning = SenseVoiceProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) {
        self.language = language
        self.paths = paths
        self.store = SenseVoiceModelStore(paths: paths)
        self.environment = environment
        self.bundle = bundle
        self.inference = SenseVoiceInference(
            paths: paths, runner: runner, environment: environment, bundle: bundle)
    }

    /// 资产落点。放在 Application Support 下，与录音库隔离，便于单独清理 / 版本管理。
    ///
    /// 与 `paths.baseDirectory` 同源——保留这个静态入口是为了让「模型装在哪」
    /// 有一个不必构造实例就能问到的答案（`mr model` 与 GUI 状态行都要用）。
    public static var modelDirectory: URL {
        SenseVoicePaths.defaultBaseDirectory
    }

    /// 当前资产状态（存在性 + 字节数，不做全量摘要）。
    public var installState: SenseVoiceInstallState {
        store.state(environment: environment, bundle: bundle)
    }

    /// 实际会被用到的运行时二进制路径。nil = 解析不到。
    public var runtimeBinaryURL: URL? {
        paths.resolveRuntimeBinary(environment: environment, bundle: bundle)
    }

    /// SenseVoiceSmall 的真实语言集：中文（含方言）、粤语、英语、日语、韩语。
    ///
    /// 骨架期这里写的是「只认中文」的占位；模型卡明示是五语种，语言由模型自动判断，
    /// 运行时也没有语言参数可传。占位留着会有一个具体后果：
    /// `--lang en-US` 会在门槛处被拦下，而引擎其实完全能处理。
    public func isLanguageSupported(_ language: String) async -> Bool {
        Self.languagePrefixes.contains { language.lowercased().hasPrefix($0) }
    }

    public func supportedLanguages() async -> [String] {
        ["zh-CN", "yue-CN", "en-US", "ja-JP", "ko-KR"]
    }

    static let languagePrefixes = ["zh", "yue", "en", "ja", "ko"]

    /// 资产门槛。就绪 → 通过；缺任何一项 → 抛一条**可照抄执行**的错误。
    ///
    /// 错误信息按「缺的是权重还是运行时」分开写：两者的修复动作完全不同
    /// （一个要下 244 MiB，一个通常只要从本地拷 3 MiB），
    /// 一律说成「模型没下」会让用户白等一次下载。
    public func prepare() async throws {
        let state = installState

        if state.isReady { return }

        var problems: [String] = []
        for asset in state.pending {
            let status = state.status(of: asset.kind)
            if asset.kind == .runtime {
                problems.append("    · 推理运行时未就绪 → `meeting-recorder model install-runtime`"
                    + "（\(asset.humanSize)：\(status.summary)）")
            } else {
                problems.append("    · \(asset.kind.displayName)未就绪 → `meeting-recorder model download`"
                    + "（\(asset.humanSize)：\(status.summary)）")
            }
        }

        if let ignored = paths.ignoredRuntimeOverride(environment: environment) {
            problems.append("    · 注意：环境变量 \(SenseVoicePaths.runtimeOverrideKey) 指向的 "
                + "\(ignored) 不存在或不可执行，已被忽略。")
        }

        let pendingBytes = state.pendingDownloadByteCount
        let sizeHint = pendingBytes > 0
            ? "\n  需要联网下载约 \(String(format: "%.0f", Double(pendingBytes) / 1_048_576)) MiB。"
            : ""

        throw MRError.transcription(
            reason: "SenseVoice 引擎的资产尚未就绪，转写不会开始（也不会产出任何文件）：\n"
                + problems.joined(separator: "\n")
                + sizeHint
                + "\n  落点：\(paths.baseDirectory.path)"
                + "\n  查看状态：`meeting-recorder model`")
    }

    /// 转写单个音频文件。
    ///
    /// 资产未就绪时**抛错**，绝不返回空数组或伪造段落——这是「半成品不得流入正式链路」
    /// 的执行点，也是原有骨架用例（`testSenseVoiceTranscribeThrowsRatherThanFaking`）的意义。
    public func transcribe(
        fileURL: URL,
        trackID: String,
        speaker: String
    ) async throws -> [TranscriptSegment] {
        if !installState.isReady {
            // 未就绪时 `prepare()` 必定抛错，措辞也由它统一（用户看到的必须是同一句话，
            // 不管从哪个入口失败）。
            //
            // 这里**不写** `return []`。早先的写法是
            // `guard state.isReady else { try await prepare(); return [] }`——
            // 而 `prepare()` 能返回，说明状态在这两次读取之间变成了就绪，
            // 于是那句 `return []` 会把一次**本来可以正常转写**的调用变成一份空稿，
            // 而空稿会被下游读成「这场确实没人说话」。窗口很窄，但代价是错的：
            // 宁可多走一次下面的检查，也不要一个会把「有内容」说成「没内容」的分支。
            // 下面 `inference.transcribe` 会自己再查一遍运行时与模型文件，不需要这里的旧结论。
            try await prepare()
        }

        let outcome = try await inference.transcribe(
            fileURL: fileURL, trackID: trackID, speaker: speaker)
        lastNotes = outcome.notes
        return outcome.segments
    }

    /// 最近一次转写的诊断信息。CLI / GUI 取它来打印「丢了几条、VAD 切了几段」。
    ///
    /// 实现的是 `TranscriptionEngineDiagnostics`（可选协议），而不是把它塞进
    /// `TranscriptionEngineDriver`——后者会逼苹果那侧也实现一个永远为空的属性。
    /// 调用方应在每次 `transcribe` 之后**立刻**读取：下一次调用会覆盖它。
    public private(set) var lastNotes: [String] = []
}
