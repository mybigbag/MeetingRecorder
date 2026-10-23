import XCTest
@testable import MRTranscribe
@testable import MRCore

/// 引擎层：**资产门槛**与错误信息。
///
/// 这一层守的规矩只有一条，但它比其它都重要：**未就绪时必须在写任何文件之前失败**。
/// 逐轨转写是「单轨失败不中断」的，所以一个安静的降级会表现为
/// 「每轨各失败一次 → 留下一份空稿 → 退出码 0」，也就是把「引擎坏了」说成
/// 「这场没人说话」。错误信息还必须**可照抄执行**——否则用户知道错了也不知道做什么。
final class SenseVoiceEngineTests: XCTestCase {

    private var fixture: SenseVoiceFixture!

    override func setUpWithError() throws {
        fixture = .make()
    }

    override func tearDownWithError() throws {
        fixture.cleanup()
        fixture = nil
    }

    private func sampleSRT() -> String {
        """
        1
        00:00:01,000 --> 00:00:03,000
        会议开始。

        2
        00:00:04,000 --> 00:00:06,000
        讨论一下排期。

        """
    }

    // MARK: - E01 / E02 / E03 / E04：门槛

    /// E01：什么都没有 → 抛错，且信息里**给出可照抄的命令**与体积量级。
    func testPrepareFailsWithActionableMessageWhenNothingInstalled() async throws {
        do {
            try await fixture.makeEngine().prepare()
            XCTFail("资产缺失时 prepare 必须抛错")
        } catch let error as MRError {
            guard case .transcription = error else {
                return XCTFail("应抛 .transcription，实际：\(error)")
            }
            let text = "\(error)"
            XCTAssertTrue(text.contains("model download"), "应给出下载命令：\(text)")
            XCTAssertTrue(text.contains("install-runtime"), "应给出运行时安装命令：\(text)")
            XCTAssertTrue(text.contains("244"), "应给出下载体积量级：\(text)")
            XCTAssertTrue(text.contains(fixture.paths.baseDirectory.path), "应给出落点路径：\(text)")
        }
    }

    /// E02：资产齐全 → 门槛通过。
    func testPrepareSucceedsWhenAssetsAreReady() async throws {
        try fixture.installEverything()
        try await fixture.makeEngine().prepare()
    }

    /// E03：**只缺运行时** → 错误必须指向 `install-runtime`。
    ///
    /// 两者修复动作完全不同（一个要下 244 MiB，一个通常只要从本地拷 2.9 MiB）。
    /// 一律说成「模型没下」会让用户白等一次下载。
    func testPrepareDistinguishesMissingRuntimeFromMissingModel() async throws {
        try fixture.installModels()

        do {
            try await fixture.makeEngine().prepare()
            XCTFail("缺运行时必须抛错")
        } catch let error as MRError {
            let text = "\(error)"
            XCTAssertTrue(text.contains("install-runtime"), "应指向 install-runtime：\(text)")
            XCTAssertTrue(text.contains("推理运行时"), "应指名是运行时：\(text)")
            XCTAssertFalse(text.contains("model download"),
                           "模型已就绪时不该再让人去下载模型：\(text)")
        }
    }

    /// E04：字节数不符（截断）→ 抛错且说清期望 / 实际字节数。
    /// 文件在、但坏了，与「文件不在」是两种不同的修复动作（重下 vs 下载），要能区分。
    func testPrepareDetectsTruncatedAsset() async throws {
        try fixture.installModels()
        try fixture.installRuntime()
        // 把权重截断
        try TestFiles.makeFile(
            at: fixture.paths.url(for: SenseVoiceAssets.model), bytes: 1024)

        let state = fixture.makeEngine().installState
        guard case let .sizeMismatch(expected, actual) = state.status(of: .model) else {
            return XCTFail("应报 sizeMismatch，实际：\(state.status(of: .model))")
        }
        XCTAssertEqual(expected, SenseVoiceAssets.model.byteCount)
        XCTAssertEqual(actual, 1024)

        do {
            try await fixture.makeEngine().prepare()
            XCTFail("字节数不符时 prepare 必须抛错")
        } catch let error as MRError {
            XCTAssertTrue("\(error)".contains("字节数不符"),
                          "应说明是字节数问题（与下载器的同类错误统一叫法）：\(error)")
        }
    }

