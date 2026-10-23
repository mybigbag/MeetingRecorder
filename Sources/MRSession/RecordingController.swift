import Foundation
import Combine
import MRCore
import MRCapture

/// 图形界面的录音状态机。
///
/// **注意：CLI 的 `record` 并不用它**（见下方「未统一」一节），本类目前只服务 GUI。
///
/// **这一层最关键的设计约束**：`DualTrackRecorder.start()` 与 `.stop()` 都是
/// **同步阻塞**的。系统音频 tap（含聚合设备）的准备耗时可以到秒级，
/// 收尾时要 flush 两条轨并写回 manifest。直接在主线程调，界面会白屏几秒——
/// 用户会以为程序卡死了，然后再点一次按钮。
///
/// 所以这里所有的阻塞调用都丢到后台，状态变化回到主线程发布。
/// `phase` 因此刻意区分 `preparing`（在启动，还没开始录）与 `recording`：
/// 这两者之间可能隔着好几秒，界面必须能显示「正在准备」而不是「正在录制」。
///
/// **未统一（已知）**：`MRCLI.runRecord` 自己 `new` 一个 `DualTrackRecorder` 直接驱动，
/// 没有走这里。它多了 `--seconds` / `--max` 自动停与 Ctrl-C 处理，硬套这个状态机
/// 需要把那些行为也搬进来。两边的差异目前只体现在「CLI 没有可取消的准备阶段」——
/// 而 CLI 恰恰不需要：它的信号处理器只放行一个信号量，`stop()` 一定在 `start()`
/// 返回之后才被调用，天然避开了下面那条陷阱。
@MainActor
public final class RecordingController: ObservableObject {

    public enum Phase: Equatable {
        /// 空闲，可以开始新录音
        case idle
        /// 正在创建设备与音轨（阻塞，可能数秒）
        case preparing
        case recording
        /// 暂停中。设备还在跑，但数据被替换成静音，音频里这一段是静音（长度不变）。
        case paused
        /// 正在收尾写盘
        case stopping
        /// 正常结束
        case finished(sessionID: String)
        /// 失败，附原因
        case failed(message: String)

        public var isBusy: Bool {
            switch self {
            case .preparing, .recording, .paused, .stopping: return true
            case .idle, .finished, .failed: return false
            }
        }

        /// 音频正在被写进文件（暂停中不算）
        public var isCapturing: Bool {
            switch self {
            case .recording, .stopping: return true
            case .idle, .preparing, .paused, .finished, .failed: return false
            }
        }

        /// 是否处于「正常结束」这一态。
        ///
        /// 抽成判据而不是让调用方写 `if case .finished = phase`，是因为
        /// `.finished` 带一个 `sessionID` 关联值，`==` 比较根本写不出来——
        /// 于是每个订阅者都要自己写一遍 `if case`，而那种写法在
        /// 订阅闭包里读起来像是「匹配任意 finished」，实际含义被埋掉了。
        public var isFinishedSession: Bool {
            if case .finished = self { return true }
            return false
        }
    }

    @Published public private(set) var phase: Phase = .idle
    /// 已录制秒数。`preparing` 期间为 0。
    @Published public private(set) var elapsed: Double = 0
    /// 正在录制/刚录完的会话 ID
    @Published public private(set) var sessionID: String?
    /// 录制结束后的告警（采样全零、某轨无数据等）
    @Published public private(set) var warnings: [String] = []
    /// 结束后拿到的完整结果，供界面显示「两轨各多少秒」
    @Published public private(set) var lastResult: SessionRecorderResult?
    /// 当前被静音的轨 id（`mic` / `system`）。
    ///
    /// 必须是 `@Published` 而不是一个计算属性：菜单项的开/关是**用户可控的 UI 状态**，
    /// SwiftUI 靠它决定勾选哪一项。若每次都去问引擎，界面无法在引擎切换（比如进程
    /// 在后台把该轨静音了）时刷新，用户会看到一个与实际不符的菜单。
    @Published public private(set) var mutedTrackIDs: Set<String> = []

