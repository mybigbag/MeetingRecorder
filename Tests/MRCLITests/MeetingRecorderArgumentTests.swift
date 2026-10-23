import XCTest
@testable import MRCLI
import MRCapture
import MRCore
import MRSession

/// 命令行参数解析与「参数 → 录制配置」这条映射。
///
/// 为什么值得单独一个 target：`Args` 与「参数 → 配置」此前**零覆盖**，
/// 而「`--f32` 写在文档里却根本没被解析、运行时静默按默认格式录」正是这个缺口
/// 放过去的——没有任何报错，脚本作者永远发现不了自己的参数没生效。
///
/// `runRecord` 要真的开设备、跑实时回调，单测碰不了；但参数映射是纯逻辑，
/// 恰恰必须被钉住。这里只测纯函数，不碰设备、不写盘、不需要任何权限。
final class MeetingRecorderArgumentTests: XCTestCase {

    // MARK: - Args 解析

    func testArgsParseValuesAndDoubles() {
        let a = MeetingRecorderCLI.Args(["--title", "会议", "--seconds", "3"])
        XCTAssertEqual(a.value("title"), "会议")
        XCTAssertEqual(a.double("seconds"), 3)
    }

    func testBooleanFlagLandsInHas() {
        let a = MeetingRecorderCLI.Args(["--pcm16"])
        XCTAssertTrue(a.has("pcm16"))
    }

    /// **已知限制**：`--flag=value` 这种写法会被当成一个未知键，静默无效。
    ///
    /// 这是 `Args` 对所有布尔开关的既有行为，不是本轮引入的——本项目文档一律用
    /// 空格分隔（`--pcm16`，不是 `--pcm16=1`）。这里把现状写成断言，
    /// 免得后来人以为它被支持了；真要支持 `=` 语法得改 `Args` 本身，那是另一件事。
    func testEqualsSyntaxIsNotSupportedAndIsSilentlyIgnored() {
        let a = MeetingRecorderCLI.Args(["--pcm16=1"])
        XCTAssertFalse(a.has("pcm16"), "`--pcm16=1` 目前是未知键——已知限制，不是遗漏")
    }

    // MARK: - 参数 → 配置

    /// 不写任何格式参数时**不表态**（`nil`），把决定权留给上层。
    ///
    /// 这条是「CLI 只认参数、不读偏好」的落点之一：CLI 也不该自己猜成 float32，
    /// 否则它和上层（`MeetingWorkspace`）就有两处默认值，早晚会漂。
    func testNoFormatArgumentLeavesItUnspecified() throws {
        let config = try MeetingRecorderCLI.recordConfiguration(
            from: MeetingRecorderCLI.Args([]))
        XCTAssertNil(config.sampleFormat, "不表态就该是 nil，由上层决定")
    }

    func testPCM16ArgumentRequestsSixteenBit() throws {
        let config = try MeetingRecorderCLI.recordConfiguration(
            from: MeetingRecorderCLI.Args(["--pcm16"]))
        XCTAssertEqual(config.sampleFormat, .pcm16)
    }

    /// `--f32` 曾经写在文档里却根本没被解析——这条专门钉住它现在真的生效。
    ///
    /// 退化示例：删掉 `if a.has("f32") { config.sampleFormat = .float32 }` 分支，
    /// 本用例变红（会拿到 nil 而不是 .float32）。
    func testF32ArgumentRequestsLossless() throws {
        let config = try MeetingRecorderCLI.recordConfiguration(
            from: MeetingRecorderCLI.Args(["--f32"]))
        XCTAssertEqual(config.sampleFormat, .float32)
    }

    /// 两个格式参数互斥。都给了必须**报错**，不能静默取其一——
    /// 静默取其一的话，脚本作者永远不会发现自己的参数没生效。
    ///
    /// 退化示例：把互斥判断删掉，本用例变红（不再抛错）。
    func testConflictingFormatArgumentsThrowInvalidArgument() {
        XCTAssertThrowsError(
            try MeetingRecorderCLI.recordConfiguration(
                from: MeetingRecorderCLI.Args(["--pcm16", "--f32"]))
        ) { error in
            guard let mr = error as? MRError, case .invalidArgument = mr else {
                return XCTFail("两个格式参数同时给应当抛 invalidArgument，实际 \(error)")
            }
        }
    }

    /// 设备锁定、时长上限、是否排除自身进程这几条映射都得对。
    func testDeviceMaxAndExcludeSelfMapToConfiguration() throws {
        let config = try MeetingRecorderCLI.recordConfiguration(
            from: MeetingRecorderCLI.Args(["--device", "UID-123", "--max", "5", "--no-self-audio"]))
        XCTAssertEqual(config.preferredInputUID, "UID-123")
        XCTAssertEqual(config.maxDuration, 5)
        XCTAssertEqual(config.systemAudioExcludesSelf, false)
    }

