import Foundation
import Combine
import AppKit
import MRCore
import MRCapture
import MRMinutes

/// 界面状态中枢。GUI 与「未来的其它前端」共用，且**不依赖任何 UI 框架**，
/// 所以在无头环境里也能完整单元测试。
///
/// 这里只放「界面需要知道什么」，不放「怎么画」。
/// 每个状态变化都对应磁盘上一次真实的操作，方便出问题时对照。
@MainActor
public final class MeetingWorkspace: ObservableObject {

    /// 转写进度状态。分段转写可能跑很久，界面必须能显示在第几段。
    public enum TranscriptPhase: Equatable {
        case idle
        case running(summary: String)
        case done(segmentCount: Int)
        case failed(String)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        /// `.running` 里的进度文字；其它相位为 nil。
        ///
        /// 存在的理由是测试要能断言「进度文字也没丢」——切走再切回时，
        /// 光有 `isRunning == true` 不足以证明状态完整：一个被重置过的
        /// 相位也可以是 `.running("")`，而用户看到的是空白进度条。
        public var summaryIfRunning: String? {
            if case .running(let summary) = self { return summary }
            return nil
        }
    }

    /// 当前选中的会议列表
    @Published public private(set) var meetings: [MeetingSummary] = []
    /// 会议根目录是否读得到。**不能只看列表是否为空**——见 `SessionLibrary.Access`。
    @Published public private(set) var access: SessionLibrary.Access = .ok
    /// 是否已经完成过一次扫描。
    ///
    /// 这个状态是必须的：刚启动时 `meetings` 也是空的，但那时我们**还什么都不知道**。
    /// 少了它，界面就会在首次布局的一瞬间宣称「还没有会议记录」——
    /// 而实际上连目录都还没打开过。这是**用「没数据」冒充「没查」**，
    /// 用户会以为录音丢了。
    @Published public private(set) var hasScanned: Bool = false
    /// 是否有一次扫描正在进行
    @Published public private(set) var isScanning: Bool = false
    /// 当前选中的会议。可写，方便界面直接做 `List` 的选择绑定；
    /// 详情加载集中在 `didSet` 里，避免「有的地方设了 ID 但忘了加载详情」。
    @Published public var selectedID: String? {
        didSet {
            guard oldValue != selectedID else { return }
            // 切走时**立刻**清空，而不是等新数据回来再覆盖。
            // 不清的话，在新标题下会短暂显示上一场的波形——比空白更难发现。
            waveforms = [:]
            // ⚠️ **这里刻意不清 `transcriptPhases`。**
            //
            // 转写是一个**按会议**的长时间任务：A 场转写要跑几十秒，
            // 用户完全可以中途切到 B、再切回 A。清掉相位等于宣布
            // 「A 没在转写了」，于是切回来时界面显示「开始转写」按钮——
            // 而它其实还在后台跑（2026-10-16 报的正是这个）。
            //
            // 更糟的是 `runTranscription` 的 `guard !isRunning` 读的是
            // 被清掉后的值，于是用户再点一次会**对同一场并发发起第二次转写**。
            //
            // 相位按 sessionID 存（见 `transcriptPhases`），换会议时
            // 界面自然读到新会议那一份，不存在「上一场的状态串到下一场」。
            lastError = nil
            guard let id = selectedID else {
manifest = nil
            transcript = nil
            minutesResult = nil
            availableTrackIDs = []
            transcriptChangedAfterMinutes = false
            return
            }
            Task { await self.loadDetailAsync(id) }
        }
    }

    @Published public private(set) var manifest: RecordingManifest?
    @Published public private(set) var transcript: TranscriptDocument?

    /// 转写稿是不是在**生成纪要之后**又被人工改过。
    ///
    /// 这条存在的理由：允许手动改稿之后，界面上那份纪要随时可能变成
    /// 「基于旧稿的结论」。它不会报错、也看不出任何异常，而用户会拿着它开会。
    /// 判据取自文件 mtime（见 `SessionLibrary.transcriptIsNewerThanMinutes`），
    /// 关掉 App 再打开仍然成立。
    @Published public private(set) var transcriptChangedAfterMinutes: Bool = false

    /// 各场会议的转写相位，**按 sessionID 索引**。
    ///
    /// ## 为什么按 ID 索引，而不是一个「当前选中这场」的标量
    ///
    /// 转写是**按会议**的长时间任务：一场跑几十秒，用户完全可以
    /// 中途切到 B、再切回 A。用一个标量表达这件事，模型就是错的——
    /// 而这个错在同一个领域已经翻过两次车：
    ///
    /// 1. **第一次（不清）**：切走时相位留着，于是 B 显示「正在转写…」，
    ///    而它一个字都没在转。
    /// 2. **第二次（清）**：改成切走就清，于是切回 A 时 A 的相位没了，
    ///    界面显示「开始转写」，而它其实还在后台跑；`runTranscription` 的
    ///    `guard !isRunning` 又挡不住，用户再点一次就是**同一场并发两次转写**。
    ///
    /// 两次都在给错误模型打补丁。按 ID 索引之后，两个问题同时消失：
    /// 界面读「当前选中这一场」的那一份，切到 B 读 B 的、切回 A 读 A 的，
    /// 互不串扰；A 在转写期间它的状态**始终是真的**。
    ///
    /// 条目数 = 转写过的会议数，每场最多一条，不随时间无限增长。
    /// 转完的条目留着不删：切回那场时不必重新读盘就知道它是 `.done`，
    /// 而删掉它只会多一条「状态要等详情加载完才补上」的时间窗。
    @Published public private(set) var transcriptPhases: [String: TranscriptPhase] = [:]

    /// **当前选中这场**的转写相位。界面只该读这个。
    ///
    /// 是 computed property 而不是 `@Published`——真实数据在
    /// `transcriptPhases` 里按 ID 存着，这里只做一次查表。
    /// 它随 `selectedID` 与 `transcriptPhases` 两者变化，
    /// 而那两个都是 `@Published`，所以界面的刷新链是完整的。
    public var transcriptPhase: TranscriptPhase {
        guard let id = selectedID else { return .idle }
        return transcriptPhases[id] ?? .idle
    }

    /// 某一场是否正在转写。**不依赖当前选中谁**——列表要靠它给每一行标状态。
    public func isTranscribing(sessionID: String) -> Bool {
        transcriptPhases[sessionID]?.isRunning ?? false
    }

    /// 正在转写的会议 id，按列表顺序。
    ///
    /// 给「有几场在转」这类汇总用。空数组表示一场都没有。
    public func transcribingSessionIDs() -> [String] {
        meetings.filter { isTranscribing(sessionID: $0.id) }.map(\.id)
    }

    /// 盘上**真的有文件**的音轨 id。
    ///
    /// 与 `manifest.tracks` 分开是因为两者会不一致：保留策略（`prune`）
    /// 只删音频、故意留着 manifest，于是「manifest 说有两条轨、盘上一个都没有」
    /// 从罕见异常变成了清理之后的**正常状态**。
    ///
    /// 任何要「对某条轨动手」的入口（单轨转写、合并、播放）都必须问它，
    /// 而不是问 manifest——按 manifest 给入口的话，用户点完只会得到
    /// 「文件不存在」，而那本可以不给这个选项。
    @Published public private(set) var availableTrackIDs: Set<String> = []

    /// 每条音轨的波形包络，按 track id（`mic` / `system`）索引。
    /// 与详情**分开加载**：算包络要通读整个 WAV，13 分钟的录音就是几百 MB。
    /// 把它挡在详情前面会让「点一场会议」明显卡住，所以详情先出、波形后补。
    @Published public private(set) var waveforms: [String: WaveformEnvelope.Envelope] = [:]
    /// 是否有一次波形计算正在进行。界面靠它区分「还没算完」和「这一轨真没有波形」。
    @Published public private(set) var isLoadingWaveforms = false
    /// 波形归属的会话。
    ///
    /// 只有它等于 `selectedID` 时才表示「这份波形就是当前这一场的」。
    /// 界面必须用它来判：只看 `waveforms` 是否为空的话，**切场的那一瞬间**
    /// 波形已经清空、新的还没算出来，界面就会宣称「这一轨没有波形」——
    /// 又是拿「没算」冒充「没有」。
    @Published public private(set) var waveformSessionID: String?

