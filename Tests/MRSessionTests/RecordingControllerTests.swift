import XCTest
@testable import MRSession
import MRCapture
import MRCore

/// 一个只存在于测试里的录音引擎。
///
/// 真录音要走 Core Audio，还需要「麦克风」与「系统音频录制」两项 TCC 授权——
/// 无头环境给不了。但「开始 → 准备 → 录制中 → 收尾 → 完成/失败」这条状态机
/// 恰恰是界面录不出音时最先出问题的地方，所以必须能在没有权限的情况下测。
private final class FakeEngine: RecordingEngine, @unchecked Sendable {

    enum Failure {
        case none
        case onStart(String)
        case onStop(String)
    }

    /// 会话 ID，同时用来在磁盘上真的建/删目录
    let sessionID: String
    private let root: URL

    var failure: Failure = .none
    /// 模拟「准备音频设备」的阻塞耗时。真机上建聚合设备 + 起 tap 可以到秒级，
    /// 这段时间是 `preparing` 状态存在的全部理由，也是取消逻辑最容易写错的地方。
    var startDelay: TimeInterval = 0
    var recordedSeconds: Double = 12
    var elapsedValue: Double = 0

    private let lock = NSLock()
    private var _startTitles: [String] = []
    private var _stopCount = 0
    private var _abortCount = 0

    var startTitles: [String] { lock.withLock { _startTitles } }
    var stopCount: Int { lock.withLock { _stopCount } }
    var abortCount: Int { lock.withLock { _abortCount } }

    init(root: URL, sessionID: String = "2026-09-27-120000-测试") {
        self.root = root
        self.sessionID = sessionID
    }

    var elapsed: Double { elapsedValue }

