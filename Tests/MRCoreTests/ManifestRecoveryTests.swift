import XCTest
@testable import MRCore

/// 崩溃恢复。
///
/// 场景：录制中被强杀 → 下次启动必须能找回，且音频头部要修好、时长要算对。
/// 「录音丢一次就再没人用了」，所以这是必需项而不是加分项。
final class ManifestRecoveryTests: XCTestCase {

    private var root: URL!
    private var store: SessionStore!
    private var recovery: Recovery!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-test-\(UUID().uuidString)", isDirectory: true)
        store = SessionStore(root: root)
        recovery = Recovery(store: store)
        try store.ensureRoot()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 造一个「录制中被杀」的会话：manifest 停在 recording，WAV 没 finalize
    @discardableResult
    private func makeCrashedSession(
        title: String = "崩溃的会议",
        frames: Int = 48000,
        channels: Int = 1,
        withAudioFile: Bool = true,
        firstHostTime: UInt64 = 0,
        lastHostTime: UInt64 = 0
    ) throws -> (id: String, dir: URL) {
        let (id, dir) = try store.createSession(title: title)
        var m = RecordingManifest(sessionID: id, title: title, state: .recording)
        m.tracks = [TrackManifest(
            id: "mic", role: .microphone, fileName: "mic.wav",
            sampleRate: 48000, channels: channels, framesWritten: 0,
            firstHostTime: firstHostTime, lastHostTime: lastHostTime,
            deviceName: "测试麦克风")]
        try store.save(m, sessionDirectory: dir)

        if withAudioFile {
            let w = try WAVWriter(
                url: dir.appendingPathComponent("mic.wav"),
                sampleRate: 48000, channels: channels, format: .float32)
            let samples = (0..<(frames * channels)).map { _ in Float(0.1) }
            try w.append(samples)
            w.abort()   // 头部保持占位值 —— 这就是崩溃现场
        }
        return (id, dir)
    }

    // MARK: - 基本恢复

    func testRecoversCrashedSession() throws {
        let (id, _) = try makeCrashedSession(frames: 96000)

        let report = try recovery.scanAndRepair()
        XCTAssertEqual(report.scanned, 1)
        XCTAssertEqual(report.recovered.count, 1)
        XCTAssertEqual(report.recovered[0].sessionID, id)
        XCTAssertTrue(report.failed.isEmpty)
    }

    func testRepairedStateIsPersisted() throws {
        let (id, dir) = try makeCrashedSession()
        _ = try recovery.scanAndRepair()

        let after = try store.loadManifest(sessionDirectory: dir)
        XCTAssertEqual(after.state, .recovered)
        XCTAssertNotNil(after.endedAt, "恢复后必须补上结束时间")
        XCTAssertTrue(after.notes.contains { $0.contains("崩溃恢复") })
        XCTAssertEqual(after.sessionID, id)
    }

    func testRecoveredFrameCountComesFromRealFileSize() throws {
        let (_, dir) = try makeCrashedSession(frames: 96000)

        let report = try recovery.scanAndRepair()
        let track = report.recovered[0].tracks[0]
        XCTAssertEqual(track.framesBefore, 0, "崩溃前 manifest 里记的是 0")
        XCTAssertEqual(track.framesAfter, 96000, "恢复后必须从文件实际长度反推出正确帧数")
        XCTAssertTrue(track.headerRepaired)

        let manifest = try store.loadManifest(sessionDirectory: dir)
        XCTAssertEqual(manifest.tracks[0].framesWritten, 96000)
        XCTAssertEqual(manifest.tracks[0].duration, 2.0, accuracy: 1e-9)
    }

    func testRecoveredAudioHeaderIsActuallyValid() throws {
        let (_, dir) = try makeCrashedSession(frames: 48000)
        _ = try recovery.scanAndRepair()

        // 修复后必须能被标准读法正常读出来
        let info = try WAVWriter.readHeader(at: dir.appendingPathComponent("mic.wav"))
        XCTAssertTrue(info.isConsistent)
        XCTAssertEqual(info.frameCount, 48000)
        XCTAssertEqual(info.duration, 1.0, accuracy: 1e-9)
    }

