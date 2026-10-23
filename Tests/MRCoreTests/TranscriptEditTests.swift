import XCTest
@testable import MRCore

/// 转写稿的人工修正（`TranscriptDocument.settingText` / `clearingText` /
/// `restoringOriginalText`）。
///
/// 这一组用例守的是「改动有没有被记住」和「改动有没有被误记」两件事：
/// - 记不住 → 用户改了三遍错字，稿子却还是引擎那一份；
/// - 记错了 → 稿子明明改回原样，界面上还挂着「已修正」，
///   下次重新转写时被当成「有改动，要不要确认覆盖」，白吓用户一次。
final class TranscriptEditTests: XCTestCase {

    private func document(_ texts: [String]) -> TranscriptDocument {
        TranscriptDocument(
            sessionID: "s1", title: "测试会议", language: "zh-CN", engine: "test",
            segments: texts.enumerated().map { i, t in
                TranscriptSegment(start: Double(i) * 2, end: Double(i) * 2 + 2,
                                  text: t, track: "mic", speaker: "我")
            })
    }

    // MARK: - 改写

    /// 改一处：正文更新、原文留存、打上「已修正」。
    func testCorrectingKeepsTheOriginalAndMarksIt() throws {
        let doc = document(["回度到 50%"])
        let updated = try XCTUnwrap(doc.settingText("灰度到 50%", at: 0))

        XCTAssertEqual(updated.segments[0].text, "灰度到 50%")
        XCTAssertEqual(updated.segments[0].manualEdit, .corrected)
        XCTAssertEqual(updated.segments[0].originalText, "回度到 50%",
                       "引擎原文必须留存，否则「恢复原文」无从下手")
        // 原文档不能被改动（值语义 + 不原地改，回滚才有东西可退）
        XCTAssertEqual(doc.segments[0].text, "回度到 50%")
    }

    /// 连改三次，`originalText` 仍是**引擎那一份**，不是上一步。
    func testOriginalIsCapturedOnlyOnce() throws {
        var doc = document(["回度"])
        doc = try XCTUnwrap(doc.settingText("灰度", at: 0))
        doc = try XCTUnwrap(doc.settingText("灰度值", at: 0))
        doc = try XCTUnwrap(doc.settingText("灰度比例", at: 0))

        XCTAssertEqual(doc.segments[0].originalText, "回度",
                       "原文只在第一次修改时留存，否则「恢复原文」会变成「恢复上一步」")
        XCTAssertEqual(doc.segments[0].text, "灰度比例")
    }

    /// 改回与原文一模一样 → 修改痕迹清掉，等于没改过。
    ///
    /// 退化示例：去掉 `settingText` 里「改回去就清标记」那条分支，本用例变红，
    /// 而界面上完全看不出异常——只是重新转写时会多弹一次确认框。
    func testRevertingByTypingClearsTheMark() throws {
        let doc = document(["回度"])
        let corrected = try XCTUnwrap(doc.settingText("灰度", at: 0))
        let reverted = try XCTUnwrap(corrected.settingText("回度", at: 0))

        XCTAssertNil(reverted.segments[0].manualEdit)
        XCTAssertNil(reverted.segments[0].originalText)
    }

    /// 内容没变 → 返回 nil（调用方不该为此写盘）。
    ///
    /// 这条挡的是「按一下方向键就重写一遍 transcript.json」。
    func testUnchangedTextProducesNoDocument() {
        let doc = document(["原样"])
        XCTAssertNil(doc.settingText("原样", at: 0))
    }

    func testOutOfRangeIndexProducesNoDocument() {
        let doc = document(["一段"])
        XCTAssertNil(doc.settingText("改", at: 3))
        XCTAssertNil(doc.clearingText(at: -1))
        XCTAssertNil(doc.restoringOriginalText(at: 9))
    }

    /// 打字途中的**尾随空格必须保留**。
    ///
    /// 如果为了「干净」在存盘前 trim，用户打「hello 」再打「world」会得到
    /// 「helloworld」——输入法里这是最容易被当成「App 坏了」的一种。
    func testTrailingSpaceWhileTypingIsNotTrimmed() throws {
        let doc = document(["ab"])
        let step = try XCTUnwrap(doc.settingText("ab ", at: 0))
        XCTAssertEqual(step.segments[0].text, "ab ")
        let next = try XCTUnwrap(step.settingText("ab c", at: 0))
        XCTAssertEqual(next.segments[0].text, "ab c")
    }

    // MARK: - 清空

    /// 清空：正文空、标记 `cleared`、原文留着。
    func testClearingEmptiesTheTextButKeepsTheOriginal() throws {
        let doc = document(["这段是识别噪音"])
        let cleared = try XCTUnwrap(doc.clearingText(at: 0))

        XCTAssertTrue(cleared.segments[0].isBlank)
        XCTAssertEqual(cleared.segments[0].manualEdit, .cleared)
        XCTAssertEqual(cleared.segments[0].originalText, "这段是识别噪音")
        XCTAssertEqual(cleared.segments.count, 1, "清空不是删除，段数不变")
    }

    /// 只打了几个空格也算清空。判据是「去掉空白后为空」，不是 `isEmpty`。
    func testWhitespaceOnlyCountsAsCleared() throws {
        let doc = document(["有内容"])
        let cleared = try XCTUnwrap(doc.settingText("   ", at: 0))
        XCTAssertEqual(cleared.segments[0].manualEdit, .cleared)
        XCTAssertFalse(cleared.hasSpeakableText)
    }

