import XCTest
@testable import MRSession
import MRCore

/// 按单轨转录（`SessionTranscriber` 的 `trackFilter`）。
///
/// ## 为什么要有这个功能
///
/// 真实会议库里**有相当比例的场次只有一条轨是有效的**——本机 4 条真实录音里
/// 就有 3 场的 system 轨是 100% 静音（当时系统音频采集没起来）。
/// 这类场次做整场双轨转录有两处浪费：
///
/// 1. **时间浪费一倍**：一条轨是空的，引擎照样对它跑一遍完整推理。
/// 2. **更隐蔽的害处**：空轨也会被写成稿子，与真轨归并后时间轴上多出一堆
///    无内容段落。用户读到的是一份掺了「对方」标签的稿子，
///    而他根本不知道那一路本来就没录到。
///
/// ## 这一组要钉住的三件事
///
/// 1. **绝不覆盖整场稿。** 写 `transcript.md` 会把另一条轨的内容永久抹掉，
///    而界面上「已转写」的标记还亮着。这是本功能最坏的一种失败。
/// 2. **不改 `manifest.state`。** 只转了一半却标成 `.transcribed`，
///    界面上就显示成「已转写」，而对方那一轨根本没转。
/// 3. **单轨不做跨轨的事。** 回声去重要两条轨才判得出来，⚡ 抢话标记同理。
///    留着这两步在单轨上跑不会出错（判据自然不成立），但**必须显式说明**，
///    否则用户会以为这份稿子已经去过重了。
final class SessionTranscriberSingleTrackTests: XCTestCase {

    private var root: URL!
    private let sessionID = "2026-10-09-single-track"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-single-track-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    // MARK: - 夹具