    @discardableResult
    func start(title: String) throws -> String {
        if startDelay > 0 { Thread.sleep(forTimeInterval: startDelay) }
        if case let .onStart(message) = failure {
            throw MRError.io(path: "-", reason: message)
        }
        // 真实现会在这一步创建会话目录并落下初始 manifest
        let dir = root.appendingPathComponent(sessionID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? RecordingManifest(sessionID: sessionID, title: title, state: .recording)
            .write(to: dir.appendingPathComponent(SessionStore.manifestFileName))
        lock.withLock { _startTitles.append(title) }
        lock.withLock {
            _running = true
            _muted.removeAll()
            _globalPauseOpen = false
            _muteAddedByGlobalPause.removeAll()
        }
        return sessionID
    }

    func stop() throws -> DualTrackRecorder.Result {
        lock.withLock {
            _stopCount += 1
            _running = false
            _muted.removeAll()
            _globalPauseOpen = false
            _muteAddedByGlobalPause.removeAll()
        }
        if case let .onStop(message) = failure {
            throw MRError.io(path: "-", reason: message)
        }
        let ticks = UInt64(recordedSeconds * 1_000_000_000 / HostClock.nanosecondsPerTick)
        let stats = TrackStats(
            sampleRate: 48000, channels: 1,
            frames: Int(recordedSeconds * 48000),
            firstHostTime: 5_000_000_000, lastHostTime: 5_000_000_000 + ticks)
        return DualTrackRecorder.Result(
            sessionID: sessionID,
            directory: root.appendingPathComponent(sessionID, isDirectory: true),
            manifest: RecordingManifest(sessionID: sessionID, title: "测试", state: .finalized),
            drift: DriftReport(tracks: [DriftReport.Track(id: "mic", stats: stats)]),
            warnings: ["音轨 [system] 未采到有效数据"])
    }

    func abort() {
        lock.withLock {
            _abortCount += 1
            _running = false
            _muted.removeAll()
            _globalPauseOpen = false
            _muteAddedByGlobalPause.removeAll()
        }
    }

    // MARK: - 分轨静音

    private var _muted: Set<String> = []
    private var _globalPauseOpen = false
    var mutedTrackIDs: Set<String> { lock.withLock { _muted } }

    /// 全局暂停自己造成的那批静音（真引擎 `muteAddedByGlobalPause` 的对应物）。
    var claimedByGlobalPause: Set<String> { lock.withLock { _muteAddedByGlobalPause } }

    /// 已启动的轨。与真引擎一致：单轨失败时另一轨照样存在。
    private let activeTracks: Set<String> = ["mic", "system"]

    func isMuted(trackID: String) -> Bool { lock.withLock { _muted.contains(trackID) } }

    @discardableResult
    func setMuted(_ muted: Bool, trackID: String) -> Bool {
        lock.withLock {
            guard _running, activeTracks.contains(trackID) else { return false }
            let wasMuted = _muted.contains(trackID)
            // 全局暂停期间该轨可能已经是静音的 —— 此时「静音」在音频上没变化，
            // 但意图变了（从"暂停造成的"变成"我自己关的"），必须摘掉标记。
            let claimedByGlobalPause = _muteAddedByGlobalPause.contains(trackID)
            if muted {
                _muted.insert(trackID)
                _muteAddedByGlobalPause.remove(trackID)
                return !wasMuted || claimedByGlobalPause
            }
            guard wasMuted else { return false }
            _muted.remove(trackID)
            _muteAddedByGlobalPause.remove(trackID)
            return true
        }
    }

    @discardableResult
    func toggleMute(trackID: String) -> Bool {
        let next = !isMuted(trackID: trackID)
        setMuted(next, trackID: trackID)
        return next
    }

    func mutedSeconds(trackID: String) -> Double { 0 }

    // MARK: - 暂停

    private var _running = false
    private var _pauseCount = 0
    private var _resumeCount = 0

    var pauseCount: Int { lock.withLock { _pauseCount } }
    var resumeCount: Int { lock.withLock { _resumeCount } }

    /// **全局暂停这件事在进行中**（真引擎查的是「全局暂停区间是否开着」，
    /// 而不是「所有轨都静音」——后者会让"两轨都被手动关掉"误判成暂停，
    /// 正是本次卡死的第二个成因）。
    var isPaused: Bool { lock.withLock { _globalPauseOpen } }

    private var isPausedLocked: Bool { _globalPauseOpen }

    /// 全局暂停**自己造成**的静音，与真引擎 `muteAddedByGlobalPause` 逐字对应。
    private var _muteAddedByGlobalPause: Set<String> = []

    @discardableResult
    func pause() -> Bool {
        lock.withLock {
            // 真实现里这条判断同样存在（`TrackRecorder.pause` 会检查 running）：
            // 「没在录的时候暂停」必须是无效操作，否则状态机会落在一个
            // 既没录音又已暂停的中间态。
            guard _running, !_globalPauseOpen else { return false }
            var added: Set<String> = []
            for track in activeTracks where !_muted.contains(track) {
                _muted.insert(track)
                added.insert(track)
            }
            // 全被手动关掉时 `changed` 为假，但全局暂停**依然成立**——
            // 真引擎正是这么记的（`openMutes[nil]` 照开）。
            // 若这里 `return false`，控制器就会因为 `guard engine.isPaused`
            // 而把相位留在 `.recording`，与真引擎不一致。
            _globalPauseOpen = true
            _muteAddedByGlobalPause.formUnion(added)
            _pauseCount += 1
            return true
        }
    }

    /// 让 `resume()` 在**真的恢复了**的情况下仍然返回 `false`。
    ///
    /// 这不是刁难：`pause()` / `resume()` 的返回值语义是「这次调用有没有改变状态」，
    /// 而控制器需要的是「现在到底暂停了没有」。两者在「引擎已被别的路径恢复过」
    /// 时会不一致。控制器只认返回值的话，就会永远停在 `.paused`——
    /// 每一次 `resume()` 都被那句 guard 挡在门外，界面上只剩「停止」还能按。
    var resumeReportsNoChange = false

    @discardableResult
    func resume() -> Bool {
        lock.withLock {
            guard _running, _globalPauseOpen else { return false }
            _globalPauseOpen = false
            // 只撤销全局暂停自己加上的那些，用户手动关的保持静音。
            for track in _muteAddedByGlobalPause { _muted.remove(track) }
            _muteAddedByGlobalPause.removeAll()
            _resumeCount += 1
            return !resumeReportsNoChange
        }
    }
}

@MainActor
final class RecordingControllerTests: XCTestCase {

