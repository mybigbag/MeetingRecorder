import XCTest
@testable import MRSession
import MRCore

/// 会议库的单元测试。
///
/// 这一层之所以能被完整测试，是因为它**不碰 UI、不碰音频设备**：
/// 只做「读目录 → 变成可展示的条目」。真正的界面渲染不在这里测。
final class SessionLibraryTests: XCTestCase {

    private var root: URL!
    private var library: SessionLibrary!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-lib-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = SessionLibrary(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 辅助

    /// 造一场正常的会议：manifest + 两个真实长度的 wav
    @discardableResult
    private func makeSession(
        title: String,
        startedAt: Date,
        state: SessionState = .finalized,
        micSeconds: Double = 10,
        systemSeconds: Double = 10,
        writeFiles: Bool = true,
        withTranscript: Bool = false
    ) throws -> String {
        let store = SessionStore(root: root)
        let (id, dir) = try store.createSession(title: title, date: startedAt)
        var manifest = try store.loadManifest(forSessionID: id)
        manifest.state = state
        manifest.endedAt = startedAt.addingTimeInterval(max(micSeconds, systemSeconds))
        manifest.tracks = [
            TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                          sampleRate: 48000, channels: 1,
                          framesWritten: Int(micSeconds * 48000)),
            TrackManifest(id: "system", role: .systemAudio, fileName: "system.wav",
                          sampleRate: 48000, channels: 2,
                          framesWritten: Int(systemSeconds * 48000)),
        ]
        try store.save(manifest, sessionDirectory: dir)
        if writeFiles {
            for name in ["mic.wav", "system.wav"] {
                try Data(repeating: 0, count: 1024).write(to: dir.appendingPathComponent(name))
            }
        }
        if withTranscript {
            try "# 稿".write(to: dir.appendingPathComponent(SessionStore.transcriptMarkdownName),
                            atomically: true, encoding: .utf8)
        }
        return id
    }

    // MARK: - 空态

    func testEmptyRootReturnsEmptyList() {
        XCTAssertTrue(library.list().isEmpty)
    }

    func testMissingRootReturnsEmptyListInsteadOfThrowing() {
        // 首次使用、从未录过音的情形：目录根本不存在。
        // 这不该是错误，只是「还没东西」。
        let missing = SessionLibrary(root: root.appendingPathComponent("nope"))
        XCTAssertTrue(missing.list().isEmpty)
    }

    // MARK: - 正常读取

