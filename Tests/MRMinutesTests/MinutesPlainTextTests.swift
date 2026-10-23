import XCTest
@testable import MRMinutes

/// 「复制纪要」复制出去的那份文本（`MinutesPlainText.render`）。
///
/// ## 这条测试盯的是「粘给别人的东西对不对」
///
/// 「复制」与「在访达中显示」替换掉彼此之后，纪要就有了**唯一的分享出口**：
/// 用户要把它发给别人时，粘进群里的就是这段字符串。
/// 落盘的 `minutes.md` 里那些东西——会话 ID、生成时间、分段数、
/// 整篇标点修复正文——对读纪要的人是纯噪声：三千字原文压在结论前面，
/// 而接收方要的是「这场会定了什么、谁欠什么」。
///
/// 所以「复制出来的必须不含原料」不是洁癖，是这个功能的全部意义。
final class MinutesPlainTextTests: XCTestCase {

    private func result(
        summary: String,
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        generatedByModel: Bool = true,
        generatorName: String = "本地 FoundationModels",
        polishedTranscript: String = ""
    ) -> MinutesResult {
        MinutesResult(
            blocks: [],
            blockSummaries: [],
            minutes: MeetingMinutes(
                summary: summary,
                keyPoints: keyPoints,
                decisions: decisions,
                actionItems: actionItems),
            polishedTranscript: polishedTranscript,
            generatedByModel: generatedByModel,
            generatorName: generatorName)
    }

    // MARK: - 不含原料

    /// **复制件里不能有标点修复正文。**
    ///
    /// 这是本组最要紧的一条：正文可能有几千字，一旦混进去，
    /// 「复制纪要」就变成了「复制整场会议」，而用户在群聊里只想发结论。
    /// 用一段极易辨识的哨兵文本——退化时它一定会出现在输出里。
    func testDoesNotLeakThePolishedTranscript() {
        let text = MinutesPlainText.render(
            result(summary: "确定了三个版本的下线时间。",
                   polishedTranscript: "SENTINEL-整篇标点修复正文-不该出现在复制件里"),
            title: "版本下线评审")
        XCTAssertFalse(text.contains("SENTINEL"),
                       "复制件里混进了整篇正文：\n\(text)")
    }

    /// 落盘 `minutes.md` 的文件头也不该跟过来：会话 ID 与生成时间对读者没用，
    /// 而「2026-10-19-143012-版本下线评审」这种串会让接收方以为这是原始记录。
    func testDoesNotLeakTheFileHeader() {
        let text = MinutesPlainText.render(
            result(summary: "结论明确。"), title: "版本下线评审")
        XCTAssertFalse(text.contains("分段："), text)
        XCTAssertFalse(text.contains("会话："), text)
        XCTAssertFalse(text.contains("- 生成："), text)
    }

    /// 正文本身也不该出现在复制件里——它是转写稿，
    /// 而转写稿已经有自己的导出入口（底部「导出」）。
    func testDoesNotIncludeTheMarkdownHeadingSyntax() {
        let text = MinutesPlainText.render(
            result(summary: "结论。", keyPoints: ["要点一"]), title: "会议")
        XCTAssertFalse(text.contains("##"), "不该带 Markdown 标题记号：\n\(text)")
        XCTAssertFalse(text.contains("**"), "不该带 Markdown 粗体记号：\n\(text)")
    }

    // MARK: - 结构化内容齐全

    /// 四项内容（摘要/要点/决议/待办）一个都不能少。
    ///
    /// 退化示例：把 `appendList` 的 guard 从 `items.isEmpty` 改成别的，
    /// 或者干脆漏掉决议那一段，下面这条会红。
    func testIncludesEveryStructuredSection() {
        let text = MinutesPlainText.render(
            result(summary: "确定 10 月 20 日下线。",
                   keyPoints: ["灰度到 50%", "回滚预案已写"],
                   decisions: ["下线日期定为 10-20"],
                   actionItems: [ActionItem(task: "更新帮助文档",
                                             owner: "小林", due: "10-18")]),
            title: "版本下线评审")

        XCTAssertTrue(text.contains("确定 10 月 20 日下线。"), text)
        XCTAssertTrue(text.contains("灰度到 50%"), text)
        XCTAssertTrue(text.contains("回滚预案已写"), text)
        XCTAssertTrue(text.contains("下线日期定为 10-20"), text)
        XCTAssertTrue(text.contains("更新帮助文档"), text)
    }

