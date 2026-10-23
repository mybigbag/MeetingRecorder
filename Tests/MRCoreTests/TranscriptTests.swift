import XCTest
@testable import MRCore

/// 转写稿归并。
///
/// 这里是双轨方案兑现价值的地方：**音轨本身即说话人身份**，
/// 归并只是按时间排序，不需要任何声纹分离，而且两人同时说话也不丢。
final class TranscriptTests: XCTestCase {

    private func seg(_ start: Double, _ end: Double, _ text: String, track: String = "mic") -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, track: track, speaker: "")
    }

    // MARK: - 归并

    func testMergeSortsByStartTime() {
        let doc = TranscriptDocument.merge(
            sessionID: "s1", title: "T", language: "zh-CN", engine: "test",
            tracks: [
                ("system", "对方", [seg(5, 8, "第二句", track: "system"), seg(12, 15, "第四句", track: "system")]),
                ("mic", "我", [seg(0, 4, "第一句"), seg(9, 11, "第三句")]),
            ])
        XCTAssertEqual(doc.segments.map(\.text), ["第一句", "第二句", "第三句", "第四句"])
    }

    func testMergeAssignsSpeakerFromTrackRole() {
        let doc = TranscriptDocument.merge(
            sessionID: "s1", title: "T", language: "zh-CN", engine: "test",
            tracks: [("mic", "我", [seg(0, 1, "a")]), ("system", "对方", [seg(2, 3, "b", track: "system")])])
        XCTAssertEqual(doc.segments[0].speaker, "我")
        XCTAssertEqual(doc.segments[1].speaker, "对方")
    }

    /// 关键用例：双方抢话，两条都必须保留
    func testSimultaneousSpeechKeepsBothTracks() {
        let doc = TranscriptDocument.merge(
            sessionID: "s1", title: "T", language: "zh-CN", engine: "test",
            tracks: [
                ("mic", "我", [seg(0, 10, "我一直在说")]),
                ("system", "对方", [seg(5, 15, "我也在说", track: "system")]),
            ])
        XCTAssertEqual(doc.segments.count, 2, "抢话时两条都要留下——这是双轨相对声纹分离的核心优势")
        XCTAssertTrue(doc.segments.allSatisfy(\.overlapping), "重叠的双方都应被标记")
    }

    func testNonOverlappingSpeechIsNotMarked() {
        let doc = TranscriptDocument.merge(
            sessionID: "s1", title: "T", language: "zh-CN", engine: "test",
            tracks: [
                ("mic", "我", [seg(0, 2, "a")]),
                ("system", "对方", [seg(3, 5, "b", track: "system")]),
            ])
        XCTAssertFalse(doc.segments.contains { $0.overlapping })
    }

    func testTouchingButNotOverlappingIsNotMarked() {
        // 边界：0-5 与 5-10 首尾相接不算重叠
        let doc = TranscriptDocument.merge(
            sessionID: "s1", title: "T", language: "zh-CN", engine: "test",
            tracks: [
                ("mic", "我", [seg(0, 5, "a")]),
                ("system", "对方", [seg(5, 10, "b", track: "system")]),
            ])
        XCTAssertFalse(doc.segments.contains { $0.overlapping })
    }

    func testSameTrackOverlapIsNotFlagged() {
        // 同一轨内部的时间重叠是引擎输出噪声，不该报"抢话"
        let doc = TranscriptDocument.merge(
            sessionID: "s1", title: "T", language: "zh-CN", engine: "test",
            tracks: [("mic", "我", [seg(0, 10, "a"), seg(5, 8, "b")])])
        XCTAssertFalse(doc.segments.contains { $0.overlapping })
    }

    func testMergeWithEmptyTracks() {
        let doc = TranscriptDocument.merge(
            sessionID: "s1", title: "T", language: "zh-CN", engine: "test", tracks: [])
        XCTAssertTrue(doc.segments.isEmpty)
        XCTAssertEqual(doc.sessionID, "s1")
    }

    func testMergePreservesProvidedSpeaker() {
        let explicit = TranscriptSegment(start: 0, end: 1, text: "x", track: "mic", speaker: "张三")
        let doc = TranscriptDocument.merge(
            sessionID: "s1", title: "T", language: "zh-CN", engine: "test",
            tracks: [("mic", "我", [explicit])])
        XCTAssertEqual(doc.segments[0].speaker, "张三", "引擎若给出说话人，应优先于轨角色默认值")
    }

    // MARK: - 时间戳

    func testTimestampFormatting() {
        XCTAssertEqual(TranscriptDocument.timestamp(0), "00:00")
        XCTAssertEqual(TranscriptDocument.timestamp(59.9), "00:59")
        XCTAssertEqual(TranscriptDocument.timestamp(61), "01:01")
        XCTAssertEqual(TranscriptDocument.timestamp(3661), "1:01:01")
    }

    func testNegativeTimestampClamped() {
        XCTAssertEqual(TranscriptDocument.timestamp(-5), "00:00")
    }

    // MARK: - 渲染

    func testMarkdownHasHeaderAndMetadata() {
        let doc = TranscriptDocument.merge(
            sessionID: "2026-09-27-143012-评审", title: "产品评审", language: "zh-CN",
            engine: "apple-speech", tracks: [("mic", "我", [seg(0, 5, "开始吧")])])
        let md = doc.markdown()

        XCTAssertTrue(md.hasPrefix("# 产品评审"))
        XCTAssertTrue(md.contains("2026-09-27-143012-评审"))
        XCTAssertTrue(md.contains("zh-CN"))
        XCTAssertTrue(md.contains("apple-speech"))
        XCTAssertTrue(md.contains("开始吧"))
        XCTAssertTrue(md.contains("**我**"))
    }

    func testMarkdownGroupsConsecutiveSameSpeaker() {
        let doc = TranscriptDocument.merge(
            sessionID: "s1", title: "T", language: "zh-CN", engine: "e",
            tracks: [("mic", "我", [seg(0, 2, "第一"), seg(2, 4, "第二")])])
        let md = doc.markdown()
        // 只数「行首的说话人标题」，避免把页眉说明里的 **我** 也算进去
        let speakerHeadings = md.components(separatedBy: "\n").filter { $0.hasPrefix("**我**") }
        XCTAssertEqual(speakerHeadings.count, 1, "连续同说话人只应出现一个标题行，避免每句都重复")
    }

    func testMarkdownMarksOverlap() {
        let doc = TranscriptDocument.merge(
            sessionID: "s1", title: "T", language: "zh-CN", engine: "e",
            tracks: [
                ("mic", "我", [seg(0, 10, "我说")]),
                ("system", "对方", [seg(5, 15, "他说", track: "system")]),
            ])
        XCTAssertTrue(doc.markdown().contains("⚡"))
    }

    func testMarkdownHandlesEmptyTranscript() {
        let doc = TranscriptDocument(sessionID: "s1", title: "空的", language: "zh-CN", engine: "e")
        let md = doc.markdown()
        XCTAssertTrue(md.contains("空的"))
        XCTAssertTrue(md.contains("没有识别到任何语音内容"))
    }

    func testPlainTextFormat() {
        let doc = TranscriptDocument.merge(
            sessionID: "s1", title: "T", language: "zh-CN", engine: "e",
            tracks: [("mic", "我", [seg(0, 1, "你好")]), ("system", "对方", [seg(2, 3, "在", track: "system")])])
        XCTAssertEqual(doc.plainText(), "我：你好\n对方：在")
    }

    // MARK: - 序列化

    func testJSONRoundTrip() throws {
        let doc = TranscriptDocument.merge(
            sessionID: "s1", title: "T", language: "zh-CN", engine: "e",
            tracks: [("mic", "我", [seg(0, 5, "内容")])])
        let data = try doc.json()

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(TranscriptDocument.self, from: data)
        XCTAssertEqual(back.sessionID, doc.sessionID)
        XCTAssertEqual(back.segments.count, 1)
        XCTAssertEqual(back.segments[0].text, "内容")
    }

    func testJSONIsHumanReadable() throws {
        let doc = TranscriptDocument(sessionID: "s1", title: "T", language: "zh-CN", engine: "e")
        let text = String(data: try doc.json(), encoding: .utf8)!
        XCTAssertTrue(text.contains("\n"), "应为格式化输出，便于人工检查")
        XCTAssertTrue(text.contains("sessionID"))
    }
}
