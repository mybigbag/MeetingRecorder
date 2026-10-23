import XCTest
@testable import MRMinutes
import MRCore

/// 造 200 响应、OpenAI 兼容的成功壳。**文件级工具而不是实例方法**：
/// 闭包里写 `Self.okBody(…)` 会被当成实例成员调用而编译不过——
/// 那类错误只在闭包里出现，容易让人怀疑是不是少了 `self.`。
private enum ProbeFixtures {

    static func configuration(
        baseURL: String = "https://api.deepseek.com/v1",
        apiKey: String = "sk-probe-key",
        model: String = "deepseek-chat"
    ) -> CloudAPIConfiguration {
        CloudAPIConfiguration(baseURL: baseURL, apiKey: apiKey, model: model)
    }

    static func okBody(model: String = "deepseek-chat", content: String = "就绪") -> Data {
        Data("""
        {"model":"\(model)","choices":[{"message":{"role":"assistant","content":"\(content)"}}]}
        """.utf8)
    }

    static func http(_ status: Int) -> URLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

/// 「测试连接」的探测行为。
///
/// 这一组最要紧的不是「通了能过」，而是三条边界：
/// 1. **探测请求里绝不出现会议内容**（只发一句固定短句）；
/// 2. **配不齐 / URL 有毛病时一个字节都不发**——发注定失败的请求只是浪费；
/// 3. 失败原因复用生成器那套映射（401 说密钥、404 说 URL 与模型名），
///    用户看到的是「该改哪里」，不是状态码。
final class MinutesAPIProbeTests: XCTestCase {

    // MARK: - 成功

    func testSuccessReportsModelLatencyAndReply() async {
        let transport = StubTransport { _ in
            (ProbeFixtures.okBody(content: "就绪"), ProbeFixtures.http(200))
        }

        let outcome = await MinutesAPIProbe.run(
            configuration: ProbeFixtures.configuration(), transport: transport)

        guard case let .ok(model, _, reply) = outcome else {
            return XCTFail("应成功，实际：\(outcome)")
        }
        XCTAssertEqual(model, "deepseek-chat")
        XCTAssertEqual(reply, "就绪")
        XCTAssertTrue(outcome.isOK)
        XCTAssertTrue(outcome.summary.contains("连接成功"))
        XCTAssertTrue(outcome.summary.contains("就绪"), "结果里要能看见模型答了什么")
    }

    /// 回显**服务报上来的**模型名，不是我们发过去的那个。
    /// 有的服务会做路由替换，用户看到真实生效的模型才不会误判。
    func testSuccessEchoesModelReportedByService() async {
        let transport = StubTransport { _ in
            (ProbeFixtures.okBody(model: "deepseek-chat-0324"), ProbeFixtures.http(200))
        }

        let outcome = await MinutesAPIProbe.run(
            configuration: ProbeFixtures.configuration(), transport: transport)

        guard case let .ok(model, _, _) = outcome else {
            return XCTFail("应成功，实际：\(outcome)")
        }
        XCTAssertEqual(model, "deepseek-chat-0324")
    }

    // MARK: - 边界：不含会议内容

    /// **最要紧的一条**：探测请求体里不能出现任何会议内容。
    ///
    /// 实现上它靠的是「prompt 是写死的常量 + 不接收 transcript」，
    /// 但这条性质一旦被破坏（有人图省事改成「拿最近一场会议试试」）
    /// 就是隐私事故，且界面与文档都不会报警——所以钉死在这里。
    func testProbeRequestCarriesNoTranscriptContent() async throws {
        let transport = StubTransport { _ in
            (ProbeFixtures.okBody(), ProbeFixtures.http(200))
        }

        _ = await MinutesAPIProbe.run(
            configuration: ProbeFixtures.configuration(), transport: transport)

        // 先取值再 unwrap：`XCTUnwrap` 的参数是 autoclosure，装不下 `await`。
        let captured = await transport.lastRequest
        let request = try XCTUnwrap(captured)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(body.contains(MinutesAPIProbe.probePrompt),
                      "探测只发固定短句，实际 body：\(body)")
        // 纪要提示词的特征词一个都不该出现
        for leak in ["会议", "说话人", "摘要", "待办", "transcript", "actionItems"] {
            XCTAssertFalse(body.contains(leak),
                           "探测请求里不该出现「\(leak)」——那意味着会议内容被发出去了")
        }
        XCTAssertTrue(body.contains("\"max_tokens\":8"), "探测要短到几乎不产生费用")
    }

