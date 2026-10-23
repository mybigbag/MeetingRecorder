import XCTest
@testable import MRMinutes
import MRCore

// MARK: - 提示词规范

/// 这组测试盯的是「提示词里那些不该消失的约束」。
///
/// 它们不能证明模型一定会总结——那是模型能力，单测管不了。它们证明的是
/// **我们确实把要求写进去了**：第一版只写了「列出讨论要点」，
/// 于是产出的就是一堆罗列。约束是行为的唯一开关，删掉一句就是换了一套需求，
/// 必须让测试先红。
final class MinutesPromptSpecTests: XCTestCase {

    // MARK: 纠错规范

    /// 四类可改的错误必须写死。少写一类，模型就会漏掉那一类
    /// （实测最先漏的是「断句造成的词义扭曲」——它听起来最不像错字）。
    func testCorrectionRulesNameTheFourFixableKinds() {
        let rules = MinutesPrompts.coreRules
        for kind in ["同音", "专有名词", "数字", "断句"] {
            XCTAssertTrue(rules.contains(kind), "纠错规范没写「\(kind)」这一类：\n\(rules)")
        }
    }

    /// **「拿不准保留原词」是这段规范的安全阀**，不能删。
    /// 少了它，模型会把听不清的口音补成一句通顺的话——那已经不是纠正，是编造。
    func testCorrectionRulesForbidGuessingWhenUnsure() {
        let rules = MinutesPrompts.coreRules
        XCTAssertTrue(rules.contains("拿不准就保留原词"), rules)
        XCTAssertTrue(rules.contains("不得把听不清的片段补写成通顺的话"), rules)
    }

    /// 纠错必须记录原词与改后的词，否则用户无法核对模型改了什么。
    func testBlockInstructionRequiresCorrectionRecords() {
        XCTAssertTrue(MinutesPrompts.blockInstruction.contains("corrections"), 
                      MinutesPrompts.blockInstruction)
        XCTAssertTrue(MinutesPrompts.blockInstruction.contains("原词"),
                      MinutesPrompts.blockInstruction)
    }

    /// **录音轨道的「我 / 对方」不是人名。**
    ///
    /// 这不是假设：2026-10-21 用真实云端模型跑样例会议时，输出里出现了
    /// 「负责人：对方、小林」——模型把 `system` 轨的显示名当成了参会者姓名。
    /// 转写稿的说话人字段只标轨道，不标身份；不写死这条约束，
    /// 纪要就会把人名区写成「对方」「我」。
    func testSpeakerLabelsAreNotTreatedAsNames() {
        XCTAssertTrue(MinutesPrompts.coreRules.contains("不是人名"),
                      MinutesPrompts.coreRules)
        XCTAssertTrue(MinutesPrompts.blockPrompt(text: "x").contains("不是人名"),
                      "本地版也要有这条（同一个模型，同一个坑）：\n"
                        + MinutesPrompts.blockPrompt(text: "x"))
    }

    // MARK: 纪要规范

    /// **禁止罗列**是这次修复的核心要求。三种表达都不能少：
    /// 结构上以议题为单位、语言上禁叙述句、内容上要合并同类项。
    func testMinutesSpecForbidsNarrationAndRequiresTopics() {
        let spec = MinutesPrompts.detailedSpec
        XCTAssertTrue(spec.contains("禁止按时间顺序复述"), spec)
        XCTAssertTrue(spec.contains("以议题为单位"), spec)
        XCTAssertTrue(spec.contains("不要一人一条地摘录"), spec)
    }

    /// 「已决议 / 未决 / 讨论中的观点」必须分开。
    /// 把「还没定」写进决议，读者会照着执行——这是纪要最危险的一种失真。
    func testMinutesSpecSeparatesDecisionsFromOpenIssues() {
        let spec = MinutesPrompts.detailedSpec
        XCTAssertTrue(spec.contains("已决议"), spec)
        XCTAssertTrue(spec.contains("未决"), spec)
        XCTAssertTrue(spec.contains("提议"), spec)

        let merge = MinutesPrompts.mergeInstruction
        XCTAssertTrue(merge.contains("openIssues"), merge)
        XCTAssertTrue(merge.contains("没有结论"), merge)
    }

