import Foundation
import MRCore

/// 纪要层的 HTTP 传输抽象。
///
/// 抽象出来**唯一的目的**是测试能注入假实现：绝不在单测里真发网络请求
/// （那会让测试结果取决于外网连通性与服务商状态，是最难查的一类红）。
/// 默认实现走 `URLSession`，与项目里 SenseVoice 下载同一条路线。
public protocol MinutesAPITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// 默认传输层：系统 `URLSession`。
public struct URLSessionMinutesTransport: MinutesAPITransport {
    /// 单次请求超时。默认 180 秒——云端 map-reduce 一场长会议要打很多次请求，
    /// 每次都可能排队；短了会把「服务端在正常生成」误判成超时。
    public var timeoutInterval: TimeInterval

    public init(timeoutInterval: TimeInterval = 180) {
        self.timeoutInterval = timeoutInterval
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.timeoutInterval = timeoutInterval
        return try await URLSession.shared.data(for: request)
    }
}

/// 云端 API 的三项配置。**纯值类型**（传输层是生成器的依赖，不混在这里）——
/// 这样测试可以直接比较两份配置是否相等，而不必比对会话语柄。
public struct CloudAPIConfiguration: Equatable, Sendable {
    /// Base URL，填到含版本号的那一层，如 `https://api.deepseek.com/v1`。
    public var baseURL: String
    /// API Key。
    public var apiKey: String
    /// 模型名，如 `deepseek-chat` / `glm-5` / `qwen-max`。
    public var model: String

    public init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 三项够不够用。**本机回环服务不算缺密钥。**
    ///
    /// ollama / LM Studio 这类本机服务根本不校验密钥，界面上逼用户
    /// 「随便填点什么」只会把「配齐」变成一个仪式，还让人以为填错了。
    /// 判据是回环地址（`isLoopbackHost`），不是「谁的域名」——公司自建的
    /// 内网网关若恰好跑在本机回环上，同样不需要密钥。
    public var isComplete: Bool {
        guard !baseURL.isEmpty, !model.isEmpty else { return false }
        if let host = URL(string: endpointString)?.host, Self.isLoopbackHost(host) {
            return true
        }
        return !apiKey.isEmpty
    }

    /// 这档配置是否需要密钥。`isComplete` 与请求构造共用它，两处不能各判一次。
    public var requiresKey: Bool {
        guard let host = URL(string: endpointString)?.host else { return true }
        return !Self.isLoopbackHost(host)
    }

    /// 缺哪些项（显示名取自 `MinutesCloudAPIField`，单一出处）。
    /// 本机服务不列 API Key——列了它就成了一个必须编出来的假字段。
    public var missingFields: [String] {
        var missing: [String] = []
        if baseURL.isEmpty { missing.append(MinutesCloudAPIField.baseURL.displayName) }
        if requiresKey && apiKey.isEmpty { missing.append(MinutesCloudAPIField.apiKey.displayName) }
        if model.isEmpty { missing.append(MinutesCloudAPIField.model.displayName) }
        return missing
    }

    /// 最终请求地址：Base URL 去尾部斜杠后追加 `/chat/completions`。
    ///
    /// **不猜版本路径**：填 `https://api.deepseek.com/v1` 就请求
    /// `…/v1/chat/completions`，填 `https://dashscope.aliyuncs.com/compatible-mode/v1`
    /// 就请求它的 compatible-mode——拼路径是服务商之间唯一不统一的地方，
    /// 猜一个「智能补 /v1」只会在另一家服务上静默拼出 404。
    public var endpointString: String {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/chat/completions"
    }

    /// 地址形态是否可用。nil = 没问题；非 nil = 人可读的原因。
    ///
    /// 这条检查挡的是两件具体事故：
    /// 1. 复制配置时带进换行/空格，拼出的 URL 静默失败；
    /// 2. **明文 http 发给第三方**——API Key 会以明文在网络上走一遍。
    ///    本机自建服务（ollama / LM Studio）是 http，所以回环地址放行。
    public var urlProblem: String? {
        let endpoint = endpointString
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else {
            return "Base URL「\(baseURL)」拼不出合法地址（将请求 \(endpoint)）"
        }
        guard scheme == "https" || scheme == "http" else {
            return "Base URL 只支持 http/https，收到「\(scheme)」"
        }
        if scheme == "http" && !Self.isLoopbackHost(host) {
            return "Base URL 是明文 http 且不是本机地址（\(host)）——API Key 会明文发送。"
                + "请改用 https；本机自建服务（ollama / LM Studio）可用 http://127.0.0.1"
        }
        return nil
    }

    /// 界面显示用的主机名。
    public var hostForDisplay: String {
        URL(string: endpointString)?.host ?? baseURL
    }

