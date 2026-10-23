import Foundation

/// 会议纪要用哪个模型层生成。**全局配置项**，与转写引擎同一套纪律：
/// 在一处改（`config set minutes <名字>` / 设置面板），之后所有 `minutes` 都听它的。
///
/// 设计纪律：
/// - **默认必须是 `local`**（macOS 26 `FoundationModels`，免费、离线、录音不出本机）。
///   换云端要用户自己显式点头——会议录音是最敏感的一类数据，把转写稿送到第三方
///   服务器是一次不可逆的隐私决策，不能因为「我们觉得云端质量好」就在某次升级里
///   悄悄把默认换掉。
/// - `cloudAPI` 是 **opt-in**：用户配齐 Base URL / Key / 模型名之后主动开启。
///   三者缺任何一项，CLI 会在**写任何文件之前**明确报错并给出要敲的命令，
///   绝不静默回退本地（那会让你拿到一份署名不同的纪要）。
public enum MinutesProvider: String, Codable, CaseIterable {
    /// 本地 `FoundationModels`（默认）。零成本、离线、录音不出本机。
    ///
    /// 硬约束：上下文 4096 token，所以长会议必须走 map-reduce 分块
    /// （见 `TranscriptChunker`）；且要求设备支持 Apple Intelligence，
    /// 不支持时 `minutes` 会明确产出「未生成摘要」的降级稿，不假装修标点。
    case local = "local"
    /// 云端通用模型 API（OpenAI 兼容的 `/chat/completions`）。
    ///
    /// 覆盖 DeepSeek / GLM / Qwen / Kimi / Moonshot 等一切兼容 OpenAI
    /// 协议的服务，也覆盖本机自建（ollama / LM Studio，`http://127.0.0.1`）。
    /// 上下文大得多（通常 32K~1M），多数场景不必分块；但**转写稿会离开本机**。
    case cloudAPI = "api"

    /// 给人看的名字。刻意不含括号——它常被打印在 `rawValue（displayName）` 里。
    public var displayName: String {
        switch self {
        case .local:   return "本地 FoundationModels"
        case .cloudAPI: return "云端模型 API"
        }
    }

    /// 设置界面 / 菜单里的说明。**代价必须写出来，不能只写好处。**
    public var menuHelp: String {
        switch self {
        case .local:
            return """
                本地 FoundationModels：免费、离线、转写稿不出本机。默认。\
                需要设备支持 Apple Intelligence；上下文 4096 token，长会议自动分块。
                """
        case .cloudAPI:
            return """
                云端模型 API（OpenAI 兼容 /chat/completions）：需要自备 \
                Base URL、API Key 与模型名。质量与上下文通常更好，但\
                转写稿会发送到第三方服务器——这是隐私决策，默认关闭。\
                密钥只存本机偏好域，界面与 config show 一律打码，绝不打印明文。
                """
        }
    }

    /// 是否 opt-in（需要用户显式配置才可用）。
    public var isOptIn: Bool {
        switch self {
        case .local:   return false
        case .cloudAPI: return true
        }
    }

    /// 从字符串解析。不认识的值（含历史遗留）一律回退 `.local`——
    /// 不能因为读到一个陌生名字就崩，更不能静默选中会把数据传出本机的那一档。
    public init(resolving raw: String?) {
        guard let raw, let parsed = MinutesProvider(rawValue: raw) else {
            self = .local
            return
        }
        self = parsed
    }
}

/// 云端纪要 API 的三个配置项。
///
/// **显示名与命令名在这里只有一个出处**：CLI 报错、`config show`、生成器的
/// 「不可用原因」、设置界面提示都取它。各写一份的话，「报错说缺 minutes-key、
/// 界面说缺 API Key」这种对不上的事迟早发生，而用户卡在中间不知道该敲什么。
public enum MinutesCloudAPIField: String, CaseIterable, Sendable {
    case baseURL = "minutes-url"
    case apiKey = "minutes-key"
    case model = "minutes-model"

    /// 给人看的名字。
    public var displayName: String {
        switch self {
        case .baseURL: return "Base URL"
        case .apiKey:  return "API Key"
        case .model:   return "模型名"
        }
    }

    /// 配齐这一项要敲的命令（不含值）。
    public var setCommand: String { "config set \(rawValue)" }
}
