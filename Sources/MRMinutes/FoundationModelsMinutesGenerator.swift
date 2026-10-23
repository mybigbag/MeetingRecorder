import Foundation
import FoundationModels
import MRCore

/// 基于 macOS 26 本地 FoundationModels 的纪要生成器。
///
/// **这是本项目接入 LLM 的首选路径**，理由三条全是硬约束而非偏好：
/// - **隐私零风险**：模型在设备本地运行，转写稿不经过任何网络、不上传任何服务器；
/// - **成本为零**：系统内置，不调用任何计费 API；
/// - **离线可用**：无网也能跑。
///
/// 唯一的硬约束是**本地模型上下文只有 4096 token**，所以 `MinutesOrchestrator`
/// 必须先分块（每块 map → 再 reduce 合并），本类只负责单块 map 与合并 reduce 这两步。
///
/// 可用性在运行时由 `isAvailable` 判定（系统模型的 `availability` 是否为 `.available`）。
/// 苹果未开启 Apple Intelligence、或设备不在支持列表时，`isAvailable` 返回 false，
/// orchestrator 据此抛 `MinutesError.modelUnavailable`，由调用方接住走降级文案——
/// **绝不假装生成**。
///
/// 注意：本类故意不持有 `LanguageModelSession` 实例。`LanguageModelSession` 在 Swift 6 下
/// 不是 `Sendable`，而 `MinutesGenerator` 协议要求 `Sendable`（orchestrator 要在并发上下文
/// 持有它）。所以每次调用在方法内部新建一个 session 句柄——模型资产是系统级共享的，
/// 新建句柄不会重新下载模型，开销可接受。
@available(macOS 26, *)
public final class FoundationModelsMinutesGenerator: MinutesGenerator {

    public init() {}

    public var isAvailable: Bool {
        // 系统模型是否就绪。未开启 Apple Intelligence 或设备不支持时为 `.unavailable`。
        SystemLanguageModel.default.availability == .available
    }

    /// 溯源名：写进纪要头部的「模型：」一行。
    public var displayName: String { "本地 FoundationModels" }