    /// 待办必须带负责人与截止，缺的那一项显式写「未指定」。
    ///
    /// **不能留空**：粘进群里的「小林 去更新文档」分不清是有意留白
    /// 还是模型漏了，而「未指定」把这件事说清楚了。
    func testActionItemsCarryOwnerAndDueAndSayMissingOnes() {
        let text = MinutesPlainText.render(
            result(summary: "有两条待办。",
                   actionItems: [
                       ActionItem(task: "写回滚脚本", owner: "老王", due: "10-19"),
                       ActionItem(task: "通知客服", owner: "", due: ""),
                   ]),
            title: "会议")
        XCTAssertTrue(text.contains("写回滚脚本（负责人：老王；截止：10-19）"), text)
        XCTAssertTrue(text.contains("通知客服（负责人：未指定；截止：未指定）"), text)
    }

    /// 三处渲染（界面卡片、复制件、落盘 Markdown）必须给同一条待办同一句话。
    ///
    /// 判据是**行为相同**：让 `actionItemLine` 改一个词，三处一起变；
    /// 如果哪天又有人各写一遍，本用例会先红。
    func testActionItemLineIsSharedByEveryRenderer() {
        let item = ActionItem(task: "拉通数据", owner: "", due: "下周五")
        let line = MinutesPlainText.actionItemLine(item)
        XCTAssertEqual(line, "拉通数据（负责人：未指定；截止：下周五）")
        XCTAssertTrue(MinutesPlainText.render(
            result(summary: "x", actionItems: [item]), title: "会议").contains(line))
    }

    // MARK: - 溯源与诚实

    /// 云端产出的纪要必须带上服务名。**这份文本是要离开本机被别人读到的**，
    /// 对方有权知道它不是本地算出来的。
    func testCloudMinutesCarryTheGeneratorName() {
        let text = MinutesPlainText.render(
            result(summary: "结论。", generatorName: "云端 API（deepseek-chat @ api.deepseek.com）"),
            title: "会议")
        XCTAssertTrue(text.contains("云端 API（deepseek-chat @ api.deepseek.com）"), text)
    }

    /// 降级稿**必须**自报家门。
    ///
    /// 一份「未生成摘要」的稿子被当成真纪要粘给同事，比不给更糟：
    /// 对方会以为「这次会议没有结论」，而真实情况是模型没跑起来。
    ///
    /// 这条还钉着一个更细的自相矛盾：降级稿上面刚说「本地模型不可用」，
    /// 下面再写一句「来源：本地模型」，读者得到的信息就变成了
    /// 「本地模型跑过了，只是没出摘要」——**与事实相反**。
    func testDegradedMinutesSaySo() {
        let text = MinutesPlainText.render(
            result(summary: "原始转写稿正文", generatedByModel: false, generatorName: ""),
            title: "会议")
        XCTAssertTrue(text.contains("未生成摘要"), text)
        XCTAssertTrue(text.contains("降级"), "降级来源要写明：\(text)")
        XCTAssertFalse(text.contains("本地 FoundationModels"),
                       "降级稿不能报一个没真跑过的模型名：\(text)")
        // 判据：出现「本地模型」的地方必须同时带着「不可用」，
        // 不能有一句孤零零的「来源：本地模型」。
        for line in text.split(separator: "\n") where line.contains("本地模型") {
            XCTAssertTrue(line.contains("不可用"),
                          "降级稿里不该出现无条件的「本地模型」：\(line)")
        }
    }

    /// 四项全空时给一句明确的话，不要给一个只有标题的空壳。
    ///
    /// 退化示例：删掉那个 `if m.summary.isEmpty && ...` 分支，
    /// 本用例红——用户看到只有「会议纪要：xxx」会以为复制坏了。
    func testAllEmptyDoesNotProduceABareHeading() {
        let text = MinutesPlainText.render(result(summary: ""), title: "空会议")
        XCTAssertTrue(text.contains("会议纪要：空会议"), text)
        XCTAssertTrue(text.count > 30, "空纪要也得说清发生了什么：\(text)")
    }

    /// 标题是空的也要给得出第一行。**粘进群里的第一行是唯一的身份标识**，
    /// 空标题时用「会议纪要」兜底，而不是留下一个孤零零的冒号。
    func testFallsBackWhenTheTitleIsBlank() {
        let text = MinutesPlainText.render(result(summary: "结论。"), title: "   ")
        XCTAssertTrue(text.hasPrefix("会议纪要"), text)
        XCTAssertFalse(text.contains("会议纪要："), "空标题不该留一个空冒号：\(text)")
    }
}

