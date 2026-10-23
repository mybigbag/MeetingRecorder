import Foundation
import MRCore

/// 云端纪要 API 的「测试连接」。
///
/// ## 为什么需要它
///
/// 配错 Base URL / 密钥 / 模型名这三件事，原本**只能靠跑一场会议暴露**——
/// 代价是录完、转写完、再等模型跑几分钟，最后拿到一句「HTTP 401」。
/// 配置界面必须有「当场验证」的手段：这正是界面相对命令行的核心价值之一
/// （命令行给不了交互反馈，界面可以）。
///
/// ## 两条硬纪律
///
/// 1. **探测请求绝不包含任何会议内容**：只发一句写死的短句，
///    `max_tokens` 极小。「点一下测试连接就把上一场会议发出去」是不能接受的
///    ——哪怕服务是自己家的，行为也要可预期。
/// 2. **失败不静默**：返回人话原因（复用生成器同一套映射），
///    界面直接显示，不写日志了事。
///
/// 不复用 `CloudAPIMinutesGenerator` 的私有请求体是**有意的**：那一份带
/// `response_format: json_object` 与纪要专用提示词，是纪要契约的一部分；
/// 探测要的是最朴素的「这个地址 + 这个密钥 + 这个模型能不能答一句话」，
/// 带上 JSON 约束反而会让某些服务因为格式要求之外的原因失败。
/// 代价是两处各有一份小响应壳，收益是探测不会因纪要契约的收紧而误报。
public enum MinutesAPIProbe {

    /// 探测结果。
    public enum Outcome: Equatable, Sendable {
        /// 通了。`reply` 是模型实际回的那几个字——
        /// 让用户看见「真的是这个模型答的」，而不是只看到一个绿色的对勾。
        case ok(model: String, latencyMs: Int, reply: String)
        /// 没通。`reason` 已含下一步动作。
        case failed(reason: String)

        public var isOK: Bool {
            if case .ok = self { return true }
            return false
        }

        /// 给界面用的一行结果文案。
        public var summary: String {
            switch self {
            case let .ok(model, latencyMs, reply):
                let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                return "连接成功（\(model)，\(latencyMs) 毫秒\(Self.echo(trimmed))）"
            case let .failed(reason):
                return reason
            }
        }

        /// 模型回的那几个字，**必须截断**。
        ///
        /// 实测踩到过：对着本机的假服务测试时，它对探测请求也返回整段纪要 JSON，
        /// 结论行瞬间被撑成一大片红字。探测要的是「能不能答」，
        /// 不是「答了多少」——超过一屏的引用只会把界面挤坏。
        static func echo(_ reply: String) -> String {
            guard !reply.isEmpty else { return "" }
            let limit = 40
            if reply.count <= limit { return "，模型答：\(reply)" }
            return "，模型答：\(reply.prefix(limit))…"
        }
    }

    /// 探测用的固定短句。**与任何会议内容无关**，且短到几乎不产生费用。
    ///
    /// public 是因为设置界面要把这句话**原样显示给用户**——
    /// 「测试连接会发什么」必须能被看见，只写「不发送会议内容」是空口承诺。
    public static let probePrompt = "只回复两个字：就绪"

    /// 探测超时。刻意比生成用的 180 秒短得多——
    /// 用户点的是「测试一下」，不该盯着转圈等三分钟。
    public static let probeTimeout: TimeInterval = 15

    /// 探测请求体。不带 `response_format`、不带 system 角色。
    private struct ProbeRequest: Encodable {
        struct Message: Encodable {
            var role = "user"
            var content: String
        }
        var model: String
        var messages: [Message]
        var max_tokens = 8
        var temperature = 0.0
        var stream = false
    }

    /// 响应壳：只要能答一句话就够，字段比纪要那套少得多。
    private struct ProbeResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?
            }
            var message: Message?
        }
        struct ErrorBody: Decodable {
            var message: String?
        }
        var model: String?
        var choices: [Choice]?
        var error: ErrorBody?
    }

    /// 测一次。**从不抛出**——界面要的是一个能直接显示的结果，
    /// 让它去 catch 自己抛的错等于把错误处理摊成两份。
    public static func run(
        configuration: CloudAPIConfiguration,
        transport: any MinutesAPITransport = URLSessionMinutesTransport(
            timeoutInterval: probeTimeout)
    ) async -> Outcome {
        // 不配齐 / URL 有毛病时**一个字节都不发**：先说清楚缺什么，
        // 比发一次注定失败的请求更快也更诚实。
        guard configuration.isComplete else {
            return .failed(reason: "还缺 \(configuration.missingFields.joined(separator: "、"))，先填完再测")
        }
        if let problem = configuration.urlProblem {
            return .failed(reason: problem)
        }
        guard let url = URL(string: configuration.endpointString) else {
            return .failed(reason: "Base URL 拼不出合法地址：\(configuration.endpointString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 本机服务不校验密钥，密钥为空就不带这个头（同生成侧的理由）。
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)",
                             forHTTPHeaderField: "Authorization")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        request.httpBody = try? encoder.encode(
            ProbeRequest(model: configuration.model,
                          messages: [ProbeRequest.Message(content: probePrompt)]))

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            return .failed(reason: CloudAPIMinutesGenerator.describeTransportFailure(error))
        }
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        guard let http = response as? HTTPURLResponse else {
            return .failed(reason: "响应不是 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            return .failed(
                reason: CloudAPIMinutesGenerator.describeHTTPFailure(
                    status: http.statusCode, data: data))
        }

        let decoded: ProbeResponse
        do {
            decoded = try JSONDecoder().decode(ProbeResponse.self, from: data)
        } catch {
            return .failed(
                reason: "响应不是约定的 JSON（\(error.localizedDescription)）。"
                    + "这一档通常意味着 Base URL 指到了网页而不是 API——"
                    + "请确认填到含版本号的那一层（如 https://api.deepseek.com/v1）")
        }
        if let message = decoded.error?.message, !message.isEmpty {
            return .failed(reason: "服务返回错误：\(message)")
        }
        guard let content = decoded.choices?.first?.message?.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(reason: "服务收到了请求，但没有返回任何内容。"
                + "响应片段：\(MinutesResponseParsing.snippet(String(decoding: data, as: UTF8.self)))")
        }
        // 回显服务报上来的模型名（而非我们发过去的那个）：
        // 有的服务会做路由/替换，用户看到真实生效的模型才不会误判。
        return .ok(
            model: decoded.model?.isEmpty == false ? decoded.model! : configuration.model,
            latencyMs: latencyMs,
            reply: content)
    }
}