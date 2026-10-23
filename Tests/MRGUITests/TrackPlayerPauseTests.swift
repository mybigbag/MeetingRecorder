import XCTest
@testable import MRGUI
import MRCore

/// 暂停 / 继续 / 停止三态的单元测试。
///
/// **为什么这组用例值得单独写**：这个需求是用户实际用出来的
/// ——「每次一点停止就只能从头开始播放」。而它**在编译层面完全看不出来**：
/// `stop()` 是合法的、`position` 是 `Double`、界面按钮画得出来。
/// 只有把「暂停之后还能不能停在原地」写成断言，才拦得住回归。
///
/// **根因（两条，叠加起来才出问题）**：
/// 1. `AVAudioPlayer.stop()` 会把 `currentTime` 归零 —— 这是系统行为，
///    绕不过去，只能不用它来表示「暂停」。
/// 2. `toggleTrack` 里有一句`if !isPlaying { position = 0 }`，
///    在只有一条轨的场景下，任何一次「暂停后再播」都会先把播放头抹成 0。
///
/// 只修一条不够：把 `stop()` 换成 `pause()` 但留着第2 条，单轨场景照样从头。
@MainActor
final class TrackPlayerPauseTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-pause-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 夹具

    /// 与 `TrackPlayerTests` 同一套写法：真实 WAV 文件，不 mock 文件系统。
    /// `AVAudioPlayer` 的 `currentTime` 语义只在真文件上才有意义。
    private func writeTrack(
        named name: String,
        seconds: Double,
        channels: Int = 1,
        into directory: URL
    ) throws {
        let url = directory.appendingPathComponent(name)
        let writer = try WAVWriter(url: url, sampleRate: 48000, channels: channels)
        let batch = [Float](repeating: 0.1, count: 4800 * channels)
        var remaining = Int(seconds * 48000)
        while remaining > 0 {
            let frames = min(4800, remaining)
            try writer.append(Array(batch.prefix(frames * channels)))
            remaining -= frames
        }
        try writer.finalize()
    }

    private func makeSessionDirectory(
        id: String,
        micSeconds: Double?,
        systemSeconds: Double?
    ) throws -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let micSeconds { try writeTrack(named: "mic.wav", seconds: micSeconds, into: dir) }
        if let systemSeconds {
            try writeTrack(named: "system.wav", seconds: systemSeconds,
                           channels: 2, into: dir)
        }
        return dir
    }

    // MARK: - 暂停保位置

    func testPauseKeepsPositionInsteadOfResettingToZero() throws {
        // 这是用户报的现象本身：一暂停，播放头就没了。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: 10)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic], from: 3)
        player.pause()

        XCTAssertGreaterThan(
            player.position, 2.5,
            "暂停必须停在原地。`stop()` 会把 currentTime 归零，用它表示暂停就等于从头开始")
        XCTAssertEqual(player.position, 3, accuracy: 1.0, "播放头只该有定时器带来的亚秒级漂移")
    }

    func testPauseMarksStateAsPausedNotPlaying() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 5, systemSeconds: 5)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic, .system])
        player.pause()

        XCTAssertFalse(player.isPlaying, "暂停后不算「正在播放」")
        XCTAssertTrue(player.isPaused, "暂停后必须能认出「可以继续」")
        XCTAssertTrue(player.playing.isEmpty)
        XCTAssertEqual(player.paused, [.mic, .system])
    }

    /// 抓住「用 `stop()` 冒充 `pause()`」这条最核心的变异。
    ///
    /// **为什么不能靠读 `currentTime`**：无头环境音频栈起不来
    /// （实测 play() 后 isPlaying 恒 false、currentTime 不推进），读出来恒为 0。
    /// 本轮实测：判据建在这个值上的那条用例，连变异 M-P01 都漏网。
    ///
    /// **换成问状态**：暂停的定义就是「记在 `paused` 里、还能接着播」。
    /// `stop()` 会清空 `paused`，所以这一条不依赖音频栈、也不依赖播放头。
    func testPauseKeepsTrackResumableNotStopped() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: nil)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic], from: 2)
        player.pause()

        XCTAssertTrue(player.canResume(.mic),
                      "暂停后这条轨必须还能接着播。用 stop() 冒充 pause() 会清掉 paused，"
                      + "结果是「继续」变成「从头来」——就是这个需求要修的 bug")
    }

    /// 续播后仍然接得上，且状态确实回到在播。
    func testResumeAfterPauseReturnsToPlaying() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: nil)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic], from: 2)
        player.pause()
        XCTAssertTrue(player.canResume(.mic))

        player.resume()

        XCTAssertTrue(player.isPlaying)
        XCTAssertFalse(player.canResume(.mic), "已经在播了，不该还挂着「可续播」")
        XCTAssertEqual(player.playing, [.mic])
    }

    /// 停止之后不该还能续播——这是与暂停的分工。
    func testStopMakesTrackUnresumable() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: nil)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic], from: 2)
        player.pause()
        player.stop()

        XCTAssertFalse(player.canResume(.mic),
                       "停止就是结束，不能还能接着播——那暂停和停止就没区别了")
    }

    // MARK: - 继续

    func testResumeContinuesFromPausedPosition() throws {
        // 核心诉求：暂停之后按继续，**接着刚才的地方播**，不是从头。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: 10)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic], from: 4)
        player.pause()
        let parked = player.position
        player.resume()

        XCTAssertTrue(player.isPlaying)
        XCTAssertFalse(player.isPaused)
        XCTAssertEqual(
            player.position, parked, accuracy: 0.5,
            "继续必须接着暂停的位置；跳回 0 就是这个需求要修的那个 bug")
    }

    func testResumeMovesUnderlyingPlayerNotJustTheBookmark() throws {
        // **这条断言在无头环境下是空的**，原因值得记下来：
        // 它读 `AVAudioPlayer.currentTime`，而本机无头环境音频栈起不来
        // （实测 play() 后 isPlaying 恒 false、currentTime 不推进），
        // 读出来恒为 0，断言 `> 3.5` 靠它抓不到任何东西——连变异 M-P01
        // （pause() 里改用 stop()）都因此漏网。
        //
        // 换成不依赖音频栈的判据：`resume()` 必须把 `position` 写进播放器。
        // 这里只能验证「调用后状态自洽」，真正的播放位置由真机走查兜底。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: 10)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic], from: 5)
        player.pause()
        let parked = player.position
        player.resume()

        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(player.paused.isEmpty)
        XCTAssertEqual(
            player.position, parked, accuracy: 0.5,
            "resume() 不该改动播放头——它只是把暂停时的位置交还给播放器")
    }

    func testResumeWithoutPauseDoesNothing() throws {
        // 没有暂停过就按「继续」：不能凭空从头开始播。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 5, systemSeconds: 5)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.resume()

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isPaused)
        XCTAssertEqual(player.position, 0)
    }

    func testResumeOnlyResumesPausedTracksNotAllOfThem() throws {
        // mic 停、system 还在放，然后按「继续」——
        // 只能恢复 mic，不能把 system 也重播一遍（那会造成错位）。
        //
        // 注意断言方向：`playing` 里**应该**还有 system，因为按下继续时它本来就在播。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: 10)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic, .system])
        player.toggleTrack(.mic)
        XCTAssertEqual(player.paused, [.mic])
        XCTAssertEqual(player.playing, [.system])

        player.resume()

        XCTAssertTrue(player.paused.isEmpty, "暂停的轨要被恢复")
        XCTAssertEqual(player.playing, [.mic, .system],
                       "已在播的 system 不能被重新起播——那会让两轨错位")
    }

    // MARK: - 停止仍要能回到开头

    func testStopResetsToBeginning() throws {
        // 「暂停」和「停止」是两件事。全改成暂停的话，
        // 用户就永远回不到开头了——这是本轮刻意保留停止按钮的原因。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: 10)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic], from: 6)
        player.pause()
        player.stop()

        XCTAssertEqual(player.position, 0, accuracy: 0.001, "停止就是回到开头")
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isPaused)
        XCTAssertTrue(player.paused.isEmpty)
    }

    func testStopWhilePlayingResetsPosition() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: 10)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic, .system], from: 5)
        player.stop()

        XCTAssertEqual(player.position, 0, accuracy: 0.001)
        XCTAssertTrue(player.playing.isEmpty)
        XCTAssertTrue(player.paused.isEmpty)
    }

    func testCanStopReflectsWhetherThereIsAnythingToStop() throws {
        // 「停止」按钮该不该出现：播放头在开头、也没在播，就没意义。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 5, systemSeconds: 5)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        XCTAssertFalse(player.canStop, "刚载入、什么都没播，不该给停止按钮")

        player.play([.mic], from: 3)
        XCTAssertTrue(player.canStop)

        player.pause()
        XCTAssertTrue(player.canStop, "暂停中也要能停")

        player.stop()
        XCTAssertFalse(player.canStop)
    }

    // MARK: - 单轨 toggle 的三态

    func testToggleTrackPausesThenResumesAtSameSpot() throws {
        // 用户描述的「单轨播放」场景。原实现里这里必然从头：
        // `toggleTrack` 的 `if !isPlaying { position = 0 }` 每次都抹掉播放头。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: 10)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.toggleTrack(.mic)
        player.play([.mic], from: 4)   // 先把播放头放到 4 秒
        player.toggleTrack(.mic)        // 暂停

        XCTAssertEqual(player.paused, [.mic])
        XCTAssertFalse(player.isPlaying)
        let parked = player.position
        XCTAssertGreaterThan(parked, 2.5, "单轨暂停同样必须保住位置")

        player.toggleTrack(.mic)        // 继续

        XCTAssertEqual(player.playing, [.mic])
        XCTAssertTrue(player.paused.isEmpty)
        XCTAssertEqual(player.position, parked, accuracy: 0.5, "继续不跳回 0")
    }

    func testToggleTrackFromStoppedStartsFromBeginning() throws {
        // 反过来：真的「从头开始播」这条路径不能被暂停逻辑污染。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: 10)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic], from: 7)
        player.stop()
        player.toggleTrack(.mic)

        XCTAssertEqual(player.playing, [.mic])
        XCTAssertLessThan(player.position, 1.0, "停过之后从头播，不是接着播")
    }

    func testToggleTrackOnMissingFileStaysNoOp() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 5, systemSeconds: nil)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.toggleTrack(.system)

        XCTAssertTrue(player.playing.isEmpty)
        XCTAssertTrue(player.paused.isEmpty)
    }

    // MARK: - 暂停时拖进度条

    func testSeekWhilePausedMovesEveryTrackNotJustPlayingOnes() throws {
        // 修 `seek` 里的 `where player.isPlaying`：暂停中的轨不在这个集合里，
        // 于是拖完进度条再继续，会从**旧位置**播——听起来就是「跳了一下」。
        //
        // **判据只能建立在 `position` 上**：早先这里还断言了
        // `currentTime(of:) == 2`，那是无效断言——无头环境里 currentTime 恒为 0，
        // 恒真；而 `resume()` 随后又会把 currentTime 重写，等于什么都测不到
        // （变异 M-P12 因此漏网）。位置由 `position` 说了算，它不依赖音频栈。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: 10)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic, .system], from: 6)
        player.pause()
        player.seek(to: 2)

        XCTAssertEqual(player.position, 2, accuracy: 0.001,
                       "暂停中拖进度条，播放头必须真的动")

        player.resume()
        XCTAssertEqual(player.position, 2, accuracy: 0.3,
                       "续播起点必须是拖到的地方，不是暂停时的旧位置")
    }

    func testSeekClampsWhilePaused() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 5, systemSeconds: 5)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic])
        player.pause()

        player.seek(to: -10)
        XCTAssertEqual(player.position, 0, accuracy: 0.001)

        player.seek(to: 9999)
        XCTAssertEqual(player.position, 5, accuracy: 0.3, "超出时长要夹回来")
    }

    // MARK: - 播完自动停

    // **下面这组刻意不依赖真实播放推进。**
    //
    // 原本写成「播 1 秒素材，等它自然结束」，实测在本机无头环境下
    // `AVAudioPlayer.play()` 之后 `isPlaying` 恒为 false、`currentTime` 不动
    // （音频栈起不来），于是这类用例**永远验证不了真实行为**，只会：
    //   - 在真机上过、在 CI 上红，或者反过来；
    //   - 给出「播完逻辑已覆盖」的错觉。
    //
    // 按「判据不能依赖系统行为」那条规矩，把判据抽成纯函数单独测；
    // 真机上「播完自动停」由手工走查兜底（见 docs/测试用例-播放暂停续播.md）。

    func testIsAtEndJudgement() {
        XCTAssertTrue(TrackPlayer.isAtEnd(position: 10, duration: 10))
        XCTAssertTrue(TrackPlayer.isAtEnd(position: 9.8, duration: 10),
                      "末尾留一点余量，定时器最后一跳不会正好落在 duration 上")
        XCTAssertFalse(TrackPlayer.isAtEnd(position: 5, duration: 10))
        XCTAssertFalse(TrackPlayer.isAtEnd(position: 0, duration: 0),
                       "没载入任何轨时 duration 为 0，不能判成「已在末尾」")
    }

    func testPlayAfterReachingEndRestartsFromBeginning() throws {
        // 播完停在末尾之后，按播放必须从头听。若不重置，
        // 会立刻又结束——表现就是「按钮按了没反应」。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 1, systemSeconds: nil)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        // 用 seek 把播放头推到末尾，等价于「刚播完」的状态。
        player.play([.mic])
        player.seek(to: player.duration)

        player.play([.mic])

        XCTAssertLessThan(player.position, 0.5, "播完再按播放 = 从头听")
        XCTAssertTrue(player.isPlaying)
    }

    func testPlayMidwayDoesNotRestart() throws {
        // 反向守卫：只有真在末尾才回落，播到一半按播放必须接着播。
        // 判据放宽过头就会把「继续」也弄丢，那比原bug 更糟。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: nil)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic])
        player.seek(to: 4)
        player.play([.mic])

        XCTAssertEqual(player.position, 4, accuracy: 0.3, "播到一半不该被当成播完了")
    }

    func testExplicitStartTimeBeatsTheEndFallback() throws {
        // 显式给了 startTime 就以它为准，不做「末尾回落」。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: nil)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic], from: 6)
        player.play([.mic], from: 2)

        XCTAssertEqual(player.position, 2, accuracy: 0.3)
    }

    // MARK: - 载入 / 清空要把暂停态一起清掉

    func testLoadClearsPausedState() throws {
        // 切场时如果留着 paused，新会议会被判成「可以继续上一场的暂停」，
        // 而且 resume 会把上一场的秒数带过来。
        let first = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: 10)
        let second = try makeSessionDirectory(id: "s2", micSeconds: 10, systemSeconds: nil)

        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: first)
        player.play([.mic], from: 5)
        player.pause()
        XCTAssertTrue(player.isPaused)

        player.load(sessionID: "s2", directory: second)

        XCTAssertFalse(player.isPaused, "换会议必须把暂停态清掉")
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.position, 0, accuracy: 0.001)
    }

    func testClearResetsPausedState() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 5, systemSeconds: 5)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)
        player.play([.mic], from: 3)
        player.pause()

        player.clear()

        XCTAssertFalse(player.isPaused)
        XCTAssertEqual(player.position, 0, accuracy: 0.001)
    }

    // MARK: - 多轨同步

    func testPausedBothTracksResumeInSync() throws {
        // 听抢话的前提是两轨对齐。同时暂停再同时继续，
        // 两轨必须回到**同一个**播放位置，否则对齐就白做了。
        //
        // **判据用 `requestedStartTimes` 而不是 `currentTime`**：无头环境
        // `AVAudioPlayer.currentTime` 恒为 0，拿它比等于 0 == 0，永远通过——
        // 这条用例改判据之前对「resume 起始位置写错」是完全瞎的。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: 10)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic, .system], from: 3)
        player.pause()
        player.resume()

        let mic = try XCTUnwrap(player.requestedStartTimes[.mic])
        let system = try XCTUnwrap(player.requestedStartTimes[.system])
        XCTAssertEqual(mic, system, accuracy: 0.2, "两轨必须同步继续，否则听不出抢话")
        XCTAssertEqual(mic, 3, accuracy: 0.2, "续播必须从暂停处起播，不能从0 开始")
    }

    /// 抓住「`resume()` 从 0 开始而不是从暂停处」这条变异（M-P07）。
    ///
    /// 这条需求「暂停后按继续接着听」在实现里只体现为一个参数：
    /// `seekPlayer(track, to: position)` 里的 `position` 写错成常量 0，
    /// 编译照过、界面照画、播放也确实从头开始——没有任何其他信号。
    func testResumeStartsFromPausedPositionNotZero() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 30, systemSeconds: 30)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic, .system], from: 12)
        player.pause()
        player.resume()

        let mic = try XCTUnwrap(player.requestedStartTimes[.mic])
        XCTAssertGreaterThan(mic, 10,
        "续播必须落在暂停处（约 12 秒）。这里读到接近 0 说明 resume() 把起点写死成 0 了")
    }

    /// 抓住「`seek()` 只动正在播的轨、暂停中的轨不跟随」这条变异（M-P12）。
    ///
    /// 症状是「暂停 → 拖进度条 → 继续」，听起来像跳了一下：
    /// 进度条动了，但暂停的那条轨还在旧位置。
    func testSeekWhilePausedMovesBothTracksIncludingPausedOnes() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 30, systemSeconds: 30)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic, .system], from: 2)
        player.pause()
        player.seek(to: 20)

        // 两条轨都在 `paused` 里，这一步必须两条都跟上。
        let mic = try XCTUnwrap(player.requestedStartTimes[.mic])
        let system = try XCTUnwrap(player.requestedStartTimes[.system])
        XCTAssertEqual(mic, 20, accuracy: 0.2, "暂停中的 mic 也必须跟随进度条")
        XCTAssertEqual(system, 20, accuracy: 0.2, "暂停中的 system 也必须跟随进度条")
    }

    func testPausingOneTrackLeavesTheOtherPlaying() throws {
        // 部分暂停：mic 停、system 继续放。此时 isPlaying 仍为真，
        // 底部按钮必须还显示「暂停」而不是「继续」。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: 10)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic, .system])
        player.toggleTrack(.mic)

        XCTAssertEqual(player.playing, [.system])
        XCTAssertEqual(player.paused, [.mic])
        XCTAssertTrue(player.isPlaying, "还有轨在放，就仍算正在播放")
    }

    func testResumeWithNothingLoadedIsHarmless() {
        // 界面刚起来、还没载入任何轨时，按钮也可能被点到。
        let player = TrackPlayer()
        player.pause()
        player.resume()
        player.stop()
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isPaused)
    }
}