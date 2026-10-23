import AppKit
import MRMinutes
import MRSession

/// 会议纪要卡片的**富文本**渲染。
///
/// ## 为什么它不是一摞 SwiftUI `Text`
///
/// 卡片原来由十几个 `Text` 叠出来，每个都是独立的选择层——
/// 用户从「摘要」往「议题」拖，选区在边界上**当场断掉**，
/// 复制出来永远只有一行（2026-10-22 报的第 2 条）。
///
/// 现在整张卡片是**一段** `NSAttributedString`，交给 `SelectableRichText`
/// 渲染成一个 `NSTextView`：跨越十几个段落也是一条连续选区，
/// 拖一半、⌘A 全选、右键复制全部原生可用。
///
/// ## 纪律：措辞不许在这里重写
///
/// 议题标题、结论标签、待办行、模型来源四处的措辞分别来自
/// `MinutesPlainText` 与 `MinutesService.modelDescription`——
/// 卡片、复制件、`minutes.md` 三处必须同源。这里只决定**怎么排版**，
/// 不决定**怎么写**。
enum MinutesCardText {

    // MARK: - 字号（与原先的 SwiftUI 语义字号对齐）

    private enum Font {
        static let body = NSFont.systemFont(ofSize: 13)
        static let callout = NSFont.systemFont(ofSize: 12)
        static let calloutMedium = NSFont.systemFont(ofSize: 12, weight: .medium)
        static let caption = NSFont.systemFont(ofSize: 11)
        static let captionSemibold = NSFont.systemFont(ofSize: 11, weight: .semibold)
        static let caption2 = NSFont.systemFont(ofSize: 10)
    }

    // MARK: - 渲染

    /// 渲染整张卡片。
    ///
    /// - Parameters:
    ///   - result: 纪要
    ///   - transcriptChanged: 稿子在纪要生成之后改过（要出橙色提示）
    ///   - showsCorrections: 勘误表是否展开。**展开时勘误也进同一段文本**，
    ///     否则它就成了一块「又只能选一行」的孤岛。
    static func render(_ result: MinutesResult,
                       transcriptChanged: Bool,
                       showsCorrections: Bool) -> NSAttributedString {
        var lines: [Line] = []

        // 稿子在纪要生成之后被改过。这条**不报就没人知道**：
        // 卡片里每个字看起来都还是对的，只是它对应的原文已经不在了。
        if transcriptChanged {
            lines.append(Line(
                "⚠️ 转写稿在这份纪要生成之后改过，下面的内容基于旧稿——"
                + "建议点右上「重新生成纪要」。",
                font: Font.caption, color: .systemOrange))
        }

        // 降级稿必须自己说明白。把「未生成摘要」和真摘要摆在一起却不标注，
        // 是让用户把两份不同性质的东西当同一种读。
        if !result.generatedByModel {
            lines.append(Line(
                "⚠️ 本地纪要模型当时不可用，以下是原始转写稿，未生成摘要。",
                font: Font.caption, color: .systemOrange))
        }

        let m = result.minutes

        if !m.summary.isEmpty {
            lines.append(Line(m.summary, font: Font.body, spacingBefore: 10))
        }

        if !m.topics.isEmpty {
            lines.append(sectionLabel("议题"))
            for (index, topic) in m.topics.enumerated() {
                lines.append(Line(
                    MinutesPlainText.topicHeading(topic, index: index),
                    font: Font.calloutMedium, spacingBefore: 6))
                if !topic.conclusion.isEmpty {
                    // 「结论：」与复制件、minutes.md 共用同一措辞。
                    lines.append(Line(
                        "\(MinutesPlainText.topicConclusionLabel)\(topic.conclusion)",
                        font: Font.callout, spacingBefore: 2))
                }
                for detail in topic.details {
                    lines.append(Line("· \(detail)", font: Font.caption,
                                      color: .secondaryLabelColor,
                                      spacingBefore: 2, headIndent: 12))
                }
            }
        }

        // 旧纪要没有议题、只有要点——两种都能读出来，不因升级丢内容。
        appendList(&lines, title: "要点", items: m.keyPoints)
        appendList(&lines, title: "决议", items: m.decisions)

        if !m.actionItems.isEmpty {
            lines.append(sectionLabel("待办"))
            for item in m.actionItems {
                // 与「复制」和落盘 Markdown 共用同一份渲染，
                // 三处不该各写一遍「负责人：未指定」。
                lines.append(Line("· \(MinutesPlainText.actionItemLine(item))",
                                  font: Font.callout, spacingBefore: 2, headIndent: 12))
            }
        }

        if !m.openIssues.isEmpty {
            lines.append(sectionLabel("未决事项"))
            for issue in m.openIssues {
                lines.append(Line("· \(issue)", font: Font.callout,
                                  color: .secondaryLabelColor,
                                  spacingBefore: 2, headIndent: 12))
            }
        }

        // 勘误表：让「纪要里的术语」与「转写稿里的错字」能对上。
        // 默认收起（它是对照用的，不是纪要正文），但必须可见——
        // 否则模型改了哪些词就完全是个黑盒。
        if !result.corrections.isEmpty, showsCorrections {
            lines.append(Line("已纠正 \(result.corrections.count) 处语音识别错误",
                              font: Font.caption, color: .tertiaryLabelColor,
                              spacingBefore: 10))
            for correction in result.corrections {
                let reason = correction.reason.isEmpty ? "" : "（\(correction.reason)）"
                lines.append(Line(
                    "\(correction.original) → \(correction.corrected)\(reason)",
                    font: Font.caption, color: .secondaryLabelColor,
                    spacingBefore: 2, headIndent: 12))
            }
        }

        // 模型名必须显示——「这一份是谁生成的」是纪要的溯源信息，
        // 尤其云端那一份：它花了钱、并且稿子离开过本机。
        // **降级稿不能写「本地模型」**，与落盘 Markdown 共用同一份判据。
        lines.append(Line("模型：\(MinutesService.modelDescription(result))",
                          font: Font.caption2, color: .tertiaryLabelColor,
                          spacingBefore: 10))

        return compose(lines)
    }