    /// 波形条数。
    ///
    /// 固定值，不按像素算：条数一变就得重读整个文件。固定下来之后，
    /// 视图只管把这么多条按容器宽度拉伸铺满——拖窗口不会引发任何磁盘读取。
    public static let waveformBuckets = 300
    /// 最近一次自动清理的说明（做了什么 / 为什么没做）。
    ///
    /// **自动路径不弹窗**，但也不能完全沉默：用户设了「30 天」之后
    /// 看不到任何反馈，只能靠「老录音真的消失了」来推断它生效了。
    /// 这个字段是那之后的唯一一条说明，所以它必须**每次都有内容**
    /// （包括「今天没有需要清理的」），而不能只在出错时才有。
    @Published public private(set) var lastAutoPruneReport: String?

    /// 最近一次操作的错误，供界面弹提示。界面读完后应调 `clearError()`。
    @Published public private(set) var lastError: String?
    /// 列表搜索关键词
    @Published public var searchText: String = ""

    /// 录制期间是否在状态栏隐藏「正在录」的迹象。
    ///
    /// 放在中枢而不是放在 `StatusItemController` 里，因为它有两个写入方
    /// （录音栏的复选框、状态栏菜单的勾选项）和至少一个读取方（状态栏按钮），
    /// 各自持一份的话，勾选状态和实际行为一定会漂。
    ///
    /// `@Published` + `didSet` 的组合是刻意的：**读到变化的人（状态栏）和
    /// 存下变化的人（偏好文件）是两条独立的订阅**，谁都不依赖谁被先通知。
    /// 只在界面回调里顺手存一次的话，将来多一个写入方就会漏存。
    @Published public var hidesStatusBarCountdown: Bool {
        didSet {
            guard oldValue != hidesStatusBarCountdown else { return }
            preferences.hidesStatusBarCountdown = hidesStatusBarCountdown
        }
    }

    /// 菜单栏上是否显示本应用的图标与菜单。**默认显示。**
    ///
    /// 与 `hidesStatusBarCountdown` 同一套写法（`@Published` + `didSet` 落盘），
    /// 但方向相反：那一个默认关，这一个默认开。写方有三个——状态栏菜单、
    /// 主窗口顶栏「录音设置」面板、设置窗口（⌘,）——读方是 `StatusItemController`
    /// 的图标显隐。各自持一份的话，「菜单里显示已关、图标还在」这种自相矛盾
    /// 是必然结果。
    ///
    /// 关掉它**不动录音**：快捷键与主窗口都不经过状态栏。也正因如此，
    /// 三个写方里前两个会在图标消失后够不着，恢复入口是设置窗口与顶栏面板。
    @Published public var showsStatusBarIcon: Bool {
        didSet {
            guard oldValue != showsStatusBarIcon else { return }
            preferences.showsStatusBarIcon = showsStatusBarIcon
        }
    }

    /// 状态栏图标所在的显示器与主窗口**不在同一块屏**时给出的提示文案。
    /// nil = 两者一致（或只有一块屏），不需要提示。
    ///
    /// 2026-10-20 的一次真故障：macOS 26 上每块屏各有菜单栏，而状态栏项
    /// 跟随 **key window 所在屏**。主窗口在副屏时，图标就在副屏的菜单栏上，
    /// 主屏菜单栏里什么都没有——用户盯着主屏找，结论只能是「图标没了」。
    /// 而 `isVisible` / `isPlaced` / 系统的 `VisibleCC` 裁决**三处都说「在」**，
    /// 因为它真的在，只是在另一块屏上。
    ///
    /// 所以这条提示是**唯一**能让用户自己找到图标的线索：告诉他图标在哪块屏，
    /// 并给一键把窗口搬过去的动作。
    @Published public var statusIconScreenHint: String?

    /// 状态栏图标所在显示器的 ID（`CGDirectDisplayID`）。
    ///
    /// 用 ID 而不是 `NSScreen`：`NSScreen` 是 AppKit 的类型，
    /// 而这个工作区不该为了一个提示语就把 AppKit 拖进会话层。
    /// 需要屏本身的视图用这个 ID 去 `NSScreen.screens` 里反查。
    @Published public var statusIconScreenID: UInt32?

    /// 「把窗口移过去」这个动作的目标屏（显示 ID）。nil = 这一轮不给这个动作。
    ///
    /// 什么时候有：图标已经落在某块屏上，而主窗口在另一块屏——用户需要
    /// 一个动作把两边对齐。什么时候没有：已经自动换过屏（窗口与图标同屏，
    /// 再搬是空操作）或**所有屏都放不下**（这时该做的是腾菜单栏空间，
    /// 搬窗口没用）。
    @Published public var statusIconRelocateScreenID: UInt32?

    /// 录音是否存成 16 位整数 PCM（体积约为 32 位浮点的一半）。
    ///
    /// 与 `hidesStatusBarCountdown` 同一套写法与同一条理由：两个写入方
    /// （录音栏复选框、状态栏菜单勾选项）、一个读取方（`startRecording` 拼配置），
    /// 各自持一份的话，界面上的勾选状态和实际录出来的格式一定会漂。
    ///
    /// **默认关**，见 `RecorderPreferences.pcm16Recording`——打开它会降低录音精度。
    @Published public var pcm16Recording: Bool {
        didSet {
            guard oldValue != pcm16Recording else { return }
            preferences.pcm16Recording = pcm16Recording
        }
    }

    /// 录音是否降成**单声道 + 24 kHz**。
    ///
    /// **单独开这一项**约合现状的 1/3（1978 → 659 MiB/小时）；**再叠上「16 位」**才约合 1/6
    /// （→ 330 MiB/小时）。别把 1/6 挂在这一项自己头上——它做不到。
    /// 两个比例都按「两条轨的源都是 48 kHz」算，真机上还取决于麦克风给的格式。
    /// （口径与 `DualTrackRecorder.Configuration.mono24k`、`RecorderPreferences.mono24kRecording`
    /// 保持一致：三处各说各话的话，将来谁写对外文案都可能抄错。）
    ///
    /// 与 `pcm16Recording` 同一套写法与同一条理由：两个写入方（录音栏复选框、
    /// 状态栏菜单勾选项）、一个读取方（`startRecording` 拼配置），
    /// 各自持一份的话，界面上的勾选状态和实际录出来的格式一定会漂。
    ///
    /// **默认关**，见 `RecorderPreferences.mono24kRecording`——它会同时改掉
    /// 录音的采样率与声道数，比位深更难回头。
    @Published public var mono24kRecording: Bool {
        didSet {
            guard oldValue != mono24kRecording else { return }
            preferences.mono24kRecording = mono24kRecording
        }
    }

    /// 多声道降成单声道时用哪种策略。
    ///
    /// 与上面两个开关同一套写法：`@Published` + `didSet` 落盘，
    /// 状态栏菜单改它、`startRecording` 读它。**读的时候不写键**——
    /// 否则「默认值」的断言第二次跑会因为键已存在而不成立。
    ///
    /// **默认 `.firstChannel`**，依据见 `RecorderPreferences.downmixStrategy`：
    /// `average` 在反相内容上会把整轨抵消成静音，而且不报错。
    @Published public var downmixStrategy: MonoDownmixStrategy {
        didSet {
            guard oldValue != downmixStrategy else { return }
            preferences.downmixStrategy = downmixStrategy
        }
    }

    /// 转写引擎。**全局偏好，不是每场单独选。**
    ///
    /// 与 `hidesStatusBarCountdown` / `pcm16Recording` 同一套写法、同一条理由：
    /// 引擎有多个读取方（转写编排、界面显示），各自持一份一定会漂。
    /// 这里的 `didSet` 只负责把变化落盘；真正取用发生在 `transcriber` 里——
    /// 那是**每次转写现取**的，所以用户在界面里改了引擎，下一场转写立刻生效。
    ///
    /// **默认苹果原生**，见 `RecorderPreferences.transcriptionEngine`。
    @Published public var transcriptionEngine: TranscriptionEngine {
        didSet {
            guard oldValue != transcriptionEngine else { return }
            preferences.transcriptionEngine = transcriptionEngine
        }
    }

