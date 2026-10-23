import XCTest
@testable import MRCore

/// 用扬声器开会时的双轨重复：同一句话被记两遍。
///
/// ## 症状
///
/// 用户报的是「转写出来的文字稿发生重复，无法使用」。物理链条很清楚：
/// 系统音频轨直接从系统输出抓数字信号，麦克风则会把扬声器放出来的对方声音
/// 一起收进去。两轨各转一遍，同一句话在稿子里出现两次，一次标「我」一次标「对方」。
///
/// ## 这一组在防什么
///
/// 去重是一件**会删掉内容**的事，判据宽一点就删掉真话。所以每一条门槛都配了
/// 一条「不许删」的对照：时间不重叠不许删、文本不像不许删、同一轨不许删、
/// 短应答不许删。只写「该删的删了」的用例是站不住的——一个恒删的实现能全绿。
final class TranscriptEchoTests: XCTestCase {

    private func seg(_ start: Double, _ end: Double, _ text: String,
                     track: String = "mic") -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, track: track, speaker: "")
    }

    /// 一对回声：系统轨原声 + 麦克风晚到 0.4 秒的副本，内容几乎一样。
    private var echoPair: [TranscriptSegment] {
        [
            seg(10.0, 14.0, "我们下周一把方案定下来", track: "system"),
            seg(10.4, 14.4, "我们下周一把方案定下来吧"),
        ]
    }

    // MARK: - 阳性对照：先证明「这对数据本来就是重复的」

    /// 少了这条，下面所有「只剩一句」的断言都是空的——
    /// 换一对本来就不重复的数据，一个什么都不删的实现照样全绿。
    func testThePairReallyIsDuplicatedBeforeDeduplication() {
        let pair = echoPair
        XCTAssertTrue(
            TranscriptDocument.isEchoText(pair[0].text, pair[1].text),
            "这一对被当作回声，前提是它们的文本确实高度相似")
        XCTAssertGreaterThanOrEqual(
            TranscriptDocument.overlapRatio(pair[1], pair[0]),
            TranscriptDocument.EchoRule.overlapRatio,
            "这一对被当作回声，前提也是它们的时间窗确实重叠")
    }

    /// 判据本身不许恒真：两句不同的话必须判为不重复。
    func testSimilarityIsNotTriviallyHigh() {
        let a = "我们下周一把方案定下来"
        let b = "我觉得这个价格有点高"
        XCTAssertLessThan(
            TranscriptDocument.textSimilarity(
                TranscriptDocument.normalized(a),
                TranscriptDocument.normalized(b)),
            TranscriptDocument.EchoRule.similarity,
            "判据若对完全不同的两句话也给出高相似度，去重就会删掉真实的双方发言")
    }

    // MARK: - 该删的

    func testEchoIsDropped() {
        let kept = TranscriptDocument.dropCrossTrackEcho(echoPair)
        XCTAssertEqual(kept.count, 1, "同一句话被两轨各转一遍时，稿子里只应留一次")
    }

    /// 保留先开始的那条：回声走「扬声器 → 空气 → 麦克风」，必然晚到。
    func testTheEarlierCopySurvives() {
        let kept = TranscriptDocument.dropCrossTrackEcho(echoPair)
        XCTAssertEqual(kept.first?.track, "system",
                       "先到的是数字信号那一路，晚到的麦克风副本才是回声")
        XCTAssertEqual(kept.first?.start, 10.0)
    }

    /// 起点分不出先后时保留系统轨——它没有房间混响，是同一句话里更干净的一份。
    func testWhenStartsAreTooCloseTheSystemTrackWins() {
        let kept = TranscriptDocument.dropCrossTrackEcho([
            seg(10.0, 14.0, "我们下周一把方案定下来"),        // 麦克风先到 0.1 秒
            seg(10.1, 14.1, "我们下周一把方案定下来", track: "system"),
        ])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.track, "system",
                       "相差小于 \(TranscriptDocument.EchoRule.startTolerance) 秒时先后不可靠，"
                       + "改按轨别裁决：留数字信号那一路")
    }

    /// 端到端症状：稿子里那句话只出现一次。
    func testMergedDocumentContainsTheSentenceOnce() {
        let doc = TranscriptDocument.merge(
            sessionID: "s1", title: "T", language: "zh-CN", engine: "test",
            tracks: [("mic", "我", echoPair.filter { $0.track == "mic" }),
                     ("system", "对方", echoPair.filter { $0.track == "system" })])
        let occurrences = doc.markdown()
            .components(separatedBy: "我们下周一把方案定下来")
            .count - 1
        XCTAssertEqual(occurrences, 1, "用户看到的就是「这句话怎么说了两遍」")
    }

    // MARK: - 不该删的

    /// 时间不重叠：同一句话在会议里说了两次，两次都要留。
    func testRepeatedPhraseAtDifferentTimesIsKept() {
        let kept = TranscriptDocument.dropCrossTrackEcho([
            seg(0, 4, "我们下周一把方案定下来"),
            seg(60, 64, "我们下周一把方案定下来", track: "system"),
        ])
        XCTAssertEqual(kept.count, 2, "相隔一分钟的同一句话是两次真实发言，不是回声")
    }

    /// 抢话：两人同时说不同的话，一条都不能删。这是双轨的核心价值。
    func testSimultaneousDifferentSpeechIsKept() {
        let kept = TranscriptDocument.dropCrossTrackEcho([
            seg(0, 8, "我这边觉得可以先做灰度"),
            seg(2, 9, "对方认为应该全量上线", track: "system"),
        ])
        XCTAssertEqual(kept.count, 2)
    }

    /// 同一轨内部的相似段落不归这里管——那是引擎输出噪声，删了会丢内容。
    func testSameTrackDuplicatesAreKept() {
        let kept = TranscriptDocument.dropCrossTrackEcho([
            seg(0, 6, "我们下周一把方案定下来"),
            seg(1, 7, "我们下周一把方案定下来"),
        ])
        XCTAssertEqual(kept.count, 2)
    }

    /// 短应答不去重：「好的」两个人同时说是常事，那是真话。
    func testShortInterjectionsAreKept() {
        let kept = TranscriptDocument.dropCrossTrackEcho([
            seg(0, 1, "好的"),
            seg(0, 1, "好的", track: "system"),
        ])
        XCTAssertEqual(kept.count, 2,
                       "短应答挡在长度门槛外：宁可留一句重复，也不能删掉一句真话")
    }

    /// 时间只擦到一点边、文本却很像：这是两个人接力说了同一句，不是回声。
    func testBarelyOverlappingSimilarTextIsKept() {
        let kept = TranscriptDocument.dropCrossTrackEcho([
            seg(0, 10, "我们下周一把方案定下来"),
            seg(9.8, 20, "我们下周一把方案定下来吧", track: "system"),
        ])
        XCTAssertEqual(kept.count, 2,
                       "重叠只占较短那段的 \(0.2 / 10)，远低于门槛——这是接力，不是回声")
    }

    // MARK: - 相似度函数的边界

    func testSimilarityOfIdenticalTextIsOne() {
        let s = "我们下周一把方案定下来"
        XCTAssertEqual(TranscriptDocument.textSimilarity(s, s), 1)
    }

    func testNormalizationDropsPunctuationAndCase() {
        XCTAssertEqual(TranscriptDocument.normalized("我们，下周一。把方案定下来！"),
                       "我们下周一把方案定下来")
        XCTAssertEqual(TranscriptDocument.normalized("OK, Done."), "okdone")
    }

    /// 单字文本不该因为「没有二元组」而被判成完全不相似以外的怪值。
    func testSingleCharacterSimilarityIsWellDefined() {
        XCTAssertEqual(TranscriptDocument.textSimilarity("好", "好"), 1)
        XCTAssertEqual(TranscriptDocument.textSimilarity("好", "不"), 0)
    }
}