    func testStereoChannelCountPreserved() throws {
        let (_, dir) = try makeCrashedSession(frames: 24000, channels: 2)
        let report = try recovery.scanAndRepair()
        XCTAssertEqual(report.recovered[0].tracks[0].framesAfter, 24000,
                       "立体声轨恢复后帧数不能按采样数算成两倍")

        let info = try WAVWriter.readHeader(at: dir.appendingPathComponent("mic.wav"))
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.duration, 0.5, accuracy: 1e-9)
    }

    // MARK: - 幂等与跳过

    func testScanIsIdempotent() throws {
        try makeCrashedSession()
        let first = try recovery.scanAndRepair()
        XCTAssertEqual(first.recovered.count, 1)

        let second = try recovery.scanAndRepair()
        XCTAssertEqual(second.recovered.count, 0, "已恢复的会话不应被再次处理")
        XCTAssertEqual(second.scanned, 1, "但仍应被扫描到")
    }

    func testSkipsProperlyFinalizedSessions() throws {
        let (id, dir) = try store.createSession(title: "正常结束")
        var m = RecordingManifest(sessionID: id, title: "正常结束", state: .recording)
        m.tracks = [TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                                  sampleRate: 48000, channels: 1)]
        try store.save(m, sessionDirectory: dir)

        let w = try WAVWriter(url: dir.appendingPathComponent("mic.wav"),
                              sampleRate: 48000, channels: 1)
        try w.append([Float](repeating: 0.1, count: 4800))
        try w.finalize()
        w.close()

        m.state = .finalized
        m.endedAt = Date()
        m.tracks[0].framesWritten = 4800
        try store.save(m, sessionDirectory: dir)

        let report = try recovery.scanAndRepair()
        XCTAssertEqual(report.recovered.count, 0)
        XCTAssertEqual(try store.loadManifest(sessionDirectory: dir).state, .finalized)
    }

    func testAlreadyTranscribedSessionUntouched() throws {
        let (id, dir) = try store.createSession(title: "已转写")
        var m = RecordingManifest(sessionID: id, title: "已转写", state: .transcribed)
        m.tracks = [TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                                  sampleRate: 48000, channels: 1)]
        try store.save(m, sessionDirectory: dir)

        let report = try recovery.scanAndRepair()
        XCTAssertEqual(report.recovered.count, 0)
        XCTAssertEqual(report.failed.count, 0)
        XCTAssertEqual(try store.loadManifest(sessionDirectory: dir).state, .transcribed)
    }

    // MARK: - 异常输入

    func testMissingAudioFileIsReportedNotCrashed() throws {
        let (_, dir) = try makeCrashedSession(withAudioFile: false)
        let report = try recovery.scanAndRepair()

        XCTAssertEqual(report.recovered.count, 1, "音频缺失不该阻断整个恢复流程")
        let track = report.recovered[0].tracks[0]
        XCTAssertNotNil(track.problem)
        XCTAssertTrue(track.problem!.contains("缺失"))
        // manifest 仍应被标记为 recovered，让用户能看到这一条并决定怎么处理
        XCTAssertEqual(try store.loadManifest(sessionDirectory: dir).state, .recovered)
    }

    func testCorruptAudioFileIsReportedNotCrashed() throws {
        let (_, dir) = try makeCrashedSession(withAudioFile: false)
        try Data("not a wav at all, just garbage bytes here".utf8)
            .write(to: dir.appendingPathComponent("mic.wav"))

        let report = try recovery.scanAndRepair()
        XCTAssertEqual(report.recovered.count, 1)
        XCTAssertNotNil(report.recovered[0].tracks[0].problem)
    }

    func testBrokenManifestIsListedAsFailure() throws {
        try store.ensureRoot()
        let dir = root.appendingPathComponent("2026-01-01-000000-坏掉的")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ 这不是合法 JSON".utf8).write(to: dir.appendingPathComponent("manifest.json"))

        let report = try recovery.scanAndRepair()
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertEqual(report.failed[0].sessionID, "2026-01-01-000000-坏掉的")
    }

    func testEmptyRootProducesEmptyReport() throws {
        let report = try recovery.scanAndRepair()
        XCTAssertEqual(report.scanned, 0)
        XCTAssertTrue(report.recovered.isEmpty)
        XCTAssertTrue(report.failed.isEmpty)
    }

    // MARK: - 结束时间反推

    func testInferEndDateUsesTrackSpanNotWallClock() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let tickSeconds = HostClock.nanosecondsPerTick / 1e9
        let t0: UInt64 = 5_000_000
        let t1 = t0 + UInt64((125.0 / tickSeconds).rounded())

        let tracks = [TrackManifest(
            id: "mic", role: .microphone, fileName: "mic.wav",
            sampleRate: 48000, channels: 1,
            firstHostTime: t0, lastHostTime: t1)]

        let end = Recovery.inferEndDate(startedAt: started, tracks: tracks)
        XCTAssertEqual(end.timeIntervalSince(started), 125.0, accuracy: 0.1,
                       "结束时间应由音轨真实跨度决定，而不是写成「现在」——否则隔天恢复会得到荒谬时长")
    }

    func testInferEndDateFallsBackToStartWhenNoSpan() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let tracks = [TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                                    sampleRate: 48000, channels: 1)]
        XCTAssertEqual(Recovery.inferEndDate(startedAt: started, tracks: tracks), started)
    }

    /// 崩溃时 manifest 可能还没写回过 hostTime（录制期 checkpoint 未到点）。
    /// 这时必须退化为用帧数推算，而不是把 endedAt 写成恢复发生的时刻。
    func testInferEndDateFallsBackToFrameCount() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let tracks = [TrackManifest(
            id: "mic", role: .microphone, fileName: "mic.wav",
            sampleRate: 48000, channels: 1, framesWritten: 240_000)]
        let end = Recovery.inferEndDate(startedAt: started, tracks: tracks)
        XCTAssertEqual(end.timeIntervalSince(started), 5.0, accuracy: 1e-9)
    }

    func testInferEndDatePrefersHostSpanOverFrameCount() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let tickSeconds = HostClock.nanosecondsPerTick / 1e9
        let t0: UInt64 = 9_000_000
        let t1 = t0 + UInt64((42.0 / tickSeconds).rounded())
        // 帧数只够 5 秒，但 hostTime 明确说录了 42 秒 —— 应以 hostTime 为准
        let tracks = [TrackManifest(
            id: "mic", role: .microphone, fileName: "mic.wav",
            sampleRate: 48000, channels: 1, framesWritten: 240_000,
            firstHostTime: t0, lastHostTime: t1)]
        let end = Recovery.inferEndDate(startedAt: started, tracks: tracks)
        XCTAssertEqual(end.timeIntervalSince(started), 42.0, accuracy: 0.05)
    }

    /// 恢复后结束时间应来自**精确的文件长度**，而不是 checkpoint 的近似 hostTime。
    func testRecoveryComputesEndDateFromExactFrameCount() throws {
        let tickSeconds = HostClock.nanosecondsPerTick / 1e9
        let t0: UInt64 = 2_000_000
        let t1 = t0 + UInt64((45.0 / tickSeconds).rounded())

        let (_, dir) = try makeCrashedSession(
            frames: 48000 * 45, channels: 1, firstHostTime: t0, lastHostTime: t1)
        _ = try recovery.scanAndRepair()

        let m = try store.loadManifest(sessionDirectory: dir)
        XCTAssertEqual(m.endedAt!.timeIntervalSince(m.startedAt), 45.0, accuracy: 0.1)
        XCTAssertEqual(m.tracks[0].duration, 45.0, accuracy: 0.01)
    }

    /// checkpoint 落后于实际录制进度时（最多落后一个间隔），
    /// 必须以文件实际长度为准，否则恢复出的时长会偏短。
    func testRecoveryPrefersFileLengthOverStaleCheckpoint() throws {
        let tickSeconds = HostClock.nanosecondsPerTick / 1e9
        let t0: UInt64 = 2_000_000
        let staleT1 = t0 + UInt64((30.0 / tickSeconds).rounded())   // checkpoint 只记到 30 秒

        let (_, dir) = try makeCrashedSession(
            frames: 48000 * 45, channels: 1, firstHostTime: t0, lastHostTime: staleT1)
        _ = try recovery.scanAndRepair()

        let m = try store.loadManifest(sessionDirectory: dir)
        XCTAssertEqual(m.tracks[0].duration, 45.0, accuracy: 0.01, "以文件长度为准")
        XCTAssertEqual(m.endedAt!.timeIntervalSince(m.startedAt), 45.0, accuracy: 0.1,
                       "不应被落后的 checkpoint 拉短")
    }

    // MARK: - 完整链路：崩溃 → 恢复 → 时长可信

    func testEndToEndCrashThenRecoverGivesUsableDuration() throws {
        let tickSeconds = HostClock.nanosecondsPerTick / 1e9
        let t0: UInt64 = 1_000_000
        let seconds = 30.0
        let t1 = t0 + UInt64((seconds / tickSeconds).rounded())
        let frames = Int(48000 * seconds)

        let (_, dir) = try makeCrashedSession(
            frames: frames, channels: 1, firstHostTime: t0, lastHostTime: t1)

        let report = try recovery.scanAndRepair()
        XCTAssertEqual(report.recovered.count, 1)
        XCTAssertEqual(report.recovered[0].duration, seconds, accuracy: 0.01)

        let m = try store.loadManifest(sessionDirectory: dir)
        XCTAssertEqual(m.state, .recovered)
        XCTAssertEqual(m.tracks[0].duration, seconds, accuracy: 0.01)
        XCTAssertEqual(m.endedAt!.timeIntervalSince(m.startedAt), seconds, accuracy: 0.1)
        XCTAssertTrue(m.tracks[0].warnings.contains { $0.contains("崩溃后恢复") })
    }
}

