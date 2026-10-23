import Foundation
import AVFoundation
import Combine

/// 双轨试听。
///
/// 为什么值得单独做：这个工具的整个立论是「**音轨即说话人身份**」，
/// 而验证这件事最直接的办法就是分别听两条轨——一条只有你，一条只有对方。
/// 所以播放器必须支持「只播某一轨」和「两轨同时播」两种模式。
///
/// 用 `AVAudioPlayer` 而不是 `AVAudioEngine`：这里只需要播放本地 WAV，
/// 不需要实时处理链，而 AVAudioPlayer 天然支持 float32 WAV 与 seek。
@MainActor
final class TrackPlayer: ObservableObject {

    enum Track: String, CaseIterable, Equatable {
        case mic
        case system

        var displayName: String {
            switch self {
            case .mic: return "我"
            case .system: return "对方"
            }
        }
    }

    /// 正在播放的那组轨（同时播放时两个都在里面）
    @Published private(set) var playing: Set<Track> = []
    /// 已暂停、可以原地继续的那组轨。
    ///
    /// **为什么必须和 `playing` 分开存**：暂停是「停在原地」，
    /// 而 `AVAudioPlayer.stop()` 会把 `currentTime` 归零——用 `stop()` 表示暂停，
    /// 每次暂停都等于从头开始。这组状态记的是「哪些轨正停在某处、可以接着播」。
    @Published private(set) var paused: Set<Track> = []
    /// 播放位置（秒），用于进度条
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    /// 打不开的音轨及原因，供界面提示
    @Published private(set) var loadErrors: [Track: String] = [:]

    @Published var micGain: Double = 1.0 { didSet { applyGain() } }
    @Published var systemGain: Double = 1.0 { didSet { applyGain() } }

    private var players: [Track: AVAudioPlayer] = [:]
    private var displayTimer: Timer?

    var isPlaying: Bool { !playing.isEmpty }
    /// 有轨停在某处、可以接着播。
    ///
    /// 与 `isPlaying` 严格区分：底部按钮在「播放中」显示暂停，
    /// 在「已暂停」显示继续，两者不能混。
    var isPaused: Bool { !paused.isEmpty }

    /// 底部「停止」按钮该不该出现。播放头还在开头、也没在播的时候，
    /// 「停止」没有任何效果，摆出来只是噪声。
    var canStop: Bool { isPlaying || isPaused || position > 0 }

    /// 某条轨当前的真实播放位置。
    ///
    /// **注意**：这个值在无头环境下不可信——本机实测音频栈起不来，
    /// `AVAudioPlayer` 的 `currentTime` 恒为 0、`isPlaying` 恒为 false。
    /// 所以它只用于诊断，**测试判据不要建立在它上面**（会变成永远绿的用例）。
    /// 要验证「暂停后还能不能接着播」，用 `canResume(_:)` 问状态。
    func currentTime(of track: Track) -> Double? { players[track]?.currentTime }

    /// 这条轨「是否还接得上续播」——即它被记在 `paused` 里，且有播放器对象。
    ///
    /// **这是区分 `pause()` 与 `stop()` 的可靠判据**，且完全不依赖音频栈：
    /// `stop()` 会把 `paused` 清空，暂停则不会。
    /// 本轮实测：判据建在 `currentTime` 上的那条用例连变异 M-P01 都漏网
    /// （无头环境那个值恒为 0），换成「问状态」才抓住。
    func canResume(_ track: Track) -> Bool {
        players[track] != nil && paused.contains(track)
    }

    /// 每条轨最后一次被要求设置的播放起点。**给测试看**。
    ///
    /// 为什么需要它：无头环境里 `AVAudioPlayer.currentTime` 恒为 0，
    /// 于是「续播有没有从暂停处起播」「seek 有没有作用到暂停中的轨」
    /// 这两个问题**读播放器是读不出答案的**——改与不改都读到 0。
    /// 这里记下「我们要求它去哪儿」，判据才有着落。
    ///
    /// 记录的是**调用意图**，不是播放器实际状态。两者在真机上应当一致，
    /// 但无头环境只能验前者。这是个明确的取舍，不是等价替代。
    private(set) var requestedStartTimes: [Track: Double] = [:]