    /// **运行时的门槛是「存在 + 可执行」，不是字节数。**
    ///
    /// 反过来说的代价很大：`model install-runtime --from <自建件>` 是文档与帮助文本
    /// 明确承诺的能力（MIT 也允许重编译），字节数门槛会让它**永远**装不上——
    /// `prepare()` 一律拒绝，而且 `status` 会把用户引回 `install-runtime`，
    /// 不带 `--from` 时又用官方副本静默覆盖掉自建件。
    ///
    /// 这条用例是那次「承诺 vs 门槛」矛盾的回归闸门。
    func testPrepareAcceptsSelfBuiltRuntimeWithForeignByteCount() async throws {
        try fixture.installModels()
        try fixture.installSelfBuiltRuntime(bytes: 128)

        let engine = fixture.makeEngine()
        let state = engine.installState
        XCTAssertEqual(state.status(of: .runtime), .ready,
                       "可执行就该算就绪，字节数不该是运行时的门槛")
        XCTAssertTrue(state.isReady)
        XCTAssertEqual(state.runtimeBinaryURL?.path, fixture.paths.installedRuntimeURL.path)

        // 门槛真的放行（这一步以前会抛「字节数不符」）
        try await engine.prepare()
    }

    /// 运行时文件在、但丢了可执行位 → 状态要说得准确（修复动作是 `chmod`，
    /// 既不是「下载」也不是「重下」），`prepare()` 仍必须拒绝。
    func testRuntimePresentButNotExecutableIsReportedAsSuch() async throws {
        try fixture.installModels()
        try TestFiles.makeFile(
            at: fixture.paths.installedRuntimeURL,
            bytes: SenseVoiceAssets.runtime.byteCount,
            executable: false)

        let engine = fixture.makeEngine()
        XCTAssertEqual(engine.installState.status(of: .runtime), .notExecutable)
        XCTAssertFalse(engine.installState.isReady)
        XCTAssertNil(engine.runtimeBinaryURL, "不可执行的文件不该被解析成可用运行时")

        do {
            try await engine.prepare()
            XCTFail("运行时不可执行时必须抛错")
        } catch let error as MRError {
            let text = "\(error)"
            XCTAssertTrue(text.contains("不可执行"), "应说清是不可执行：\(text)")
            XCTAssertTrue(text.contains("install-runtime"), "应给出修复命令：\(text)")
        }
    }

    /// E12：运行时解析不到时，错误信息指向 `install-runtime` 而不是泛泛的「未就绪」。
    func testPrepareMentionsRuntimeInstallWhenBinaryUnresolvable() async throws {
        try fixture.installModels()
        XCTAssertNil(fixture.makeEngine().runtimeBinaryURL)
        do {
            try await fixture.makeEngine().prepare()
            XCTFail("解析不到运行时必须抛错")
        } catch let error as MRError {
            XCTAssertTrue("\(error)".contains("install-runtime"))
        }
    }

    // MARK: - E05 / E06：转写

    /// E05：资产缺失时 `transcribe` **抛错**，绝不返回空数组或伪造段落。
    ///
    /// 这是原有骨架用例的意义所在：如果哪天有人为了「让它跑起来」把缺资产的路径
    /// 改成返回 `[]`，这里会立刻变红。
    func testTranscribeThrowsRatherThanFakingWhenAssetsMissing() async throws {
        do {
            _ = try await fixture.makeEngine().transcribe(
                fileURL: URL(fileURLWithPath: "/tmp/does-not-exist.wav"),
                trackID: "mic", speaker: "我")
            XCTFail("资产缺失时 transcribe 必须抛错，绝不能返回伪造文稿")
        } catch let error as MRError {
            guard case .transcription = error else {
                return XCTFail("应抛 .transcription，实际：\(error)")
            }
        }
        XCTAssertTrue(fixture.runner.invocations.isEmpty,
                      "资产没就绪就不该去启动子进程")
    }

