import Foundation
import CoreAudio
import MRCore

/// 双轨录制协调器。
///
/// 同时跑两条独立链路：
/// - `mic`    → 本机麦克风（**我**）
/// - `system` → 系统音频 Process Tap（**对方**）
///
/// 这个设计最聪明的一手是：**音轨本身即说话人身份**。把「谁在说」这个最难的问题
/// （说话人分离）直接绕过去了，而且两人同时说话也不丢——任何声纹分离方案都做不到这点。
///
/// **启动顺序很关键**：系统音频 tap（含聚合设备）的**准备**明显慢于麦克风
/// （建 tap + 聚合设备约 0.1 秒，而单个 IOProc 启动只要约 0.01 秒）。
/// 若按「先开麦克风、再建 tap」的直觉顺序写，两轨会错开这段时间——会议开头那一段
/// 就只有单边。所以这里分两阶段：先把慢资源全部准备好，再连续启动两条轨。
///
/// **注意不要在这两步之间对聚合设备做「预热」**（启动一次、停掉、再正式启动）。
/// 对纯 tap 聚合设备执行 stop 后再 start，第二轮会静默采到全零——帧数完全正常、
/// 没有任何报错，只有内容是空的。而它想省的「冷启动开销」实测只有 9 毫秒。
/// 零收益 + 确定性的破坏，详见 `SystemAudioTap` 类末尾的完整实验。
public final class DualTrackRecorder {

    public struct Configuration {
        /// 锁定使用的输入设备 UID。为空则用系统默认输入。
        /// 某些机器上存在「iPhone」连续互通麦克风，默认输入可能被切走，建议显式锁定。
        public var preferredInputUID: String?
        /// 系统音频是否排除本进程（避免把自己的提示音录进去）
        public var systemAudioExcludesSelf: Bool
        /// WAV 采样格式。**`nil` = 我没有意见，由上层决定。**
        ///
        /// 这是可选的唯一理由：非可选类型无法区分「我明确要 float32」和「我没表态」。
        /// 上层（`MeetingWorkspace`）只在调用方没表态时才用偏好兜底——
        /// 若这里写死成非可选，调用方显式指定的格式与「默认值」在类型上就分不开，
        /// 于是任何一层想要「尊重调用方」都做不到。
        /// 默认值（`.float32`）只在真正开始录制时于 `DualTrackRecorder.start` 里落地一处。
        public var sampleFormat: WAVSampleFormat?

        /// 解析后的格式：`nil`（调用方没表态）落到 32 位浮点无损。
        ///
        /// 默认值挂在类型上，而不是散在 `start()` 里写一个 `??`：`start()` 要真的开设备、
        /// 跑实时回调，是本模块**唯一一条没有任何自动化用例能覆盖**的路径（GUI 走假引擎、
        /// CLI 只测纯函数、真机用例默认跳过）。放在这里，「nil 到底落到哪个格式」才有得测——
        /// 它是「默认不能悄悄降质量」的最后一道。
        var resolvedSampleFormat: WAVSampleFormat { sampleFormat ?? .float32 }

        /// 是否把录音降成**单声道 + 24 kHz**。
        ///
        /// **单独开这一项**约合现状的 1/3（1978 → 659 MiB/小时）；**再叠加「16 位」**才约合
        /// 1/6（→ 330 MiB/小时）。口径与 `MeetingWorkspace.mono24kRecording`、
        /// `RecorderPreferences.mono24kRecording` 逐字一致——三处各说各话的话，
        /// 将来谁写对外文案都可能抄错。
        ///
        /// 与 `sampleFormat` 同一套语义：**`nil` = 我没有意见，由上层决定**。
        /// 分成「可选 + 一处解析」而不是直接给 `Bool = false`，理由与位深完全一样——
        /// 非可选类型分不开「我明确要全带宽」和「我没表态」，
        /// 于是上层想「调用方显式指定就尊重他」时根本做不到。
        public var mono24k: Bool?

        /// 解析后的开关：`nil`（调用方没表态）落到 **false**，也就是保持源格式不动。
        ///
        /// 与 `resolvedSampleFormat` 同一条纪律：**默认不能悄悄降质量**。
        /// 这个值比位深更进一步——它同时决定文件的**声道数与采样率**，
        /// 一旦默认打开，用户拿到的是另一副形态的录音，而已经录完的那些补不回来。
        ///
        /// 之所以是 `public` 而 `resolvedSampleFormat` 不是：命令行要在**开录之前**
        /// 把「这一场会录成什么」打出来，而 CLI 是独立模块。让它自己写一遍
        /// `?? false` 就等于把这个默认值复制成两份，改一处必漏一处。
        public var resolvedMono24k: Bool { mono24k ?? false }

        /// 多声道降成单声道时用哪种策略。**`nil` = 我没有意见，由上层决定。**
        ///
        /// 与 `sampleFormat` / `mono24k` 同一套语义。源本来就是单声道时降混不发生，
        /// 这个值也就无意义——但**必须留着这个入口**：本机系统音频 tap 给的是
        /// 2 声道，`mono24k` 一开就必然走降混，而两种策略的差别有 6 dB
        /// 甚至「整轨抵消成静音」那么大（见 `MonoDownmixStrategy`）。
        public var downmix: MonoDownmixStrategy?