    /// 摘要不能退回到「一句话」。
    /// 一句话装不下「谈成了什么」，模型只能写「本次会议讨论了排期问题」这种空话——
    /// 那正是用户抱怨「没有总结」的一半原因。
    func testMergeInstructionRequiresSubstantiveSummary() {
        let merge = MinutesPrompts.mergeInstruction
        XCTAssertTrue(merge.contains("2-5 句"), merge)
        XCTAssertTrue(merge.contains("这是什么会"), merge)
        XCTAssertTrue(merge.contains("下一步"), merge)
        XCTAssertTrue(merge.contains("不要"), merge)
        XCTAssertTrue(merge.contains("围绕"), "缺少「不要用空话开头」的约束：\n\(merge)")
    }

    // MARK: 本地与云端的篇幅差

    /// 本地 4096 上下文的 prompt **必须比云端短**。
    ///
    /// 完整规范约 700 字，塞进本地版会把 3000 token 的正文块挤掉——
    /// 模型只能看到半段话还硬要输出摘要。这条用长度比例兜住，
    /// 防止以后「为了统一」把 detailedSpec 并进本地 prompt。
    func testLocalBlockPromptIsCompactEnoughForSmallContext() {
        let local = MinutesPrompts.blockPrompt(text: "占位")
        let cloud = MinutesPrompts.blockUserPrompt(text: "占位")
        XCTAssertLessThan(local.count, cloud.count,
                          "本地 prompt 不该比云端长（本地上下文只有 4096）")
        XCTAssertLessThan(local.count, 900,
                          "本地 prompt 过长会挤占正文：\(local.count) 字")
        // 短归短，纠错与不编造的硬约束不能丢
        XCTAssertTrue(local.contains("语音识别"), local)
        XCTAssertTrue(local.contains("保留原词"), local)
    }

    /// 云端 JSON 契约必须逐字给出字段名。
    /// 不写死字段名，模型会自由发挥出 `actions` / `todos` 这类近义词，
    /// 解析层全凭运气。
    func testCloudContractsPinEveryFieldName() {
        let block = MinutesPrompts.blockUserPrompt(text: "x")
        for field in ["polishedText", "summary", "keyPoints", "decisions",
                      "actionItems", "corrections", "original", "corrected", "reason"] {
            XCTAssertTrue(block.contains("\"\(field)\""), "block 契约缺字段 \(field)：\n\(block)")
        }

        let merge = MinutesPrompts.mergeUserPrompt(joinedSummaries: "x")
        for field in ["summary", "topics", "title", "conclusion", "details",
                      "decisions", "actionItems", "openIssues"] {
            XCTAssertTrue(merge.contains("\"\(field)\""), "merge 契约缺字段 \(field)：\n\(merge)")
        }
    }
}

// MARK: - 数据模型兼容

/// 旧 `minutes.json` **必须还能打开**。
///
/// `topics` / `openIssues` / `corrections` 都是这次新加的键。合成 Decodable
/// 遇到缺键会抛 `keyNotFound`，用户点开一份昨天的纪要就是一片报错——
/// 这类「升级即丢历史」的坑，项目里已经因为 `generatorName` 踩过一次。
final class MinutesModelCompatibilityTests: XCTestCase {

    /// 只有旧字段的最小 JSON（照 2026-10 之前的真实结构写）。
    private let legacyJSON = """
    {
      "blocks": [],
      "blockSummaries": [
        {"index": 1, "polishedText": "第一段。", "summary": "谈排期",
         "keyPoints": ["要点一"], "decisions": [], "actionItems": []}
      ],
      "minutes": {
        "summary": "本次会议讨论了排期问题。",
        "keyPoints": ["要点一", "要点二"],
        "decisions": ["10-20 上线"],
        "actionItems": [{"task": "写方案", "owner": "", "due": ""}]
      },
      "polishedTranscript": "我：第一段。",
      "generatedByModel": true
    }
    """

