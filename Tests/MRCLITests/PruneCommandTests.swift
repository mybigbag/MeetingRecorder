import XCTest
@testable import MRCLI
@testable import MRSession
import MRCore
import Foundation

/// `mr prune` 的参数 → 行为映射，以及「默认不删东西」这件事。
///
/// 这一组测的不是「参数怎么解析」而是**三件在删数据的命令上才成立的事**：
///
/// 1. **默认是预演，不是执行。** `prune` 是个短到会顺手敲的命令，
///    缺 `--yes` 就执行的话，一次手滑就没了。
/// 2. **拼错一律报错，不猜。** 猜错的方向是不对称的：猜成「关」用户以为设了档位，
///    猜成「30 天」则直接开始删。
/// 3. **`--days` 不落盘。** 一次性覆盖与长期设置必须分开，否则
///    「我试着清一次」会把设置改掉。
final class PruneCommandTests: XCTestCase {

    private func config(_ args: [String]) throws -> MeetingRecorderCLI.PruneConfiguration {
        try MeetingRecorderCLI.pruneConfiguration(from: MeetingRecorderCLI.Args(args))
    }

    // MARK: - 默认值

    /// 默认三项全false：**不覆盖、不执行、不含无稿场次**。
    func testDefaultsAreAllOff() throws {
        let c = try config([])
        XCTAssertNil(c.daysOverride)
        XCTAssertFalse(c.yes)
        XCTAssertFalse(c.dryRun)
        XCTAssertFalse(c.includeUntranscribed,
                       "默认不能碰没转写过的会议")
    }

    // MARK: - --days

    /// 只接受四个产品档位。`--days 60` 静默跑起来的话，用户以为在试一个数，
    /// 而界面上永远不会有「60 天」这一档。
    func testDaysAcceptsOnlyTheProductTiers() throws {
        for n in RetentionPolicy.selectableDayCounts {
            XCTAssertEqual(try config(["--days", String(n)]).daysOverride, n)
        }
    }

    func testDaysRejectsAnythingElseWithTheLegalListInTheMessage() {
        for bad in ["60", "0", "-7", "abc", ""] {
            XCTAssertThrowsError(try config(["--days", bad]), "--days \(bad)") { error in
                let text = "\(error)"
                XCTAssertTrue(text.contains("7"), "报错要列出合法值：\(text)")
                XCTAssertTrue(text.contains("90"), "报错要列出合法值：\(text)")
            }
        }
    }

    /// `--days` 后面缺值必须报错，不是静默走偏好。
    ///
    /// 第一次写成 `config(["--days"])` 时它是绿的——`Args` 把这种形态记成 flag，
    /// `value("days")` 返回 nil，于是代码路径与「用户压根没写 `--days`」完全一样，
    /// 悄悄用了偏好里的档位。对一条会删数据的命令，静默降级比报错糟得多：
    /// 用户以为在按 30 天清，实际按的是偏好里那个数（可能是 90）。
    func testDaysWithoutValueIsRejected() {
        XCTAssertThrowsError(try config(["--days"])) { error in
            XCTAssertTrue("\(error)".contains("缺天数"), "报错要说清是缺值：\(error)")
        }
    }

    /// `--dry-run` 后面跟一个值不该被当成「缺值」——
    /// 它是 flag，`Args` 的读法对它本来就成立。
    func testDryRunFollowedByAPositionalIsNotMistakenForMissingValue() throws {
        let c = try config(["--dry-run", "--days", "30"])
        XCTAssertTrue(c.dryRun)
        XCTAssertEqual(c.daysOverride, 30)
    }

    // MARK: - 档位解析（含 M-D11 的覆盖）

