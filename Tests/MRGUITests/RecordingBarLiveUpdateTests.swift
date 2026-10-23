import XCTest
import AppKit
import Combine
import SwiftUI
import MRCapture
import MRCore
import MRSession
@testable import MRGUI

/// 「按了开始，窗口里还是那个开始按钮」——录音栏必须跟着状态机实时变。
///
/// ## 这一组要钉的是什么
///
/// 用户报的两件事其实是同一件事的两面：
///
///  1. 「用快捷键暂停后无法继续，只能停止录音」
///  2. 「开始/暂停/停止后 App 界面不实时更新，看不到最新状态」
///
/// 只要**录音栏不再重绘**，第 2 条必然成立；而第 1 条跟着来——
/// 暂停之后窗口里那行字还停在「录制中」，那个按钮还是「暂停」。
/// 此时点「暂停」什么也不会发生（状态机里它只在 `.recording` 生效），
/// 界面上唯一还有反应的按钮就是**停止**。用户的描述一字不差。
///
/// ## 为什么不能用「读属性」来验
///
/// 状态机本身一直是对的（`RecordingController` 的用例全绿，探针在真 `run()` 里
/// 也量到相位与首行都对）。坏的是**它和界面之间那一根线**。
/// 所以这里既验机制（`MeetingWorkspace` 有没有把 recorder 的变化报出去），
/// 也验症状（**真的把视图渲染出来，看它有没有重绘**）。
///
/// 只验机制会漏掉「转发接上了、但视图压根没订阅」；只验症状则无法在失败时
/// 指出是哪一层断的。两条都要。
@MainActor
final class RecordingBarLiveUpdateTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var engine: StubEngine!
    private var workspace: MeetingWorkspace!

    private var window: NSWindow!
    private var hosting: NSHostingView<RecordingBarView>!

    /// 刻意写成**同步**的 `setUp` / `tearDown`。
    ///
    /// 第一版是 `async throws`，配合下面手动转 run loop，xctest 直接以
    /// signal 11 崩在同一个进程里跑多条用例时。改成同步之后消失——
    /// 夹具里本来就没有要 await 的东西，多一次主 actor 跳转只是多一个崩溃面。
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-bar-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 偏好用自己的 suite，别碰测试进程的 `.standard`。
        suiteName = "mr-bar-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)

        let stub = StubEngine(root: root)
        engine = stub
        workspace = MeetingWorkspace(
            root: root,
            preferences: RecorderPreferences(defaults: defaults),
            makeRecorder: { _, _ in stub })
    }

    override func tearDown() {
        // 先停掉计时器再拆窗口：录制中启动的 0.5 秒 ticker 挂在 `RunLoop.main` 上，
        // 留着它会在下一条用例的 run loop 里继续触发——那不是断言要管的事。
        workspace?.recorder.abort()
        window?.close()
        window = nil
        hosting = nil
        workspace = nil
        engine = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    // MARK: - 夹具

    /// 只够把状态机推到 `.recording` / `.paused` 的假引擎（同 `StatusItemConcealTests`）。
    /// 真录音要麦克风 + 系统音频两项 TCC 授权，无头环境给不了。
    private final class StubEngine: RecordingEngine, @unchecked Sendable {
        let sessionID = "2026-09-27-120000-界面刷新"
        private let root: URL
        private let lock = NSLock()
        private var running = false
        private var paused = false

        init(root: URL) { self.root = root }

        var elapsed: Double { 0 }
        var recordedSeconds: Double { 0 }

        @discardableResult
        func start(title: String) throws -> String {
            let dir = root.appendingPathComponent(sessionID, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            lock.withLock { running = true; paused = false }
            return sessionID
        }

        func stop() throws -> DualTrackRecorder.Result {
            lock.withLock { running = false; paused = false }
            let stats = TrackStats(sampleRate: 48000, channels: 1, frames: 24000)
            return DualTrackRecorder.Result(
                sessionID: sessionID,
                directory: root.appendingPathComponent(sessionID, isDirectory: true),
                manifest: RecordingManifest(
                    sessionID: sessionID, title: "界面刷新", state: .finalized),
                drift: DriftReport(tracks: [DriftReport.Track(id: "mic", stats: stats)]))
        }

        func abort() { lock.withLock { running = false; paused = false } }

        var isPaused: Bool { lock.withLock { paused } }

        // MARK: 分轨静音（复刻真引擎语义，供界面刷新用例驱动）

        private var muted: Set<String> = []
        private var globalPauseOpen = false

        func isMuted(trackID: String) -> Bool { lock.withLock { muted.contains(trackID) } }

        @discardableResult
        func setMuted(_ muted: Bool, trackID: String) -> Bool {
            lock.withLock {
                guard running else { return false }
                if muted { self.muted.insert(trackID) } else { self.muted.remove(trackID) }
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

        @discardableResult
        func pause() -> Bool {
            lock.withLock {
                guard running, !paused else { return false }
                paused = true
                return true
            }
        }

        @discardableResult
        func resume() -> Bool {
            lock.withLock {
                guard running, paused else { return false }
                paused = false
                return true
            }
        }
    }

    /// 把录音栏真的放进一个窗口里渲染出来。
    ///
    /// **必须走真窗口。** `ImageRenderer` 每次都重新求值 body，一个「压根没订阅
    /// recorder」的视图在它下面照样能画出正确的样子——那种测试验的是模板，不是界面。
    /// 只有挂在窗口上、交给 SwiftUI 的更新机制去驱动，才能看出「状态变了它有没有反应」。
    private func installBar() {
        let view = RecordingBarView(workspace: workspace, onSessionSaved: {})
        hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 46)

        window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hosting
        // **必须显式关掉。** 代码 new 出来的 `NSWindow` 默认 `isReleasedWhenClosed == true`，
        // 于是 `close()` 已经释放它一次，ARC 再置 nil 就是第二次——
        // 进程会在 XCTest 的内存检查 pop 自动释放池时以 SIGSEGV 崩掉
        // （堆栈：`objc_release` → `AutoreleasePoolPage::releaseUntil`）。
        // 那一声崩跟被测逻辑毫无关系，却会让整条用例看起来像「测不了」。
        window.isReleasedWhenClosed = false
        // 挪到屏幕外，免得测试跑起来时窗口在脸上闪。窗口仍然有 backing store，
        // `cacheDisplay` 照样取得到像素——这也正是不能用「窗口可见」当判据的原因。
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        window.orderFrontRegardless()
        settle()
    }

    /// 让主 run loop 转一会儿。
    ///
    /// SwiftUI 收到 `objectWillChange` 之后**不是**同步重绘，它把这次更新排到
    /// 下一个显示周期。所以「改完状态立刻看」永远看到旧的——这不是产品的错，
    /// 是断言写错了。必须让循环转起来。
    ///
    /// 顺带一提：这里跑 run loop 也顺手排空了主队列，于是 `startRecording` 丢到
    /// detached task 里的那一段（`beginRecording` 回到主 actor）能落下来。
    private func settle(_ seconds: TimeInterval = 0.35) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// 转着 run loop 等条件成立，超时判失败。
    ///
    /// **整个文件刻意不写 `async` 用例**：第一版是 `async` 的，再在里面嵌
    /// `RunLoop.main.run`，xctest 直接以 signal 11 崩掉。同步用例 + 手动转循环
    /// 既避开了这件事，又比 `Task.sleep` 更能说明「界面是被哪个周期驱动的」。
    private func pump(_ description: String, timeout: TimeInterval = 5,
                      file: StaticString = #filePath, line: UInt = #line,
                      until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("等待超时（\(timeout) 秒）：\(description)", file: file, line: line)
    }

    /// 只有真的建过窗口的用例才调得到它。
    ///
    /// 快照与「推进状态机」刻意分成两个动作：只验机制的两条用例不建窗口，
    /// 让它们顺带取一次快照只会在 `hosting` 上撞到 nil。
    private func snapshot(file: StaticString = #filePath, line: UInt = #line) -> Data {
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("取不到位图缓存", file: file, line: line)
            return Data()
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("位图转不出 PNG", file: file, line: line)
            return Data()
        }
        return data
    }

    /// 开始录制并等到状态机真的进 `.recording`。**不取快照。**
    private func driveToRecording(file: StaticString = #filePath, line: UInt = #line) {
        workspace.startRecording(titleBase: "")
        pump("状态机进入 .recording", file: file, line: line) {
            self.workspace.recorder.phase == .recording
        }
        settle()
    }

    // MARK: - 阳性对照：先证明「快照对比」本身可信

    /// 状态不动 → 两次快照必须**逐字节相同**。
    ///
    /// 少了这条，下面那些 `XCTAssertNotEqual` 全是空的：一个每次快照都带点噪声的
    /// 采集方法会让它们无条件通过，看起来一切正常。测试夹具本身也得有对照。
    ///
    /// 这里也顺带钉住「渲染出东西了」：全透明或全空的图，两次当然也相同。
    func testSnapshotIsStableWhenNothingChanges() throws {
        installBar()
        let first = snapshot()
        settle()
        let second = snapshot()

        XCTAssertEqual(first, second,
                       "没有改任何状态，两次快照却不同——快照方法本身不稳定，"
                       + "下面的「重绘了」断言就失去意义了")
        XCTAssertGreaterThan(first.count, 1000,
                             "位图太小，可能根本没画出内容（\(first.count) 字节）")
    }

    // MARK: - 症状：录音栏必须跟着状态机走

    /// 点下开始录制之后，录音栏必须重绘。
    func testTheBarRepaintsWhenRecordingStarts() throws {
        installBar()
        let idle = snapshot()

        driveToRecording()
        let recording = snapshot()

        XCTAssertNotEqual(idle, recording, """
            状态机已经进到 .recording，界面却还画着同一张图。
            用户看到的就是「点了开始没反应」——他会再点一次（被状态机挡掉），
            然后以为程序坏了。
            """)
    }

    /// 暂停 → 继续，两段都必须画出来。
    ///
    /// 这是用户报的第 1 条：「暂停之后无法继续，只能停止」。
    /// 窗口里如果一直停在「录制中 + 暂停按钮」，那唯一按得动的就只剩停止。
    func testTheBarRepaintsAcrossPauseAndResume() throws {
        installBar()
        driveToRecording()
        let recording = snapshot()

        // 快捷键 ⌥⌘P 走的就是这一句。
        workspace.recorder.togglePause()
        pump("进入 .paused") { self.workspace.recorder.phase == .paused }
        settle()
        let paused = snapshot()

        XCTAssertNotEqual(recording, paused, """
            暂停之后录音栏没有重绘：窗口里还写着「录制中」、按钮还是「暂停」。
            此时点「暂停」不会有任何反应（状态机只在 .recording 生效），
            界面上唯一还有反应的按钮是「停止」——这正是「无法继续，只能停止录音」。
            """)

        // 再按一次 ⌥⌘P
        workspace.recorder.togglePause()
        pump("回到 .recording") { self.workspace.recorder.phase == .recording }
        settle()
        let resumed = snapshot()

        XCTAssertNotEqual(paused, resumed, "继续之后录音栏没有重绘，界面停在「已暂停」")
    }

    /// **分轨静音之后，菜单标题必须重绘。**
    ///
    /// 这是用户报的第 2 条：「选择音轨后，再选择音轨时又卡死了」。
    ///
    /// 根因是**观察链缺失**：`RecordingBarView` 原本只
    /// `@ObservedObject var workspace`，而 `mutedTrackIDs` 挂在
    /// `workspace.recorder` 这个**另一个** ObservableObject 上，
    /// 且 `recorder` 是 `workspace` 的一个普通 `let` 属性（不是 `@Published`）。
    /// 于是 `mutedTrackIDs` 怎么变都不会让这个视图重绘——
    /// 菜单标题停在「音轨」，勾选态与真实状态分叉，
    /// 下一次交互就落进「点了没反应、界面锁死」。
    ///
    /// ## 断言为什么必须是「基线 → 只改静音 → 再快照」
    ///
    /// 第一版把基线取在 `driveToRecording()` 之后，那**测不出这个 bug**：
    /// 中间隔着 `startRecording`，它会连带改动 `workspace` 上的其它 `@Published`
    /// （列表、会话），于是无论视图有没有订阅 recorder，快照都会变——
    /// 用例无条件通过，是一条假绿。
    ///
    /// 所以基线必须在**任何 workspace 变化都结束之后**取，
    /// 紧接着只调 `setMuted` 这一个动作，中间不做别的。
    /// 这样「快照变了」才真的等于「静音驱动了重绘」。
    func testTheBarRepaintsWhenATrackIsMuted() throws {
        installBar()
        driveToRecording()
        // **多转几轮**，让 startRecording 引发的所有异步更新彻底落地，
        // 否则基线本身还在被别的变化搅动。
        settle(1.0)

        let baseline = snapshot()
        settle(0.3)
        // 基线自身必须稳定，否则后面的「变了」没有意义（夹具也要有对照）
        XCTAssertEqual(baseline, snapshot(), """
            什么都没改，两次快照就不同——快照方法本身不稳定，\
            「重绘了」的断言失去意义。
            """)

        // 唯一动作：静音麦克风
        workspace.recorder.setMuted(true, trackID: TrackID.mic.rawValue)
        pump("mutedTrackIDs 变成 {mic}") {
            self.workspace.recorder.mutedTrackIDs.contains(TrackID.mic.rawValue)
        }
        settle(0.5)
        let afterMute = snapshot()

        XCTAssertNotEqual(baseline, afterMute, """
            唯一的动作是静音麦克风，界面却一像素没变。
            菜单标题仍写着「音轨」而不是「音轨 · 1 已静音」——
            用户从界面上看不出自己已把麦克风关了，\
            而菜单项的勾选态与真实状态分叉，下一次点它就会锁死。
            """)
    }

    /// 连续两次切换音轨：第二次也必须画出来。
    ///
    /// 用户的原话是「**再**选择音轨时」才卡——也就是第二次交互才暴露。
    /// 只验第一次会漏掉「第一次把状态改坏、第二次才出问题」这类缺陷。
    ///
    /// 同样按「基线 → 只改静音」的方式隔离变量，与上一条同一个道理。
    func testTheBarRepaintsAcrossRepeatedTrackMuting() throws {
        installBar()
        driveToRecording()
        settle(1.0)

        workspace.recorder.setMuted(true, trackID: TrackID.system.rawValue)
        pump("system 静音") {
            self.workspace.recorder.mutedTrackIDs.contains(TrackID.system.rawValue)
        }
        settle(0.5)
        let firstMuted = snapshot()

        // 唯一动作：取消静音
        workspace.recorder.setMuted(false, trackID: TrackID.system.rawValue)
        pump("system 取消静音") {
            !self.workspace.recorder.mutedTrackIDs.contains(TrackID.system.rawValue)
        }
        settle(0.5)
        let firstUnmuted = snapshot()

        XCTAssertNotEqual(firstMuted, firstUnmuted, """
            取消静音之后界面没有变化，菜单标题仍停在「1 已静音」。
            用户会以为第二次点击没生效而反复点——这条路径正是「卡死」的现场。
            """)
    }

    /// 停止之后也得画出来，否则新会议既看不到也刷不进列表。
    func testTheBarRepaintsWhenRecordingStops() throws {
        installBar()
        driveToRecording()
        let recording = snapshot()

        workspace.recorder.stop()
        pump("进入 .finished") {
            if case .finished = self.workspace.recorder.phase { return true }
            return false
        }
        settle()
        let finished = snapshot()

        XCTAssertNotEqual(recording, finished, """
            停止之后录音栏没有重绘：窗口里还写着「正在录」。
            而列表的刷新挂在录音栏的 `onChange(of: phase)` 上——
            界面不重绘，那个回调也永远不会触发，新录的会议不会出现在列表里。
            """)
    }

    // MARK: - 机制：中枢必须把 recorder 的变化报出去

    /// `MeetingWorkspace` 必须把 `recorder` 的变化转成自己的 `objectWillChange`。
    ///
    /// **这就是那根断掉的线。** 视图订阅的是 `workspace`，而相位变化发生在
    /// `workspace.recorder` 上——两个对象。中枢不转发，订阅 workspace 的视图
    /// 就永远收不到通知，界面冻结在最后一次重绘时的样子。
    ///
    /// 这条断言在无头环境里就能跑，不依赖窗口和像素。
    func testWorkspaceAnnouncesRecorderChanges() throws {
        var announcements = 0
        let token = workspace.objectWillChange.sink { announcements += 1 }
        defer { token.cancel() }

        workspace.startRecording(titleBase: "")
        pump("进入 .recording") { self.workspace.recorder.phase == .recording }

        XCTAssertGreaterThan(announcements, 0, """
            驱动录音状态机之后，`MeetingWorkspace` 一次 `objectWillChange` 都没发。
            订阅它的视图（录音栏、列表、详情）因此全都收不到通知——
            界面会一直停在开始之前的样子。
            """)
    }

    /// 每一次相位变化都要报出去，包括暂停/继续这种「不是开始也不是结束」的。
    func testWorkspaceAnnouncesEveryPhaseTransition() throws {
        driveToRecording()

        var announcements = 0
        let token = workspace.objectWillChange.sink { announcements += 1 }
        defer { token.cancel() }

        workspace.recorder.togglePause()
        pump("进入 .paused") { self.workspace.recorder.phase == .paused }
        let afterPause = announcements

        workspace.recorder.togglePause()
        pump("回到 .recording") { self.workspace.recorder.phase == .recording }

        XCTAssertGreaterThan(afterPause, 0, "暂停没有触发 objectWillChange——界面会停在「录制中」")
        XCTAssertGreaterThan(announcements, afterPause, "继续没有触发 objectWillChange")
    }
}