    // MARK: - `--help` 必须只打印用法

    /// `record --help` 曾经**直接开录**：分派里没有处理子命令后面的 `--help`，
    /// 它被当成了一个多余的开关。实测往真实会议库写进了 2 分钟无用录音（约 68 MB）。
    ///
    /// 退化示例：把 `run()` 里那段 `wantsHelp` 判断删掉，本组仍绿（它测的是纯函数），
    /// 所以真正钉住修复的是 `SenseVoiceCommandTests` 里那条**跑 `run()`** 的用例。
    func testHelpFlagIsRecognisedWhereverItAppears() {
        XCTAssertTrue(MeetingRecorderCLI.wantsHelp(["--help"]))
        XCTAssertTrue(MeetingRecorderCLI.wantsHelp(["-h"]))
        XCTAssertTrue(MeetingRecorderCLI.wantsHelp(["--seconds", "5", "--help"]),
                      "跟在别的参数后面也要认出来")
        XCTAssertTrue(MeetingRecorderCLI.wantsHelp(["--pcm16", "-h"]),
                      "跟在布尔开关后面也要认出来——漏判的代价是「真的开录」")
    }

    /// 反面：没有求助意图的参数列表不该被误读。
    func testOrdinaryArgumentListsAreNotHelpRequests() {
        XCTAssertFalse(MeetingRecorderCLI.wantsHelp([]))
        XCTAssertFalse(MeetingRecorderCLI.wantsHelp(["--title", "会议", "--seconds", "3"]))
        XCTAssertFalse(MeetingRecorderCLI.wantsHelp(["--log", "/tmp/meeting.log"]))
        XCTAssertFalse(MeetingRecorderCLI.wantsHelp(["--pcm16"]))
    }

    /// **刻意接受的一处从宽**：`-h` 出现在值的位置上也会被当成求助。
    ///
    /// 这不是没想到，是**选过**的。两侧代价完全不对等：
    /// 漏判 = 命令照常执行（`record` 上就是真的开录、往真实会议库写 68 MB）；
    /// 误判 = 多打印一次用法，什么都不动。所以判据一律从宽。
    /// 把它写成断言，是为了让后来人看到这是决定、而不是疏漏。
    func testSingleDashValueIsDeliberatelyReadAsHelp() {
        XCTAssertTrue(MeetingRecorderCLI.wantsHelp(["--title", "-h"]),
                      "`-h` 当标题是病态写法；为它保留「真的开录」的风险不划算")
    }

    /// 从宽不影响最关键的那一形态：`--help` 作为值时**不存在**歧义。
    ///
    /// `Args.init` 只把「不以 `--` 开头」的下一个 token 当值，所以
    /// `record --title --help` 在解析器眼里同样是「title 是开关、help 是开关」——
    /// 两边读法一致，不冲突。
    func testHelpDetectionDoesNotContradictTheArgParser() {
        let raw = ["--title", "--help", "--seconds", "5"]
        let a = MeetingRecorderCLI.Args(raw)
        XCTAssertTrue(a.has("title"), "解析器也不把 `--help` 当成 title 的值")
        XCTAssertTrue(a.has("help"), "解析器读到同一个开关")
        XCTAssertEqual(a.double("seconds"), 5)
        XCTAssertTrue(MeetingRecorderCLI.wantsHelp(raw))
    }

    // MARK: - 采样率与声道（单声道 24 kHz）

    /// `--mono24k` 必须真的被解析。
    ///
    /// 同一个坑踩过一次：`--f32` 曾经写在文档里却根本没被解析，运行时静默按默认格式录，
    /// 没有任何提示，脚本作者永远发现不了。这条与 `testF32ArgumentRequestsLossless` 同构。
    ///
    /// 退化示例：删掉 `if a.has("mono24k") { config.mono24k = true }`，本用例变红。
    func testMono24kArgumentRequestsDownsampling() throws {
        let config = try MeetingRecorderCLI.recordConfiguration(
            from: MeetingRecorderCLI.Args(["--mono24k"]))
        XCTAssertEqual(config.mono24k, true)
        XCTAssertTrue(config.resolvedMono24k)
    }

    /// `--fullband` 是显式的「不降带宽」，与「没表态」在语义上不同。
    ///
    /// 分开是必要的：`--fullband` 表达的是「我明确要全带宽」，
    /// 将来若有上层按偏好兜底，它必须能压住偏好；`nil` 则是「你决定」。
    func testFullbandArgumentIsExplicitOptOut() throws {
        let config = try MeetingRecorderCLI.recordConfiguration(
            from: MeetingRecorderCLI.Args(["--fullband"]))
        XCTAssertEqual(config.mono24k, false)
        XCTAssertFalse(config.resolvedMono24k)
    }