    /// 录音保留策略。与上面几个同一套写法：`@Published` + `didSet` 落盘。
    ///
    /// **默认 `.off`（什么都不删）**，见 `RecorderPreferences.retentionPolicy`。
    ///
    /// 这里刻意**不暴露可选**：读偏好时把「不认识的值」映射成 `.off` 是对的
    /// （界面上不该因为一个坏键就不让菜单打开），但那样会**盖住**坏键的存在——
    /// 而 `prune` 侧必须因为它拒绝执行。所以判断「键是不是坏的值」交给
    /// `preferences.hasUnrecognizedRetentionPolicy()`，执行路径单独问一次。
    @Published public var retentionPolicy: RetentionPolicy {
        didSet {
            guard oldValue != retentionPolicy else { return }
            preferences.retentionPolicy = retentionPolicy
        }
    }

    /// 偏好里存着不认识的保留档位吗？CLI/GUI 在执行清理前问它。
    public var hasUnrecognizedRetentionPolicy: Bool {
        preferences.hasUnrecognizedRetentionPolicy()
    }

    /// 是否自动清理旧音频。**默认关**，与档位刻意分开——
    /// 档位说「按什么规则清」，这一项说「谁去清」。
    @Published public var autoPruneEnabled: Bool {
        didSet {
            guard oldValue != autoPruneEnabled else { return }
            preferences.autoPruneEnabled = autoPruneEnabled
        }
    }

    // MARK: 会议纪要（本地 / 云端 API）

    /// 纪要模型层。**全局偏好**，与转写引擎同一套纪律：默认 `.local`
    /// （录音不出本机），换云端要用户逐项配齐后主动开启。
    @Published public var minutesProvider: MinutesProvider {
        didSet {
            guard oldValue != minutesProvider else { return }
            preferences.minutesProvider = minutesProvider
        }
    }

    /// 云端纪要 API 的 Base URL。界面里是文本字段；**空串 = 未设置**
    /// （与偏好的语义一致，清空输入框就真的清掉）。
    @Published public var minutesAPIBaseURL: String {
        didSet {
            guard oldValue != minutesAPIBaseURL else { return }
            preferences.minutesAPIBaseURL = minutesAPIBaseURL
        }
    }

    /// 云端纪要 API 的密钥。界面只在 `SecureField` 里出现；
    /// 展示状态用 `maskedMinutesAPIKey`（绝不进任何标签）。
    @Published public var minutesAPIKey: String {
        didSet {
            guard oldValue != minutesAPIKey else { return }
            preferences.minutesAPIKey = minutesAPIKey
        }
    }

    /// 云端纪要 API 的模型名。空串 = 未设置。
    @Published public var minutesModelName: String {
        didSet {
            guard oldValue != minutesModelName else { return }
            preferences.minutesModel = minutesModelName
        }
    }

    /// 云端三件套齐了吗。界面据此决定「生成纪要」是直接可用还是要先补配置。
    public var minutesCloudAPIIsComplete: Bool {
        preferences.minutesCloudAPIIsComplete
    }

    /// 缺哪些云端配置项（显示名）。
    public var missingMinutesCloudAPIItems: [String] {
        preferences.missingMinutesCloudAPIItems()
    }

    /// 打码后的密钥，供界面显示「设没设、是哪一把」。
    public var maskedMinutesAPIKey: String {
        preferences.maskedMinutesAPIKey
    }

    /// 本机跑本地纪要**到底行不行**。nil = 可以；非 nil = 人可读的提醒。
    ///
    /// 设置界面必须说清这件事：用户选了「本地」却在生成后只看到原稿，
    /// 而界面从头到尾没提过「这台机器不支持 Apple Intelligence」——
    /// 那看起来就像功能坏了。诚实告知的成本只是一行字。
    public var localMinutesUnavailableReason: String? {
        guard case let .ready(generator) =
            MinutesGeneratorResolver.resolve(preferences: preferences) else { return nil }
        return generator.isAvailable ? nil : generator.unavailableReason
    }

    /// 「打开设置窗口」的回调。**由宿主（`AppDelegate`）在启动时注入**。
    ///
    /// 用闭包而不是 NotificationCenter：这里只有一个发送方和一个接收方，
    /// 通知中心那套注册/注销时序换来的是「谁发的、发给谁」在类型上完全消失。
    ///
    /// 默认 nil —— 测试里的 workspace 不注入，按钮点了也不崩（它本来就
    /// 不该在无宿主的测试环境里真的弹窗）。
    public var onOpenSettings: (() -> Void)?

    /// 纪要生成相位，**按 sessionID 存**——与 `transcriptPhases` 同一理由：
    /// 云端一场长会议可能跑几分钟，用户中途切到别的会议再切回来，
    /// 状态不能丢；两场同时生成也不能串。
    @Published public private(set) var minutesPhases: [String: MinutesPhase] = [:]

    /// 当前选中会议的纪要相位。
    public var minutesPhase: MinutesPhase {
        minutesPhases[selectedID ?? ""] ?? .idle
    }

    /// 当前选中会议的纪要内容（`minutes.json` 解码而来），没有则 nil。
    @Published public private(set) var minutesResult: MinutesResult?

    /// 纪要生成的进行状态。
    public enum MinutesPhase: Equatable {
        case idle
        case running(summary: String)
        /// 生成成功。带生成器名——「这一份是谁写的」必须能在界面上读到。
        case done(generatorName: String)
        case failed(String)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    public let library: SessionLibrary
    public let recorder: RecordingController

    /// 当前引擎下的转写编排器。
    ///
    /// 做成**计算属性**而不是构造时定死的一个实例：引擎是可全局切换的偏好，
    /// 若在 `init` 里用当时的值造一个 `SessionTranscriber` 存起来，用户在界面里
    /// 换了引擎也不会生效——那正是「配置项改了却没用」这类最难发现的问题。
    /// `SessionTranscriber` 是轻量 struct（只持有 store 与一份配置），现取现造代价可忽略。
    public var transcriber: SessionTranscriber {
        var configuration = transcriptionConfiguration
        configuration.engine = transcriptionEngine
        return SessionTranscriber(store: library.store, configuration: configuration)
    }

    /// 偏好的落盘层。见 `RecorderPreferences`。
    private let preferences: RecorderPreferences

    /// 录音状态机的变化订阅。
    ///
    /// **这一条订阅是「状态机 → 界面」之间唯一的那根线，缺了界面就是死的。**
    ///
    /// 视图订阅的是 `workspace`，而 `phase` / `elapsed` 发布在 `workspace.recorder`
    /// 上——这是**两个不同的 `ObservableObject`**。SwiftUI 不会因为 body 里读到了
    /// `workspace.recorder.phase` 就顺带去订阅 `recorder`；它只跟踪被
    /// `@ObservedObject` 标记的那一个。
    ///
    /// 于是状态机怎么变，录音栏、列表、详情全都纹丝不动：按下「开始录制」之后
    /// 窗口里还是那个「开始录制」按钮，暂停之后还是「暂停」按钮——
    /// 「继续」永远不出现，看上去就成了「暂停之后无法继续，只能停止」。
    ///
    /// 转发 `objectWillChange` 而不是逐个字段转 `@Published`：将来给
    /// `RecordingController` 加新字段时这里不用改，也就不会漏。
    private var recorderCancellables: Set<AnyCancellable> = []

    /// 详情请求的代际号。用来丢弃「用户已经切走」的迟到结果。
    private var detailGeneration = 0
    /// 扫描请求的代际号。用来丢弃被更新扫描取代的迟到结果。
    private var scanGeneration = 0
    /// 波形请求的代际号。理由同上：切走后不能把上一场的波形填进来。
    private var waveformGeneration = 0

    /// 转写配置（语言、是否分段）
    public let transcriptionConfiguration: SessionTranscriber.Configuration