    func testLegacyFileWithoutNewKeysDecodes() throws {
        let result = try JSONDecoder().decode(
            MinutesResult.self, from: Data(legacyJSON.utf8))

        // 旧内容一个不丢
        XCTAssertEqual(result.minutes.summary, "本次会议讨论了排期问题。")
        XCTAssertEqual(result.minutes.keyPoints, ["要点一", "要点二"])
        XCTAssertEqual(result.minutes.decisions, ["10-20 上线"])
        XCTAssertEqual(result.minutes.actionItems.count, 1)
        XCTAssertEqual(result.generatedByModel, true)
        XCTAssertEqual(result.generatorName, "", "旧文件没有 generatorName，应为空串")

        // 新字段给默认值，不是崩
        XCTAssertTrue(result.minutes.topics.isEmpty)
        XCTAssertTrue(result.minutes.openIssues.isEmpty)
        XCTAssertTrue(result.corrections.isEmpty)
        XCTAssertTrue(result.blockSummaries[0].corrections.isEmpty)
    }

    /// 新结构必须能完整往返（写入后再读出，一个字段都不能掉）。
    /// 这条挡的是「加了字段但忘了手写 encode」——
    /// 那种情况下文件写进去看着正常，读出来却是空的。
    func testNewStructureRoundTrips() throws {
        let original = MinutesResult(
            blocks: [],
            blockSummaries: [],
            minutes: MeetingMinutes(
                summary: "定了 10-20 上线。",
                topics: [MeetingTopic(
                    title: "Q4 排期",
                    conclusion: "10-20 上线，灰度 3 天",
                    details: ["支付投诉 12 起，优先修"])],
                decisions: ["10-20 上线"],
                actionItems: [ActionItem(task: "写回滚脚本", owner: "老王", due: "10-18")],
                openIssues: ["是否通知客服未定"]),
            polishedTranscript: "原文",
            generatedByModel: true,
            generatorName: "云端 API（deepseek-chat @ api.deepseek.com）",
            corrections: [TranscriptCorrection(
                original: "支付光关", corrected: "支付网关", reason: "后文出现正确写法")])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MinutesResult.self, from: data)

        XCTAssertEqual(decoded, original, "新结构往返后必须完全一致")
    }

    /// `hasContent` 是「这份纪要有东西吗」的唯一判据，三处渲染都用它。
    /// 漏掉任何一个新字段，那一栏的纪要就会被判成空稿。
    func testHasContentCountsEverySection() {
        XCTAssertFalse(MeetingMinutes(summary: "").hasContent)
        XCTAssertTrue(MeetingMinutes(
            summary: "", topics: [MeetingTopic(title: "t", conclusion: "c")]).hasContent)
        XCTAssertTrue(MeetingMinutes(summary: "", keyPoints: ["k"]).hasContent)
        XCTAssertTrue(MeetingMinutes(summary: "", openIssues: ["还没定"]).hasContent)
    }
}

// MARK: - 去噪与汇总

final class MinutesNormalizerTests: XCTestCase {

