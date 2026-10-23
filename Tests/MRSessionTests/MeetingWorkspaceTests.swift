import XCTest
@testable import MRSession
import MRCore
import MRCapture

/// `MeetingWorkspace` 的单元测试——**界面状态中枢**。
///
/// 这一层是本项目所有「界面骗人」类 bug 的高发区，因此测得比别的层更细：
///  - 「还没查」被说成「没有」（`hasScanned`）
///  - 「没授权」被说成「没数据」（`Access.permissionDenied`）
///  - 详情区显示的是**上一场**的音轨与文稿（迟到的读取结果回填）
///
/// 前两个都真实发生并被用户看到过；第三个是同类结构里最容易复发的一个。
/// 全部用临时目录 + 伪造 manifest 驱动，不碰窗口、不碰音频设备、不需要任何权限。
@MainActor
final class MeetingWorkspaceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-ws-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 夹具

    /// 造一场会议。`segments` 非 nil 时同时写出真实的 transcript.json / .md。
    @discardableResult
    private func makeSession(
        title: String,
        startedAt: Date,
        micSeconds: Double = 5,
        segments: Int? = nil
    ) throws -> String {
        let store = SessionStore(root: root)
        let (id, dir) = try store.createSession(title: title, date: startedAt)
        var manifest = try store.loadManifest(forSessionID: id)
        manifest.state = .finalized
        manifest.endedAt = startedAt.addingTimeInterval(micSeconds)
        manifest.tracks = [
            TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                          sampleRate: 48000, channels: 1,
                          framesWritten: Int(micSeconds * 48000))
        ]
        try store.save(manifest, sessionDirectory: dir)
        try Data(repeating: 0, count: 512)
            .write(to: dir.appendingPathComponent("mic.wav"))

        if let segments {
            let document = TranscriptDocument(
                sessionID: id, title: title, language: "zh-CN", engine: "test",
                segments: (0..<segments).map {
                    TranscriptSegment(start: Double($0), end: Double($0) + 0.5,
                                      text: "第 \($0) 句", track: "mic", speaker: "我")
                })
            try document.json()
                .write(to: dir.appendingPathComponent(SessionStore.transcriptJSONName))
            try document.markdown()
                .write(to: dir.appendingPathComponent(SessionStore.transcriptMarkdownName),
                       atomically: true, encoding: .utf8)
        }
        return id
    }

    /// 等挂起的 Task 落地。异步编排（`selectedID.didSet`、`delete`）都会自己起 Task，
    /// 测试必须给它们机会跑完，否则断言的是中间状态。
    private func settle(_ seconds: Double = 0.4) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// 轮询等到条件成立，最多等 `timeout` 秒。
    ///
    /// **为什么不干脆用 `settle()` 固定睡一会儿**：`startRecording` 把引擎工厂丢进
    /// `Task.detached`，状态还要再绕回主线程（`beginRecording`），是两跳异步。
    /// 固定睡眠等于把「机器多快」写进了测试前提——机器一慢就红，而生产代码是对的。
    /// 实测：给 `start()` 注入 700ms 延迟（> `settle` 默认的 400ms），下面三条
    /// 「格式偏好进了配置」的用例会**全部失败**，尽管功能完全正常。
    /// 改成「等到条件成立为止」之后，等待时长只由真实进度决定。
    private func waitUntil(
        _ description: String,
        timeout: Double = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("等待超时：\(description)", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - 第一次启动：不能急着说「没有记录」

    func testFreshWorkspaceDoesNotClaimEmptyBeforeScanning() {
        // 这是本类型存在 `hasScanned` 的全部理由。
        // 少了它，界面在首次布局的一瞬间就会宣称「还没有会议记录」——
        // 而那时连目录都还没打开过。用户会以为录音丢了。
        let workspace = MeetingWorkspace(root: root)
        XCTAssertFalse(workspace.hasScanned)
        XCTAssertTrue(workspace.meetings.isEmpty)
        XCTAssertNil(workspace.emptyStateMessage,
                     "还没扫过磁盘就不能下「没有记录」的结论")
        XCTAssertFalse(workspace.isScanning)
    }

    func testEmptyAfterScanDoesSayNoSessions() async {
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()
        XCTAssertTrue(workspace.hasScanned)
        XCTAssertEqual(workspace.emptyStateMessage,
                       "还没有会议记录。点「开始录制」录第一场。")
    }

    // MARK: - 扫描

    func testRefreshAsyncPopulatesListAndAccess() async throws {
        try makeSession(title: "产品评审", startedAt: Date())
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()

        XCTAssertEqual(workspace.access, .ok)
        XCTAssertTrue(workspace.hasScanned)
        XCTAssertEqual(workspace.meetings.map(\.title), ["产品评审"])
        XCTAssertNil(workspace.emptyStateMessage)
    }

    func testScanningFlagReturnsToFalseWhenDone() async {
        let workspace = MeetingWorkspace(root: root)
        XCTAssertFalse(workspace.isScanning)
        await workspace.refreshAsync()
        XCTAssertFalse(workspace.isScanning, "扫完必须归位，否则界面会一直转圈")
    }

    func testRescanPicksUpNewlyCreatedSession() async throws {
        // 「录完立刻刷新」走的就是这条路：先扫一次（空的），落了新会话再扫。
        // 如果扫描做了「进行中就直接返回」的早退，重试会被静默吞掉，新会议不出现。
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()
        XCTAssertTrue(workspace.meetings.isEmpty)

        try makeSession(title: "新录的", startedAt: Date())
        await workspace.refreshAsync()
        XCTAssertEqual(workspace.meetings.count, 1, "重扫必须看得到新出现的会议")
    }

    func testMissingRootIsMissingNotPermissionDenied() async {
        // 首次使用就是这样：目录还没建。这**不是**权限问题，
        // 界面不该引导用户去翻隐私设置。
        let workspace = MeetingWorkspace(root: root.appendingPathComponent("从未存在"))
        await workspace.refreshAsync()
        XCTAssertEqual(workspace.access, .missing)
        XCTAssertFalse(workspace.needsPermissionGuidance)
        XCTAssertEqual(workspace.emptyStateMessage,
                       "还没有会议记录。点「开始录制」录第一场。")
    }

    func testPermissionDeniedIsDistinguishedFromEmpty() async throws {
        // 这一条是「用空白界面骗用户说数据没了」的正面防线。
        // TCC 拒绝时 `fileExists` 会说目录不存在，必须靠 errno 才能分辨。
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: locked.path)
        }

        let workspace = MeetingWorkspace(root: locked)
        await workspace.refreshAsync()

        XCTAssertEqual(workspace.access, .permissionDenied,
                       "必须区分「没数据」和「没权限」")
        XCTAssertTrue(workspace.needsPermissionGuidance)
        XCTAssertEqual(workspace.emptyStateMessage,
                       "系统未授权访问「文稿」文件夹，因此看不到已有录音。")
    }

    func testBrokenSessionDoesNotHideHealthyOnes() async throws {
        try makeSession(title: "好的", startedAt: Date())
        let badDir = root.appendingPathComponent("2026-09-27-000000-坏的", isDirectory: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try "{ 这不是 JSON".write(to: badDir.appendingPathComponent("manifest.json"),
                                 atomically: true, encoding: .utf8)

        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()

        XCTAssertEqual(workspace.meetings.count, 2)
        XCTAssertNotNil(workspace.meetings.first { $0.loadError != nil })
        XCTAssertNotNil(workspace.meetings.first { $0.title == "好的" })
        XCTAssertNil(workspace.emptyStateMessage, "列表非空就不该显示空态")
    }

    // MARK: - 选中与详情

    func testRefreshAutoSelectsNewest() async throws {
        try makeSession(title: "旧", startedAt: Date().addingTimeInterval(-600))
        let newest = try makeSession(title: "新", startedAt: Date())

        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()
        XCTAssertEqual(workspace.selectedID, newest, "首次进入应自动选中最新一场")
        XCTAssertEqual(workspace.selectedMeeting?.title, "新")
    }

    /// 详情加载要把 manifest、转写稿、相位一次填齐。
    ///
    /// 相位断言读 `transcriptPhases[id]` 而不是 `workspace.transcriptPhase`：
    /// 后者是「当前选中那一场」的便捷视图，而这条用例**没有设 `selectedID`**
    /// （它直接调 `loadDetailAsync`），读便捷视图只会恒得 `.idle`——
    /// 那不是「实现对了」，是断言压根没碰到被测的东西。
    func testLoadDetailFillsManifestAndTranscriptPhase() async throws {
        let id = try makeSession(title: "有稿", startedAt: Date(), segments: 3)
        let workspace = MeetingWorkspace(root: root)

        let applied = await workspace.loadDetailAsync(id)
        XCTAssertTrue(applied)
        XCTAssertEqual(workspace.manifest?.sessionID, id)
        XCTAssertEqual(workspace.transcript?.segments.count, 3)
        XCTAssertEqual(workspace.transcriptPhases[id], .done(segmentCount: 3))
    }

    /// 没有转写稿时相位是 `.idle`。同上，按 ID 断言。
    func testDetailWithoutTranscriptIsIdlePhase() async throws {
        let id = try makeSession(title: "没稿", startedAt: Date())
        let workspace = MeetingWorkspace(root: root)
        _ = await workspace.loadDetailAsync(id)

        XCTAssertNil(workspace.transcript)
        XCTAssertEqual(workspace.transcriptPhases[id], .idle)
    }

    func testSelectingIDLoadsDetailAutomatically() async throws {
        // 详情加载挂在 `selectedID.didSet` 上，界面只负责设 ID。
        // 这样就不会出现「设了 ID 但忘了加载详情」的空壳。
        try makeSession(title: "甲", startedAt: Date().addingTimeInterval(-600))
        let second = try makeSession(title: "乙", startedAt: Date())

        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()
        workspace.selectedID = nil
        workspace.selectedID = second
        try await settle()

        XCTAssertEqual(workspace.manifest?.sessionID, second)
        XCTAssertEqual(workspace.selectedMeeting?.title, "乙")
    }

    func testSelectingNilClearsDetail() async throws {
        let id = try makeSession(title: "甲", startedAt: Date())
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()
        // 自动选中触发的那次详情读取是**另一个** Task，必须等它落地。
        // （这里不能靠 `await loadDetailAsync(id)`：它会和自己的并发调用撞代际号，
        //   被丢弃后立刻返回 false，manifest 这时还是 nil——那是在测时序，不是测行为。）
        try await settle()
        XCTAssertEqual(workspace.manifest?.sessionID, id, "自动选中之后详情应当已经加载")

        workspace.selectedID = nil
        XCTAssertNil(workspace.manifest, "清空选择必须同时清掉详情，不能留着上一场的")
        XCTAssertNil(workspace.transcript)
    }

    /// **回归测试**：迟到的详情结果不得覆盖当前选中项。
    ///
    /// 这一条对应的是最容易复发、也最难发现的一类 bug：读取是异步的，
    /// 用户切走之后旧请求才返回，详情区于是显示**上一场**的音轨和文稿，
    /// 而标题却是这一场的。比空白更难发现。
    func testStaleDetailResultIsDiscarded() async throws {
        let first = try makeSession(title: "甲", startedAt: Date().addingTimeInterval(-600))
        let second = try makeSession(title: "乙", startedAt: Date())

        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()

        // 连着切两次。甲的读取在飞，乙的读取紧接着发起。
        workspace.selectedID = first
        workspace.selectedID = second
        try await settle(0.6)

        XCTAssertEqual(workspace.selectedID, second)
        XCTAssertEqual(workspace.manifest?.sessionID, second,
                       "详情必须属于当前选中项，不能被被取代的那次迟到结果回填")
    }

    // MARK: - 搜索

    func testSearchMatchesTitle() async throws {
        try makeSession(title: "产品评审", startedAt: Date().addingTimeInterval(-600))
        try makeSession(title: "周会", startedAt: Date())

        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()
        XCTAssertEqual(workspace.visibleMeetings.count, 2)

        workspace.searchText = "产品"
        XCTAssertEqual(workspace.visibleMeetings.map(\.title), ["产品评审"])

        workspace.searchText = "   "
        XCTAssertEqual(workspace.visibleMeetings.count, 2, "纯空白不该被当成关键词")
    }

    func testSearchMatchesSessionID() async throws {
        let id = try makeSession(title: "周会", startedAt: Date())
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()

        workspace.searchText = id
        XCTAssertEqual(workspace.visibleMeetings.count, 1)
    }

    // MARK: - 修改操作

    func testRenameUpdatesTitleAndKeepsID() async throws {
        let id = try makeSession(title: "旧名字", startedAt: Date())
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()

        workspace.rename(sessionID: id, to: "新名字")
        try await settle()

        XCTAssertEqual(workspace.meetings.first?.title, "新名字")
        XCTAssertEqual(workspace.meetings.first?.id, id)
        XCTAssertNil(workspace.lastError)
    }

    func testRenameFailureLandsInLastError() async throws {
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()
        workspace.rename(sessionID: "根本不存在", to: "随便")
        try await settle()
        XCTAssertNotNil(workspace.lastError, "失败必须能被界面看到，不能静默")
    }

    func testDeleteRemovesSessionAndClearsSelection() async throws {
        let id = try makeSession(title: "要删的", startedAt: Date())
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()
        XCTAssertEqual(workspace.selectedID, id)

        workspace.delete(sessionID: id)
        try await settle()

        XCTAssertTrue(workspace.meetings.isEmpty)
        XCTAssertNil(workspace.selectedID, "删掉当前选中项后选择必须清空")
        XCTAssertNil(workspace.manifest)
    }

    // MARK: - 导出

    func testExportWritesMarkdown() async throws {
        let id = try makeSession(title: "有稿", startedAt: Date(), segments: 2)
        let workspace = MeetingWorkspace(root: root)
        _ = await workspace.loadDetailAsync(id)

        let destination = root.appendingPathComponent("导出.md")
        try workspace.exportTranscript(to: destination, format: .markdown)

        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(text.contains("有稿"))
        XCTAssertTrue(text.contains("第 0 句"))
    }

    func testExportWithoutTranscriptReportsErrorInsteadOfThrowing() async throws {
        let id = try makeSession(title: "没稿", startedAt: Date())
        let workspace = MeetingWorkspace(root: root)
        _ = await workspace.loadDetailAsync(id)

        // 界面用的是 Safe 版本：文件系统错误不该由视图层处理
        workspace.exportTranscriptSafe(
            to: root.appendingPathComponent("导出.md"), format: .plainText)
        XCTAssertNotNil(workspace.lastError)

        workspace.clearError()
        XCTAssertNil(workspace.lastError)
    }

    // MARK: - 偏好

    /// 「静默录制」的偏好域。**绝不用 `.standard`**——那是测试进程的偏好域，
    /// 写进去会跨用例、跨运行残留，于是「默认值是关」这种断言第二次跑就不成立，
    /// 而且失败与否取决于执行顺序。
    private func makePreferences() throws -> (prefs: RecorderPreferences, defaults: UserDefaults) {
        let name = "mr-ws-prefs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (RecorderPreferences(defaults: defaults), defaults)
    }

    /// 默认**关着**，也就是照旧看得见在录。
    ///
    /// 这个默认值本身是规格：开关的用途是「不想让别人看到」，不是「不让自己看到」。
    /// 一旦默认打开，受影响的是「忘记录着音」——一整场会议没录到，
    /// 而且过程中没有任何地方提示过，比被看见严重得多。
    func testHidesCountdownDefaultsOff() throws {
        let (prefs, _) = try makePreferences()
        let workspace = MeetingWorkspace(root: root, preferences: prefs)
        XCTAssertFalse(workspace.hidesStatusBarCountdown)
    }

    /// 打开之后写进偏好；换个工作区（= 下次启动应用）读得回来。
    ///
    /// 这里刻意查两件事：内存里的值变了，**而且**落盘的那个键也变了。
    /// 只查「换个实例读回来还是 true」，在一个只在内存里记着的实现上同样成立。
    func testHidesCountdownIsWrittenThroughAndReloaded() throws {
        let (prefs, defaults) = try makePreferences()
        let workspace = MeetingWorkspace(root: root, preferences: prefs)
        workspace.hidesStatusBarCountdown = true

        XCTAssertEqual(
            defaults.object(forKey: RecorderPreferences.hidesStatusBarCountdownKey) as? Bool,
            true, "工作区必须把开关写穿到偏好域")

        let reopened = MeetingWorkspace(root: root, preferences: prefs)
        XCTAssertTrue(reopened.hidesStatusBarCountdown, "换个工作区应当读回上次的设置")
    }

    /// 关得掉，而且反复设同一个值不会把偏好弄坏。
    func testHidesCountdownCanBeTurnedOffAgain() throws {
        let (prefs, defaults) = try makePreferences()
        let workspace = MeetingWorkspace(root: root, preferences: prefs)

        // 同一个值连设两次：`didSet` 里的相等判断应当把它当无事发生
        workspace.hidesStatusBarCountdown = true
        workspace.hidesStatusBarCountdown = true
        XCTAssertEqual(
            defaults.object(forKey: RecorderPreferences.hidesStatusBarCountdownKey) as? Bool, true)

        workspace.hidesStatusBarCountdown = false
        workspace.hidesStatusBarCountdown = false
        XCTAssertEqual(
            defaults.object(forKey: RecorderPreferences.hidesStatusBarCountdownKey) as? Bool, false)
    }

    // MARK: - 菜单栏图标显示开关

    /// 默认**显示**。方向与上面那个开关相反：关掉它菜单栏上就什么都不会剩，
    /// 「图标不见了」会是这个开关自己造出来的症状，所以默认必须是开的。
    func testShowsStatusBarIconDefaultsOn() throws {
        let (prefs, _) = try makePreferences()
        let workspace = MeetingWorkspace(root: root, preferences: prefs)
        XCTAssertTrue(workspace.showsStatusBarIcon)
    }

    /// 关掉之后写穿到偏好域；换个工作区（= 下次启动应用）读得回来。
    func testHidingTheIconIsWrittenThroughAndReloaded() throws {
        let (prefs, defaults) = try makePreferences()
        let workspace = MeetingWorkspace(root: root, preferences: prefs)
        workspace.showsStatusBarIcon = false

        XCTAssertEqual(
            defaults.object(forKey: RecorderPreferences.showsStatusBarIconKey) as? Bool,
            false, "工作区必须把图标开关写穿到偏好域")

        let reopened = MeetingWorkspace(root: root, preferences: prefs)
        XCTAssertFalse(reopened.showsStatusBarIcon, "换个工作区应当读回上次的设置")
    }

    /// 开得回来。这条挡的是「一旦关掉就再也回不来」——那种 bug 的表现是
    /// 用户照着设置窗口去恢复，图标却死活不出现，且没有任何报错。
    func testTheIconCanBeShownAgain() throws {
        let (prefs, _) = try makePreferences()
        let workspace = MeetingWorkspace(root: root, preferences: prefs)

        workspace.showsStatusBarIcon = false
        XCTAssertFalse(workspace.showsStatusBarIcon)

        workspace.showsStatusBarIcon = true
        XCTAssertTrue(workspace.showsStatusBarIcon)
        XCTAssertTrue(
            MeetingWorkspace(root: root, preferences: prefs).showsStatusBarIcon,
            "重新打开之后，下次启动必须是显示的")
    }

    // MARK: - 转写引擎偏好（全局配置项）

    /// 默认必须是苹果原生。这条默认值本身是规格：换引擎（尤其换成要下载模型的 SV）
    /// 必须由用户显式点头，不能在界面里悄悄变成别的。
    func testTranscriptionEngineDefaultsToApple() throws {
        let (prefs, _) = try makePreferences()
        let workspace = MeetingWorkspace(root: root, preferences: prefs)
        XCTAssertEqual(workspace.transcriptionEngine, .apple)
    }

    /// 界面里改引擎要写穿到偏好域，且换工作区读得回来（= 下次启动仍是这个引擎）。
    func testTranscriptionEngineIsWrittenThroughAndReloaded() throws {
        let (prefs, defaults) = try makePreferences()
        let workspace = MeetingWorkspace(root: root, preferences: prefs)
        workspace.transcriptionEngine = .senseVoice

        XCTAssertEqual(
            defaults.string(forKey: RecorderPreferences.transcriptionEngineKey),
            TranscriptionEngine.senseVoice.rawValue,
            "工作区必须把引擎写穿到偏好域")

        let reopened = MeetingWorkspace(root: root, preferences: prefs)
        XCTAssertEqual(reopened.transcriptionEngine, .senseVoice, "换个工作区应当读回上次的引擎")
    }

    /// **这一组里最关键的一条**：改引擎必须真的进到转写编排器的配置里。
    ///
    /// 「偏好存下来了」与「转写真的用它」是两件独立的事——若只在 `init` 里按当时的
    /// 引擎造一个 `SessionTranscriber` 存起来，上面那条「写穿偏好域」照样全绿，
    /// 但用户在界面里换了引擎，下一场转写还是走老引擎。所以这里直接查
    /// `transcriber.configuration.engine`。
    func testChangingEngineFlowsIntoTheTranscriber() throws {
        let (prefs, _) = try makePreferences()
        let workspace = MeetingWorkspace(root: root, preferences: prefs)
        XCTAssertEqual(workspace.transcriber.configuration.engine, .apple, "默认编排器用苹果原生")

        workspace.transcriptionEngine = .senseVoice
        XCTAssertEqual(
            workspace.transcriber.configuration.engine, .senseVoice,
            "工作区选了新引擎后，转写编排器必须用它——否则这个配置项形同虚设")
    }

    // MARK: - 录音格式偏好（16 位）

    /// 默认不是 16 位。理由见 `RecorderPreferencesTests.testSixteenBitDefaultsOff`——
    /// 打开这个开关会降低录音精度，默认值必须是「什么都不改」。
    func testSixteenBitDefaultsOff() throws {
        let (prefs, _) = try makePreferences()
        let workspace = MeetingWorkspace(root: root, preferences: prefs)
        XCTAssertFalse(workspace.pcm16Recording)
    }

    /// 打开之后写穿到偏好域；换个工作区（= 下次启动应用）读得回来。
    func testSixteenBitIsWrittenThroughAndReloaded() throws {
        let (prefs, defaults) = try makePreferences()
        let workspace = MeetingWorkspace(root: root, preferences: prefs)
        workspace.pcm16Recording = true

        XCTAssertEqual(
            defaults.object(forKey: RecorderPreferences.pcm16RecordingKey) as? Bool,
            true, "工作区必须把开关写穿到偏好域")

        let reopened = MeetingWorkspace(root: root, preferences: prefs)
        XCTAssertTrue(reopened.pcm16Recording, "换个工作区应当读回上次的设置")
    }

    /// **这一组里最关键的一条**：开关的值必须真的进到录制配置里。
    ///
    /// 「偏好存下来了」与「录制真的用了它」是两件独立的事。只测前者的实现
    /// 会把偏好读进属性、然后忘了拼进 `Configuration` —— 照样全绿。
    /// 而用户看到的是：开关打了勾，磁盘占用一个字节都没少，且界面上没有任何异常。
    func testSixteenBitPreferenceReachesTheRecorderConfiguration() async throws {
        let (prefs, _) = try makePreferences()
        let log = ConfigurationLog()
        let libraryRoot = try XCTUnwrap(root)
        let workspace = MeetingWorkspace(root: libraryRoot, preferences: prefs) { _, config in
            log.record(config)
            return FormatSpyEngine(root: libraryRoot)
        }

        workspace.pcm16Recording = true
        workspace.startRecording()
        try await waitUntil("配置被交给引擎一次") { log.count == 1 }

        XCTAssertEqual(log.count, 1, "开始录制应当恰好把配置交给引擎一次")
        let recorded = try XCTUnwrap(log.last)
        XCTAssertEqual(recorded.sampleFormat, .pcm16, "勾了 16 位就必须以 16 位开录")
    }

    /// 反面：没勾的时候不能顺手也降成 16 位。
    ///
    /// 上一条是「勾了要生效」，这一条是「没勾不能生效」。少了它，一个把
    /// `sampleFormat` 写死成 `.pcm16` 的实现能过上面那条测试，
    /// 代价是**所有**用户默认录音精度减半。
    func testUncheckedPreferenceAsksForLosslessRecording() async throws {
        let (prefs, _) = try makePreferences()
        let log = ConfigurationLog()
        let libraryRoot = try XCTUnwrap(root)
        let workspace = MeetingWorkspace(root: libraryRoot, preferences: prefs) { _, config in
            log.record(config)
            return FormatSpyEngine(root: libraryRoot)
        }

        workspace.startRecording()
        try await waitUntil("配置被交给引擎一次") { log.count == 1 }

        let recorded = try XCTUnwrap(log.last)
        XCTAssertEqual(recorded.sampleFormat, .float32,
                       "没勾 16 位时必须照旧 32 位浮点")
    }

    /// 每开录一场都重新读一次偏好，用的不是「工作区初始化时的快照」。
    ///
    /// 用户的真实顺序是「先勾开关、再点开始录制」，中间不会重建工作区；
    /// 而中途改设置再录第二场，也必须按新的来。这两件事都由同一条实现保证，
    /// 但它错起来是隐形的：只在 init 时读一次，用户第一次勾选就无效，
    /// 要重启应用才生效——典型的「第一次不管用」。
    func testEachRecordingPicksUpTheCurrentPreference() async throws {
        let (prefs, _) = try makePreferences()
        let log = ConfigurationLog()
        let libraryRoot = try XCTUnwrap(root)
        let workspace = MeetingWorkspace(root: libraryRoot, preferences: prefs) { _, config in
            log.record(config)
            return FormatSpyEngine(root: libraryRoot)
        }

        // 第一场：没勾
        workspace.startRecording()
        try await waitUntil("第一场配置已记录") { log.count == 1 }
        try await waitUntil("第一场已进入录制态") { workspace.recorder.phase == .recording }
        workspace.recorder.stop()
        try await waitUntil("第一场已收尾") {
            if case .finished = workspace.recorder.phase { return true }
            return false
        }
        workspace.recorder.acknowledge()

        // 中途改设置
        workspace.pcm16Recording = true

        // 第二场：勾了
        workspace.startRecording()
        try await waitUntil("第二场配置已记录") { log.count == 2 }

        XCTAssertEqual(log.count, 2, "两场录制应当各自交一次配置")
        XCTAssertEqual(log.all.compactMap(\.sampleFormat), [.float32, .pcm16],
                       "两场应当各按当时的偏好，而不是同一个快照用到底")
    }

    // MARK: - 显式传入的格式（偏好只在「没表态」时兜底）

    /// 调用方**显式**要 16 位时，偏好是关的也必须尊重它。
    ///
    /// 原先 `startRecording` 是无条件用偏好覆盖：调用方显式要 `.pcm16` 会被静默改回
    /// float32，没有任何日志或返回值能让人发现。同一个仓库里 `RecordingController.start`
    /// 与 CLI 都尊重调用方——只有这一层把意图吞掉，语义是反的。
    ///
    /// 退化示例：把 `startRecording` 改回
    /// `config.sampleFormat = preferences.sampleFormat` 的无条件覆盖，本用例变红。
    func testExplicitFormatSurvivesWhenPreferenceIsOff() async throws {
        let (prefs, _) = try makePreferences()
        let log = ConfigurationLog()
        let libraryRoot = try XCTUnwrap(root)
        let workspace = MeetingWorkspace(root: libraryRoot, preferences: prefs) { _, config in
            log.record(config)
            return FormatSpyEngine(root: libraryRoot)
        }

        XCTAssertFalse(workspace.pcm16Recording, "前提：偏好必须是关的")
        var config = DualTrackRecorder.Configuration()
        config.sampleFormat = .pcm16
        workspace.startRecording(configuration: config)
        try await waitUntil("配置被交给引擎一次") { log.count == 1 }

        XCTAssertEqual(try XCTUnwrap(log.last).sampleFormat, .pcm16,
                       "调用方显式指定的格式不能被偏好静默吞掉")
    }

    /// 反面：偏好是开的，调用方显式要 float32 时也必须尊重调用方。
    ///
    /// 与上一条成对，挡住「只要偏好开着就一律用偏好」这种假修——
    /// 那只是把覆盖的方向换了一边，并没有做到「尊重调用方」。
    ///
    /// 退化示例：把 `startRecording` 改成
    /// `if config.sampleFormat == nil || preferences.pcm16Recording { … }`，
    /// 本用例变红（会拿到 .pcm16）。
    func testExplicitLosslessFormatSurvivesWhenPreferenceIsOn() async throws {
        let (prefs, _) = try makePreferences()
        let log = ConfigurationLog()
        let libraryRoot = try XCTUnwrap(root)
        let workspace = MeetingWorkspace(root: libraryRoot, preferences: prefs) { _, config in
            log.record(config)
            return FormatSpyEngine(root: libraryRoot)
        }

        workspace.pcm16Recording = true
        var config = DualTrackRecorder.Configuration()
        config.sampleFormat = .float32
        workspace.startRecording(configuration: config)
        try await waitUntil("配置被交给引擎一次") { log.count == 1 }

        XCTAssertEqual(try XCTUnwrap(log.last).sampleFormat, .float32,
                       "显式要无损时，偏好为开也不能改掉它")
    }

    /// 调用方**没表态**（`sampleFormat == nil`）时，偏好仍然是缺省来源；
    /// 而且调用方设的其它字段（这里用 `maxDuration`）不能被顺手丢掉。
    ///
    /// 这一条钉住三件事：偏好仍是「缺省值」而非被彻底弃用；`nil` 与
    /// 「显式 float32」在语义上确实不同；拼配置时不能只填格式、把别的字段丢了。
    ///
    /// 退化示例：把兜底条件写成 `if config.sampleFormat == .float32`，
    /// 本用例会拿到 nil 而不是 .pcm16 而变红。
    func testUnspecifiedFormatFallsBackToPreferenceAndKeepsOtherFields() async throws {
        let (prefs, _) = try makePreferences()
        let log = ConfigurationLog()
        let libraryRoot = try XCTUnwrap(root)
        let workspace = MeetingWorkspace(root: libraryRoot, preferences: prefs) { _, config in
            log.record(config)
            return FormatSpyEngine(root: libraryRoot)
        }

        workspace.pcm16Recording = true
        // sampleFormat 留在 nil（= 我没表态），只改别的字段
        let config = DualTrackRecorder.Configuration(maxDuration: 42)
        XCTAssertNil(config.sampleFormat, "前提：这个配置没有表态格式")
        workspace.startRecording(configuration: config)
        try await waitUntil("配置被交给引擎一次") { log.count == 1 }

        let recorded = try XCTUnwrap(log.last)
        XCTAssertEqual(recorded.sampleFormat, .pcm16, "没表态时应当按偏好填")
        XCTAssertEqual(recorded.maxDuration, 42, "调用方设的其它字段不能被丢掉")
    }

    // MARK: - 录音带宽偏好（单声道 + 24 kHz）

    /// 默认关闭。理由比位深更硬：这一项同时改掉采样率与声道数，
    /// 录完的东西形态就定了，回头补不回来。
    func testMono24kDefaultsOff() throws {
        let (prefs, _) = try makePreferences()
        let workspace = MeetingWorkspace(root: root, preferences: prefs)
        XCTAssertFalse(workspace.mono24kRecording)
    }

    /// 打开之后写穿到偏好域；换个工作区（= 下次启动应用）读得回来。
    func testMono24kIsWrittenThroughAndReloaded() throws {
        let (prefs, defaults) = try makePreferences()
        let workspace = MeetingWorkspace(root: root, preferences: prefs)
        workspace.mono24kRecording = true

        XCTAssertEqual(
            defaults.object(forKey: RecorderPreferences.mono24kRecordingKey) as? Bool,
            true, "工作区必须把开关写穿到偏好域")

        let reopened = MeetingWorkspace(root: root, preferences: prefs)
        XCTAssertTrue(reopened.mono24kRecording, "换个工作区应当读回上次的设置")
    }

    /// **这一组里最关键的一条**：开关的值必须真的进到录制配置里。
    ///
    /// 「偏好存下来了」与「录制真的用了它」是两件独立的事。只测前者的实现
    /// 会把偏好读进属性、然后忘了拼进 `Configuration`——照样全绿。
    /// 而用户看到的是：开关打了勾，磁盘占用一个字节都没少，界面上没有任何异常。
    func testMono24kPreferenceReachesTheRecorderConfiguration() async throws {
        let (prefs, _) = try makePreferences()
        let log = ConfigurationLog()
        let libraryRoot = try XCTUnwrap(root)
        let workspace = MeetingWorkspace(root: libraryRoot, preferences: prefs) { _, config in
            log.record(config)
            return FormatSpyEngine(root: libraryRoot)
        }

        workspace.mono24kRecording = true
        workspace.startRecording()
        try await waitUntil("配置被交给引擎一次") { log.count == 1 }

        XCTAssertEqual(try XCTUnwrap(log.last).mono24k, true,
                       "勾了单声道 24 kHz 就必须带着这个开关开录")
    }

    /// 反面：没勾的时候不能顺手也降带宽。
    ///
    /// 少了这条，一个把 `mono24k` 写死成 `true` 的实现能过上面那条测试，
    /// 代价是**所有**用户默认拿到降采样录音——而这正是「默认不能悄悄降质量」要挡的事。
    func testUncheckedMono24kAsksForFullBandwidth() async throws {
        let (prefs, _) = try makePreferences()
        let log = ConfigurationLog()
        let libraryRoot = try XCTUnwrap(root)
        let workspace = MeetingWorkspace(root: libraryRoot, preferences: prefs) { _, config in
            log.record(config)
            return FormatSpyEngine(root: libraryRoot)
        }

        workspace.startRecording()
        try await waitUntil("配置被交给引擎一次") { log.count == 1 }

        // 判据落在「解析后的值」上：`nil` 与 `false` 都要落到「不动格式」，
        // 而写死 true 的实现会在这里给出 true。
        XCTAssertEqual(try XCTUnwrap(log.last).resolvedMono24k, false,
                       "没勾时必须保留源的采样率与声道数")
    }

    /// 调用方**显式**要降带宽时，偏好是关的也必须尊重它。
    func testExplicitMono24kSurvivesWhenPreferenceIsOff() async throws {
        let (prefs, _) = try makePreferences()
        let log = ConfigurationLog()
        let libraryRoot = try XCTUnwrap(root)
        let workspace = MeetingWorkspace(root: libraryRoot, preferences: prefs) { _, config in
            log.record(config)
            return FormatSpyEngine(root: libraryRoot)
        }

        XCTAssertFalse(workspace.mono24kRecording, "前提：偏好必须是关的")
        var config = DualTrackRecorder.Configuration()
        config.mono24k = true
        workspace.startRecording(configuration: config)
        try await waitUntil("配置被交给引擎一次") { log.count == 1 }

        XCTAssertEqual(try XCTUnwrap(log.last).resolvedMono24k, true,
                       "调用方显式指定的带宽不能被偏好静默吞掉")
    }

    /// 反面：偏好是开的，调用方显式要全带宽时也必须尊重调用方。
    ///
    /// 与上一条成对，挡住「只要偏好开着就一律用偏好」这种假修。
    func testExplicitFullbandSurvivesWhenPreferenceIsOn() async throws {
        let (prefs, _) = try makePreferences()
        let log = ConfigurationLog()
        let libraryRoot = try XCTUnwrap(root)
        let workspace = MeetingWorkspace(root: libraryRoot, preferences: prefs) { _, config in
            log.record(config)
            return FormatSpyEngine(root: libraryRoot)
        }

        workspace.mono24kRecording = true
        var config = DualTrackRecorder.Configuration()
        config.mono24k = false
        workspace.startRecording(configuration: config)
        try await waitUntil("配置被交给引擎一次") { log.count == 1 }

        XCTAssertEqual(try XCTUnwrap(log.last).resolvedMono24k, false,
                       "显式要全带宽时，偏好为开也不能改掉它")
    }

    /// 两个格式开关**互不干扰**：各开各的，四个组合都能表达。
    ///
    /// 两个偏好共用一个 `UserDefaults`，键名写错一个字母就会互相覆盖，
    /// 症状是「勾了单声道 24 kHz，位深也跟着变了」——没人会往这边想。
    func testTheTwoFormatSwitchesDoNotInterfere() throws {
        let (prefs, defaults) = try makePreferences()
        let workspace = MeetingWorkspace(root: root, preferences: prefs)

        XCTAssertNotEqual(RecorderPreferences.pcm16RecordingKey,
                          RecorderPreferences.mono24kRecordingKey,
                          "两个开关的键名必须不同")

        workspace.pcm16Recording = true
        XCTAssertTrue(workspace.pcm16Recording)
        XCTAssertFalse(workspace.mono24kRecording, "开 16 位不该顺手把带宽也降了")

        workspace.mono24kRecording = true
        XCTAssertTrue(workspace.pcm16Recording, "开带宽开关不该把位深挤掉")
        XCTAssertTrue(workspace.mono24kRecording)
        XCTAssertEqual(
            defaults.object(forKey: RecorderPreferences.mono24kRecordingKey) as? Bool, true)

        // 重新读一遍偏好，两个值都要还在
        let reopened = MeetingWorkspace(root: root, preferences: prefs)
        XCTAssertTrue(reopened.pcm16Recording)
        XCTAssertTrue(reopened.mono24kRecording)
    }

    // MARK: - 切换会议时转写相位必须跟着换

    /// **切到另一场时，看到的必须是那一场自己的相位。**
    ///
    /// 这条用例的**意图**从 2026-10-16 起没变过：A 在转写，切到 B，
    /// B 不能显示「正在转写…」——它一个字都没在转。
    ///
    /// 但实现换过一次根子，值得记一笔，因为两次都是同一个领域翻车：
    ///
    /// - **第一版（不清）**：`transcriptPhase` 是「当前选中这场」的标量，
    ///   切走时没清，于是 B 继承了 A 的 `.running`。修法是切走就清。
    /// - **第二版（清）**：清了之后 B 是对的，但**切回 A 时 A 的状态也没了**——
    ///   界面显示「开始转写」，而它其实还在后台跑；`runTranscription` 的
    ///   `guard !isRunning` 又挡不住，用户再点一次就是同一场并发两次转写。
    ///   （2026-10-16 报的正是这个。）
    ///
    /// 现在相位按 sessionID 存（`transcriptPhases`），「跟着换」不再是
    /// 「清干净」，而是**换到那一份**：B 读 B 的（没在转）、A 读 A 的（还在转）。
    func testSwitchingAwayShowsTheOtherSessionsOwnPhase() async throws {
        let first = try makeSession(title: "第一场", startedAt: Date(), segments: 2)
        let second = try makeSession(title: "第二场", startedAt: Date(), segments: 3)
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()

        workspace.selectedID = first
        try await waitUntil("第一场详情就绪") { workspace.manifest != nil }

        // 假装第一场正在转写
        workspace.setTranscriptPhaseForTesting(.running(summary: "正在转写第 1 段…"), for: first)
        XCTAssertTrue(workspace.transcriptPhase.isRunning)

        // 切到第二场：看到的必须是第二场自己的相位（它没在转）
        workspace.selectedID = second
        XCTAssertFalse(workspace.transcriptPhase.isRunning, """
            切走之后仍显示「正在转写」——界面会把第一场的状态安在第二场上。
            """)

        // 而第一场的状态**必须还在**：它真的还在后台转。
        // 这条是第二版翻车的直接回归——清相位的那一版会把它擦掉。
        XCTAssertEqual(workspace.transcriptPhases[first]?.isRunning, true, """
            第一场还在转写，它的相位却被擦掉了。
            后果不只是界面显示错：`runTranscription` 的 `guard !isRunning`
            读的是这个值，被擦掉之后用户再点一次「开始转写」，
            会对同一场**并发发起第二次转写**。
            """)
    }

    /// 取消选中（回到空态）时看不到任何一场的相位。
    ///
    /// 漏这条的症状更怪：详情区已经没有内容了，转写进度条却还在转。
    func testDeselectingShowsNoPhase() async throws {
        let first = try makeSession(title: "第一场", startedAt: Date(), segments: 2)
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()

        workspace.selectedID = first
        try await waitUntil("详情就绪") { workspace.manifest != nil }
        workspace.setTranscriptPhaseForTesting(.running(summary: "正在转写…"), for: first)

        workspace.selectedID = nil
        XCTAssertFalse(workspace.transcriptPhase.isRunning,
                       "取消选中之后不该还显示「正在转写」")
        // 但数据仍在——选中回来就恢复了，这正是按 ID 存的意义。
        XCTAssertEqual(workspace.transcriptPhases[first]?.isRunning, true)
    }

    /// 切到**已有转写稿**的会议，看到的必须是 `.done` 而不是别场的 running。
    ///
    /// 这条比上面两条更能暴露问题：`loadDetailAsync` 确实会按盘上有没有稿
    /// 重算相位，但那是**异步**的。切换瞬间（await 之前）界面上挂的仍是旧值，
    /// 于是用户会看到「已转写 3 句」闪一下变成「正在转写…」。
    func testSwitchingToASessionWithTranscriptMustNotFlashRunning() async throws {
        let withTranscript = try makeSession(title: "有稿", startedAt: Date(), segments: 4)
        let withoutTranscript = try makeSession(title: "没稿", startedAt: Date(), segments: nil)
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()

        // 先让「没稿」那场假装在转写——上一场的 running 不能闪到这一场来
        workspace.selectedID = withoutTranscript
        try await waitUntil("没稿的详情就绪") { workspace.manifest != nil }
        workspace.setTranscriptPhaseForTesting(.running(summary: "正在转写…"),
                                               for: withoutTranscript)

        // 切到有稿的那场，**切换瞬间**就不能还挂着上一场的 running
        workspace.selectedID = withTranscript
        XCTAssertFalse(workspace.transcriptPhase.isRunning, """
            切换瞬间仍显示上一场的「正在转写」——
            标题已经是新会议，转写状态却属于上一场。
            """)
        try await waitUntil("有稿的相位为 done") {
            if case .done = workspace.transcriptPhase { return true }
            return false
        }
    }

    // MARK: - 转写中切走再切回（2026-10-16 报：「状态不对」）

    /// **切回一场正在转写的会议，必须还是「转写中」。**
    ///
    /// 这是用户报障的直接回归：A 点开始转写 → 显示「转写中」→
    /// 切到 B → 切回 A → 又显示「开始转写」按钮。
    ///
    /// 报障时的实现是「切走就清相位」，所以 A 的 `.running` 在切走那一刻
    /// 就被擦了；`loadDetailAsync` 随后又按「盘上还没稿」把它设成 `.idle`。
    /// 两个动作叠加，用户切回来看到的是一个从没点过转写的界面。
    func testSwitchingBackToATranscribingSessionKeepsRunning() async throws {
        let first = try makeSession(title: "第一场", startedAt: Date(), segments: nil)
        let second = try makeSession(title: "第二场", startedAt: Date(), segments: nil)
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()

        // A 开始转写（用测试注入代替真的跑推理——要验的是状态机，不是引擎）
        workspace.selectedID = first
        try await waitUntil("第一场详情就绪") { workspace.manifest != nil }
        workspace.setTranscriptPhaseForTesting(.running(summary: "正在转写第 2 段…"), for: first)
        XCTAssertTrue(workspace.transcriptPhase.isRunning, "前置条件：A 正在转写")

        // 切到 B，再切回 A
        workspace.selectedID = second
        try await waitUntil("第二场详情就绪") { workspace.manifest != nil }
        workspace.selectedID = first

        // **切换瞬间**就必须是 running——不能等详情加载完才补，
        // 那一瞬间用户看到的就是最终结论。
        XCTAssertTrue(workspace.transcriptPhase.isRunning, """
            切回正在转写的会议，界面却显示「开始转写」——
            它其实还在后台跑，而用户会以为从没点过。
            """)

        // 详情加载完之后**仍然**是 running：那一次按磁盘重算不许覆盖它。
        try await waitUntil("第一场详情再次就绪") { workspace.manifest != nil }
        XCTAssertTrue(workspace.transcriptPhase.isRunning, """
            详情加载把 `.running` 擦成了磁盘推导值。
            这正是报障链路的后半段：相位先被切走清掉，再被详情加载按
            「盘上还没稿」设成 `.idle`。
            """)
        XCTAssertEqual(workspace.transcriptPhase.summaryIfRunning, "正在转写第 2 段…",
                       "进度文字也不能丢——用户靠它知道转到第几段了")
    }

    /// 转写完成后再切走切回，必须是 `.done` 而不是 `.idle`。
    ///
    /// 这是上一条的收尾：相位按 ID 存，所以 A 转完时哪怕用户已经切到 B，
    /// 那个 `.done` 也不会丢。旧实现在转写回调里有一道
    /// `guard self.selectedID == id`，切走了就**整个丢弃**完成事件——
    /// 用户切回来看到「开始转写」，而稿子其实已经写盘了。
    func testSwitchingBackAfterCompletionShowsDone() async throws {
        let first = try makeSession(title: "第一场", startedAt: Date(), segments: nil)
        let second = try makeSession(title: "第二场", startedAt: Date(), segments: nil)
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()

        workspace.selectedID = first
        try await waitUntil("第一场详情就绪") { workspace.manifest != nil }
        workspace.setTranscriptPhaseForTesting(.running(summary: "正在收尾…"), for: first)

        // 切走，然后在后台完成
        workspace.selectedID = second
        try await waitUntil("第二场详情就绪") { workspace.manifest != nil }
        workspace.setTranscriptPhaseForTesting(.done(segmentCount: 5), for: first)

        // 切回 A：必须看到完成态
        workspace.selectedID = first
        try await waitUntil("第一场详情再次就绪") { workspace.manifest != nil }
        if case .done = workspace.transcriptPhase {
            // 对
        } else {
            XCTFail("转写已完成，切回来却显示 \(workspace.transcriptPhase)")
        }
    }

    // MARK: - 列表要能看出「哪一场在转写」

    /// **`isTranscribing(sessionID:)` 不依赖当前选中谁。**
    ///
    /// 列表里每一行都要靠它标一个转圈图标。若它读的是「当前选中这场」，
    /// 那么 A 在转写、用户切到 B 时，列表里 A 那一行会是静止的——
    /// 切走的那一场就**彻底不可见**了：用户只记得点了转写，
    /// 却没有任何地方告诉他那件事还在跑。
    func testIsTranscribingWorksForAnySessionNotJustTheSelectedOne() async throws {
        let first = try makeSession(title: "第一场", startedAt: Date(), segments: nil)
        let second = try makeSession(title: "第二场", startedAt: Date(), segments: nil)
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()

        // A 在转写，然后切到 B
        workspace.selectedID = first
        try await waitUntil("第一场详情就绪") { workspace.manifest != nil }
        workspace.setTranscriptPhaseForTesting(.running(summary: "正在转写…"), for: first)
        workspace.selectedID = second
        try await waitUntil("第二场详情就绪") { workspace.manifest != nil }

        XCTAssertFalse(workspace.isTranscribing(sessionID: second),
                       "B 没在转写")
        XCTAssertTrue(workspace.isTranscribing(sessionID: first), """
            A 还在转写，但 `isTranscribing` 说没有——列表里那一行会是静止的，
            用户切到 B 之后就再也看不出 A 还在跑。
            """)
        XCTAssertEqual(workspace.transcribingSessionIDs(), [first],
                       "汇总也要认得出正在转写的是哪一场")
    }

    /// 两场可以**同时**转写，各自状态独立。
    ///
    /// 这是按 ID 索引相对标量模型的额外收益：标量模型下「同时在转两场」
    /// 根本无法表达（只有一个相位可写）。这里顺带钉住它别退回去。
    func testTwoSessionsCanTranscribeAtTheSameTime() async throws {
        let first = try makeSession(title: "第一场", startedAt: Date(), segments: nil)
        let second = try makeSession(title: "第二场", startedAt: Date(), segments: nil)
        let workspace = MeetingWorkspace(root: root)
        await workspace.refreshAsync()

        workspace.setTranscriptPhaseForTesting(.running(summary: "A 在转"), for: first)
        workspace.setTranscriptPhaseForTesting(.running(summary: "B 在转"), for: second)

        XCTAssertEqual(workspace.transcribingSessionIDs().count, 2,
                       "两场同时在转，汇总应该是两条")
        XCTAssertEqual(workspace.transcriptPhases[first]?.summaryIfRunning, "A 在转")
        XCTAssertEqual(workspace.transcriptPhases[second]?.summaryIfRunning, "B 在转",
                       "两场的进度文字不能互相覆盖")
    }
}