    private var root: URL!
    private var engine: FakeEngine!
    private var controller: RecordingController!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-rec-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        makeController()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeController() {
        let store = SessionStore(root: root)
        let engine = FakeEngine(root: root)
        self.engine = engine
        controller = RecordingController(store: store) { _, _ in engine }
    }

    /// 等挂起的 Task 落地
    private func settle(_ seconds: Double = 0.3) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - 基本状态流转

    func testStartsIdle() {
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.phase.isBusy)
    }

    func testStartReportsPreparingThenRecording() async throws {
        engine.startDelay = 0.4
        controller.start(titleBase: "产品评审")

        // 同步返回后立刻是 preparing：设备还没起来。
        // 界面必须能区分这两个状态，否则用户会以为没点中而再点一次。
        XCTAssertEqual(controller.phase, .preparing)
        XCTAssertTrue(controller.phase.isBusy)
        XCTAssertEqual(controller.elapsed, 0)

        try await settle(0.8)
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(controller.sessionID, engine.sessionID)

        // 标题 = 前缀 + 时间序号。序号由状态机统一追加，调用方只管前缀。
        let sent = try XCTUnwrap(engine.startTitles.first)
        XCTAssertTrue(sent.hasPrefix("产品评审"), "前缀必须保留，收到：\(sent)")
        let suffix = String(sent.dropFirst("产品评审".count))
        XCTAssertEqual(suffix.count, 12, "时间序号应当是 yyyyMMddHHmm，收到：\(sent)")
        XCTAssertTrue(suffix.allSatisfy(\.isNumber), "序号必须全是数字，收到：\(sent)")
    }

    /// 不给前缀时的默认标题：「会议202607271624」这个形状。
    func testEmptyPrefixFallsBackToDefaultBase() async throws {
        controller.start(titleBase: "   ")
        try await settle()

        let sent = try XCTUnwrap(engine.startTitles.first)
        XCTAssertTrue(sent.hasPrefix("会议"), "空白前缀要退回「会议」，收到：\(sent)")
        XCTAssertEqual(sent.count, 2 + 12, "收到：\(sent)")
    }

    func testStartFailureLandsInFailed() async throws {
        engine.failure = .onStart("没有可用的输入设备")
        controller.start(titleBase: "会议")
        try await settle()

        guard case let .failed(message) = controller.phase else {
            return XCTFail("启动失败必须落到 failed，当前是 \(controller.phase)")
        }
        XCTAssertTrue(message.contains("没有可用的输入设备"))
    }

    func testSecondStartWhileBusyIsIgnored() async throws {
        engine.startDelay = 0.3
        controller.start(titleBase: "第一次")
        controller.start(titleBase: "第二次")   // 应当被忽略
        try await settle(0.6)

        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(engine.startTitles.count, 1, "忙碌中的第二次启动必须被挡掉")
        XCTAssertTrue(engine.startTitles[0].hasPrefix("第一次"))
    }

    func testStopWhileIdleIsIgnored() {
        controller.stop()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(engine.stopCount, 0)
    }

    // MARK: - 正常收尾