/// manifest 读失败时的**报错措辞**。
///
/// 这段文字会原样出现在界面横幅上。它必须一眼让人看懂「是文件坏了，
/// 不是程序坏了」——而不是糊一整面
/// `UserInfo={NSJSONSerializationErrorIndex=3, NSDebugDescription=...}` 上去，
/// 把唯一有用的信息埋在中间。
final class ManifestErrorTextTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ text: String, as name: String = "manifest.json") throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testInvalidJSONIsDescribedInPlainWords() throws {
        let url = try write("{ 这不是 JSON ")
        XCTAssertThrowsError(try RecordingManifest.read(from: url)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("JSON 无效"),
                          "要说清楚是 JSON 的问题，收到：\(text)")
            XCTAssertFalse(text.contains("UserInfo={"),
                           "别把这串内部结构糊到界面上，收到：\(text)")
            XCTAssertFalse(text.contains("NSDebugDescription"),
                           "别把这串内部结构糊到界面上，收到：\(text)")
            XCTAssertTrue(text.contains("manifest.json"), "要带上文件路径：\(text)")
        }
    }

    func testMissingFieldNamesTheField() throws {
        // 合法 JSON，但缺 sessionID
        let url = try write(#"{"version":1,"title":"x","startedAt":"2026-09-27T00:00:00.000Z"}"#)
        XCTAssertThrowsError(try RecordingManifest.read(from: url)) { error in
            XCTAssertTrue("\(error)".contains("sessionID"),
                          "要指出缺的是哪个字段，收到：\(error)")
        }
    }

    func testBadTimestampPointsAtTheField() throws {
        let url = try write(#"{"sessionID":"s","startedAt":"不是时间","tracks":[]}"#)
        XCTAssertThrowsError(try RecordingManifest.read(from: url)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("startedAt"), "要带出错字段的位置：\(text)")
            XCTAssertTrue(text.contains("无法解析时间戳"), "要说明是时间戳的问题：\(text)")
        }
    }

    func testUnreadableFileStillReportsThePath() throws {
        XCTAssertThrowsError(
            try RecordingManifest.read(from: root.appendingPathComponent("根本不存在.json"))) { error in
            XCTAssertTrue("\(error)".contains("根本不存在.json"))
        }
    }
}