    /// E06：资产齐全 → 走子进程，段落正确，track / speaker 透传。
    func testTranscribeProducesSegmentsWhenReady() async throws {
        try fixture.installEverything()
        fixture.runner.result = SenseVoiceProcessResult(
            standardOutput: sampleSRT(), standardError: "", exitCode: 0)

        let engine = fixture.makeEngine()
        let segments = try await engine.transcribe(
            fileURL: fixture.base.appendingPathComponent("mic.wav"),
            trackID: "mic", speaker: "我")

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "会议开始。")
        XCTAssertEqual(segments[0].track, "mic")
        XCTAssertEqual(segments[0].speaker, "我")
        XCTAssertEqual(segments[1].text, "讨论一下排期。")
    }

    /// 诊断信息通过 `TranscriptionEngineDiagnostics` 暴露出来（编排层据此把它们
    /// 拼进 `trackFinished` 的 notes）。
    func testDiagnosticsAreExposedThroughOptionalProtocol() async throws {
        try fixture.installEverything()
        fixture.runner.result = SenseVoiceProcessResult(
            standardOutput: "1\n00:00:01,000 --> 00:00:02,000\n。\n",
            standardError: "[sensevoice] 1 vad segments\n", exitCode: 0)

        let engine = fixture.makeEngine()
        XCTAssertTrue(engine.lastNotes.isEmpty, "转写之前不该有诊断")

        _ = try await engine.transcribe(
            fileURL: fixture.base.appendingPathComponent("a.wav"),
            trackID: "mic", speaker: "我")

        XCTAssertTrue(engine.lastNotes.contains { $0.contains("丢弃 1 条纯标点空段") },
                      "被丢弃的条目必须报出来：\(engine.lastNotes)")
        let asProtocol = engine as TranscriptionEngineDiagnostics
        XCTAssertEqual(asProtocol.lastNotes, engine.lastNotes)
    }

    // MARK: - E07 / E08 / E09 / E10 / E11

    /// E07 / E10：标签与解析器映射。
    func testEngineIDAndResolverWiring() {
        let engine = fixture.makeEngine()
        XCTAssertEqual(engine.engineID, "sensevoice")
        XCTAssertEqual(engine.engineID, TranscriptionEngine.senseVoice.driverEngineID)

        let driver = TranscriptionEngineResolver.driver(for: .senseVoice, language: "zh-CN")
        XCTAssertTrue(driver is SenseVoiceTranscriptionEngine)
        XCTAssertEqual(driver.engineID, TranscriptionEngine.senseVoice.driverEngineID)
    }

    /// E08 / E09：真实的五语种支持集。
    ///
    /// 骨架期这里写的是「只认中文」的占位。占位留着会有一个具体后果：
    /// `--lang en-US` 会在门槛处被拦下，而引擎其实完全能处理。
    func testLanguageSupportReflectsRealModelCapability() async {
        let engine = fixture.makeEngine()
        for language in ["zh-CN", "zh-TW", "yue-CN", "en-US", "ja-JP", "ko-KR"] {
            let supported = await engine.isLanguageSupported(language)
            XCTAssertTrue(supported, "\(language) 应被支持")
        }
        let french = await engine.isLanguageSupported("fr-FR")
        XCTAssertFalse(french, "SenseVoiceSmall 不含法语，不能假装支持")

        let list = await engine.supportedLanguages()
        XCTAssertTrue(list.contains("zh-CN"))
        XCTAssertTrue(list.contains("en-US"))
    }

    /// E11：`installState` 逐项列出资产，缺项时 `isReady == false`。
    func testInstallStateReportsPerAssetDetail() throws {
        let empty = fixture.makeEngine().installState
        XCTAssertFalse(empty.isReady)
        XCTAssertEqual(empty.pending.count, 3)
        XCTAssertEqual(empty.status(of: .model), .missing)
        XCTAssertEqual(empty.pendingDownloadByteCount,
                       SenseVoiceAssets.model.byteCount + SenseVoiceAssets.vad.byteCount)

        try fixture.installEverything()
        let ready = fixture.makeEngine().installState
        XCTAssertTrue(ready.isReady)
        XCTAssertTrue(ready.pending.isEmpty)
        XCTAssertEqual(ready.pendingDownloadByteCount, 0)
        XCTAssertEqual(ready.runtimeBinaryURL?.path, fixture.paths.installedRuntimeURL.path)
    }

    /// 坏掉的 env 覆盖要被**指出来**，而不是静默忽略。
    /// 「我明明改了环境变量，程序却毫无变化」是最难排查的一类问题。
    func testBrokenEnvironmentOverrideIsReported() async throws {
        let engine = SenseVoiceTranscriptionEngine(
            paths: fixture.paths,
            runner: fixture.runner,
            environment: [SenseVoicePaths.runtimeOverrideKey: "/tmp/not-a-runtime-\(UUID().uuidString)"],
            bundle: .main)
        do {
            try await engine.prepare()
            XCTFail("资产缺失时必须抛错")
        } catch let error as MRError {
            XCTAssertTrue("\(error)".contains("已被忽略"), "应指出 env 覆盖被忽略：\(error)")
        }
    }

    /// 模型目录是静态可查的（CLI 与 GUI 的状态行都要用它）。
    func testStaticModelDirectoryMatchesPaths() {
        XCTAssertTrue(SenseVoiceTranscriptionEngine.modelDirectory.path
            .contains("meeting-recorder/sensevoice"))
        XCTAssertEqual(SenseVoiceTranscriptionEngine.modelDirectory.path,
                       SenseVoicePaths.defaultBaseDirectory.path)
    }

    /// 构造引擎**不得**在磁盘上建目录。
    func testConstructingEngineCreatesNothing() {
        let base = fixture.base.appendingPathComponent("never-created")
        _ = SenseVoiceTranscriptionEngine(
            paths: SenseVoicePaths(baseDirectory: base),
            runner: fixture.runner, environment: [:], bundle: .main)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
    }

    // MARK: - SenseVoiceInference 自己的守卫

    /// 直接调 `SenseVoiceInference`（绕过引擎的门槛）时，它必须自己守住两条：
    /// 找不到运行时、缺模型资产。少了这两条，任何绕过引擎的调用方都会拿着
    /// 一个不存在的路径去启动子进程，错误信息里只剩 `Process` 的含糊报错。
    func testInferenceGuardsRuntimeAndModelItself() async throws {
        let audio = fixture.base.appendingPathComponent("a.wav")

        do {
            _ = try await fixture.makeInference().transcribe(
                fileURL: audio, trackID: "mic", speaker: "我")
            XCTFail("找不到运行时必须抛错")
        } catch let error as MRError {
            let text = "\(error)"
            XCTAssertTrue(text.contains("推理运行时"), "应指名是运行时：\(text)")
            XCTAssertTrue(text.contains("install-runtime"), "应给出修复命令：\(text)")
        }
        XCTAssertTrue(fixture.runner.invocations.isEmpty,
                      "运行时都没解析出来，就不该去启动子进程")

        // 只补运行时、不补权重 → 第二条守卫
        try fixture.installRuntime()
        do {
            _ = try await fixture.makeInference().transcribe(
                fileURL: audio, trackID: "mic", speaker: "我")
            XCTFail("缺模型资产必须抛错")
        } catch let error as MRError {
            let text = "\(error)"
            XCTAssertTrue(text.contains("缺少模型资产"), "应指名缺模型资产：\(text)")
            XCTAssertTrue(text.contains("model download"), "应给出修复命令：\(text)")
            XCTAssertTrue(text.contains(fixture.paths.url(for: SenseVoiceAssets.model).path),
                          "应给出期望落点：\(text)")
        }
        XCTAssertTrue(fixture.runner.invocations.isEmpty, "缺资产时不该启动子进程")
    }

    /// 被信号终止时要说出来——否则「退出码 9」会被读成「程序返回了 9」。
    func testInferenceReportsSignalTermination() async throws {
        try fixture.installEverything()
        fixture.runner.result = SenseVoiceProcessResult(
            standardOutput: "", standardError: "boom\n", exitCode: 9, terminatedBySignal: true)

        do {
            _ = try await fixture.makeInference().transcribe(
                fileURL: fixture.base.appendingPathComponent("a.wav"),
                trackID: "mic", speaker: "我")
            XCTFail("非 0 退出码必须抛错")
        } catch let error as MRError {
            let text = "\(error)"
            XCTAssertTrue(text.contains("被信号终止"), "应说明是信号终止：\(text)")
            XCTAssertTrue(text.contains("boom"), "应带出 stderr 尾部：\(text)")
        }
    }
}