    /// - Parameters:
    ///   - root: 会议库根目录
    ///   - transcriptionConfiguration: 转写语言/分段策略
    ///   - preferences: 偏好落盘层。**测试传自己的 suite**，别碰真用户的偏好域。
    ///   - makeRecorder: 引擎工厂。默认产出真实的 `DualTrackRecorder`；
    ///     测试注入假引擎，好在没有麦克风/系统音频授权的环境里把「相位变化
    ///     → 状态栏按钮重绘」这条实时链路整段跑完。**默认 `nil` 时走真实引擎**，
    ///     所以生产路径上这个参数完全不存在。
    public init(
        root: URL = SessionStore.defaultRoot(),
        transcriptionConfiguration: SessionTranscriber.Configuration = .init(),
        preferences: RecorderPreferences = RecorderPreferences(),
        makeRecorder: RecordingController.RecorderFactory? = nil
    ) {
        let library = SessionLibrary(root: root)
        self.library = library
        self.transcriptionConfiguration = transcriptionConfiguration
        self.preferences = preferences
        if let makeRecorder {
            self.recorder = RecordingController(store: library.store, makeRecorder: makeRecorder)
        } else {
            self.recorder = RecordingController(store: library.store)
        }
        // 放在最后：`@Published` 的赋值会走属性包装器的 setter，
        // 而 setter 是一次「用到 self」——必须等所有存储属性都就位。
        self.hidesStatusBarCountdown = preferences.hidesStatusBarCountdown
        self.showsStatusBarIcon = preferences.showsStatusBarIcon
        self.pcm16Recording = preferences.pcm16Recording
        self.mono24kRecording = preferences.mono24kRecording
        self.downmixStrategy = preferences.downmixStrategy
        self.transcriptionEngine = preferences.transcriptionEngine
        self.retentionPolicy = preferences.resolvedRetentionPolicy()
        self.minutesProvider = preferences.minutesProvider
        self.minutesAPIBaseURL = preferences.minutesAPIBaseURL ?? ""
        self.minutesAPIKey = preferences.minutesAPIKey ?? ""
        self.minutesModelName = preferences.minutesModel ?? ""
        self.autoPruneEnabled = preferences.autoPruneEnabled

        // 必须在所有存储属性就位之后：`sink` 的闭包捕获了 self。
        // 这一行的作用见 `recorderCancellables` 的说明——它是界面能跟着
        // 状态机变的唯一原因，删掉界面就冻结在启动时的样子。
        recorder.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &recorderCancellables)