/// 只服务于「格式偏好有没有真的传到录制配置」这一组用例的最小引擎。
///
/// 刻意做得比 `RecordingControllerTests` 里那个更薄：这里要验的不是状态机，
/// 而是**配置对象的传递**。它多做的每一件事都可能掩盖「参数根本没传过来」，
/// 而把一个假引擎做得足够复杂、以致于它自己出问题，是这类测试最常见的翻车方式。
private final class FormatSpyEngine: RecordingEngine, @unchecked Sendable {

    private let root: URL
    let sessionID = "2026-09-27-120000-格式探针"

    init(root: URL) { self.root = root }

    @discardableResult
    func start(title: String) throws -> String {
        // 真实现会在这一步建目录并落下初始 manifest，这里照做，
        // 免得测试在一个「状态机成功、磁盘上什么都没有」的假场景上取证。
        let dir = root.appendingPathComponent(sessionID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? RecordingManifest(sessionID: sessionID, title: title, state: .recording)
            .write(to: dir.appendingPathComponent(SessionStore.manifestFileName))
        return sessionID
    }

    func stop() throws -> DualTrackRecorder.Result {
        DualTrackRecorder.Result(
            sessionID: sessionID,
            directory: root.appendingPathComponent(sessionID, isDirectory: true),
            manifest: RecordingManifest(sessionID: sessionID, title: "格式探针", state: .finalized),
            drift: DriftReport(tracks: []))
    }

    func abort() {}

    var elapsed: Double { 0 }
}

/// 引擎工厂拿到的配置，按次留档。
///
/// 工厂是在 `Task.detached` 里被调用的，所以这里必须自己加锁——
/// 与「测试里不会真有并发」这种侥幸无关：`Task.detached` 本来就跑在别的线程上。
private final class ConfigurationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [DualTrackRecorder.Configuration] = []

    func record(_ configuration: DualTrackRecorder.Configuration) {
        lock.lock(); defer { lock.unlock() }
        entries.append(configuration)
    }

    var all: [DualTrackRecorder.Configuration] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    var last: DualTrackRecorder.Configuration? { all.last }

    var count: Int { all.count }
}
