import Foundation
import XCTest
@testable import MRMinutes
import MRCore

/// 假传输层：不真发网络请求，按脚本返回响应 / 抛错。
///
/// 单测里真调外网是最难查的一类红（结果取决于服务商状态与网络），
/// 所以这里把「网络」整层换掉，只验证**我们这一侧**的行为：
/// 请求长什么样、响应怎么解析、失败怎么映射。
///
/// 做成 **actor** 而不是带锁的 class：它天然是跨任务共享的可变状态，
/// actor 用编译器保证这一点，`@unchecked Sendable` 则是把保证推给「记得别并发」。
actor FakeMinutesTransport: MinutesAPITransport {
    struct Call: Equatable {
        var url: String
        var method: String
        var authorization: String?
        var contentType: String?
        var body: String
    }

    private(set) var calls: [Call] = []
    private let responseBlock: (URLRequest) throws -> (Data, URLResponse)

    init(responder: @escaping (URLRequest) throws -> (Data, URLResponse)) {
        self.responseBlock = responder
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        calls.append(Call(
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: String(decoding: request.httpBody ?? Data(), as: UTF8.self)))
        return try responseBlock(request)
    }
}

/// 造一个 200 响应，content 为给定文本。
private func httpResponse(status: Int, url: URL, body: String = "") -> HTTPURLResponse {
    HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])!
}

/// OpenAI 兼容的成功响应壳。
private func chatResponse(content: String) -> String {
    """
    {"choices":[{"index":0,"message":{"role":"assistant","content":\(TestJSON.string(content))},"finish_reason":"stop"}]}
    """
}

/// 测试用的 JSON 小工具。
private enum TestJSON {
    /// 把任意文本安全地嵌进 JSON 字符串字面量。
    static func string(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed])
        // ["..."] 去掉方括号即是带引号的 JSON 字符串
        let s = String(decoding: data ?? Data(), as: UTF8.self)
        return String(s.dropFirst().dropLast())
    }

    /// 从请求体里取出最后一条 user 消息的 content。
    static func userMessage(from body: String) throws -> String {
        let json = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        let messages = json?["messages"] as? [[String: Any]]
        return messages?.last?["content"] as? String ?? ""
    }
}

// MARK: - 配置校验

final class CloudAPIConfigurationTests: XCTestCase {