    func testStopProducesFinishedWithTrackSummary() async throws {
        engine.recordedSeconds = 65
        controller.start(titleBase: "会议")
        try await settle()
        XCTAssertEqual(controller.phase, .recording)

        controller.stop()
        XCTAssertEqual(controller.phase, .stopping)
        try await settle()

        guard case let .finished(sessionID) = controller.phase else {
            return XCTFail("正常收尾必须落到 finished，当前是 \(controller.phase)")
        }
        XCTAssertEqual(sessionID, engine.sessionID)
        XCTAssertEqual(engine.stopCount, 1)

        // 结果要被翻译成界面能直接显示的形状（我 / 对方 + 秒数）
        let result = try XCTUnwrap(controller.lastResult)
        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(result.tracks.first?.displayName, "我")
        XCTAssertEqual(result.tracks.first?.seconds ?? 0, 65, accuracy: 0.01)
        XCTAssertEqual(result.tracks.first?.sampleRate, 48000)
    }

    func testWarningsAreSurfaced() async throws {
        controller.start(titleBase: "会议")
        try await settle()
        controller.stop()
        try await settle()

        // 「录到了但内容是空的」必须传到界面，否则用户要等到回听才发现
        XCTAssertEqual(controller.warnings, ["音轨 [system] 未采到有效数据"])
    }

    func testStopFailureLandsInFailed() async throws {
        controller.start(titleBase: "会议")
        try await settle()
        engine.failure = .onStop("磁盘写满")
        controller.stop()
        try await settle()

        guard case let .failed(message) = controller.phase else {
            return XCTFail("收尾失败必须落到 failed，当前是 \(controller.phase)")
        }
        XCTAssertTrue(message.contains("磁盘写满"))
    }

