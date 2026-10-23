import XCTest
@testable import MRSession
import MRCore
import MRMinutes

/// 工作区层面的人工修正转写稿：**改动落盘、失败回滚、纪要过期提醒**。
///
/// 纯逻辑见 `TranscriptEditTests`（MRCoreTests）。这一组只问三件只有在
/// 真实磁盘上才答得出来的事：
/// 1. 改完是不是真写进了 `transcript.json` **和** `transcript.md`（两份文件不能互相打脸）；
/// 2. 写盘失败时内存里的稿子有没有退回改之前（不然界面显示改后、文件是改前）；
/// 3. 稿子改过之后，「纪要基于旧稿」这条提示会不会亮。
@MainActor
final class TranscriptEditingTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "mr-edit-prefs-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    private func makeWorkspace() -> MeetingWorkspace {
        MeetingWorkspace(root: root, preferences: RecorderPreferences(defaults: defaults))
    }

    private func settle(_ seconds: Double = 0.4) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// 造一场已转写的会议，可选再放一份 `minutes.json`。
    @discardableResult
    private func makeSession(withMinutes: Bool = false) throws -> (id: String, dir: URL) {
        let store = SessionStore(root: root)
        let (id, dir) = try store.createSession(title: "人工修正测试", date: Date())
        var manifest = try store.loadManifest(forSessionID: id)
        manifest.state = .transcribed
        try store.save(manifest, sessionDirectory: dir)

        let document = TranscriptDocument(
            sessionID: id, title: "人工修正测试", language: "zh-CN", engine: "test",
            segments: [
                TranscriptSegment(start: 0, end: 2, text: "回度到百分之五十",
                                  track: "mic", speaker: "我"),
                TranscriptSegment(start: 2, end: 4, text: "嗯，好，那个",
                                  track: "mic", speaker: "我"),
            ])
        try document.json()
            .write(to: dir.appendingPathComponent(SessionStore.transcriptJSONName))
        try document.markdown()
            .write(to: dir.appendingPathComponent(SessionStore.transcriptMarkdownName),
                   atomically: true, encoding: .utf8)

        if withMinutes {
            // 先写稿再写纪要 → 正常时间顺序（纪要基于这份稿子）。
            let minutes = MinutesResult(
                blocks: [], blockSummaries: [],
                minutes: MeetingMinutes(summary: "旧摘要"),
                polishedTranscript: "", generatedByModel: true, generatorName: "测试模型")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(minutes)
                .write(to: dir.appendingPathComponent(MinutesService.minutesJSONName))
        }
        return (id, dir)
    }

    private func onDisk(_ dir: URL) throws -> TranscriptDocument {
        let data = try Data(contentsOf: dir.appendingPathComponent(SessionStore.transcriptJSONName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptDocument.self, from: data)
    }

    // MARK: - 落盘

    /// 改一个字：内存、`transcript.json`、`transcript.md` 三处必须同时是改后的样子。
    ///
    /// 只写 json 的实现在这里露馅——用户在访达打开的还是错字那一版，
    /// 而界面上显示的是改后的，**两份文件互相打脸且不报错**。
    func testEditReachesBothFiles() async throws {
        let (id, dir) = try makeSession()
        let workspace = makeWorkspace()
        workspace.select(id)
        try await settle()
        XCTAssertNotNil(workspace.transcript, "夹具要有转写稿")

        workspace.setTranscriptText(at: 0, to: "灰度到 50%")

        XCTAssertEqual(workspace.transcript?.segments[0].text, "灰度到 50%")
        XCTAssertEqual(workspace.transcript?.segments[0].manualEdit, .corrected)

        let persisted = try onDisk(dir)
        XCTAssertEqual(persisted.segments[0].text, "灰度到 50%", "json 必须落盘")
        XCTAssertEqual(persisted.segments[0].originalText, "回度到百分之五十")

        let md = try String(contentsOf: dir.appendingPathComponent(SessionStore.transcriptMarkdownName),
                            encoding: .utf8)
        XCTAssertTrue(md.contains("灰度到 50%"), "md 必须一起更新：\n\(md)")
        XCTAssertFalse(md.contains("回度到百分之五十"), "md 里不该还留着旧文字：\n\(md)")
    }

    /// 清空一段：正文变空、标记 `cleared`、原文留在磁盘上（供「恢复原文」）。
    func testClearReachesDiskAndKeepsTheOriginal() async throws {
        let (id, dir) = try makeSession()
        let workspace = makeWorkspace()
        workspace.select(id)
        try await settle()

        workspace.clearTranscriptSegment(at: 1)

        XCTAssertEqual(workspace.transcript?.segments[1].manualEdit, .cleared)
        let persisted = try onDisk(dir)
        XCTAssertTrue(persisted.segments[1].isBlank)
        XCTAssertEqual(persisted.segments[1].originalText, "嗯，好，那个")

        let md = try String(contentsOf: dir.appendingPathComponent(SessionStore.transcriptMarkdownName),
                            encoding: .utf8)
        XCTAssertTrue(md.contains("（已人工清空）"), "清空的那一行要写明：\n\(md)")
    }

    /// 「恢复原文」也要落盘，否则下次打开又变成空的。
    func testRestoreReachesDisk() async throws {
        let (id, dir) = try makeSession()
        let workspace = makeWorkspace()
        workspace.select(id)
        try await settle()

        workspace.clearTranscriptSegment(at: 0)
        workspace.restoreTranscriptSegment(at: 0)

        let persisted = try onDisk(dir)
        XCTAssertEqual(persisted.segments[0].text, "回度到百分之五十")
        XCTAssertNil(persisted.segments[0].manualEdit, "回到原文就不该再挂「已修改」")
    }

    /// 没改动的赋值不该写盘（按一下方向键就重写文件的实现会在这里露出 mtime 变化）。
    func testNoOpEditDoesNotTouchTheFile() async throws {
        let (id, dir) = try makeSession()
        let workspace = makeWorkspace()
        workspace.select(id)
        try await settle()

        let url = dir.appendingPathComponent(SessionStore.transcriptJSONName)
        let before = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        workspace.setTranscriptText(at: 0, to: "回度到百分之五十")   // 与当前一致
        workspace.setTranscriptText(at: 99, to: "越界")              // 越界

        let after = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "没有改动却重写了文件")
    }

    // MARK: - 写失败必须回滚（阴性对照）

    /// 写盘失败：报错 + **内存退回改之前**。
    ///
    /// 只报错不回滚的话，界面显示改后的、文件是改前的，重新加载一次就凭空复原——
    /// 用户会以为是自己没改成功，然后再改一遍。
    ///
    /// 造失败的办法：改之前把会话目录删掉（目录不在，写文件必然抛错）。
    func testSaveFailureRollsBackAndReports() async throws {
        let (id, dir) = try makeSession()
        let workspace = makeWorkspace()
        workspace.select(id)
        try await settle()
        XCTAssertEqual(workspace.transcript?.segments[0].text, "回度到百分之五十")

        try FileManager.default.removeItem(at: dir)

        workspace.setTranscriptText(at: 0, to: "灰度到 50%")

        XCTAssertNotNil(workspace.lastError, "写盘失败必须报出来")
        XCTAssertEqual(workspace.transcript?.segments[0].text, "回度到百分之五十",
                       "写盘失败时内存必须退回改之前，否则界面与磁盘不一致")
    }

    // MARK: - 纪要过期提示

    /// 稿子比纪要新（＝改过稿但没重跑纪要）→ 提示亮。
    ///
    /// 判据取自文件 mtime，所以**关掉 App 再打开依然成立**——
    /// 内存标志做不到这一点，而用户正是在下次打开时才最需要看到它。
    func testStaleFlagComesFromFileTimestamps() async throws {
        let (id, dir) = try makeSession(withMinutes: true)
        // 把稿子的 mtime 拨到纪要之后，模拟「改完稿没重新生成纪要」。
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: dir.appendingPathComponent(SessionStore.transcriptJSONName).path)

        let workspace = makeWorkspace()
        workspace.select(id)
        try await settle()

        XCTAssertTrue(workspace.transcriptChangedAfterMinutes,
                      "稿子比纪要新时必须提示「纪要基于旧稿」")
    }

    /// 正常顺序（先稿后纪要）→ 不提示。假提示会让用户忽略真提示。
    func testFreshMinutesDoNotRaiseTheStaleFlag() async throws {
        let (id, _) = try makeSession(withMinutes: true)
        let workspace = makeWorkspace()
        workspace.select(id)
        try await settle()

        XCTAssertFalse(workspace.transcriptChangedAfterMinutes)
    }

    /// 在界面上改一处 → 提示立刻亮（不用等下次加载）。
    func testEditingRaisesTheStaleFlagImmediately() async throws {
        let (id, _) = try makeSession(withMinutes: true)
        let workspace = makeWorkspace()
        workspace.select(id)
        try await settle()
        XCTAssertFalse(workspace.transcriptChangedAfterMinutes)

        workspace.setTranscriptText(at: 0, to: "灰度到 50%")

        XCTAssertTrue(workspace.transcriptChangedAfterMinutes)
    }

    /// 没有纪要时不该亮：那份提示说的是「你手上这份纪要是旧的」，
    /// 而根本没有纪要时它没有宾语。
    func testNoStaleFlagWithoutMinutes() async throws {
        let (id, _) = try makeSession(withMinutes: false)
        let workspace = makeWorkspace()
        workspace.select(id)
        try await settle()

        workspace.setTranscriptText(at: 0, to: "灰度到 50%")
        XCTAssertFalse(workspace.transcriptChangedAfterMinutes)
    }

    // MARK: - 提交必须打给「草稿所属的那一场」

    /// 防抖提交可能发生在**用户已经切走之后**：那时 `selectedID` 指向另一场。
    ///
    /// 若按 `selectedID` 写，就是把上一场的内容写进**另一场**的 `transcript.json`——
    /// 两场段数不同时多半是下标越界、什么都没发生；段数相同就静默改坏别人的稿子，
    /// 而界面上一点迹象都没有。这一条就是为了钉死这一点。
    func testEditTargetsTheDraftSessionNotTheCurrentSelection() async throws {
        let (first, firstDir) = try makeSession()
        let (second, secondDir) = try makeSession()
        let workspace = makeWorkspace()
        workspace.select(first)
        try await settle()
        // 用户切走了：草稿簿里的 flush 会在这之后才发生。
        workspace.select(second)
        try await settle()
        XCTAssertEqual(workspace.transcript?.sessionID, second, "夹具前提：界面上是第二场")

        let ok = workspace.setTranscriptText(at: 0, to: "第一场改过的字", forSessionID: first)

        XCTAssertTrue(ok)
        XCTAssertEqual(try onDisk(firstDir).segments[0].text, "第一场改过的字",
                       "改动必须落进它自己那一场")
        XCTAssertEqual(try onDisk(secondDir).segments[0].text, "回度到百分之五十",
                       "另一场的稿子一个字都不许动")
        XCTAssertEqual(workspace.transcript?.segments[0].text, "回度到百分之五十",
                       "界面上显示的是第二场，不该被第一场的改动带着走")
    }
}
