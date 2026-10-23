import Foundation

/// 会议纪要生成器的协议。
///
/// 抽象成协议有三个目的，都是项目里反复强调的纪律：
/// 1. **可测**：单测用 `FakeMinutesGenerator`，绝不在测试里真调模型；
/// 2. **可降级**：本地模型不可用时换一个实现（见 `MinutesOrchestrator` 的降级分支）；
/// 3. **可替换**：云端模型（DeepSeek/GLM/Kimi，OpenAI 兼容协议）是
///    `CloudAPIMinutesGenerator`——隐私决策点：默认本地、用户显式配置并开启，
///    绝不偷偷把录音传出去。
///
/// 两步式接口对应 map-reduce：
/// - `summarize(block:)` 是 **map**：每一块独立产出局部摘要；
/// - `merge(summaries:)` 是 **reduce**：把若干局部摘要合成全局纪要。
///
/// 之所以分两步而不是「一次吃全文」：本地模型上下文只有 4096 token，
/// 长会议全文塞不进去。分块 map 之后再 reduce，reduce 的输入是已被压过的
/// 局部摘要，体积小得多。（云端模型上下文大得多，但两段式对同样成立——
/// 分块还顺带控制单次请求体量，`TranscriptChunker` 因此保持共用。）
public protocol MinutesGenerator: Sendable {

    /// 模型是否真正可用。调用方据此决定走真模型还是降级。
    ///
    /// 注意这是**运行时**可用性（模型资产/配置是否就绪），不是「代码里有没有这个实现」。
    var isAvailable: Bool { get }

    /// 给人看的模型名，写进纪要文件头部的「模型：」一行。
    ///
    /// 这一行是**溯源信息**：同一份转写稿过三个月回看，必须能分清
    /// 「这是本地模型写的」还是「这是花了钱、发了外网的云端模型写的」。
    /// 默认空串由 `MinutesOrchestrator` 兜底成「本地模型」。
    var displayName: String { get }

    /// `isAvailable == false` 的原因。nil 表示用 orchestrator 的通用文案。
    ///
    /// 存在的理由是**可操作性**：云端三件套没配齐时，通用文案只会说
    /// 「模型不可用」，而用户真正需要的是「缺 Base URL，敲这条命令补上」。
    var unavailableReason: String? { get }

    /// map 阶段：单块 → 局部摘要（含该块标点修复后的正文）。
    func summarize(block: TranscriptBlock) async throws -> BlockSummary

    /// reduce 阶段：多块局部摘要 → 全局纪要。
    func merge(summaries: [BlockSummary]) async throws -> MeetingMinutes
}

public extension MinutesGenerator {
    var displayName: String { "" }
    var unavailableReason: String? { nil }
}

/// 纪要层专属错误。与 `MRError` 并存——它描述的是「这一层」的失败，
/// 不混入采集/转写那套语义。
///
/// 同时实现 `CustomStringConvertible` 与 `LocalizedError`，理由与 `MRError`
/// 同源：CLI 的顶层 catch 打的是 `"❌ \(error)"`，只实现 `LocalizedError` 的话
/// 这里会退化成 `apiCall(reason: "…")` 这种枚举壳——真实原因被包在
/// Swift 的 case 语法里，用户读到的第一屏是噪音。
public enum MinutesError: LocalizedError, Equatable, Sendable, CustomStringConvertible {
    /// 模型不可用，且调用方选择显式抛错（而非走降级）。
    case modelUnavailable(reason: String)
    /// 没有任何可处理的转写内容。
    case emptyTranscript
    /// 云端 API 调用失败（网络 / 鉴权 / 限流 / 响应不是约定的 JSON）。
    ///
    /// **与 `modelUnavailable` 刻意分开**：`modelUnavailable` 走降级
    /// （写一份「仅原稿」的诚实纪要），而这一条**必须上抛、不写文件**——
    /// 用户显式选了云端并花了钱，一次 401 或超时如果被降级稿悄悄接住，
    /// 看到的会是「这场没有摘要」，一次网络故障就这样伪装成模型判断。
    case apiCall(reason: String)

    public var errorDescription: String? { description }

    /// 与 `errorDescription` **刻意同源**——两份文案分头维护的话，
    /// 迟早有一处加了上下文另一处没加，而踩到的那一处通常正是唯一可见的那处。
    public var description: String {
        switch self {
        case let .modelUnavailable(reason):
            return "纪要模型不可用：\(reason)"
        case .emptyTranscript:
            // 「全部段落被人工清空」也会走到这里，所以不能说成「稿子没有转写」——
            // 那会让用户去重新转写，而重新转写会把他的修改一起冲掉。
            return "转写稿没有可用的内容（可能是空稿，也可能所有段落都被人工清空），无法生成纪要"
        case let .apiCall(reason):
            return "纪要 API 调用失败：\(reason)"
        }
    }
}

/// 永远不可用的兜底生成器。
///
/// 用于运行在不支持 FoundationModels 的部署目标上（`FoundationModelsMinutesGenerator`
/// 标了 `@available(macOS 26, *)`）。它的 `isAvailable` 恒为 false，orchestrator 会据此
/// 直接走降级；`summarize`/`merge` 不会被调用（若被调用也抛错）。
public struct UnavailableMinutesGenerator: MinutesGenerator {
    public var isAvailable: Bool { false }
    public var displayName: String { "不可用" }

    public init() {}

    public func summarize(block: TranscriptBlock) async throws -> BlockSummary {
        throw MinutesError.modelUnavailable(reason: "当前部署目标不支持本地模型")
    }

    public func merge(summaries: [BlockSummary]) async throws -> MeetingMinutes {
        throw MinutesError.modelUnavailable(reason: "当前部署目标不支持本地模型")
    }
}
