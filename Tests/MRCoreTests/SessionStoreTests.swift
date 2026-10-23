import XCTest
@testable import MRCore

/// 会议文件夹布局。
///
/// 要求：每场会议一个纯文件夹、可读可 grep、**绝不覆盖已有会议**。
final class SessionStoreTests: XCTestCase {

    private var root: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-test-\(UUID().uuidString)", isDirectory: true)
        store = SessionStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - slug

    func testSlugKeepsChineseCharacters() {
        XCTAssertEqual(SessionStore.slugify("产品评审会"), "产品评审会")
        XCTAssertEqual(SessionStore.slugify("Q3 复盘"), "Q3-复盘")
    }

    func testSlugReplacesIllegalCharacters() {
        XCTAssertEqual(SessionStore.slugify("a/b:c*d?e\"f<g>h|i"), "a-b-c-d-e-f-g-h-i")
        XCTAssertEqual(SessionStore.slugify("line1\nline2"), "line1-line2")
        XCTAssertEqual(SessionStore.slugify("tab\there"), "tab-here")
    }

    func testSlugCollapsesDashesAndTrims() {
        XCTAssertEqual(SessionStore.slugify("a   b"), "a-b")
        XCTAssertEqual(SessionStore.slugify("  hello  "), "hello")
        XCTAssertEqual(SessionStore.slugify("a - b"), "a-b")
        XCTAssertEqual(SessionStore.slugify("...abc..."), "abc")
    }

    func testSlugTruncates() {
        let long = String(repeating: "会", count: 100)
        XCTAssertEqual(SessionStore.slugify(long).count, 40)
    }

    func testSlugOfAllIllegalIsEmpty() {
        XCTAssertEqual(SessionStore.slugify("   "), "")
        XCTAssertEqual(SessionStore.slugify("///"), "")
    }

    // MARK: - 会话 ID

    func testSessionIDFormat() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 27
        comps.hour = 14; comps.minute = 30; comps.second = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let date = cal.date(from: comps)!

