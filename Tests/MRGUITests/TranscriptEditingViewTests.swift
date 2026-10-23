import XCTest
import MRCore
import MRMinutes
import MRSession
@testable import MRGUI

/// 编辑转写稿与「纪要过期」提示上的**文案判据**。
///
/// 为什么单测字符串：这些文字是界面上唯一的告知渠道，而它们出错时
/// 编译通过、界面没报错、测试也全绿——例如「稿子改过、纪要基于旧稿」
/// 这条提示若在折叠态被漏掉，用户看到的就只是一句「已折叠」。
final class TranscriptEditingViewTests: XCTestCase {

    private func document(_ texts: [String]) -> TranscriptDocument {
        TranscriptDocument(
            sessionID: "s1", title: "t", language: "zh-CN", engine: "test",
            segments: texts.enumerated().map { i, t in
                TranscriptSegment(start: Double(i) * 2, end: Double(i) * 2 + 2,
                                  text: t, track: "mic", speaker: "我")
            })
    }

    private func result(generated: Bool = true) -> MinutesResult {
        MinutesResult(
            blocks: [], blockSummaries: [],
            minutes: MeetingMinutes(summary: "摘要"),
            polishedTranscript: "", generatedByModel: generated, generatorName: "测试模型")
    }

    // MARK: - 转写稿标题旁的计数

    /// 改过几段必须写在标题旁：编辑态一退出，界面上没有别处说得出来
    /// 「这份稿子哪些字不是引擎听的」。
    func testTitleHintShowsManualEditCount() {
        var doc = document(["a", "b", "c"])
        doc = doc.settingText("a2", at: 0) ?? doc

        let hint = MeetingDetailView.transcriptTitleHint(document: doc)
        XCTAssertTrue(hint.contains("3 段"), hint)
        XCTAssertTrue(hint.contains("人工修正 1 段"), hint)
    }

    func testTitleHintStaysPlainWhenUntouched() {
        let hint = MeetingDetailView.transcriptTitleHint(document: document(["a", "b"]))
        XCTAssertEqual(hint, "2 段", "没改过的稿子不该挂「人工修正」：\(hint)")
    }

    // MARK: - 纪要过期提示

    /// 折叠态也必须说出「纪要基于旧稿」——它就是为折叠准备的：
    /// 展开时卡片顶部还有一条橙色警告，收起后那条警告一起没了。
    func testCollapsedHintCarriesTheStaleWarning() {
        let hint = MeetingDetailView.minutesCollapsedHint(
            phase: .done(generatorName: "测试模型"),
            result: result(),
            transcriptChanged: true)

        XCTAssertTrue(hint.contains("⚠️"), hint)
        XCTAssertTrue(hint.contains("改过"), hint)
        XCTAssertFalse(hint.contains("展开可读摘要、议题、决议与待办"),
                       "有新鲜度问题时不能只说「展开可读」：\(hint)")
    }

    func testCollapsedHintStaysNormalWhenTranscriptIsFresh() {
        let hint = MeetingDetailView.minutesCollapsedHint(
            phase: .done(generatorName: "测试模型"),
            result: result(),
            transcriptChanged: false)
        XCTAssertTrue(hint.contains("展开可读摘要"), hint)
    }

    /// 降级稿 + 稿子改过：两条都要说。只说一条，另一种真相就没人知道了。
    func testCollapsedHintReportsBothDegradedAndStale() {
        let hint = MeetingDetailView.minutesCollapsedHint(
            phase: .done(generatorName: ""),
            result: result(generated: false),
            transcriptChanged: true)
        XCTAssertTrue(hint.contains("降级稿"), hint)
        XCTAssertTrue(hint.contains("改过"), hint)
    }

    // MARK: - 重新转写的确认文案

    /// 覆盖前的话必须说清两件事：**几处会被覆盖**、**有没有替代做法**。
    func testRetranscribeWarningIsSpecific() {
        let text = MeetingDetailView.retranscribeWarning(manualEditCount: 3)
        XCTAssertTrue(text.contains("3 处"), text)
        XCTAssertTrue(text.contains("覆盖"), text)
        XCTAssertTrue(text.contains("编辑"), "要给出「只想改个别错字」的替代路径：\(text)")
    }

    // MARK: - 编辑态说明

    func testEditModeHintCountsClearedSegments() {
        let hint = MeetingDetailView.editModeHint(manualEditCount: 3, clearedCount: 2)
        XCTAssertTrue(hint.contains("已清空 2 段"), hint)
        XCTAssertTrue(hint.contains("不参与纪要生成"), hint)
    }

    func testEditModeHintIsSilentWhenNothingChanged() {
        let hint = MeetingDetailView.editModeHint(manualEditCount: 0, clearedCount: 0)
        XCTAssertFalse(hint.contains("已清空"), hint)
        XCTAssertFalse(hint.contains("已修正"), hint)
    }

    /// 「恢复原文」的提示要把**原文内容**带上：只写「恢复原文」，
    /// 用户不知道会恢复成什么，就不敢点。
    func testRestoreHelpQuotesTheOriginal() {
        let segment = TranscriptSegment(
            start: 0, end: 2, text: "灰度", track: "mic", speaker: "我",
            manualEdit: .corrected, originalText: "回度")
        XCTAssertTrue(MeetingDetailView.restoreHelp(segment).contains("回度"))
    }
}
