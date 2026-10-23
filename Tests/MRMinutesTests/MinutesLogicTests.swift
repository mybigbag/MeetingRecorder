import Foundation
import XCTest
import MRCore
import MRMinutes

/// 假生成器：不调任何模型，按可预测的规则造数据。
///
/// 用途是**隔离测试编排逻辑**——我们要验证的是「map 被每块调一次、
/// reduce 被调一次、最终结构正确」，而不是模型说了什么。
struct FakeMinutesGenerator: MinutesGenerator {
    var available: Bool
    var isAvailable: Bool { available }

    func summarize(block: TranscriptBlock) async throws -> BlockSummary {
        BlockSummary(
            index: block.index,
            polishedText: "[polished#\(block.index)] \(block.text)",
            summary: "局部摘要\(block.index)",
            keyPoints: ["要点\(block.index)-a", "要点\(block.index)-b"],
            decisions: ["决议\(block.index)"],
            actionItems: [ActionItem(task: "待办\(block.index)", owner: "某人", due: "周五")])
    }

    func merge(summaries: [BlockSummary]) async throws -> MeetingMinutes {
        MeetingMinutes(
            summary: "全局摘要（合并了 \(summaries.count) 块）",
            keyPoints: summaries.flatMap { $0.keyPoints },
            decisions: summaries.flatMap { $0.decisions },
            actionItems: summaries.flatMap { $0.actionItems })
    }
}

// MARK: - TranscriptChunker

final class ChunkerTests: XCTestCase {

    /// 造一段转写稿：count 段，每段约 charsPerSeg 个非空白字符。
    static func makeDocument(segmentCount: Int, charsPerSeg: Int) -> TranscriptDocument {
        var segs: [TranscriptSegment] = []
        for i in 0..<segmentCount {
            let text = String(repeating: "中", count: charsPerSeg)
            segs.append(TranscriptSegment(
                start: Double(i) * 10, end: Double(i) * 10 + 9,
                text: text, track: "mic", speaker: "我"))
        }
        return TranscriptDocument(
            sessionID: "test", title: "测试", language: "zh-CN",
            engine: "apple-speech", segments: segs)
    }

    func test_emptyDoc_returnsOneEmptyBlock() {
        let doc = TranscriptDocument(
            sessionID: "x", title: "x", language: "zh-CN", engine: "x", segments: [])
        let blocks = TranscriptChunker().chunk(doc)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].text.isEmpty)
    }

    func test_normalSegmentsStayIntact_andWithinBudget() {
        // 每段 100 字（≈100 token），预算 300。7 段共 700 → 至少 3 块，每块 ≤300。
        let doc = Self.makeDocument(segmentCount: 7, charsPerSeg: 100)
        let blocks = TranscriptChunker(maxTokensPerBlock: 300).chunk(doc)

        // 没有一块塞进「被切断的 segment」：每段贡献恰好一行，行数应等于段数。
        let totalLines = blocks.reduce(0) { $0 + $1.text.split(separator: "\n").count }
        XCTAssertEqual(totalLines, 7, "7 段应原样保留，未被在句中断开")

        for b in blocks {
            XCTAssertLessThanOrEqual(TranscriptChunker.estimateTokens(b.text), 300)
        }
        XCTAssertGreaterThanOrEqual(blocks.count, 3)
    }

    func test_oversizedSegmentIsSplit_withoutLosingCharacters() {
        // 一段 5000 字，预算 300。会被切成多块，但总字数守恒。
        let doc = Self.makeDocument(segmentCount: 1, charsPerSeg: 5000)
        let blocks = TranscriptChunker(maxTokensPerBlock: 300).chunk(doc)
        XCTAssertGreaterThanOrEqual(blocks.count, 16, "5000 字 / 300 应至少 17 块")

        let joined = blocks.map(\.text).joined()
        let originalChars = doc.segments[0].text.count
        let recoveredChars = joined.filter { $0 == "中" }.count
        XCTAssertEqual(recoveredChars, originalChars, "切碎后不得丢字")
    }

    func test_oversizedNoPunctuationFallsBackToStep() {
        // 一段完全没有句读的 5000 字，预算 300：必须靠步长硬切，结果仍全 ≤300。
        let seg = TranscriptSegment(
            start: 0, end: 9, text: String(repeating: "中", count: 5000),
            track: "mic", speaker: "我")
        let doc = TranscriptDocument(
            sessionID: "x", title: "x", language: "zh-CN", engine: "x", segments: [seg])
        let blocks = TranscriptChunker(maxTokensPerBlock: 300).chunk(doc)
        for b in blocks {
            XCTAssertLessThanOrEqual(TranscriptChunker.estimateTokens(b.text), 300)
        }
    }
}