    /// 切换某一轨的静音。
    ///
    /// **只在 `.recording` 下有效，暂停期间不提供。**
    /// 暂停时两轨都已因全局暂停而静音，这里再操作没有意义；
    /// 更要紧的是「取消勾选」会让那一轨**在暂停期间开始录音**，
    /// 于是暂停名存实亡，而界面还写着「两轨都静音」。
    /// 要让某轨在继续之后仍保持静音，继续之后再来菜单里关它。
    ///
    /// 只挡 `.preparing`：那时两轨都还没起来，静音一个不存在的东西没有意义。
    ///
    /// 状态**以引擎的真实状态为准**，不是 `setMuted` 的返回值——
    /// 返回值只回答「这次调用有没有改变什么」。界面要回答「现在到底静没静音」。
    public func toggleMute(trackID: String) {
        guard phase == .recording else { return }
        guard let engine = holder.recorder else { return }
        engine.toggleMute(trackID: trackID)
        syncMuteState()
    }

    /// 明确设置某一轨的静音（供状态栏菜单与快捷键用）。
    ///
    /// 暂停期间一律忽略，理由同 `toggleMute(trackID:)`。
    public func setMuted(_ muted: Bool, trackID: String) {
        guard phase == .recording else { return }
        guard let engine = holder.recorder else { return }
        engine.setMuted(muted, trackID: trackID)
        syncMuteState()
    }

    /// 界面上分轨开关此刻**能不能用**。
    ///
    /// 单独暴露出来，是因为 `setMuted` 在非录制态是**静默返回**的：
    /// 菜单项若照旧显示成可点，用户点下去毫无反应，
    /// 而界面又没有任何提示说明为什么——于是「状态显示不对」被误以为是状态乱了，
    /// 实际上只是这次点击压根没送达。
    public var canToggleTracks: Bool { phase == .recording }

    /// 某一轨当前是否静音（以引擎为准）。
    public func isMuted(trackID: String) -> Bool {
        holder.recorder?.isMuted(trackID: trackID) ?? false
    }

    /// 从引擎把静音状态同步到 `@Published`，供界面订阅。
    private func syncMuteState() {
        guard let engine = holder.recorder else {
            if !mutedTrackIDs.isEmpty { mutedTrackIDs = [] }
            return
        }
        let ids = TrackID.allCases
            .filter { engine.isMuted(trackID: $0.rawValue) }
            .map(\.rawValue)
        let next = Set(ids)
        // 无变化就不发 `@Published`：每次调用都无条件赋值会让菜单项反复重建。
        if next != mutedTrackIDs { mutedTrackIDs = next }
    }

    private let store: SessionStore
    private let holder = RecorderHolder()
    private var ticker: Timer?

    /// 引擎工厂。默认产出真实的 `DualTrackRecorder`；
    /// 测试注入假引擎，好在没有音频权限的环境里把状态机跑完。
    public typealias RecorderFactory =
        (SessionStore, DualTrackRecorder.Configuration) -> any RecordingEngine

    private let makeRecorder: RecorderFactory

    public init(
        store: SessionStore,
        makeRecorder: @escaping RecorderFactory = { DualTrackRecorder(store: $0, configuration: $1) }
    ) {
        self.store = store
        self.makeRecorder = makeRecorder
    }

    public var isRecording: Bool { phase == .recording }
    public var isPaused: Bool { phase == .paused }
    /// 是否有一次录音正在进行（含暂停与收尾）
    public var isActive: Bool { phase.isBusy }

