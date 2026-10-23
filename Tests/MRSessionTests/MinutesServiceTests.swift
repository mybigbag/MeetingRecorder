import XCTest
@testable import MRSession
import MRCore
import MRMinutes

/// `MinutesService` 的端到端回归测试。
///
/// 关键意图：单元测试里 `MinutesOrchestrator` 直接吃内存中的 `TranscriptDocument`，
/// 绕过了「磁盘读 `transcript.json`」这一步。而真实 `transcript.json` 的日期字段
/// 用 `.iso8601` 编码（`TranscriptDocument.json()`），`MinutesService` 若用默认
/// `JSONDecoder`（期望 Double 时间戳）解码就会 **typeMismatch 崩溃**——
/// 这个 bug 只在真实磁盘往返时才暴露。本测试用项目真实的编码器写出 fixture，
/// 确保读取路径与产出方编码策略一致。
final class MinutesServiceTests: XCTestCase {

    private var root: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-minutes-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SessionStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 用项目真实编码器（`TranscriptDocument.json()`，ISO8601 日期）写出一个
    /// 合法的 `transcript.json`，模拟 `transcribe` 的真实产物。
    private func writeRealTranscript(sessionID: String) throws -> URL {
        let doc = TranscriptDocument(
            sessionID: sessionID,
            title: "回归测试会议",
            language: "zh-CN",
            engine: "apple-speech",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            segments: [
                TranscriptSegment(start: 0, end: 12.3,
                    text: "我们今天讨论一下下个季度的排期问题吧", track: "mic", speaker: "我"),
                TranscriptSegment(start: 12.5, end: 30.1,
                    text: "好的我觉得应该优先把支付模块上线因为用户投诉比较多",
                    track: "system", speaker: "对方"),
            ])
        let dir = store.directory(forSessionID: sessionID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try doc.json().write(to: dir.appendingPathComponent(SessionStore.transcriptJSONName))
        return dir
    }

    /// 验证：用真实 ISO8601 编码的 transcript.json 能被正确读取、且确定性降级路径
    /// 不崩溃、产物诚实（不假装修标点、不编造摘要）。
    func test_readRealTranscriptAndDegradeHonestly() async throws {
        let sessionID = "svc-test"
        _ = try writeRealTranscript(sessionID: sessionID)

        // 用显式不可用的生成器，让降级路径在所有机器上确定性触发，
        // 不依赖本机是否开启了 Apple Intelligence。
        let outcome = try await MinutesService(store: store)
            .generate(sessionID: sessionID, generator: UnavailableMinutesGenerator())

        // 1) 降级标记正确
        XCTAssertFalse(outcome.result.generatedByModel, "强制不可用应走降级")

        // 2) 文件都落了地
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: outcome.markdownURL.path))
        XCTAssertTrue(fm.fileExists(atPath: outcome.jsonURL.path))

        // 3) 降级不假装修标点——polishedTranscript 应等于原稿渲染，
        //    原文无标点，降级输出也不得出现任何新增标点。
        let expected = "我：我们今天讨论一下下个季度的排期问题吧\n"
            + "对方：好的我觉得应该优先把支付模块上线因为用户投诉比较多"
        XCTAssertEqual(outcome.result.polishedTranscript, expected,
                       "降级不得假装修标点，必须原样保留")

        // 4) 摘要/要点/决议/待办在降级下为空（或明确标注未生成）
        XCTAssertTrue(outcome.result.minutes.summary.contains("未生成"),
                      "降级摘要应明确标注未生成")
        XCTAssertTrue(outcome.result.minutes.keyPoints.isEmpty)
        XCTAssertTrue(outcome.result.minutes.decisions.isEmpty)
        XCTAssertTrue(outcome.result.minutes.actionItems.isEmpty)

        // 5) markdown 里带有降级警示，且不含伪造的要点
        let md = try String(contentsOf: outcome.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("本地纪要模型不可用"), "md 应说明降级原因")
        XCTAssertTrue(md.contains("未生成任何摘要或待办"), "md 应声明未生成待办")
    }

    /// 验证：未转写（无 transcript.json）时给出明确错误而非静默降级。
    func test_missingTranscriptThrows() async {
        let sessionID = "no-transcript"
        _ = store.directory(forSessionID: sessionID) // 目录不存在也没关系
        do {
            _ = try await MinutesService(store: store)
                .generate(sessionID: sessionID, generator: UnavailableMinutesGenerator())
            XCTFail("缺少 transcript.json 应抛错")
        } catch {
            // 期望是 IO 类错误（提示先转写）
            XCTAssertTrue("\(error)".contains("尚未转写") || "\(error)".contains("transcribe"),
                          "错误应提示先转写，而非静默降级：\(error)")
        }
    }
}

/// 云端路径专用的回归：**失败不降级**、溯源名落盘、旧纪要文件可读。
final class MinutesServiceCloudTests: XCTestCase {

