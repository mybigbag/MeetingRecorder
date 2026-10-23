import XCTest
@testable import MRSession
@testable import MRTranscribe
import MRCore

/// 引擎「就绪」是转写的前置门槛，不是逐轨的偶然失败。
///
/// 背景：逐轨转写是**单轨失败不中断**的（一轨坏掉不该连累另一轨）。那条设计本身没错，
/// 但它会把「引擎根本不可用」（资产没装好、语言资产装不上）变成「每一轨各失败一次」，
/// 最后留下一份空稿、退出码还是 0——**把「引擎坏了」说成「这场没人说话」**。
///
/// 所以 readiness（`driver.prepare()`）被提到循环之前。这组用例钉住这个门槛：
/// 引擎未就绪时，转写必须在**写任何文件之前**明确抛错，且不得改动 manifest 状态。
///
/// **为什么注入驱动器工厂**：SenseVoice 的资产落在 `~/Library/Application Support` 下。
/// 不隔离的话，这组用例在「装过模型的开发机」上会走到真推理上去，结论随机器而变——
/// 而一个只在干净机器上通过的用例，等于没有。
final class SessionTranscriberEngineGateTests: XCTestCase {

    private var root: URL!
    private var assets: URL!
    private let sessionID = "2026-09-29-gate-test"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-engine-gate-\(UUID().uuidString)", isDirectory: true)
        assets = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-engine-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: assets)
        root = nil
        assets = nil
    }

    /// 造一场「已录制完成、有一条轨」的会议。
    ///
    /// `withAudio == false`：**故意不写真实的 WAV**。门槛必须在**打开任何音频之前**
    /// 就拦住，所以那条用例若真的走到读音频那一步，本身就是回归（会以别的错误失败，
    /// 而不是按预期在门槛处抛错）。
    ///
    /// `withAudio == true`：写一段真实（1 秒）的 WAV。就绪那条路会一路走到
    /// `AudioSlicer.inspect` 去读时长，一个空文件/不存在的文件在那里就断了——
    /// 那测到的是「音频读不了」，不是「门槛放行」。假 runner 返回的稿子与音频内容无关，
    /// 所以这段音频只需要**结构合法**。
    private func makeSession(withAudio: Bool = false) throws -> (SessionStore, URL) {
        let store = SessionStore(root: root)
        let dir = store.directory(forSessionID: sessionID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = RecordingManifest(
            sessionID: sessionID,
            title: "gate-test",
            state: .finalized,
            tracks: [
                TrackManifest(
                    id: "mic", role: .microphone, fileName: "mic.wav",
                    sampleRate: 48000, channels: 1, framesWritten: 24000),
            ])
        try store.save(manifest, sessionDirectory: dir)

        if withAudio {
            let url = store.trackURL(sessionDirectory: dir, fileName: "mic.wav")
            let writer = try WAVWriter(url: url, sampleRate: 48000, channels: 1)
            try writer.append([Float](repeating: 0, count: 48000))   // 1 秒
            try writer.finalize()
            writer.close()
        }
        return (store, dir)
    }

    /// 把 SenseVoice 驱动器指到隔离的资产目录上。
    private func isolatedConfiguration(
        runner: SenseVoiceProcessRunnerStub = SenseVoiceProcessRunnerStub()
    ) -> SessionTranscriber.Configuration {
        let paths = SenseVoicePaths(baseDirectory: assets)
        return .init(
            language: "zh-CN",
            engine: .senseVoice,
            makeDriver: { _, language in
                SenseVoiceTranscriptionEngine(
                    language: language, paths: paths, runner: runner,
                    environment: [:], bundle: .main)
            })
    }

    func testUnusableEngineFailsBeforeWritingAnything() async throws {
        let (store, dir) = try makeSession()
        let transcriber = SessionTranscriber(
            store: store, configuration: isolatedConfiguration())

        do {
            _ = try await transcriber.transcribe(sessionID: sessionID)
            XCTFail("用未就绪的引擎转写必须抛错，而不是安静地产出空稿")
        } catch let error as MRError {
            guard case .transcription = error else {
                return XCTFail("应抛 .transcription，实际：\(error)")
            }
        }

        // 关键断言一：不产出任何转写稿。空稿会被下游当成「这场确实没人说话」。
        let md = dir.appendingPathComponent(SessionStore.transcriptMarkdownName)
        let json = dir.appendingPathComponent(SessionStore.transcriptJSONName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: md.path), "失败时不得写出 Markdown 稿")
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path), "失败时不得写出 JSON 稿")

        // 关键断言二：manifest 状态不得被改成 transcribed。
        let reloaded = try store.loadManifest(sessionDirectory: dir)
        XCTAssertEqual(reloaded.state, .finalized, "引擎不可用时不得把状态改成 transcribed")
    }

    /// 门槛的**另一半**：资产就绪时这条路必须真的能走通。
    ///
    /// 只测「失败得对」是不够的——一个恒抛错的实现能让上面那条用例永远为绿。
    /// 这条用最小夹具（稀疏文件 + 假 runner）证明门槛会放行，并且引擎的诊断
    /// 会经由引擎可选协议流进 `trackFinished` 的 notes。
    func testReadyEngineProceedsAndSurfacesDiagnostics() async throws {
        let (store, dir) = try makeSession(withAudio: true)
        try makeReadyAssets()

        let runner = SenseVoiceProcessRunnerStub()
        runner.result = SenseVoiceProcessResult(
            standardOutput: "1\n00:00:01,000 --> 00:00:03,000\n会议开始。\n",
            standardError: "[sensevoice] 1 vad segments\n",
            exitCode: 0)

        var notes: [String] = []
        let transcriber = SessionTranscriber(
            store: store, configuration: isolatedConfiguration(runner: runner))
        let outcome = try await transcriber.transcribe(sessionID: sessionID) { event in
            if case let .trackFinished(_, _, _, _, eventNotes, _) = event {
                notes = eventNotes
            }
        }

        XCTAssertEqual(outcome.document.segments.count, 1)
        XCTAssertEqual(outcome.document.engine, TranscriptionEngine.senseVoice.driverEngineID)
        XCTAssertEqual(outcome.document.segments[0].track, "mic")
        XCTAssertTrue(notes.contains { $0.contains("VAD 切出 1 段") },
                      "引擎诊断应流进 trackFinished 的 notes：\(notes)")

        let json = dir.appendingPathComponent(SessionStore.transcriptJSONName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))

        let reloaded = try store.loadManifest(sessionDirectory: dir)
        XCTAssertEqual(reloaded.state, .transcribed)
    }

    /// 就绪所需的资产：用**稀疏文件**凑出精确字节数，用假 runner 免掉真推理。
    ///
    /// 逐项按 `asset.byteCount` 造，**运行时也不例外**：门槛判的是精确字节数，
    /// 早先这里给运行时建了个 0 字节的空文件，于是「就绪」这条路永远走不通，
    /// 用例红得像产品坏了，实际是夹具没按自己的约定造文件。
    private func makeReadyAssets() throws {
        let paths = SenseVoicePaths(baseDirectory: assets)
        for asset in SenseVoiceAssets.all {
            let url = paths.url(for: asset)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(asset.byteCount))
            try handle.close()
        }
        // 运行时还要可执行位；否则门槛会以「不可执行」拦下它——那是另一条用例的职责。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: paths.installedRuntimeURL.path)
    }
}

/// 假的子进程执行器。放在这里而不是复用 `MRTranscribeTests` 里的那个：
/// 两个 test target 是独立模块，跨 target 复用需要一个共享的测试支撑模块，
/// 而为了一个 20 行的替身去建模块不划算。
final class SenseVoiceProcessRunnerStub: SenseVoiceProcessRunning, @unchecked Sendable {

    private let lock = NSLock()
    private var _arguments: [[String]] = []

    var result = SenseVoiceProcessResult(
        standardOutput: "", standardError: "", exitCode: 0)
    var error: Error?

    var invocations: [[String]] {
        lock.withLock { _arguments }
    }

    func run(executable: URL, arguments: [String]) async throws -> SenseVoiceProcessResult {
        // `withLock` 而不是裸的 lock/unlock：`run` 是 async，
        // 而 `NSLock.lock()` 在异步上下文里会被判成不安全（Swift 6 起是错误）。
        lock.withLock { _arguments.append(arguments) }
        if let error { throw error }
        return result
    }
}
