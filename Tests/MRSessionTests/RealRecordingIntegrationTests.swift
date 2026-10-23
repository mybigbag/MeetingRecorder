import XCTest
@testable import MRSession
import MRCapture
import MRCore

/// 真机录音集成检查：`RecordingController` + 真实 `DualTrackRecorder`。
///
/// **为什么单独一个文件、而且默认跳过。**
///
/// GUI 的录音按钮走的就是这条链路，但 `RecordingControllerTests` 用的是**假引擎**——
/// 因为真录音需要「麦克风」和「系统音频录制」两项 TCC 授权，CI 和干净环境给不了。
/// 于是「这条真链路到底能不能录出文件」一直是个缺口，而它恰恰是用户最先碰到的东西。
///
/// 但真录音会占麦克风与系统音频、写几百 KB 文件、耗时 5 秒以上，
/// 把它塞进默认测试套件会让「`swift test` 是不是绿的」依赖运行环境的授权状态——
/// 那正是最不该有的不确定性。所以做成显式开关：
///
/// ```bash
/// MR_REAL_RECORDING_CHECK=1 swift test --filter RealRecordingIntegrationTests
/// ```
///
/// 不设这个变量时跳过，默认套件仍然是「零权限、无窗口、几秒钟跑完」。
final class RealRecordingIntegrationTests: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["MR_REAL_RECORDING_CHECK"] == "1"
    }

    // MARK: - 「这条轨的内容到底能不能用提示音判」

    /// 默认输入与默认输出是不是**同一台物理设备**。
    ///
    /// 这一位决定 mic 轨的内容判据能不能算数。共用一台设备时（典型：AirPods 同进同出），
    /// 系统会给这条麦克风启用 **回声消除**，把**本机自己播放的提示音**滤掉——
    /// 而提示音正是本文件唯一的确定音源。那种设置下 mic 轨可以整段全零，
    /// 而**麦克风本身是好的**；拿全零去判它就是假红。
    ///
    /// 判据刻意与 `doctor` 的 `CaptureReadiness` 同源（同一个
    /// `AudioDeviceIdentity.sharesPhysicalDevice`），免得同一件事在自检与测试里
    /// 得出两个不同结论。实测 2026-10-02：这台机器默认输入输出都是 AirPods，
    /// `doctor` 的结论是「麦克风轨无法用提示音验证」而不是「有问题」。
    private var inputSharesOutputDevice: Bool {
        guard let micID = AudioDevices.defaultInputDeviceID(),
              let micUID = AudioDevices.info(deviceID: micID)?.uid,
              let outID = AudioDevices.defaultOutputDeviceID(),
              let outUID = AudioDevices.info(deviceID: outID)?.uid
        else { return false }
        return AudioDeviceIdentity.sharesPhysicalDevice(micUID, outUID)
    }

    /// 这条轨的内容能不能用提示音判。
    ///
    /// 系统音频轨采的就是本机播放的声音，提示音对它是**有效音源**，永远可判——
    /// 而且它正是单声道 24 kHz 那一档收益最大的轨（2ch → 1ch 再降采样），
    /// 所以「system 轨非零」这条判据必须留着。
    /// 麦克风轨只在「输入与输出不是同一台设备」时才可判。
    private func canJudgeContent(of trackID: String) -> Bool {
        trackID == "mic" ? !inputSharesOutputDevice : true
    }

    /// 采集一帧都没写进去 → **采集链路根本没起来**，本次检验不了格式。
    ///
    /// 判据**必须是两个条件同时成立**（`framesWritten == 0` **且** `firstHostTime == 0`）。
    /// 只看 `framesWritten` 会假绿：`stats.accumulate` 在回调里是**独立于写盘成败**照常累计的，
    /// 所以「回调正常跑起来了、但新的写前管线每块都产出空数组」这种情况，
    /// `framesWritten` 也是 0 而 `firstHostTime` 非 0——那是**确凿的写盘缺陷，必须红**，
    /// 不能被当成「环境没授权」跳过。
    ///
    /// 这个盲区是被交叉审查用变异验证抓出来的：把 `TrackSamplePipeline.process` 的非恒等分支
    /// 改成恒 `return []`，只看帧数时用例**静默跳过**、毫无反应。加上 `firstHostTime`
    /// 条件之后，同样的变异会让下面的 `frameCount > 0` 断言变红。
    ///
    /// **判据成立时是 `XCTFail`，不是 `XCTSkip`。** 本文件每个用例入口都有
    /// `XCTSkipUnless(enabled)`，所以**能走到这一行就说明 `MR_REAL_RECORDING_CHECK=1`
    /// 已经显式要求了真机验证**。此时再 `XCTSkip`，等于把「要证据、但一条都没拿到」
    /// 报成通过——套件退出码 0，而 `skipped` 那一行没人会回头看。
    /// 默认套件该跳的在入口就跳掉了（默认那 5 条 skip 走的是入口），
    /// 显式验证拿不到证据必须红：否则这条用例最该拦住的那种情况（采集链路挂了）
    /// 恰好变成它最安静的时候。
    ///
    /// 0 帧的真正环境成因（TCC 授权在重新编译后失配、设备被占用、聚合设备没就绪）
    /// 都会让两轨**连回调都没跑过**，`firstHostTime` 恰好是 0——与上面的缺陷区分得开。
    ///
    /// - Returns: `true` 表示采集确实起来过、可以接着判格式；`false` 表示本次验不了，调用方应直接 `return`。
    private func captureStarted(_ manifest: RecordingManifest) -> Bool {
        guard Self.captureNeverStarted(framesWritten: manifest.tracks.map(\.framesWritten),
                                       firstHostTimes: manifest.tracks.map(\.firstHostTime))
        else { return true }
        XCTFail(Self.captureNeverStartedMessage(
            framesWritten: manifest.tracks.map(\.framesWritten),
            firstHostTimes: manifest.tracks.map(\.firstHostTime)))
        return false
    }

    /// 判据本身抽成**纯函数**，为的是它能被单元测试直接钉住。
    ///
    /// 这个判据决定「红还是放过」，判错方向就是假绿——正是 P0 那一条的成因。
    /// 放在这里（而不是散在 helper 里）之后，下面四条用例可以穷举它的分支。
    static func captureNeverStarted(framesWritten: [Int], firstHostTimes: [UInt64]) -> Bool {
        framesWritten.allSatisfy { $0 == 0 } && firstHostTimes.allSatisfy { $0 == 0 }
    }

    static func captureNeverStartedMessage(framesWritten: [Int], firstHostTimes: [UInt64]) -> String {
        "两轨都没回调过（帧数与 firstHostTime 全为 0）：采集链路没起来"
        + "（多半是 TCC 授权在重新编译后失配）。本次检验不了格式，请授权后重跑。"
        + "各轨帧数：\(framesWritten)，firstHostTime：\(firstHostTimes)"
    }

    // MARK: - 判据本身的单元覆盖（**不走真机、默认套件里就跑**）

    /// 环境没起来：两轨帧数与 firstHostTime 全 0 → 判「没起来」。
    func testCaptureNeverStartedWhenNothingRanAtAll() {
        XCTAssertTrue(Self.captureNeverStarted(framesWritten: [0, 0], firstHostTimes: [0, 0]))
    }

    /// **P0 那一条的核心**：帧数全 0，但回调跑过（`firstHostTime` 非 0）→ **不算「没起来」**。
    ///
    /// 这正是「管线被改坏、每块产出空数组」的指纹：`stats.accumulate` 独立于写盘成败照常累计，
    /// 所以回调跑过就一定有 hostTime。判成「没起来」会把确凿的写盘缺陷放走。
    func testFramesZeroButCallbackRanIsNotTreatedAsNoCapture() {
        XCTAssertFalse(Self.captureNeverStarted(framesWritten: [0, 0], firstHostTimes: [1234, 1234]))
        XCTAssertFalse(Self.captureNeverStarted(framesWritten: [0, 0], firstHostTimes: [0, 999]),
                       "只要有一轨回调跑过，就不是「环境没起来」")
    }

    /// 正常采到东西 → 不算「没起来」。
    func testCaptureStartedWhenFramesWritten() {
        XCTAssertFalse(Self.captureNeverStarted(framesWritten: [100, 200], firstHostTimes: [0, 0]),
                       "有帧数就说明写盘成功过")
    }

    /// 空 manifest（一轨都没有）按「没起来」处理——比默默放过去安全。
    func testEmptyManifestIsTreatedAsNoCapture() {
        XCTAssertTrue(Self.captureNeverStarted(framesWritten: [], firstHostTimes: []))
    }

    /// 失败文案里必须带上两轨的实际数值，否则真机上没法一眼判断是不是权限问题。
    func testFailureMessageCarriesTheObservedNumbers() {
        let msg = Self.captureNeverStartedMessage(framesWritten: [0, 0], firstHostTimes: [0, 0])
        XCTAssertTrue(msg.contains("各轨帧数：[0, 0]"), "实际：\(msg)")
        XCTAssertTrue(msg.contains("firstHostTime：[0, 0]"), "实际：\(msg)")
    }

    // MARK: - 给系统音频轨喂一段确定的声音

    /// 造一段正弦波提示音文件，用 `WAVWriter` 写——顺便让写出来的东西也被播一次。
    private func makeToneFile(seconds: Double, hz: Double = 440) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-real-tone-\(UUID().uuidString).wav")
        let writer = try WAVWriter(url: url, sampleRate: 48000, channels: 1, format: .float32)
        let frames = Int(48000 * seconds)
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            samples[i] = 0.4 * Float(sin(2 * Double.pi * hz * Double(i) / 48000))
        }
        try writer.append(samples)
        writer.close()
        return url
    }

    /// 起一个后台 `afplay` 放这段提示音。调用方负责终止。
    ///
    /// **为什么要自己喂声音。** 系统音频轨在没人放声音时本来就是全零，而
    /// 「这一段确实没出声」与「系统音频权限未生效」从录音数据上**无法区分**
    /// ——README 的已知限制里写着这件事，`doctor` 也得靠主动播一段提示音才能把两者分开。
    /// 所以「断言 system 轨采样非零」实际上是在断言「跑这条测试的时候机器上正好有音源」：
    /// 那是环境前提，不是代码性质。实测——无音源时这条必红（`system 的采样全是零`），
    /// 播上音源立刻绿。判据要落在「采集 → 量化 → 写盘」上，音源就必须由测试自己提供。
    ///
    /// 用**独立进程**播，不在测试进程里播：双轨录制默认排除本进程的音频
    /// （`systemAudioExcludesSelf`），自己播会被排除掉，等于没喂。
    private func startTone(_ url: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [url.path]
        try process.run()
        return process
    }

    func testRealRecordingThroughControllerProducesSelfConsistentSession() async throws {
        try XCTSkipUnless(enabled, """
            需要显式开启：MR_REAL_RECORDING_CHECK=1
            （真录音会占麦克风与系统音频，且依赖本机 TCC 授权）
            """)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-real-rec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let controller = await RecordingController(store: store)

        await MainActor.run { controller.start(titleBase: "真机冒烟") }

        // 等它真正进入录制态。准备阶段可能要秒级（首次建聚合设备 + 起 tap）。
        var entered = false
        for _ in 0..<150 {
            let phase = await controller.phase
            if phase == .recording { entered = true; break }
            if case let .failed(message) = phase {
                return XCTFail("启动失败：\(message)")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(entered, "15 秒内没有进入录制态")

        try await Task.sleep(nanoseconds: 5_000_000_000)   // 录 5 秒

        await MainActor.run { controller.stop() }
        var settled = false
        for _ in 0..<300 {
            let phase = await controller.phase
            if case .finished = phase { settled = true; break }
            if case let .failed(message) = phase { return XCTFail("收尾失败：\(message)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(settled, "30 秒内没有完成收尾")

        // XCTUnwrap 的 autoclosure 不支持并发，必须先 await 到局部变量
        let maybeResult = await controller.lastResult
        let result = try XCTUnwrap(maybeResult, "没有拿到录制结果")
        let warnings = await controller.warnings

        // —— 以下是这条检查的重点：不是「跑完了」，而是「落盘的东西自洽」 ——

        let library = SessionLibrary(root: root)
        let meetings = library.list()
        XCTAssertEqual(meetings.count, 1, "应当正好落下一场")

        let meeting = try XCTUnwrap(meetings.first)
        XCTAssertNil(meeting.loadError)
        XCTAssertEqual(meeting.state, .finalized)
        XCTAssertEqual(meeting.existingTrackCount, 2, "两条 wav 都应当真的存在")

        // 最诚实的判据：文件头里的帧数必须等于 manifest 声称的帧数，且不为零。
        // 「进程正常退出、退出码 0、时长对」都有可能在全零采样下成立——
        // 见 README 里「API 不报错，只会静默返回全零」那一节。
        let manifest = try library.manifest(forSessionID: meeting.id)
        guard captureStarted(manifest) else { return }
        XCTAssertFalse(manifest.tracks.isEmpty, "manifest 里没有任何音轨")
        for track in manifest.tracks {
            let url = meeting.directory.appendingPathComponent(track.fileName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(track.fileName) 不存在")
            let header = try WAVWriter.readHeader(at: url)
            XCTAssertEqual(header.frameCount, track.framesWritten,
                           "\(track.id) 的文件帧数与 manifest 不一致")
            XCTAssertGreaterThan(header.frameCount, 0, "\(track.id) 一帧都没写进去")
            XCTAssertGreaterThan(header.duration, 1, "\(track.id) 时长明显不对")
        }

        // 两轨都要有数据。只有一轨通常意味着对应权限没给——必须暴露出来，
        // 不能让「录到了一个只有自己的会议」静默通过。
        for track in manifest.tracks {
            XCTAssertFalse(warnings.contains { $0.contains("[\(track.id)]") },
                           "\(track.id) 报了「未采到有效数据」：\(warnings)")
        }

        print("""
            === 真机录音检查 ===
            会话：\(result.sessionID)
            两轨启动差：\(String(format: "%.4f", result.startSkew)) s
            共同覆盖：\(String(format: "%.2f", result.overlapDuration)) s
            \(result.tracks.map {
                "  [\($0.displayName)] \($0.id)  \(String(format: "%.2f", $0.seconds))s  "
                + "\(Int($0.sampleRate))Hz \($0.channels)ch \($0.frames) 帧"
            }.joined(separator: "\n"))
            警告：\(warnings.isEmpty ? "无" : warnings.joined(separator: " | "))
            """)
    }

    /// 真机录音**含暂停**：静音的那一段必须是真静音，且两轨时间轴仍然自洽。
    ///
    /// 语义已改过一次：暂停现在写静音帧而非丢弃数据（旧测试名里的 `Excises`
    /// 已不副实，改名是为了不让后来的人照着旧名字去找"掐掉"的逻辑）。
    ///
    /// 这是分轨静音唯一无法靠单测证明的地方：假引擎只能证明状态机转对了，
    /// 证明不了「静音期间回调真的写进了零」，也证明不了「写零之后
    /// 帧数与时钟还对得上」。而这两个恰好是全部风险所在——
    /// 出错的形态是「静音里混进环境声」「两轨长度分叉」「漂移告警误报」，
    /// 都不是崩溃，只会在事后回听或转写时才被发现。
    ///
    /// 判据把三样东西绑在一起：
    ///   文件帧数 / 采样率  ==  墙钟跨度（endedAt − startedAt）
    /// 任意一处偷懒（静音没生效、帧没写、时长算错）都会让等式不成立。
    func testRealPauseWritesSilenceAndKeepsTimelineConsistent() async throws {
        try XCTSkipUnless(enabled, """
            需要显式开启：MR_REAL_RECORDING_CHECK=1
            （真录音会占麦克风与系统音频，且依赖本机 TCC 授权）
            """)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-real-pause-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let controller = await RecordingController(store: store)
        await MainActor.run { controller.start(titleBase: "暂停冒烟") }

        // 等进入录制态
        var entered = false
        for _ in 0..<150 {
            let phase = await controller.phase
            if phase == .recording { entered = true; break }
            if case let .failed(message) = phase { return XCTFail("启动失败：\(message)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(entered, "15 秒内没有进入录制态")

        try await Task.sleep(nanoseconds: 3_000_000_000)   // 录 3 秒
        let elapsedBeforePause = await controller.elapsed

        await MainActor.run { controller.pause() }
        let pausedPhase = await controller.phase
        XCTAssertEqual(pausedPhase, .paused, "暂停没有落到 paused 状态")

        // 静音期间计时**照走**——写的是静音帧，文件长度不变，
        // 内容时长自然不减。这与「暂停即掐掉、计时冻住」的旧行为相反，
        // 改动原因见 `MeetingDetailView` 与 `DualTrackRecorder.pause()` 的注释：
        // 两轨文件必须等长，分轨静音才成立。
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let elapsedWhilePaused = await controller.elapsed
        XCTAssertGreaterThan(elapsedWhilePaused, elapsedBeforePause,
                             "静音期间写静音帧，计时应当继续走（\(elapsedBeforePause) → \(elapsedWhilePaused)）")

        await MainActor.run { controller.resume() }
        try await Task.sleep(nanoseconds: 3_000_000_000)   // 再录 3 秒
        await MainActor.run { controller.stop() }

        var settled = false
        for _ in 0..<300 {
            let phase = await controller.phase
            if case .finished = phase { settled = true; break }
            if case let .failed(message) = phase { return XCTFail("收尾失败：\(message)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(settled, "30 秒内没有完成收尾")

        let library = SessionLibrary(root: root)
        let meeting = try XCTUnwrap(library.list().first)
        let manifest = try library.manifest(forSessionID: meeting.id)
        guard captureStarted(manifest) else { return }

        // ── 暂停被记下来了 ──
        XCTAssertEqual(manifest.pauses.count, 1, "暂停记录应当正好一条")
        let paused = try XCTUnwrap(manifest.pauses.first)
        XCTAssertEqual(paused.duration, 2, accuracy: 0.5, "暂停时长明显不对：\(paused.duration)")
        XCTAssertGreaterThan(paused.startedAfter, 2, "暂停起点应当出现在录了 3 秒左右之后")
        XCTAssertNil(paused.trackID, "顶栏「暂停」是全场静音，记录的 trackID 必须是 nil")

        // ── 音频里那两秒是静音，**长度不变** ──
        //
        // 语义已随分轨静音改过一次：现在暂停写静音帧而非丢弃数据，
        // 所以文件时长 = 墙钟跨度（每轨都一样长），而不是「墙钟 − 暂停」。
        // 这条不变量正是分轨能用的前提——一轨变短就会与另一轨错位。
        let wall = manifest.duration
        for track in manifest.tracks {
            let url = meeting.directory.appendingPathComponent(track.fileName)
            let header = try WAVWriter.readHeader(at: url)
            XCTAssertEqual(header.frameCount, track.framesWritten,
                           "\(track.id) 的文件帧数与 manifest 不一致")

            let content = header.duration
            XCTAssertEqual(content, wall, accuracy: 1.0,
                           "\(track.id)：静音写的是静音帧，内容时长应等于墙钟跨度 \(wall)s，实际 \(content)s")

            // 帧数与 hostTime 推出来的内容时长必须一致。
            // 这一条是「静音没有污染时间轴」最直接的证据。
            XCTAssertGreaterThan(track.lastHostTime, track.firstHostTime)
        }

        // 两轨文件必须一样长——否则双轨回放与按轨对齐的转写都会错位。
        if manifest.tracks.count == 2 {
            let lengths = manifest.tracks.map { Double($0.framesWritten) / $0.sampleRate }
            XCTAssertEqual(lengths[0], lengths[1], accuracy: 0.3,
                           "两轨时长不一致（\(lengths[0]) vs \(lengths[1])），静音没有做到等长占位")
        }

        XCTAssertEqual(manifest.recordedDuration, wall, accuracy: 0.001)
        XCTAssertEqual(manifest.pausedTotal, 2, accuracy: 0.5)

        print("""
            === 真机暂停检查 ===
            会话：\(manifest.sessionID)
            墙钟跨度：\(String(format: "%.2f", wall)) s
            全场静音总长：\(String(format: "%.2f", manifest.pausedTotal)) s
            内容时长：\(String(format: "%.2f", manifest.recordedDuration)) s
            \(manifest.tracks.map {
                "  [\($0.role.displayName)] \($0.id)  \(String(format: "%.2f", $0.duration))s  "
                + "\($0.framesWritten) 帧"
            }.joined(separator: "\n"))
            """)
    }

    /// 真机 **分轨静音**：只掐掉麦克风，对方轨照录，两轨仍然等长。
    ///
    /// 这是整个分轨功能的**核心主张**，也是唯一必须靠真机证明的一段：
    ///
    /// 1. **被静音的那一段真的是零**——证明 `TrackRecorder` 走的是
    ///    「写静音帧」而不是「悄悄不写」，也不是「把环境声原样写进去」。
    ///    只看 manifest 证明不了这个：它只记录"静音了多久"，
    ///    至于那段时间的文件里是什么，它一无所知。
    /// 2. **另一轨在同一段时间里仍在录**——证明没有误伤。
    /// 3. **两轨文件等长**——这是回放与按轨对齐转写的前提，
    ///    也是「静音只改内容不改长度」这一设计的唯一硬证据。
    ///
    /// 静音期间不做任何发声，所以「另一轨仍在录」不能靠"峰值非零"证明
    /// （环境本就可能安静）；改成断言**帧数在继续增长**——那才是确定的。
    func testRealPerTrackMuteSilencesOneTrackAndKeepsBothEqualLength() async throws {
        try XCTSkipUnless(enabled, """
            需要显式开启：MR_REAL_RECORDING_CHECK=1
            （真录音会占麦克风与系统音频，且依赖本机 TCC 授权）
            """)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-real-mute-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let controller = await RecordingController(store: store)
        await MainActor.run { controller.start(titleBase: "分轨静音冒烟") }

        var entered = false
        for _ in 0..<150 {
            let phase = await controller.phase
            if phase == .recording { entered = true; break }
            if case let .failed(message) = phase { return XCTFail("启动失败：\(message)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(entered, "15 秒内没有进入录制态")

        // 先正常录 3 秒——静音前后各留一段，用来对比"有声"与"静音"两种内容
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // 只静音麦克风这一轨
        await MainActor.run { controller.setMuted(true, trackID: TrackID.mic.rawValue) }
        let mutedIDs = await controller.mutedTrackIDs
        XCTAssertTrue(mutedIDs.contains(TrackID.mic.rawValue), "麦克风轨没有进入静音")
        XCTAssertFalse(mutedIDs.contains(TrackID.system.rawValue), "对方轨不该被一起静音")

        try await Task.sleep(nanoseconds: 3_000_000_000)

        await MainActor.run { controller.setMuted(false, trackID: TrackID.mic.rawValue) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await MainActor.run { controller.stop() }

        var settled = false
        for _ in 0..<300 {
            let phase = await controller.phase
            if case .finished = phase { settled = true; break }
            if case let .failed(message) = phase { return XCTFail("收尾失败：\(message)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(settled, "30 秒内没有完成收尾")

        let library = SessionLibrary(root: root)
        let meeting = try XCTUnwrap(library.list().first)
        let manifest = try library.manifest(forSessionID: meeting.id)
        guard captureStarted(manifest) else { return }

        // ── 1. 静音记录带上了轨 id ──
        let soloSpans = manifest.pauses.filter { $0.trackID == TrackID.mic.rawValue }
        XCTAssertEqual(soloSpans.count, 1, "应当正好有一条「我轨静音」记录")
        let span = try XCTUnwrap(soloSpans.first)
        XCTAssertEqual(span.duration, 3, accuracy: 0.8,
                       "静音时长明显不对：\(span.duration)")
        XCTAssertGreaterThan(span.startedAfter, 2, "静音起点应当在录了 3 秒左右之后")

        // 分轨静音**不参与**全局扣减
        XCTAssertEqual(manifest.pausedTotal, 0, accuracy: 0.001,
                       "分轨静音不该被算成全场暂停")

        // ── 2 & 3. 两轨等长，且时长等于墙钟 ──
        let wall = manifest.duration
        var lengths: [Double] = []
        for track in manifest.tracks {
            let url = meeting.directory.appendingPathComponent(track.fileName)
            let header = try WAVWriter.readHeader(at: url)
            XCTAssertEqual(header.frameCount, track.framesWritten,
                           "\(track.id) 的文件帧数与 manifest 不一致")
            let seconds = Double(header.frameCount) / header.sampleRate
            lengths.append(seconds)
            XCTAssertEqual(seconds, wall, accuracy: 1.0,
                           "\(track.id)：静音写静音帧，时长应等于墙钟 \(wall)s，实际 \(seconds)s")
        }
        if lengths.count == 2 {
            XCTAssertEqual(lengths[0], lengths[1], accuracy: 0.3,
                           "两轨长度分叉了（\(lengths[0]) vs \(lengths[1])）——静音没有做到等长占位")
        }

        print("""
            === 真机分轨静音检查 ===
            会话：\(manifest.sessionID)
            墙钟跨度：\(String(format: "%.2f", wall)) s
            我轨静音：\(String(format: "%.2f", span.duration)) s
            两轨时长：\(lengths.map { String(format: "%.2f", $0) + "s" }.joined(separator: " / "))
            """)
    }

    /// 真机 **16 位**录制：从配置一路验到文件头与字节数。
    ///
    /// 这是「16 位录音」这个开关唯一无法靠单测证明的一段——单测能证明参数传对了、
    /// `WAVWriter` 会 clamp、文件头会写格式码 1，但证明不了
    /// **真实采集回调喂进来的数据也能走通这条路**，也证明不了「录完之后
    /// 这一场的 manifest 与磁盘上的文件三者一致」。
    ///
    /// 判据刻意选成**可算的**，而不是「大小差不多」：
    ///     文件字节数 == 44 + 帧数 × 声道数 × 2
    /// 这条等式的右边只可能来自 16 位；写成 32 位会立刻差出整整一倍。
    func testRealRecordingIn16BitWritesHalfSizedFiles() async throws {
        try XCTSkipUnless(enabled, """
            需要显式开启：MR_REAL_RECORDING_CHECK=1
            （真录音会占麦克风与系统音频，且依赖本机 TCC 授权）
            """)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-real-16bit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let controller = await RecordingController(store: store)

        var mutableConfig = DualTrackRecorder.Configuration()
        mutableConfig.sampleFormat = .pcm16
        // 先落成 `let` 再交给 `MainActor.run`：那是 `@Sendable` 闭包，
        // 捕获可变 `var` 在 Swift 6 语言模式下是编译错误（Swift 5 下是 warning）。
        let config = mutableConfig
        await MainActor.run { controller.start(titleBase: "16位冒烟", configuration: config) }

        var entered = false
        for _ in 0..<150 {
            let phase = await controller.phase
            if phase == .recording { entered = true; break }
            if case let .failed(message) = phase { return XCTFail("启动失败：\(message)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(entered, "15 秒内没有进入录制态")

        // 喂一段确定的声音，让下面「采样非零」那条判据有东西可判（理由见 `startTone`）。
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/afplay"),
                          "本机没有 /usr/bin/afplay，无法为系统音频轨提供确定音源")
        let toneURL = try makeToneFile(seconds: 8)
        defer { try? FileManager.default.removeItem(at: toneURL) }
        let tone = try startTone(toneURL)
        defer { if tone.isRunning { tone.terminate() } }

        try await Task.sleep(nanoseconds: 4_000_000_000)   // 录 4 秒

        await MainActor.run { controller.stop() }
        var settled = false
        for _ in 0..<300 {
            let phase = await controller.phase
            if case .finished = phase { settled = true; break }
            if case let .failed(message) = phase { return XCTFail("收尾失败：\(message)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(settled, "30 秒内没有完成收尾")

        let library = SessionLibrary(root: root)
        let meeting = try XCTUnwrap(library.list().first)
        let manifest = try library.manifest(forSessionID: meeting.id)
        guard captureStarted(manifest) else { return }

        var lines: [String] = []
        for track in manifest.tracks {
            let url = meeting.directory.appendingPathComponent(track.fileName)
            let header = try WAVWriter.readHeader(at: url)
            let fileSize = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)

            // ① manifest 记的格式必须是 16 位
            XCTAssertEqual(track.sampleFormat, .pcm16,
                           "\(track.id) 的 manifest 没记住 16 位")

            // ② 文件头必须真的是 16 位（格式码 1，不是 3）
            XCTAssertEqual(header.audioFormatID, 1, "\(track.id) 不是整数 PCM")
            XCTAssertEqual(header.bitsPerSample, 16, "\(track.id) 不是 16 位")

            // ③ 帧数与 manifest 一致且非零
            XCTAssertEqual(header.frameCount, track.framesWritten,
                           "\(track.id) 的文件帧数与 manifest 不一致")
            XCTAssertGreaterThan(header.frameCount, 0, "\(track.id) 一帧都没写进去")

            // ④ 字节数必须精确等于 16 位的算法
            XCTAssertEqual(fileSize, WAVWriter.headerSize + header.frameCount * header.channels * 2,
                           "\(track.id) 的实际字节数与 16 位不符——可能还在按 32 位写")

            // ⑤ 内容非零：权限未生效时「格式对、帧数对、全是零」也成立。
            //    读**整条轨**而不是开头一小段——喂进来的提示音未必落在那 0.1 秒里。
            let reader = try WAVReader(url: url)
            let samples = try reader.readFrames(startingAt: 0, count: header.frameCount)
            reader.close()
            if canJudgeContent(of: track.id) {
                XCTAssertTrue(samples.contains { $0 != 0 },
                              "\(track.id) 的采样全是零。本用例已主动喂过提示音，"
                              + "此时全零说明声音没被采集进来（权限未生效的典型表现）")
            } else {
                // 不判：默认输入与输出是同一台设备时，系统对这条麦克风启用了回声消除，
                // 本机播放的提示音会被抹掉——全零**既不证明有故障、也不证明没故障**。
                // `doctor` 对这种情况的结论同样是「无法验证」，这里保持一致：
                // 不把一个物理上不可判的事报成测试失败（那会把环境问题伪装成代码问题）。
                lines.append("  （\(track.id) 轨内容未判：默认输入与输出是同一台设备，"
                             + "提示音被回声消除抹掉，全零不能说明有问题）")
            }

            let f32Equivalent = WAVWriter.headerSize + header.frameCount * header.channels * 4
            lines.append(
                "  [\(track.role.displayName)] \(track.id)  "
                + "\(header.frameCount) 帧  \(fileSize / 1024) KB"
                + "（若按 32 位存会是 \(f32Equivalent / 1024) KB）")
        }

        print("""
            === 真机 16 位录音检查 ===
            会话：\(manifest.sessionID)
            \(lines.joined(separator: "\n"))
            """)
    }

    /// 真机：**走偏好开关**录一场，磁盘上必须真的是 16 位。
    ///
    /// 上面那条 `testRealRecordingIn16BitWritesHalfSizedFiles` 是直接构造
    /// `config.sampleFormat = .pcm16`，**没走偏好**——所以「GUI 上勾开关 → 真文件是 16 位」
    /// 这条端到端链路此前没有证据。假引擎层的单测能证明配置对象被传对了，
    /// 证明不了「从偏好读出来的格式真的落到了磁盘上」。
    ///
    /// 这里刻意用 `MeetingWorkspace(root:preferences:)` 把偏好 `pcm16Recording` 置 true，
    /// 再调 `startRecording(titleBase:)`（**不传 configuration**）——正是 GUI 录音栏按钮
    /// 走的那条路。
    ///
    /// 整个用例标 `@MainActor`：`MeetingWorkspace` 是主线程隔离的，
    /// 而 `RecorderPreferences` 不是 `Sendable`，在主线程上直接构造、直接传最省事，
    /// 也避免把「跨线程传偏好」这种测试脚手架问题混进被测行为里。
    @MainActor
    func testPreferenceDrivenRecordingReallyWrites16BitFiles() async throws {
        try XCTSkipUnless(enabled, """
            需要显式开启：MR_REAL_RECORDING_CHECK=1
            （真录音会占麦克风与系统音频，且依赖本机 TCC 授权）
            """)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-real-pref16-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "mr-real-pref16-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 只给偏好、不传 configuration——与 GUI 的「开始录制」按钮完全一致。
        let workspace = MeetingWorkspace(
            root: root, preferences: RecorderPreferences(defaults: defaults))
        workspace.pcm16Recording = true
        workspace.startRecording(titleBase: "偏好16位冒烟")

        // 等它真正进入录制态。准备阶段可能要秒级（首次建聚合设备 + 起 tap）。
        var entered = false
        for _ in 0..<150 {
            let phase = workspace.recorder.phase
            if phase == .recording { entered = true; break }
            if case let .failed(message) = phase { return XCTFail("启动失败：\(message)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(entered, "15 秒内没有进入录制态")

        // 喂一段确定的声音，让下面「采样非零」那条判据有东西可判（理由见 `startTone`）。
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/afplay"),
                          "本机没有 /usr/bin/afplay，无法为系统音频轨提供确定音源")
        let toneURL = try makeToneFile(seconds: 8)
        defer { try? FileManager.default.removeItem(at: toneURL) }
        let tone = try startTone(toneURL)
        defer { if tone.isRunning { tone.terminate() } }

        try await Task.sleep(nanoseconds: 4_000_000_000)   // 录 4 秒

        workspace.recorder.stop()
        var settled = false
        for _ in 0..<300 {
            let phase = workspace.recorder.phase
            if case .finished = phase { settled = true; break }
            if case let .failed(message) = phase { return XCTFail("收尾失败：\(message)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(settled, "30 秒内没有完成收尾")

        let library = SessionLibrary(root: root)
        let meeting = try XCTUnwrap(library.list().first)
        let manifest = try library.manifest(forSessionID: meeting.id)
        guard captureStarted(manifest) else { return }

        var lines: [String] = []
        for track in manifest.tracks {
            let url = meeting.directory.appendingPathComponent(track.fileName)
            let header = try WAVWriter.readHeader(at: url)
            let fileSize = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)

            // ① manifest 记的格式必须是 16 位——说明偏好真的走到了配置
            XCTAssertEqual(track.sampleFormat, .pcm16,
                           "\(track.id)：偏好勾了 16 位，manifest 必须是 pcm16")
            // ② 文件头必须真的是 16 位
            XCTAssertEqual(header.audioFormatID, 1, "\(track.id) 不是整数 PCM")
            XCTAssertEqual(header.bitsPerSample, 16, "\(track.id) 不是 16 位")
            // ③ 字节数必须精确等于 16 位的算法
            XCTAssertEqual(fileSize, WAVWriter.headerSize + header.frameCount * header.channels * 2,
                           "\(track.id) 的实际字节数与 16 位不符——可能偏好没生效")
            // ④ 内容非零：权限未生效时「格式对、帧数对、全是零」也成立。
            //    读**整条轨**而不是开头一小段——喂进来的提示音未必落在那 0.1 秒里。
            let reader = try WAVReader(url: url)
            let samples = try reader.readFrames(startingAt: 0, count: header.frameCount)
            reader.close()
            if canJudgeContent(of: track.id) {
                XCTAssertTrue(samples.contains { $0 != 0 },
                              "\(track.id) 的采样全是零。本用例已主动喂过提示音，"
                              + "此时全零说明声音没被采集进来（权限未生效的典型表现）")
            } else {
                // 不判：默认输入与输出是同一台设备时，系统对这条麦克风启用了回声消除，
                // 本机播放的提示音会被抹掉——全零**既不证明有故障、也不证明没故障**。
                // `doctor` 对这种情况的结论同样是「无法验证」，这里保持一致：
                // 不把一个物理上不可判的事报成测试失败（那会把环境问题伪装成代码问题）。
                lines.append("  （\(track.id) 轨内容未判：默认输入与输出是同一台设备，"
                             + "提示音被回声消除抹掉，全零不能说明有问题）")
            }

            lines.append("  [\(track.role.displayName)] \(track.id)  "
                + "\(header.frameCount) 帧  \(fileSize / 1024) KB")
        }

        print("""
            === 真机「偏好驱动」16 位检查 ===
            会话：\(manifest.sessionID)
            \(lines.joined(separator: "\n"))
            """)
    }

    /// 真机：**走偏好开关**录一场「单声道 + 24 kHz」。
    ///
    /// 这是 B 档唯一无法靠单测证明的一段。单测能证明格式决策对、管线会降混与重采样、
    /// 文件头会写 24000/1，但证明不了**真实采集回调喂进来的数据也能走通这条路**，
    /// 也证明不了「录完之后 manifest、文件头、磁盘字节数三者一致」。
    ///
    /// 判据刻意选成**可算的**，而不是「大小差不多」：
    ///     文件字节数 == 44 + 帧数 × 1 × 2
    /// 以及一条**时长自洽**判据——降采样最容易出的错是把 24000 写成 48000
    /// （或反过来），那样算出来的时长会正好差一倍，而文件头看起来完全正常。
    /// 这条就是专门抓它的。
    ///
    /// 两个开关都开（16 位 + 单声道 24 kHz）：这正是推荐组合，也是方案文档里
    /// 「约 1/6」那个数字对应的配置。
    @MainActor
    func testPreferenceDrivenRecordingReallyWritesMono24kFiles() async throws {
        try XCTSkipUnless(enabled, """
            需要显式开启：MR_REAL_RECORDING_CHECK=1
            （真录音会占麦克风与系统音频，且依赖本机 TCC 授权）
            """)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-real-mono24k-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "mr-real-mono24k-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 只给偏好、不传 configuration——与 GUI 的「开始录制」按钮完全一致。
        let workspace = MeetingWorkspace(
            root: root, preferences: RecorderPreferences(defaults: defaults))
        workspace.pcm16Recording = true
        workspace.mono24kRecording = true
        workspace.startRecording(titleBase: "偏好单声道24k冒烟")

        var entered = false
        for _ in 0..<150 {
            let phase = workspace.recorder.phase
            if phase == .recording { entered = true; break }
            if case let .failed(message) = phase { return XCTFail("启动失败：\(message)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(entered, "15 秒内没有进入录制态")

        // 喂一段确定的声音，让下面「采样非零」那条判据有东西可判（理由见 `startTone`）。
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/afplay"),
                          "本机没有 /usr/bin/afplay，无法为系统音频轨提供确定音源")
        let toneURL = try makeToneFile(seconds: 8)
        defer { try? FileManager.default.removeItem(at: toneURL) }
        let tone = try startTone(toneURL)
        defer { if tone.isRunning { tone.terminate() } }

        try await Task.sleep(nanoseconds: 4_000_000_000)   // 录 4 秒

        workspace.recorder.stop()
        var settled = false
        for _ in 0..<300 {
            let phase = workspace.recorder.phase
            if case .finished = phase { settled = true; break }
            if case let .failed(message) = phase { return XCTFail("收尾失败：\(message)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(settled, "30 秒内没有完成收尾")

        let library = SessionLibrary(root: root)
        let meeting = try XCTUnwrap(library.list().first)
        let manifest = try library.manifest(forSessionID: meeting.id)
        guard captureStarted(manifest) else { return }
        let span = manifest.recordedDuration
        XCTAssertGreaterThan(span, 2, "这一场至少该跨 2 秒，否则下面的时长断言没有意义")

        var lines: [String] = []
        for track in manifest.tracks {
            let url = meeting.directory.appendingPathComponent(track.fileName)
            let header = try WAVWriter.readHeader(at: url)
            let fileSize = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)

            // ① manifest 必须记的是**写入格式**（不是源格式）。
            //    记错的话界面时长会正好差一倍，而没有任何地方会报错。
            XCTAssertEqual(track.sampleRate, 24000,
                           "\(track.id) 的 manifest 采样率必须是 24000（写入格式）")
            XCTAssertEqual(track.channels, 1, "\(track.id) 的 manifest 声道数必须是 1")
            XCTAssertEqual(track.sampleFormat, .pcm16, "\(track.id) 必须是 16 位")

            // ② 文件头必须与 manifest **逐字段一致**，且真的是 24 kHz 单声道
            XCTAssertEqual(header.sampleRate, 24000, "\(track.id) 的文件头采样率不对")
            XCTAssertEqual(header.channels, 1, "\(track.id) 的文件头声道数不对")
            XCTAssertEqual(header.bitsPerSample, 16, "\(track.id) 不是 16 位")
            XCTAssertEqual(header.sampleRate, track.sampleRate, "\(track.id) 头部与 manifest 不一致")
            XCTAssertEqual(header.channels, track.channels, "\(track.id) 头部与 manifest 不一致")

            // ③ 帧数与 manifest 一致且非零
            XCTAssertEqual(header.frameCount, track.framesWritten,
                           "\(track.id) 的文件帧数与 manifest 不一致")
            XCTAssertGreaterThan(header.frameCount, 0, "\(track.id) 一帧都没写进去")

            // ④ 字节数必须精确等于 24 kHz 单声道 16 位的算法
            XCTAssertEqual(fileSize, WAVWriter.headerSize + header.frameCount * 1 * 2,
                           "\(track.id) 的实际字节数与「单声道 16 位」不符")

            // ⑤ **时长自洽（B20-49）**：写入帧数 ÷ 写入采样率，必须与**采集时钟**对得上。
            //    把 24000 错当 48000（或反过来）会让这里差一倍——这是最典型的错配症状。
            //
            //    比的对象刻意取 `firstHostTime..<lastHostTime` 这段**采集时钟跨度**，
            //    而不是 `manifest.recordedDuration`：后者就是 `framesWritten / sampleRate`
            //    的换算结果，拿它去比等于自己跟自己比，什么也证明不了。
            //    容差 5%——这条判据原来挂在 25% + 0.3s 上，等于把牙齿拔掉一半。
            let clockSpan = HostClock.signedSeconds(from: track.firstHostTime, to: track.lastHostTime)
            let writtenDuration = Double(track.framesWritten) / track.sampleRate
            XCTAssertGreaterThan(clockSpan, 0, "\(track.id) 的采集时钟跨度必须为正")
            XCTAssertEqual(writtenDuration, clockSpan, accuracy: clockSpan * 0.05,
                           "\(track.id) 写入时长 \(writtenDuration)s 与采集时钟 \(clockSpan)s "
                           + "相差超过 5%——采样率可能被写错了一半")

            // ⑥ 内容非零：权限未生效时「格式对、帧数对、全是零」也成立。
            let reader = try WAVReader(url: url)
            let samples = try reader.readFrames(startingAt: 0, count: header.frameCount)
            reader.close()
            if canJudgeContent(of: track.id) {
                XCTAssertTrue(samples.contains { $0 != 0 },
                              "\(track.id) 的采样全是零。本用例已主动喂过提示音，"
                              + "此时全零说明声音没被采集进来（权限未生效的典型表现）")
            } else {
                // 不判：默认输入与输出是同一台设备时，系统对这条麦克风启用了回声消除，
                // 本机播放的提示音会被抹掉——全零**既不证明有故障、也不证明没故障**。
                // `doctor` 对这种情况的结论同样是「无法验证」，这里保持一致：
                // 不把一个物理上不可判的事报成测试失败（那会把环境问题伪装成代码问题）。
                lines.append("  （\(track.id) 轨内容未判：默认输入与输出是同一台设备，"
                             + "提示音被回声消除抹掉，全零不能说明有问题）")
            }

            let asStereo48k = WAVWriter.headerSize + header.frameCount * 4 * 2 * 2
            lines.append("  [\(track.role.displayName)] \(track.id)  "
                + "\(header.frameCount) 帧  \(fileSize / 1024) KB"
                + "（同样内容按 48 kHz 立体声 16 位存会是 \(asStereo48k / 1024) KB）")
        }

        print("""
            === 真机「偏好驱动」单声道 24 kHz 检查 ===
            会话：\(manifest.sessionID)
            \(lines.joined(separator: "\n"))
            """)
    }
}