        /// 解析后的策略：`nil`（调用方没表态）落到 `.firstChannel`。
        ///
        /// 与上面两个 `resolved*` 同一条纪律——**默认值只有一处**。
        /// 散在各处写 `?? .firstChannel` 等于把这个决定复制成若干份，
        /// 将来改默认值必漏一处，而漏掉那处的后果是「有的轨按新策略、有的按旧策略」。
        public var resolvedDownmix: MonoDownmixStrategy { downmix ?? .firstChannel }

        /// 最长录制时长（秒），到时自动停止。防止忘记停导致磁盘写满。
        public var maxDuration: Double?

        public init(
            preferredInputUID: String? = nil,
            systemAudioExcludesSelf: Bool = true,
            sampleFormat: WAVSampleFormat? = nil,
            mono24k: Bool? = nil,
            downmix: MonoDownmixStrategy? = nil,
            maxDuration: Double? = nil
        ) {
            self.preferredInputUID = preferredInputUID
            self.systemAudioExcludesSelf = systemAudioExcludesSelf
            self.sampleFormat = sampleFormat
            self.mono24k = mono24k
            self.downmix = downmix
            self.maxDuration = maxDuration
        }
    }

    public struct Result {
        public var sessionID: String
        public var directory: URL
        public var manifest: RecordingManifest
        public var drift: DriftReport
        /// 录制期间发生的所有异常（设备降级、某轨启动失败、写入错误等）
        public var warnings: [String]
        /// 各轨累计静音秒数，键是轨 id。
        ///
        /// 与 manifest 里的 `pauses` 是同一个事实的两个视角：这里按轨汇总，
        /// 界面直接显示「我轨静音 2:10」；那里逐段记录，能定位到具体位置。
        /// 之所以还留一份在这里，是因为**未闭合的静音段不会进 manifest**
        /// （见 `closeOpenMute`），而用户仍然有权知道「我刚才掐掉了 40 秒」。
        public var mutedSecondsByTrack: [String: Double]

        /// 显式构造器。除了方便测试伪造一次录制结果，没有别的用途——
        /// 真机上这个值只由 `stop()` 产出。
        public init(
            sessionID: String,
            directory: URL,
            manifest: RecordingManifest,
            drift: DriftReport,
            warnings: [String] = [],
            mutedSecondsByTrack: [String: Double] = [:]
        ) {
            self.sessionID = sessionID
            self.directory = directory
            self.manifest = manifest
            self.drift = drift
            self.warnings = warnings
            self.mutedSecondsByTrack = mutedSecondsByTrack
        }
    }

    private struct MicrophonePlan {
        var device: AudioDeviceInfo
        var format: AudioStreamBasicDescription
        var warning: String?
    }

    private struct SystemPlan {
        var tap: SystemAudioTap
        var format: AudioStreamBasicDescription
    }

    public let store: SessionStore
    public let configuration: Configuration

    private var micRecorder: TrackRecorder?
    private var systemRecorder: TrackRecorder?
    private var tap: SystemAudioTap?
    /// 录制期周期性把进度写回 manifest 的定时器
    private var heartbeat: DispatchSourceTimer?

    private var sessionID = ""
    private var sessionDirectory: URL?
    /// 录制起点。`--seconds` 之类的时长控制应以它为基准。
    private var startedAt = Date()

    /// 暂停记录的锁。
    ///
    /// 必须加锁：`pause()` / `resume()` 从界面线程调，而 `checkpoint()` 跑在
    /// 后台定时器上，两边都会读写这两个字段。
    private let pauseLock = NSLock()
    private var pauses: [PauseSpan] = []
    /// 正在进行中的静音区间：轨 id → 开始时刻。`nil` 键表示全局暂停。
    ///
    /// 用字典而不是「一条全局记录」，是因为分轨静音允许两轨各自的区间重叠
    /// （我轨静音的同一段，对方轨可能正在录）。单条记录表达不了这种状态。
    private var openMutes: [String?: Date] = [:]

    /// 全局暂停**自己造成的**那些静音：轨 id 集合。
    ///
    /// **存在的原因**：`resume()` 不能无差别地把所有轨 unmute。
    /// 用户完全可能「手动静音了 mic → 按暂停 → 按继续」，
    /// 此时全局暂停只该撤销它自己加上的那部分（system），
    /// mic 的静音是用户自己的决定，必须留着。
    ///
    /// 反过来做（resume 时全解）会怎样：用户的 mic 静音意图被清空，
    /// 而界面上的菜单仍按 `@Published` 里的旧值显示「我 已静音」——
    /// **界面与引擎从此分叉**，下一次点暂停/继续就会在两个互相矛盾的真相之间摆，
    /// 表现就是「按了没反应、像卡死」。
    ///
    /// 记成集合而不是布尔量，是因为暂停与分轨静音可以任意交错：
    /// 「暂停 → 手动再关一轨 → 继续」时，那一轨也不该被恢复。
    private var muteAddedByGlobalPause: Set<String> = []

    public init(store: SessionStore, configuration: Configuration = Configuration()) {
        self.store = store
        self.configuration = configuration
    }