    func testListReadsTitleDurationAndTrackCount() throws {
        let id = try makeSession(title: "产品评审", startedAt: Date(), micSeconds: 842)
        let items = library.list()
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.title, "产品评审")
        XCTAssertEqual(item.duration, 842, accuracy: 0.001)
        XCTAssertEqual(item.existingTrackCount, 2)
        XCTAssertNil(item.loadError)
        XCTAssertFalse(item.needsAttention)
    }

    func testDurationComesFromTracksNotFromEndedAt() throws {
        // recording 状态下 endedAt 为空，manifest.duration 会随「现在」增长。
        // 列表里的数字不能自己跳，所以时长必须取音轨时长。
        let start = Date().addingTimeInterval(-3600)
        try makeSession(title: "录到一半", startedAt: start, state: .recording, micSeconds: 65)
        let item = try XCTUnwrap(library.list().first)
        XCTAssertEqual(item.duration, 65, accuracy: 0.001,
                       "应当用音轨时长，而不是 startedAt 到现在的 3600 秒")
    }

    // MARK: - 排序

    func testNewestFirst() throws {
        let base = Date()
        try makeSession(title: "最早", startedAt: base.addingTimeInterval(-300))
        try makeSession(title: "中间", startedAt: base.addingTimeInterval(-200))
        try makeSession(title: "最新", startedAt: base)
        XCTAssertEqual(library.list().map(\.title), ["最新", "中间", "最早"])
    }

    func testSameTimestampFallsBackToIDDescending() throws {
        // 同一秒内建两场（自动追加 -2），排序必须稳定
        let t = Date()
        try makeSession(title: "同名", startedAt: t)
        try makeSession(title: "同名", startedAt: t)
        let ids = library.list().map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids, ids.sorted(by: >), "时间相同时按 ID 倒序，保证结果稳定")
    }

    // MARK: - 容错：一个坏条目不能毁掉整个列表

    func testBrokenManifestDoesNotHideHealthySessions() throws {
        try makeSession(title: "好的", startedAt: Date())
        let badDir = root.appendingPathComponent("2026-09-27-000000-坏的", isDirectory: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try "{ 这不是 JSON".write(to: badDir.appendingPathComponent("manifest.json"),
                                 atomically: true, encoding: .utf8)

        let items = library.list()
        XCTAssertEqual(items.count, 2, "坏目录也要出现在列表里，否则用户会以为记录丢了")
        let bad = try XCTUnwrap(items.first { $0.id.contains("坏的") })
        XCTAssertNotNil(bad.loadError)
        XCTAssertTrue(bad.needsAttention)
        XCTAssertEqual(bad.title, bad.id, "读不出来时标题退回目录名")
        let good = try XCTUnwrap(items.first { $0.title == "好的" })
        XCTAssertNil(good.loadError, "坏条目不得影响好条目")
    }

    func testDirectoryWithoutManifestIsNotListed() throws {
        // 不是会议目录（没有 manifest.json）就不该出现在列表里
        let other = root.appendingPathComponent("随手放的文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertTrue(library.list().isEmpty)
    }

    func testDotDirectoriesAreIgnored() throws {
        let hidden = root.appendingPathComponent(".DS_Store", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try "{}".write(to: hidden.appendingPathComponent("manifest.json"),
                       atomically: true, encoding: .utf8)
        XCTAssertTrue(library.list().isEmpty)
    }

    func testManifestClaimingTracksThatDoNotExistCountsOnlyRealFiles() throws {
        // manifest 说有 2 轨，但用户手工删掉了 system.wav
        try makeSession(title: "缺文件", startedAt: Date(), writeFiles: false)
        let item = try XCTUnwrap(library.list().first)
        XCTAssertEqual(item.existingTrackCount, 0)
        XCTAssertNil(item.loadError, "文件缺失不是 manifest 损坏")
    }

    // MARK: - 转写状态

    func testHasTranscriptReflectsFilePresence() throws {
        try makeSession(title: "没转写", startedAt: Date())
        try makeSession(title: "转了", startedAt: Date(), withTranscript: true)
        let items = library.list()
        XCTAssertEqual(items.first { $0.title == "没转写" }?.hasTranscript, false)
        XCTAssertEqual(items.first { $0.title == "转了" }?.hasTranscript, true)
    }

    // MARK: - 修改

    func testRenameChangesTitleButNotDirectory() throws {
        let id = try makeSession(title: "旧名字", startedAt: Date())
        try library.rename(sessionID: id, to: "新名字")
        XCTAssertEqual(library.list().first?.title, "新名字")
        // 目录名（会话 ID）必须不变：转写稿与用户脚本可能已经引用它
        XCTAssertEqual(library.list().first?.id, id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(id).path))
    }

    func testRenameRejectsBlankTitle() throws {
        let id = try makeSession(title: "旧名字", startedAt: Date())
        XCTAssertThrowsError(try library.rename(sessionID: id, to: "   "))
    }

    func testRenameTrimsWhitespace() throws {
        let id = try makeSession(title: "旧名字", startedAt: Date())
        try library.rename(sessionID: id, to: "  带空格的  ")
        XCTAssertEqual(library.list().first?.title, "带空格的")
    }

    func testDeleteMissingSessionThrows() {
        XCTAssertThrowsError(try library.delete(sessionID: "根本不存在"))
    }

    func testDeleteRemovesFromList() throws {
        let id = try makeSession(title: "要删的", startedAt: Date())
        XCTAssertEqual(library.list().count, 1)
        try library.delete(sessionID: id)
        XCTAssertTrue(library.list().isEmpty)
    }
}
