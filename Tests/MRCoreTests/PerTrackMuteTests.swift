import XCTest
@testable import MRCore

/// 分轨静音（写静音帧）的纯逻辑测试。
///
/// 这里只测**能脱离设备测的部分**：manifest 的记录与时长口径。
/// 真正写静音帧的路径在 `TrackRecorder.handle` 的实时回调里，
/// 由 `RealRecordingIntegrationTests` 覆盖（真机、需要权限，默认跳过）。
final class PerTrackMuteTests: XCTestCase {

    // MARK: - 旧数据兼容

    /// **旧 manifest 里没有 `trackID` 键，必须解成「全局静音」。**
    ///
    /// 这是本次改动最容易埋雷的地方：若解成 `nil` 之外的什么值（例如空串），
    /// 历史会议的 `pausedTotal` 会变成 0——时长凭空多出一整段静音，
    /// 而界面上「已静音」的说明行也会消失，听的人完全无从察觉。
    func testLegacyPauseSpanDecodesAsGlobalMute() throws {
        let legacy = """
        {"startedAfter":60,"duration":90}
        """
        let span = try JSONDecoder().decode(PauseSpan.self, from: Data(legacy.utf8))
        XCTAssertNil(span.trackID, "缺 trackID 的旧记录必须当成全局静音")
        XCTAssertTrue(span.affects(trackID: "mic"))
        XCTAssertTrue(span.affects(trackID: "system"), "全局静音对每一轨都成立")
    }

    /// 显式的分轨记录要能往返。
    func testPauseSpanRoundTripKeepsTrackID() throws {
        let original = PauseSpan(startedAfter: 12.5, duration: 30.25, trackID: "mic")
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(PauseSpan.self, from: data)
        XCTAssertEqual(back.trackID, "mic")
        XCTAssertEqual(back, original)
    }

    // MARK: - affects

    func testGlobalMuteAffectsEveryTrack() {
        let span = PauseSpan(startedAfter: 0, duration: 10)
        XCTAssertTrue(span.affects(trackID: "mic"))
        XCTAssertTrue(span.affects(trackID: "system"))
        XCTAssertTrue(span.affects(trackID: "any-other-track"),
                      "全局静音对将来新增的轨同样成立")
    }

    func testSoloMuteAffectsOnlyItsOwnTrack() {
        let span = PauseSpan(startedAfter: 0, duration: 10, trackID: "mic")
        XCTAssertTrue(span.affects(trackID: "mic"))
        XCTAssertFalse(span.affects(trackID: "system"),
                       "只静音了我轨，对方轨不该被算进来——那会让两轨时长看起来不等")
    }

    // MARK: - 时长口径：这是最容易搞错的地方

    /// **分轨静音不得从时长里扣。**
    ///
    /// 静音写的是静音帧，文件长度不变，所以这一轨的内容时长本来就包含那段时间。
    /// 若把它扣掉，「我轨静音 10 分钟」会算成「这场会只有 5 分钟」，
    /// 而文件明明是 15 分钟——且任何地方都不会报错。
    func testSoloMuteIsNotDeductedFromPausedTotal() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = RecordingManifest(
            sessionID: "s", title: "会议",
            startedAt: started,
            endedAt: started.addingTimeInterval(900),   // 15 分钟
            state: .finalized,
            pauses: [
                PauseSpan(startedAfter: 60, duration: 600, trackID: "mic"),
            ])