// MARK: - MinutesOrchestrator

final class OrchestratorTests: XCTestCase {

    static func sampleDoc() -> TranscriptDocument {
        var segs: [TranscriptSegment] = []
        for i in 0..<6 {
            segs.append(TranscriptSegment(
                start: Double(i) * 10, end: Double(i) * 10 + 9,
                text: String(repeating: "中", count: 100),
                track: "mic", speaker: "我"))
        }
        return TranscriptDocument(
            sessionID: "test", title: "测试", language: "zh-CN",
            engine: "apple-speech", segments: segs)
    }

    func test_availableRunsMapReduce_structureCorrect() async throws {
        let gen = FakeMinutesGenerator(available: true)
        let orch = MinutesOrchestrator(
            generator: gen, chunker: TranscriptChunker(maxTokensPerBlock: 300))
        let result = try await orch.generate(for: Self.sampleDoc())

        XCTAssertTrue(result.generatedByModel)
        // 6 段 ×（100 字 + 「我：」前缀 2 = 102 token）÷ 预算 300 → 每 2 段一块 = 3 块
        XCTAssertEqual(result.blocks.count, 3, "应切成 3 块")
        XCTAssertEqual(result.blockSummaries.count, 3, "每块 map 一次")
        XCTAssertTrue(result.minutes.summary.contains("合并了 3 块"))

        XCTAssertTrue(result.polishedTranscript.contains("[polished#1]"))
        XCTAssertTrue(result.polishedTranscript.contains("[polished#3]"))
        XCTAssertEqual(result.minutes.actionItems.count, 3)
    }

    func test_unavailableThrows_modelUnavailable() async {
        let gen = FakeMinutesGenerator(available: false)
        let orch = MinutesOrchestrator(generator: gen)
        do {
            _ = try await orch.generate(for: Self.sampleDoc())
            XCTFail("应当抛错")
        } catch let MinutesError.modelUnavailable(reason) {
            XCTAssertFalse(reason.isEmpty)
        } catch {
            XCTFail("抛出的不是预期的 modelUnavailable：\(error)")
        }
    }

    func test_emptyThrows_emptyTranscript() async {
        let gen = FakeMinutesGenerator(available: true)
        let orch = MinutesOrchestrator(generator: gen)
        let empty = TranscriptDocument(
            sessionID: "x", title: "x", language: "zh-CN", engine: "x", segments: [])
        do {
            _ = try await orch.generate(for: empty)
            XCTFail("应当抛错")
        } catch MinutesError.emptyTranscript {
            // 期望
        } catch {
            XCTFail("应为 emptyTranscript：\(error)")
        }
    }
}

// MARK: - DegradedMinutes

final class DegradedMinutesTests: XCTestCase {

    func test_degradedIsHonest_keepsRawText() {
        var segs: [TranscriptSegment] = []
        segs.append(TranscriptSegment(
            start: 0, end: 5, text: "今天开会讨论项目", track: "mic", speaker: "我"))
        segs.append(TranscriptSegment(
            start: 5, end: 9, text: "明确了下一步计划", track: "system", speaker: "对方"))
        let doc = TranscriptDocument(
            sessionID: "x", title: "x", language: "zh-CN", engine: "x", segments: segs)
        let result = DegradedMinutes.build(from: doc)

        XCTAssertFalse(result.generatedByModel)
        XCTAssertTrue(result.blockSummaries.isEmpty)
        XCTAssertTrue(result.minutes.summary.contains("未生成摘要"))
        XCTAssertTrue(result.polishedTranscript.contains("今天开会讨论项目"))
        XCTAssertTrue(result.polishedTranscript.contains("明确了下一步计划"))
    }
}