    /// 回环地址判定。`::1` / `127.*` / `0.0.0.0` 都算——
    /// 用户拿 `0.0.0.0` 起本地服务并不少见，把它判成「会外传」是误伤。
    static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "::1" || h == "0.0.0.0" { return true }
        if h.hasPrefix("127.") {
            let octets = h.dropFirst(4).split(separator: ".")
            return octets.count == 3 && octets.allSatisfy { UInt16($0) != nil }
        }
        return false
    }
}

/// 基于**通用模型服务 API**（OpenAI 兼容 `/chat/completions`）的纪要生成器。
///
/// 覆盖 DeepSeek / GLM / Qwen / Kimi / Moonshot 等一切兼容该协议的服务，
/// 以及本机自建（ollama / LM Studio）。与 `FoundationModelsMinutesGenerator`
/// 实现同一个 `MinutesGenerator` 协议——上层编排（分块、map-reduce、降级）
/// 一行都不区分用的是谁。
///
/// 三条硬纪律：
/// 1. **密钥绝不进日志与界面**：请求由本类发出，错误信息只带状态码与
///    响应片段，不回显请求体；
/// 2. **失败不降级**：网络 / 鉴权 / 限流失败一律抛 `MinutesError.apiCall`
///    （见该 case 的注释），由调用方决定怎么办，绝不悄悄写一份降级稿；
/// 3. **默认不用它**：选它是一次显式的隐私决策（转写稿离开本机），
///    见 `MinutesGeneratorResolver` 与 `MinutesProvider`。
public struct CloudAPIMinutesGenerator: MinutesGenerator {

    public var configuration: CloudAPIConfiguration
    public var transport: any MinutesAPITransport