    public var isRecording: Bool {
    (micRecorder?.isRunning ?? false) || (systemRecorder?.isRunning ?? false)
}

/// 是否处于**全场**静音（等价旧版的「暂停」）。
    ///
    /// 判据是「全局暂停这件事在进行中」（`openMutes[nil]` 开着），
    /// 而**不是「所有已启动的轨都静音了」**。
    ///
    /// 后者看着等价、实则更糟：用户可以用「音轨」菜单把**两轨都**关掉，
    /// 此时 `allSatisfy(isMuting)` 为 true，但全局暂停**从未发生过**。
    /// 控制器于是把相位设成 `.paused`，而 `resume()` 因为「自己没加过静音」
    /// 返回 false —— `guard !engine.isPaused` 永远不成立，
    /// 状态机被永久钉在 `.paused`：**「继续」彻底失效，只剩停止能按。**
    /// 这正是用户报告的卡死。
    ///
    /// 「用户把两轨都手动关掉」与「按了暂停」是两种不同的状态，
    /// 界面上也应当显示得不同（前者菜单两项都打勾，后者显示「已暂停」）。
    public var isPaused: Bool {
        pauseLock.lock(); defer { pauseLock.unlock() }
        return openMutes[nil] != nil
    }

    // MARK: - 分轨静音

    /// 某一轨当前是否被静音。
    ///
    /// 用的是 **recorder 的真实状态**，不是「用户点过按钮」的记录。
    /// 两者会在一种情况下分叉：静音期间进程被杀又恢复，那条指令从来没落地，
    /// 而界面若按点击记录显示，就会声称「这一轨已静音」而实际在录——
    /// 用户以为掐掉了声音，实际全都录进去了。
    public func isMuted(trackID: String) -> Bool {
        recorder(for: trackID)?.isMuting ?? false
    }

    /// 全部轨的静音状态，键是轨 id（`mic` / `system`）。
    public var mutedTrackIDs: Set<String> {
        Set([micRecorder, systemRecorder].compactMap { $0 }
            .filter { $0.isMuting }.map(\.id))
    }

    /// 某一轨累计静音秒数。**不能拿它去减时长**（静音段仍占文件长度）。
    public func mutedSeconds(trackID: String) -> Double {
        recorder(for: trackID)?.mutedSeconds ?? 0
    }

    /// 静音 / 取消静音**某一轨**。
    ///
    /// 语义是「这一段留白」：该轨照常写文件，但这段内容是静音。
    /// 另一轨完全不受影响，继续正常录。
    ///
    /// 设备不关——与全局暂停同一条理由（见 `pause()`），
    /// 且系统音频的聚合设备反复 stop/start 有过「静默采到全零」的记录。
    ///
    /// **全局暂停期间调用同样有效，且必须被区别对待。**
    /// 那时这一轨已经因全局暂停而处于静音，用户再点「静音」在音频上
    /// 没有任何变化（`TrackRecorder.mute()` 会因状态未变返回 false），
    /// 但**意图变了**：从「暂停期间没录」变成「这一轨是我自己关的，暂停结束也要关」。
    /// 所以这里不能简单 `return false`，必须把这一轨从
    /// `muteAddedByGlobalPause` 里摘出去，让随后的 `resume()` 不再恢复它。
    ///
    /// - Returns: 是否发生了**意图**上的变化
    @discardableResult
    public func setMuted(_ muted: Bool, trackID: String) -> Bool {
        guard let target = recorder(for: trackID) else { return false }
        pauseLock.lock()
        let claimedByGlobalPause = muteAddedByGlobalPause.contains(trackID)
        pauseLock.unlock()

        let changed = muted ? target.mute() : target.unmute()

        if muted {
            pauseLock.lock()
            // 无论 `mute()` 有没有真的改变状态，都要摘掉「这是全局暂停造成的」标记。
            // 否则暂停期间手动关的轨会被随后的 `resume()` 恢复——用户明确要求它别录，
            // 而恢复后它又开始录，且界面上的菜单已经不再显示静音（分叉）。
            muteAddedByGlobalPause.remove(trackID)
            // 重复调用会被上面的 `mute()` 挡掉，这里不会把区间切碎
            openMutes[trackID] = openMutes[trackID] ?? Date()
            pauseLock.unlock()
            // `claimedByGlobalPause` 为真时，音频状态没变但意图变了，仍然算「生效」。
            return changed || claimedByGlobalPause
        }

        guard changed else { return false }
        pauseLock.lock()
        // 用**不加锁**的版本：这里已经持有 `pauseLock`，
        // 再进加锁版就是 `NSLock` 的重入 → 永久死锁（用户报的「第二次点卡死」）。
        closeOpenMuteLocked(trackID)
        pauseLock.unlock()
        return true
    }

    /// 切换某一轨的静音。
    /// - Returns: 切换后的状态
    @discardableResult
    public func toggleMute(trackID: String) -> Bool {
        let next = !isMuted(trackID: trackID)
        setMuted(next, trackID: trackID)
        return next
    }

    /// 按轨 id 取recorder。`nil` = 该轨没有启动（设备失败或这轮只录了单轨）。
    private func recorder(for trackID: String) -> TrackRecorder? {
        [micRecorder, systemRecorder].compactMap { $0 }
            .first { $0.id == trackID }
    }

