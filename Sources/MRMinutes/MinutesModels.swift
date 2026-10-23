import Foundation

/// 会议纪要层的数据模型。
///
/// 这一层是**加在转写稿之后的一层 LLM**，与前面用哪个 ASR 引擎完全解耦——
/// 它只吃 `TranscriptDocument`，不关心里面是苹果还是 SenseVoice 产的字。
///
/// 全部是普通 `Sendable` 值类型，**不依赖 FoundationModels 框架**：
/// `@Generable` 的系统宏只能出现在引入该框架的编译单元里，所以真正的模型
/// 映射放在 `FoundationModelsMinutesGenerator` 一侧，这里只定义干净的纯数据。
public struct ActionItem: Codable, Equatable, Sendable {
    /// 任务内容
    public var task: String
    /// 负责人；模型判断未提及时为空字符串（**不瞎编**）
    public var owner: String
    /// 截止时间；未提及时为空字符串
    public var due: String

    public init(task: String, owner: String = "", due: String = "") {
        self.task = task
        self.owner = owner
        self.due = due
    }
}

/// 一处**语音识别错误的纠正记录**。
///
/// 为什么纪要约得起这个麻烦：转写稿里「支付网关」被听成「支付光关」、
/// 「灰度」被听成「回度」是常态。模型若只在正文里悄悄改掉，用户没法核对
/// 它改得对不对；若完全不改，纪要里就会留下一堆莫名其妙的内容。
/// 所以两条一起做：**正文按纠正后的写**，同时把每一处改动摊开给人看。
///
/// `reason` 不是装饰：它是「凭什么这么改」的依据（后文出现过正确写法 /
/// 同场会议重复出现 / 行业术语），没有依据就不该出现在这里。
public struct TranscriptCorrection: Codable, Equatable, Sendable {
    /// 转写稿里的原词（错的那一个）
    public var original: String
    /// 纠正后的词
    public var corrected: String
    /// 一句话依据
    public var reason: String

    public init(original: String, corrected: String, reason: String = "") {
        self.original = original
        self.corrected = corrected
        self.reason = reason
    }
}

/// 一个**议题**的纪要：这场会就某件事谈了什么、最后定了什么。
///
/// 这是「总结」与「罗列」的分界线。一个字符串数组（原来的 `keyPoints`）
/// 无论怎么嘱咐模型「写结论」，出来的仍然是一排并列的句子——
/// 结构本身没有「议题 → 结论」的关系，模型只能平铺。
public struct MeetingTopic: Codable, Equatable, Sendable {
    /// 议题名（名词短语，如「Q4 排期」「支付模块上线风险」）
    public var title: String
    /// 该议题的结论：定了什么 / 分歧在哪 / 暂无结论
    public var conclusion: String
    /// 支撑结论的关键事实、数据与分歧点（0-3 条，**不写谁说了什么**）
    public var details: [String]

    public init(title: String, conclusion: String, details: [String] = []) {
        self.title = title
        self.conclusion = conclusion
        self.details = details
    }
}

/// 全局纪要（reduce 阶段的最终产物）。
public struct MeetingMinutes: Codable, Equatable, Sendable {
    /// **核心摘要**：这场会是什么会、谈成了什么、下一步是什么（2-5 句）
    ///
    /// 以前这里是「一句话摘要」，一句话装不下「谈成了什么」，
    /// 模型只能写「本次会议讨论了排期问题」这种等于没说的句子。
    public var summary: String
    /// 按重要性排序的议题
    public var topics: [MeetingTopic]
    /// 按重要性排序的讨论要点（**旧字段**）
    ///
    /// 新纪要改用 `topics`：`[String]` 这种平铺结构天然只能罗列。
    /// 保留它是因为**旧 minutes.json 里只有这个字段**，删掉会让历史纪要
    /// 打开后一片空白——那不是升级，是丢数据。新生成时它为空。
    public var keyPoints: [String]
    /// 明确达成的决议或结论
    public var decisions: [String]
    /// 待办事项
    public var actionItems: [ActionItem]
    /// 未决事项与风险：讨论了但没有结论、或者需要上级/外部决定的事
    ///
    /// **必须与决议分开**：把「还没定」混进「决议」是纪要最危险的一种失真，
    /// 读者会按已定的事项去执行。
    public var openIssues: [String]

    public init(
        summary: String,
        topics: [MeetingTopic] = [],
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        openIssues: [String] = []
    ) {
        self.summary = summary
        self.topics = topics
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openIssues = openIssues
    }

    /// 手写解码：`topics` / `openIssues` 都是后加的键，旧 minutes.json 没有。
    /// 合成 Decodable 不支持默认值——不写这段，读任何一份旧纪要都会
    /// `keyNotFound` 崩溃。项目里已因同类问题踩过坑（见 `MinutesResult` 的注释）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary)
        topics = try c.decodeIfPresent([MeetingTopic].self, forKey: .topics) ?? []
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        openIssues = try c.decodeIfPresent([String].self, forKey: .openIssues) ?? []
    }

    /// 界面上「有没有实质内容」的唯一判据。
    ///
    /// 三处渲染（卡片、复制件、minutes.md）都要判断这件事，
    /// 各写一遍的话，新增一种内容时必然漏掉一处，那一处就会显示成空稿。
    public var hasContent: Bool {
        !summary.isEmpty || !topics.isEmpty || !keyPoints.isEmpty
            || !decisions.isEmpty || !actionItems.isEmpty || !openIssues.isEmpty
    }
}