    /// 开始录制。
    ///
    /// - Parameters:
    ///   - titleBase: 标题**前缀**。最终标题 = 前缀 + 时间序号
    ///     （见 `SessionStore.autoTitle`），留空即「会议202607271624」。
    ///     时间序号刻意在这个状态机里统一追加，而不是交给各个调用方——
    ///     界面的按钮与状态栏菜单是两条调用路径，各拼一次早晚会漂成两种格式。
    ///   - configuration: 设备锁定、时长上限等
    public func start(
        titleBase: String = "",
        configuration: DualTrackRecorder.Configuration = .init()
    ) {
        guard !phase.isBusy else { return }
        phase = .preparing
        elapsed = 0
        warnings = []
        lastResult = nil
        sessionID = nil
        // 上一场残留的静音状态会让新一场一开场就显示成静音。
        mutedTrackIDs = []

        let title = SessionStore.autoTitle(base: titleBase)
        let holder = self.holder
        let makeRecorder = self.makeRecorder
        Task.detached(priority: .userInitiated) { [weak self, store, holder, makeRecorder] in
            do {
                let recorder = makeRecorder(store, configuration)
                holder.recorder = recorder
                // 阻塞调用：系统音频 tap + 聚合设备创建
                let id = try recorder.start(title: title)
                await self?.beginRecording(sessionID: id)
            } catch {
                holder.recorder = nil
                await self?.failStart(message: "\(error)")
            }
        }
    }

    /// 暂停。**只有真正在录制时才有效**。
    ///
    /// 准备阶段调用会被忽略——那时设备还没起全，暂停一个不存在的东西没有意义，
    /// 而且会让状态机落在一个「既在准备又已暂停」的中间态里。
    ///
    /// 判据取引擎的**真实状态**（`isPaused`）而不是 `pause()` 的返回值：
    /// 返回值回答的是「这次调用有没有改变什么」，界面需要的是「现在到底停了没有」。
    /// 引擎已经处于暂停时再调一次会返回 false，而界面必须照样显示「已暂停」。
    public func pause() {
        guard phase == .recording else { return }
        guard let engine = holder.recorder else { return }
        engine.pause()
        // **暂停会把两轨都静音**，界面上的菜单必须跟着变，
        // 否则菜单还显示「两轨都在录」而实际已经在写静音——
        // 用户从菜单读到的状态是错的，据此做决定必然出错。
        syncMuteState()
        guard engine.isPaused else { return }
        phase = .paused
        // 计时**不重置**：恢复后从内容时长接着走
        tick()
    }

    /// 从暂停恢复。
    ///
    /// 同样以引擎的真实状态为准，理由比 `pause()` 那一处更重：
    /// `resume()` 返回 `false` 只说明「这一次没切换」。如果引擎其实已经不在暂停了
    /// （被别的路径恢复过、或某一轨根本没暂停成功），而控制器只认返回值，
    /// 它就会**永远停在 `.paused`**——每一次 `resume()` 都被那句 guard 挡在门外。
    /// 界面上的表现正是「暂停之后无法继续，只能停止」。
    public func resume() {
        guard phase == .paused else { return }
        guard let engine = holder.recorder else {
            // 引擎已经丢了：没有任何东西处于暂停，控制器不该继续声称「已暂停」。
            // 回到 `.recording` 之后按停止会如实报出「录制器已丢失」——
            // 那本来就是引擎丢失时既定的反馈路径，比卡在暂停里出不来要好。
            phase = .recording
            return
        }
        engine.resume()
        // 同 `pause()`：恢复可能只解开了全局静音加上的那部分，
        // 用户手动关掉的轨仍然是静音的。界面必须跟着引擎走。
        syncMuteState()
        guard !engine.isPaused else { return }
        phase = .recording
        tick()
    }

    /// 录制中不停地在「录 / 暂停」之间切换
    public func togglePause() {
        switch phase {
        case .recording: pause()
        case .paused: resume()
        default: break
        }
    }

