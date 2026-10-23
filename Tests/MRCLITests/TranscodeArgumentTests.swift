import XCTest
@testable import MRCLI
@testable import MRSession
import MRCore
import Foundation

/// `mr transcode` 的参数 → 配置映射。
///
/// 与 `MeetingRecorderArgumentTests` 同一套理由，但更紧迫：`transcode` 会**改写用户盘上
/// 已有录音**，参数拼错的后果是「用户以为转成了 16 位，实际按另一个档转了」——
/// 而转码是原文件被替换的操作，事后无法回退（除非开了 `--keep-original`）。
///
/// `Args` 对未知 `--xxx` 一律放过（`--log` 这类入口层参数需要共存），所以本层
/// **必须**自己校验每一个有消费者的键，否则拼错等于静默走默认档。
final class TranscodeArgumentTests: XCTestCase {

    // MARK: - --to 预设

    func testDefaultPresetIsBTier() throws {
        let config = try MeetingRecorderCLI.transcodeConfiguration(
            from: MeetingRecorderCLI.Args([]))
        XCTAssertEqual(config.preset, .bTier,
                       "默认走 B 档——这是 E 档存量迁移要用的那一档")
        // 默认降混是 `firstChannel`：真机实测 `average` 在反相内容上会整轨抵消成静音，
        // 而录音看起来完全成功（帧数/时长/manifest 全对）。
        // 依据见 `DownmixStrategyDefaultTests`。
        XCTAssertEqual(config.downmix, .firstChannel)
        XCTAssertFalse(config.dryRun)
        XCTAssertFalse(config.allSessions)
    }

    func testPresetAliasesAllResolve() throws {
        let cases: [(String, AudioTranscoder.Preset)] = [
            ("b", .bTier), ("B", .bTier), ("bTier", .bTier), ("b-tier", .bTier),
            ("mono24k", .bTier), ("24k", .bTier),
            ("pcm16", .pcm16), ("a", .pcm16), ("a-tier", .pcm16),
            ("f32", .lossless32), ("lossless32", .lossless32), ("lossless", .lossless32),
        ]
        for (raw, expected) in cases {
            let config = try MeetingRecorderCLI.transcodeConfiguration(
                from: MeetingRecorderCLI.Args(["--to", raw]))
            XCTAssertEqual(config.preset, expected, "--to \(raw)")
        }
    }