/// 单块（map 阶段）的局部产出。
///
/// 每个分块先独立交给模型，产出「这块的标点修复正文 + 局部摘要 + 局部要点」。
/// 之所以在块级别就做标点修复，是为了让长会议不必把整篇无标点原文塞进
/// 4096 token 的上下文——分而治之。
public struct BlockSummary: Codable, Equatable, Sendable {
    /// 块的序号（从 1 开始，便于回溯）
    public var index: Int
    /// 标点修复后的该块正文（纯可读文本）
    public var polishedText: String
    /// 该块局部摘要
    public var summary: String
    /// 该块局部要点
    public var keyPoints: [String]
    /// 该块局部决议
    public var decisions: [String]
    /// 该块局部待办
    public var actionItems: [ActionItem]
    /// 该块纠正过的语音识别错误（正文里已按 `corrected` 写入）
    public var corrections: [TranscriptCorrection]

    public init(
        index: Int,
        polishedText: String,
        summary: String,
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        corrections: [TranscriptCorrection] = []
    ) {
        self.index = index
        self.polishedText = polishedText
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.corrections = corrections
    }

    /// `corrections` 是后加的键，旧 minutes.json 的分块摘要里没有它。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        polishedText = try c.decodeIfPresent(String.self, forKey: .polishedText) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        corrections = try c.decodeIfPresent([TranscriptCorrection].self, forKey: .corrections) ?? []
    }
}

/// 一个待处理的转写块。保留时间信息与说话人，便于纪要在必要时引用出处。
public struct TranscriptBlock: Codable, Equatable, Sendable {
    public var index: Int
    /// 该块覆盖的会话时间范围（秒）
    public var start: Double
    public var end: Double
    /// 合并后的可读文本（保留说话人标签，便于模型区分谁在说）
    public var text: String

    public init(index: Int, start: Double, end: Double, text: String) {
        self.index = index
        self.start = start
        self.end = end
        self.text = text
    }
}

/// 纪要层的最终产出，连同落盘所需的一切。
public struct MinutesResult: Codable, Equatable, Sendable {
    public var blocks: [TranscriptBlock]
    public var blockSummaries: [BlockSummary]
    public var minutes: MeetingMinutes
    /// 标点修复 + 按块拼接后的完整可读正文（仅在模型可用时产出）
    public var polishedTranscript: String
    /// 模型是否实际参与。false 表示走的降级路径，polishedTranscript 等于原稿。
    public var generatedByModel: Bool
    /// 生成器的显示名（「本地 FoundationModels」/「云端 API（xxx @ host）」）。
    ///
    /// 这是**溯源字段**：三个月后回看一份纪要，必须能分清它是本地产出
    /// 还是花了钱、发了外网的云端产出。降级稿为空串。
    public var generatorName: String
    /// 整场会议纠正过的语音识别错误（各块合并去重，按出现顺序）
    ///
    /// 放在 `MinutesResult` 而不是 `MeetingMinutes` 里：它是**转写稿的勘误表**，
    /// 不是纪要内容。复制给别人的纪要里不该出现它。
    public var corrections: [TranscriptCorrection]

    public init(
        blocks: [TranscriptBlock],
        blockSummaries: [BlockSummary],
        minutes: MeetingMinutes,
        polishedTranscript: String,
        generatedByModel: Bool,
        generatorName: String = "",
        corrections: [TranscriptCorrection] = []
    ) {
        self.blocks = blocks
        self.blockSummaries = blockSummaries
        self.minutes = minutes
        self.polishedTranscript = polishedTranscript
        self.generatedByModel = generatedByModel
        self.generatorName = generatorName
        self.corrections = corrections
    }

    /// 自定义解码：`generatorName` 是后加的字段，**旧 minutes.json 没有这个键**。
    /// 合成 Decodable 不支持默认值，不手写这段的话，读任何一份旧文件都会
    /// `keyNotFound` 崩溃——而项目里已经踩过一次同型的坑
    /// （transcript.json 的日期解码策略与写入方不一致）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocks = try c.decode([TranscriptBlock].self, forKey: .blocks)
        blockSummaries = try c.decode([BlockSummary].self, forKey: .blockSummaries)
        minutes = try c.decode(MeetingMinutes.self, forKey: .minutes)
        polishedTranscript = try c.decode(String.self, forKey: .polishedTranscript)
        generatedByModel = try c.decode(Bool.self, forKey: .generatedByModel)
        generatorName = try c.decodeIfPresent(String.self, forKey: .generatorName) ?? ""
        corrections = try c.decodeIfPresent([TranscriptCorrection].self, forKey: .corrections) ?? []
    }
}