    func testProbeRequestCarriesAuthorizationHeader() async throws {
        let transport = StubTransport { _ in
            (ProbeFixtures.okBody(), ProbeFixtures.http(200))
        }
        _ = await MinutesAPIProbe.run(
            configuration: ProbeFixtures.configuration(), transport: transport)

        let captured = await transport.lastRequest
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-probe-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    // MARK: - 边界：不配齐 / URL 有毛病时不发请求

    func testIncompleteConfigurationFailsWithoutSendingAnything() async {
        let transport = StubTransport { _ in
            (ProbeFixtures.okBody(), ProbeFixtures.http(200))
        }

        let outcome = await MinutesAPIProbe.run(
            configuration: ProbeFixtures.configuration(apiKey: "", model: ""),
            transport: transport)

        XCTAssertFalse(outcome.isOK)
        let sends = await transport.sendCount
        XCTAssertEqual(sends, 0, "缺配置时不许发请求")
        guard case let .failed(reason) = outcome else { return XCTFail("应失败") }
        XCTAssertTrue(reason.contains("API Key"), "要说清缺哪项：\(reason)")
        XCTAssertTrue(reason.contains("模型名"), "要说清缺哪项：\(reason)")
    }

    /// 明文 http 且不是回环：发出去等于把 API Key 明文过一遍网络。
    /// 探测也必须在这里就拦住——否则用户会以为「测通了就没事」。
    func testPlainHTTPToRemoteHostIsRejectedBeforeSending() async {
        let transport = StubTransport { _ in
            (ProbeFixtures.okBody(), ProbeFixtures.http(200))
        }

        let outcome = await MinutesAPIProbe.run(
            configuration: ProbeFixtures.configuration(
                baseURL: "http://api.example.com/v1", apiKey: "k", model: "m"),
            transport: transport)

        let sends = await transport.sendCount
        XCTAssertEqual(sends, 0)
        guard case let .failed(reason) = outcome else { return XCTFail("应失败") }
        XCTAssertTrue(reason.contains("明文"), "要说清为什么拦：\(reason)")
    }

    /// 本机自建（http 回环）放行——否则 ollama 用户根本没法用探测。
    func testLoopbackPlainHTTPIsAllowed() async {
        let transport = StubTransport { _ in
            (ProbeFixtures.okBody(), ProbeFixtures.http(200))
        }

        let outcome = await MinutesAPIProbe.run(
            configuration: ProbeFixtures.configuration(
                baseURL: "http://127.0.0.1:11434/v1", apiKey: "", model: "qwen2.5:7b"),
            transport: transport)

        XCTAssertTrue(outcome.isOK, "本机服务不该被密钥拦住，实际：\(outcome)")
        let sends = await transport.sendCount
        XCTAssertEqual(sends, 1)

        // 密钥为空时**不能**发空的 Bearer 头：值是空的 `Bearer `
        // 会被一部分网关当成「提供了错误凭据」，报出来的错还指向密钥。
        let captured = await transport.lastRequest
        let request = try? XCTUnwrap(captured)
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"),
                     "本机服务不应收到 Authorization 头")
    }

    // MARK: - 失败原因可操作

