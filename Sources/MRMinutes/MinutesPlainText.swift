import Foundation

/// 纪要的**纯文本**渲染。给「复制纪要」用——粘进聊天窗口、邮件、飞书的那一份。
///
/// ## 为什么不复用 `MinutesService.markdown(...)`
///
/// 那是**落盘**用的：开头带会话 ID、生成时间、分段数，正文里还塞着整篇
/// 「标点修复正文」。用户点「复制」想要的是**能直接发出去的纪要本身**，
/// 把 `2026-10-19-143012-产品评审`、`分段：14 段`、以及三千字原文一起粘进
/// 群聊，是把文件头和原料也倒给了别人。
///
/// 所以这里是**另一份渲染**，只输出摘要 / 议题 / 要点 / 决议 / 待办 / 未决——
/// 也就是界面上那张卡片**看得见的那几项**。卡片与复制件必须同源：
/// 用户看到的和粘出去的若是两套内容，就再也无法判断哪个是这份会议的纪要。
///
/// ## 格式选择
///
/// **不带 Markdown 记号**（`##`、`-`、`**`）。多数聊天工具能认，
/// 但不是全部；而不带记号的纯文本在任何地方都能读。
/// 粘到记事本里也不会看到一堆 `###`。
public enum MinutesPlainText {

    /// 渲染一份纪要，可直接粘走。
    ///
    /// - Parameters:
    ///   - result: 纪要（`minutes.json` 解码而来）
    ///   - title: 会议标题，放在最前面一行——粘进群聊时这一行是唯一的身份标识
    public static func render(_ result: MinutesResult, title: String) -> String {
        var lines: [String] = []
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(heading.isEmpty ? "会议纪要" : "会议纪要：\(heading)")

        // 降级稿必须自己说明白。与界面卡片同一条纪律：
        // 一份「未生成摘要」的稿子被当成真纪要粘出去，比不给更糟。
        if !result.generatedByModel {
            lines.append("")
            lines.append("⚠️ 本地纪要模型当时不可用，以下仅为原始转写稿，未生成摘要。")
        }

        let m = result.minutes

        if !m.summary.isEmpty {
            lines.append("")
            lines.append("【摘要】")
            lines.append(m.summary)
        }

        // 议题在前、要点在后。新纪要里 `keyPoints` 是空的（议题取代了它），
        // 旧纪要里没有议题——两种情况都能读出东西，靠的是同一份 `topics`/`keyPoints` 判据。
        if !m.topics.isEmpty {
            lines.append("")
            lines.append("【议题】")
            for (i, topic) in m.topics.enumerated() {
                lines.append(topicHeading(topic, index: i))
                if !topic.conclusion.isEmpty {
                    lines.append("   \(topicConclusionLabel)\(topic.conclusion)")
                }
                for detail in topic.details {
                    lines.append("   · \(detail)")
                }
            }
        }
        appendList(&lines, title: "【要点】", items: m.keyPoints)
        appendList(&lines, title: "【决议】", items: m.decisions)

        if !m.actionItems.isEmpty {
            lines.append("")
            lines.append("【待办】")
            for item in m.actionItems {
                lines.append("· " + actionItemLine(item))
            }
        }
        appendList(&lines, title: "【未决事项】", items: m.openIssues)

        // 全空（降级稿的常见形态）时给一句明确的话，
        // 不要给一个只有标题的空壳——用户会以为复制坏了。
        if !m.hasContent {
            lines.append("")
            lines.append("（这份纪要没有摘要、议题、决议与待办内容。）")
        }

        // 模型名必须带上。**粘出去的这一份是要脱离本机被别人读到的**，
        // 对方有权知道它来自本地模型、还是某个云端服务。
        //
        // 降级稿写「本地模型」是撒谎——那一栏上面刚说过「模型不可用」，
        // 下面紧跟一句「本地模型」就变成了「跑过了，只是没出摘要」。
        let source: String
        if !result.generatedByModel {
            source = "降级（本地模型不可用，未生成摘要）"
        } else {
            source = result.generatorName.isEmpty ? "本地模型" : result.generatorName
        }
        lines.append("")
        lines.append("（来源：\(source)）")

        return lines.joined(separator: "\n")
    }

    /// 一条待办的单行文本。与界面卡片、落盘 Markdown 用**同一个函数**——
    /// 三处各写一遍的话，「负责人未指定」会漂成三种说法。
    public static func actionItemLine(_ item: ActionItem) -> String {
        let owner = item.owner.isEmpty ? "未指定" : item.owner
        let due = item.due.isEmpty ? "未指定" : item.due
        return "\(item.task)（负责人：\(owner)；截止：\(due)）"
    }

    /// 议题「结论」的标签。三处渲染共用同一措辞——
    /// 各写一遍的话，同一份纪要在卡片里是「结论」、在 markdown 里是「决定」，
    /// 读的人会以为它们指两件事。
    public static let topicConclusionLabel = "结论："

    /// 议题标题的显示文本（含序号）。序号是给「这场会一共谈了哪几件事」一个可数的读法。
    public static func topicHeading(_ topic: MeetingTopic, index: Int) -> String {
        topic.title.isEmpty ? "议题 \(index + 1)" : "\(index + 1). \(topic.title)"
    }

    private static func appendList(_ lines: inout [String], title: String, items: [String]) {
        guard !items.isEmpty else { return }
        lines.append("")
        lines.append(title)
        for item in items { lines.append("· \(item)") }
    }
}