    func testAcknowledgeReturnsToIdle() async throws {
        controller.start(titleBase: "会议")
        try await settle()
        controller.stop()
        try await settle()

        controller.acknowledge()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.elapsed, 0)
    }

    func testAcknowledgeDoesNothingWhileBusy() async throws {
        controller.start(titleBase: "会议")
        try await settle()
        XCTAssertEqual(controller.phase, .recording)

        controller.acknowledge()   // 录制中不该被「好」按钮拉回 idle
        XCTAssertEqual(controller.phase, .recording)
    }

    func testAbortTellsEngineAndReturnsToIdle() async throws {
        controller.start(titleBase: "会议")
        try await settle()
        controller.abort()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(engine.abortCount, 1)
    }

    // MARK: - 准备阶段取消（最容易写错的一条路）

    /// **回归测试**：在「正在准备音频设备」时点取消，绝不能留下一个停不掉的录音。
    ///
    /// 曾经的时序是：`start()` 是同步阻塞且不可中断的，用户点取消时它还在跑；
    /// 取消逻辑把持有者清空并立刻返回，等 `start()` 返回后又把状态改成 `recording`。
    /// 结果就是：界面显示「录制中」，而录音**没有任何人能停**——
    /// 再点停止只会得到「录制器已丢失」，音频设备一直采到退出程序。
    func testCancelDuringPreparingDoesNotLeavePhantomRecording() async throws {
        engine.startDelay = 0.5
        controller.start(titleBase: "会议")
        XCTAssertEqual(controller.phase, .preparing)

        controller.stop()                       // 用户不耐烦，点了「取消」
        XCTAssertEqual(controller.phase, .stopping, "取消要立刻给界面反馈")

        // 轮询整个窗口期，确认状态**从未**回到 recording
        var sawRecording = false
        for _ in 0..<40 {
            if controller.phase == .recording { sawRecording = true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(sawRecording, "取消之后绝不能再进入录制态——那会是个停不掉的录音")
        XCTAssertEqual(controller.phase, .idle, "取消完成后应回到 idle，而不是停在 stopping")
        XCTAssertEqual(engine.stopCount, 1, "设备必须真的被关掉，不能只改状态")
        XCTAssertEqual(engine.abortCount, 0, "这条路要的是收尾，不是放弃")
    }

    func testCancelDuringPreparingRemovesTheEmptySession() async throws {
        engine.startDelay = 0.3
        controller.start(titleBase: "会议")
        controller.stop()
        try await settle(1.0)

        // 取消掉的启动会留下一个刚建出来、没有内容的目录。
        // 它既不是用户的作品，也不含任何音频，留在列表里只会让人困惑。
        let leftover = root.appendingPathComponent(engine.sessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path),
                       "取消掉的一场不该留下空会话目录")
        XCTAssertNil(controller.sessionID)
        XCTAssertNil(controller.lastResult)
    }

    func testCancelDuringPreparingDoesNotReportFailureWhenStartAlsoFails() async throws {
        // 用户已经点了取消，这时启动再报错不该弹一条吓人的错误。
        engine.startDelay = 0.3
        engine.failure = .onStart("设备被占用")
        controller.start(titleBase: "会议")
        controller.stop()
        try await settle(1.0)

        XCTAssertEqual(controller.phase, .idle, "取消就是取消，别把它显示成失败")
    }

    // MARK: - 暂停

    func testPauseAndResumeRoundTrip() async throws {
        controller.start(titleBase: "会议")
        try await settle()
        XCTAssertEqual(controller.phase, .recording)

        controller.pause()
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertTrue(controller.phase.isBusy, "暂停中仍在录音，不能允许开第二场")
        XCTAssertEqual(engine.pauseCount, 1)
        XCTAssertTrue(engine.isPaused)

        controller.resume()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(engine.resumeCount, 1)
        XCTAssertFalse(engine.isPaused)
    }

    /// 暂停中按「开始录制」必须被挡住——真实现在暂停期间同样不写盘，
    /// 放行的话会得到一场「开始时间对、内容是空的」的会议。
    func testStartWhilePausedIsIgnored() async throws {
        controller.start(titleBase: "会议")
        try await settle()
        controller.pause()

        controller.start(titleBase: "又来一场")
        try await settle()

        XCTAssertEqual(controller.phase, .paused)
        XCTAssertEqual(engine.startTitles.count, 1)
    }

    func testPauseWhileIdleIsIgnored() {
        controller.pause()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(engine.pauseCount, 0, "没在录的时候暂停必须是无效操作")
    }

    /// 准备阶段按暂停要被忽略，**但不能因此把启动搞坏**。
    ///
    /// 这条是真会踩的：用户看到「正在准备音频设备…」要等两三秒，
    /// 手快按了暂停。如果状态机这时切进 `paused`，等 `start()` 返回时
    /// 就会撞上「状态不是 preparing」的取消分支，把刚录上的一场直接删掉。
    func testPauseDuringPreparingIsIgnoredAndStartStillSucceeds() async throws {
        engine.startDelay = 0.4
        controller.start(titleBase: "会议")
        XCTAssertEqual(controller.phase, .preparing)

        controller.pause()
        XCTAssertEqual(controller.phase, .preparing, "准备阶段的暂停请求必须被挡掉")
        XCTAssertEqual(engine.pauseCount, 0)

        try await settle(0.8)
        XCTAssertEqual(controller.phase, .recording, "启动不能被这次暂停打断")
        XCTAssertNotNil(controller.sessionID)
    }

    func testResumeWhileRecordingIsIgnored() async throws {
        controller.start(titleBase: "会议")
        try await settle()

        controller.resume()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(engine.resumeCount, 0)
    }

    func testTogglePauseAlternates() async throws {
        controller.start(titleBase: "会议")
        try await settle()

        controller.togglePause()
        XCTAssertEqual(controller.phase, .paused)
        controller.togglePause()
        XCTAssertEqual(controller.phase, .recording)
        // 空闲时切换没有作用
        controller.stop()
        try await settle()
        controller.acknowledge()
        controller.togglePause()
        XCTAssertEqual(controller.phase, .idle)
    }

    // MARK: - 相位必须跟随引擎的真实状态，而不是 `pause()` / `resume()` 的返回值

    /// 引擎已经真的恢复了，只是 `resume()` 报告「这次没变化」——控制器必须照样回到录制。
    ///
    /// 这是「用快捷键暂停之后无法继续，只能停止」的成因。只认返回值的写法会把
    /// 状态机永久钉在 `.paused`：界面上是「已暂停」，按继续没反应，
    /// 唯一还能按的只剩停止。
    func testResumeFollowsTheEngineRatherThanTheReturnValue() async throws {
        controller.start(titleBase: "会议")
        try await settle()
        controller.pause()
        XCTAssertEqual(controller.phase, .paused)

        // 引擎确实恢复了，只是这次调用报告「没变化」（被别的路径抢先恢复过）
        engine.resumeReportsNoChange = true
        controller.resume()

        XCTAssertEqual(controller.phase, .recording, """
            引擎已经不在暂停了，控制器却还声称「已暂停」。
            判据应该是引擎的真实状态，不是 `resume()` 的返回值——
            返回值说的只是「这次调用有没有改变什么」。
            """)
    }

    /// 反过来的顺序：引擎早就被别的路径暂停了，控制器自己的 `pause()` 于是返回 false。
    func testPauseFollowsTheEngineRatherThanTheReturnValue() async throws {
        controller.start(titleBase: "会议")
        try await settle()
        XCTAssertEqual(controller.phase, .recording)

        // 别的调用路径（状态栏菜单里的暂停项）已经把引擎停了
        engine.pause()
        XCTAssertTrue(engine.isPaused)

        controller.pause()
        XCTAssertEqual(controller.phase, .paused, """
            引擎确实处于暂停，控制器却在界面上继续显示「录制中」——
            那一段是真的没被录进去，界面这么说等于在骗人。
            """)
    }

    /// 暂停中直接停止：不需要先「继续」。
    ///
    /// 真实现里 `TrackRecorder.stop()` 不依赖暂停状态，收尾照常；
    /// 刻意不在这里自动补一次 resume——那会给音频补上一小段，
    /// 用户会因为「我先暂停再停止」而多得到几百毫秒的杂音。
    func testStopFromPausedWorks() async throws {
        controller.start(titleBase: "会议")
        try await settle()
        controller.pause()

        controller.stop()
        XCTAssertEqual(controller.phase, .stopping)
        try await settle()

        guard case .finished = controller.phase else {
            return XCTFail("暂停中停止必须正常收尾，当前是 \(controller.phase)")
        }
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.resumeCount, 0, "停止不该偷偷补一次继续")
    }

    /// **计时用的是内容时长，不是墙上时钟。**
    ///
    /// 这条最容易写错的地方是拿 `recorder.elapsed`（墙钟）当计时：
    /// 那样「录 5 分钟、中途暂停 10 分钟」会显示 15 分钟，
    /// 而音频文件里只有 5 分钟——界面在撒谎，且很难被发现。
    func testElapsedIsContentTimeNotWallClock() async throws {
        controller.start(titleBase: "会议")
        try await settle()

        engine.recordedSeconds = 20
        engine.elapsedValue = 999          // 墙钟，被拉得很远
        controller.pause()

        XCTAssertEqual(controller.elapsed, 20, accuracy: 0.001,
                       "计时必须取内容时长；取到 999 说明用了墙钟")
    }

    // MARK: - 关掉一轨之后按暂停/继续（真实用户报告的卡死）

    /// 用户报告的动作序列，一步不多：关掉一轨 → 暂停 → 继续。
    ///
    /// **这个序列曾让 App 卡死。** 根因是控制器把「全局暂停」与「分轨静音」
    /// 当成了两件独立的事，而引擎里它们共用同一个 `mute` 状态：
    ///
    /// 1. 用户手动静音 mic（`_muted = {mic}`），此时 `isPaused == false`（system 还在录）
    /// 2. 点「暂停」→ 引擎把**两轨都**静音（`{mic, system}`）→ `isPaused == true`
    /// 3. 点「继续」→ 引擎把**两轨都**取消静音（`{}`）
    ///
    /// 第 3 步是错的（用户手动静音的 mic 被顺手恢复了），但它还不至于卡死。
    /// 真正致命的是**用户自己的静音意图在第 3 步被清空之后**，菜单仍然显示
    /// 「我 已静音」——于是下一次点「暂停」时 `isPaused` 又变成 true，
    /// 状态机在两个真相之间来回摆，界面与实际状态分叉。
    ///
    /// 这条测试锁住两件事：**用户主动静音的那一轨不会被「继续」恢复**，
    /// 以及**控制器显示的静音状态与引擎一致**。
    func testMutingOneTrackSurvivesPauseAndResume() async throws {
        controller.start(titleBase: "会议")
        try await settle()
        XCTAssertEqual(controller.phase, .recording)

        // 1. 手动静音 mic
        controller.setMuted(true, trackID: TrackID.mic.rawValue)
        XCTAssertTrue(controller.mutedTrackIDs.contains(TrackID.mic.rawValue))
        XCTAssertFalse(engine.isPaused, "只关一轨不算全场暂停")

        // 2. 按暂停 → 两轨都静音
        controller.pause()
        XCTAssertEqual(controller.phase, .paused)

        // 3. 按继续
        controller.resume()
        XCTAssertEqual(controller.phase, .recording, """
            「继续」之后仍停在已暂停——界面只剩「停止」能按，这就是用户说的卡死。
            """)

        XCTAssertTrue(engine.isMuted(trackID: TrackID.mic.rawValue), """
            用户主动静音的「我」轨被「继续」顺手恢复了。
            全局继续只该撤销它自己造成的全局静音，不能替用户决定别的轨还要不要录。
            """)
        XCTAssertTrue(controller.mutedTrackIDs.contains(TrackID.mic.rawValue),
                      "界面上的静音状态与引擎不一致——菜单会说谎")
    }

    /// 连续多轮「关一轨 → 暂停 → 继续」不得让状态机漂移。
    ///
    /// 单轮能过不代表稳定：任何一处「界面状态 ≠ 引擎状态」都会在下一轮
    /// 被放大成「暂停键无效」或「继续键无效」。
    func testRepeatedMutePauseResumeCyclesStayConsistent() async throws {
        controller.start(titleBase: "会议")
        try await settle()

        for round in 1...5 {
            controller.setMuted(true, trackID: TrackID.system.rawValue)
            XCTAssertTrue(engine.isMuted(trackID: TrackID.system.rawValue),
                          "第 \(round) 轮：对方轨应当是静音的")

            controller.pause()
            XCTAssertEqual(controller.phase, .paused, "第 \(round) 轮：暂停应生效")

            controller.resume()
            XCTAssertEqual(controller.phase, .recording, "第 \(round) 轮：继续应生效")

            XCTAssertTrue(engine.isMuted(trackID: TrackID.system.rawValue),
                          "第 \(round) 轮：手动静音的轨被「继续」清掉了")
            XCTAssertEqual(controller.mutedTrackIDs, engine.mutedTrackIDs,
                           "第 \(round) 轮：界面与引擎状态分叉")
        }
    }

    /// **两轨都被手动关掉**之后再按暂停/继续。
    ///
    /// 这是更隐蔽的一支：若 `isPaused` 用「所有轨都静音」来判，
    /// 这里会被误判成「已经在暂停」，于是控制器的 `pause()` 因
    /// `guard phase == .recording` 而进不去、`resume()` 又因为相位不是 `.paused`
    /// 也进不去——**两个按钮都失效**，界面上只剩停止能按，就是用户说的卡死。
    ///
    /// 正确判据是「全局暂停这件事在进行中」，它与「两轨都被手动关掉」是两种状态。
    func testBothTracksManuallyMutedThenPauseResumeStillWorks() async throws {
        controller.start(titleBase: "会议")
        try await settle()

        // 两轨都手动关掉
        controller.setMuted(true, trackID: TrackID.mic.rawValue)
        controller.setMuted(true, trackID: TrackID.system.rawValue)
        XCTAssertEqual(controller.mutedTrackIDs.count, 2)

        // 这是「手动全关」，**不是**暂停——相位必须仍在录制
        XCTAssertEqual(controller.phase, .recording,
                       "两轨被手动关掉不等于全局暂停，相位不该变成已暂停")

        // 此刻按「暂停」：全局暂停区间打开
        controller.pause()
        XCTAssertEqual(controller.phase, .paused)

        // 按「继续」：全局暂停关闭，但两轨仍保持手动静音
        controller.resume()
        XCTAssertEqual(controller.phase, .recording, """
            「继续」之后仍停在已暂停——两个按钮都失效，这就是卡死。
            引擎把「两轨都被手动关掉」误判成了「已经在暂停」。
            """)
        XCTAssertEqual(controller.mutedTrackIDs.count, 2,
                       "手动关的两轨应当保持静音")
    }

    /// 暂停期间**不提供**分轨开关——那里两轨本来都静音，取消勾选会让它开始录音。
    ///
    /// 这条锁住一个**刻意的不作为**：看起来"顺手支持一下"是对的，
    /// 实际上会让「暂停」失去意义（某一轨在暂停期间仍在录音，
    /// 而界面上还写着「两轨都静音」）。要某轨继续后保持静音，
    /// 正确做法是继续之后再去菜单里关它。
    ///
    /// 断言的是**对引擎的影响**：暂停期间的那次调用根本不该到达引擎，
    /// 所以「继续」之后两轨都恢复——没有任何人要求过保留手动静音。
    func testPerTrackMuteIsRejectedWhilePaused() async throws {
        controller.start(titleBase: "会议")
        try await settle()
        controller.pause()
        XCTAssertEqual(controller.phase, .paused)

        // 暂停期间尝试单独关一轨：控制器应当**在入口就拦下**，不碰引擎
        controller.setMuted(true, trackID: TrackID.mic.rawValue)

        // 全局暂停本身仍然成立，可正常继续；继续后两轨都恢复
        controller.resume()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertFalse(engine.isMuted(trackID: TrackID.mic.rawValue),
                       "暂停期间的这次调用不应被记成用户的分轨静音决定，"
                       + "否则继续之后 mic 会一直静音，而用户从没要求过")
        XCTAssertTrue(controller.mutedTrackIDs.isEmpty,
                      "界面上的静音状态与引擎不一致")
    }

    /// `canToggleTracks` 必须如实反映「此刻点了会不会生效」。
    ///
    /// 这条存在的理由：`setMuted` 在非录制态是**静默返回**的，
    /// 而菜单项若照旧显示成可点，用户点下去毫无反应、界面也无从解释，
    /// 于是「状态显示不对」被误读成状态乱了。
    /// 界面据此禁用按钮，这里验证它给的判据是对的。
    func testCanToggleTracksReflectsWhetherAClickWouldTakeEffect() async throws {
        controller.start(titleBase: "会议")
        try await settle()

        XCTAssertTrue(controller.canToggleTracks, "录制中应当可以切换音轨")

        controller.pause()
        XCTAssertFalse(controller.canToggleTracks, """
            暂停时不能单独切换音轨（暂停已静音两轨），判据必须说 false，
            否则界面会把按钮显示成可点，而点击被静默丢弃。
            """)

        controller.resume()
        XCTAssertTrue(controller.canToggleTracks, "继续之后应当恢复可切换")

        controller.stop()
        try await settle()
        XCTAssertFalse(controller.canToggleTracks, "收尾之后不应再能切换音轨")
    }
}
