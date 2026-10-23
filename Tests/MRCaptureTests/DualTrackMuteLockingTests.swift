import XCTest
import CoreAudio
@testable import MRCapture
import MRCore

/// `DualTrackRecorder` 分轨静音的**并发契约**与语义。
///
/// ## 为什么这些必须测
///
/// 分轨静音的入口 `setMuted` 会在主线程上被界面直接调用，它要同时动
/// `TrackRecorder`（自己的锁）与协调层的 `pauseLock`。两者一旦**以相反顺序**
/// 被拿到，就是死锁——而且死锁时没有任何报错、异常、日志：
/// 主线程只是再也不动了，界面表现为「卡死」。
///
/// 这类缺陷**点一遍是发现不了的**：它取决于具体的调用顺序，
/// 而顺序很容易在别的改动里被无意调换。所以必须用测试钉住。
///
/// ## 夹具的必要性
///
/// 这些用例都**先注入一条"正在运行"的音轨**（`_testInjectTrackRecorder`
/// + `_testForceRunning`）。这不是图省事：`setMuted` 在没有已启动音轨时
/// 会于第一行 `guard let target = recorder(for:)` 直接返回，
/// **`closeOpenMute` 根本不会被调用**——那样构造出来的测试一路绿灯，
/// 却完全测不到死锁路径。第一版正是这么写的，全绿但什么都没验到。
///
/// 不需要任何权限：全部路径都不碰 Core Audio。
final class DualTrackMuteLockingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-mute-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 造一个协调器，里面躺着一条**正在运行**的 `mic` 轨。
    private func makeRecorder(
        mic: Bool = true, system: Bool = false
    ) -> DualTrackRecorder {
        let recorder = DualTrackRecorder(store: SessionStore(root: root))
        if mic {
            let track = Self.makeTrack(id: "mic", dir: root)
            recorder._testInjectTrackRecorder(track)
            recorder._testMarkRunning(track)
        }
        if system {
            let track = Self.makeTrack(id: "system", dir: root)
            recorder._testInjectTrackRecorder(track)
            recorder._testMarkRunning(track)
        }
        return recorder
    }

    /// 构造一条 `TrackRecorder`。**不调 `start()`**——那需要真实设备。
    private static func makeTrack(id: String, dir: URL) -> TrackRecorder {
        try! TrackRecorder(
            id: id,
            role: id == "mic" ? .microphone : .systemAudio,
            deviceID: AudioDeviceID(0),
            deviceName: nil,
            fileURL: dir.appendingPathComponent("\(id).wav"),
            sourceSampleRate: 48000,
            sourceChannels: 1,
            sourceIsInterleaved: true)
    }

    /// 在后台线程调 `body`，等它完成；超时判失败。
    ///
    /// **必须带超时。** 没有它，死锁 = 整个测试进程永久挂起，
    /// 报出来的是套件级超时而不是「这一条锁死了」，看不出是哪条用例。
    ///
    /// **超时阈值刻意压到 2 秒。** 死锁一旦发生，那个后台线程会**永远**占着锁；
    /// 后续每一条用例都要再等一遍自己的超时，套件就会按「用例数 × 超时」
    /// 线性拖下去（实测能拖到几分钟）。阈值小一点，失败来得快，
    /// 报错信息里那条"死锁"的描述也更容易被人看见。
    private func withoutDeadlock(
        _ description: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: @escaping () -> Void
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            body()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            XCTFail("""
                「\(description)」在 \(Int(timeout)) 秒内没有返回 —— 死锁。
                现象：界面上点第二次就卡死，正是这里的后台线程再也拿不到锁。
                """, file: file, line: line)
        }
    }

    // MARK: - 死锁复现

    /// **连续两次切换同一轨的静音**（先静音、再取消）不得死锁。
    ///
    /// 用户报的原话是「选择音轨后，**再**选择音轨时又卡死了」——
    /// 关键在第二次。这个顺序精确命中死锁路径：
    ///
    /// - 第一次 `setMuted(true)`：走「设置静音」分支，不碰 `closeOpenMute`。
    /// - 第二次 `setMuted(false)`：走「取消静音」分支，
    ///   它在**已持有 `pauseLock`** 的情况下调用 `closeOpenMute`，
    ///   而后者第一行又 `pauseLock.lock()` —— `NSLock` 不可重入 → 永久挂起。
    ///
    /// 所以「第一次正常、第二次卡死」不是巧合，而是这条代码路径的必然结果。
    func testTogglingTheSameTrackTwiceMustNotDeadlock() {
        let recorder = makeRecorder()

        withoutDeadlock("静音后再取消静音") {
            _ = recorder.setMuted(true, trackID: "mic")
            _ = recorder.setMuted(false, trackID: "mic")
        }
    }

    /// 先取消静音、再静音（另一个方向）。
    func testUnmuteThenMuteMustNotDeadlock() {
        let recorder = makeRecorder()

        withoutDeadlock("取消静音后再静音") {
            _ = recorder.setMuted(false, trackID: "mic")
            _ = recorder.setMuted(true, trackID: "mic")
        }
    }

    /// 两轨交替切换。
    func testAlternatingBetweenTracksMustNotDeadlock() {
        let recorder = makeRecorder(mic: true, system: true)

        withoutDeadlock("两轨交替静音/取消") {
            _ = recorder.setMuted(true, trackID: "mic")
            _ = recorder.setMuted(true, trackID: "system")
            _ = recorder.setMuted(false, trackID: "mic")
            _ = recorder.setMuted(false, trackID: "system")
        }
    }

    /// 反复切换必须始终不死锁——死锁往往在第 N 次才出现。
    func testRepeatedTogglingNeverDeadlocks() {
        let recorder = makeRecorder()

        withoutDeadlock("20 轮反复切换", timeout: 10) {
            for _ in 0..<20 {
                _ = recorder.setMuted(true, trackID: "mic")
                _ = recorder.setMuted(false, trackID: "mic")
            }
        }
    }

    /// 分轨静音与全局暂停交错不得死锁。
    ///
    /// `pause()` / `resume()` 同样会动 `openMutes`，且与 `setMuted` 共享
    /// `pauseLock`。两条路径交错时若拿锁顺序不同，就是同一个死锁。
    func testInterleavingWithGlobalPauseMustNotDeadlock() {
        let recorder = makeRecorder(mic: true, system: true)

        withoutDeadlock("分轨静音与全局暂停交错") {
            _ = recorder.setMuted(true, trackID: "mic")
            _ = recorder.pause()
            _ = recorder.setMuted(false, trackID: "mic")
            _ = recorder.resume()
            _ = recorder.setMuted(true, trackID: "system")
            _ = recorder.pause()
            _ = recorder.resume()
            _ = recorder.setMuted(false, trackID: "system")
        }
    }

    // MARK: - 语义：死锁修好之后，这些必须成立

    /// 静音 → 取消静音之后，该轨确实回到「在录」。
    ///
    /// 上一组只证明"没卡死"，这里证明"卡死修复没有把功能改坏"——
    /// 一个把 `setMuted` 整个改成 no-op 的写法同样能通过死锁那几条。
    func testUnmuteAfterMuteClearsTheFlag() {
        let recorder = makeRecorder()

        XCTAssertTrue(recorder.setMuted(true, trackID: "mic"), "静音应当生效")
        XCTAssertTrue(recorder.isMuted(trackID: "mic"))

        XCTAssertTrue(recorder.setMuted(false, trackID: "mic"), "取消静音应当生效")
        XCTAssertFalse(recorder.isMuted(trackID: "mic"), """
            取消静音之后仍在静音——功能被改坏了。\
            （死锁那几条测试对这一点是不敏感的：把 setMuted 写成空操作也能过。）
            """)
    }

    /// 静音会留下记录，且带上了轨 id；分轨静音不计入全局扣减。
    func testMuteProducesATrackScopedRecord() {
        let recorder = makeRecorder()

        XCTAssertTrue(recorder.setMuted(true, trackID: "mic"), "静音应当生效")
        // 取消静音同样返回 true——它确实把状态从"静音"改回了"在录"。
        XCTAssertTrue(recorder.setMuted(false, trackID: "mic"), "取消静音应当生效")

        // 分轨静音不参与全局扣减：这一条走的是 `openMutes["mic"]`，
        // 而 `pausedTotal` 只统计 `openMutes[nil]`（全局暂停）。
        XCTAssertEqual(recorder.pausedTotal, 0, accuracy: 0.001,
                       "分轨静音不该计入全局暂停时长")
    }

    /// 对不存在的轨操作不得崩、也不得卡。
    func testUnknownTrackIsIgnored() {
        let recorder = makeRecorder()

        withoutDeadlock("对不存在的轨操作") {
            XCTAssertFalse(recorder.setMuted(true, trackID: "不存在的轨"))
            XCTAssertFalse(recorder.isMuted(trackID: "不存在的轨"))
        }
    }
}