        XCTAssertEqual(manifest.pausedTotal, 0, accuracy: 0.001,
                       "分轨静音不参与全局扣减")
        XCTAssertEqual(manifest.recordedDuration, 900, accuracy: 0.001,
                       "两轨文件都完整，时长就是墙钟跨度")
    }

    /// 全场静音照旧要扣。
    func testGlobalMuteIsStillDeducted() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = RecordingManifest(
            sessionID: "s", title: "会议",
            startedAt: started,
            endedAt: started.addingTimeInterval(900),
            state: .finalized,
            pauses: [
                PauseSpan(startedAfter: 60, duration: 300),                       // 全场
                PauseSpan(startedAfter: 400, duration: 100, trackID: "mic"),       // 单轨
            ])

        XCTAssertEqual(manifest.pausedTotal, 300, accuracy: 0.001,
                       "只算 trackID == nil 的那些")
        XCTAssertEqual(manifest.recordedDuration, 600, accuracy: 0.001)
    }

    /// 两种混在一起时不能互相串味。
    func testGlobalAndSoloMutesAreCountedSeparately() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = RecordingManifest(
            sessionID: "s", title: "会议",
            startedAt: started,
            endedAt: started.addingTimeInterval(600),
            state: .finalized,
            pauses: [
                PauseSpan(startedAfter: 10, duration: 60),
                PauseSpan(startedAfter: 100, duration: 30, trackID: "mic"),
                PauseSpan(startedAfter: 200, duration: 20, trackID: "mic"),
                PauseSpan(startedAfter: 300, duration: 40, trackID: "system"),
            ])

        XCTAssertEqual(manifest.pausedTotal, 60, accuracy: 0.001)
        XCTAssertEqual(manifest.soloMutedTotal(trackID: "mic"), 50, accuracy: 0.001)
        XCTAssertEqual(manifest.soloMutedTotal(trackID: "system"), 40, accuracy: 0.001)
    }

    /// 「这一轨一共被掐掉多久」含全局暂停——那段时间它同样没在录。
    func testMutedTotalIncludesGlobalMute() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = RecordingManifest(
            sessionID: "s", title: "会议",
            startedAt: started,
            endedAt: started.addingTimeInterval(600),
            state: .finalized,
            pauses: [
                PauseSpan(startedAfter: 10, duration: 60),                 // 全场
                PauseSpan(startedAfter: 100, duration: 30, trackID: "mic"),
            ])

        // 我轨：全场 60 + 自己的 30
        XCTAssertEqual(manifest.mutedTotal(trackID: "mic"), 90, accuracy: 0.001)
        // 对方轨：只有全场那 60
        XCTAssertEqual(manifest.mutedTotal(trackID: "system"), 60, accuracy: 0.001)
    }

    /// 坏数据（负时长）不能把静音总长算成负数。
    func testNegativeSoloMuteDoesNotProduceNegativeTotal() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = RecordingManifest(
            sessionID: "s", title: "会议",
            startedAt: started,
            endedAt: started.addingTimeInterval(60),
            state: .finalized,
            pauses: [PauseSpan(startedAfter: 10, duration: -30, trackID: "mic")])

        XCTAssertEqual(manifest.soloMutedTotal(trackID: "mic"), 0, accuracy: 0.001)
        XCTAssertEqual(manifest.pausedTotal, 0, accuracy: 0.001)
    }

    /// 旧 manifest 的 `pausedTotal` 口径必须与改动前完全一致。
    ///
    /// 旧数据里所有 `trackID` 都是 `nil`，所以新口径（只算 nil）与旧口径（算全部）
    /// 在旧数据上等价。这一条是**升级不能改变历史显示**的保证。
    func testLegacyManifestPausedTotalIsUnchangedByNewSemantics() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = RecordingManifest(
            sessionID: "s", title: "会议",
            startedAt: started,
            endedAt: started.addingTimeInterval(600),
            state: .finalized,
            pauses: [
                PauseSpan(startedAfter: 60, duration: 90),
                PauseSpan(startedAfter: 300, duration: 30),
            ])

        XCTAssertEqual(legacy.pausedTotal, 120, accuracy: 0.001)
        XCTAssertEqual(legacy.recordedDuration, 480, accuracy: 0.001)
    }

    // MARK: - TrackID

    /// 轨 id 同时是文件名主干，任何一个拼错都会让文件读不出来。
    func testTrackIDRawValuesMatchFileStems() {
        XCTAssertEqual(TrackID.mic.rawValue, "mic")
        XCTAssertEqual(TrackID.system.rawValue, "system")
    }

    func testTrackIDDisplayNameMatchesRole() {
        XCTAssertEqual(TrackID.mic.displayName, TrackRole.microphone.displayName)
        XCTAssertEqual(TrackID.system.displayName, TrackRole.systemAudio.displayName)
    }

    /// **每一轨的图标必须属于自己**，不能跨轨复用。
    ///
    /// 用户报过的现象：静音「对方」之后菜单上显示的是麦克风被划掉。
    /// 对方轨来自系统音频，与麦克风毫无关系——显示麦克风图标会让人
    /// 以为是自己这边被关了，从而按错误的判断去操作。
    ///
    /// 这里钉住两条：静音图标必须是 `slash` 版本（否则看不出"被静音"），
    /// 且两轨的图标字符串**不得相同**（相同就意味着画错了轨）。
    func testTrackIconsBelongToTheirOwnTrack() {
        XCTAssertEqual(TrackID.mic.activeIcon, "mic")
        XCTAssertEqual(TrackID.system.activeIcon, "speaker.wave.2")

        XCTAssertEqual(TrackID.mic.mutedIcon, "mic.slash")
        XCTAssertEqual(TrackID.system.mutedIcon, "speaker.slash")

        XCTAssertNotEqual(TrackID.mic.mutedIcon, TrackID.system.mutedIcon,
                          "两轨的静音图标相同：说明画界面时把轨搞混了")
        XCTAssertNotEqual(TrackID.mic.activeIcon, TrackID.system.activeIcon)
        XCTAssertNotEqual(TrackID.mic.mutedIcon, TrackID.mic.activeIcon,
                          "静音图标不能与在录图标相同，否则界面无法表达状态")
        XCTAssertNotEqual(TrackID.system.mutedIcon, TrackID.system.activeIcon,
                          "静音图标不能与在录图标相同，否则界面无法表达状态")
    }
}