    /// 两个带宽参数互斥，同时给必须报错。
    ///
    /// 与 `--pcm16` / `--f32` 同一条纪律：静默取其一的话，
    /// 脚本作者永远不会发现自己的参数没生效。
    func testConflictingBandwidthArgumentsThrowInvalidArgument() {
        XCTAssertThrowsError(
            try MeetingRecorderCLI.recordConfiguration(
                from: MeetingRecorderCLI.Args(["--mono24k", "--fullband"]))
        ) { error in
            guard let mr = error as? MRError, case .invalidArgument = mr else {
                return XCTFail("两个带宽参数同时给应当抛 invalidArgument，实际 \(error)")
            }
        }
    }

    /// 不给带宽参数时**不表态**（`nil`），决定权留给上层——CLI 不读偏好。
    func testNoBandwidthArgumentLeavesItUnspecified() throws {
        let config = try MeetingRecorderCLI.recordConfiguration(
            from: MeetingRecorderCLI.Args([]))
        XCTAssertNil(config.mono24k, "不表态就该是 nil，由上层决定")
        XCTAssertFalse(config.resolvedMono24k, "而解析后的默认必须是「不动格式」")
    }

    /// **位深与带宽不互斥**：「16 位 + 单声道 24 kHz」是推荐组合，必须能一条命令表达。
    ///
    /// 这条单独写，是因为它很容易被顺手做成互斥——把两个 `if ... &&` 写在一起
    /// 就会把推荐组合挡在门外，而「勾两个开关报错」在界面上会显得像 bug。
    func testBitDepthAndBandwidthArgumentsStack() throws {
        let config = try MeetingRecorderCLI.recordConfiguration(
            from: MeetingRecorderCLI.Args(["--pcm16", "--mono24k"]))
        XCTAssertEqual(config.sampleFormat, .pcm16, "两个维度各自生效，不该互相抵消")
        XCTAssertEqual(config.mono24k, true)
        XCTAssertTrue(config.resolvedMono24k)

        // 反过来的组合也要能表达
        let lossless = try MeetingRecorderCLI.recordConfiguration(
            from: MeetingRecorderCLI.Args(["--f32", "--mono24k"]))
        XCTAssertEqual(lossless.sampleFormat, .float32)
        XCTAssertEqual(lossless.mono24k, true)
    }

    /// `--help` 文本必须提到这两个参数。
    ///
    /// `--f32` 曾经「写在文档里、实现里没有」，反过来（实现里有、文档里没有）
    /// 同样会让用户以为参数不存在。所以帮助文本也钉住。
    func testUsageTextDocumentsTheBandwidthFlags() {
        let usage = MeetingRecorderCLI.usageText()
        XCTAssertTrue(usage.contains("--mono24k"), "帮助里必须列出 --mono24k")
        XCTAssertTrue(usage.contains("--fullband"), "帮助里必须列出 --fullband")
        XCTAssertTrue(usage.contains("--pcm16"), "既有的位深参数不能被挤掉")
    }

    /// `record --help` 仍然只打印用法，不会因为我们加了参数而误开录。
    func testHelpStillWinsOverTheNewFlags() {
        XCTAssertTrue(MeetingRecorderCLI.wantsHelp(["--mono24k", "--help"]))
        XCTAssertFalse(MeetingRecorderCLI.wantsHelp(["--mono24k"]),
                       "只给 --mono24k 不是求助，是真要录")
    }

    // MARK: - B20-46　`config show` 的输出

    private func freshPreferences() throws -> (RecorderPreferences, String) {
        let suiteName = "mr-cli-config-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (RecorderPreferences(defaults: defaults), suiteName)
    }

    /// `config show` 必须把「单声道 24 kHz」这一行打出来。
    ///
    /// 这条此前**完全没写**（交叉审查查出来的覆盖盲区）：用户改完开关之后，
    /// `config show` 是他唯一能确认「我到底设成了什么」的出口——与已覆盖的
    /// `--help` 文本（B20-47）同一性质，却漏了。
    ///
    /// 断言用纯函数 `configShowLines`（`runConfig` 直接 `print` 到 stdout，测试不便捕获），
    /// 并且**双向**验：默认关、打开后开。只验一边的话，把这一行写死成「关」也能过。
    func testConfigShowDocumentsTheMono24kSwitch() throws {
        let (prefs, suiteName) = try freshPreferences()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let offLines = MeetingRecorderCLI.configShowLines(prefs: prefs)
        XCTAssertTrue(offLines.contains { $0.contains("单声道 24 kHz：关") },
                      "默认必须显示「关」，实际输出：\(offLines)")

        prefs.mono24kRecording = true
        let onLines = MeetingRecorderCLI.configShowLines(prefs: prefs)
        XCTAssertTrue(onLines.contains { $0.contains("单声道 24 kHz：开") },
                      "开关打开后必须显示「开」，实际输出：\(onLines)")
    }

