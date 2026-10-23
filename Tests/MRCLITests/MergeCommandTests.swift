import XCTest
@testable import MRCLI
@testable import MRSession
import MRCore
import Foundation

/// `mr merge` 的参数 → 配置映射，与整场编排（`SessionAudioExporter`）。
///
/// 与 `TranscodeArgumentTests` 同一套理由：真正去写盘的动作单测碰不了，
/// 但「哪个参数决定哪种行为」「产物会不会被当成第三条轨」必须被钉住。
final class MergeCommandTests: XCTestCase {

    private var root: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-merge-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SessionStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 参数 → 配置

    /// 默认**必须**是立体声分置。混音是不可逆的，拿它当默认值等于替用户做决定。
    func testDefaultIsStereoSplitPCM16() throws {
        let config = try MeetingRecorderCLI.mergeConfiguration(
            from: MeetingRecorderCLI.Args([]))
        XCTAssertEqual(config.mode, .stereoSplit)
        XCTAssertEqual(config.format, .pcm16)
        XCTAssertFalse(config.overwrite)
    }

    func testMonoAndStereoFlags() throws {
        XCTAssertEqual(try MeetingRecorderCLI.mergeConfiguration(
            from: MeetingRecorderCLI.Args(["--mono"])).mode, .monoMix)
        XCTAssertEqual(try MeetingRecorderCLI.mergeConfiguration(
            from: MeetingRecorderCLI.Args(["--stereo"])).mode, .stereoSplit)
    }

    /// **退化示例**：删掉这个互斥检查，本用例红。
    /// 静默取其一的话，脚本作者永远发现不了自己的参数没生效。
    func testMonoAndStereoTogetherIsRejected() {
        XCTAssertThrowsError(try MeetingRecorderCLI.mergeConfiguration(
            from: MeetingRecorderCLI.Args(["--mono", "--stereo"])))
    }

    func testModeValueOverridesFlags() throws {
        let config = try MeetingRecorderCLI.mergeConfiguration(
            from: MeetingRecorderCLI.Args(["--stereo", "--mode", "mono"]))
        XCTAssertEqual(config.mode, .monoMix,
                       "--mode 是显式选择，应覆盖开关")
    }