    /// **仅供测试**：注入一条音轨，让 `setMuted` 走到真实的记账路径。
    ///
    /// 为什么需要它：`setMuted` 在没有已启动音轨时会于第一行
    /// `guard let target = recorder(for:)` 直接返回——**`closeOpenMute` 根本不会被调用**。
    /// 于是只构造 `DualTrackRecorder` 的测试会一路绿灯，却完全测不到
    /// 「已持有 `pauseLock` 时再进 `closeOpenMute`」这条死锁路径。
    ///
    /// 不把它做成 `public`：生产代码没有正当理由去替换音轨，
    /// 一旦公开，这条"仅供测试"的约定就名存实亡。
    func _testInjectTrackRecorder(_ recorder: TrackRecorder) {
        switch recorder.id {
        case "mic": micRecorder = recorder
        default: systemRecorder = recorder
        }
    }

    /// **仅供测试**：把某条音轨标记成"正在运行"。
    ///
    /// `TrackRecorder.mute()` 会检查 `state.running`，未启动的轨一律返回 false，
    /// 于是"静音→取消静音"这一步根本不会真的改变状态，也测不出语义。
    /// 直接改 running 可以在不碰 Core Audio 的前提下让这条路径成立。
    func _testMarkRunning(_ recorder: TrackRecorder) {
        recorder._testForceRunning()
    }

    public var sessionDirectoryURL: URL? { sessionDirectory }

    /// 自开始录制以来已经过去的秒数（**墙上时钟**，含暂停与准备阶段）。
    /// 准备系统音频 tap 可能要花上秒级（首次），定时停止必须扣掉这段，
    /// 否则用户设 16 秒会实际录到 18.8 秒。
    public var elapsed: Double { max(0, Date().timeIntervalSince(startedAt)) }

    /// 真正录到的秒数（**内容时长**，不含暂停，也不含准备阶段）。
    ///
    /// 取自音轨统计而不是 `elapsed` 减去暂停总长：后者把「准备设备的那几秒」
    /// 也算进去了，界面上的计时器会从 1 秒多开始跳。
    /// 取各轨最大值，单轨失败时另一样照常给数。
    public var recordedSeconds: Double {
        [micRecorder, systemRecorder].compactMap { $0 }.map(\.stats.clockDuration).max() ?? 0
    }

    /// 全局暂停总时长（秒），含正在进行中的这一次。**不含分轨静音。**
    ///
    /// 界面用它显示「已暂停」，所以口径必须与 `PauseSpan.trackID == nil`
    /// 的那些记录一致——否则会出现「暂停 0 秒」却显示已暂停。
    public var pausedTotal: Double {
        pauseLock.lock(); defer { pauseLock.unlock() }
        return pauses.reduce(0) { $0 + (($1.trackID == nil) ? max(0, $1.duration) : 0) }
            + (openMutes[nil].map { max(0, Date().timeIntervalSince($0)) } ?? 0)
    }

    // MARK: - 开始