        // 自动清理的触发点之三：录完一场。
        //
        // 接在 `phase` 变成 `.finished` 上，而不是 `RecordingController.stop()` 里——
        // 状态机是「录音结束」这件事的**唯一**权威，控制器里有多个出口
        // （正常停止、崩溃恢复后的收尾），挂在 phase 上才不会漏。
        //
        // `finished` → `idle` → `finished` 这种来回**不该**重复触发清理，
        // 所以这里只在「从非 finished 态进入 finished」时才触发。
        recorder.$phase
            .map(\.isFinishedSession)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] finished in
                guard let self, finished else { return }
                Task { await self.runAutoPruneAfterRecordingAsync() }
            }
            .store(in: &recorderCancellables)
    }

    // MARK: - 派生状态

    /// 过滤后的列表。搜索匹配标题或会话 ID。
    public var visibleMeetings: [MeetingSummary] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return meetings }
        return meetings.filter {
            $0.title.localizedCaseInsensitiveContains(keyword)
                || $0.id.localizedCaseInsensitiveContains(keyword)
        }
    }

    public var selectedMeeting: MeetingSummary? {
        guard let selectedID else { return nil }
        return meetings.first { $0.id == selectedID }
    }

    /// 「列表空」的含义必须能分开，否则界面会撒谎。
    ///
    /// 返回 `nil` 有两种情况，**必须区分**：
    ///  - 列表非空（有内容可显示）
    ///  - 还没扫描过（`hasScanned == false`，此时我们对磁盘一无所知）
    ///
    /// 调用方靠 `hasScanned` 区分后者，界面应当显示「正在读取…」而不是「还没有记录」。
    public var emptyStateMessage: String? {
        if !meetings.isEmpty { return nil }
        // 还没扫过就别下结论
        guard hasScanned else { return nil }
        switch access {
        case .permissionDenied:
            return "系统未授权访问「文稿」文件夹，因此看不到已有录音。"
        case .failed(let reason):
            return "无法读取会议目录：\(reason)"
        case .missing, .ok:
            return "还没有会议记录。点「开始录制」录第一场。"
        }
    }

    /// 未授权时界面要显示一条可操作的指引（不只是说「没权限」）
    public var needsPermissionGuidance: Bool {
        if case .permissionDenied = access { return true }
        return false
    }

    // MARK: - 刷新

    /// 重新扫描磁盘（同步版）。
    ///
    /// ⚠️ **界面不要直接调它**——见 `refreshAsync()` 的说明。
    /// 保留同步版是给单元测试和 CLI 用的，那里没有 TCC 弹窗交互。
    public func refresh() {
        access = library.accessStatus()
        meetings = library.list()
        hasScanned = true
        reconcileSelection()
    }

    /// 重新扫描磁盘（异步版）。**图形界面必须走这条。**
    ///
    /// 这不是性能优化，是正确性要求。`~/Documents` 受 TCC 保护，而权限探测
    /// （`open`）在「是否允许访问文稿文件夹」弹窗**未决时会同步阻塞**。
    /// 实测把它放在主线程的后果是：窗口卡在 SwiftUI 布局阶段，**根本显示不出来**，
    /// 用户看到的是「双击了没反应」。堆栈确认阻塞点在 `open` → `__open`。
    ///
    /// 所以磁盘与权限相关的一切都放到后台，界面只接收结果。
    ///
    /// 并发调用用代际号仲裁：**后发起的赢**，先发起的那次结果直接丢弃。
    /// 这里刻意**不做「扫描中就直接返回」的早退**——那样会带来一个很难发现的洞：
    /// 录制刚结束、界面正在扫描，用户又点了「重试」，那次重试会被静默吞掉，
    /// 于是新录的会议迟迟不出现。
    public func refreshAsync() async {
        scanGeneration &+= 1
        let generation = scanGeneration
        isScanning = true
        defer { if generation == scanGeneration { isScanning = false } }

        let root = library.root
        let snapshot = await Task.detached(priority: .userInitiated) {
            Self.scan(root: root)
        }.value

        guard generation == scanGeneration else { return }

        access = snapshot.access
        meetings = snapshot.meetings
        hasScanned = true
        reconcileSelection()
    }

    /// 扫描全库。`nonisolated` + 只捕获 `URL`（Sendable），因此可以安全地丢到后台。
    nonisolated private static func scan(root: URL) -> LibrarySnapshot {
        let library = SessionLibrary(root: root)
        return LibrarySnapshot(access: library.accessStatus(), meetings: library.list())
    }

    /// 读单个会话的详情（后台执行，理由同 `refreshAsync`）。
    nonisolated private static func readDetail(root: URL, id: String) -> DetailSnapshot {
        let library = SessionLibrary(root: root)
        let manifest = try? library.manifest(forSessionID: id)
        let directory = library.store.directory(forSessionID: id)
        // 「盘上真有文件」在这里算一次，而不是让每个视图各问一遍磁盘——
        // 三个入口（单轨转写、合并、播放）问三次就是三次不一致的机会。
        return DetailSnapshot(
            manifest: manifest,
            transcript: library.transcript(forSessionID: id),
            existingTrackIDs: existingTrackIDs(of: manifest, in: directory),
            minutes: library.minutes(forSessionID: id),
            transcriptChangedAfterMinutes: library.transcriptIsNewerThanMinutes(sessionID: id))
    }

    /// 刷新之后把选中项收敛到一个有效值
    private func reconcileSelection() {
        if let id = selectedID, !meetings.contains(where: { $0.id == id }) {
            selectedID = nil      // didSet 会顺手清掉详情
            return
        }
        if selectedID == nil, let first = meetings.first {
            selectedID = first.id // didSet 会加载详情
            return
        }
        if let id = selectedID {
            // 详情可能已经变了（录完的时长、新生成的转写稿），重新读一次
            Task { await loadDetailAsync(id) }
        }
    }

    public func select(_ id: String?) {
        selectedID = id
    }

    /// **仅供测试**：把某场会议的转写相位设成指定值。
    ///
    /// 为什么需要它：要复现「转写中切换会议」必须能进入 `.running`，
    /// 而真正的 `runTranscription` 会真的去加载 SenseVoice 资产跑推理——
    /// 那既慢、又要真音频文件。测试要的是**状态机本身**，
    /// 不该被引擎的可用性绑住。
    ///
    /// - Parameter sessionID: 设给哪一场。`nil` = 当前选中的那一场
    ///   （绝大多数用例只关心当前这场，少写一个参数）。
    func setTranscriptPhaseForTesting(_ phase: TranscriptPhase,
                                      for sessionID: String? = nil) {
        let id = sessionID ?? selectedID
        guard let id else { return }
        transcriptPhases[id] = phase
    }

    /// 用磁盘状态推导一场的相位，**只在这一场没在转写时**。
    ///
    /// ## 为什么必须有「没在转写」这个前提
    ///
    /// 详情加载是切换会议时发起的，而那场可能**正在转写**。
    /// 无条件覆盖会把 `.running` 擦成 `.idle`——用户切回来看到
    /// 「开始转写」按钮，而它其实还在后台跑（2026-10-16 修的正是这个）。
    ///
    /// 反过来，`.failed` 状态**允许**被磁盘覆盖：切走再切回时重新读一次盘，
    /// 万一稿子其实已经写出来了（比如失败发生在写盘之后），界面该显示 `.done`。
    /// 用户不会因为「切了个会议」就被永远困在一条过期的报错上。
    private func adoptPhaseFromDisk(_ id: String, transcript: TranscriptDocument?) {
        guard transcriptPhases[id]?.isRunning != true else { return }
        transcriptPhases[id] = transcript == nil
            ? .idle
            : .done(segmentCount: transcript?.segments.count ?? 0)
    }

    /// 用磁盘状态推导纪要相位，规则与 `adoptPhaseFromDisk` 相同：
    /// 正在生成的不覆盖；`minutes.json` 在盘上就是 `.done`，不在就是 `.idle`。
    ///
    /// 单独一个方法而不是塞进 `adoptPhaseFromDisk`：两者的判据不同
    /// （一个看 transcript、一个看 minutes.json），合成一个只会让
    /// 「改纪要的磁盘规则顺手动了转写的规则」变得可能。
    private func adoptMinutesPhaseFromDisk(_ id: String, minutes: MinutesResult?) {
        guard minutesPhases[id]?.isRunning != true else { return }
        minutesPhases[id] = minutes == nil
            ? .idle
            : .done(generatorName: minutes?.generatorName ?? "")
    }

    /// 同步读详情（测试与 CLI 用）
    private func loadDetail(_ id: String) {
        manifest = try? library.manifest(forSessionID: id)
        transcript = library.transcript(forSessionID: id)
        minutesResult = library.minutes(forSessionID: id)
        availableTrackIDs = Self.existingTrackIDs(
            of: manifest, in: library.store.directory(forSessionID: id))
        transcriptChangedAfterMinutes = library.transcriptIsNewerThanMinutes(sessionID: id)
        adoptPhaseFromDisk(id, transcript: transcript)
        adoptMinutesPhaseFromDisk(id, minutes: minutesResult)
    }

    /// manifest 里登记、且文件**真的在盘上**的轨 id。
    ///
    /// 单独抽出来是因为 `readDetail`（后台快照）与 `loadDetail`（同步版）
    /// 都要用它——两处各写一遍判据，早晚会漂，而漂的方向是
    /// 「界面说有、盘上没有」。
    nonisolated static func existingTrackIDs(of manifest: RecordingManifest?,
                                           in directory: URL) -> Set<String> {
        guard let manifest else { return [] }
        return Set(manifest.tracks.compactMap { track in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(track.fileName).path)
                ? track.id : nil
        })
    }

    /// 异步读详情。返回 false 表示这次结果已被更新的请求取代（调用方可忽略）。
    @discardableResult
    public func loadDetailAsync(_ id: String) async -> Bool {
        detailGeneration &+= 1
        let generation = detailGeneration
        let root = library.root
        let snapshot = await Task.detached(priority: .userInitiated) {
            Self.readDetail(root: root, id: id)
        }.value

        // 读取期间用户可能已经切走了。不校验的话，详情区会显示**上一场**的音轨与
        // 文稿，而标题却是这一场的——比空白更难发现。
        guard generation == detailGeneration else { return false }

        manifest = snapshot.manifest
        transcript = snapshot.transcript
        availableTrackIDs = snapshot.existingTrackIDs
        minutesResult = snapshot.minutes
        transcriptChangedAfterMinutes = snapshot.transcriptChangedAfterMinutes
        // 与同步版同一条规则：这一场正在转写时不许用磁盘状态覆盖它的相位。
        // 见 `adoptPhaseFromDisk` 的说明。
        adoptPhaseFromDisk(id, transcript: snapshot.transcript)
        adoptMinutesPhaseFromDisk(id, minutes: snapshot.minutes)

        // 详情就绪之后再算波形：波形要通读整个 WAV，不能挡在详情前面。
        // 界面先把音轨参数和转写稿显示出来，波形随后补上。
        if let meeting = meetings.first(where: { $0.id == id }) {
            Task { await self.loadWaveformsAsync(for: meeting) }
        }
        return true
    }

    /// 算一场会议各轨的波形。**文件 IO 全在后台**，界面只接收结果。
    ///
    /// 与详情用同一个代际号仲裁策略：切走后到达的结果直接丢弃，
    /// 否则波形区会显示**上一场**的曲线，而标题是这一场的——比空白更难发现。
    public func loadWaveformsAsync(for meeting: MeetingSummary) async {
        // 同一场已经算过就不重算。列表刷新（录完一场、删掉一条）也会走到这里，
        // 每次都重读几百 MB 是不可接受的。
        if waveformSessionID == meeting.id, !waveforms.isEmpty { return }

        waveformGeneration &+= 1
        let generation = waveformGeneration
        waveformSessionID = meeting.id
        waveforms = [:]
        isLoadingWaveforms = true
        defer { if generation == waveformGeneration { isLoadingWaveforms = false } }

        let directory = meeting.directory
        let buckets = Self.waveformBuckets
        let result = await Task.detached(priority: .utility) {
            Self.computeWaveforms(directory: directory, buckets: buckets)
        }.value

        guard generation == waveformGeneration else { return }
        waveforms = result
    }

    /// 通读每条轨的 WAV 算包络。
    ///
    /// `nonisolated` + 只捕获 `URL`（Sendable），因此可以安全地丢到后台。
    /// 单条轨算不出来（文件缺失、头损坏）只影响那一条，其余照常显示。
    nonisolated private static func computeWaveforms(
        directory: URL, buckets: Int
    ) -> [String: WaveformEnvelope.Envelope] {
        let manifestURL = directory.appendingPathComponent(SessionStore.manifestFileName)
        guard let manifest = try? RecordingManifest.read(from: manifestURL) else { return [:] }

        var output: [String: WaveformEnvelope.Envelope] = [:]
        for track in manifest.tracks {
            let url = directory.appendingPathComponent(track.fileName)
            if let envelope = try? WaveformEnvelope.compute(from: url, buckets: buckets) {
                output[track.id] = envelope
            }
        }
        return output
    }

    public func clearError() { lastError = nil }

    // MARK: - 录音

    /// 开始录制。**标题只在这一处生成。**
    ///
    /// 界面的「开始录制」按钮与状态栏菜单都走这里，所以两边给出的一定是同一个会话名。
    /// 标题 = 前缀 + 时间序号（`yyyyMMddHHmm`），前缀留空即「会议202607271624」。
    ///
    /// **存储格式的缺省来源也只在那一处**：调用方可以带自己的设备锁定、时长上限，
    /// 位深则「没表态时」按偏好填。这里有两个入口（录音栏按钮、状态栏菜单），
    /// 它们都不传 `configuration`，所以照样走偏好——「两个入口各判一次会漂」这个
    /// 初衷仍然成立。而调用方**显式**指定 `sampleFormat` 时不再被静默覆盖：
    /// 同一仓库里 `RecordingController.start` 与 CLI 都尊重调用方，只有这一层
    /// 原来会把意图吞掉，语义是反的。CLI 不经过这里，走它自己的 `--pcm16` / `--f32`。
    ///
    /// - Parameter titleBase: 标题前缀，可留空。
    /// - Parameter configuration: 设备锁定、时长上限等。为 `nil` 时用默认配置。
    ///   `sampleFormat` 留空（`nil`）时按偏好填；显式指定则尊重调用方。
    public func startRecording(
        titleBase: String = "",
        configuration: DualTrackRecorder.Configuration? = nil
    ) {
        var config = configuration ?? DualTrackRecorder.Configuration()
        // 偏好只在**调用方没表态**时兜底（`sampleFormat == nil`）。
        //
        // 原来是无条件覆盖：调用方显式要 `.pcm16` 也会被静默改回偏好值，没有任何日志或
        // 返回值能让人发现。改成条件兜底之后，GUI 的两个入口仍走偏好，
        // 而任何用 `configuration` 表达「这一场必须无损 / 必须省空间」的调用方都会被尊重。
        if config.sampleFormat == nil { config.sampleFormat = preferences.sampleFormat }
        // 同一条纪律用在「单声道 + 24 kHz」上：它同时决定文件的声道数与采样率，
        // 显式表态的调用方（比如「这一场必须全带宽」）不能被偏好悄悄改掉。
        if config.mono24k == nil { config.mono24k = preferences.mono24kRecording }
        // 降混策略同理：**调用方没表态才用偏好兜底**，
        // 否则显式指定的那一方会被静默覆盖。
        if config.downmix == nil { config.downmix = preferences.downmixStrategy }
        recorder.start(titleBase: titleBase, configuration: config)
    }

    /// 预览「用这个前缀现在开录会得到什么标题」。界面用它做输入框旁的提示，
    /// 免得用户以为时间序号要自己手打。
    ///
    /// 刻意做成接受 `base` 的函数而不是只读属性：前缀是界面上的输入框状态，
    /// 中枢不该去持有它的一份拷贝——两份状态一定会漂。
    public func pendingTitle(for base: String) -> String {
        SessionStore.autoTitle(base: base)
    }

    // MARK: - 修改操作

    /// 删除一场会议。磁盘操作在后台，删完重扫。
    ///
    /// 之所以整体异步：`delete` 会往废纸篓搬文件，而 `refresh` 要重扫受 TCC 保护的目录。
    /// 界面按钮点下去不该有任何阻塞主线程的路径。
    public func delete(sessionID: String) {
        let root = library.root
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SessionLibrary(root: root).delete(sessionID: sessionID)
                }.value
                if self.selectedID == sessionID { self.selectedID = nil }
                await self.refreshAsync()
            } catch {
                self.lastError = "删除失败：\(error)"
            }
        }
    }

    public func rename(sessionID: String, to title: String) {
        let root = library.root
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SessionLibrary(root: root).rename(sessionID: sessionID, to: title)
                }.value
                await self.refreshAsync()
            } catch {
                self.lastError = "重命名失败：\(error)"
            }
        }
    }

    /// 在访达里显示该会议的目录。沙盒外直接用 NSWorkspace，无需额外权限。
    public func revealInFinder(sessionID: String) {
        let dir = library.store.directory(forSessionID: sessionID)
        NSWorkspaceOpener.open(dir)
    }

    public func revealRootInFinder() {
        NSWorkspaceOpener.open(library.root)
    }

    // MARK: - 人工修正转写稿

    /// 改写某一时段转写出来的文字。
    ///
    /// ## 写盘频率由调用方控制
    ///
    /// 这个函数**每调一次就写一次盘**（编码整份 `transcript.json` + 重写
    /// `transcript.md` + 两次原子写）。界面上是「防抖提交」在调它
    /// （`TranscriptDraftSession`），所以实际频率是「停顿时一次」，
    /// 而不是「每按一个键一次」——1375 段的那场会，后者会把主线程钉死。
    ///
    /// ## 写失败必须回滚
    ///
    /// 写盘失败（磁盘满、目录被移走）时**内存里的稿子不动**（仍是磁盘上那份），
    /// 并报错。先改内存再写盘的话，界面会是改后的、文件是改前的，
    /// 刷新一次就凭空复原——用户会以为自己没改成功，然后再改一遍。
    ///
    /// - Returns: 是否真的落盘成功。`false` 时调用方要把输入框退回磁盘那份。
    @discardableResult
    public func setTranscriptText(at index: Int, to text: String) -> Bool {
        guard let id = selectedID else { return false }
        return setTranscriptText(at: index, to: text, forSessionID: id)
    }

    /// 按**会话 id** 改写某一段（草稿的防抖提交走这条）。
    ///
    /// ## 为什么必须显式传 id，不能读 `selectedID`
    ///
    /// 草稿是防抖提交的，flush 可能发生在**用户已经切到另一场会议之后**
    /// （切会议时会 flush，而 `onChange` 触发时 `selectedID` 已经换了）。
    /// 那时按 `selectedID` 写，就是把上一场的内容写进**另一场**的
    /// `transcript.json`——两场稿子的段数往往不同，运气好是下标越界什么都不写，
    /// 运气不好就是静默改坏别人那一场，而界面上一点迹象都没有。
    ///
    /// 目标不是当前选中那一场时，从磁盘读它自己的稿子来改，
    /// 且**不动**界面上那几份状态（`transcript` / `transcriptChangedAfterMinutes`）。
    @discardableResult
    public func setTranscriptText(at index: Int, to text: String,
                                  forSessionID id: String) -> Bool {
        applyTranscriptEdit(to: id) { $0.settingText(text, at: index) }
    }

    /// 清空某一时段的内容（这一段从此不参与纪要生成）。可随时「恢复原文」。
    @discardableResult
    public func clearTranscriptSegment(at index: Int) -> Bool {
        applyTranscriptEdit { $0.clearingText(at: index) }
    }

    /// 把某一时段还原成语音识别的原始文本。
    @discardableResult
    public func restoreTranscriptSegment(at index: Int) -> Bool {
        applyTranscriptEdit { $0.restoringOriginalText(at: index) }
    }

    /// 编辑动作的统一收口：算出新稿 → 落盘 → 失败不上前。
    ///
    /// - Parameter transform: 返回 `nil` 表示无事可做（下标越界 / 内容没变），
    ///   此时**不写盘**——按一次方向键就重写一遍文件是纯噪音。
    @discardableResult
    private func applyTranscriptEdit(
        _ transform: (TranscriptDocument) -> TranscriptDocument?
    ) -> Bool {
        guard let id = selectedID else { return false }
        return applyTranscriptEdit(to: id, transform)
    }

    @discardableResult
    private func applyTranscriptEdit(
        to id: String,
        _ transform: (TranscriptDocument) -> TranscriptDocument?
    ) -> Bool {
        let isCurrent = (id == selectedID)
        guard let current = isCurrent ? transcript : library.transcript(forSessionID: id),
              let updated = transform(current), updated != current else {
            // 内容没变：**不算失败**（调用方不该因此把输入框退回）。
            // 读不到稿子时也走这里：那是「没有可改的东西」，不是写盘失败。
            return true
        }

        do {
            try library.saveTranscript(updated, forSessionID: id)
        } catch {
            lastError = "转写稿没能保存到磁盘：\(error)"
            return false
        }
        guard isCurrent else { return true }
        transcript = updated
        // 稿子变了，之前生成的纪要就不再是这份稿子的结论。
        // 判据用「有没有纪要」而不是「有没有改动」：没有纪要时这句话没有意义。
        if minutesResult != nil { transcriptChangedAfterMinutes = true }
        return true
    }

    // MARK: - 转写

    /// 对当前选中的会议跑转写。已有转写稿时会被覆盖。
    ///
    /// - Parameter onlyTrackIDs: 只转写这些轨；`nil` 或空 = 整场。
    ///   单轨转写的产物写 `transcript-<轨>.md`，**不覆盖整场稿、不改 manifest 状态**，
    ///   理由见 `SessionTranscriber.Configuration.trackFilter`。
    public func runTranscription(onlyTrackIDs: Set<String>? = nil) {
        guard let id = selectedID else { return }
        // 只挡**这一场**的重复发起。按 ID 判断，所以 B 在转写不影响 A 发起；
        // 反过来 A 在转写时再点 A 会被挡住——那正是我们要的并发保护。
        guard transcriptPhases[id]?.isRunning != true else { return }
        transcriptPhases[id] = .running(summary: "正在准备引擎…")
        lastError = nil

        /// 现取当前引擎下的编排器：引擎是全局偏好，可能在上一场转写之后被改过。
        // `transcriber` 的 `configuration` 是 `let`，所以按轨筛选必须在这里
        // 重新造一个编排器——`SessionTranscriber` 是 struct，造新的代价可忽略，
        // 而改动一个共享实例的配置会让并发的那次转写读到被改过的值。
        var configuration = transcriptionConfiguration
        configuration.engine = transcriptionEngine
        configuration.trackFilter = onlyTrackIDs
        let transcriber = SessionTranscriber(store: library.store, configuration: configuration)
        let singleTrack = !(onlyTrackIDs?.isEmpty ?? true)
        Task { [weak self, transcriber] in
            do {
                let outcome = try await transcriber.transcribe(sessionID: id) { [weak self] event in
                    // 回调来自转写内部，逐段更新界面文字
                    Task { @MainActor in
                        // **按 id 更新，不按「当前选中谁」。**
                        //
                        // 转写要跑几十秒，用户完全可以中途切到另一场。
                        // 按 ID 写入 `transcriptPhases[id]` 之后，A 的进度
                        // 始终归 A：切到 B 时 B 显示自己的状态，切回 A 时
                        // A 的进度一秒都没丢。
                        //
                        // 这里不再需要 `guard self.selectedID == id`——
                        // 那个判断是标量模型下的补丁（防止把进度写到另一场上），
                        // 而按 ID 存之后它反而会**丢掉**切走期间的进度。
                        guard let self else { return }
                        self.transcriptPhases[id] = .running(summary: Self.describe(event))
                    }
                }
                guard let self else { return }
                // 相位同样按 id 落——即使已经切到别的会议，A 的状态也要是对的。
                // 用户切回来时看到「已完成」而不是「开始转写」，这才是事实。
                self.transcriptPhases[id] = .done(segmentCount: outcome.document.segments.count)
                // **单轨稿不写进 `transcript`。** 那个字段是界面上「当前选中会议的稿子」，
                // 填一份只含一条轨的稿子进去，用户会以为整场就这么点儿内容，
                // 而另一条轨的内容其实还在 transcript.json 里没被碰到。
                //
                // 另外它只在「当前选中的还是这一场」时才写：转写完成时用户
                // 可能已经切到 B，此时把 A 的稿子塞进去会让 B 的详情区显示 A 的内容。
                if !singleTrack, self.selectedID == id {
                    self.transcript = outcome.document
                    // 换了新稿子，桌上那份纪要必然是基于上一份稿子得出的结论。
                    if self.minutesResult != nil { self.transcriptChangedAfterMinutes = true }
                }
                if !outcome.warnings.isEmpty {
                    self.lastError = outcome.warnings.joined(separator: "\n")
                }
                // 走异步版：转写结束后磁盘状态变了要重扫，而重扫会碰 TCC 保护的目录。
                // 这里虽然已经在后台 Task 里，但 `self` 是 MainActor 隔离的，
                // 同步版会把 `open()` 又拉回主线程。
                await self.refreshAsync()
                // 自动清理的触发点之二：转写完成。
                //
                // 这个时机是三条触发点里最讲道理的一条——转写刚落地，
                // 满足「只清理已经转写过的会议」这条安全前提的场次最多。
                // 「今天跑过了吗」保证它不会与启动那次重复删。
                await self.runAutoPruneAfterTranscriptionAsync()
            } catch {
                Task { @MainActor in
                    // 失败也按 id 落：切走之后 A 失败了，切回来要看到失败原因，
                    // 而不是一个干干净净的「开始转写」按钮——那会让人以为
                    // 从没点过。`lastError` 仍只在还选中这一场时写，
                    // 否则会弹一条与当前会议无关的提示。
                    guard let self else { return }
                    self.transcriptPhases[id] = .failed("\(error)")
                    if self.selectedID == id {
                        self.lastError = "\(error)"
                    }
                }
            }
        }
    }

    // MARK: - 纪要

    /// 为当前选中的会议生成纪要。
    ///
    /// 与 `runTranscription` 同构：按 ID 存相位、切走不丢、失败按 ID 落。
    /// 生成器由 `MinutesGeneratorResolver` 按**当前偏好**现取——
    /// 用户在设置面板里刚把 provider 改成 api 并填完三项，下一次点这里
    /// 立刻走云端，不需要重启（与引擎「每次转写现取」同一理由）。
    ///
    /// 云端配置不齐时：**在调 MinutesService 之前就失败**。那一步任何文件
    /// 都不会写，与 CLI 同一条纪律（用户选了云端却拿到本地产物，是谎报）。
    public func runMinutes() {
        guard let id = selectedID else { return }
        guard minutesPhases[id]?.isRunning != true else { return }
        guard transcript != nil else {
            minutesPhases[id] = .failed("这场会议还没有转写稿，请先转写。")
            return
        }

        let generator: any MinutesGenerator
        switch MinutesGeneratorResolver.resolve(preferences: preferences) {
        case let .ready(resolved):
            generator = resolved
        case let .blocked(reason):
            minutesPhases[id] = .failed(reason)
            lastError = reason
            return
        }

        minutesPhases[id] = .running(summary: "正在生成纪要…")
        lastError = nil

        let store = library.store
        Task { [weak self, generator] in
            do {
                let outcome = try await MinutesService(store: store)
                    .generate(sessionID: id, generator: generator)
                guard let self else { return }
                self.minutesPhases[id] = .done(generatorName: outcome.result.generatorName)
                // 只在还选中这一场时填内容——切走后到达的结果填进去，
                // 会让另一场的详情区显示这一场的纪要。
                if self.selectedID == id {
                    self.minutesResult = outcome.result
                    // 纪要刚刚读的就是眼下这份稿子，旧的提示必须立刻消失。
                    self.transcriptChangedAfterMinutes = false
                }
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    // 失败原因按 ID 落，与转写一致：切回来要看到为什么失败，
                    // 而不是一个干净的「生成纪要」按钮——那会让人以为从没点过。
                    self.minutesPhases[id] = .failed("\(error)")
                    if self.selectedID == id {
                        self.lastError = "\(error)"
                    }
                }
            }
        }
    }

    /// 在访达里显示这场会议的纪要文件（存在才指得出来）。
    public func revealMinutes(sessionID id: String) {
        let url = library.store.directory(forSessionID: id)
            .appendingPathComponent(MinutesService.minutesMarkdownName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspaceOpener.open(url)
    }

    private static func describe(_ event: SessionTranscriber.Progress) -> String {        switch event {
        case .engineReady:
            return "引擎就绪，正在对齐时间轴…"
        case let .trackStarted(id, displayName, index, total):
            return "正在转写第 \(index)/\(total) 条轨：\(id)（\(displayName)）"
        case let .segmentStarted(_, index, total, _, _):
            return "第 \(index)/\(total) 段…"
        case let .trackFinished(_, displayName, count, _, _, _):
            return "\(displayName) 轨完成，\(count) 段"
        case let .trackFailed(_, displayName, _):
            return "\(displayName) 轨失败"
        case let .trackSkipped(id, _):
            return "跳过 \(id)"
        case .aligned:
            return "按 hostTime 对齐时间轴…"
        case let .finished(count):
            return "完成，共 \(count) 段"
        }
    }

    // MARK: - 导出

    /// 把转写稿另存到用户选择的位置。返回实际写入的路径。
    ///
    /// 做成「另存一份」而不是「移动」：会议目录里的稿子是原始产物，
    /// 用户可以随时重新导出一份到桌面或邮件附件，原稿不该被搬走。
    @discardableResult
    public func exportTranscript(to destination: URL, format: ExportFormat) throws -> URL {
        guard let document = transcript else {
            throw MRError.io(path: destination.path, reason: "这场会议还没有转写稿")
        }
        let data: Data
        switch format {
        case .markdown: data = Data(document.markdown().utf8)
        case .plainText: data = Data(document.plainText().utf8)
        case .json: data = try document.json()
        }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw MRError.io(path: destination.path,
                             reason: "写入失败：\(error.localizedDescription)")
        }
        return destination
    }

    /// 导出失败不抛给界面，转成 `lastError` 弹一次提示。
    /// 界面层不应该处理文件系统错误——那是这一层的职责。
    public func exportTranscriptSafe(to destination: URL, format: ExportFormat) {
        do {
            try exportTranscript(to: destination, format: format)
        } catch {
            lastError = "导出失败：\(error)"
        }
    }

    // MARK: - 保留策略

    /// 清理器。抽成计算属性，与 `transcriber` 同一理由：
    /// 保留档位可随时改，构造时定死一个实例会让改了不生效。
    public var retentionCleaner: SessionRetentionCleaner {
        SessionRetentionCleaner(store: library.store)
    }

    /// 清理前的账。界面用它显示「会删掉什么」，一个字节都不写。
    public func retentionPlan(includeUntranscribed: Bool = false) throws
        -> SessionRetentionCleaner.Plan {
        try retentionCleaner.plan(policy: retentionPolicy,
                                  includeUntranscribed: includeUntranscribed)
    }

    /// 读失败时返回 nil 并把原因写进 `lastError`——界面层不该处理文件系统错误。
    public func retentionPlanSafe(includeUntranscribed: Bool = false)
        -> SessionRetentionCleaner.Plan? {
        do {
            return try retentionPlan(includeUntranscribed: includeUntranscribed)
        } catch {
            lastError = "读取会议库失败：\(error)"
            return nil
        }
    }

    /// 执行清理。
    ///
    /// **绝不在设置档位时自动调用。** 改一个下拉框的期望是「以后按这个规则办」，
    /// 不是「帮我清一批」；而且用户多半不是在用这个功能时顺手改它的。
    @discardableResult
    public func pruneOldAudio(includeUntranscribed: Bool = false,
                              dryRun: Bool = false) throws -> SessionRetentionCleaner.Outcome {
        let outcome = try retentionCleaner.run(policy: retentionPolicy,
                                                includeUntranscribed: includeUntranscribed,
                                                dryRun: dryRun)
        // 清单要刷新：被清理的场次现在 `existingTrackCount == 0`，
        // 不刷新的话列表上仍显示「2 轨」，点开才发现没声音。
        if !dryRun && !outcome.deleted.isEmpty {
            refresh()
        }
        return outcome
    }

    /// 清理失败不抛给界面，转成 `lastError`。
    @discardableResult
    public func pruneOldAudioSafe(includeUntranscribed: Bool = false,
                                  dryRun: Bool = false)
        -> SessionRetentionCleaner.Outcome? {
        do {
            return try pruneOldAudio(includeUntranscribed: includeUntranscribed, dryRun: dryRun)
        } catch {
            lastError = "清理失败：\(error)"
            return nil
        }
    }

    // MARK: - 自动清理

    /// 自动清理器。与 `retentionCleaner` 同一理由做成计算属性：
    /// 档位与开关都能随时改，构造时定死一个实例会让改了不生效。
    public var autoPruner: RetentionAutoPruner {
        RetentionAutoPruner(cleaner: retentionCleaner, preferences: preferences)
    }

    /// 跑一次自动清理。**至多删一场都不多删**，判据见 `RetentionAutoPruner`。
    ///
    /// 触发点有三个（启动应用、录完一场、转写完成），它们都调这里。
    /// 「今天跑过了吗」那道闸保证同一天最多真删一次。
    ///
    /// 返回 `nil` 表示这次什么都没做。**删除时不弹窗**——
    /// 自动清理不该在用户正在做别的事时抢注意力；要做的事只有一件：
    /// 把结果记进 `lastAutoPruneReport`，由界面择机显示。
    @discardableResult
    public func runAutoPruneIfDue() -> SessionRetentionCleaner.Outcome? {
        let attempt = autoPruner.runIfDue()
        lastAutoPruneReport = RetentionAutoPruner.report(for: attempt)
        guard attempt.didRun, let outcome = attempt.outcome else { return nil }
        if !outcome.deleted.isEmpty {
            // 清单要刷新，理由与 `pruneOldAudio` 相同：
            // 被清理的场次现在 `existingTrackCount == 0`，不刷新列表仍显示「2 轨」。
            refresh()
        }
        return outcome
    }

    /// 转写完成后的那个触发点。走异步版，理由与 `refreshAsync` 相同：
    /// 它要重扫 TCC 保护的目录，同步版会把 `open()` 拉回主线程。
    ///
    /// 单独抽一个方法而不是让调用方记得配对，是为了让
    /// 「磁盘操作在后台、属性在 MainActor 上更新」这件事只有一处写法。
    private func runAutoPruneAfterTranscriptionAsync() async {
        await runAutoPruneInBackground()
    }

    /// 录完一场后的那个触发点。走异步版，理由同上。
    private func runAutoPruneAfterRecordingAsync() async {
        // 刚录完的这一场**必然不该被清**：它的 `startedAt` 就是现在，
        // 而任何天数档都要求「够 N 天」。这一层检查是为了让「刚录的会议不会被
        // 同一次触发点里别的原因误伤」这件事不必依赖档位实现的正确性——
        // 自动路径上没有人在场看。
        await runAutoPruneInBackground()
    }

    /// 在后台跑一次自动清理，磁盘 IO 全不占主线程。
    private func runAutoPruneInBackground() async {
        // **在离开主 actor 之前把值取出来。** `autoPruner` 与 `preferences`
        // 都是 MainActor 隔离的，在 detached 闭包里读会编译不过；
        // 更重要的是它是 struct（只持有 store 与偏好），跨线程传值安全，
        // 而闭包里捕获 `self` 则会把整个工作区拖进后台——那不是我们要的。
        let pruner = autoPruner
        let ids = await Task.detached(priority: .utility) {
            let attempt = pruner.runIfDue()
            return (attempt.outcome?.deleted.map(\.sessionID) ?? [],
                    RetentionAutoPruner.report(for: attempt))
        }.value
        lastAutoPruneReport = ids.1
        guard !ids.0.isEmpty else { return }
        await refreshAsync()
    }

    // MARK: - 合并音轨

    /// 合并两轨成一个可播放的文件，返回写出的路径。
    ///
    /// 编排复用 `SessionAudioExporter`——与 CLI 的 `mr merge` 是**同一份代码**，
    /// 所以界面里导出的文件与命令行导出的必然一致（偏移算法、降混策略、
    /// 「有一轨是静音」的判据全都不重复实现）。
    @discardableResult
    public func mergeTracks(sessionID: String,
                            to destination: URL,
                            mode: AudioTrackMerger.Mode = .stereoSplit,
                            format: AudioTrackMerger.OutputFormat = .pcm16) throws -> URL {
        try SessionAudioExporter(store: library.store).merge(
            sessionID: sessionID, mode: mode, format: format,
            destination: destination, overwrite: true).destination
    }

    /// 合并失败不抛给界面，转成 `lastError`。
    public func mergeTracksSafe(sessionID: String,
                                to destination: URL,
                                mode: AudioTrackMerger.Mode = .stereoSplit,
                                format: AudioTrackMerger.OutputFormat = .pcm16) {
        do {
            try mergeTracks(sessionID: sessionID, to: destination,
                            mode: mode, format: format)
        } catch {
            lastError = "合并失败：\(error)"
        }
    }

    /// 合并前的账。界面用它来显示「将要发生什么」，一个字节都不写。
    public func mergePlan(sessionID: String,
                          mode: AudioTrackMerger.Mode = .stereoSplit,
                          format: AudioTrackMerger.OutputFormat = .pcm16) throws
        -> SessionAudioExporter.Plan {
        try SessionAudioExporter(store: library.store)
            .plan(sessionID: sessionID, mode: mode, format: format)
    }

    public enum ExportFormat: String, CaseIterable {
        case markdown
        case plainText
        case json

        public var displayName: String {
            switch self {
            case .markdown: return "Markdown（.md）"
            case .plainText: return "纯文本（.txt）"
            case .json: return "结构化 JSON"
            }
        }

        public var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .plainText: return "txt"
            case .json: return "json"
            }
        }
    }
}