// MARK: - 议题与未决事项

/// 这组盯的是「复制出去的东西有没有真正总结」。
///
/// 旧版只有【要点】一栏，`[String]` 平铺出来必然是罗列；
/// 议题结构把「谈了什么 → 定了什么」的关系带进了复制件。
final class MinutesPlainTextTopicTests: XCTestCase {

    private func result(topics: [MeetingTopic] = [],
                        keyPoints: [String] = [],
                        decisions: [String] = [],
                        openIssues: [String] = [],
                        corrections: [TranscriptCorrection] = []) -> MinutesResult {
        MinutesResult(
            blocks: [],
            blockSummaries: [],
            minutes: MeetingMinutes(
                summary: "评审了 Q4 排期。",
                topics: topics,
                keyPoints: keyPoints,
                decisions: decisions,
                openIssues: openIssues),
            polishedTranscript: "",
            generatedByModel: true,
            generatorName: "云端 API（deepseek-chat @ api.deepseek.com）",
            corrections: corrections)
    }

    /// 议题要带标题、结论与支撑事实，三者缺一读者就看不出「定了什么」。
    func testTopicsCarryTitleConclusionAndDetails() {
        let text = MinutesPlainText.render(
            result(topics: [MeetingTopic(
                title: "Q4 排期",
                conclusion: "10-20 上线，灰度 3 天",
                details: ["支付投诉 12 起，优先修"])]),
            title: "排期评审")

        XCTAssertTrue(text.contains("【议题】"), text)
        XCTAssertTrue(text.contains("1. Q4 排期"), text)
        XCTAssertTrue(text.contains("结论：10-20 上线，灰度 3 天"), text)
        XCTAssertTrue(text.contains("· 支付投诉 12 起，优先修"), text)
    }

    /// **未决事项必须与决议分开呈现**。
    ///
    /// 判据不是「出现了」而是「出现在哪一栏」：把「还没定」摆进【决议】，
    /// 接收方会照着执行——这是纪要最危险的一类失真。
    func testOpenIssuesSitUnderTheirOwnHeadingNotUnderDecisions() {
        let text = MinutesPlainText.render(
            result(decisions: ["10-20 上线"],
                   openIssues: ["是否通知客服未定"]),
            title: "排期评审")

        guard let decisionRange = text.range(of: "【决议】"),
              let openRange = text.range(of: "【未决事项】"),
              let issueRange = text.range(of: "是否通知客服未定") else {
            return XCTFail("决议/未决栏目或内容缺失：\n\(text)")
        }
        let d = decisionRange.lowerBound
        let o = openRange.lowerBound
        let issue = issueRange.lowerBound

        XCTAssertTrue(issue > o, "未决事项应排在【未决事项】之后：\n\(text)")
        XCTAssertTrue(issue > d)
        // 决议栏里只能有已定的事
        let decisionSection = text[d..<o]
        XCTAssertFalse(decisionSection.contains("是否通知客服未定"),
                       "「还没定」的内容混进了决议栏：\n\(decisionSection)")
    }

    /// 旧纪要（只有 keyPoints、没有议题）仍然要能读。
    ///
    /// 升级不该让「上个月那份纪要」在复制时变成空白——
    /// 这是用户对历史数据的最低期待。
    func testLegacyKeyPointsStillRenderWhenThereAreNoTopics() {
        let text = MinutesPlainText.render(
            result(keyPoints: ["要点一", "要点二"]), title: "旧会议")
        XCTAssertTrue(text.contains("【要点】"), text)
        XCTAssertTrue(text.contains("要点一"), text)
        XCTAssertFalse(text.contains("【议题】"), "没有议题时不该出现空栏目：\n\(text)")
    }

    /// 勘误表**不进复制件**。
    ///
    /// 它是给「核对模型改了什么」用的内部信息，而复制件是发给未参会者的纪要。
    /// 把「支付光关 → 支付网关」粘进群里，对方只会盯着错字看结论。
    /// 落盘 `minutes.md` 与界面卡片会保留它。
    func testCorrectionLedgerIsNotCopiedOut() {
        let text = MinutesPlainText.render(
            result(corrections: [TranscriptCorrection(
                original: "支付光关", corrected: "支付网关", reason: "后文出现正确写法")]),
            title: "排期评审")
        XCTAssertFalse(text.contains("支付光关"), "勘误表混进了复制件：\n\(text)")
        XCTAssertFalse(text.contains("勘误"), text)
    }
}