    @discardableResult
    public func start(title: String) throws -> String {
        let (id, dir) = try store.createSession(title: title)
        sessionID = id
        sessionDirectory = dir
        startedAt = Date()
        // 格式在这里解析一次并用到底。**默认值（float32）的落点就是
        // `Configuration.resolvedSampleFormat` 这一处**——把它挂在类型上而不是
        // 在这里写一个 `??`，是因为这一行所在的 `start()` 要真开设备，无法被单测覆盖。
        let format = configuration.resolvedSampleFormat
        let mono24k = configuration.resolvedMono24k
        let downmix = configuration.resolvedDownmix
        // 同一个实例被复用开第二场时，上一场的静音记录必须清干净
        pauseLock.lock()
        pauses = []
        openMutes = [:]
        muteAddedByGlobalPause = []
        pauseLock.unlock()

        var tracks: [TrackManifest] = []
        var warnings: [String] = []

        // ── 阶段 1：准备慢资源（tap 创建可能要秒级，全部前置）──────
        let micPlan = prepareMicrophone(warnings: &warnings)
        let systemPlan = prepareSystemAudio(warnings: &warnings)

        // ── 阶段 2：创建录制器（只建对象，不启动）──────────────────
        // 注意这里**没有**「预热聚合设备」这一步，尽管代码历史上曾经有。
        // 那个预热会在同一聚合设备上 stop 后再 start，导致正式录制采到全零。
        // 且它想省下的「1.6 秒冷启动」经复测只有 9 毫秒，收益本来就是零。
        // 完整实验与结论见 SystemAudioTap 类末尾的注释。
        var micRecorder: TrackRecorder?
        if let plan = micPlan {
            let write = Self.writeFormat(for: plan.format, mono24k: mono24k)
            do {
                micRecorder = try TrackRecorder(
                    id: "mic", role: .microphone,
                    deviceID: plan.device.id, deviceName: plan.device.displayName,
                    fileURL: dir.appendingPathComponent("mic.wav"),
                    sourceSampleRate: plan.format.mSampleRate,
                    sourceChannels: Int(plan.format.mChannelsPerFrame),
                    sourceIsInterleaved: !AudioDevices.isNonInterleaved(plan.format),
                    writeSampleRate: write.sampleRate,
                    writeChannels: write.channels,
                    format: format,
                    downmixStrategy: downmix)
            } catch {
                warnings.append("麦克风轨初始化失败：\(error)")
            }
        }

        var systemRecorder: TrackRecorder?
        if let plan = systemPlan {
            let write = Self.writeFormat(for: plan.format, mono24k: mono24k)
            do {
                systemRecorder = try TrackRecorder(
                    id: "system", role: .systemAudio,
                    deviceID: plan.tap.aggregateDeviceID,
                    deviceName: "系统音频输出",
                    fileURL: dir.appendingPathComponent("system.wav"),
                    sourceSampleRate: plan.format.mSampleRate,
                    sourceChannels: Int(plan.format.mChannelsPerFrame),
                    sourceIsInterleaved: !AudioDevices.isNonInterleaved(plan.format),
                    writeSampleRate: write.sampleRate,
                    writeChannels: write.channels,
                    format: format,
                    downmixStrategy: downmix)
            } catch {
                warnings.append("系统音频轨初始化失败：\(error)")
            }
        }

        // ── 阶段 3：连续启动，把两轨起始偏差压到毫秒级 ──────────────
        if let recorder = micRecorder, let plan = micPlan {
            do {
                try recorder.start()
                self.micRecorder = recorder
                // manifest 的格式**直接取自 recorder**，不在这里重算一遍：
                // 重算就要保证「这里的公式」与「recorder 内部用的公式」永远一致，
                // 而路径上任何一处不变量都会表现为「manifest 说 48k、文件其实是 24k」，
                // 也就是界面时长差一倍——没有任何地方会报错。
                tracks.append(TrackManifest(
                    id: "mic", role: .microphone, fileName: "mic.wav",
                    sampleRate: recorder.writeFormat.sampleRate,
                    channels: recorder.writeFormat.channels,
                    sampleFormat: format,
                    deviceUID: plan.device.uid, deviceName: plan.device.displayName,
                    warnings: plan.warning.map { [$0] } ?? []))
            } catch {
                warnings.append("麦克风轨启动失败：\(error)")
            }
        }

        if let recorder = systemRecorder {
            do {
                try recorder.start()
                self.systemRecorder = recorder
                if systemPlan != nil {
                    tracks.append(TrackManifest(
                        id: "system", role: .systemAudio, fileName: "system.wav",
                        sampleRate: recorder.writeFormat.sampleRate,
                        channels: recorder.writeFormat.channels,
                        sampleFormat: format,
                        deviceUID: nil, deviceName: "系统音频输出"))
                }
            } catch {
                warnings.append("系统音频轨启动失败：\(error)")
            }
        }

        guard !tracks.isEmpty else {
            tap?.destroy()
            tap = nil
            // 把两次启动的失败原因一起抛出。只说「没有输入设备」无法区分
            // 权限未授予 / HAL 未响应 / 设备被连续互通切走——这三种的处置完全不同。
            throw MRError.captureFailed(reasons: warnings)
        }

        var manifest = RecordingManifest(
            sessionID: id, title: title, startedAt: startedAt,
            state: .recording, tracks: tracks)
        manifest.notes = warnings
        try store.save(manifest, sessionDirectory: dir)

        startCheckpointing()
        return id
    }

    // MARK: - 录制期持续落盘