    func testEndpointAppendsChatCompletions_withoutGuessingVersionPath() {
        let config = CloudAPIConfiguration(
            baseURL: "https://api.deepseek.com/v1", apiKey: "k", model: "m")
        XCTAssertEqual(config.endpointString, "https://api.deepseek.com/v1/chat/completions")

        // 尾部斜杠要去掉，不然拼出 //chat/completions
        let slashed = CloudAPIConfiguration(
            baseURL: "https://api.deepseek.com/v1/", apiKey: "k", model: "m")
        XCTAssertEqual(slashed.endpointString, "https://api.deepseek.com/v1/chat/completions")

        // 不猜 /v1：用户填到哪一层就从哪一层拼。dashscope 的 compatible-mode
        // 与直接 /v1 是两条不同路径，猜一个就会在另一家服务上静默 404。
        let dashscope = CloudAPIConfiguration(
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", apiKey: "k", model: "m")
        XCTAssertEqual(dashscope.endpointString,
                       "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
    }

    func testLoopbackHTTPIsAllowed_remoteHTTPIsNot() {
        // 本机自建服务（ollama / LM Studio）是明文 http——误伤它们没道理
        for host in ["http://127.0.0.1:11434/v1", "http://localhost:1234/v1", "http://[::1]:8080/v1"] {
            XCTAssertNil(CloudAPIConfiguration(baseURL: host, apiKey: "k", model: "m").urlProblem,
                         "回环地址的 http 应放行：\(host)")
        }
        // 第三方明文 http：API Key 会明文在网络上走一遍，必须拒绝
        let remote = CloudAPIConfiguration(
            baseURL: "http://api.example.com/v1", apiKey: "sk-secret", model: "m")
        XCTAssertNotNil(remote.urlProblem, "第三方 http 必须拒绝")
        XCTAssertTrue(remote.urlProblem?.contains("明文") == true)
    }

    func testMalformedURLIsRejected() {
        let config = CloudAPIConfiguration(
            baseURL: "https://api.deepseek.com/v1\n", apiKey: "k", model: "m")
        XCTAssertNil(config.urlProblem, "构造时已去首尾空白")

        let garbage = CloudAPIConfiguration(baseURL: "不是URL", apiKey: "k", model: "m")
        XCTAssertNotNil(garbage.urlProblem)
    }

    func testMissingFieldsListsDisplayNames() {
        let empty = CloudAPIConfiguration(baseURL: "", apiKey: "", model: "")
        XCTAssertEqual(empty.missingFields, ["Base URL", "API Key", "模型名"])
        XCTAssertFalse(empty.isComplete)

        let full = CloudAPIConfiguration(
            baseURL: "https://api.deepseek.com/v1", apiKey: "sk-x", model: "deepseek-chat")
        XCTAssertTrue(full.isComplete)
        XCTAssertEqual(full.missingFields, [])
        XCTAssertEqual(full.hostForDisplay, "api.deepseek.com")
    }
}

// MARK: - 生成器

final class CloudAPIMinutesGeneratorTests: XCTestCase {

    private func makeGenerator(
        baseURL: String = "https://api.deepseek.com/v1",
        apiKey: String = "sk-test-123456",
        model: String = "deepseek-chat",
        transport: any MinutesAPITransport
    ) -> CloudAPIMinutesGenerator {
        CloudAPIMinutesGenerator(
            configuration: CloudAPIConfiguration(baseURL: baseURL, apiKey: apiKey, model: model),
            transport: transport)
    }

    private func sampleBlock() -> TranscriptBlock {
        TranscriptBlock(index: 1, start: 0, end: 10, text: "我：我们先讨论排期\n对方：好的")
    }

    // MARK: 请求形状

    func test_summarize_sendsOpenAICompatibleRequest() async throws {
        let transport = FakeMinutesTransport { request in
            (Data(chatResponse(content: """
                {"polishedText":"我们先讨论排期。","summary":"讨论排期","keyPoints":["排期"],
                "decisions":[],"actionItems":[]}
                """).utf8), httpResponse(status: 200, url: request.url!))
        }
        let generator = makeGenerator(transport: transport)

        let summary = try await generator.summarize(block: sampleBlock())

        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
        let call = calls[0]
        XCTAssertEqual(call.url, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.authorization, "Bearer sk-test-123456")
        XCTAssertEqual(call.contentType, "application/json")

        // 请求体字段：model / messages(role+content) / stream=false
        let body = try JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "deepseek-chat")
        XCTAssertEqual(body?["stream"] as? Bool, false)
        let messages = body?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?.first?["role"] as? String, "system")
        XCTAssertEqual(messages?.last?["role"] as? String, "user")
        XCTAssertTrue((messages?.last?["content"] as? String)?.contains("我们先讨论排期") == true)

        // 解析结果
        XCTAssertEqual(summary.index, 1)
        XCTAssertEqual(summary.polishedText, "我们先讨论排期。")
        XCTAssertEqual(summary.summary, "讨论排期")
    }

    func test_merge_usesBlockSummariesAsInput() async throws {
        let transport = FakeMinutesTransport { request in
            (Data(chatResponse(content: """
                {"summary":"全局摘要","keyPoints":["要点A"],"decisions":["决议A"],
                "actionItems":[{"task":"写周报","owner":"","due":"周五"}]}
                """).utf8), httpResponse(status: 200, url: request.url!))
        }
        let generator = makeGenerator(transport: transport)

        let minutes = try await generator.merge(summaries: [
            BlockSummary(index: 1, polishedText: "p1", summary: "局部1",
                         keyPoints: ["要点A"], decisions: ["决议A"],
                         actionItems: [ActionItem(task: "写周报", due: "周五")]),
            BlockSummary(index: 2, polishedText: "p2", summary: "局部2",
                         keyPoints: [], decisions: [], actionItems: []),
        ])

        let calls = await transport.calls
        let userMessage = try TestJSON.userMessage(from: calls[0].body)
        XCTAssertTrue(userMessage.contains("[第1段]"), "reduce 输入应含分段标记")
        XCTAssertTrue(userMessage.contains("局部1"))
        XCTAssertTrue(userMessage.contains("写周报"))

        XCTAssertEqual(minutes.summary, "全局摘要")
        XCTAssertEqual(minutes.actionItems.first?.task, "写周报")
        XCTAssertEqual(minutes.actionItems.first?.due, "周五")
        XCTAssertEqual(minutes.actionItems.first?.owner, "", "未提及的负责人必须是空串，不是「无」")
    }