/// 后台扫描的结果快照。
///
/// 用一个独立的 `Sendable` 值承载，而不是让后台任务直接写 view model 的属性——
/// 那样就必须跨域传递 `self`。返回值搬运比共享可变状态安全得多。
private struct LibrarySnapshot: Sendable {
    var access: SessionLibrary.Access
    var meetings: [MeetingSummary]
}

private struct DetailSnapshot: Sendable {
    var manifest: RecordingManifest?
    var transcript: TranscriptDocument?
    /// 盘上真的有文件的轨 id。见 `MeetingWorkspace.availableTrackIDs`。
    var existingTrackIDs: Set<String> = []
    /// 已生成的纪要（`minutes.json`）。没有则 nil。
    var minutes: MinutesResult?
    /// 转写稿比纪要新（＝纪要基于旧稿）。见 `MeetingWorkspace.transcriptChangedAfterMinutes`。
    var transcriptChangedAfterMinutes: Bool = false
}

/// 极薄的封装，只为让 `MeetingWorkspace` 不直接依赖 AppKit。
///
/// 这样这个类型在无头测试环境里也能编译（AppKit 在命令行测试进程里可用，
/// 但把 UI 依赖挡在外面能让意图更清楚）。
enum NSWorkspaceOpener {
    static func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}