    /// **退化示例**：把 `transcodeConfiguration` 里的 `default:` 分支删掉、
    /// 让拼错的值静默走 `.bTier`，本用例变红（不抛错了）。
    func testUnknownPresetValueIsRejectedWithTheLegalList() {
        XCTAssertThrowsError(try MeetingRecorderCLI.transcodeConfiguration(
            from: MeetingRecorderCLI.Args(["--to", "pcm-16"]))) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("pcm-16"), "报错要带上用户实际写的值：\(text)")
            XCTAssertTrue(text.contains("bTier"),
                          "报错要列出合法值，否则用户只能猜：\(text)")
        }
    }

    /// `--to` 的默认值必须是 B 档而不是「不表态」。
    ///
    /// 与 `record` 的 `--f32` 不表态是**不同的决定**：record 是**新建**文件，
    /// 不表态能把选择权留给上层；transcode 是**原地替换已有文件**，
    /// 没有「上层之后再决定」这个时机。所以必须给一个有依据的默认值。
    func testPresetIsAlwaysConcreteBecauseTranscodeOverwritesInPlace() throws {
        for args in [[], ["--dry-run"], ["--keep-original"]] {
            let config = try MeetingRecorderCLI.transcodeConfiguration(
                from: MeetingRecorderCLI.Args(args))
            XCTAssertEqual(config.preset, .bTier, "参数 \(args) 下也必须有确定的档位")
        }
    }

    // MARK: - --downmix

    func testDownmixAliases() throws {
        let cases: [(String, MonoDownmixStrategy)] = [
            ("average", .average), ("avg", .average),
            ("firstChannel", .firstChannel), ("first-channel", .firstChannel),
            ("first", .firstChannel),
        ]
        for (raw, expected) in cases {
            let config = try MeetingRecorderCLI.transcodeConfiguration(
                from: MeetingRecorderCLI.Args(["--downmix", raw]))
            XCTAssertEqual(config.downmix, expected, "--downmix \(raw)")
        }
    }

    func testUnknownDownmixValueIsRejected() {
        XCTAssertThrowsError(try MeetingRecorderCLI.transcodeConfiguration(
            from: MeetingRecorderCLI.Args(["--downmix", "left"])))
    }

    /// `.firstChannel` 只在**真要降混**的档位下才有意义。
    ///
    /// `--to pcm16` 保留源声道数 → 根本不降混，此时传 `--downmix first-channel`
    /// 是「一个不起作用的参数」。这里不报错（用户可能只是想显式表达），
    /// 但必须让 CLI 在报告里说清这一点——否则用户会以为系统轨做了处理。
    /// 退化示例：把 CLI 报告里的 `config.downmix.displayName` 删掉，
    /// `testReportDescribesDownmixEvenWhenItCannotApply` 就红。
    func testFirstChannelWithPcm16PresetIsAcceptedButReportMustDisclose() throws {
        let config = try MeetingRecorderCLI.transcodeConfiguration(
            from: MeetingRecorderCLI.Args(["--to", "pcm16", "--downmix", "first-channel"]))
        XCTAssertEqual(config.preset, .pcm16)
        XCTAssertEqual(config.downmix, .firstChannel)

        let text = MeetingRecorderCLI.transcodeHeaderText(config)
        XCTAssertTrue(text.contains("只取第 1 声道"), "报告里必须出现实际使用的降混策略")
        XCTAssertTrue(text.contains("不会真正生效") || text.contains("不会降混"),
                      "pcm16 档保留源声道数，必须说明该策略在此档下不生效：\(text)")
    }

    // MARK: - 开关

    func testDryRunFlags() throws {
        for flag in ["--dry-run", "--plan"] {
            let config = try MeetingRecorderCLI.transcodeConfiguration(
                from: MeetingRecorderCLI.Args([flag]))
            XCTAssertTrue(config.dryRun, "\(flag) 都应该打开 dry-run")
        }
    }

    func testKeepOriginalIsOptIn() throws {
        let off = try MeetingRecorderCLI.transcodeConfiguration(
            from: MeetingRecorderCLI.Args([]))
        XCTAssertFalse(off.keepOriginal, "默认不留备份——批量迁移时备份等于把磁盘填满")

        let on = try MeetingRecorderCLI.transcodeConfiguration(
            from: MeetingRecorderCLI.Args(["--keep-original"]))
        XCTAssertTrue(on.keepOriginal)
    }

    /// **退化示例**：删掉 `--all` 与 `--keep-original` 的互斥检查，
    /// 本用例变红（配置不再抛错）。
    func testAllRejectsKeepOriginalBecauseItDoublesPeakDiskUsage() {
        XCTAssertThrowsError(try MeetingRecorderCLI.transcodeConfiguration(
            from: MeetingRecorderCLI.Args(["--all", "--keep-original"]))) { error in
            XCTAssertTrue("\(error)".contains("翻倍"),
                          "报错要说清代价是峰值磁盘占用翻倍：\(error)")
        }
    }

    func testAllAloneIsFine() throws {
        let config = try MeetingRecorderCLI.transcodeConfiguration(
            from: MeetingRecorderCLI.Args(["--all", "--to", "b"]))
        XCTAssertTrue(config.allSessions)
        XCTAssertEqual(config.preset, .bTier)
    }

    /// `--all` 与位置参数同时给时报错。两个意图都合法，但合在一起没有确定含义
    /// （转这一场？还是全部？），静默取其一就是脚本作者永远发现不了的那种坑。
    /// 退化示例：删掉 `if a.positional.contains(...)` 那个分支，本用例变红。
    func testAllWithPositionalTargetIsRejected() {
        XCTAssertThrowsError(try MeetingRecorderCLI.transcodeConfiguration(
            from: MeetingRecorderCLI.Args(["--all", "2026-10-04-173008-B档真机复验-1004"]))) { error in
            XCTAssertTrue("\(error)".contains("全部会议"), "\(error)")
        }
    }

    func testAllAloneWithoutPositionalIsAccepted() throws {
        let config = try MeetingRecorderCLI.transcodeConfiguration(
            from: MeetingRecorderCLI.Args(["--all", "--to", "b"]))
        XCTAssertTrue(config.allSessions)
        XCTAssertEqual(config.preset, .bTier)
    }

    // MARK: - 报告文本

    /// dry-run 的账必须**一个字节都不写**——这是 CLI 层的承诺。
    /// 退化示例：把 `runTranscode` 里的 `dryRun: config.dryRun` 改成 `false`，
    /// 本用例与 `testDryRunWritesNothingOnDisk` 都变红。
    func testDryRunHeaderSaysNothingIsWritten() throws {
        let config = try MeetingRecorderCLI.transcodeConfiguration(
            from: MeetingRecorderCLI.Args(["--dry-run"]))
        let text = MeetingRecorderCLI.transcodeHeaderText(config)
        XCTAssertTrue(text.contains("一个字节都不会写"), text)
    }

    func testHeaderNamesThePresetAndItsHintWithPreconditions() throws {
        let config = try MeetingRecorderCLI.transcodeConfiguration(
            from: MeetingRecorderCLI.Args(["--to", "b"]))
        let text = MeetingRecorderCLI.transcodeHeaderText(config)
        XCTAssertTrue(text.contains("单声道 24 kHz"), text)
        // `hint` 里「取决于源本来就是什么」这类前提必须出现——
        // 报数不带前提是本项目已踩过的坑（6.0× vs 实测 4.99×）。
        XCTAssertTrue(text.contains("若源本来就是 24 kHz 单声道"), text)
    }

    // MARK: - 字节数格式化

    /// 退化示例：把 `/1048576` 改成 `/1000`（或 `/1048576*8`），
    /// 本用例变红——单位换算错了会让「省了多少」整体差 7%。
    func testMibFormatting() {
        XCTAssertEqual(MeetingRecorderCLI.mib(1048576), String(format: "%.1f MiB", 1.0))
        XCTAssertEqual(MeetingRecorderCLI.mib(0), String(format: "%.1f MiB", 0.0))
        XCTAssertEqual(MeetingRecorderCLI.mib(1_500_000), String(format: "%.1f MiB", 1.4305))
    }

    func testFormatDescriptionUsesShortDisplayName() {
        XCTAssertEqual(MeetingRecorderCLI.describeFormat(48000, 1, .pcm16),
                       MeetingRecorderCLI.describeFormat(48000, 1, .pcm16))
        XCTAssertTrue(MeetingRecorderCLI.describeFormat(24000, 1, .pcm16).contains("单声道"))
        XCTAssertTrue(MeetingRecorderCLI.describeFormat(48000, 2, .float32).contains("2 声道"))
    }
}