    // MARK: 宽松解析

    func test_parsing_toleratesCodeFenceAndSnakeCase() async throws {
        // 真实观测：模型爱包 ```json 围栏，还爱把字段写成 snake_case。
        // 一次成功的调用不该因为这些被判失败——钱已经花了。
        let transport = FakeMinutesTransport { request in
            let content = """
                ```json
                {"polished_text":"正文。","summary":"摘要","key_points":["要点"],
                "decisions":[],"action_items":[{"task":"任务","owner":"未提及","due":"N/A"}]}
                ```
                """
            return (Data(chatResponse(content: content).utf8),
                    httpResponse(status: 200, url: request.url!))
        }
        let generator = makeGenerator(transport: transport)

        let summary = try await generator.summarize(block: sampleBlock())

        XCTAssertEqual(summary.polishedText, "正文。")
        XCTAssertEqual(summary.keyPoints, ["要点"])
        XCTAssertEqual(summary.actionItems.first?.task, "任务")
        XCTAssertEqual(summary.actionItems.first?.owner, "", "「未提及」必须收敛成空串")
        XCTAssertEqual(summary.actionItems.first?.due, "", "「N/A」必须收敛成空串")
    }

    func test_unparseableOutput_throwsAPICallWithSnippet() async throws {
        let transport = FakeMinutesTransport { request in
            (Data(chatResponse(content: "我觉得这场会议挺好的，没有要总结的。").utf8),
             httpResponse(status: 200, url: request.url!))
        }
        let generator = makeGenerator(transport: transport)

        do {
            _ = try await generator.summarize(block: sampleBlock())
            XCTFail("取不出 JSON 必须抛错，绝不能猜")
        } catch let MinutesError.apiCall(reason) {
            XCTAssertTrue(reason.contains("找不到 JSON"), "原因应说明是解析失败：\(reason)")
            XCTAssertTrue(reason.contains("这场会议挺好"), "原因应带原文片段便于排查")
        }
    }

    func test_wrongFieldType_throwsRatherThanSilentlyDropping() async throws {
        // keyPoints 给了字符串而不是数组：报错并带上片段。
        // 静默丢内容的纪要比报错的纪要危险得多。
        let transport = FakeMinutesTransport { request in
            (Data(chatResponse(content: """
                {"polishedText":"正文","summary":"摘要","keyPoints":"要点A、要点B",
                "decisions":[],"actionItems":[]}
                """).utf8), httpResponse(status: 200, url: request.url!))
        }
        let generator = makeGenerator(transport: transport)

        do {
            _ = try await generator.summarize(block: sampleBlock())
            XCTFail("字段类型不符必须抛错")
        } catch let MinutesError.apiCall(reason) {
            XCTAssertTrue(reason.contains("字段不符合约定"), "：\(reason)")
        }
    }

    // MARK: 失败映射

    func test_http401_mapsToKeyHint() async throws {
        let transport = FakeMinutesTransport { request in
            (Data("{\"error\":{\"message\":\"invalid api key\"}}".utf8),
             httpResponse(status: 401, url: request.url!))
        }
        let generator = makeGenerator(transport: transport)

        do {
            _ = try await generator.summarize(block: sampleBlock())
            XCTFail("401 必须抛 apiCall")
        } catch let MinutesError.apiCall(reason) {
            XCTAssertTrue(reason.contains("密钥"), "401 的提示必须指向密钥：\(reason)")
        }
    }

    func test_http404_mapsToBaseURLHint() async throws {
        let transport = FakeMinutesTransport { request in
            (Data("".utf8), httpResponse(status: 404, url: request.url!))
        }
        let generator = makeGenerator(transport: transport)

        do {
            _ = try await generator.summarize(block: sampleBlock())
            XCTFail("404 必须抛 apiCall")
        } catch let MinutesError.apiCall(reason) {
            XCTAssertTrue(reason.contains("Base URL"), "404 的提示必须指向 Base URL：\(reason)")
        }
    }