    private var root: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-minutes-cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SessionStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeRealTranscript(sessionID: String) throws {
        let doc = TranscriptDocument(
            sessionID: sessionID,
            title: "云端回归会议",
            language: "zh-CN",
            engine: "apple-speech",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            segments: [
                TranscriptSegment(start: 0, end: 12.3,
                    text: "我们今天讨论一下下个季度的排期问题吧", track: "mic", speaker: "我"),
                TranscriptSegment(start: 12.5, end: 30.1,
                    text: "好的我觉得应该优先把支付模块上线因为用户投诉比较多",
                    track: "system", speaker: "对方"),
            ])
        let dir = store.directory(forSessionID: sessionID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try doc.json().write(to: dir.appendingPathComponent(SessionStore.transcriptJSONName))
    }

    /// 正常工作的假生成器，带一个可区分的 displayName。
    private struct WorkingGenerator: MinutesGenerator {
        var isAvailable: Bool { true }
        var displayName: String { "测试云端（fake-model @ fake.host）" }

        func summarize(block: TranscriptBlock) async throws -> BlockSummary {
            BlockSummary(index: block.index, polishedText: "（修复后）\(block.text)",
                         summary: "局部\(block.index)", keyPoints: ["要点\(block.index)"],
                         decisions: [], actionItems: [])
        }

        func merge(summaries: [BlockSummary]) async throws -> MeetingMinutes {
            MeetingMinutes(summary: "全局摘要", keyPoints: ["全局要点"], decisions: ["全局决议"],
                           actionItems: [ActionItem(task: "待办", owner: "", due: "")])
        }
    }

    /// 云端 API 调用失败（网络/鉴权/限流/响应不合法）必须**上抛且不写文件**。
    ///
    /// 反面对照：如果这里被降级稿接住，用户看到的会是「这场没有摘要」——
    /// 一次 401 就这样伪装成模型的判断。用户显式选了云端并花了钱，
    /// 失败必须响亮。
    func test_apiCallFailurePropagates_andWritesNothing() async throws {
        let sessionID = "cloud-fail"
        try writeRealTranscript(sessionID: sessionID)

        struct FailingGenerator: MinutesGenerator {
            var isAvailable: Bool { true }
            func summarize(block: TranscriptBlock) async throws -> BlockSummary {
                throw MinutesError.apiCall(reason: "密钥无效或没有该模型的权限（HTTP 401）")
            }
            func merge(summaries: [BlockSummary]) async throws -> MeetingMinutes {
                throw MinutesError.apiCall(reason: "不该走到 reduce")
            }
        }

        do {
            _ = try await MinutesService(store: store)
                .generate(sessionID: sessionID, generator: FailingGenerator())
            XCTFail("apiCall 必须上抛")
        } catch let MinutesError.apiCall(reason) {
            XCTAssertTrue(reason.contains("401"), "：\(reason)")
        }

        // 一个字节都不该写——失败后目录里只有 transcript.json
        let dir = store.directory(forSessionID: sessionID)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, [SessionStore.transcriptJSONName],
                       "失败不得留下降级纪要：\(names)")
    }

    /// 本地模型不可用仍然降级（既有行为不被新语义收窄波及）。
    func test_modelUnavailableStillDegrades() async throws {
        let sessionID = "cloud-degrade"
        try writeRealTranscript(sessionID: sessionID)

        let outcome = try await MinutesService(store: store)
            .generate(sessionID: sessionID, generator: UnavailableMinutesGenerator())

        XCTAssertFalse(outcome.result.generatedByModel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.markdownURL.path))
    }

    /// 生成器名要同时落进 minutes.md（人读）与 minutes.json（机读）。
    /// 三个月后回看一份纪要，必须能分清它是本地产出还是云端产出。
    func test_generatorNameIsPersisted() async throws {
        let sessionID = "cloud-name"
        try writeRealTranscript(sessionID: sessionID)

        let outcome = try await MinutesService(store: store)
            .generate(sessionID: sessionID, generator: WorkingGenerator())

        XCTAssertEqual(outcome.result.generatorName, "测试云端（fake-model @ fake.host）")
        let md = try String(contentsOf: outcome.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("测试云端（fake-model @ fake.host）"),
                      "minutes.md 的「模型：」行要写真名：\(md)")

        let data = try Data(contentsOf: outcome.jsonURL)
        let decoded = try JSONDecoder().decode(MinutesResult.self, from: data)
        XCTAssertEqual(decoded.generatorName, "测试云端（fake-model @ fake.host）")
    }

    /// 旧 minutes.json（没有 generatorName 键）必须还能读——
    /// 那是后加的溯源字段，不能因为它让读旧纪要直接崩。
    func test_oldMinutesJSONWithoutGeneratorNameStillDecodes() async throws {
        let sessionID = "cloud-old"
        try writeRealTranscript(sessionID: sessionID)
        let dir = store.directory(forSessionID: sessionID)

        // 手写一份「旧格式」minutes.json：字段与当前一致，唯独没有 generatorName
        let oldJSON = """
        {"blocks":[],"blockSummaries":[],"generatedByModel":true,
        "minutes":{"summary":"旧纪要","keyPoints":[],"decisions":[],"actionItems":[]},
        "polishedTranscript":"正文"}
        """
        try oldJSON.write(to: dir.appendingPathComponent(MinutesService.minutesJSONName),
                          atomically: true, encoding: .utf8)

        let decoded = try XCTUnwrap(library_minutes(sessionID: sessionID))
        XCTAssertEqual(decoded.generatorName, "", "缺键时默认空串")
        XCTAssertEqual(decoded.minutes.summary, "旧纪要")
    }

    /// 走 `SessionLibrary.minutes(forSessionID:)`（GUI 详情页的读法）。
    private func library_minutes(sessionID: String) -> MinutesResult? {
        let library = SessionLibrary(root: root)
        return library.minutes(forSessionID: sessionID)
    }
}
