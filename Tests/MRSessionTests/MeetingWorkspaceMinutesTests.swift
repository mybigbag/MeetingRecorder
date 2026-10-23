import XCTest
@testable import MRSession
import MRCore
import MRCapture

/// `MeetingWorkspace` 的纪要相关行为。
///
/// 三条主线，都是「界面骗人」类 bug 的高发区：
/// 1. 偏好要真落盘——「在设置里改了，重启后回默认」是最不易察觉的一类；
/// 2. 云端没配齐时必须**明确失败**，不能悄悄用本地模型写一份出来；
/// 3. 磁盘上已有的纪要（含旧格式）要能读回来——读不了的话，
///    生成过一次的会议在界面上看起来像从没生成过。
@MainActor
final class MeetingWorkspaceMinutesTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-ws-minutes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "mr-ws-minutes-prefs-\(UUID().uuidString)"
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

    /// 造一场已转写的会议（写真实 transcript.json）。
    @discardableResult
    private func makeTranscribedSession(title: String = "纪要测试会议") throws -> String {
        let store = SessionStore(root: root)
        let (id, dir) = try store.createSession(title: title, date: Date())
        var manifest = try store.loadManifest(forSessionID: id)
        manifest.state = .transcribed
        manifest.tracks = [
            TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                          sampleRate: 48000, channels: 1, framesWritten: 48000 * 5)
        ]
        try store.save(manifest, sessionDirectory: dir)
        let document = TranscriptDocument(
            sessionID: id, title: title, language: "zh-CN", engine: "test",
            segments: [
                TranscriptSegment(start: 0, end: 2, text: "我们先讨论排期",
                                  track: "mic", speaker: "我"),
                TranscriptSegment(start: 2, end: 4, text: "好的优先支付模块",
                                  track: "system", speaker: "对方"),
            ])
        try document.json()
            .write(to: dir.appendingPathComponent(SessionStore.transcriptJSONName))
        return id
    }

    private func settle(_ seconds: Double = 0.4) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - 偏好落盘

    /// 在 workspace 上改纪要偏好，必须真的落到偏好域——换个实例
    /// （= 下次启动应用）仍读得到。「只在内存里转一圈」的实现在这里露馅。
    func test_minutesPreferencesPersist() {
        let workspace = makeWorkspace()
        workspace.minutesProvider = .cloudAPI
        workspace.minutesAPIBaseURL = "https://api.deepseek.com/v1"
        workspace.minutesAPIKey = "sk-abc123"
        workspace.minutesModelName = "deepseek-chat"

        XCTAssertEqual(defaults.string(forKey: RecorderPreferences.minutesProviderKey), "api")
        XCTAssertEqual(defaults.string(forKey: RecorderPreferences.minutesAPIBaseURLKey),
                       "https://api.deepseek.com/v1")

        let reloaded = makeWorkspace()
        XCTAssertEqual(reloaded.minutesProvider, .cloudAPI)
        XCTAssertEqual(reloaded.minutesAPIBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(reloaded.minutesAPIKey, "sk-abc123")
        XCTAssertEqual(reloaded.minutesModelName, "deepseek-chat")
        XCTAssertTrue(reloaded.minutesCloudAPIIsComplete)
    }

    /// 清空输入框 = 真清除（空串语义与偏好层一致）。
    func test_clearingFieldsUnsetsPreferences() {
        let workspace = makeWorkspace()
        workspace.minutesAPIBaseURL = "https://api.deepseek.com/v1"
        workspace.minutesAPIBaseURL = ""
        XCTAssertFalse(workspace.minutesCloudAPIIsComplete)
        XCTAssertNil(defaults.string(forKey: RecorderPreferences.minutesAPIBaseURLKey))
    }

    // MARK: - 云端没配齐

    /// 选了云端但没配齐：`runMinutes` 必须失败并说清缺什么、敲什么，
    /// **且一个纪要文件都不写**。悄悄用本地模型写一份出来是署名不同的谎报。
    func test_runMinutes_blocksWhenCloudIncomplete() async throws {
        let id = try makeTranscribedSession()
        let workspace = makeWorkspace()
        workspace.minutesProvider = .cloudAPI
        workspace.minutesAPIKey = "sk-abc"  // 缺 URL 与模型名

        workspace.select(id)
        try await settle()
        XCTAssertNotNil(workspace.transcript, "夹具要有转写稿")

        workspace.runMinutes()

        guard case let .failed(message) = workspace.minutesPhase else {
            return XCTFail("没配齐必须失败，实际相位：\(workspace.minutesPhase)")
        }
        XCTAssertTrue(message.contains("Base URL"), "要说缺什么：\(message)")
        XCTAssertTrue(message.contains("config set minutes-url"), "要带命令：\(message)")

        let dir = SessionStore(root: root).directory(forSessionID: id)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(names.contains("minutes.md"), "失败不得写纪要文件：\(names)")
        XCTAssertFalse(names.contains("minutes.json"), "失败不得写纪要文件：\(names)")
    }

    /// 没转写稿时点「生成纪要」：明确失败，不发起调用。
    func test_runMinutes_withoutTranscript_failsClearly() throws {
        let store = SessionStore(root: root)
        let (id, _) = try store.createSession(title: "没转写", date: Date())
        let workspace = makeWorkspace()
        workspace.select(id)
        workspace.runMinutes()

        guard case let .failed(message) = workspace.minutesPhase else {
            return XCTFail("没稿子必须失败，实际：\(workspace.minutesPhase)")
        }
        XCTAssertTrue(message.contains("转写"), "：\(message)")
    }

    // MARK: - 磁盘上的既有纪要

    /// 磁盘上已有 minutes.json（**旧格式，无 generatorName**）：
    /// 选中这场要读得回来，相位是 `.done`。读不了的话，生成过的会议
    /// 在界面上看起来像从没生成过——而文件明明在。
    func test_existingMinutesAreLoadedOnSelect() async throws {
        let id = try makeTranscribedSession()
        let dir = SessionStore(root: root).directory(forSessionID: id)
        let oldJSON = """
        {"blocks":[],"blockSummaries":[],"generatedByModel":true,
        "minutes":{"summary":"磁盘上的旧纪要","keyPoints":["旧要点"],"decisions":[],
        "actionItems":[]},"polishedTranscript":"正文"}
        """
        try oldJSON.write(to: dir.appendingPathComponent(MinutesService.minutesJSONName),
                          atomically: true, encoding: .utf8)

        let workspace = makeWorkspace()
        workspace.select(id)
        try await settle()

        XCTAssertEqual(workspace.minutesResult?.minutes.summary, "磁盘上的旧纪要")
        XCTAssertEqual(workspace.minutesResult?.generatorName, "", "缺键默认空串")
        guard case .done = workspace.minutesPhase else {
            return XCTFail("有纪要文件应是 .done，实际：\(workspace.minutesPhase)")
        }
    }

    /// 本地生成器跑完：纪要文件落地、相位 .done。
    ///
    /// **不断言 generatedByModel**：本机是否支持 Apple Intelligence 因机型而异，
    /// 不支持时走既定的诚实降级（写仅原稿 + 标注未生成）。两条路径都算成功，
    /// 断言的共同底线是「文件落地、相位诚实」。
    func test_runMinutes_localPath_landsFiles() async throws {
        let id = try makeTranscribedSession()
        let workspace = makeWorkspace()
        workspace.select(id)
        try await settle()

        workspace.runMinutes()
        try await settle(1.5)

        guard case .done = workspace.minutesPhase else {
            return XCTFail("应走到 .done，实际：\(workspace.minutesPhase)")
        }
        let dir = SessionStore(root: root).directory(forSessionID: id)
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: dir.appendingPathComponent("minutes.md").path))
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: dir.appendingPathComponent("minutes.json").path))
    }
}
