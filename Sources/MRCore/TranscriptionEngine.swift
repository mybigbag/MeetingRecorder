import Foundation

/// 转写引擎的全局选择。
///
/// 这是一个**统一的配置项**，不是每场会议里勾选的开关——用户在一处改了，
/// 之后所有 `transcribe` 都用同一个引擎（见 `RecorderPreferences.transcriptionEngine`）。
///
/// 设计纪律（与「静默录制」「16 位录音」一致）：
/// - **默认必须是苹果原生**（`apple`）。换引擎要用户自己显式点头，
///   不能因为「我们觉得 SV 更准」就在某次升级里悄悄把默认换掉——
///   那样被换掉的那批会议已经录完了，且 SV 还有英文词 / ITN 退步、242 MB 下载、
///   内存涨到 300~400 MB 的代价，用户完全不知情。
/// - `senseVoice` 是 **opt-in**：默认关，用户通过 `config set engine sensevoice` 主动开启，
///   主要服务专有名词密集场景（见 `docs/评估-AI模型接入可行性.md` 第 1/3 步结论）。
public enum TranscriptionEngine: String, Codable, CaseIterable {
    /// 苹果原生本地转写（macOS 26 `SpeechAnalyzer`，零下载、约 160×、约 24 MB）。
    case apple = "apple"
    /// SenseVoice（opt-in，需下载模型、更吃内存）。
    ///
    /// 实测（2026-09-29，48 kHz 真实会议录音）：**86×**（单声道 175 MB / 10.6 s）、
    /// **26×**（双声道 351 MB / 35.4 s）；子进程 RSS 峰值 300~400 MB，退出即归还。
    /// 权重 242.4 MiB（仅首次下载，落 `~/Library/Application Support/meeting-recorder/sensevoice`）。
    ///
    /// 落盘 / CLI 的规范写法是**全小写 `sensevoice`**（不是 Swift 的 `senseVoice`）：
    /// 用户要在终端敲它，`allCases.map(\.rawValue)`、帮助文案、错误提示必须是同一个串，
    /// 否则「文档写 sensevoice、实际只认 senseVoice」会让那个命令永远失败。
    case senseVoice = "sensevoice"

    /// 给人看的名字。刻意不含括号——它常被打印在 `rawValue（displayName）` 里，
    /// 自带括号会套出「apple（苹果原生（…））」那种叠括号。
    public var displayName: String {
        switch self {
        case .apple:      return "苹果原生"
        case .senseVoice: return "SenseVoice"
        }
    }

    /// 是否是需要用户显式开启的 opt-in 引擎。
    ///
    /// 这一位的意义是隐私与默认安全的边界：`apple` 出本机、零下载；
    /// `senseVoice` 要拉模型、走本地推理进程，属于「换一种更重的实现」，
    /// 按项目纪律必须默认关、用户主动要，而不是默认替换。
    public var isOptIn: Bool {
        switch self {
        case .apple:      return false
        case .senseVoice: return true
        }
    }

    /// 菜单项 / 面板里的说明文字。
    ///
    /// **代价必须写出来，不能只写好处**——两个引擎的差别不是「哪个更好」，
    /// 而是「多花的 244 MiB 与 300~400 MB 内存换来什么、代价是什么」。
    /// 只写好处的说明等于隐瞒，而这一项的差别恰恰全在代价里。
    public var menuHelp: String {
        switch self {
        case .apple:
            return """
                苹果原生本地转写：零下载、约 160 倍实时、录音不出本机。默认。
                """
        case .senseVoice:
            return """
                SenseVoice（opt-in）：需先下载约 244 MiB 模型，仅首次；推理时内存 \
                涨到 300~400 MB。实测 48 kHz 双轨真实会议约 26 倍实时。\
                主要服务专有名词密集场景。资产没装好时转写会在写任何文件之前\
                明确报错——不会产出空稿，也不会静默改用苹果引擎\
                （那会让你拿到一份署名不同的稿子）。
                """
        }
    }

    /// 写进 `TranscriptDocument.engine` 的标签，也是驱动器 `engineID` 的权威来源。
    ///
    /// 单一出处：CLI 打印、文档渲染、`TranscriptDocument` 落盘都从这里取，
    /// 不各自硬编码字符串，避免「代码里写 sensevoice、稿子里写 sense-voice」那种漂移。
    public var driverEngineID: String {
        switch self {
        case .apple:      return "apple-speech"
        case .senseVoice: return "sensevoice"
        }
    }

    /// 从字符串解析，无效值（含旧文档里的 `whisper` 等）一律回退到 `.apple`——
    /// 宁可保守也不能因为读到一个不认识的引擎名就崩，或静默选了更重的引擎。
    public init(resolving raw: String?) {
        guard let raw, let parsed = TranscriptionEngine(rawValue: raw) else {
            self = .apple
            return
        }
        self = parsed
    }
}

/// 转写驱动器的统一接口。
///
/// `SessionTranscriber` 只认这个协议，不认具体引擎类——换引擎就是换一个实现，
/// 上层（逐轨转写、hostTime 对齐、归并、去回声、渲染）一行都不用动。
///
/// 苹果原生实现见 `AppleSpeechEngineDriver`（包装 `AppleSpeechTranscriber`），
/// SenseVoice 实现见 `SenseVoiceTranscriptionEngine`（均位于 `MRTranscribe`）。
public protocol TranscriptionEngineDriver {
    /// 写进 `TranscriptDocument.engine` 的标签，必须等于对应 `TranscriptionEngine.driverEngineID`。
    var engineID: String { get }

    /// 该引擎是否支持某语言（不一定已下载资产）。
    func isLanguageSupported(_ language: String) async -> Bool

    /// 该引擎支持的语言列表。
    func supportedLanguages() async -> [String]

    /// 转写前确保资产就绪（首次可能触发一次性下载）。骨架引擎可在此抛「未实现」。
    func prepare() async throws

    /// 转写单个音频文件，产出统一格式的段落。
    func transcribe(
        fileURL: URL,
        trackID: String,
        speaker: String
    ) async throws -> [TranscriptSegment]
}

/// 引擎可选实现的**诊断通道**。
///
/// 为什么不把 `lastNotes` 直接塞进 `TranscriptionEngineDriver`：那会逼着苹果那侧也实现一个
/// 永远为空的属性。而诊断信息本身是有价值的——「丢了几条纯标点空段」「VAD 切了几段」
/// 必须能流到 CLI 与 GUI，否则一次「少了几条」的转写就只能靠猜。
///
/// 约定：`lastNotes` 描述**最近一次 `transcribe` 调用**。调用方应在每次转写后立刻读取，
/// 因为下一次调用会把它覆盖掉。
public protocol TranscriptionEngineDiagnostics: AnyObject {
    var lastNotes: [String] { get }
}
