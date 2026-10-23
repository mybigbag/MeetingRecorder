import XCTest
@testable import MRTranscribe
@testable import MRCore

/// 子进程桥接。
///
/// 这里分两类：
/// - **真跑进程**的（`/bin/echo`、`/bin/sh`、`/bin/sleep`）：假对象证明不了
///   「管道读法写对了没有」。子进程封装最容易踩的坑（管道写满死锁、父子互等）
///   只在真进程上出现。
/// - **假 runner** 的：验参数拼装、退出码判定、SRT 映射、诊断提取，
///   这些用假对象才能穷举边界。
final class SenseVoiceProcessRunnerTests: XCTestCase {

    private var fixture: SenseVoiceFixture!

    override func setUpWithError() throws {
        fixture = .make()
    }

    override func tearDownWithError() throws {
        fixture.cleanup()
        fixture = nil
    }

    // MARK: - 真进程

    /// R08：stdout 被正确捕获，退出码被如实返回。
    func testRealProcessCapturesStdoutAndExitCode() async throws {
        let runner = SenseVoiceProcessRunner()

        let ok = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello-sensevoice"])
        XCTAssertEqual(ok.exitCode, 0)
        XCTAssertEqual(ok.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                       "hello-sensevoice")

        let failed = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"])
        XCTAssertEqual(failed.exitCode, 3, "退出码必须如实返回，不能一律折算成 0/1")
        XCTAssertFalse(failed.terminatedBySignal)
    }

    /// R09：**大输出不得死锁**。
    ///
    /// 管道内核缓冲约 64 KiB。子进程写满就阻塞在 `write`，父进程若在 `waitUntilExit`
    /// 上等它结束，双方互等、永不返回。一场长会议的 SRT 完全可能超过 64 KiB。
    /// 这条用例的意义就是「跑完」——超时即失败。
    func testRealProcessDoesNotDeadlockOnLargeOutput() async throws {
        let runner = SenseVoiceProcessRunner()
        let script = "yes sensevoice-padding-line | head -c 300000"
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(result.standardOutput.utf8.count, 200_000,
                             "输出被截断说明读法有问题")
    }