    /// 停止并收尾。重复调用是安全的（内部有状态判断）。
    ///
    /// **`preparing` 阶段也能停**，但走的是另一条路：`start()` 是同步阻塞且
    /// **无法中断**的（建聚合设备 + 起 tap 可耗秒级），所以这里只能记下意图、
    /// 立刻把状态改成 `stopping` 给界面反馈，真正的收尾等 `start()` 返回后
    /// 由 `beginRecording` 接手。见那个方法里的说明——少了这一步，
    /// 「准备中」点取消会留下一个**永远停不掉的录音**。
    public func stop() {
        guard phase == .recording || phase == .preparing || phase == .paused else { return }
        let wasPreparing = (phase == .preparing)
        phase = .stopping
        stopTicker()
        // 还在准备阶段：设备尚未起全，此刻调 `stop()` 只会读到半成品。
        // 交给 `beginRecording` 在启动返回后再收尾。
        if wasPreparing { return }
        shutdown(deleteSession: false, failurePrefix: "收尾失败")
    }

    /// 关掉引擎并收尾。
    ///
    /// - Parameters:
    ///   - deleteSession: 这是一次「取消」而不是「录完了」。取消掉的启动会留下
    ///     一个刚建出来、没有任何内容的会话目录，应当顺手清掉。
    ///   - failurePrefix: 失败时的提示前缀，区分「收尾」与「取消」两种语境。
    private func shutdown(deleteSession: Bool, failurePrefix: String) {
        let holder = self.holder
        Task.detached(priority: .userInitiated) { [weak self, holder] in
            guard let recorder = holder.recorder else {
                await self?.failStop(message: "录制器已丢失")
                return
            }
            holder.recorder = nil
            do {
                // 阻塞调用：flush 两轨 + 销毁 tap + 写回 manifest
                let result = try recorder.stop()
                if deleteSession {
                    await self?.discardCancelledSession(sessionID: result.sessionID)
                } else {
                    await self?.finishRecording(with: result)
                }
            } catch {
                await self?.failStop(message: "\(failurePrefix)：\(error)")
            }
        }
    }

    // MARK: - 后台线程回到主线程的落点

    private func beginRecording(sessionID id: String) {
        guard phase == .preparing else {
            // **启动期间被取消了。** 这是本类最容易写错的一处。
            //
            // `start()` 是不可中断的阻塞调用，用户点「取消」时它还在跑、设备马上就
            // 要起来了。如果这里不管不顾地把状态改成 `recording`，就会出现：
            // 持有者已被 `stop()` 清空 → 录音**没有任何人能停** → 再点停止只会得到
            // 「录制器已丢失」，而音频设备会一直采到退出程序为止。
            //
            // 所以必须在这里真的把设备关掉。启动没走完，这场录音不可能有内容，
            // 顺手把刚建出来的空会话目录也清掉。
            sessionID = id
            shutdown(deleteSession: true, failurePrefix: "取消失败")
            return
        }
        sessionID = id
        phase = .recording
        // 同步一次静音状态：引擎可能在别处（状态栏菜单 / 快捷键）被切过，
        // 而启动前 `mutedTrackIDs` 被清空了，这里是让界面追上引擎的唯一时机。
        syncMuteState()
        startTicker()
    }

    private func failStart(message: String) {
        // 用户已经点了「取消」，这不是失败，别弹错误出来。
        if phase == .stopping {
            phase = .idle
            return
        }
        phase = .failed(message: message)
    }

    /// 取消掉的启动要清场。
    ///
    /// 直接删而不进废纸篓：这个目录是上一秒由「这次取消的动作」创建的，
    /// 既不是用户的作品，也不可能含任何音频，丢进废纸篓只会添乱。
    private func discardCancelledSession(sessionID id: String) {
        try? FileManager.default.removeItem(at: store.directory(forSessionID: id))
        sessionID = nil
        lastResult = nil
        warnings = []
        elapsed = 0
        phase = .idle
    }

    private func finishRecording(with result: DualTrackRecorder.Result) {
        lastResult = SessionRecorderResult(result)
        warnings = result.warnings
        sessionID = result.sessionID
        // 静音状态在这里归零：录制已经结束，菜单不再显示任何音轨开关，
        // 留着会让用户在下一场开始前误以为还能切换。
        mutedTrackIDs = []
        phase = .finished(sessionID: result.sessionID)
    }

    private func failStop(message: String) {
        phase = .failed(message: message)
    }

