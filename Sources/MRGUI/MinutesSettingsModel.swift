import Foundation
import Combine
import MRCore
import MRMinutes
import MRSession

/// 会议纪要设置界面的**状态与逻辑**（不含视图）。
///
/// ## 为什么要把它从视图里剥出来
///
/// 这一层要回答的问题都很具体、也都很容易写错：现在配齐了吗？能不能测？
/// 测完的结论对不对当下的输入？改了配置之后旧结论还算不算数？
/// 这些都是**逻辑**，塞进 SwiftUI 视图就只能靠渲染冒烟去验，而渲染冒烟
/// 既看不见文案也点不了按钮。所以规则是：判断放这里，视图只做呈现。
///
/// ## 最要紧的一条不变量
///
/// **改动任一项配置，就作废上一次的测试结论。**
///
/// 上一轮通、这一轮改错了密钥，界面却还挂着绿色的「连接成功」——
/// 用户会带着这个错觉去跑会议，然后在几分钟后拿到 401。
/// 绿色的过期结论比没有结论更危险，所以这里订阅四项偏好，任一变化就清空。
@MainActor
final class MinutesSettingsModel: ObservableObject {

    /// 测试连接的状态。
    enum ProbePhase: Equatable {
        case idle
        case running
        case finished(MinutesAPIProbe.Outcome)
    }

    /// 当前测试连接状态。
    @Published private(set) var probePhase: ProbePhase = .idle

    /// 是否明文显示密钥（默认否）。
    @Published public var revealsKey = false

    /// 设置窗口当前停在哪一页。
    ///
    /// 放在 model 而不是视图的 `@State`：窗口控制器要**按页高重新量窗口**
    /// （三页的字段数差 200 pt 上下），而它只拿得到 model。
    @Published public var tab: SettingsTab = .recording

    /// 刚点了哪个预设——只为显示它的「密钥去哪申请」说明。
    @Published public private(set) var appliedPreset: MinutesServicePreset?

    let workspace: MeetingWorkspace

    /// 探测的注入口。测试注入假实现，**绝不真发网络请求**。
    private let probeRunner: @Sendable (CloudAPIConfiguration) async -> MinutesAPIProbe.Outcome

    private var cancellables: Set<AnyCancellable> = []

    init(
        workspace: MeetingWorkspace,
        probeRunner: @escaping @Sendable (CloudAPIConfiguration) async -> MinutesAPIProbe.Outcome
            = { await MinutesAPIProbe.run(configuration: $0) }
    ) {
        self.workspace = workspace
        self.probeRunner = probeRunner
        observeConfigurationChanges()
    }

    // MARK: - 取值

    /// 界面当前这三项拼出的配置。
    public var configuration: CloudAPIConfiguration {
        CloudAPIConfiguration(
            baseURL: workspace.minutesAPIBaseURL,
            apiKey: workspace.minutesAPIKey,
            model: workspace.minutesModelName)
    }

    public var isProbing: Bool {
        if case .running = probePhase { return true }
        return false
    }

    /// 现在能不能点「测试连接」。缺项或 URL 有毛病时**禁用按钮**：
    /// 让用户填完再说，而不是点一下得到一句「还缺 API Key」。
    public var canProbe: Bool {
        configuration.isComplete && configuration.urlProblem == nil
    }

    /// 状态行（一行，说清现在是什么状态）。
    public var statusLine: String {
        guard workspace.minutesProvider == .cloudAPI else {
            if let reason = workspace.localMinutesUnavailableReason {
                return "⚠️ \(reason)"
            }
            return "本地生成 · 转写稿不出本机 · 零成本"
        }
        let config = configuration
        // **顺序要紧**：先说缺什么，再谈 URL 有毛病。
        // 三项全空时 URL 一定也「拼不出合法地址」，先报那条的话，
        // 用户会看到一句关于空引号的语法错误，而不是「你还没填」。
        let missing = config.missingFields
        if !missing.isEmpty {
            return "⚠️ 还缺 \(missing.joined(separator: "、"))，三项齐了才能生成纪要"
        }
        if let problem = config.urlProblem { return "⚠️ \(problem)" }
        // 密钥那部分用「·」分隔而不是再套一层括号：`maskedMinutesAPIKey`
        // 自带「（已设置）」，套进去就成了「（密钥 sk-…ghij（已设置））」。
        return "已配置 · 生成时转写稿会发往 \(config.hostForDisplay) · 密钥 \(workspace.maskedMinutesAPIKey)"
    }

    /// 状态行是不是警告色。
    public var statusIsWarning: Bool {
        if workspace.minutesProvider == .cloudAPI {
            let config = configuration
            return !config.isComplete || config.urlProblem != nil
        }
        return workspace.localMinutesUnavailableReason != nil
    }

    /// 测试结论（一行）。没测过就 nil，视图不显示这一行。
    public var probeConclusion: String? {
        guard case let .finished(outcome) = probePhase else { return nil }
        return outcome.summary
    }

    /// 测试结论是不是成功色。
    public var probeConclusionIsSuccess: Bool {
        guard case let .finished(outcome) = probePhase else { return false }
        return outcome.isOK
    }

    /// 预设的说明（密钥去哪申请）。
    public var presetNote: String? {
        appliedPreset?.note
    }

    // MARK: - 动作

    /// 应用服务商预设：**只填 Base URL 与模型名，绝不碰密钥**。
    ///
    /// 覆盖用户已填的模型名是有意的——模型名与 Base URL 是配套的，
    /// 留着一个旧服务商的模型名配上新 URL 只会得到一个费解的 404。
    public func apply(preset: MinutesServicePreset) {
        workspace.minutesAPIBaseURL = preset.baseURL
        workspace.minutesModelName = preset.suggestedModel
        appliedPreset = preset
    }

    /// 测一次。**从不抛**：结论无论好坏都进 `probePhase`。
    public func runProbe() {
        guard canProbe, !isProbing else { return }
        probePhase = .running
        let config = configuration
        Task { [weak self] in
            let outcome = await self?.probeRunner(config)
            guard let self, let outcome else { return }
            self.probePhase = .finished(outcome)
        }
    }

    /// 把密钥的明文显示翻回去（下次输入仍以隐藏方式呈现）。
    public func hideKey() {
        revealsKey = false
    }

    // MARK: - 作废过期结论

    /// 任一项配置变化 → 旧结论立即作废。
    ///
    /// 订阅四个 `@Published` 而不是各视图主动调 `invalidate()`：
    /// 前者不会漏——新增一个配置项时，只要它是 `@Published`，这里自动覆盖。
    private func observeConfigurationChanges() {
        // 统一擦成 `Void`：四个发布者的元素类型各不相同（String / MinutesProvider），
        // 而这里只关心「有没有变」，不关心变成了什么。
        let triggers: [AnyPublisher<Void, Never>] = [
            workspace.$minutesAPIBaseURL.map { _ in () }.eraseToAnyPublisher(),
            workspace.$minutesAPIKey.map { _ in () }.eraseToAnyPublisher(),
            workspace.$minutesModelName.map { _ in () }.eraseToAnyPublisher(),
            workspace.$minutesProvider.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .sink { [weak self] in
                guard let self else { return }
                // 只在「有结论」时清，避免每次按键都触发无谓的界面刷新。
                if case .finished = self.probePhase { self.probePhase = .idle }
            }
            .store(in: &cancellables)
    }
}