    /// `--days` 覆盖之后**偏好必须一个字节都没变**。
    ///
    /// M-D11 第一次零命中，就是因为只有 `pruneHeaderText` 那条文本断言在守着，
    /// 而它压根读不到偏好。变异把 `--days` 改成顺手落盘时，测试全绿——
    /// 「我试着清一次」会把长期设置也改掉，而这条路径上一条断言都没有。
    /// 现在把「解析结果」单独抽成 `resolvePrunePolicy` 并断言偏好未变，才算真的钉住。
    func testDaysOverrideDoesNotPersistToPreferences() throws {
        let suite = "mr-cli-days-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("拿不到独立 suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.retentionPolicy = .days(90)

        var c = MeetingRecorderCLI.PruneConfiguration()
        c.daysOverride = 30
        let policy = try MeetingRecorderCLI.resolvePrunePolicy(prefs: prefs, config: c)

        XCTAssertEqual(policy, .days(30), "本次执行按 30 天走")
        XCTAssertEqual(prefs.retentionPolicy, .days(90),
                       "一次性覆盖不该改长期设置——否则「我试着清一次」就把设置改了")
    }

    /// 没给 `--days` 时按偏好走，且同样不写偏好。
    func testWithoutDaysOverrideThePreferenceIsUsedAndLeftAlone() throws {
        let suite = "mr-cli-nodays-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("拿不到独立 suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.retentionPolicy = .days(7)

        let policy = try MeetingRecorderCLI.resolvePrunePolicy(
            prefs: prefs, config: MeetingRecorderCLI.PruneConfiguration())

        XCTAssertEqual(policy, .days(7))
        XCTAssertEqual(prefs.retentionPolicy, .days(7))
    }