    /// 放弃录制（应用即将退出时用）。刻意不 finalize，留下可恢复的现场。
    public func abort() {
        stopTicker()
        holder.recorder?.abort()
        holder.recorder = nil
        phase = .idle
    }

    /// 把 `finished` / `failed` 收回到 `idle`，让界面回到可再次录制的状态。
    public func acknowledge() {
        guard !phase.isBusy else { return }
        phase = .idle
        elapsed = 0
    }

    // MARK: - 计时

    private func startTicker() {
        stopTicker()
        // 0.5 秒一次：既让秒数看起来是活的，又不至于每帧都触发重绘
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let recorder = holder.recorder else { return }
        // 取**内容时长**而不是墙钟：暂停时它自然停住，
        // 于是界面上「暂停」按下去计时器就不动了——这正是暂停该有的样子。
        // 用墙钟的话，暂停十分钟回来会看到一个包含那十分钟的数字，
        // 而音频里根本没有这一段。
        elapsed = recorder.recordedSeconds
    }
}

/// 录制结束后的轻量结果，避免把 `DualTrackRecorder.Result` 整个暴露到界面层。
public struct SessionRecorderResult: Equatable, Sendable {
    public struct TrackInfo: Equatable, Sendable {
        public var id: String
        public var displayName: String
        public var seconds: Double
        public var sampleRate: Double
        public var channels: Int
        public var frames: Int
        /// 本轨累计被静音的秒数。**不影响 `seconds`**（静音帧仍占时长）。
        public var mutedSeconds: Double
    }
    public var sessionID: String
    public var directory: URL
    public var tracks: [TrackInfo]
    /// 两轨启动时间差（秒）
    public var startSkew: Double
    /// 共同覆盖时长（秒）
    public var overlapDuration: Double

    init(_ result: DualTrackRecorder.Result) {
        sessionID = result.sessionID
        directory = result.directory
        tracks = result.drift.tracks.map { track in
            // 格式与帧数取 **manifest（写入格式）**，不是 `stats`。
            // `TrackStats` 刻意留在源格式（漂移要跟采集时钟比），拿它去回答
            // 「这一轨录成了什么」会复现 CLI 曾经踩过的歧义：开了单声道 24 kHz
            // 却显示「48000Hz 2ch」，用户会以为开关没生效，而盘上其实已经是 24k 单声道。
            // `seconds` 仍然取 `stats.clockDuration`——那是时间量，与格式无关。
            let written = result.manifest.tracks.first { $0.id == track.id }
            // 轨名从 `TrackID` 取，而不是 `track.id == "mic" ? "我" : "对方"`：
            // 后者在将来增加第三条轨时会静默把新轨也显示成「对方」——
            // 认错了说话人，比显示错名字严重得多。
            let role = TrackID(rawValue: track.id)?.displayName ?? track.id
            return TrackInfo(
                id: track.id,
                displayName: role,
                seconds: track.stats.clockDuration,
                sampleRate: written?.sampleRate ?? track.stats.sampleRate,
                channels: written?.channels ?? track.stats.channels,
                frames: written?.framesWritten ?? track.stats.frames,
                mutedSeconds: result.mutedSecondsByTrack[track.id] ?? 0)
        }
        startSkew = result.drift.startSkew
        overlapDuration = result.drift.overlapDuration
    }
}

/// 跨线程持有 recorder。
///
/// **它承担的是跨线程语义，不是线程安全**：`DualTrackRecorder` 自身并不线程安全
/// （两条 `TrackRecorder` 各自带锁，但它自己的字段没有保护）。这里的约定是
/// 「同一时刻只有一个线程在用它」——`start` / `stop` 都在 `Task.detached` 里跑，
/// 而且状态机保证不会并发。把这个约定写成 `@unchecked Sendable`，
/// 是为了让编译器知道是**我们**而不是它在负责这件事。
private final class RecorderHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (any RecordingEngine)?

    var recorder: (any RecordingEngine)? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}