    /// 给某条轨设置播放起点的唯一出口。所有会改播放头的路径都走这里，
    /// 顺带把意图记进 `requestedStartTimes`。
    private func seekPlayer(_ track: Track, to time: Double) {
        guard let player = players[track] else { return }
        player.currentTime = min(max(0, time), max(0, player.duration - 0.05))
        requestedStartTimes[track] = player.currentTime
    }

    deinit {
        displayTimer?.invalidate()
    }

    // MARK: - 载入

    /// 载入一场会议的两条轨。切换会议时必须调用，否则会播到上一场的音频。
    func load(sessionID: String, directory: URL) {
        stop()
        players.removeAll()
        loadErrors.removeAll()
        duration = 0
        position = 0
        paused = []

        for track in Track.allCases {
            let fileName = "\(track.rawValue).wav"
            let url = directory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                loadErrors[track] = "没有 \(fileName)"
                continue
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                players[track] = player
                // 时长取最长的一轨：两轨长度本来就可能差几十毫秒
                duration = max(duration, player.duration)
            } catch {
                loadErrors[track] = "打不开：\(error.localizedDescription)"
            }
        }
        applyGain()
    }

    func clear() {
        stop()
        players.removeAll()
        loadErrors.removeAll()
        duration = 0
        position = 0
        paused = []
    }

    func canPlay(_ track: Track) -> Bool { players[track] != nil }

    // MARK: - 控制

    /// 从当前位置开始只播指定轨（或同时播多轨）。
    ///
    /// **注意它和「继续」的区别**：这个方法是「从头（或指定位置）播」，
    /// 会把已有的暂停态清掉。继续播放请走 `resume()`——两者混用，
    /// 「暂停后按播放又从头」这个 bug 就会原样长回来。
    func play(_ tracks: Set<Track>, from startTime: Double? = nil) {
        // 只保留**真的打得开**的轨。把没有文件的轨留在 `playing` 里会带来一个
        // 隐蔽后果：`tick()` 判定「播完了」用的是 `playing.allSatisfy`，
        // 而缺失轨的 `players[$0]` 是 nil、比较结果恒为假，于是**永远不自动停**，
        // 进度条会一直挂在末尾。缺失的轨本来也已经通过 `loadErrors` 报给界面了。
        let playable = tracks.filter { players[$0] != nil }
        guard !playable.isEmpty else { return }

        // **必须在 `stop()` 之前取**：它会把 `position` 清零，
        // 之后再读就永远是 0，于是「拖了进度条 → 按播放」会从头开始。
        let carried = position
        stop()
        paused = []

        // 播完一遍之后按播放 = 从头听。否则播放头还停在末尾，
        // 一按就立刻又结束，看起来就是「按钮按了没反应」。
        // 有显式 startTime 时以它为准，不做这个回落。
        let requested = startTime
            ?? (Self.isAtEnd(position: carried, duration: duration) ? 0 : carried)

        // 同步起点：两轨必须从**同一时刻**起播，否则听不出抢话在哪。
        // 各自的 firstHostTime 已经在转写时对齐过，这里只需要同一播放位置。
        let start = max(0, requested)
        for track in playable {
            seekPlayer(track, to: start)
            players[track]?.play()
        }
        playing = playable
        position = start
        startTimer()
    }

    /// 暂停。停在原地，可以接着播。
    ///
    /// **必须用 `AVAudioPlayer.pause()` 而不是 `stop()`**：后者会把
    /// `currentTime` 归零，那样每次暂停都等于从头开始。
    func pause() {
        let pausedNow = playing
        guard !pausedNow.isEmpty else { return }
        for track in pausedNow {
            players[track]?.pause()
        }
        playing = []
        paused = pausedNow
        stopTimer()
    }

    /// 从暂停处接着播。只恢复 `paused` 里的轨，不动正在放的轨。
    func resume() {
        let toResume = paused.filter { players[$0] != nil }
        guard !toResume.isEmpty else { return }
        for track in toResume {
            // 暂停期间用户可能拖过进度条，所以对齐到当前 `position`，
            // 而不是沿用各自被冻结的 currentTime——那会跳回拖动之前。
            seekPlayer(track, to: position)
            players[track]?.play()
        }
        paused = []
        // **并集，不是覆盖**：`playing` 里可能还有正在放的轨
        // （比如 mic 单独暂停、system 还在放）。
        // 写成 `playing = toResume` 会把 system 从状态里抹掉——
        // 界面不再显示它在放，下一轮tick 也拿它当参考，两轨就此错位。
        playing.formUnion(toResume)
        startTimer()
    }

    /// 停止并回到开头。**不保留播放位置**——这是它和 `pause()` 的分工。
    func stop() {
        for player in players.values { player.stop() }
        playing = []
        paused = []
        stopTimer()
        position = 0
    }

    func toggleTrack(_ track: Track) {
        guard players[track] != nil else { return }
        if playing.contains(track) {
            // 单轨暂停：只把这轨挪进 `paused`，其余轨继续放。
            //
            // **不要在这里读 `currentTime` 回写 `position`**：`tick()` 已经每
            // 0.1 秒维护它了，暂停时冻结就是准的。反倒是读回来那一步会让
            // 整个逻辑依赖音频栈真的在推进——无头环境里 `currentTime` 恒为 0，
            // 一读就把播放头抹平，「暂停保位置」这条需求当场失效且测不出来。
            players[track]?.pause()
            playing.remove(track)
            paused.insert(track)
            if playing.isEmpty { stopTimer() }
        } else {
            guard let player = players[track] else { return }
            // 关键：**不**在这里把 position 归零。
            // 旧实现有一句 `if !isPlaying { position = 0 }`，
            // 正是它让「单轨暂停后再播」永远从头开始。
            // 从哪开始由 `position` 自己说话：拖过进度条就从拖的地方，
            // 没拖过就从上次停下的地方。
            seekPlayer(track, to: position)
            player.play()
            playing.insert(track)
            paused.remove(track)
            startTimer()
        }
    }

    /// 跳转到指定秒数。播放中也能用（进度条拖动）。
    ///
    /// **暂停中的轨也要跟**：旧实现只动正在播的（`where player.isPlaying`），
    /// 于是「暂停 →拖进度条 → 继续」会从旧位置播，听起来像跳了一下。
    func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration))
        // 所有轨都跟，**包括暂停中的**：`where player.isPlaying` 会漏掉它们，
        // 于是「暂停 → 拖进度条 → 继续」从旧位置起播，听起来像跳了一下。
        for track in players.keys {
            seekPlayer(track, to: target)
        }
        position = target
    }

    private func applyGain() {
        players[.mic]?.volume = Float(micGain)
        players[.system]?.volume = Float(systemGain)
    }

    // MARK: - 进度

    private func startTimer() {
        stopTimer()
        // 0.1 秒足够进度条看起来是连续的（人眼分辨不出更细）
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func tick() {
        guard let reference = playing.compactMap({ players[$0] }).first else { return }
        position = reference.currentTime
        // 到末尾自动停。
        // **不能走 `pause()`**：自然播完不是「暂停」，进 `paused` 的话
        // 按「继续」会立刻又播完、立刻又停，按钮等于失灵。
        // 播放头留在末尾，让人看得出是播完了；下一次按播放由 `play()` 负责从头来。
        if playing.allSatisfy({ players[$0]?.isPlaying == false }) {
            for player in players.values { player.stop() }
            playing = []
            paused = []
            stopTimer()
        }
    }

    /// 「已经播到末尾」吗。抽成纯函数是为了能测：
    /// `tick()` 的自动停依赖 `AVAudioPlayer` 真的推进 `currentTime`，
    /// 而无头环境里音频栈起不来（实测 `play()` 后 `isPlaying` 恒为 false、
    /// `currentTime` 不动），那条路在此环境**根本验证不了**。
    /// 判据本身能脱离音频栈单测，才不至于让这块永远处于「未覆盖」状态。
    static func isAtEnd(position: Double, duration: Double) -> Bool {
        duration > 0 && position >= duration - endEpsilon
    }

    /// 判定「已经播到末尾」的余量。比播放器自己判定得宽松一点，
    /// 因为 `currentTime` 在末尾会正好等于 duration。
    private static let endEpsilon: Double = 0.25
}
