import Foundation

/// 模型输出的「占位词」收敛。
///
/// 模型对「未提及」的表达极不稳定：`无` / `未提及` / `N/A` / `-` / `null` 都会出现。
/// 不收敛的话，纪要待办区会挂着一排「负责人：无」——看着像内容，其实是废话。
/// 本地与云端两个实现共用它，避免同一种占位在一份纪要里被两种方式处理。
enum MinutesNormalizer {

    static func normalizeBlank(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders = [
            "无", "未提及", "未指定", "没有", "无明确", "不详", "待定",
            "n/a", "na", "none", "null", "nil", "-", "—", "–",
            "：", ":", "？", "?",
        ]
        guard !placeholders.contains(v.lowercased()) else { return "" }
        return v
    }

    // MARK: - 结构去噪

    /// 把宽松解析出的议题转成模型，并丢掉**空壳议题**。
    ///
    /// 模型被要求「至少给 1 个议题」时，很容易用「会议整体情况 / 与会人员进行了讨论」
    /// 这种空壳凑数。这类条目的 title 与 conclusion 至少会有一个是空的；
    /// 留着它们，界面上就会出现一个点不开、说不出结论的议题，比没有更糟。
    static func topics(_ raw: [LenientTopic]) -> [MeetingTopic] {
        raw.compactMap { t -> MeetingTopic? in
            let title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let conclusion = t.conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !conclusion.isEmpty else { return nil }
            let details = t.details
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // 只有结论没有标题时，用结论开头兜底——宁可标题粗糙，
            // 也不要让一条真实结论因为「模型没写标题」而消失。
            let safeTitle = title.isEmpty ? String(conclusion.prefix(20)) : title
            return MeetingTopic(title: safeTitle, conclusion: conclusion, details: details)
        }
    }