    /// 每 5 秒把当前进度写回 manifest。
    ///
    /// 这不是可选优化：崩溃恢复要能算出「录了多久」，就得知道音轨的 hostTime 跨度。
    /// 只在停止时写回的话，进程被杀时这些字段全是 0，恢复出来的时长就无从判断。
    private func startCheckpointing(interval: TimeInterval = 5) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.checkpoint() }
        timer.resume()
        heartbeat = timer
    }

    private func checkpoint() {
        guard let dir = sessionDirectory, isRecording else { return }
        guard var manifest = try? store.loadManifest(sessionDirectory: dir) else { return }
        guard manifest.state == .recording else { return }

        for i in manifest.tracks.indices {
            guard let recorder = [micRecorder, systemRecorder]
                .compactMap({ $0 })
                .first(where: { $0.id == manifest.tracks[i].id }) else { continue }
            let stats = recorder.stats
            guard stats.frames > 0 else { continue }
            // 帧数取**文件真实帧数**（`recorder.framesWritten`）而不是 `stats.frames`。
            // 两者在正常录制时严格相等；只有在 `WAVWriter` 触顶之后才会分叉——
            // 触顶后数据被丢弃、文件不再变长，而 `stats` 仍在同一把锁里照旧累计，
            // 于是 manifest 的帧数（以及由它算出的 duration）会超过音频真实长度。
            // 用文件帧数就顺手把这件事纠正了，且不改变任何正常路径的行为。
            manifest.tracks[i].framesWritten = recorder.framesWritten
            manifest.tracks[i].firstHostTime = stats.firstHostTime
            manifest.tracks[i].lastHostTime = stats.lastHostTime
        }
        // 静音记录也要签到。签到只写 manifest 的这几个字段，进程被杀时
        // 已闭合的记录会留在盘上；否则恢复出来的那场会议看不出「中间有一段是静音的」，
        // 听的人只会以为那段时间真的没人说话。
        manifest.pauses = closedPauses()
        try? store.save(manifest, sessionDirectory: dir)
    }

    // MARK: - 阶段 1 的两个准备动作

    /// 一条轨的写入格式（源格式 + 开关 → 文件格式）。
    ///
    /// 调到与 `TrackRecorder` 内部**同一个纯函数** `TrackWriteFormat.resolve`，
    /// 所以这里传进去的值与它自己算出来的不可能不一致。
    static func writeFormat(
        for format: AudioStreamBasicDescription, mono24k: Bool
    ) -> TrackWriteFormat {
        TrackWriteFormat.resolve(
            sourceSampleRate: format.mSampleRate,
            sourceChannels: Int(format.mChannelsPerFrame),
            mono24k: mono24k)
    }

    private func prepareMicrophone(warnings: inout [String]) -> MicrophonePlan? {
        do {
            let resolved = try AudioDevices.resolveInput(preferredUID: configuration.preferredInputUID)
            if let w = resolved.warning { warnings.append(w) }

            guard let fmt = AudioDevices.inputStreamFormat(deviceID: resolved.device.id),
                  fmt.mSampleRate > 0, fmt.mChannelsPerFrame > 0 else {
                warnings.append("无法读取麦克风「\(resolved.device.displayName)」的流格式，麦克风轨已跳过")
                return nil
            }
            guard AudioDevices.isFloat(fmt) else {
                warnings.append("麦克风「\(resolved.device.displayName)」非浮点格式"
                    + "（bits=\(fmt.mBitsPerChannel)），麦克风轨已跳过")
                return nil
            }
            return MicrophonePlan(device: resolved.device, format: fmt, warning: resolved.warning)
        } catch {
            warnings.append("麦克风准备失败：\(error)")
            return nil
        }
    }

    private func prepareSystemAudio(warnings: inout [String]) -> SystemPlan? {
        do {
            let created = try SystemAudioTap.create(
                name: "meeting-recorder-\(sessionID.isEmpty ? "session" : sessionID)",
                excludingCurrentProcess: configuration.systemAudioExcludesSelf)

            guard let fmt = AudioDevices.inputStreamFormat(deviceID: created.aggregateDeviceID),
                  fmt.mSampleRate > 0, fmt.mChannelsPerFrame > 0 else {
                warnings.append("系统音频 tap 的流格式不可读，系统音频轨已跳过")
                created.destroy()
                return nil
            }
            tap = created
            return SystemPlan(tap: created, format: fmt)
        } catch {
            warnings.append(
                "系统音频轨准备失败：\(error)　"
                + "（若提示权限，请到「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」授权本程序）")
            return nil
        }
    }

    // MARK: - 暂停 / 继续

    /// 暂停录制（**全局**：两轨一起停）。
    ///
    /// **实现上就是「两轨都静音」**——走 `mute()` 而不是 `TrackRecorder.pause()`。
    ///
    /// 这一点是**必须统一**的，不是风格选择：分轨静音写静音帧（文件等长），
    /// 若全局暂停仍丢弃数据（文件变短），同一场会议里就会出现
    /// 「暂停过的那一段之后，两轨长度不再一致」——而双轨回放与按轨对齐的转写
    /// 正是建立在"两轨时间轴同源"上的，破坏它等于把分轨静音刚解决的问题又请回来。
    ///
    /// 设备本身不关——`AudioDeviceStop` 再启动整条链路要重来一遍，实测代价远超收益，
    /// 而且系统音频的聚合设备反复 stop/start 有过「静默采到全零」的记录。
    /// 所以这里是「采集照跑、数据替换成静音」。
    ///
    /// - Returns: 是否真的切换了状态
    @discardableResult
    public func pause() -> Bool {
        var changed = false
        var addedByThisPause: Set<String> = []
        for recorder in [micRecorder, systemRecorder].compactMap({ $0 }) {
            // `mute()` 只在「从非静音变成静音」时返回 true，
            // 所以它天然区分了「这一轨原本就是静音的」（用户自己关的）与
            // 「这一轨原本在录」（被全局暂停掐掉的）——后者才需要被 resume 恢复。
            if recorder.mute() {
                changed = true
                addedByThisPause.insert(recorder.id)
            }
        }
        guard changed else { return false }
        pauseLock.lock()
        // 只在第一次暂停时开区间，重复调用不会把区间切碎
        openMutes[nil] = openMutes[nil] ?? Date()
        // 累加而不是覆盖：用户在暂停期间又手动关了一轨时，
        // 那一次的意图不该被这一轮的全局暂停「认领」。
        muteAddedByGlobalPause.formUnion(addedByThisPause)
        pauseLock.unlock()
        return true
    }

    /// 从暂停恢复。
    ///
    /// **只撤销全局暂停自己加上的静音**（见 `muteAddedByGlobalPause`），
    /// 用户手动关掉的轨保持静音。全解会让界面与引擎状态分叉，
    /// 表现为「继续之后按暂停没反应」。
    ///
    /// - Returns: 是否真的切换了状态
    @discardableResult
    public func resume() -> Bool {
        pauseLock.lock()
        let toRestore = muteAddedByGlobalPause
        guard !toRestore.isEmpty else {
            pauseLock.unlock()
            return false
        }
        muteAddedByGlobalPause.removeAll()
        pauseLock.unlock()

        var changed = false
        for recorder in [micRecorder, systemRecorder].compactMap({ $0 }) {
            guard toRestore.contains(recorder.id) else { continue }
            if recorder.unmute() { changed = true }
        }
        guard changed else { return false }
        pauseLock.lock()
        // 同 `setMuted`：此处已持锁，必须走不加锁的版本。
        closeOpenMuteLocked(nil)
        pauseLock.unlock()
        return true
    }

    /// 没有暂停就暂停，正在暂停就继续。
    @discardableResult
    public func togglePause() -> Bool {
        isPaused ? resume() : pause()
    }

    /// 收尾某一次静音，把它落成一条记录。
    ///
    /// **只在「静音 → 取消静音」时调用，停止时不调。**
    /// `pauses` 里每条记录都对应音频里一段真实的留白（全局则是全轨静音段）。
    /// 而「静音之后直接停止」不产生可标注的区间——音频就是在那里结束的，
    /// 再记一条只会让时长计算把这段时间**重复扣一次**。
    /// 所以未闭合的静音（`openMutes` 里的项）在停止时直接丢弃。
    ///
    /// ⚠️ **本方法假定调用方已持有 `pauseLock`。**
    /// 它自己**不再加锁**——`NSLock` 不可重入，而 `setMuted` / `resume()`
    /// 都会在**已持锁**的状态下调用它。此处若再 `lock()` 就是**永久死锁**：
    /// 主线程静默挂起，界面表现为「点第二次就卡死」，且没有任何报错。
    /// 这正是用户报的那一条。
    private func closeOpenMuteLocked(_ key: String?) {
        guard let open = openMutes.removeValue(forKey: key) else { return }
        let span = PauseSpan(
            startedAfter: open.timeIntervalSince(startedAt),
            duration: Date().timeIntervalSince(open),
            trackID: key)
        // 不足 1 毫秒的抖动不值得记：误按一下再按回来不该在会议里留记录
        if span.duration >= 0.001 { pauses.append(span) }
    }

    /// **刻意不提供加锁版。**
    ///
    /// 写过又删掉了：它看起来是"方便"的封装，但 `setMuted` / `resume()`
    /// 都已经持有 `pauseLock`，谁哪天顺手用了它就是一次静默死锁。
    /// 少一个入口，就少一条能让它错的路。

    /// 已经**闭合**的静音列表（只读快照）
    private func closedPauses() -> [PauseSpan] {
        pauseLock.lock(); defer { pauseLock.unlock() }
        return pauses.sorted { $0.startedAfter < $1.startedAfter }
    }

    // MARK: - 停止

    @discardableResult
    public func stop() throws -> Result {
        heartbeat?.cancel()
        heartbeat = nil
        // 只落**已闭合**的静音记录。收到这里的这次静音（如果有）意味着用户静音后
        // 直接停了录制——音频就在那里结束，不该再记一条。见 `closeOpenMute` 的说明。
        let pauses = closedPauses()

        guard let dir = sessionDirectory else {
            throw MRError.io(path: store.root.path, reason: "尚未开始录制，无法停止")
        }

        var warnings: [String] = []
        var driftTracks: [DriftReport.Track] = []

        for recorder in [micRecorder, systemRecorder].compactMap({ $0 }) {
            // **不能 `try?` 吞掉。** 收尾失败最典型的后果是「文件头没回填、`dataSize` 为 0」：
            // 音频字节都在盘上，但 WAVReader / 播放器 / 波形 / 转写会一律读成空轨，
            // 而这里给调用方报的是「录制完成」。静默吞掉就等于交出一份
            // 「看起来成功、实际打不开」的录音，而且恢复流程只扫 `state == .recording`
            // 的会话，这个会话收尾时已被标成 finalized，**永远没有人会来修它**。
            // (`TrackRecorder.stop()` 内部已就地兜一次 `repairHeader`，这里负责把
            //  「兜底也没成功」这件事说出去。)
            do {
                _ = try recorder.stop()
            } catch {
                warnings.append(
                    "音轨 \(recorder.id) 收尾失败：\(error.localizedDescription)"
                    + "（音频数据已落盘，但文件头可能没回填，该轨可能被读成空轨）")
            }
            warnings.append(contentsOf: recorder.warnings)

            if recorder.missingTimestampBuffers > 0 {
                warnings.append(
                    "音轨 \(recorder.id) 有 \(recorder.missingTimestampBuffers) 个缓冲区未提供时间戳，"
                    + "时间轴精度可能下降")
            }
            driftTracks.append(DriftReport.Track(id: recorder.id, stats: recorder.stats))
        }

        // 收尾自检：揪出「录到了但内容是空的」。
        //
        // 这一步必须在停止的那一刻做。授权未生效时录制会正常完成——
        // 时长对、帧数对、manifest 写着 finalized、退出码 0，只有采样全是零。
        // 不说出来的话，使用者要等到回听或转写出空文稿才发现，那时会议已经结束了。
        //
        // `cancelledTrackIDs` 来自 recorder 自己记录的降混抵消：那一轨的「全零」
        // 原因已经查明，交给 `RecordingSanity` 出**准确**的那条告警。
        // 不传的话会额外冒出一条「可能是权限未生效」——实测踩过：
        // 反相内容被 average 抵消后同时收到两条告警，把人引去查权限（明明没问题）。
        let cancelledTrackIDs = Set(
            [micRecorder, systemRecorder].compactMap { $0 }
                .filter { $0.phaseCancelled }.map(\.id))
        warnings.append(contentsOf: RecordingSanity.warnings(
            tracks: [micRecorder, systemRecorder].compactMap { $0 }.map {
                RecordingSanity.Track(
                    id: $0.id, role: $0.role,
                    frames: $0.stats.frames, peakAmplitude: $0.peakAmplitude,
                    allZeroCause: cancelledTrackIDs.contains($0.id)
                        ? .downmixCancellation : nil)
            }))

        tap?.destroy()
        tap = nil

        var manifest = try store.loadManifest(sessionDirectory: dir)
        manifest.state = .finalized
        manifest.pauses = pauses

        // 用音轨 hostTime 跨度反推结束时刻，避免用户在停止前等待导致时长虚高。
        //
        // 这里用**原始跨度**（`spanDuration`）而不是内容时长：
        // `endedAt` 是一个真实的墙上时刻（最后一次出声发生在几点几分），
        // 用它减 `startedAt` 得到的是「录制横跨了多久」。
        // 内容时长另有出处——音轨的 `framesWritten`（静音帧占位，时长不打折）。
        // 若这里改成扣掉静音，`endedAt` 就不对应任何一个真实时刻了。
        let longest = driftTracks.map(\.stats.spanDuration).max() ?? 0
        manifest.endedAt = longest > 0 ? startedAt.addingTimeInterval(longest) : Date()

        for i in manifest.tracks.indices {
            guard let recorder = [micRecorder, systemRecorder]
                .compactMap({ $0 })
                .first(where: { $0.id == manifest.tracks[i].id }) else { continue }
            let stats = recorder.stats
            // 同 `checkpoint()`：正常录制时 `framesWritten == stats.frames`，
            // 只有在文件触顶时才分叉——那时必须以文件真实帧数为准，
            // 否则「正常收尾」的这一场 manifest 时长会大于音频真实时长（`Recovery` 不会修它）。
            manifest.tracks[i].framesWritten = recorder.framesWritten
            manifest.tracks[i].firstHostTime = stats.firstHostTime
            manifest.tracks[i].lastHostTime = stats.lastHostTime
            manifest.tracks[i].warnings.append(contentsOf: recorder.warnings)
        }

        let drift = DriftReport(tracks: driftTracks)

        // 注意措辞：两轨起点差**不是错误**，而是系统音频要经聚合设备启动的固有开销。
        // 两轨时间戳同源（同一个 mach 时钟），转写时按 hostTime 对齐即可。
        // 真正需要报警的是「某轨完全没数据」——那通常意味着权限没拿到。
        if !drift.isUsable {
            let dead = driftTracks.filter { $0.stats.isEmpty || $0.stats.firstHostTime == 0 }
                .map(\.id).joined(separator: ", ")
            warnings.append(
                "音轨 [\(dead)] 未采到有效数据。若为系统音频，通常是权限未授予——"
                + "注意权限缺失时 API 不报错，只会静默返回全零。")
        } else if driftTracks.count > 1, drift.startSkew > 0.2 {
            warnings.append(String(format:
                "两轨启动相差 %.1f 秒（系统音频经聚合设备启动，通常 <0.1 秒），共同覆盖 %.1f 秒。"
                + "两轨时间戳同源，转写时会按 hostTime 对齐，不影响时间轴正确性。",
                drift.startSkew, drift.overlapDuration))
        }
        for w in warnings where !manifest.notes.contains(w) {
            manifest.notes.append(w)
        }
        try store.save(manifest, sessionDirectory: dir)

        micRecorder = nil
        systemRecorder = nil
        sessionDirectory = nil

        // 未闭合的静音段也要计入：音频里已经是静音了（帧写进去了），
        // 只是一条 `PauseSpan` 没落地。不报的话，用户掐掉的时间就凭空消失了。
        var mutedByTrack: [String: Double] = [:]
        for recorder in [micRecorder, systemRecorder].compactMap({ $0 }) {
            let seconds = recorder.mutedSeconds
            if seconds > 0 { mutedByTrack[recorder.id] = seconds }
        }

        return Result(
            sessionID: manifest.sessionID, directory: dir,
            manifest: manifest, drift: drift, warnings: warnings,
            mutedSecondsByTrack: mutedByTrack)
    }

    /// 放弃录制（进程即将退出时用）。刻意不 finalize，留下可恢复的现场。
    public func abort() {
        heartbeat?.cancel()
        heartbeat = nil
        micRecorder?.abort()
        systemRecorder?.abort()
        tap?.destroy()
        tap = nil
        micRecorder = nil
        systemRecorder = nil
    }
}
