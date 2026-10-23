import Foundation
import MRCore

/// 纪要生成编排：分块（map）→ 合并（reduce）。
///
/// 这一层是纯逻辑，不碰任何系统资源、不直接调用任何模型——模型藏在
/// `MinutesGenerator` 协议后面。因此它可以（也必须）在无头环境里完整单测：
/// 用 `FakeMinutesGenerator` 验证「块数正确、map/reduce 各被调用几次、最终结构对」。
///
/// 两种结局：
/// - 模型可用 → 真跑 map-reduce；
/// - 模型不可用 → 抛 `MinutesError.modelUnavailable`，由调用方接住后走降级文案
///   （降级文案不属于本层职责，它要不要在界面上提示、提示什么，是前端的事）。
public struct MinutesOrchestrator: Sendable {

    public var generator: any MinutesGenerator
    public var chunker: TranscriptChunker

    public init(generator: any MinutesGenerator, chunker: TranscriptChunker = TranscriptChunker()) {
        self.generator = generator
        self.chunker = chunker
    }

    /// 为一份转写稿生成纪要。
    ///
    /// - Parameter document: 已双轨归并的转写稿
    /// - Returns: 含分块、局部摘要、全局纪要、标点修复正文
    /// - Throws: 模型不可用时抛 `MinutesError.modelUnavailable`
    public func generate(for document: TranscriptDocument) async throws -> MinutesResult {
        // 判据是「还有没有能读的内容」，不是「有没有段」。用户可以逐段清空，
        // 段数还在、内容全没了；照旧往下跑会生成一份看起来正常、其实什么都没说的纪要。
        guard document.hasSpeakableText else {
            throw MinutesError.emptyTranscript
        }

        let blocks = chunker.chunk(document)

        // 模型不可用：不假装能生成，直接交还给调用方去降级。
        guard generator.isAvailable else {
            throw MinutesError.modelUnavailable(
                reason: generator.unavailableReason
                    ?? "生成器报告不可用（本地模型未就绪，或运行在不支持的设备上）")
        }

        // map：每块独立产出局部摘要（含该块标点修复正文）
        var summaries: [BlockSummary] = []
        summaries.reserveCapacity(blocks.count)
        for block in blocks {
            let s = try await generator.summarize(block: block)
            summaries.append(s)
        }

        // reduce：局部摘要 → 全局纪要
        let minutes = try await generator.merge(summaries: summaries)

        // 标点修复正文 = 各块 polishedText 按原序拼接
        let polished = summaries
            .sorted { $0.index < $1.index }
            .map(\.polishedText)
            .joined(separator: "\n\n")

        return MinutesResult(
            blocks: blocks,
            blockSummaries: summaries,
            minutes: minutes,
            polishedTranscript: polished,
            generatedByModel: true,
            generatorName: generator.displayName,
            // 勘误表由编排层直接汇总，不劳模型再抄一遍：抄写只会多一层出错机会，
            // 而且同一处错误在相邻两块里往往被纠正两次（块边界处的重叠发言）。
            corrections: MinutesNormalizer.mergeCorrections(
                summaries.flatMap(\.corrections)))
    }
}

/// 降级纪要：模型不可用时，不假装修标点、也不假造要点。
///
/// 诚实是关键——`TranscriptChunker`/orchestrator 解决的是「能不能跑」，
/// 这一份解决的是「跑不了的时候说什么」。它只提供原稿本身加一句说明，
/// 绝不编造标点或摘要（那会污染用户对稿子真实可读性的判断）。
public struct DegradedMinutes {

    public static func build(from document: TranscriptDocument) -> MinutesResult {
        let blocks = TranscriptChunker().chunk(document)
        // 与分块共用同一份渲染（跳过人工清空的段落）。
        let raw = TranscriptDocument.dialogueText(document.segments)
        return MinutesResult(
            blocks: blocks,
            blockSummaries: [],
            minutes: MeetingMinutes(
                summary: "（本地纪要模型不可用，未生成摘要。原始转写稿如下，标点未经修复。）"),
            polishedTranscript: raw,
            generatedByModel: false)
    }
}
