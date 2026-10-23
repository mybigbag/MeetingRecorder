import XCTest
@testable import MRMinutes
import MRCore

/// 人工清空的段落**不许进纪要**。
///
/// 清空的语义是「这段不算数」。如果它仍然以「我：」这种空行混进分块文本，
/// 模型看到的是一个又一个没有内容的说话人标签——轻则浪费 token，
/// 重则被它当成「这里有人说话但没听清」而自己编一句补上。
final class ChunkerClearedSegmentTests: XCTestCase {

    private func document(_ texts: [String]) -> TranscriptDocument {
        TranscriptDocument(
            sessionID: "s1", title: "清空测试", language: "zh-CN", engine: "test",
            segments: texts.enumerated().map { i, t in
                TranscriptSegment(start: Double(i) * 2, end: Double(i) * 2 + 2,
                                  text: t, track: "mic", speaker: "我")
            })
    }

    func testClearedSegmentsDoNotReachBlocks() {
        var doc = document(["第一句", "嗯嗯嗯", "第二句"])
        doc = doc.clearingText(at: 1) ?? doc

        let blocks = TranscriptChunker().chunk(doc)
        let text = blocks.map(\.text).joined(separator: "\n")

        XCTAssertTrue(text.contains("第一句"))
        XCTAssertTrue(text.contains("第二句"))
        XCTAssertFalse(text.contains("嗯嗯嗯"), "被清空的内容不该进块：\n\(text)")
        XCTAssertFalse(text.contains("我：\n"), "空说话人行是噪音：\n\(text)")
    }

    /// 全部清空时仍要给出一个块，但**内容是空的**——调用方靠
    /// `hasSpeakableText` 提前拦住，不该靠块数判断。
    func testAllClearedStillYieldsOneEmptyBlock() {
        var doc = document(["a", "b"])
        doc = doc.clearingText(at: 0) ?? doc
        doc = doc.clearingText(at: 1) ?? doc

        let blocks = TranscriptChunker().chunk(doc)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].text.isEmpty)
    }

    /// 全清空的稿子：编排层直接拒绝，**不发起模型调用**。
    ///
    /// 退化示例：把判据从 `hasSpeakableText` 改回 `!segments.isEmpty`，
    /// 本用例立刻红——而那时真实调用会拿一串空行去让模型编一份纪要。
    func testOrchestratorRefusesFullyClearedTranscript() async {
        var doc = document(["a", "b"])
        doc = doc.clearingText(at: 0) ?? doc
        doc = doc.clearingText(at: 1) ?? doc

        let generator = CountingGenerator()
        let orchestrator = MinutesOrchestrator(generator: generator)

        do {
            _ = try await orchestrator.generate(for: doc)
            XCTFail("全清空必须拒绝生成")
        } catch let error as MinutesError {
            XCTAssertEqual(error, .emptyTranscript)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
        let calls = await generator.summarizeCallCount
        XCTAssertEqual(calls, 0, "拒绝之后不许再调模型")
    }
}

/// 数一数被调用了几次的最小生成器。
private actor CountingGenerator: MinutesGenerator {
    private(set) var summarizeCallCount = 0

    nonisolated var isAvailable: Bool { true }

    func summarize(block: TranscriptBlock) async throws -> BlockSummary {
        summarizeCallCount += 1
        return BlockSummary(index: block.index, polishedText: block.text, summary: "")
    }

    func merge(summaries: [BlockSummary]) async throws -> MeetingMinutes {
        MeetingMinutes(summary: "")
    }
}