    /// 造一场双轨会议，各写 1 秒真实音频。
    ///
    /// 两条轨都必须是**结构合法的真 WAV**：转写链路会先
    /// `AudioSlicer.inspect` 读时长，文件不存在或头损坏时会在那里就断掉，
    /// 那测到的是「音频读不了」，不是本组要测的行为。
    private func makeSession(trackIDs: [String] = ["mic", "system"],
                             startSkewSeconds: Double = 0.4) throws
        -> (store: SessionStore, dir: URL) {
        let store = SessionStore(root: root)
        let dir = store.directory(forSessionID: sessionID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 偏移要**反算成 tick**。写死一个整数（早先写的是 40_000_000）等于
        // 假设「1 tick = 1 纳秒」——那在 Apple Silicon 上不成立（本机是 125/3），
        // 于是断言里的 0.4 秒与夹具实际造出的偏移对不上。
        let skewTicks = UInt64(startSkewSeconds * 1_000_000_000
                               / HostClock.nanosecondsPerTick)

        // 基准起点**不能是 0**。`TrackAlignment.sessionBase` 把 `0` 当成
        // 「这条轨没有有效的 hostTime」而剔除（真实的旧 manifest 就是这样），
        // 于是基准会变成第二轨自己、偏移算成 0——夹具造出了偏移为 0 的假象，
        // 而断言 0.4 与它对不上，看起来像实现坏了。
        // 真实的绝对值无所谓，只有**两条轨之间的差值**有意义。
        let baseTicks = HostClock.now()

        var tracks: [TrackManifest] = []
        for (index, id) in trackIDs.enumerated() {
            let role: TrackRole = id == "mic" ? .microphone : .systemAudio
            tracks.append(TrackManifest(
                id: id, role: role, fileName: "\(id).wav",
                sampleRate: 48000, channels: 1,
                // 让第二轨比第一轨晚 startSkewSeconds 启动，
                // 好验证时间轴平移在单轨下仍然生效。
                firstHostTime: baseTicks + UInt64(index) * skewTicks))
            let writer = try WAVWriter(url: dir.appendingPathComponent("\(id).wav"),
                                       sampleRate: 48000, channels: 1)
            try writer.append([Float](repeating: 0, count: 48000))
            try writer.finalize()
            writer.close()
        }
        let manifest = RecordingManifest(
            sessionID: sessionID, title: "单轨测试", state: .finalized, tracks: tracks)
        try store.save(manifest, sessionDirectory: dir)
        return (store, dir)
    }

    /// 一个只按调用方要求产出内容的假驱动器。
    ///
    /// 注入假驱动器而不是真引擎：真引擎的产出随模型版本与机器环境变化，
    /// 那种用例的结果不可复现。这里要验的是**编排层怎么处理单轨**，
    /// 与「引擎转出了什么」无关。
    private final class ScriptedDriver: TranscriptionEngineDriver {
        let engineID = TranscriptionEngine.apple.driverEngineID
        private(set) var transcribedTrackIDs: [String] = []

        func isLanguageSupported(_ language: String) async -> Bool { true }
        func supportedLanguages() async -> [String] { ["zh-CN"] }
        func prepare() async throws {}

        func transcribe(fileURL: URL, trackID: String,
                        speaker: String) async throws -> [TranscriptSegment] {
            transcribedTrackIDs.append(trackID)
            return [
                TranscriptSegment(start: 0, end: 1, text: "来自\(speaker)的一句话。",
                                  track: trackID, speaker: speaker)
            ]
        }
    }

    private func config(driver: ScriptedDriver,
                        filter: Set<String>?) -> SessionTranscriber.Configuration {
        var c = SessionTranscriber.Configuration(language: "zh-CN", engine: .apple)
        c.trackFilter = filter
        c.makeDriver = { _, _ in driver }
        return c
    }

    // MARK: - 只转选中的那条轨

    /// 引擎只被叫了一次，且叫的是被选中的那条轨。
    ///
    /// 这是本功能的**核心收益**：空轨不该再跑一遍推理。
    /// 只断言产物文件的话，一个「偷偷转了两轨但只报一份」的实现也能过。
    func testOnlyTheSelectedTrackIsSentToTheEngine() async throws {
        let (store, _) = try makeSession()
        let driver = ScriptedDriver()
        let transcriber = SessionTranscriber(
            store: store, configuration: config(driver: driver, filter: ["mic"]))

        _ = try await transcriber.transcribe(sessionID: sessionID)

        XCTAssertEqual(driver.transcribedTrackIDs, ["mic"],
                       "只该转写 mic 轨；对方那条是空的，跑一遍纯属浪费")
    }

    /// 产物写到 `transcript-mic.md` / `.json`。
    func testSingleTrackOutputGoesToItsOwnFileName() async throws {
        let (store, dir) = try makeSession()
        let transcriber = SessionTranscriber(
            store: store, configuration: config(driver: ScriptedDriver(), filter: ["mic"]))

        let outcome = try await transcriber.transcribe(sessionID: sessionID)

        XCTAssertEqual(outcome.markdownURL.lastPathComponent, "transcript-mic.md")
        XCTAssertEqual(outcome.jsonURL.lastPathComponent, "transcript-mic.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.markdownURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.jsonURL.path))
        XCTAssertEqual(outcome.document.segments.count, 1)
        XCTAssertEqual(outcome.document.segments[0].track, "mic")
        _ = dir
    }

    /// **绝不能覆盖整场稿。**
    ///
    /// 这是本功能最坏的失败形态：用户已经有一份双轨稿，
    /// 点了「只转写我这条轨」，结果整场稿被单轨稿替换，
    /// 对方那一路的内容永久消失，而界面上「已转写」的标记还亮着。
    func testSingleTrackRunNeverOverwritesTheWholeSessionTranscript() async throws {
        let (store, dir) = try makeSession()
        // 先造一份已存在的整场稿，内容必须一字不差地留下来。
        let md = dir.appendingPathComponent(SessionStore.transcriptMarkdownName)
        let json = dir.appendingPathComponent(SessionStore.transcriptJSONName)
        let originalMarkdown = "# 原稿\n\n这一行绝不能被单轨转录覆盖掉。\n"
        let originalDocument = TranscriptDocument(
            sessionID: sessionID, title: "单轨测试", language: "zh-CN",
            engine: "apple-speech",
            segments: [TranscriptSegment(start: 0, end: 1, text: "原来的双轨内容。",
                                        track: "system", speaker: "对方")])
        try originalMarkdown.write(to: md, atomically: true, encoding: .utf8)
        try originalDocument.json().write(to: json)

        let transcriber = SessionTranscriber(
            store: store, configuration: config(driver: ScriptedDriver(), filter: ["mic"]))
        _ = try await transcriber.transcribe(sessionID: sessionID)

        XCTAssertEqual(try String(contentsOf: md, encoding: .utf8), originalMarkdown,
                       "单轨转录**绝不能**覆盖整场 transcript.md——"
                       + "那会把另一条轨的内容永久抹掉")
        // 解码策略必须与 `SessionLibrary.transcript` 一致（iso8601）。
        // 用默认策略的话，`generatedAt` 是字符串而解码器期待 Double，
        // 于是这条用例会以「解码失败」告终——那测的是解码器，不是本功能。
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reloaded = try decoder.decode(
            TranscriptDocument.self, from: Data(contentsOf: json))
        XCTAssertEqual(reloaded.segments.map(\.track), ["system"],
                       "整场 transcript.json 也不能被动")
        XCTAssertEqual(reloaded.segments.first?.text, "原来的双轨内容。")
    }

    /// **不改 `manifest.state`。**
    ///
    /// 只转了一半却标成 `.transcribed`，界面上就显示成「已转写」，
    /// 而对方那一轨根本没转。用户点开看到的是一份缺了一半的稿子，
    /// 却没有任何地方告诉他这一点。
    func testSingleTrackRunDoesNotMarkTheSessionAsTranscribed() async throws {
        let (store, dir) = try makeSession()
        let transcriber = SessionTranscriber(
            store: store, configuration: config(driver: ScriptedDriver(), filter: ["mic"]))

        _ = try await transcriber.transcribe(sessionID: sessionID)

        let reloaded = try store.loadManifest(sessionDirectory: dir)
        XCTAssertNotEqual(reloaded.state, .transcribed,
                          "只转了一条轨，不能标成「已转写」——"
                          + "否则界面会把一份缺了一半的稿子显示成完整的")
    }

    /// 整场转写（`trackFilter == nil`）的原有行为**一条都不能变**。
    ///
    /// 单轨功能是加法。回归的方向很具体：若有人为了省事让
    /// 「nil 也写成 `Set(manifest.tracks)`」，那么
    /// `transcript.md` 会变成 `transcript-mic-system.md`，整场转写彻底坏掉，
    /// 而上面那些单轨用例全绿。
    func testWholeSessionRunKeepsWritingTheOriginalFileNames() async throws {
        let (store, dir) = try makeSession()
        let driver = ScriptedDriver()
        let transcriber = SessionTranscriber(
            store: store, configuration: config(driver: driver, filter: nil))

        let outcome = try await transcriber.transcribe(sessionID: sessionID)

        XCTAssertEqual(outcome.markdownURL.lastPathComponent,
                       SessionStore.transcriptMarkdownName,
                       "整场转写必须仍写 transcript.md，不能变成带轨名的文件")
        XCTAssertEqual(outcome.jsonURL.lastPathComponent,
                       SessionStore.transcriptJSONName)
        XCTAssertEqual(driver.transcribedTrackIDs, ["mic", "system"],
                       "整场转写必须仍转两条轨")
        XCTAssertEqual(try store.loadManifest(sessionDirectory: dir).state, .transcribed,
                       "整场转写仍然要把状态改成 transcribed")
    }

    // MARK: - 单轨不该做的事

    /// **⚡ 抢话标记在单轨下恒为 false。**
    ///
    /// `overlapping` 的判据是「同一时段另一条轨也有内容」。单轨时另一条轨
    /// 根本没进这份文档，所以恒为 false——这不是 bug，是无从判定。
    /// 钉住它是为了防止将来有人给单轨稿加个「按音量猜对方在不在说话」的启发式：
    /// 那种标记看起来像信息，实际是编的。
    func testSingleTrackDocumentNeverMarksOverlapping() async throws {
        let (store, _) = try makeSession()
        let transcriber = SessionTranscriber(
            store: store, configuration: config(driver: ScriptedDriver(), filter: ["mic"]))

        let outcome = try await transcriber.transcribe(sessionID: sessionID)

        XCTAssertFalse(outcome.document.segments.contains { $0.overlapping },
                       "单轨没有另一条轨可比，⚡ 标记必须恒为 false")
    }

    /// 产出里必须说明「这是单轨稿」，且说清**没做什么**。
    ///
    /// 少了后半句，用户会把这份稿子当成已经去过重的完整稿——
    /// 而用扬声器开会时，对方的话会经扬声器漏进麦克风，
    /// 同一句在这份稿子里出现两次正是它没做的事。
    func testSingleTrackOutcomeExplainsWhatItDidNotDo() async throws {
        let (store, _) = try makeSession()
        let transcriber = SessionTranscriber(
            store: store, configuration: config(driver: ScriptedDriver(), filter: ["mic"]))

        let outcome = try await transcriber.transcribe(sessionID: sessionID)

        let all = outcome.warnings.joined(separator: "\n")
        XCTAssertTrue(all.contains("单轨"), "必须说明这是单轨稿：\(all)")
        XCTAssertTrue(all.contains("回声") || all.contains("重复"),
                      "必须说明没有做跨轨去重：\(all)")
        XCTAssertTrue(all.contains("整场") || all.contains("另一"),
                      "必须指向补齐的方式：\(all)")
    }

    /// 整场稿里**不能**出现「只转了一条轨」这类说明。
    ///
    /// 退化示例：把「单轨时才加这句」写成无条件添加，本用例变红——
    /// 而界面上没人在意一段多余的提醒，它只是让真正的单轨提醒变得不值钱。
    func testWholeSessionOutcomeDoesNotMentionSingleTrack() async throws {
        let (store, _) = try makeSession()
        let transcriber = SessionTranscriber(
            store: store, configuration: config(driver: ScriptedDriver(), filter: nil))

        let outcome = try await transcriber.transcribe(sessionID: sessionID)

        XCTAssertFalse(outcome.warnings.joined(separator: "\n").contains("单轨"),
                       "整场转写不该带单轨说明：\(outcome.warnings)")
    }

    // MARK: - 时间轴

    /// 单轨也要按 hostTime 对齐到会话时间轴。
    ///
    /// 夹具里 system 轨比 mic 晚 0.4 秒启动，所以「只转 system」时
    /// 段落的开始时间应当是 0.4 而不是 0。不对齐的话，
    /// 单轨稿与整场稿对不上时间，同一场会议出现两个时间线。
    func testSingleTrackIsStillShiftedOntoTheSessionTimeline() async throws {
        let (store, _) = try makeSession()
        let transcriber = SessionTranscriber(
            store: store, configuration: config(driver: ScriptedDriver(), filter: ["system"]))

        let outcome = try await transcriber.transcribe(sessionID: sessionID)

        let segment = try XCTUnwrap(outcome.document.segments.first)
        XCTAssertEqual(segment.start, 0.4, accuracy: 0.01,
                       "只转 system 轨时也要按 hostTime 平移到会话时间轴")
        XCTAssertEqual(segment.end, 1.4, accuracy: 0.01)
    }

    // MARK: - 参数校验

    /// 指定的轨不存在时**报错**，列出可选的轨。
    ///
    /// 静默转成「转全部」是最糟的读法：用户敲 `--track mci`（手滑），
    /// 拿到一份完整双轨稿，而以为自己只是重转了「我」那条——
    /// 然后在「转写花了 3 倍时间」里找不到原因。
    func testUnknownTrackIDIsRejectedWithTheAvailableList() async throws {
        let (store, _) = try makeSession()
        let driver = ScriptedDriver()
        let transcriber = SessionTranscriber(
            store: store, configuration: config(driver: driver, filter: ["mci"]))

        do {
            _ = try await transcriber.transcribe(sessionID: sessionID)
            XCTFail("指定了不存在的轨必须报错，不能静默转全部")
        } catch let error as MRError {
            let text = "\(error)"
            XCTAssertTrue(text.contains("mic"), "报错要列出可用的轨：\(text)")
            XCTAssertTrue(text.contains("system"), "报错要列出可用的轨：\(text)")
        }
        XCTAssertTrue(driver.transcribedTrackIDs.isEmpty,
                      "报错时不该已经转了任何轨")
    }

    /// 指定多条轨是允许的（不只支持「一条」）。
    ///
    /// 这是「按轨筛选」而不是「按单轨」的读法：将来如果 manifest 里
    /// 出现第三条轨，用户会想只转其中两条。产物文件名此时必须能区分开。
    func testMultipleSelectedTracksProduceDistinctFileNames() async throws {
        let (store, _) = try makeSession()
        let transcriber = SessionTranscriber(
            store: store, configuration: config(driver: ScriptedDriver(),
                                                filter: ["mic", "system"]))

        let outcome = try await transcriber.transcribe(sessionID: sessionID)

        XCTAssertEqual(outcome.markdownURL.lastPathComponent,
                       "transcript-mic-system.md",
                       "选了多条轨时文件名要列出全部轨，否则两个筛选结果会互相覆盖")
        XCTAssertNotEqual(outcome.markdownURL.lastPathComponent,
                          SessionStore.transcriptMarkdownName)
    }

    /// 空的筛选集（既没指定 `--track`、集合又是空的）当作「转全部」。
    ///
    /// `Set<String>()` 与 `nil` 在调用方可能不区分得清，而
    /// 「转全部」是两种解释里安全的那个（它不改任何既有文件的状态）。
    func testEmptyFilterSetMeansWholeSession() async throws {
        let (store, dir) = try makeSession()
        let driver = ScriptedDriver()
        let transcriber = SessionTranscriber(
            store: store, configuration: config(driver: driver, filter: []))

        let outcome = try await transcriber.transcribe(sessionID: sessionID)

        XCTAssertEqual(driver.transcribedTrackIDs, ["mic", "system"])
        XCTAssertEqual(outcome.markdownURL.lastPathComponent,
                       SessionStore.transcriptMarkdownName)
        XCTAssertEqual(try store.loadManifest(sessionDirectory: dir).state, .transcribed)
    }
}