    /// 不可用时的人话原因。
    ///
    /// **这段以前是 nil**：协议给了默认实现，而这里没写，于是用户在设置界面
    /// 选「本地」、生成后只看到「未生成摘要」，从头到尾没有任何一处说明
    /// 「这台机器根本跑不了」——看起来就像功能坏了。
    ///
    /// 而「本机不支持」和「没开 Apple Intelligence」是两件不同的事：
    /// 后者只要去系统设置里打开就行，说清楚能省掉一次「是不是软件有 bug」的怀疑。
    public var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case let .unavailable(reason):
            return Self.describe(reason)
        @unknown default:
            return "系统没有报告具体原因（系统设置 → 通用 → 存储空间，或更新一下系统）"
        }
    }

    /// 把系统的不可用原因翻成人能行动的话。
    ///
    /// **一句说完，且带上下一步**：这段会原样出现在设置界面的模型层卡片上，
    /// 太长会被折成三行、把「转写稿不出本机」这条卖点挤到视线之外；
    /// 而只说「不支持」不说怎么办，用户只能干瞪眼。
    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "这台 Mac 的机型不在 Apple Intelligence 支持列表里，本地纪要跑不了；可改用云端模型 API"
        case .appleIntelligenceNotEnabled:
            return "系统设置 → Apple Intelligence 与 Siri 还没打开，打开后本地纪要即可用"
        case .modelNotReady:
            return "系统模型还在准备中，稍后再试即可；也可以先用云端模型 API"
        @unknown default:
            return "系统没有报告具体原因，稍后再试或改用云端模型 API"
        }
    }

    // MARK: - 镜像结构（@Generable 只能定义在引入 FoundationModels 的编译单元里）

    @Generable
    struct FMActionItem {
        @Guide(description: "任务内容") var task: String
        @Guide(description: "负责人；若发言中未提及则为空字符串，不要编造")
        var owner: String
        @Guide(description: "截止时间；若未提及则为空字符串，不要编造")
        var due: String
    }

    @Generable
    struct FMCorrection {
        @Guide(description: "转写稿里的原词（错的那一个）")
        var original: String
        @Guide(description: "纠正后的词，正文里必须用这个写法")
        var corrected: String
        @Guide(description: "一句话依据：后文出现正确写法 / 同场重复出现 / 上下文唯一吻合的术语")
        var reason: String
    }

    /// map 阶段单块产出：标点修复正文 + 局部摘要/要点/决议/待办 + 纠错记录。
    @Generable
    struct FMBlockResult {
        @Guide(description: "为该块纠错、补全标点、按语义断句分段，输出可读正文。"
               + "只改识别错的词，不增删句子、不改数字与结论；数字与专名用纠正后的写法。")
        var polishedText: String
        @Guide(description: "该块的一句话中文摘要，说明这段在谈什么，不是复述内容")
        var summary: String
        @Guide(description: "该块关键信息，每条一句结论或事实并带具体数字与对象，最多 5 条")
        var keyPoints: [String]
        @Guide(description: "该块里已经明确的决议；提议、设想、待确认的不算")
        var decisions: [String]
        @Guide(description: "该块产生的待办事项")
        var actionItems: [FMActionItem]
        @Guide(description: "该块纠正过的语音识别错误；没有纠正就给空数组")
        var corrections: [FMCorrection]
    }

    /// reduce 阶段的一个议题。
    @Generable
    struct FMTopic {
        @Guide(description: "议题名，名词短语，指向一件事（如「Q4 排期」）")
        var title: String
        @Guide(description: "一句话结论：定了什么；没定就写「未定：分歧在 X」。不要写讨论过程")
        var conclusion: String
        @Guide(description: "0-3 条支撑结论的事实、数据、分歧点；没有具体内容给空数组")
        var details: [String]
    }

    /// reduce 阶段：多块局部摘要 → 全局纪要。
    @Generable
    struct FMMinutes {
        @Guide(description: "2-5 句核心摘要：什么会、得出了什么结论、下一步是什么；"
               + "不要用「围绕……展开讨论」这类没有信息的开头")
        var summary: String
        @Guide(description: "按重要性排序的议题，2-6 个；同一件事的发言合并成一个议题")
        var topics: [FMTopic]
        @Guide(description: "明确拍板的决定，每条可独立执行；提议与待确认的不算")
        var decisions: [String]
        @Guide(description: "全局待办事项，合并各段相同的项")
        var actionItems: [FMActionItem]
        @Guide(description: "未决事项与风险：讨论过但没定、或要等外部决定的事；没有给空数组")
        var openIssues: [String]
    }

    // MARK: - map

    public func summarize(block: TranscriptBlock) async throws -> BlockSummary {
        let session = LanguageModelSession()
        // 提示词取自 `MinutesPrompts`——与云端实现同源。两边各写一份的话，
        // 「绝不编造」「未提及填空」这类关键约束迟早只在一半里有效。
        let prompt = MinutesPrompts.blockPrompt(text: block.text)
        let reply = try await session.respond(to: prompt, generating: FMBlockResult.self)
        let c = reply.content
        return BlockSummary(
            index: block.index,
            polishedText: c.polishedText.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: c.summary,
            keyPoints: c.keyPoints,
            decisions: c.decisions,
            actionItems: c.actionItems.map {
                ActionItem(task: $0.task, owner: MinutesNormalizer.normalizeBlank($0.owner), due: MinutesNormalizer.normalizeBlank($0.due))
            },
            corrections: c.corrections.compactMap { item in
                let original = item.original.trimmingCharacters(in: .whitespacesAndNewlines)
                let corrected = item.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
                // 与云端走同一套去噪判据：改前改后一样就不是纠正。
                guard !original.isEmpty, !corrected.isEmpty,
                      original.lowercased() != corrected.lowercased() else { return nil }
                return TranscriptCorrection(
                    original: original,
                    corrected: corrected,
                    reason: item.reason.trimmingCharacters(in: .whitespacesAndNewlines))
            })
    }

    // MARK: - reduce

    public func merge(summaries: [BlockSummary]) async throws -> MeetingMinutes {
        let session = LanguageModelSession()
        // 渲染与云端实现同源（`MinutesPrompts.renderSummaries`）。
        let joined = MinutesPrompts.renderSummaries(summaries)

        let prompt = MinutesPrompts.mergePrompt(joinedSummaries: joined)
        let reply = try await session.respond(to: prompt, generating: FMMinutes.self)
        let c = reply.content
        return MeetingMinutes(
            summary: c.summary,
            topics: c.topics.compactMap { t in
                let title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let conclusion = t.conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty || !conclusion.isEmpty else { return nil }
                return MeetingTopic(
                    title: title.isEmpty ? String(conclusion.prefix(20)) : title,
                    conclusion: conclusion,
                    details: t.details
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty })
            },
            decisions: c.decisions,
            actionItems: c.actionItems.map {
                ActionItem(task: $0.task, owner: MinutesNormalizer.normalizeBlank($0.owner), due: MinutesNormalizer.normalizeBlank($0.due))
            },
            openIssues: c.openIssues)
    }
}
