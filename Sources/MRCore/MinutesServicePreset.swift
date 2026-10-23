import Foundation

/// 常见云端模型服务的**快捷预设**：一键填好 Base URL 与模型名。
///
/// ## 为什么要有这个表
///
/// 「支持通用模型服务 API」这句话对用户来说太抽象了。真实卡点不是「不会用
/// OpenAI 兼容协议」，而是**不知道该填哪一行**：填到域名根上 404，填到 `/v1`
/// 前面少一段也 404，模型名写成 `deepseek-chat-v3` 又是另一种 404。
/// 每个服务商的 Base URL 与当前模型名都是它的知识，把这份知识内置成按钮，
/// 才是「支持通用服务」这句话真正兑现的地方。
///
/// **只填 URL 与模型名，绝不碰密钥**：密钥只能由用户自己粘贴，
/// 我们没有任何理由预置它。
///
/// 预设只是**快捷方式**，不是白名单：填法完全开放，预设外的服务商
/// （本机自建、代理网关、企业内部服务）照常手填。
public enum MinutesServicePreset: String, CaseIterable, Sendable {
    case deepSeek
    case zhipu
    case qwen
    case kimi
    case ollama

    public var displayName: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .zhipu:    return "智谱 GLM"
        case .qwen:     return "通义千问"
        case .kimi:     return "Kimi"
        case .ollama:   return "本机 ollama"
        }
    }

    /// Base URL，**填到含版本号的那一层**（请求会自动追加 `/chat/completions`）。
    public var baseURL: String {
        switch self {
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .zhipu:    return "https://open.bigmodel.cn/api/paas/v4"
        case .qwen:     return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .kimi:     return "https://api.moonshot.cn/v1"
        case .ollama:   return "http://127.0.0.1:11434/v1"
        }
    }

    /// 该服务商当前可用的模型名。**随服务方更新**，填错时「测试连接」会直接
    /// 报 404 并提示核对模型名——那时用户去服务商的模型列表看一眼即可。
    public var suggestedModel: String {
        switch self {
        case .deepSeek: return "deepseek-chat"
        case .zhipu:    return "glm-4-plus"
        case .qwen:     return "qwen-plus"
        case .kimi:     return "moonshot-v1-8k"
        case .ollama:   return "qwen2.5:7b"
        }
    }

    /// 密钥去哪申请 + 这档的已知特点。写在界面上而不是藏进文档：
    /// 「配置界面要能独立完成任务」意味着不能把关键一步外链出去。
    public var note: String {
        switch self {
        case .deepSeek:
            return "在 platform.deepseek.com 注册后创建 API Key。"
        case .zhipu:
            return "在 open.bigmodel.cn 控制台创建 API Key。"
        case .qwen:
            return "在百炼（dashscope）控制台创建 API Key，用兼容 OpenAI 的地址。"
        case .kimi:
            return "在 platform.moonshot.cn 创建 API Key。"
        case .ollama:
            return "本机自建，不经过网络、密钥可随便填。先 `ollama pull qwen2.5:7b` 拉好模型；"
                + "若没开 CORS 需要设 `OLLAMA_ORIGINS=app://*`。"
        }
    }
}