    func test_http429_mapsToRateLimit() async throws {
        let transport = FakeMinutesTransport { request in
            (Data("".utf8), httpResponse(status: 429, url: request.url!))
        }
        let generator = makeGenerator(transport: transport)

        do {
            _ = try await generator.summarize(block: sampleBlock())
            XCTFail("429 必须抛 apiCall")
        } catch let MinutesError.apiCall(reason) {
            XCTAssertTrue(reason.contains("限流"), "：\(reason)")
        }
    }

    func test_transportFailure_mapsToNetworkHint() async throws {
        struct Boom: Error {}
        let transport = FakeMinutesTransport { _ in throw URLError(.notConnectedToInternet) }
        let generator = makeGenerator(transport: transport)

        do {
            _ = try await generator.summarize(block: sampleBlock())
            XCTFail("网络失败必须抛 apiCall，不能当空响应")
        } catch let MinutesError.apiCall(reason) {
            XCTAssertTrue(reason.contains("网络"), "：\(reason)")
        }
    }

    func test_http200WithErrorBody_isSurfaced() async throws {
        // 有些代理层把错误放在 200 里
        let transport = FakeMinutesTransport { request in
            (Data("{\"error\":{\"message\":\"quota exceeded\"}}".utf8),
             httpResponse(status: 200, url: request.url!))
        }
        let generator = makeGenerator(transport: transport)

        do {
            _ = try await generator.summarize(block: sampleBlock())
            XCTFail("200 里的错误体必须被识别为失败")
        } catch let MinutesError.apiCall(reason) {
            XCTAssertTrue(reason.contains("quota exceeded"), "：\(reason)")
        }
    }

    // MARK: 可用性

    func test_isAvailable_requiresCompleteAndValidConfig() {
        let ok = makeGenerator(transport: FakeMinutesTransport { r in
            (Data(), httpResponse(status: 200, url: r.url!))
        })
        XCTAssertTrue(ok.isAvailable)
        XCTAssertTrue(ok.displayName.contains("deepseek-chat"))
        XCTAssertTrue(ok.displayName.contains("api.deepseek.com"))

        let incomplete = CloudAPIMinutesGenerator(
            configuration: CloudAPIConfiguration(baseURL: "", apiKey: "", model: ""),
            transport: URLSessionMinutesTransport())
        XCTAssertFalse(incomplete.isAvailable)
        XCTAssertTrue(incomplete.unavailableReason?.contains("Base URL") == true,
                      "不可用原因必须说清缺什么")

        let insecure = CloudAPIMinutesGenerator(
            configuration: CloudAPIConfiguration(
                baseURL: "http://api.example.com/v1", apiKey: "k", model: "m"),
            transport: URLSessionMinutesTransport())
        XCTAssertFalse(insecure.isAvailable)
        XCTAssertTrue(insecure.unavailableReason?.contains("明文") == true)
    }
}

// MARK: - 解析器

final class MinutesGeneratorResolverTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "mr-minutes-resolver-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    private func prefs() -> RecorderPreferences {
        RecorderPreferences(defaults: defaults)
    }

    /// 默认（没设过）= 本地生成器。
    func test_defaultResolvesToLocalGenerator() {
        let resolution = MinutesGeneratorResolver.resolve(preferences: prefs())
        guard case let .ready(generator) = resolution else {
            return XCTFail("默认应解析出生成器，实际：\(resolution)")
        }
        // macOS 26 部署目标下本地实现可用；机型不支持时它是
        // isAvailable == false 的 FoundationModels 实现——那也是「本地」这一档，
        // 由 orchestrator 决定降级。这里只断言不是云端、不是 blocked。
        XCTAssertFalse(generator.displayName.contains("云端"))
    }

    /// 云端配齐 → 云端生成器。
    func test_cloudAPI_resolvesWhenComplete() {
        let p = prefs()
        p.minutesProvider = .cloudAPI
        p.minutesAPIBaseURL = "https://api.deepseek.com/v1"
        p.minutesAPIKey = "sk-abc"
        p.minutesModel = "deepseek-chat"

        let resolution = MinutesGeneratorResolver.resolve(preferences: p)
        guard case let .ready(generator) = resolution else {
            return XCTFail("配齐了应解析出生成器，实际：\(resolution)")
        }
        XCTAssertTrue(generator.displayName.contains("deepseek-chat"))
        XCTAssertTrue(generator.isAvailable)
    }

    /// 云端没配齐 → **blocked，不是本地**。用户选了云端却拿到本地产出，是谎报。
    func test_cloudAPI_blocksWhenIncomplete() {
        let p = prefs()
        p.minutesProvider = .cloudAPI
        p.minutesAPIKey = "sk-abc"  // 缺 URL 与模型名

        let resolution = MinutesGeneratorResolver.resolve(preferences: p)
        guard case let .blocked(reason) = resolution else {
            return XCTFail("没配齐必须 blocked，不能静默回退本地")
        }
        XCTAssertTrue(reason.contains("Base URL"))
        XCTAssertTrue(reason.contains("模型名"))
        XCTAssertTrue(reason.contains("config set minutes-url"),
                      "原因必须带上要敲的命令：\(reason)")
    }

    /// 云端 URL 是第三方明文 http → blocked（Key 会明文外发）。
    func test_cloudAPI_blocksOnInsecureRemoteURL() {
        let p = prefs()
        p.minutesProvider = .cloudAPI
        p.minutesAPIBaseURL = "http://api.example.com/v1"
        p.minutesAPIKey = "sk-abc"
        p.minutesModel = "m"

        let resolution = MinutesGeneratorResolver.resolve(preferences: p)
        guard case let .blocked(reason) = resolution else {
            return XCTFail("第三方 http 必须 blocked")
        }
        XCTAssertTrue(reason.contains("明文"))
    }

    /// 本机自建服务放行。
    func test_cloudAPI_allowsLoopbackHTTP() {
        let p = prefs()
        p.minutesProvider = .cloudAPI
        p.minutesAPIBaseURL = "http://127.0.0.1:11434/v1"
        p.minutesAPIKey = "ollama"
        p.minutesModel = "qwen3"

        let resolution = MinutesGeneratorResolver.resolve(preferences: p)
        guard case let .ready(generator) = resolution else {
            return XCTFail("回环 http 应放行，实际：\(resolution)")
        }
        XCTAssertTrue(generator.isAvailable)
    }

    /// 坏 provider 值回退 local（RecorderPreferences 的读法保证），
    /// 这里确认解析器因此也走本地档。
    func test_unknownProviderFallsBackToLocal() {
        defaults.set("openai", forKey: RecorderPreferences.minutesProviderKey)
        let resolution = MinutesGeneratorResolver.resolve(preferences: prefs())
        guard case let .ready(generator) = resolution else {
            return XCTFail("坏值应回退本地档")
        }
        XCTAssertFalse(generator.displayName.contains("云端"))
    }
}

// MARK: - 编排器与溯源名

final class MinutesGeneratorNameTests: XCTestCase {

    /// 带显示名的假生成器：验证 orchestrator 把 generatorName 透传进结果。
    final class NamedFake: MinutesGenerator {
        var isAvailable: Bool { true }
        var displayName: String { "测试模型（fake）" }
        func summarize(block: TranscriptBlock) async throws -> BlockSummary {
            BlockSummary(index: block.index, polishedText: "p", summary: "s",
                         keyPoints: [], decisions: [], actionItems: [])
        }
        func merge(summaries: [BlockSummary]) async throws -> MeetingMinutes {
            MeetingMinutes(summary: "m")
        }
    }

    func test_generatorNameIsRecordedForProvenance() async throws {
        let doc = TranscriptDocument(
            sessionID: "x", title: "x", language: "zh-CN", engine: "x",
            segments: [TranscriptSegment(start: 0, end: 5, text: "测试",
                                         track: "mic", speaker: "我")])
        let result = try await MinutesOrchestrator(generator: NamedFake()).generate(for: doc)
        XCTAssertEqual(result.generatorName, "测试模型（fake）",
                       "纪要必须能自证是谁生成的——尤其云端那份花了钱、稿子离开过本机")
    }
}