        let id = SessionStore.makeSessionID(title: "产品评审", date: date, calendar: cal)
        XCTAssertEqual(id, "2026-09-27-143012-产品评审")
    }

    func testSessionIDFallsBackToTimestampWhenSlugEmpty() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 0)
        let id = SessionStore.makeSessionID(title: "///", date: date, calendar: cal)
        XCTAssertEqual(id, "1970-01-01-000000")
    }

    // MARK: - 目录

    func testEnsureRootCreatesDirectory() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try store.ensureRoot()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testEnsureRootIsIdempotent() throws {
        try store.ensureRoot()
        try store.ensureRoot()
    }

    func testCreateSessionMakesDirectory() throws {
        let (id, dir) = try store.createSession(title: "周会")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(dir.lastPathComponent, id)
        XCTAssertTrue(id.contains("周会"))
    }

    func testCreateSessionNeverOverwrites() throws {
        // 同一标题、同一时刻连开三次，必须得到三个不同目录
        let fixed = Date()
        let a = try store.createSession(title: "周会", date: fixed)
        let b = try store.createSession(title: "周会", date: fixed)
        let c = try store.createSession(title: "周会", date: fixed)

        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(b.id, c.id)
        XCTAssertTrue(b.id.hasSuffix("-2"))
        XCTAssertTrue(c.id.hasSuffix("-3"))
        for d in [a.directory, b.directory, c.directory] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: d.path))
        }
    }

    func testCreateSessionRefusesWhenRootIsAFile() throws {
        try Data("x".utf8).write(to: root)
        XCTAssertThrowsError(try store.createSession(title: "周会"))
    }

    // MARK: - 列举

    func testListSessionIDsSortedNewestFirst() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try store.createSession(title: "早", date: base)
        _ = try store.createSession(title: "晚", date: base.addingTimeInterval(3600))
        _ = try store.createSession(title: "中", date: base.addingTimeInterval(1800))

        let ids = try store.listSessionIDs()
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids, ids.sorted(by: >), "必须按时间倒序，最新的在最前")
        XCTAssertTrue(ids[0].contains("晚"))
    }

    func testListIgnoresNonSessionsAndHiddenFiles() throws {
        try store.ensureRoot()
        _ = try store.createSession(title: "有效")

        // 目录存在但没有 manifest —— 不是会话，不该被列出
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("2026-01-01-000000-残缺"), withIntermediateDirectories: true)
        // 隐藏文件
        try Data("{}".utf8).write(to: root.appendingPathComponent(".DS_Store"))

        let ids = try store.listSessionIDs()
        XCTAssertEqual(ids.count, 1)
        XCTAssertTrue(ids[0].contains("有效"))
    }

    func testListOnMissingRootReturnsEmpty() throws {
        XCTAssertEqual(try store.listSessionIDs().count, 0)
    }

    // MARK: - manifest 往返

    func testManifestRoundTripThroughStore() throws {
        let (id, dir) = try store.createSession(title: "评审")
        var m = RecordingManifest(sessionID: id, title: "评审")
        m.tracks = [
            TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                          sampleRate: 48000, channels: 1, framesWritten: 240000,
                          deviceName: "MacBook Air麦克风"),
            TrackManifest(id: "system", role: .systemAudio, fileName: "system.wav",
                          sampleRate: 48000, channels: 2, framesWritten: 479000),
        ]
        try store.save(m, sessionDirectory: dir)

        let loaded = try store.loadManifest(sessionDirectory: dir)
        XCTAssertEqual(loaded.sessionID, id)
        XCTAssertEqual(loaded.tracks.count, 2)
        XCTAssertEqual(loaded.track(id: "system")?.channels, 2)
        XCTAssertEqual(loaded.track(id: "mic")?.duration ?? 0, 5.0, accuracy: 1e-6)
    }

    func testTrackRoleDisplayNames() {
        XCTAssertEqual(TrackRole.microphone.displayName, "我")
        XCTAssertEqual(TrackRole.systemAudio.displayName, "对方")
    }

    /// 默认的 ISO8601 策略会丢掉小数秒，几秒级的录音会因此出现取整误差。
    func testManifestKeepsSubSecondPrecision() throws {
        let (id, dir) = try store.createSession(title: "精度")
        var m = RecordingManifest(
            sessionID: id, title: "精度",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000.456))
        m.endedAt = Date(timeIntervalSince1970: 1_700_000_005.789)
        try store.save(m, sessionDirectory: dir)

        let back = try store.loadManifest(sessionDirectory: dir)
        XCTAssertEqual(back.startedAt.timeIntervalSince1970, 1_700_000_000.456, accuracy: 0.002)
        XCTAssertEqual(back.endedAt!.timeIntervalSince1970, 1_700_000_005.789, accuracy: 0.002)
    }

    func testManifestReadsLegacyTimestampsWithoutFraction() throws {
        try store.ensureRoot()
        let dir = root.appendingPathComponent("2026-01-01-000000-旧格式")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = """
        {
          "sessionID" : "2026-01-01-000000-旧格式",
          "startedAt" : "2026-01-01T00:00:00Z",
          "state" : "finalized",
          "title" : "旧格式",
          "tracks" : [],
          "version" : 1
        }
        """
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("manifest.json"))

        let m = try store.loadManifest(sessionDirectory: dir)
        XCTAssertEqual(m.title, "旧格式")
        XCTAssertEqual(m.startedAt.timeIntervalSince1970, 1_767_225_600, accuracy: 1)
    }

    func testStateNeedsAttention() {
        XCTAssertTrue(SessionState.crashed.needsAttention)
        XCTAssertFalse(SessionState.recording.needsAttention)
        XCTAssertFalse(SessionState.finalized.needsAttention)
        XCTAssertFalse(SessionState.recovered.needsAttention)
    }

    func testDurationFormatting() {
        XCTAssertEqual(SessionStore.formatDuration(0), "0:00")
        XCTAssertEqual(SessionStore.formatDuration(59), "0:59")
        XCTAssertEqual(SessionStore.formatDuration(61), "1:01")
        XCTAssertEqual(SessionStore.formatDuration(3661), "1:01:01")
    }

    // MARK: - 摘要与「盘上真的有什么」

    /// manifest 记的是「当初录了什么」，不是「现在盘上有什么」。
    /// 保留策略只删音频、故意留 manifest，所以两者不一致从罕见异常变成了
    /// 清理之后的**正常状态**。这条用例守的就是那个转折点。
    private func summaryFixture() -> RecordingManifest {
        RecordingManifest(sessionID: "s1", title: "老会议",
                          startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                          endedAt: Date(timeIntervalSince1970: 1_780_000_600),
                          state: .finalized,
                          tracks: [
            TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                          sampleRate: 48000, channels: 1, framesWritten: 48_000 * 600),
            TrackManifest(id: "system", role: .systemAudio, fileName: "system.wav",
                          sampleRate: 48000, channels: 2, framesWritten: 48_000 * 600),
        ])
    }

    /// 不给`existingFileNames` 时按老口径显示（恢复流程的诊断输出依赖它）。
    func testSummaryWithoutFileListShowsTracksAsRecorded() {
        let text = SessionStore.summary(of: summaryFixture())
        XCTAssertTrue(text.contains("[我] mic"))
        XCTAssertFalse(text.contains("音频已被清理"),
                       "不给盘上清单时不该说「已清理」——那是在断言一件不知道的事")
    }

    /// 音频都不在了就**逐条标出来**，并在末尾补一句总括。
    ///
    /// 少了这个标注，用户会看到一列格式完好的音轨，点进去什么都没有——
    /// 而 `mr list` 的输出里没有任何线索指向「盘上其实没了」。
    func testSummaryFlagsTracksWhoseFilesAreGone() {
        let text = SessionStore.summary(of: summaryFixture(), existingFileNames: [])
        XCTAssertTrue(text.contains("音频已被清理（转写稿保留）"))
        XCTAssertEqual(text.components(separatedBy: "音频已被清理").count - 1, 2,
                       "两条轨都该被标出来")
        XCTAssertTrue(text.contains("转写稿与 manifest 仍然保留"))
    }

    /// 只少一条时，只标那一条——全标等于没标。
    func testSummaryFlagsOnlyTheMissingTrack() {
        let text = SessionStore.summary(of: summaryFixture(),
                                        existingFileNames: ["mic.wav"])
        XCTAssertEqual(text.components(separatedBy: "音频已被清理").count - 1, 1)
        XCTAssertFalse(text.contains("音频都不在了"))
    }

    /// 空的 `existingFileNames`（空目录）与「不给」是两件事，行为不能混。
    func testEmptyTrackListIsNotReportedAsPruned() {
        let empty = RecordingManifest(sessionID: "s2", title: "什么都没有",
                                     startedAt: Date(timeIntervalSince1970: 1_780_000_000))
        let text = SessionStore.summary(of: empty, existingFileNames: [])
        XCTAssertFalse(text.contains("音频已被清理"))
        XCTAssertFalse(text.contains("音频都不在了"))
    }
}
