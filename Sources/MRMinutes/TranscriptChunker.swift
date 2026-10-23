import Foundation
import MRCore

/// 把整份转写稿切成若干块，使每块 token 数不超过预算。
///
/// **为什么需要它**：本地 FoundationModels 上下文只有 4096 token，而一场
/// 1 小时的会议转写稿约 1.5 万字（中文约 1 字 1 token，远超上下文）。
/// 不分块就直接丢给模型，必然截断或失败。所以必须「分而治之」——
/// 每块独立 map，再合并 reduce。
///
/// **切分原则（写在代码里，改一处要同时想清楚对哪些结论有影响）**：
/// 1. **不切断 segment**：一个语义段落（说话人一句完整的话）要么整段进同一块，
///    要么……如果单段本身就超预算，才在句子边界强制切。
/// 2. **token 估算口径统一为「渲染后」**：所有块文本都带「说话人：」前缀，
///    估算与累积必须用渲染后的文本，否则前缀会悄悄把块顶过预算（已踩过）。
/// 3. **token 估算保守高估**：中文 1 字 ≈ 1 token，英文按字符数算会高估；
///    高估只会让块更小、更安全，不会爆上下文，所以直接数非空白字符。
/// 4. **保留时间窗**：每块记录 `start`/`end`，纪要在必要时可回溯「这句话几点说的」。
///
/// 纯函数、零系统依赖，可在无头环境完整单元测试。
public struct TranscriptChunker: Sendable {

    /// 每块允许的最大**输入** token 数。
    ///
    /// 4096 是硬上限；扣掉提示词与模型输出（摘要本身也要占 token），
    /// 留 1000 给输出比较宽裕。改这个数前先想清楚：调大可能爆上下文，
    /// 调小只是多几块、多几次模型调用（更慢但不危险）。
    public var maxTokensPerBlock: Int

    public init(maxTokensPerBlock: Int = 3000) {
        self.maxTokensPerBlock = maxTokensPerBlock
    }

    /// 粗略的 token 估算：非空白字符数。中文准、英文高估，方向安全。
    public static func estimateTokens(_ text: String) -> Int {
        text.unicodeScalapesCount
    }

    /// 把整份转写稿切成块。
    ///
    /// - Parameter document: 已经过双轨归并的转写稿
    /// - Returns: 至少 1 块（即使空稿也返回 1 个空块，调用方好统一处理）
    public func chunk(_ document: TranscriptDocument) -> [TranscriptBlock] {
        let segments = document.segments
        guard !segments.isEmpty else {
            return [TranscriptBlock(index: 1, start: 0, end: 0, text: "")]
        }

        var blocks: [TranscriptBlock] = []
        var currentSegments: [TranscriptSegment] = []
        var currentTokens = 0
        var blockIndex = 1
        var blockStart = segments[0].start

        func flush() {
            guard !currentSegments.isEmpty else { return }
            let end = currentSegments.last?.end ?? blockStart
            let text = Self.renderBlock(currentSegments)
            blocks.append(TranscriptBlock(
                index: blockIndex, start: blockStart, end: end, text: text))
            blockIndex += 1
            currentSegments = []
            currentTokens = 0
        }

        for seg in segments {
            // 被人工清空的段落**不进块**：它渲染出来是空串，占 0 token，
            // 但会白白撑开块的时间窗、也可能单独凑出一个「只有空行」的块。
            // 清空的语义就是「这段不存在」，那就让它在分块这一层就不存在。
            guard !seg.isBlank else { continue }

            // 渲染后（含「说话人：」前缀）的 token，与 currentTokens 同口径
            let segText = Self.renderBlock([seg])
            let segTokens = Self.estimateTokens(segText)

            if segTokens > maxTokensPerBlock {
                // 单段超预算：切碎成纯文本碎片，逐个按「渲染后」口径投进当前块。
                // 碎片同属一个 segment，时间窗无法细分，统一用 seg.start 兜底起点。
                if !currentSegments.isEmpty { flush() }
                blockStart = seg.start
                for piece in Self.splitOversizedSegment(seg, budget: maxTokensPerBlock) {
                    let subSeg = TranscriptSegment(
                        start: seg.start, end: seg.end, text: piece,
                        track: seg.track, speaker: seg.speaker,
                        overlapping: seg.overlapping)
                    let subText = Self.renderBlock([subSeg])
                    let subTokens = Self.estimateTokens(subText)
                    if !currentSegments.isEmpty,
                       currentTokens + subTokens > maxTokensPerBlock {
                        flush()
                        blockStart = seg.start
                    }
                    currentSegments.append(subSeg)
                    currentTokens += subTokens
                }
                continue
            }

            // 正常段落：放进当前块；放不下就先 flush 再开新块
            if !currentSegments.isEmpty,
               currentTokens + segTokens > maxTokensPerBlock {
                flush()
                blockStart = seg.start
            }
            currentSegments.append(seg)
            currentTokens += segTokens
        }
        flush()

        // 一段都没有（全部被人工清空）时仍要给调用方一个块，别返回空数组——
        // 空数组会让调用方在上游多写一层「可能为空」的判断。
        return blocks.isEmpty ? [TranscriptBlock(index: 1, start: 0, end: 0, text: "")] : blocks
    }

    // MARK: - 内部

    /// 把若干 segment 渲染成「说话人：文本」的可读块文本。
    ///
    /// **跳过正文为空的段落**（被用户人工清空的那一段）。渲染成「我：」的空行
    /// 只会让模型以为「这里有人说话但没听清」，而真实含义是「这段不算数」。
    /// 与降级稿、纯文本导出共用 `TranscriptDocument.dialogueText`——
    /// 三处各写一遍的话，「清空的段算不算内容」会有三种答案。
    static func renderBlock(_ segments: [TranscriptSegment]) -> String {
        TranscriptDocument.dialogueText(segments)
    }

    /// 把超预算的单段切成纯文本碎片。**保证每个碎片渲染后（含说话人前缀）不超过 budget**。
    ///
    /// 两步：
    /// 1. 先按标点/句读边界切；
    /// 2. 仍有超 budget 的碎片（连续无标点长句）→ 按步长硬切兜底，步长预留了说话人前缀开销。
    ///
    /// 之所以要预留前缀：碎片是纯文本，落进块里会被渲染成「说话人：碎片」，
    /// 前缀会额外占 token，不预留就会把块悄悄顶过 budget（已踩过这个坑）。
    static func splitOversizedSegment(_ seg: TranscriptSegment, budget: Int) -> [String] {
        let overhead = seg.speaker.count + 2  // 「：」+ 换行分隔符
        let pieceBudget = max(1, budget - overhead)

        let text = seg.text
        var pieces: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if "。！？!?；;\n".contains(char), !current.isEmpty {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }

        var result: [String] = []
        for piece in pieces {
            if estimateTokens(piece) <= pieceBudget {
                result.append(piece)
            } else {
                var i = piece.startIndex
                while i < piece.endIndex {
                    let step = min(pieceBudget, piece.distance(from: i, to: piece.endIndex))
                    let end = piece.index(i, offsetBy: step, limitedBy: piece.endIndex) ?? piece.endIndex
                    result.append(String(piece[i..<end]))
                    i = end
                }
            }
        }
        return result.isEmpty ? [text] : result
    }
}

extension String {
    /// 非空白字符数（token 估算用）。
    fileprivate var unicodeScalapesCount: Int {
        self.unicodeScalars.filter { !$0.properties.isWhitespace }.count
    }
}
