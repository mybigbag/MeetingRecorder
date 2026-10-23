import XCTest
@testable import MRGUI
import MRCore

/// 双轨试听的单元测试。
///
/// 为什么值得单独测：这个工具的整个立论是「**音轨即说话人身份**」，
/// 而验证它最直接的办法就是分别听两条轨。但「播放」这件事恰恰是界面冒烟测试
/// **点不出来**的——截图只能证明按钮画对了，证明不了 `load` 有没有残留上一场的音频、
/// `seek` 会不会越界、缺一条轨时还能不能正常播。
///
/// 这里用真实写出的 WAV 文件驱动，不 mock 文件系统：`AVAudioPlayer` 的行为
/// 只在真文件上才有意义。
@MainActor
final class TrackPlayerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-player-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 夹具

    /// 在 `directory` 下写一条真实可读的 WAV。`seconds` 决定时长。
    private func writeTrack(
        named name: String,
        seconds: Double,
        channels: Int = 1,
        into directory: URL
    ) throws {
        let url = directory.appendingPathComponent(name)
        let writer = try WAVWriter(url: url, sampleRate: 48000, channels: channels)
        // 4800 个 float 一批，写满需要的帧数
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

    // MARK: - 载入

    func testLoadReadsBothTracks() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 3, systemSeconds: 3)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        XCTAssertTrue(player.canPlay(.mic))
        XCTAssertTrue(player.canPlay(.system))
        XCTAssertTrue(player.loadErrors.isEmpty)
    }

    func testDurationIsTheLongerTrack() throws {
        // 两轨长度本来就可能差几十毫秒，进度条要按最长的那条走，
        // 否则短的播完了、界面还在跑。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 2, systemSeconds: 5)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        XCTAssertEqual(player.duration, 5, accuracy: 0.2)
    }

    func testMissingTrackIsReportedNotSilentlyDropped() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 2, systemSeconds: nil)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        XCTAssertTrue(player.canPlay(.mic))
        XCTAssertFalse(player.canPlay(.system))
        XCTAssertNotNil(player.loadErrors[.system], "缺文件必须说出来，不能装作只有一条轨")
    }

    func testLoadReplacesPreviousSession() throws {
        // 切换会议时如果不清空，会播到**上一场**的音频，而界面显示的是这一场。
        // 这类错位比直接报错更难发现，所以专门测一条。
        let first = try makeSessionDirectory(id: "s1", micSeconds: 2, systemSeconds: 2)
        let second = try makeSessionDirectory(id: "s2", micSeconds: 7, systemSeconds: nil)

        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: first)
        XCTAssertEqual(player.duration, 2, accuracy: 0.2)
        XCTAssertTrue(player.canPlay(.system))

        player.load(sessionID: "s2", directory: second)
        XCTAssertEqual(player.duration, 7, accuracy: 0.2, "时长必须换成新会议的")
        XCTAssertFalse(player.canPlay(.system), "上一场有的轨不能残留")
        XCTAssertNotNil(player.loadErrors[.system])
    }

    func testClearResetsEverything() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 2, systemSeconds: 2)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)
        XCTAssertGreaterThan(player.duration, 0)

        player.clear()
        XCTAssertEqual(player.duration, 0)
        XCTAssertEqual(player.position, 0)
        XCTAssertFalse(player.canPlay(.mic))
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.loadErrors.isEmpty)
    }

    func testLoadOnEmptyDirectoryReportsBothMissing() throws {
        let dir = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let player = TrackPlayer()
        player.load(sessionID: "empty", directory: dir)
        XCTAssertEqual(player.loadErrors.count, 2)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.duration, 0)
    }

    // MARK: - 播放控制

    func testPlaySingleTrack() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 3, systemSeconds: 3)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic])
        XCTAssertEqual(player.playing, [.mic])
        XCTAssertTrue(player.isPlaying)

        player.stop()
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.playing.isEmpty)
    }

    func testPlayBothTracksSimultaneously() throws {
        // 「两轨同时播放」是听抢话的唯一办法，必须两条都在 playing 里。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 3, systemSeconds: 3)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic, .system])
        XCTAssertEqual(player.playing, [.mic, .system])

        player.stop()
    }

    func testPlayIgnoresTracksWithoutFiles() throws {
        // 缺一条轨时只播能播的那条，而不是把缺失轨也算进「正在播放」——
        // 那会让「播完了自动停」的判定永远为假，进度条卡在末尾。
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 2, systemSeconds: nil)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic, .system])
        XCTAssertEqual(player.playing, [.mic], "打不开的轨不该出现在 playing 里")

        player.stop()
    }

    func testPlayWithNothingPlayableDoesNothing() throws {
        let dir = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let player = TrackPlayer()
        player.load(sessionID: "empty", directory: dir)
        player.play([.mic, .system])
        XCTAssertFalse(player.isPlaying)
    }

    func testPlayStartsFromRequestedPosition() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 10, systemSeconds: 10)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.play([.mic], from: 4)
        XCTAssertEqual(player.position, 4, accuracy: 0.001)

        player.stop()
    }

    func testToggleTrackAddsAndRemoves() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 5, systemSeconds: 5)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.toggleTrack(.mic)
        XCTAssertEqual(player.playing, [.mic])

        player.toggleTrack(.system)
        XCTAssertEqual(player.playing, [.mic, .system])

        player.toggleTrack(.mic)
        XCTAssertEqual(player.playing, [.system])

        player.stop()
    }

    func testToggleTrackWithoutFileIsIgnored() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 5, systemSeconds: nil)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.toggleTrack(.system)
        XCTAssertTrue(player.playing.isEmpty)
    }

    // MARK: - seek

    func testSeekClampsToBounds() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 5, systemSeconds: 5)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.seek(to: 2)
        XCTAssertEqual(player.position, 2, accuracy: 0.001)

        player.seek(to: -10)
        XCTAssertEqual(player.position, 0, accuracy: 0.001, "负数要夹到 0")

        player.seek(to: 9999)
        XCTAssertEqual(player.position, player.duration, accuracy: 0.001, "超出要夹到时长")
    }

    // MARK: - 增益

    func testGainChangeWithoutLoadedTracksIsHarmless() {
        // 音量滑块在没载入任何轨时也可能被拖动（比如刚启动界面）
        let player = TrackPlayer()
        player.micGain = 0.5
        player.systemGain = 2
        XCTAssertEqual(player.micGain, 0.5)
        XCTAssertEqual(player.systemGain, 2)
    }

    func testGainChangeWithLoadedTracksApplies() throws {
        let dir = try makeSessionDirectory(id: "s1", micSeconds: 2, systemSeconds: 2)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)

        player.micGain = 0.25
        player.systemGain = 0.75
        XCTAssertEqual(player.micGain, 0.25)
        XCTAssertEqual(player.systemGain, 0.75)
    }
}
