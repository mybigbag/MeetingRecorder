import XCTest
import AppKit
import MRMinutes
import MRSession
@testable import MRGUI

/// 纪要卡片的富文本渲染。
///
/// ## 这一组用例要钉住的是什么
///
/// 反馈的「复制只能复制一行」，根因是卡片由十几个 `Text` 叠成、
/// 每个 `Text` 各自是独立选区。改成**一段** `NSAttributedString` 之后，
/// 「是不是一段」就成了必须被断言的东西——
/// 一旦有人把某块内容改回单独的视图，选区又会在那里断开，
/// 而界面上看不出任何异常（照样能选、就是选不过去）。
final class MinutesCardTextTests: XCTestCase {

    private func makeResult(
        summary: String = "这场会定了版本下线时间，并把灰度范围收窄到一个部门。",
        generatedByModel: Bool = true,
        generatorName: String = "云端 API（deepseek-chat @ api.deepseek.com）",
        corrections: [TranscriptCorrection] = []
    ) -> MinutesResult {
        MinutesResult(
            blocks: [],
            blockSummaries: [],
            minutes: MeetingMinutes(
                summary: summary,
                topics: [
                    MeetingTopic(title: "版本下线时间",
                                 conclusion: "定在周五 18:00",
                                 details: ["灰度先覆盖用户部门", "回滚方案已就绪"]),
                    MeetingTopic(title: "灰度范围", conclusion: "只放一个部门"),
                ],
                decisions: ["周五 18:00 下线旧版本"],
                actionItems: [ActionItem(task: "补一份回滚脚本", owner: "小林", due: "周四")],
                openIssues: ["是否通知客服团队还没定"]),
            polishedTranscript: "",
            generatedByModel: generatedByModel,
            generatorName: generatorName,
            corrections: corrections)
    }

    // MARK: - 一段文本

    /// **核心判据**：整张卡片必须是**一段**文本，且带足够多的段落。
    ///
    /// 阴性对照：把渲染改成只返回 `summary`（一行）时，这条会红——
    /// 而那一种情况在界面上「看起来仍然正常」，只有跨行选择会失效。
    func testCardIsOneMultiParagraphText() {
        let text = MinutesCardText.render(makeResult(),
                                          transcriptChanged: false,
                                          showsCorrections: false).string
        let paragraphs = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        // 摘要 + 议题标题×2 + 结论×2 + 细节×2 + 决议(标题+1) + 待办(标题+1)
        // + 未决(标题+1) + 模型行 = 14 段起
        XCTAssertGreaterThanOrEqual(paragraphs.count, 12,
                                    "卡片只有 \(paragraphs.count) 段，跨行复制会断在段落边界上：\n\(text)")
    }

    func testSectionsAppearInReadingOrder() throws {
        let text = MinutesCardText.render(makeResult(),
                                          transcriptChanged: false,
                                          showsCorrections: false).string
        let summary = try XCTUnwrap(range(of: "灰度范围收窄", in: text))
        let topics = try XCTUnwrap(range(of: "议题", in: text))
        let decisions = try XCTUnwrap(range(of: "决议", in: text))
        let actions = try XCTUnwrap(range(of: "待办", in: text))
        let issues = try XCTUnwrap(range(of: "未决事项", in: text))
        let model = try XCTUnwrap(range(of: "模型：", in: text))

        XCTAssertLessThan(summary.lowerBound, topics.lowerBound)
        XCTAssertLessThan(topics.lowerBound, decisions.lowerBound)
        XCTAssertLessThan(decisions.lowerBound, actions.lowerBound)
        XCTAssertLessThan(actions.lowerBound, issues.lowerBound)
        XCTAssertLessThan(issues.lowerBound, model.lowerBound)
    }

    /// 卡片与复制件、`minutes.md` 共用同一套措辞——这里量的是「共用」这件事，
    /// 不是把措辞再抄一遍。
    func testWordingComesFromSharedRenderers() {
        let result = makeResult()
        let text = MinutesCardText.render(result,
                                          transcriptChanged: false,
                                          showsCorrections: false).string
        XCTAssertTrue(text.contains(MinutesPlainText.topicConclusionLabel + "定在周五 18:00"))
        XCTAssertTrue(text.contains(MinutesPlainText.actionItemLine(
            ActionItem(task: "补一份回滚脚本", owner: "小林", due: "周四"))))
        XCTAssertTrue(text.contains(MinutesService.modelDescription(result)))
    }

