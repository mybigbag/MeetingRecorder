import XCTest
@testable import MRSession
import MRCore
import MRMinutes

/// 落盘 `minutes.md` 的**版式**测试。
///
/// 这组盯的不是「内容对不对」（那是 `MRMinutes` 的事），而是
/// **结论和原料谁排在前面**。旧版把「标点修复正文」放在最前面：
/// 打开纪要文件先滚过整场会议的原文，才在几千字之后看到结论。
/// 而这份文件存在的唯一理由就是「看结论」。
final class MinutesMarkdownLayoutTests: XCTestCase {

    private var root: URL!
    private var service: MinutesService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-md-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = MinutesService(store: SessionStore(root: root))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func result(
        topics: [MeetingTopic] = [],
        keyPoints: [String] = [],
        decisions: [String] = [],
        openIssues: [String] = [],
        corrections: [TranscriptCorrection] = [],
        polished: String = "SENTINEL-整篇标点修复正文",
        generatedByModel: Bool = true
    ) -> MinutesResult {
        MinutesResult(
            blocks: [],
            blockSummaries: [],
            minutes: MeetingMinutes(
                summary: "评审了 Q4 排期，定了 10-20 上线。",
                topics: topics,
                keyPoints: keyPoints,
                decisions: decisions,
                openIssues: openIssues),
            polishedTranscript: polished,
            generatedByModel: generatedByModel,
            generatorName: "云端 API（deepseek-chat @ api.deepseek.com）",
            corrections: corrections)
    }

    /// **纪要必须排在原文之前**。这条是这次改版最直接的判据：
    /// 用户抱怨「全是会议内容罗列」，一半原因是文件打开就是几千字原文。
    func testMinutesComeBeforeTheRawTranscript() throws {
        let md = service.markdown(for: result(), sessionID: "s1", title: "排期评审")

        guard let summary = md.range(of: "## 摘要"),
              let raw = md.range(of: "## 原文（标点修复）") else {
            return XCTFail("摘要或原文栏目缺失：\n\(md)")
        }
        XCTAssertTrue(summary.lowerBound < raw.lowerBound,
                      "摘要必须在原文之前：\n\(md)")

        // 原文那一节确实在最后
        let afterRaw = String(md[raw.lowerBound...])
        XCTAssertTrue(afterRaw.contains("SENTINEL"), "原文内容应跟着它自己的标题：\n\(afterRaw)")
    }

    /// 议题要有三级标题、序号与「结论：」标签，与卡片和复制件同一措辞。
    func testTopicsRenderAsHeadingsWithConclusionLabel() {
        let md = service.markdown(
            for: result(topics: [MeetingTopic(
                title: "Q4 排期",
                conclusion: "10-20 上线，灰度 3 天",
                details: ["支付投诉 12 起"])]),
            sessionID: "s1", title: "排期评审")

        XCTAssertTrue(md.contains("## 议题"), md)
        XCTAssertTrue(md.contains("### 1. Q4 排期"), md)
        XCTAssertTrue(md.contains("结论：10-20 上线，灰度 3 天"), md)
        XCTAssertTrue(md.contains("- 支付投诉 12 起"), md)
    }

    /// 未决事项那一节必须**自己说明它不是已定事项**。
    /// 只给标题「未决事项」，读者容易把里面的内容当成待办清单。
    func testOpenIssuesSectionWarnsTheyAreNotDecisions() {
        let md = service.markdown(
            for: result(openIssues: ["是否通知客服未定"]),
            sessionID: "s1", title: "排期评审")

        guard let openSection = md.range(of: "## 未决事项") else {
            return XCTFail("缺少未决事项栏目：\n\(md)")
        }
        let tail = String(md[openSection.lowerBound...])
        XCTAssertTrue(tail.contains("没有结论"), tail)
        XCTAssertTrue(tail.contains("不要照着执行"), tail)
        XCTAssertTrue(tail.contains("是否通知客服未定"), tail)
    }

    /// 勘误表要带处数、原词、纠正后、依据。
    ///
    /// 四个要素缺一个，用户就没法核对：只有「原词」不知道改成了什么，
    /// 只有「纠正后」不知道原文错在哪，没有依据就不知道凭什么改。
    func testCorrectionLedgerListsCountOriginalCorrectedAndReason() {
        let md = service.markdown(
            for: result(corrections: [
                TranscriptCorrection(original: "支付光关", corrected: "支付网关",
                                     reason: "后文出现正确写法"),
                TranscriptCorrection(original: "回度", corrected: "灰度"),
            ]),
            sessionID: "s1", title: "排期评审")

        XCTAssertTrue(md.contains("## 转写勘误（2 处）"), md)
        XCTAssertTrue(md.contains("支付光关"), md)
        XCTAssertTrue(md.contains("支付网关"), md)
        XCTAssertTrue(md.contains("后文出现正确写法"), md)
        // 没有依据的那一条也要列出（只是不写括号），不能因为原因空就整条丢掉
        XCTAssertTrue(md.contains("回度"), md)
    }

    /// 降级稿：警示在前、不给议题/勘误空栏目。
    ///
    /// 空栏目会被读成「这场会没谈议题」，而真实情况是模型没跑起来。
    func testDegradedMinutesDoNotRenderEmptySections() {
        let md = service.markdown(
            for: result(polished: "原始转写稿", generatedByModel: false),
            sessionID: "s1", title: "排期评审")

        XCTAssertTrue(md.contains("本地纪要模型不可用"), md)
        XCTAssertTrue(md.contains("未生成任何摘要或待办"), md)
        XCTAssertFalse(md.contains("## 议题"), "降级稿不该出现空的议题栏：\n\(md)")
        XCTAssertFalse(md.contains("## 转写勘误"), "降级稿不该出现勘误栏：\n\(md)")
    }

    /// 旧纪要（只有 keyPoints）落盘时仍然显示要点栏，且不凭空造出议题栏。
    func testLegacyKeyPointsStillRenderedWithoutTopics() {
        let md = service.markdown(
            for: result(keyPoints: ["要点一", "要点二"]),
            sessionID: "s1", title: "旧会议")
        XCTAssertTrue(md.contains("## 要点"), md)
        XCTAssertTrue(md.contains("- 要点一"), md)
        XCTAssertFalse(md.contains("## 议题"), md)
    }
}