    /// 空壳议题必须丢掉。模型被要求「至少一个议题」时，会用
    /// 「会议整体情况 / 与会人员进行了讨论」这种没有结论的条目凑数。
    func testEmptyTopicsAreDropped() {
        let raw = [
            LenientTopic(title: "Q4 排期", conclusion: "10-20 上线", details: ["灰度 3 天"]),
            LenientTopic(title: "", conclusion: "", details: []),
            LenientTopic(title: "  ", conclusion: "  ", details: ["只说不做"]),
        ]
        let topics = MinutesNormalizer.topics(raw)
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics[0].title, "Q4 排期")
        XCTAssertEqual(topics[0].details, ["灰度 3 天"])
    }

    /// 只有结论、没有标题的议题**不能丢**：结论是真的，
    /// 标题空了就截取结论开头兜底——宁可标题粗糙，也不要丢一条真结论。
    func testTopicWithConclusionButNoTitleIsKept() {
        let topics = MinutesNormalizer.topics([
            LenientTopic(title: "", conclusion: "10-20 上线，灰度三天后再全量", details: [])
        ])
        XCTAssertEqual(topics.count, 1)
        XCTAssertFalse(topics[0].title.isEmpty)
    }

    /// 「改前改后一样」的纠错记录是噪声，必须丢掉。
    /// 模型凑数时常把没改的词也列进来；留着它，界面就会出现
    /// 「支付网关 → 支付网关」这种让人怀疑勘误表可信度的条目。
    func testCorrectionsWithoutActualChangeAreDropped() {
        let raw = [
            LenientCorrection(original: "支付光关", corrected: "支付网关", reason: "后文出现"),
            LenientCorrection(original: "排期", corrected: "排期", reason: ""),
            LenientCorrection(original: "Q4", corrected: "q4", reason: "大小写"),
            LenientCorrection(original: "", corrected: "空原词", reason: ""),
        ]
        let out = MinutesNormalizer.corrections(raw)
        XCTAssertEqual(out.count, 1, "只应保留真有改动的那一条：\(out)")
        XCTAssertEqual(out[0].original, "支付光关")
    }

    /// 跨块去重：同一个错词在两块里被纠正成同一个词，只算一处
    /// （块边界处的重叠发言会导致重复纠正）。
    func testMergeDeduplicatesSameCorrection() {
        let merged = MinutesNormalizer.mergeCorrections([
            TranscriptCorrection(original: "支付光关", corrected: "支付网关"),
            TranscriptCorrection(original: "支付光关", corrected: "支付网关", reason: "后文出现正确写法"),
            TranscriptCorrection(original: "回度", corrected: "灰度"),
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].original, "支付光关")
        // 首次出现的条目没写依据，后出现的补上——依据比顺序重要
        XCTAssertEqual(merged[0].reason, "后文出现正确写法")
    }

    /// 同一个原词被纠正成两个不同的词时，**两条都保留**。
    /// 这是模型自己前后不一致的信号；静默选一个等于把问题藏起来。
    func testMergeKeepsConflictingCorrections() {
        let merged = MinutesNormalizer.mergeCorrections([
            TranscriptCorrection(original: "回度", corrected: "灰度"),
            TranscriptCorrection(original: "回度", corrected: "回复"),
        ])
        XCTAssertEqual(merged.count, 2, "前后不一致必须暴露出来，不能静默选一个")
    }
}

// MARK: - 编排层汇总勘误

final class OrchestratorCorrectionTests: XCTestCase {

    /// 带纠错的假生成器：每块都把「支付光关」纠正成「支付网关」。
    private struct CorrectingGenerator: MinutesGenerator {
        var isAvailable: Bool { true }
        var displayName: String { "假生成器" }
        var unavailableReason: String? { nil }

        func summarize(block: TranscriptBlock) async throws -> BlockSummary {
            BlockSummary(
                index: block.index,
                polishedText: "支付网关今天上线。",
                summary: "讨论支付网关",
                keyPoints: ["支付网关今天上线"],
                corrections: [TranscriptCorrection(
                    original: "支付光关", corrected: "支付网关", reason: "后文出现正确写法")])
        }

        func merge(summaries: [BlockSummary]) async throws -> MeetingMinutes {
            MeetingMinutes(summary: "支付网关今天上线。")
        }
    }

    /// 每块各纠正一次，最终勘误表只能有一条——
    /// 用户看到的应该是「错在哪」，不是「错了几次」。
    func testCorrectionsAcrossBlocksAreMergedOnce() async throws {
        var segs: [TranscriptSegment] = []
        for i in 0..<4 {
            segs.append(TranscriptSegment(
                start: Double(i) * 10, end: Double(i) * 10 + 9,
                text: String(repeating: "中", count: 100), track: "mic", speaker: "我"))
        }
        let doc = TranscriptDocument(
            sessionID: "t", title: "t", language: "zh-CN", engine: "x", segments: segs)
        let orchestrator = MinutesOrchestrator(
            generator: CorrectingGenerator(),
            chunker: TranscriptChunker(maxTokensPerBlock: 300))

        let result = try await orchestrator.generate(for: doc)

        XCTAssertGreaterThan(result.blocks.count, 1, "本用例需要多块才有意义")
        XCTAssertEqual(result.corrections.count, 1, "跨块重复纠正应合并：\(result.corrections)")
        XCTAssertEqual(result.corrections[0].original, "支付光关")
        XCTAssertEqual(result.corrections[0].corrected, "支付网关")
    }
}

// MARK: - 云端解析新字段

final class CloudAPITopicParsingTests: XCTestCase {