    /// R10：stdout 与 stderr **都要**读全。
    /// 只读一个管道、另一个不读，正是上面那个死锁的经典触发方式。
    func testRealProcessCapturesBothStreams() async throws {
        let runner = SenseVoiceProcessRunner()
        let script = "yes out-line | head -c 150000; yes err-line | head -c 150000 1>&2"
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])

        XCTAssertGreaterThan(result.standardOutput.utf8.count, 100_000, "stdout 不完整")
        XCTAssertGreaterThan(result.standardError.utf8.count, 100_000, "stderr 不完整")
    }

    /// R11：取消要能**及时**终止进程，不留孤儿。
    ///
    /// 孤儿进程会把 CPU 吃满直到自己跑完，用户看到的是「取消之后风扇还在转」。
    func testCancellationTerminatesProcessPromptly() async throws {
        let runner = SenseVoiceProcessRunner()
        let started = Date()

        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        }
        // 给它一点时间真正启动（否则测的是「还没启动就取消」，那是另一条分支）
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("被取消的调用必须抛错")
        } catch {
            // CancellationError 或任何错误都可接受；关键是**时间**
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 5, "取消后应在数秒内返回，实际 \(elapsed) 秒")
    }

    /// R12 / R13：可执行文件不存在 → 明确报错，而不是静默成功。
    func testMissingOrNonExecutableBinaryThrows() async throws {
        let runner = SenseVoiceProcessRunner()

        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/tmp/definitely-missing-\(UUID().uuidString)"),
                arguments: [])
            XCTFail("不存在的可执行文件必须抛错")
        } catch let error as MRError {
            XCTAssertTrue("\(error)".contains("不可用"), "错误信息应说明运行时不可用：\(error)")
        }

        // 存在但没有可执行位
        let plain = fixture.base.appendingPathComponent("plain-file")
        try TestFiles.makeFile(at: plain, bytes: 32, executable: false)
        do {
            _ = try await runner.run(executable: plain, arguments: [])
            XCTFail("没有可执行权限的文件必须抛错")
        } catch let error as MRError {
            XCTAssertTrue("\(error)".contains("不可执行"), "应指出是权限问题：\(error)")
        }
    }

    // MARK: - 假 runner：参数与映射

    /// R06 / R07：参数完整、顺序正确、**全部是绝对路径**。
    /// 子进程的工作目录不由我们决定，相对路径会解析到别的地方去。
    func testArgumentsAreCompleteAndAbsolute() async throws {
        try fixture.installEverything()
        fixture.runner.result = SenseVoiceProcessResult(
            standardOutput: "1\n00:00:01,000 --> 00:00:02,000\n你好\n",
            standardError: "", exitCode: 0)

        let audio = fixture.base.appendingPathComponent("audio/mic.wav")
        try TestFiles.makeFile(at: audio, bytes: 1024)
        _ = try await fixture.makeInference().transcribe(
            fileURL: audio, trackID: "mic", speaker: "我")

        let arguments = try XCTUnwrap(fixture.runner.lastArguments)
        XCTAssertTrue(arguments.contains("-srt") || arguments.contains("--srt"))
        XCTAssertTrue(arguments.contains("-a"))
        XCTAssertTrue(arguments.contains("--vad"))
        XCTAssertTrue(arguments.contains("-m"))
        XCTAssertFalse(arguments.contains("--keep-tags"), "标签必须由运行时剥掉，不能在稿子里出现")
        XCTAssertFalse(arguments.contains("--ids"))

        let modelIndex = try XCTUnwrap(arguments.firstIndex(of: "-m"))
        XCTAssertEqual(arguments[modelIndex + 1], fixture.paths.url(for: SenseVoiceAssets.model).path)
        let vadIndex = try XCTUnwrap(arguments.firstIndex(of: "--vad"))
        XCTAssertEqual(arguments[vadIndex + 1], fixture.paths.url(for: SenseVoiceAssets.vad).path)
        let audioIndex = try XCTUnwrap(arguments.firstIndex(of: "-a"))
        XCTAssertEqual(arguments[audioIndex + 1], audio.path)

        for path in [arguments[modelIndex + 1], arguments[vadIndex + 1], arguments[audioIndex + 1]] {
            XCTAssertTrue(path.hasPrefix("/"), "必须是绝对路径：\(path)")
        }
        XCTAssertEqual(fixture.runner.invocations.first?.executable.path,
                       fixture.paths.installedRuntimeURL.path)
    }

    /// R01：正常返回 → 段落映射正确，track / speaker 透传。
    func testMapsCaptionsToSegments() async throws {
        try fixture.installEverything()
        fixture.runner.result = SenseVoiceProcessResult(
            standardOutput: """
            1
            00:00:01,500 --> 00:00:03,000
            第一句话。

            2
            00:00:04,000 --> 00:00:06,250
            第二句话。

            """,
            standardError: "[sensevoice] 2 vad segments\n[sensevoice] done 0.42s\n",
            exitCode: 0)

        let outcome = try await fixture.makeInference().transcribe(
            fileURL: fixture.base.appendingPathComponent("a.wav"),
            trackID: "system", speaker: "对方")

        XCTAssertEqual(outcome.segments.count, 2)
        XCTAssertEqual(outcome.segments[0].text, "第一句话。")
        XCTAssertEqual(outcome.segments[0].start, 1.5, accuracy: 0.0001)
        XCTAssertEqual(outcome.segments[0].end, 3.0, accuracy: 0.0001)
        XCTAssertEqual(outcome.segments[0].track, "system")
        XCTAssertEqual(outcome.segments[0].speaker, "对方")

        // 诊断信息要被提取出来（VAD 段数 + 耗时），否则「少了几条」只能靠猜
        XCTAssertTrue(outcome.notes.contains { $0.contains("VAD 切出 2 段") },
                      "应报出 VAD 段数：\(outcome.notes)")
        XCTAssertTrue(outcome.notes.contains { $0.contains("0.42") },
                      "应报出耗时：\(outcome.notes)")
    }

    /// R02：退出码 0 + 空输出 = **确实没有语音**，不是失败。
    ///
    /// 真机实测：整段静音时运行时就是 exit 0 + 0 字节。
    /// 把这两种情况混为一谈，一场安静的会议会被显示成「转写失败」。
    func testEmptyOutputWithZeroExitIsNotAnError() async throws {
        try fixture.installEverything()
        fixture.runner.result = SenseVoiceProcessResult(
            standardOutput: "", standardError: "[sensevoice] 0 vad segments\n", exitCode: 0)

        let outcome = try await fixture.makeInference().transcribe(
            fileURL: fixture.base.appendingPathComponent("silent.wav"),
            trackID: "mic", speaker: "我")
        XCTAssertTrue(outcome.segments.isEmpty)
    }

    /// R03 / R04：退出码非 0 → 抛错，并把 runtime 的诊断**尾部**带出来。
    ///
    /// 取尾部而不是头部：运行时按「加载模型 → VAD → 构图 → 计算」顺序打日志，
    /// 真正失败的那一步永远是最后一条。
    func testNonZeroExitSurfacesTailOfStderr() async throws {
        try fixture.installEverything()
        fixture.runner.result = SenseVoiceProcessResult(
            standardOutput: "",
            standardError: "stage 1\nstage 2\naudio: failed to open/decode /x.wav\nread audio failed\n",
            exitCode: 1)

        do {
            _ = try await fixture.makeInference().transcribe(
                fileURL: fixture.base.appendingPathComponent("x.wav"),
                trackID: "mic", speaker: "我")
            XCTFail("退出码非 0 必须抛错")
        } catch let error as MRError {
            let text = "\(error)"
            XCTAssertTrue(text.contains("read audio failed"), "应带出 stderr 尾部：\(text)")
            XCTAssertTrue(text.contains("1"), "应报出退出码：\(text)")
        }

        // stderr 为空也要给出可判断的错误，不能抛一条什么都没有的错
        fixture.runner.result = SenseVoiceProcessResult(
            standardOutput: "", standardError: "", exitCode: 137)
        do {
            _ = try await fixture.makeInference().transcribe(
                fileURL: fixture.base.appendingPathComponent("x.wav"),
                trackID: "mic", speaker: "我")
            XCTFail("退出码非 0 必须抛错")
        } catch let error as MRError {
            XCTAssertTrue("\(error)".contains("137"), "无诊断信息时至少要带退出码：\(error)")
            XCTAssertTrue("\(error)".contains("没有输出诊断信息"), "应说明没有诊断信息")
        }
    }

    /// R05：stdout 是垃圾（不是 SRT）→ 不崩，产出 0 段并把畸形数量作为诊断报出。
    func testGarbageOutputDoesNotCrashAndReportsMalformedBlocks() async throws {
        try fixture.installEverything()
        fixture.runner.result = SenseVoiceProcessResult(
            standardOutput: "<html><body>502 Bad Gateway</body></html>\n\n随便一段文字\n",
            standardError: "", exitCode: 0)

        let outcome = try await fixture.makeInference().transcribe(
            fileURL: fixture.base.appendingPathComponent("a.wav"),
            trackID: "mic", speaker: "我")
        XCTAssertTrue(outcome.segments.isEmpty)
        XCTAssertTrue(outcome.notes.contains { $0.contains("无法解析的字幕块") },
                      "畸形块数量必须被报出来：\(outcome.notes)")
    }

    /// 悬浮的 `.part` 之类不该出现在诊断里；诊断只报真实发生的事。
    func testDiagnosticsStayEmptyOnCleanRun() async throws {
        try fixture.installEverything()
        fixture.runner.result = SenseVoiceProcessResult(
            standardOutput: "1\n00:00:01,000 --> 00:00:02,000\n干净的一行\n",
            standardError: "[sensevoice] 1 vad segments\n", exitCode: 0)

        let outcome = try await fixture.makeInference().transcribe(
            fileURL: fixture.base.appendingPathComponent("a.wav"),
            trackID: "mic", speaker: "我")
        XCTAssertFalse(outcome.notes.contains { $0.contains("丢弃") })
        XCTAssertFalse(outcome.notes.contains { $0.contains("畸形") })
        XCTAssertFalse(outcome.notes.contains { $0.contains("可疑短段") })
    }

    // MARK: - 近静音幻觉的如实告知

    /// 某轨**只**产出极短文本时，必须多一条把成因讲清楚的注记。
    ///
    /// 输入照抄 2026-09-29 那场 70 秒无语音录音的真机产物：`He.` / `い。` / `一。` 三条。
    /// 关键行为有两个：**一条都不删**（删错会丢真话，见 `SenseVoiceCaptionFilter`），
    /// 但**必须说出来**——否则用户看到这几行只会以为软件坏了，或者以为这就是录音内容。
    func testShortOnlyTrackGetsAnExplainingNote() async throws {
        try fixture.installEverything()
        fixture.runner.result = SenseVoiceProcessResult(
            standardOutput: [
                "1", "00:00:02,510 --> 00:00:03,140", "He.", "",
                "2", "00:00:37,990 --> 00:00:38,560", "い。", "",
                "3", "00:01:05,090 --> 00:01:05,610", "一。", "",
            ].joined(separator: "\n"),
            standardError: "[sensevoice] 4 vad segments\n", exitCode: 0)

        let outcome = try await fixture.makeInference().transcribe(
            fileURL: fixture.base.appendingPathComponent("a.wav"),
            trackID: "mic", speaker: "我")

        XCTAssertEqual(outcome.segments.count, 3, "极短段落仍然保留——清洗层一条都不删")
        XCTAssertTrue(outcome.notes.contains { $0.contains("没有任何成句内容") },
                      "必须如实描述「只有极短文本」：\(outcome.notes)")
        XCTAssertTrue(outcome.notes.contains { $0.contains("幻觉") },
                      "必须把已知成因讲出来：\(outcome.notes)")
        XCTAssertTrue(outcome.notes.contains { $0.contains("3 条") },
                      "注记里要带条数：\(outcome.notes)")
    }

    /// 反面：真实会议里短句一大堆，但只要有成句内容，就不该套那条提示。
    ///
    /// 少了这条，一个「只要看到短段就喊幻觉」的实现也能让上面那条绿——
    /// 而那会把一场正常会议的诊断区刷满噪声，久了没人再看它。
    func testTrackWithSentenceLevelContentGetsNoShortOnlyNote() async throws {
        try fixture.installEverything()
        fixture.runner.result = SenseVoiceProcessResult(
            standardOutput: [
                "1", "00:00:00,000 --> 00:00:30,000",
                "主要还是在做那个表单用例的分析，然后把现有的文档做一次补充。", "",
                "2", "00:00:37,390 --> 00:00:38,490", "好。", "",
            ].joined(separator: "\n"),
            standardError: "[sensevoice] 2 vad segments\n", exitCode: 0)

        let outcome = try await fixture.makeInference().transcribe(
            fileURL: fixture.base.appendingPathComponent("a.wav"),
            trackID: "mic", speaker: "我")

        XCTAssertEqual(outcome.segments.count, 2)
        XCTAssertTrue(outcome.notes.contains { $0.contains("可疑短段 1 条") },
                      "短段仍然要计数：\(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains { $0.contains("没有任何成句内容") },
                       "有成句内容就不该说「没有任何成句内容」：\(outcome.notes)")
    }

    /// 纯函数层面把边界钉死：**必须在两侧都立得住**。
    func testShortOnlyNoteBoundaries() {
        func note(_ kept: Int, _ short: Int) -> String? {
            SenseVoiceInference.shortOnlyNote(kept: kept, short: short)
        }
        XCTAssertNil(note(0, 0), "一条都没有时不该说「只检出 0 条」")
        XCTAssertNil(note(137, 37), "有成句内容的正常轨")
        XCTAssertNil(note(1, 0), "长句不算短段")
        XCTAssertNotNil(note(1, 1))
        XCTAssertNotNil(note(3, 3))
    }

    // MARK: - 输出文件的读取

    /// 空文件读出来是空串——**这条是「静音 = 没语音」判据的地基**。
    func testReadingEmptyOutputYieldsEmptyString() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-read-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(try SenseVoiceProcessRunner.readOutput(at: file, label: "stdout"), "")
    }

    /// 文件不见了 → **抛错**，不能当成「没有输出」。
    ///
    /// 本模块有一条判据：「退出码 0 + 空输出 = 这段确实没语音」（整段静音时运行时
    /// 就是这样收场的）。若这里用 `(try? …) ?? ""` 把读失败也变成空串，
    /// 那么「输出文件被外部清掉」「权限不对」这类**真实故障**会全部伪装成
    /// 「没人说话」——用户得到一份空稿，还会以为会议确实很安静。
    func testMissingOutputFileRaisesInsteadOfLookingLikeSilence() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-missing-\(UUID().uuidString)")

        XCTAssertThrowsError(try SenseVoiceProcessRunner.readOutput(at: missing, label: "stdout")) {
            error in
            XCTAssertTrue("\(error)".contains("stdout"), "应指明是哪一路输出：\(error)")
            XCTAssertTrue("\(error)".contains("不见了"), "应说清是文件不见了：\(error)")
        }
    }

    /// 路径上是个目录（读取必然失败）→ 同样要抛错，而不是悄悄给一个空串。
    func testUnreadableOutputPathRaises() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try SenseVoiceProcessRunner.readOutput(at: directory, label: "stderr")) {
            error in
            XCTAssertTrue("\(error)".contains("stderr"), "应指明是哪一路输出：\(error)")
        }
    }

    /// 非法 UTF-8 字节要**容错解码**，不能抛错。
    ///
    /// 输出被截断在半个多字节字符上是可能的；那时我们要的是「确实拿到了内容」
    /// 这个事实（于是不会被读成「没语音」），而不是因为一个替换字符
    /// 就把一次成功的转写判成失败。
    func testInvalidUTF8IsDecodedLossilyRatherThanFailing() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-bytes-\(UUID().uuidString)")
        // 一个孤立的 UTF-8 续字节 + 正常文本
        try Data([0x80, 0xE4, 0xB8, 0xAD]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let text = try SenseVoiceProcessRunner.readOutput(at: file, label: "stdout")
        XCTAssertFalse(text.isEmpty, "拿到字节就得算「有输出」，不能被读成「这段没语音」")
        XCTAssertTrue(text.contains("中"), "可解码的部分要保留：\(text)")
    }
}