    /// 把宽松解析出的纠错记录转成模型，并丢掉**没有实际改动的条目**。
    ///
    /// 判据是「改前改后不一样」：模型常把没改的词也列进来凑数（甚至同一个词写两遍），
    /// 那不是勘误，是噪声。大小写与首尾空白不算改动。
    static func corrections(_ raw: [LenientCorrection]) -> [TranscriptCorrection] {
        raw.compactMap { c -> TranscriptCorrection? in
            let original = c.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let corrected = c.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty, !corrected.isEmpty else { return nil }
            guard original.lowercased() != corrected.lowercased() else { return nil }
            return TranscriptCorrection(
                original: original,
                corrected: corrected,
                reason: c.reason.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 合并各块的纠错记录并去重。**保留首次出现的顺序**——
    /// 勘误表是按时间读的，重排会让用户对不上正文。
    ///
    /// 去重键是「原词 + 纠正后」：同一个错词在不同块里被纠正成同一个词，只算一处；
    /// 若同一个原词被纠正成两个不同的词（模型自己前后不一致），两条都保留，
    /// 让人一眼看出这里有问题——静默选一个才是掩盖。
    static func mergeCorrections(_ all: [TranscriptCorrection]) -> [TranscriptCorrection] {
        var seen = Set<String>()
        var out: [TranscriptCorrection] = []
        for c in all {
            let key = "\(c.original)→\(c.corrected)"
            guard !seen.contains(key) else {
                // 已有条目若没写依据，用后出现的补上（依据比顺序重要）
                if let i = out.firstIndex(where: { "\($0.original)→\($0.corrected)" == key }),
                   out[i].reason.isEmpty, !c.reason.isEmpty {
                    out[i].reason = c.reason
                }
                continue
            }
            seen.insert(key)
            out.append(c)
        }
        return out
    }
}

/// 云端模型响应的**宽松解析**。
///
/// 之所以要「宽松」：让模型输出 JSON 是嘱咐，不是保证。真实观测到的形态包括
/// ```json 围栏、前后附带说明文字、字段名写成 snake_case。严格解析会在这些
/// 形态上把一次成功的调用变成失败——而钱已经花了。
///
/// 但有两条不宽松的底线：
/// 1. **取不出 JSON 对象就报错**（`MinutesError.apiCall`），绝不猜；
/// 2. 字段类型不对（如 `keyPoints` 给了字符串）也报错并带上原文片段，
///    而不是静默丢弃——静默丢内容的纪要比报错的纪要危险得多。
enum MinutesResponseParsing {

    /// 从模型输出中取出 JSON 对象文本。容忍围栏与前后缀废话。
    static func extractJSONObject(from text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 剥 ```json / ``` 围栏：第一行是 ```xxx，最后一行是 ```
        if s.hasPrefix("```") {
            let lines = s.components(separatedBy: "\n")
            var body = lines.dropFirst().joined(separator: "\n")
            if let fenceRange = body.range(of: "```", options: .backwards) {
                body.removeSubrange(fenceRange.lowerBound..<body.endIndex)
            }
            s = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let start = s.firstIndex(of: "{"),
              let end = s.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(s[start...end])
    }

    /// 原文片段（截断 + 压掉控制字符），用于错误信息。
    /// 密钥、地址这类敏感信息不在模型回复里，但回复可能很长，全部塞进
    /// 错误信息会刷屏——200 字符足够定位「模型到底回了什么」。
    static func snippet(_ text: String, limit: Int = 200) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: " ")
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}

/// 宽松解码的 map 阶段结果。字段名同时接受 camelCase 与 snake_case——
/// 不把字段名写死，模型就会自由发挥，而解析层不该为此把一次成功的调用判失败。
struct LenientBlockResult: Decodable {
    var polishedText: String
    var summary: String
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [LenientActionItem]
    var corrections: [LenientCorrection]

    private enum CodingKeys: String, CodingKey {
        case polishedText, polished_text
        case summary
        case keyPoints, key_points
        case decisions
        case actionItems, action_items
        case corrections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        polishedText = try c.decodeIfPresent(String.self, forKey: .polishedText)
            ?? c.decodeIfPresent(String.self, forKey: .polished_text) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints)
            ?? c.decodeIfPresent([String].self, forKey: .key_points) ?? []
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try c.decodeIfPresent([LenientActionItem].self, forKey: .actionItems)
            ?? c.decodeIfPresent([LenientActionItem].self, forKey: .action_items) ?? []
        corrections = try c.decodeIfPresent([LenientCorrection].self, forKey: .corrections) ?? []
    }
}

/// 宽松解码的 reduce 阶段结果。
struct LenientMinutesResult: Decodable {
    var summary: String
    var topics: [LenientTopic]
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [LenientActionItem]
    var openIssues: [String]

    private enum CodingKeys: String, CodingKey {
        case summary
        case topics
        case keyPoints, key_points
        case decisions
        case actionItems, action_items
        case openIssues, open_issues
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        topics = try c.decodeIfPresent([LenientTopic].self, forKey: .topics) ?? []
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints)
            ?? c.decodeIfPresent([String].self, forKey: .key_points) ?? []
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try c.decodeIfPresent([LenientActionItem].self, forKey: .actionItems)
            ?? c.decodeIfPresent([LenientActionItem].self, forKey: .action_items) ?? []
        openIssues = try c.decodeIfPresent([String].self, forKey: .openIssues)
            ?? c.decodeIfPresent([String].self, forKey: .open_issues) ?? []
    }
}

/// 宽松解码的议题。字段全部可选、缺省空串——
/// 模型偶尔会漏 `details`，不该因此把整场纪要判成解析失败。
struct LenientTopic: Decodable {
    var title: String
    var conclusion: String
    var details: [String]

    private enum CodingKeys: String, CodingKey {
        case title, conclusion, details
    }

    /// 成员初始化器：生产路径只走 `init(from:)`，这条是给测试与手工构造用的
    /// （直接拼 JSON 造用例会让「测的是什么」淹没在转义字符里）。
    init(title: String, conclusion: String, details: [String] = []) {
        self.title = title
        self.conclusion = conclusion
        self.details = details
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        conclusion = try c.decodeIfPresent(String.self, forKey: .conclusion) ?? ""
        details = try c.decodeIfPresent([String].self, forKey: .details) ?? []
    }
}

/// 宽松解码的纠错记录。
struct LenientCorrection: Decodable {
    var original: String
    var corrected: String
    var reason: String

    private enum CodingKeys: String, CodingKey {
        case original, corrected, reason
    }

    /// 成员初始化器（测试与手工构造用，见 `LenientTopic` 同名字段）。
    init(original: String, corrected: String, reason: String = "") {
        self.original = original
        self.corrected = corrected
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        original = try c.decodeIfPresent(String.self, forKey: .original) ?? ""
        corrected = try c.decodeIfPresent(String.self, forKey: .corrected) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

/// 宽松解码的待办项。三个字段全部可选、缺省空串。
struct LenientActionItem: Decodable {
    var task: String
    var owner: String
    var due: String

    private enum CodingKeys: String, CodingKey {
        case task, owner, due
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        due = try c.decodeIfPresent(String.self, forKey: .due) ?? ""
    }
}