    /// 「恢复原文」把引擎那一份拿回来，并清掉修改痕迹。
    func testRestoringBringsBackTheEngineText() throws {
        let doc = document(["回度"])
        let cleared = try XCTUnwrap(doc.clearingText(at: 0))
        let restored = try XCTUnwrap(cleared.restoringOriginalText(at: 0))

        XCTAssertEqual(restored.segments[0].text, "回度")
        XCTAssertNil(restored.segments[0].manualEdit)
    }

    /// 没改过的段没有原文可恢复 → nil，而不是「恢复成空」。
    func testRestoringWithoutOriginalProducesNothing() {
        XCTAssertNil(document(["没改过"]).restoringOriginalText(at: 0))
    }

    // MARK: - 计数与可用性

    func testCountsSeparateCorrectedFromCleared() {
        var doc = document(["a", "b", "c"])
        doc = doc.settingText("a2", at: 0) ?? doc
        doc = doc.clearingText(at: 1) ?? doc

        XCTAssertEqual(doc.manualEditCount, 2)
        XCTAssertEqual(doc.clearedCount, 1)
    }

    /// 全部清空后「没有可用内容」——纪要层据此拒绝生成，
    /// 而不是拿一串空说话人标签去让模型编一份纪要。
    func testAllClearedMeansNothingToSummarize() {
        var doc = document(["a", "b"])
        doc = doc.clearingText(at: 0) ?? doc
        doc = doc.clearingText(at: 1) ?? doc

        XCTAssertFalse(doc.hasSpeakableText)
        XCTAssertEqual(doc.segments.count, 2, "段还在，只是没有内容")
    }

    // MARK: - 渲染

    /// 清空的段落不出现在「说话人：正文」里。
    func testDialogueTextSkipsClearedSegments() {
        var doc = document(["第一句", "第二句"])
        doc = doc.clearingText(at: 0) ?? doc

        let text = TranscriptDocument.dialogueText(doc.segments)
        XCTAssertEqual(text, "我：第二句")
        XCTAssertFalse(text.contains("我：\n"), "空说话人行是纯噪音，不能留给模型")
    }

    func testPlainTextSkipsClearedSegments() {
        var doc = document(["甲", "乙"])
        doc = doc.clearingText(at: 1) ?? doc
        XCTAssertEqual(doc.plainText(), "我：甲")
    }

    /// `transcript.md` 里：头部有一句人工修改的说明，清空的那行写明「已清空」。
    ///
    /// 这份 .md 是拿去转发的东西，读的人有权知道哪几句不是引擎听出来的。
    func testMarkdownDeclaresEditsAndClearedRows() {
        var doc = document(["回度到 50%", "嗯"])
        doc = doc.settingText("灰度到 50%", at: 0) ?? doc
        doc = doc.clearingText(at: 1) ?? doc

        let md = doc.markdown()
        XCTAssertTrue(md.contains("本稿有 2 段人工修改"), md)
        XCTAssertTrue(md.contains("其中 1 段已清空"), md)
        XCTAssertTrue(md.contains("（已人工清空）"), md)
        XCTAssertTrue(md.contains("灰度到 50%"))
    }

    /// 一处都没改的稿子**不能**出现这行说明——假提示会让用户以为稿子被动过。
    func testMarkdownStaysSilentWhenUntouched() {
        let md = document(["原话"]).markdown()
        XCTAssertFalse(md.contains("人工修改"), md)
        XCTAssertFalse(md.contains("已人工清空"), md)
    }

    // MARK: - 旧文件兼容

    /// 旧 `transcript.json` 没有 `manualEdit` / `originalText` 两个键，
    /// 必须照样解码成功（都是 Optional，合成解码走 `decodeIfPresent`）。
    ///
    /// 这条是加字段时的**必测项**：一个带默认值的非 Optional 属性
    /// 会让所有旧文件 `keyNotFound`，而症状是「这场会议的转写稿突然打不开了」。
    func testOldTranscriptJSONWithoutEditKeysStillDecodes() throws {
        let json = """
        {
          "version": 1,
          "sessionID": "s1",
          "title": "旧会议",
          "language": "zh-CN",
          "engine": "apple",
          "generatedAt": "2026-10-01T09:00:00Z",
          "segments": [
            {"start": 0, "end": 2, "text": "旧稿的一句话", "track": "mic",
             "speaker": "我", "overlapping": false}
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(TranscriptDocument.self, from: Data(json.utf8))

        XCTAssertEqual(doc.segments.count, 1)
        XCTAssertEqual(doc.segments[0].text, "旧稿的一句话")
        XCTAssertNil(doc.segments[0].manualEdit)
        XCTAssertNil(doc.segments[0].originalText)
        XCTAssertEqual(doc.manualEditCount, 0)
    }

    /// 改过之后再编码、再解码，痕迹和原文都还在（不然重启 App 就丢）。
    func testEditsSurviveJSONRoundTrip() throws {
        let edited = try XCTUnwrap(document(["回度"]).settingText("灰度", at: 0))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(TranscriptDocument.self, from: edited.json())

        XCTAssertEqual(back.segments[0].text, "灰度")
        XCTAssertEqual(back.segments[0].manualEdit, .corrected)
        XCTAssertEqual(back.segments[0].originalText, "回度")
    }
}