    /// **坏键必须让执行拒绝**，而不是当成「关」照常跑。
    ///
    /// 这是 M-D9 在执行侧的落点：偏好层已经不再回退（`RetentionPolicyTests`
    /// 钉住了），所以拒绝执行的义务落在这个函数上。两处都要有断言——
    /// 少任何一处，坏键都会变成静默的行为。
    func testUnrecognizedStoredPolicyIsRefusedBeforeAnythingRuns() throws {
        let suite = "mr-cli-refuse-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("拿不到独立 suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("60", forKey: RecorderPreferences.retentionPolicyKey)
        let prefs = RecorderPreferences(defaults: defaults)

        XCTAssertThrowsError(try MeetingRecorderCLI.resolvePrunePolicy(
            prefs: prefs, config: MeetingRecorderCLI.PruneConfiguration())) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("已拒绝执行"),
                          "报错必须明说「已拒绝执行」：\(text)")
            XCTAssertTrue(text.contains("一个文件都没删"))
        }
    }

    /// 但 `--days` 能**绕开**坏键：它显式指定了这一次用什么档位，
    /// 坏键与本次执行无关。这时候报错反而是刁难。
    func testDaysOverrideBypassesAnUnrecognizedStoredPolicy() throws {
        let suite = "mr-cli-bypass-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("拿不到独立 suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("60", forKey: RecorderPreferences.retentionPolicyKey)
        let prefs = RecorderPreferences(defaults: defaults)

        var c = MeetingRecorderCLI.PruneConfiguration()
        c.daysOverride = 30

        XCTAssertEqual(try MeetingRecorderCLI.resolvePrunePolicy(prefs: prefs, config: c),
                       .days(30))
    }

    // MARK: - 开关

    func testSwitchesAreRecognised() throws {
        XCTAssertTrue(try config(["--yes"]).yes)
        XCTAssertTrue(try config(["--y"]).yes)
        XCTAssertTrue(try config(["--dry-run"]).dryRun)
        XCTAssertTrue(try config(["--plan"]).dryRun)
        XCTAssertTrue(try config(["--include-untranscribed"]).includeUntranscribed)
    }

    /// 三个开关可以自由组合，没有互斥关系。
    func testSwitchesCompose() throws {
        let c = try config(["--days", "30", "--yes", "--dry-run", "--include-untranscribed"])
        XCTAssertEqual(c.daysOverride, 30)
        XCTAssertTrue(c.yes)
        XCTAssertTrue(c.dryRun)
        XCTAssertTrue(c.includeUntranscribed)
    }

    // MARK: - 头部文本

    /// 预演模式必须在输出里明说「一个文件都不会被删」。
    ///
    /// 这是这条命令最重要的行为，而它只体现在输出里——
    /// 不抽成纯函数就只能靠人眼扫，而人眼扫过的次数在这个项目里
    /// 已经错过东西了（见 `MeetingRecorderCLI.trackLevelLine` 的乱码事故）。
    func testDryRunHeaderSaysNothingWillBeDeleted() {
        let text = MeetingRecorderCLI.pruneHeaderText(
            policy: .days(30), config: MeetingRecorderCLI.PruneConfiguration(), executing: false)
        XCTAssertTrue(text.contains("预演"))
        XCTAssertTrue(text.contains("一个文件都不会被删"))
        XCTAssertFalse(text.contains("模式：**执行**"))
    }

    func testExecutingHeaderSaysItGoesToTheTrash() {
        var c = MeetingRecorderCLI.PruneConfiguration()
        c.yes = true
        let text = MeetingRecorderCLI.pruneHeaderText(policy: .days(30), config: c, executing: true)
        XCTAssertTrue(text.contains("执行"))
        XCTAssertTrue(text.contains("废纸篓"))
    }

    /// `--days` 覆盖要在输出里说清它**不改变设置**——
    /// 否则用户以为自己在改偏好。
    func testHeaderStatesTheDaysOverrideDoesNotPersist() {
        var c = MeetingRecorderCLI.PruneConfiguration()
        c.daysOverride = 30
        let text = MeetingRecorderCLI.pruneHeaderText(policy: .days(30), config: c,
                                                      executing: false)
        XCTAssertTrue(text.contains("不改变设置"))
    }

    // MARK: - config get/set retention

    func testGetRetentionPrintsAResolvableValue() {
        let suite = "mr-cli-retention-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("拿不到独立 suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = RecorderPreferences(defaults: defaults)

        for p in RetentionPolicy.selectableCases {
            prefs.retentionPolicy = p
            XCTAssertEqual(RecorderPreferences(defaults: defaults)
                .resolvedRetentionPolicy().rawValue, p.rawValue)
        }
    }

    /// `config show` 里要有保留策略那一行，且**不挤掉既有的四行**。
    func testConfigShowIncludesRetentionWithoutDroppingExistingLines() {
        let suite = "mr-cli-show-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("拿不到独立 suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = RecorderPreferences(defaults: defaults)

        let lines = MeetingRecorderCLI.configShowLines(prefs: prefs)

        XCTAssertTrue(lines.contains { $0.contains("转写引擎") })
        XCTAssertTrue(lines.contains { $0.contains("静默录制") })
        XCTAssertTrue(lines.contains { $0.contains("16 位录音") })
        XCTAssertTrue(lines.contains { $0.contains("单声道 24 kHz") })
        XCTAssertTrue(lines.contains { $0.contains("降混策略") })
        let retentionLine = lines.first { $0.contains("保留策略") }
        XCTAssertNotNil(retentionLine, "config show 里必须有保留策略那一行")
        XCTAssertTrue(retentionLine?.contains("off") ?? false,
                      "默认档位应当显示为 off")
    }

    /// **坏键必须被单独说出来。** 显示成「关」会让用户以为「我设了一个月」
    /// 而实际什么都没删——那正是这条命令最需要避免的误读。
    func testConfigShowFlagsAnUnrecognizedRetentionValue() {
        let suite = "mr-cli-badkey-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("拿不到独立 suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("60", forKey: RecorderPreferences.retentionPolicyKey)

        let lines = MeetingRecorderCLI.configShowLines(prefs: RecorderPreferences(defaults: defaults))

        let line = lines.first { $0.contains("保留策略") } ?? ""
        XCTAssertTrue(line.contains("已拒绝执行"),
                      "坏键必须在 config show 里明说「清理已拒绝执行」：\(line)")
    }

    // MARK: - 帮助

    /// 用法文本里必须有 `prune` 与 `config set retention`——
    /// 一个会删数据的命令如果不在帮助里出现，等于没有。
    func testUsageMentionsPruneAndRetentionConfig() {
        let usage = MeetingRecorderCLI.usageText()
        XCTAssertTrue(usage.contains("meeting-recorder prune"))
        XCTAssertTrue(usage.contains("config set retention"))
        XCTAssertTrue(usage.contains("--include-untranscribed"))
    }

    /// 帮助里必须点明「唯一会删用户数据」与「设档位不删东西」这两件事。
    func testUsageWarnsAboutDeletionAndAboutPersistence() {
        let usage = MeetingRecorderCLI.usageText()
        XCTAssertTrue(usage.contains("唯一会删用户数据"))
        XCTAssertTrue(usage.contains("不会删掉任何文件"),
                      "帮助必须说清「设档位」这一步不删东西——否则用户会以为设了就清了")
    }

    // MARK: - autoprune（自动清理）

    /// 自动清理是**单独一次授权**，帮助里必须出现它。
    ///
    /// 少了这一段，用户从「设了 30 天但没人来清」的现象出发，
    /// 在帮助里找不到任何自动化的入口——那条路现在是有的。
    func testUsageMentionsAutoPruneAsASeparateOptIn() {
        let usage = MeetingRecorderCLI.usageText()
        XCTAssertTrue(usage.contains("config set autoprune"),
                      "帮助里必须有自动清理的开关：\(usage)")
        XCTAssertTrue(usage.contains("默认 off"),
                      "必须写明自动清理默认关——它会在用户不在场时删数据")
    }

    /// `config show` 里必须能一眼看出「自动清理是关的」。
    func testConfigShowReportsAutoPrune() {
        let suite = "mr-cli-autoprune-show-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("拿不到独立 suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let lines = MeetingRecorderCLI.configShowLines(
            prefs: RecorderPreferences(defaults: defaults))

        let line = lines.first { $0.contains("自动清理") }
        XCTAssertNotNil(line, "config show 里必须有自动清理那一行")
        XCTAssertTrue(line?.contains("关") ?? false, "默认应当显示为关：\(line ?? "")")
    }

    /// 开了自动清理但档位清不了东西时，`config show` 要点出来。
    ///
    /// 否则用户会以为「我开了自动清理，怎么什么都没发生」——
    /// 而真实原因是档位还是关闭。这两件事在界面上长得一模一样。
    func testConfigShowWarnsWhenAutoPruneIsOnButThePolicyDeletesNothing() {
        let suite = "mr-cli-autoprune-warn-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("拿不到独立 suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.autoPruneEnabled = true

        let lines = MeetingRecorderCLI.configShowLines(prefs: prefs)

        let line = lines.first { $0.contains("自动清理") } ?? ""
        XCTAssertTrue(line.contains("⚠️"),
                      "开了自动清理但档位关闭时必须提示：\(line)")
    }

    /// 两个都设好时不该再报那个警告。
    func testConfigShowIsQuietWhenAutoPruneIsFullyConfigured() {
        let suite = "mr-cli-autoprune-ok-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("拿不到独立 suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.autoPruneEnabled = true
        prefs.retentionPolicy = .days(30)

        let line = MeetingRecorderCLI.configShowLines(prefs: prefs)
            .first { $0.contains("自动清理") } ?? ""
        XCTAssertFalse(line.contains("⚠️"), line)
        XCTAssertTrue(line.contains("开"), line)
    }

    /// `--help` 必须被认出来。
    func testHelpIsRecognisedForPrune() {
        XCTAssertTrue(MeetingRecorderCLI.wantsHelp(["prune", "--help"]))
        XCTAssertTrue(MeetingRecorderCLI.wantsHelp(["prune", "-h"]))
    }
}