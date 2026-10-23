import XCTest
@testable import MRGUI
import MRCore

/// 播放按钮三态文案的测试。
///
/// **为什么文案也要测**：这是用户唯一能看到的判据。图标只有
/// play / pause 两种，三种状态里「从头播」和「接着播」用的是**同一个图标**，
/// 全靠标题和提示区分。判据写错，界面就答非所问——而这在编译期完全看不出来。
@MainActor
final class TransportControlLabelTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-label-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeTrack(named name: String, seconds: Double,
                            channels: Int = 1, into directory: URL) throws {
        let writer = try WAVWriter(url: directory.appendingPathComponent(name),
                                   sampleRate: 48000, channels: channels)
        let batch = [Float](repeating: 0.1, count: 4800 * channels)
        var remaining = Int(seconds * 48000)
        while remaining > 0 {
            let frames = min(4800, remaining)
            try writer.append(Array(batch.prefix(frames * channels)))
            remaining -= frames
        }
        try writer.finalize()
    }

    private func makePlayer() throws -> TrackPlayer {
        let dir = root.appendingPathComponent("s1", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeTrack(named: "mic.wav", seconds: 10, into: dir)
        try writeTrack(named: "system.wav", seconds: 10, channels: 2, into: dir)
        let player = TrackPlayer()
        player.load(sessionID: "s1", directory: dir)
        return player
    }

    // MARK: - 标题三态

    func testTitleIsPlayWhenIdle() throws {
        let player = try makePlayer()
        XCTAssertEqual(MeetingDetailView.transportTitle(player), "两轨同时播放")
        XCTAssertEqual(MeetingDetailView.transportSymbol(player), "play.fill")
    }

    func testTitleIsPauseWhilePlaying() throws {
        let player = try makePlayer()
        player.play([.mic, .system])
        XCTAssertEqual(MeetingDetailView.transportTitle(player), "暂停")
        XCTAssertEqual(MeetingDetailView.transportSymbol(player), "pause.fill")
    }

    func testTitleIsResumeWhilePaused() throws {
        // 关键一态：暂停之后必须说「继续」，而不是又变回「两轨同时播放」。
        // 后者会让用户以为暂停丢了位置。
        let player = try makePlayer()
        player.play([.mic], from: 3)
        player.pause()
        XCTAssertEqual(MeetingDetailView.transportTitle(player), "继续")
        XCTAssertEqual(MeetingDetailView.transportSymbol(player), "play.fill")
    }

    func testTitleReturnsToPlayAfterStop() throws {
        let player = try makePlayer()
        player.play([.mic], from: 3)
        player.stop()
        XCTAssertEqual(MeetingDetailView.transportTitle(player), "两轨同时播放")
    }

    func testTitleStaysPauseWhenOnlyOneTrackPaused() throws {
        // 部分暂停（mic停、system还在放）时 isPlaying 仍为真，
        // 标题必须还是「暂停」，不能因为有轨进了 paused 就变成「继续」。
        let player = try makePlayer()
        player.play([.mic, .system])
        player.toggleTrack(.mic)
        XCTAssertEqual(MeetingDetailView.transportTitle(player), "暂停")
    }

    // MARK: - 提示文案

    func testResumeHelpStatesTheActualPosition() throws {
        let player = try makePlayer()
        player.play([.mic], from: 3)
        player.pause()
        let help = MeetingDetailView.transportHelp(player)
        XCTAssertTrue(help.contains("00:03"),
                      "续播提示必须带上真实位置，否则用户不知道会从哪继续：\(help)")
    }

    func testTrackHelpDistinguishesResumeFromFreshStart() throws {
        // 同一个图标要区分两种语义，全靠提示。
        let player = try makePlayer()

        let fresh = MeetingDetailView.trackButtonHelp(player: player, track: .mic)
        XCTAssertTrue(fresh.contains("播放"), "没暂停过就是播放：\(fresh)")

        player.play([.mic], from: 5)
        player.pause()
        let resumed = MeetingDetailView.trackButtonHelp(player: player, track: .mic)
        XCTAssertTrue(resumed.contains("继续"), "暂停过就该说继续：\(resumed)")
        XCTAssertTrue(resumed.contains("00:05"), "要带上位置：\(resumed)")
    }

    func testTrackHelpSaysAligningWhenJoiningAnAlreadyRunningTrack() throws {
        // 已有一条轨在放时加入另一条，位置必须对齐——听抢话全靠这个。
        let player = try makePlayer()
        player.play([.mic], from: 2)
        let help = MeetingDetailView.trackButtonHelp(player: player, track: .system)
        XCTAssertTrue(help.contains("对齐") || help.contains("00:02"), help)
    }

    func testTrackHelpWhilePlayingSaysPause() throws {
        let player = try makePlayer()
        player.play([.mic])
        let help = MeetingDetailView.trackButtonHelp(player: player, track: .mic)
        XCTAssertTrue(help.contains("暂停"), help)
    }
}