    // MARK: - 降级稿

    /// 降级稿必须自己说明白，而且**不能**在模型行里写「本地模型」——
    /// 那会和上方的「模型不可用」自相矛盾。
    func testDegradedMinutesSaySoAndDoNotClaimALocalModel() {
        let result = makeResult(summary: "", generatedByModel: false, generatorName: "")
        let text = MinutesCardText.render(result,
                                          transcriptChanged: false,
                                          showsCorrections: false).string
        XCTAssertTrue(text.contains("未生成摘要"))
        XCTAssertTrue(text.contains("降级"), "降级稿的模型行必须写「降级」：\n\(text)")
        XCTAssertFalse(text.contains("模型：本地模型"),
                       "上方刚说模型不可用，下面不能写「本地模型」：\n\(text)")
    }

    /// 「纪要基于旧稿」这条提示必须在**同一段文本**里，
    /// 否则它又是那个「只能选一行」的孤岛，而且用户把它当正文的一部分复制走。
    func testStaleWarningIsPartOfTheSelectableText() {
        let text = MinutesCardText.render(makeResult(),
                                          transcriptChanged: true,
                                          showsCorrections: false).string
        XCTAssertTrue(text.contains("基于旧稿"))
        let firstLine = text.components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(firstLine.contains("基于旧稿"),
                      "警告必须在第一段，用户一打开卡片就看到：\(firstLine)")
    }

    // MARK: - 勘误表

    func testCorrectionsStayCollapsedByDefault() {
        let result = makeResult(corrections: [
            TranscriptCorrection(original: "回度", corrected: "灰度", reason: "后文出现正确写法"),
        ])
        let collapsed = MinutesCardText.render(result,
                                               transcriptChanged: false,
                                               showsCorrections: false).string
        XCTAssertFalse(collapsed.contains("回度 → 灰度"),
                       "默认收起时不该出现勘误明细：\n\(collapsed)")
        // 但「有几处」必须还在——否则用户不知道有东西可展开（那个入口在按钮上，
        // 这里断言的是文本里没有明细、而不是「什么都不说」由按钮负责）。
    }

    func testExpandedCorrectionsJoinTheSameText() {
        let result = makeResult(corrections: [
            TranscriptCorrection(original: "回度", corrected: "灰度", reason: "后文出现正确写法"),
        ])
        let expanded = MinutesCardText.render(result,
                                              transcriptChanged: false,
                                              showsCorrections: true).string
        XCTAssertTrue(expanded.contains("已纠正 1 处语音识别错误"))
        XCTAssertTrue(expanded.contains("回度 → 灰度（后文出现正确写法）"))
    }

    /// 展开/收起按钮的文案：已经展开的开关上不能还写着「点开核对」。
    func testCorrectionsToggleLabelSwitchesWithState() {
        XCTAssertTrue(MeetingDetailView.correctionsToggleLabel(count: 3, shows: false)
            .contains("点开核对"))
        XCTAssertFalse(MeetingDetailView.correctionsToggleLabel(count: 3, shows: true)
            .contains("点开核对"))
    }

    // MARK: - 空纪要

    /// 全空（降级稿的常见形态）时也要有话说，不能给一个只剩「模型：」的空壳。
    func testEmptyMinutesStillSaySomething() {
        let result = MinutesResult(blocks: [], blockSummaries: [],
                                   minutes: MeetingMinutes(summary: ""),
                                   polishedTranscript: "",
                                   generatedByModel: false)
        let text = MinutesCardText.render(result,
                                          transcriptChanged: false,
                                          showsCorrections: false).string
        XCTAssertTrue(text.contains("未生成摘要"))
        XCTAssertTrue(text.contains("模型："))
    }

    private func range(of needle: String, in text: String) -> Range<String.Index>? {
        text.range(of: needle)
    }
}