    public init(
        configuration: CloudAPIConfiguration,
        transport: any MinutesAPITransport = URLSessionMinutesTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public var isAvailable: Bool {
        configuration.isComplete && configuration.urlProblem == nil
    }

    public var displayName: String {
        "云端 API（\(configuration.model) @ \(configuration.hostForDisplay)）"
    }

    public var unavailableReason: String? {
        if !configuration.isComplete {
            return "云端 API 未配齐：缺 \(configuration.missingFields.joined(separator: "、"))"
                + "（用 \(MinutesCloudAPIField.allCases.map(\.setCommand).joined(separator: " / ")) 补齐）"
        }
        return configuration.urlProblem
    }

    // MARK: - map

    public func summarize(block: TranscriptBlock) async throws -> BlockSummary {
        let content = try await chat(
            system: MinutesPrompts.systemRole,
            user: MinutesPrompts.blockUserPrompt(text: block.text))
        let parsed = try Self.decode(
            LenientBlockResult.self, from: content, stage: "分段摘要")
        return BlockSummary(
            index: block.index,
            polishedText: MinutesNormalizer.normalizeBlank(parsed.polishedText),
            summary: parsed.summary,
            keyPoints: parsed.keyPoints,
            decisions: parsed.decisions,
            actionItems: parsed.actionItems.map {
                ActionItem(
                    task: $0.task,
                    owner: MinutesNormalizer.normalizeBlank($0.owner),
                    due: MinutesNormalizer.normalizeBlank($0.due))
            },
            corrections: MinutesNormalizer.corrections(parsed.corrections))
    }

    // MARK: - reduce

    public func merge(summaries: [BlockSummary]) async throws -> MeetingMinutes {
        let joined = MinutesPrompts.renderSummaries(summaries)
        let content = try await chat(
            system: MinutesPrompts.systemRole,
            user: MinutesPrompts.mergeUserPrompt(joinedSummaries: joined))
        let parsed = try Self.decode(
            LenientMinutesResult.self, from: content, stage: "全局纪要")
        return MeetingMinutes(
            summary: parsed.summary,
            topics: MinutesNormalizer.topics(parsed.topics),
            keyPoints: parsed.keyPoints,
            decisions: parsed.decisions,
            actionItems: parsed.actionItems.map {
                ActionItem(
                    task: $0.task,
                    owner: MinutesNormalizer.normalizeBlank($0.owner),
                    due: MinutesNormalizer.normalizeBlank($0.due))
            },
            openIssues: parsed.openIssues)
    }

    // MARK: - 请求

    /// OpenAI 兼容的请求体。`stream: false` 是**必须显式关掉的**：
    /// 有些兼容服务默认走 SSE，不关就会收到一行行 `data: {...}` 而不是一个完整 JSON。
    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }
        struct ResponseFormat: Encodable {
            var type = "json_object"
        }
        var model: String
        var messages: [Message]
        var temperature = 0.2
        var response_format = ResponseFormat()
        var stream = false
    }

    private func makeRequest(system: String, user: String) throws -> URLRequest {
        guard let url = URL(string: configuration.endpointString) else {
            throw MinutesError.apiCall(
                reason: "Base URL 拼不出合法地址：\(configuration.endpointString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 密钥为空（只可能是本机服务）时**不发** Authorization：
        // 一个值是空的 `Bearer ` 头会被一部分网关当成「提供了错误的凭据」，
        // 报出来的错还指向密钥，方向完全错。
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)",
                             forHTTPHeaderField: "Authorization")
        }
        let body = ChatRequest(
            model: configuration.model,
            messages: [
                ChatRequest.Message(role: "system", content: system),
                ChatRequest.Message(role: "user", content: user),
            ])
        let encoder = JSONEncoder()
        // 紧凑输出：纪要正文可能上万字，pretty 打印纯粹浪费带宽。
        encoder.outputFormatting = [.withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body)
        return request
    }

    // MARK: - 响应

    private struct ChatResponse: Decodable {
        struct Message: Decodable {
            var role: String?
            var content: String?
        }
        struct Choice: Decodable {
            var message: Message?
        }
        /// 有些服务把错误放在 200 响应体里（尤其是代理层）。
        struct ErrorBody: Decodable {
            var message: String?
        }
        var choices: [Choice]?
        var error: ErrorBody?
    }

    /// 发一次 chat 请求，取出助手消息的文本。
    private func chat(system: String, user: String) async throws -> String {
        let request = try makeRequest(system: system, user: user)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw MinutesError.apiCall(reason: Self.describeTransportFailure(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw MinutesError.apiCall(reason: "响应不是 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw MinutesError.apiCall(
                reason: Self.describeHTTPFailure(status: http.statusCode, data: data))
        }

        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw MinutesError.apiCall(
                reason: "响应不是约定的 JSON（\(error.localizedDescription)）。"
                    + "响应片段：\(MinutesResponseParsing.snippet(String(decoding: data, as: UTF8.self)))")
        }

        if let content = decoded.choices?.first?.message?.content,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }
        // 200 但没内容：错误可能藏在 body 里
        if let message = decoded.error?.message, !message.isEmpty {
            throw MinutesError.apiCall(reason: "服务返回错误：\(message)")
        }
        throw MinutesError.apiCall(
            reason: "响应里没有 choices[0].message.content。"
                + "响应片段：\(MinutesResponseParsing.snippet(String(decoding: data, as: UTF8.self)))")
    }

    /// 网络层失败的人文化描述。`URLError` 的 `localizedDescription`
    /// 对中文用户是「The network connection was lost」这种，翻一下更可操作。
    static func describeTransportFailure(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "网络不通（\(urlError.localizedDescription)）"
            case .timedOut:
                return "请求超时（服务在超时时间内没有返回完整响应）"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "连不上服务器（\(urlError.localizedDescription)）。检查 Base URL 是否填错"
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return "TLS 握手失败（\(urlError.localizedDescription)）"
            default:
                return "网络错误（\(urlError.localizedDescription)）"
            }
        }
        return "请求失败：\(error.localizedDescription)"
    }

    /// HTTP 失败的人文化描述。**按状态码给下一步动作**——
    /// 只说「HTTP 401」用户还是不知道该改哪里。
    static func describeHTTPFailure(status: Int, data: Data) -> String {
        let body = MinutesResponseParsing.snippet(String(decoding: data, as: UTF8.self))
        switch status {
        case 401, 403:
            return "密钥无效或没有该模型的权限（HTTP \(status)）。"
                + "检查 API Key 是否填对、是否过期、是否有权限访问模型「\(body.isEmpty ? "" : body)」"
        case 404:
            return "接口不存在（HTTP 404）。Base URL 要填到含版本号的那一层"
                + "（如 https://api.deepseek.com/v1），模型名也要填对"
        case 429:
            return "触发限流（HTTP 429），稍后重试或降低调用频率"
        case 400, 422:
            return "请求被拒绝（HTTP \(status)）：\(body)"
        case 500, 502, 503, 504:
            return "服务端错误（HTTP \(status)），稍后重试：\(body)"
        default:
            return "服务返回 HTTP \(status)：\(body)"
        }
    }

    // MARK: - 解析

    /// 把模型输出解析成目标结构。失败一律 `apiCall`，并带上原文片段。
    static func decode<T: Decodable>(_ type: T.Type, from content: String, stage: String) throws -> T {
        guard let jsonText = MinutesResponseParsing.extractJSONObject(from: content) else {
            throw MinutesError.apiCall(
                reason: "\(stage)：模型输出里找不到 JSON 对象。"
                    + "输出片段：\(MinutesResponseParsing.snippet(content))")
        }
        guard let data = jsonText.data(using: .utf8) else {
            throw MinutesError.apiCall(reason: "\(stage)：JSON 文本无法编码为 Data")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MinutesError.apiCall(
                reason: "\(stage)：JSON 字段不符合约定（\(error.localizedDescription)）。"
                    + "输出片段：\(MinutesResponseParsing.snippet(content))")
        }
    }
}