    /// **退化示例**：让未知 `--mode` 静默走默认，本用例红。
    func testUnknownModeValueIsRejectedWithTheLegalList() {
        XCTAssertThrowsError(try MeetingRecorderCLI.mergeConfiguration(
            from: MeetingRecorderCLI.Args(["--mode", "binaural"]))) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("stereo") && text.contains("mono"), text)
        }
    }

    func testUnknownFormatValueIsRejectedAndExplainsItIsBitDepth() {
        XCTAssertThrowsError(try MeetingRecorderCLI.mergeConfiguration(
            from: MeetingRecorderCLI.Args(["--to", "b"]))) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("b"), "报错要带上用户写的值：\(text)")
            XCTAssertTrue(text.contains("声道"), "要说清 --to 是位深、--mono 才是声道：\(text)")
        }
    }

    /// 位深与声道是**两件事**，可以叠加。判成互斥会让「16 位单声道」没法表达。
    func testFormatAndModeAreIndependent() throws {
        let config = try MeetingRecorderCLI.mergeConfiguration(
            from: MeetingRecorderCLI.Args(["--mono", "--to", "f32"]))
        XCTAssertEqual(config.mode, .monoMix)
        XCTAssertEqual(config.format, .float32)
    }

    func testOverwriteIsOptInAndOutPathIsCaptured() throws {
        let config = try MeetingRecorderCLI.mergeConfiguration(
            from: MeetingRecorderCLI.Args(["--overwrite", "--out", "/tmp/x.wav"]))
        XCTAssertTrue(config.overwrite)
        XCTAssertEqual(config.outputPath, "/tmp/x.wav")
    }

    // MARK: - 整场编排

    /// hostTime 是 mach 绝对时间（`nanosecondsPerTick` 每 tick 折算成纳秒），
    /// **不是**纳秒本身。所以测试里的偏移必须换算，不能直接写「300_000_000 当 0.3 秒」——
    /// 那在真机上可能是 0.06 秒也可能是 30 秒，取决于这台机器的 timebase。
    ///
    /// 用 `HostClock.nanosecondsPerTick` 反算出一个「确实是 N 秒」的 tick 数，
    /// 这样用例在任何机器上都成立（Apple Silicon 的 timebase 是 1/1，
    /// 但 Intel 上是125/3，差了 41 倍）。
    private func ticks(forSeconds seconds: Double) -> UInt64 {
        UInt64(seconds * 1_000_000_000 / HostClock.nanosecondsPerTick)
    }

    /// 一个贴近真实的 hostTime 基准（开机后若干秒）。
    private static let baseHostTime: UInt64 = 22850802647912

    private func makeSession(title: String = "合并测试",
                             systemOffsetSeconds: Double = 0.01,
                             systemSilent: Bool = false,
                             includeSystem: Bool = true) throws -> String {
        let (id, dir) = try store.createSession(title: title,
                                                 date: Date(timeIntervalSince1970: 1_780_000_000))
        var manifest = try store.loadManifest(forSessionID: id)
        manifest.state = .finalized
        manifest.endedAt = Date(timeIntervalSince1970: 1_780_000_002)

        func write(_ name: String, seconds: Double, channels: Int, silent: Bool) throws {
            let w = try WAVWriter(url: dir.appendingPathComponent(name),
                                  sampleRate: 48000, channels: channels, format: .float32)
            let frames = Int(48000 * seconds)
            var block: [Float] = []
            for f in 0..<frames {
                for c in 0..<channels {
                    // 两声道不等幅，这样「左=我、右=对方」在结果里可分辨
                    let base = c == 0 ? 0.5 : 0.2
                    block.append(silent ? 0
                        : Float(base * sin(2 * .pi * Double(300 + c * 200) * Double(f) / 48000)))
                }
                if block.count >= 48000 * channels {
                    try w.append(block); block.removeAll(keepingCapacity: true)
                }
            }
            if !block.isEmpty { try w.append(block) }
            try w.finalize()
            w.close()
        }

        try write("mic.wav", seconds: 2, channels: 1, silent: false)
        var tracks = [TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                                     sampleRate: 48000, channels: 1, framesWritten: 96000)]
        tracks[0].firstHostTime = Self.baseHostTime
        tracks[0].lastHostTime = Self.baseHostTime + ticks(forSeconds: 2)
        if includeSystem {
            try write("system.wav", seconds: 2, channels: 2, silent: systemSilent)
            var t = TrackManifest(id: "system", role: .systemAudio, fileName: "system.wav",
                                  sampleRate: 48000, channels: 2, framesWritten: 96000)
            // 让 system 晚一点开始（真实两轨就有这个差，方向随设备与时序而异）
            let delta = ticks(forSeconds: systemOffsetSeconds)
            t.firstHostTime = Self.baseHostTime + delta
            t.lastHostTime = Self.baseHostTime + delta + ticks(forSeconds: 2)
            tracks.append(t)
        }
        manifest.tracks = tracks
        try store.save(manifest, sessionDirectory: dir)
        return id
    }

    func testPlanComputesEverythingWithoutWriting() throws {
        let id = try makeSession()
        let before = try FileManager.default.contentsOfDirectory(
            atPath: store.directory(forSessionID: id).path).sorted()
        let plan = try SessionAudioExporter(store: store).plan(sessionID: id)
        let after = try FileManager.default.contentsOfDirectory(
            atPath: store.directory(forSessionID: id).path).sorted()
        XCTAssertEqual(after, before, "plan 一个字节都不写")
        XCTAssertEqual(plan.inputs.count, 2)
        XCTAssertFalse(plan.isNotApplicable)
        XCTAssertEqual(plan.outputChannels, 2)
        XCTAssertGreaterThan(plan.estimatedBytes, 0)
        XCTAssertTrue(plan.outputName.hasSuffix("-merged.wav"))
    }

    /// **本模块最关键的一条**：合并产物**不能**被当成第三条轨。
    ///
    /// 目录里多一个 `.wav` 就可能被工具或用户当成音频轨，所以除了文件名，
    /// 还必须保证它没被写进 manifest。
    /// 退化示例：把合并结果 `append` 进 `manifest.tracks` 再保存，本用例红。
    func testMergedFileIsNotWrittenIntoTheManifest() throws {
        let id = try makeSession()
        let outcome = try SessionAudioExporter(store: store).merge(sessionID: id)
        XCTAssertTrue(outcome.isSuccess)
        XCTAssertFalse(outcome.manifestTouched, "合并产物不是一条轨")

        let manifest = try store.loadManifest(forSessionID: id)
        XCTAssertEqual(manifest.tracks.count, 2, "manifest 仍是两条轨")
        XCTAssertFalse(manifest.tracks.contains { $0.fileName.contains("merged") })

        // 原轨的格式字段也不能被合并动过
        XCTAssertTrue(manifest.tracks.allSatisfy { $0.sampleFormat == .float32 })
        XCTAssertTrue(manifest.tracks.allSatisfy { $0.sampleRate == 48000 })
    }

    func testMergedFileLandsBesideTheSessionWithMergedName() throws {
        let id = try makeSession()
        let outcome = try SessionAudioExporter(store: store).merge(sessionID: id)
        let dir = store.directory(forSessionID: id)
        XCTAssertEqual(outcome.destination.deletingLastPathComponent().path, dir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.destination.path))
        let header = try WAVWriter.readHeader(at: outcome.destination)
        XCTAssertEqual(header.channels, 2)
        XCTAssertEqual(header.sampleRate, 48000)
    }

    /// 已有产物时**默认不覆盖**。合并可能跑很久，静默覆盖掉用户上次的成果比报错更糟。
    /// 退化示例：去掉 overwrite 检查，本用例红。
    func testExistingDestinationIsNotOverwrittenByDefault() throws {
        let id = try makeSession()
        let first = try SessionAudioExporter(store: store).merge(sessionID: id)
        // 用内容指纹而不是 mtime：文件系统的时间戳精度不一，
        // 而「内容有没有变」才是这件事真正要断言的东西。
        let before = try Data(contentsOf: first.destination)

        XCTAssertThrowsError(try SessionAudioExporter(store: store).merge(sessionID: id)) { error in
            XCTAssertTrue("\(error)".contains("已存在"), "\(error)")
            XCTAssertTrue("\(error)".contains("overwrite"),
                          "报错要说清怎么覆盖：\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: first.destination), before,
                       "被拒绝的那次不能碰文件")
    }

    func testOverwriteReplacesTheFile() throws {
        let id = try makeSession()
        _ = try SessionAudioExporter(store: store).merge(sessionID: id)
        let second = try SessionAudioExporter(store: store)
            .merge(sessionID: id, overwrite: true)
        XCTAssertTrue(second.isSuccess)
        let header = try WAVWriter.readHeader(at: second.destination)
        XCTAssertTrue(header.isConsistent)
    }

    /// **本机真实数据里有 3 场的 system 轨是 100% 静音**（系统音频采集没起来）。
    /// 合并后总体有声音，用户不会发现对方那一路是空的。
    /// 退化示例：把静音提醒那几行删掉，本用例红。
    func testSilentTrackProducesAnExplicitNote() throws {
        let id = try makeSession(systemSilent: true)
        let outcome = try SessionAudioExporter(store: store).merge(sessionID: id)
        XCTAssertTrue(outcome.isSuccess, "源本身静音不是故障，不该失败")
        XCTAssertTrue(outcome.notes.contains { $0.contains("system") && $0.contains("静音") },
                      "必须点名是 system 那轨静音：\(outcome.notes)")
        XCTAssertEqual(outcome.result?.silentTracks(), ["system"])
    }

    /// **退化示例**：把偏移提醒的阈值从 0.05 改成 10（本项目的一秒级偏移就会漏报），
    /// 本用例红。阈值要有依据：小于 5 ms 人耳基本听不出，而系统音频冷启动
    /// 可能慢到几百毫秒——那正是必须说的情形。
    func testLargeOffsetIsReported() throws {
        let id = try makeSession(systemOffsetSeconds: 0.3)

        let outcome = try SessionAudioExporter(store: store).merge(sessionID: id)
        XCTAssertTrue(outcome.notes.contains { $0.contains("hostTime") && $0.contains("0.3") },
                      "0.3 秒的偏移必须报出来：\(outcome.notes)")
    }

    /// 偏移真的被用上了：合并结果应比两条轨都长出那段偏移。
    /// 退化示例：让 `plan` 不带偏移（恒 0），本用例红。
    func testOffsetActuallyLengthensTheMergedFile() throws {
        let id = try makeSession(systemOffsetSeconds: 0.5)

        let outcome = try SessionAudioExporter(store: store).merge(sessionID: id)
        let duration = try XCTUnwrap(outcome.result?.duration)
        XCTAssertEqual(duration, 2.5, accuracy: 0.01,
                       "2 秒音频 + 0.5 秒偏移 → 2.5 秒。少了偏移就是 2 秒")
    }

    /// 一条轨时合并没有意义，必须明确报错而不是产出一个「合并文件」。
    func testSingleTrackIsRejectedWithAnExplanation() throws {
        let id = try makeSession(includeSystem: false)
        XCTAssertThrowsError(try SessionAudioExporter(store: store).merge(sessionID: id)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("1 条") || text.contains("只有"), text)
        }
    }

    /// 缺一条轨时必须拒绝，而不是合并出一条「对方那一路是空的」的文件。
    func testMissingTrackStopsTheMerge() throws {
        let id = try makeSession()
        try FileManager.default.removeItem(at: store.directory(forSessionID: id)
            .appendingPathComponent("system.wav"))
        XCTAssertThrowsError(try SessionAudioExporter(store: store).merge(sessionID: id)) { error in
            XCTAssertTrue("\(error)".contains("system"), "\(error)")
        }
    }

    /// 报告文本必须说清「产物不是音轨」，否则用户会怕它污染这场会议。
    func testReportTextDisclosesThatItIsNotATrack() throws {
        let id = try makeSession()
        let plan = try SessionAudioExporter(store: store).plan(sessionID: id)
        let config = try MeetingRecorderCLI.mergeConfiguration(from: MeetingRecorderCLI.Args([]))
        let text = MeetingRecorderCLI.mergeHeaderText(config, plan: plan)
        XCTAssertTrue(text.contains("stereoSplit") || text.contains("立体声"), text)
        XCTAssertTrue(text.contains("mic"), "要列出参与的轨：\(text)")
        XCTAssertTrue(text.contains("system"), "要列出参与的轨：\(text)")
    }

    /// 报告里必须出现「不升采样」这条纪律，否则用户看到 48k→24k 会以为降了质量。
    func testReportSaysSampleRateIsNotUpsampled() throws {
        let id = try makeSession()
        var manifest = try store.loadManifest(forSessionID: id)
        // 把 mic 换成 24 kHz，触发混合采样率
        let dir = store.directory(forSessionID: id)
        let w = try WAVWriter(url: dir.appendingPathComponent("mic.wav"),
                              sampleRate: 24000, channels: 1, format: .float32)
        try w.append([Float](repeating: 0.4, count: 24000 * 2))
        try w.finalize()
        w.close()
        manifest.tracks[0].sampleRate = 24000
        manifest.tracks[0].framesWritten = 24000 * 2
        try store.save(manifest, sessionDirectory: dir)

        let plan = try SessionAudioExporter(store: store).plan(sessionID: id)
        XCTAssertEqual(plan.outputSampleRate, 24000)
        let text = MeetingRecorderCLI.mergeHeaderText(
            try MeetingRecorderCLI.mergeConfiguration(from: MeetingRecorderCLI.Args([])),
            plan: plan)
        XCTAssertTrue(text.contains("不升采样"), text)
    }

    /// 静音轨必须在**报告文本**里被点名，而不只是 `Result.silentTracks()` 里有。
    ///
    /// 合并后整体听着有声音，用户不会发现对方那一路是空的——本机 22 场真实会议里
    /// 有 3 场的 system 轨就是全静音（当时系统音频采集没起来）。
    func testSilentTrackIsNamedInTheReportText() throws {
        let id = try makeSession(systemSilent: true)
        let outcome = try SessionAudioExporter(store: store).merge(sessionID: id)
        XCTAssertTrue(outcome.isSuccess)
        XCTAssertEqual(outcome.result?.silentTracks(), ["system"],
                       "对方那轨全静音，必须被指出来")
        let text = outcome.notes.joined(separator: "\n")
        XCTAssertTrue(text.contains("system"), "要指名是哪一条：\(text)")
        XCTAssertTrue(text.contains("静音"), "要说清是静音而不是合并出错：\(text)")
    }

    /// 静默轨的电平行**不能有乱码**，且静音轨必须带标记。
    ///
    /// 真实缺陷：`String(format: "… %.5f%s", name, rms, rms < 阈值 ? "  ← 全静音" : "")`
    /// 里的三元两侧长度不同，编译器为两侧分别生成临时字符串、而空串字面量没有自己的
    /// 存储，`%s` 于是读到已复用的内存 —— mic RMS 为 0 时输出成
    /// `mic 平均电平 0.00000厣悯`。**只有静音轨才触发**，平时根本看不到。
    ///
    /// ⚠️ 这条用例必须调用**生产代码** `MeetingRecorderCLI.trackLevelLine`。
    /// 写成「在测试里复刻一遍同样的拼装」的话，改生产代码它照样绿——
    /// 变异 M8 实测就是这么白跑的（那是本项目第四次自己造出来的假绿）。
    func testSilentTrackLevelLineIsCleanAndMarked() throws {
        let id = try makeSession(systemSilent: true)
        let outcome = try SessionAudioExporter(store: store).merge(sessionID: id)
        let result = try XCTUnwrap(outcome.result)
        XCTAssertEqual(result.perTrackRMS.count, 2)

        let digits = Set("0123456789.".map(String.init))
        let fixed = Set(" 平均电平←全静音".map(String.init))
        for (name, rms) in zip(result.labels, result.perTrackRMS) {
            let line = MeetingRecorderCLI.trackLevelLine(name: name, rms: rms)
            // 整行字符只能来自「轨名 + 固定文案 + 数字」。原缺陷多出的「厣悯」
            // 既不是数字也不是文案，这个白名单就能抓到。
            for ch in line {
                XCTAssertTrue(digits.contains(String(ch))
                              || fixed.contains(String(ch))
                              || name.contains(ch),
                              "电平行混入了不该有的字符：\(line)"
                              + "（读到 \(ch.debugDescription)）")
            }
            let isSilent = rms < AudioTrackMerger.Result.silenceRMSThreshold
            XCTAssertEqual(line.contains("全静音"), isSilent,
                           "静音轨必须带标记、非静音轨必须没有：\(line)")
            if isSilent {
                XCTAssertTrue(line.hasSuffix("全静音"),
                              "标记后面不该再有多余字符：\(line)")
            } else {
                XCTAssertNotNil(line.last.flatMap { digits.contains(String($0)) ? $0 : nil },
                                "非静音轨的行尾必须是数字：\(line)")
            }
        }
    }

    /// 直接打这道判据，不依赖任何夹具 —— 三个 RMS 档位各打一行。
    /// 静音那一档就是原缺陷的触发条件。
    func testTrackLevelLineAtEveryLevel() {
        let prefix = "    mic 平均电平 "
        let cases: [(Float, String)] = [
            (0.0005, "\(prefix)0.00050"),           // 恰好等于阈值不算静音（判据是 <）
            (0.0,    "\(prefix)0.00000  ← 全静音"),  // 原缺陷的触发档
            (0.04564, "\(prefix)0.04564"),
            (0.994,  "\(prefix)0.99400"),
        ]
        for (rms, expected) in cases {
            let line = MeetingRecorderCLI.trackLevelLine(name: "mic", rms: rms)
            XCTAssertEqual(line, expected)
        }
    }
}