    /// 加新行不能把既有几行挤掉。
    func testConfigShowKeepsTheExistingLines() throws {
        let (prefs, suiteName) = try freshPreferences()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let lines = MeetingRecorderCLI.configShowLines(prefs: prefs)
        XCTAssertTrue(lines.contains { $0.contains("转写引擎：") }, "实际输出：\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("静默录制：") })
        XCTAssertTrue(lines.contains { $0.contains("16 位录音：") })
        XCTAssertTrue(lines.contains { $0.contains("可选引擎：") })
    }

    // MARK: - transcribe --track（单轨转录）

    private func trackFilter(_ args: [String]) throws -> Set<String>? {
        var config = SessionTranscriber.Configuration()
        try MeetingRecorderCLI.trackFilterConfiguration(
            from: MeetingRecorderCLI.Args(args), into: &config)
        return config.trackFilter
    }

    /// 不给 `--track` 就是整场转写。
    func testNoTrackMeansWholeSession() throws {
        XCTAssertNil(try trackFilter([]))
        XCTAssertTrue(SessionTranscriber.Configuration().isWholeSession)
    }

    func testTrackAcceptsBothCanonicalIDsAndAliases() throws {
        XCTAssertEqual(try trackFilter(["--track", "mic"]), ["mic"])
        XCTAssertEqual(try trackFilter(["--track", "system"]), ["system"])
        XCTAssertEqual(try trackFilter(["--track", "MIC"]), ["mic"])
        XCTAssertEqual(try trackFilter(["--track", " 我 "]), ["mic"])
        XCTAssertEqual(try trackFilter(["--track", "对方"]), ["system"])
    }

    /// **`--track` 缺值必须报错。**
    ///
    /// 退化示例：删掉那个 `a.has("track") && a.value("track") == nil` 的检查，
    /// 本用例变红，而症状是「我明明只转了一条，怎么出了两份稿」。
    func testTrackWithoutValueIsRejected() {
        XCTAssertThrowsError(try trackFilter(["--track"])) { error in
            XCTAssertTrue("\(error)".contains("缺轨 ID"), "\(error)")
        }
    }

    /// 拼错的轨必须报错并列出可选值。静默转整场是最糟的读法。
    ///
    /// 列表里**没有** `"mic "`：尾随空格会被 `trimmingCharacters` 正确处理，
    /// 那是一个合法的输入形态（手滑多打一个空格），报错才是刁难。
    func testUnknownTrackIsRejectedWithTheLegalList() {
        for bad in ["mci", "sytem", "s", "both", "mic2"] {
            XCTAssertThrowsError(try trackFilter(["--track", bad]), "--track \(bad)") { error in
                let text = "\(error)"
                XCTAssertTrue(text.contains("mic"), "报错要列出合法值：\(text)")
                XCTAssertTrue(text.contains("system"), "报错要列出合法值：\(text)")
            }
        }
    }

    /// 单轨时 `isWholeSession` 必须是 false——
    /// 它同时决定文件名、manifest 状态改不改、要不要加单轨说明，三件事同源。
    func testTrackFilterMakesItNotAWholeSessionRun() throws {
        var config = SessionTranscriber.Configuration()
        try MeetingRecorderCLI.trackFilterConfiguration(
            from: MeetingRecorderCLI.Args(["--track", "mic"]), into: &config)
        XCTAssertFalse(config.isWholeSession)
    }

    /// 单轨提示里必须说清「整场稿不会被改动」。
    ///
    /// 这是本功能最要紧的一条事实，而它只出现在终端输出里——
    /// 不抽成返回值就只能靠人眼扫，而人眼在这个项目里已经错过东西了。
    func testSingleTrackBannerStatesThatTheWholeTranscriptIsUntouched() {
        let lines = MeetingRecorderCLI.singleTrackBanner(trackIDs: ["mic"]).joined(separator: "\n")
        XCTAssertTrue(lines.contains("transcript-mic.md"),
                      "要点明单轨稿写到哪里：\(lines)")
        XCTAssertTrue(lines.contains("transcript.md"),
                      "要点明整场稿的名字：\(lines)")
        XCTAssertTrue(lines.contains("不会被改动"), "要点明整场稿不被改动：\(lines)")
        XCTAssertTrue(lines.contains("已转写"),
                      "要点明不会把会议标记为「已转写」：\(lines)")
    }

    /// 帮助里必须有 `--track`，否则单轨转录等于没有。
    func testUsageMentionsSingleTrackTranscription() {
        let usage = MeetingRecorderCLI.usageText()
        XCTAssertTrue(usage.contains("--track"),
                      "帮助里必须有按轨转录的入口：\(usage)")
    }
}