    /// 本文件专用的响应壳。另一个测试文件里的同名 helper 是 `private`，
    /// 跨文件不可见；共用就要放宽它的可见性，而这里是三行代码的事。
    private func chatResponse(content: String) -> String {
        let array = try? JSONSerialization.data(
            withJSONObject: [content], options: [.fragmentsAllowed])
        let quoted = String(decoding: array ?? Data(), as: UTF8.self)
            .dropFirst().dropLast()
        return """
        {"choices":[{"index":0,"message":{"role":"assistant","content":\(quoted)},"finish_reason":"stop"}]}
        """
    }

    private func httpResponse(status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
    }

    private func makeGenerator(transport: any MinutesAPITransport) -> CloudAPIMinutesGenerator {
        CloudAPIMinutesGenerator(
            configuration: CloudAPIConfiguration(
                baseURL: "https://api.deepseek.com/v1", apiKey: "k", model: "m"),
            transport: transport)
    }

    /// 云端返回议题结构时，解析与去噪要一起生效：
    /// 有内容的议题进来、空壳议题进不来、纠错缺字段也不该让整次调用失败。
    func testMergeParsesTopicsOpenIssuesAndToleratesMissingFields() async throws {
        let transport = FakeMinutesTransport { request in
            let content = """
            {"summary":"评审了 Q4 排期，定了 10-20 上线。",
             "topics":[
               {"title":"Q4 排期","conclusion":"10-20 上线","details":["灰度 3 天","支付投诉 12 起"]},
               {"title":"","conclusion":"","details":[]}
             ],
             "decisions":["10-20 上线"],
             "actionItems":[{"task":"写回滚脚本","owner":"老王","due":"10-18"}],
             "openIssues":["是否通知客服未定"]}
            """
            return (Data(self.chatResponse(content: content).utf8),
                    self.httpResponse(status: 200, url: request.url!))
        }
        let generator = makeGenerator(transport: transport)

        let minutes = try await generator.merge(summaries: [
            BlockSummary(index: 1, polishedText: "p", summary: "局部")
        ])

        XCTAssertEqual(minutes.topics.count, 1, "空壳议题应被丢掉：\(minutes.topics)")
        XCTAssertEqual(minutes.topics[0].title, "Q4 排期")
        XCTAssertEqual(minutes.topics[0].conclusion, "10-20 上线")
        XCTAssertEqual(minutes.topics[0].details.count, 2)
        XCTAssertEqual(minutes.openIssues, ["是否通知客服未定"])
        XCTAssertEqual(minutes.decisions, ["10-20 上线"])
    }

    /// map 阶段缺少 `corrections` 键时不能报错——
    /// 模型完全可能一句纠正都没有（转写很干净），那一次调用是成功的。
    func testSummarizeWithoutCorrectionsKeyIsNotAnError() async throws {
        let transport = FakeMinutesTransport { request in
            let content = """
            {"polishedText":"我们先讨论排期。","summary":"讨论排期",
             "keyPoints":["排期"],"decisions":[],"actionItems":[]}
            """
            return (Data(self.chatResponse(content: content).utf8),
                    self.httpResponse(status: 200, url: request.url!))
        }
        let generator = makeGenerator(transport: transport)

        let summary = try await generator.summarize(
            block: TranscriptBlock(index: 1, start: 0, end: 10, text: "我：先讨论排期"))
        XCTAssertTrue(summary.corrections.isEmpty)
        XCTAssertEqual(summary.summary, "讨论排期")
    }

    /// 云端返回的纠错记录要经过同一套去噪：没改动的条目不能进纪要。
    func testSummarizeDropsNoOpCorrections() async throws {
        let transport = FakeMinutesTransport { request in
            let content = """
            {"polishedText":"支付网关今天上线。","summary":"支付网关上线",
             "keyPoints":[],"decisions":[],"actionItems":[],
             "corrections":[
               {"original":"支付光关","corrected":"支付网关","reason":"后文出现正确写法"},
               {"original":"上线","corrected":"上线","reason":""}
             ]}
            """
            return (Data(self.chatResponse(content: content).utf8),
                    self.httpResponse(status: 200, url: request.url!))
        }
        let generator = makeGenerator(transport: transport)

        let summary = try await generator.summarize(
            block: TranscriptBlock(index: 1, start: 0, end: 10, text: "支付光关今天上线"))
        XCTAssertEqual(summary.corrections.count, 1, "\(summary.corrections)")
        XCTAssertEqual(summary.corrections[0].corrected, "支付网关")
    }
}