    /// 「议题」「决议」这类小标题。与正文之间留一点空，读起来才是分节。
    private static func sectionLabel(_ text: String) -> Line {
        Line(text, font: Font.captionSemibold, color: .tertiaryLabelColor, spacingBefore: 10)
    }

    private static func appendList(_ lines: inout [Line], title: String, items: [String]) {
        guard !items.isEmpty else { return }
        lines.append(sectionLabel(title))
        for item in items {
            lines.append(Line("· \(item)", font: Font.callout, spacingBefore: 2, headIndent: 12))
        }
    }

    // MARK: - 段落拼装

    private struct Line {
        var text: String
        var font: NSFont
        var color: NSColor = .labelColor
        /// 与上一段之间的空档（像素）。卡片原来用 VStack 的 spacing 做出这个层次。
        var spacingBefore: CGFloat = 0
        var headIndent: CGFloat = 0

        init(_ text: String, font: NSFont, color: NSColor = .labelColor,
             spacingBefore: CGFloat = 0, headIndent: CGFloat = 0) {
            self.text = text
            self.font = font
            self.color = color
            self.spacingBefore = spacingBefore
            self.headIndent = headIndent
        }
    }

    /// 每行一个段落，行尾换行；空档用 `paragraphSpacingBefore` 表达。
    ///
    /// **不能用空行表达空档**：空行在复制出去之后是一串多余的换行，
    /// 而粘进聊天窗口的人看到的是一大坨空白。
    private static func compose(_ lines: [Line]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = line.spacingBefore
            paragraph.lineSpacing = 2
            // 换行后缩进（`headIndent`），首行不缩进：条目折行时对齐在「·」后面，
            // 而不是顶回最左边、和上一条混在一起。
            paragraph.headIndent = line.headIndent
            // 只允许在行尾断行——中文长句里被强行断开的「议」/「题」很难读。
            paragraph.lineBreakMode = .byWordWrapping

            let piece = NSAttributedString(string: line.text, attributes: [
                .font: line.font,
                .foregroundColor: line.color,
                .paragraphStyle: paragraph,
            ])
            result.append(piece)
            // 最后一行不留换行：留着的话文本视图底部会多出一个空段落的高度。
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }
}