    func testUnauthorizedGivesKeySpecificReason() async {
        let transport = StubTransport { _ in
            (Data(#"{"error":{"message":"invalid api key"}}"#.utf8), ProbeFixtures.http(401))
        }

        let outcome = await MinutesAPIProbe.run(
            configuration: ProbeFixtures.configuration(), transport: transport)

        guard case let .failed(reason) = outcome else { return XCTFail("应失败") }
        XCTAssertTrue(reason.contains("密钥"), "401 要指向密钥：\(reason)")
    }

    func testNotFoundPointsAtURLAndModel() async {
        let transport = StubTransport { _ in
            (Data("not found".utf8), ProbeFixtures.http(404))
        }

        let outcome = await MinutesAPIProbe.run(
            configuration: ProbeFixtures.configuration(), transport: transport)

        guard case let .failed(reason) = outcome else { return XCTFail("应失败") }
        XCTAssertTrue(reason.contains("404"), "404 要提到状态码：\(reason)")
        XCTAssertTrue(reason.contains("版本号"), "404 要指向 Base URL 填法：\(reason)")
    }

    /// 200 但不是 API（填成了网页地址）：这是最常见的填错，
    /// 原因里必须直接教用户怎么改。
    func testNonAPIResponseExplainsVersionPath() async {
        let transport = StubTransport { _ in
            (Data("<html>login</html>".utf8), ProbeFixtures.http(200))
        }

        let outcome = await MinutesAPIProbe.run(
            configuration: ProbeFixtures.configuration(), transport: transport)

        guard case let .failed(reason) = outcome else { return XCTFail("应失败") }
        XCTAssertTrue(reason.contains("含版本号"), "要教用户 Base URL 填到哪一层：\(reason)")
    }

    func testTimeoutIsReportedAsTimeout() async {
        let transport = StubTransport { _ in throw URLError(.timedOut) }

        let outcome = await MinutesAPIProbe.run(
            configuration: ProbeFixtures.configuration(), transport: transport)

        guard case let .failed(reason) = outcome else { return XCTFail("应失败") }
        XCTAssertTrue(reason.contains("超时"), "要能一眼看出是超时：\(reason)")
    }

    /// 200 + choices 但内容为空：也算失败——通了但答不上来，
    /// 让用户以为「测通了」就会在真跑会议时才发现问题。
    /// 超长回复要截断——界面上那是一行，不是日志。
/// 实测踩到：对假服务测试时它回整段纪要 JSON，结论行被撑成一大片。
func testLongReplyIsTruncatedInTheSummary() async {
    let long = String(repeating: "会议纪要内容", count: 30)
    let transport = StubTransport { _ in
        (ProbeFixtures.okBody(content: long), ProbeFixtures.http(200))
    }

    let outcome = await MinutesAPIProbe.run(
        configuration: ProbeFixtures.configuration(), transport: transport)

    XCTAssertTrue(outcome.isOK)
    guard case let .ok(_, _, reply) = outcome else { return XCTFail("应成功") }
    XCTAssertEqual(reply, long, "Outcome 本身保留完整回复，不在这里丢信息")
    XCTAssertTrue(outcome.summary.hasSuffix("…）"), "摘要里要截断：\(outcome.summary)")
    XCTAssertLessThan(outcome.summary.count, 80, "结论行必须是一行的量级")
}

func testEmptyReplyIsAFailure() async {
        let transport = StubTransport { _ in
            (ProbeFixtures.okBody(content: "   "), ProbeFixtures.http(200))
        }

        let outcome = await MinutesAPIProbe.run(
            configuration: ProbeFixtures.configuration(), transport: transport)

        XCTAssertFalse(outcome.isOK, "空回复不算通")
    }

    // MARK: - 服务商预设

    /// 预设里的 Base URL 必须都填到含版本号那一层，
    /// 否则「一键填好」反而把用户带进 404。
    func testEveryPresetBaseURLTargetsTheVersionedPath() {
        for preset in MinutesServicePreset.allCases {
            let config = CloudAPIConfiguration(
                baseURL: preset.baseURL, apiKey: "k", model: preset.suggestedModel)
            XCTAssertNil(config.urlProblem,
                         "\(preset.displayName) 的 Base URL 有问题：\(config.urlProblem ?? "")")
            XCTAssertTrue(config.endpointString.hasSuffix("/chat/completions"),
                          "\(preset.displayName) 拼出的地址不对：\(config.endpointString)")
            XCTAssertFalse(preset.note.isEmpty, "\(preset.displayName) 缺申请密钥的说明")
            XCTAssertFalse(preset.suggestedModel.isEmpty)
        }
    }

    /// 本机自建走 http 回环——它是唯一允许 http 的那档（密钥不过网）。
    func testOllamaPresetIsLoopbackAndValidates() {
        let config = CloudAPIConfiguration(
            baseURL: MinutesServicePreset.ollama.baseURL,
            apiKey: "ollama",
            model: MinutesServicePreset.ollama.suggestedModel)
        XCTAssertNil(config.urlProblem)
        XCTAssertTrue(MinutesServicePreset.ollama.note.contains("ollama pull"))
    }

    func testPresetDisplayNamesAreUnique() {
        let names = MinutesServicePreset.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "预设名重复会让界面上的按钮认不出来")
    }
}

/// 假传输层。**必须是 actor**：单测并行执行时共享一个实例的 `lastRequest`
/// 会互相覆盖，而那种红只在高负载下偶发，最难查。
/// 测试侧一律 `await transport.…` 取值——跨 actor 读属性必须显式等。
private actor StubTransport: MinutesAPITransport {
    private let responder: @Sendable (URLRequest) throws -> (Data, URLResponse)
    private var storedRequest: URLRequest?
    private(set) var sendCount = 0

    init(responder: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)) {
        self.responder = responder
    }

    var lastRequest: URLRequest? { storedRequest }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        sendCount += 1
        storedRequest = request
        return try responder(request)
    }
}