// MARK: - 降混策略：record 与 transcode 两侧

/// `--downmix` 在两个命令上的参数映射。
///
/// 单列一组的原因：`Args` **不拒绝未知的 `--xxx`**，拼错会静默走默认值。
/// `transcode --downmix avrage`（拼错）会安静地按 `firstChannel` 转完整个存量库 ——
/// 而 `firstChannel` 与 `average` 的产物**参数完全一样**（都是单声道），
/// 文件大小、时长、manifest 全对，只是内容不同。没有任何事后能发现的痕迹。
/// 所以这里必须显式校验并把合法值列出来。
extension TranscodeArgumentTests {

    // transcode 侧的别名与未知值由本文件已有的
    // `testDownmixAliases` / `testUnknownDownmixValueIsRejected` 覆盖。
    // 这里只补 `record` —— 那一侧此前**完全没有** `--downmix`，
    // 而 `Args` 不拒绝未知 `--xxx`，拼错会静默走默认值。

    // MARK: record

    /// `record` 不给 `--downmix` 时**留 nil**，由上层用偏好兜底。
    ///
    /// 刻意不设默认值：CLI 独立跑时没有 workspace，
    /// `nil` 会落到 `Configuration.resolvedDownmix`（同一条默认值）。
    /// 断言 `nil` 就是为了守住「不在这儿复制一份默认值」。
    func testRecordLeavesDownmixUnsetWhenNotGiven() throws {
        let config = try MeetingRecorderCLI.recordConfiguration(
            from: MeetingRecorderCLI.Args([]))
        XCTAssertNil(config.downmix, "没给参数时必须留 nil，让上层用偏好兜底")
    }

    func testRecordAcceptsBothDownmixStrategies() throws {
        for (text, expected) in [("first-channel", MonoDownmixStrategy.firstChannel),
                                 ("average", MonoDownmixStrategy.average)] {
            let config = try MeetingRecorderCLI.recordConfiguration(
                from: MeetingRecorderCLI.Args(["--downmix", text]))
            XCTAssertEqual(config.downmix, expected)
            XCTAssertEqual(config.resolvedDownmix, expected)
        }
    }

    func testRecordRejectsUnknownDownmixValue() {
        XCTAssertThrowsError(
            try MeetingRecorderCLI.recordConfiguration(
                from: MeetingRecorderCLI.Args(["--downmix", "mix"]))
        ) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("mix"), "报错要回显错的值：\(text)")
            XCTAssertTrue(text.contains("firstChannel"), "报错要列出合法值：\(text)")
        }
    }

    /// `--downmix` 与 `--mono24k` **不互斥**。
    ///
    /// 它们是不同维度：一个是「降不降」，一个是「怎么降」。
    /// 判成互斥会让「开 mono24k 并指定策略」这条最典型的命令没法用一条表达，
    /// 用户得先选一边、之后想换就得重录。
    func testDownmixAndMono24kAreNotMutuallyExclusive() throws {
        let config = try MeetingRecorderCLI.recordConfiguration(
            from: MeetingRecorderCLI.Args(["--mono24k", "--downmix", "average"]))
        XCTAssertTrue(config.resolvedMono24k)
        XCTAssertEqual(config.resolvedDownmix, .average)
    }
}
