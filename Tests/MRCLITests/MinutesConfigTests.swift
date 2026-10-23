import XCTest
@testable import MRCLI
import MRCore

/// 会议纪要配置在 CLI 侧的行为。
///
/// 测的全是**纯函数**：`configShowLines`（打印的每一行）、
/// `minutesCloudSetupHint`（补配指引）、`makeMinutesGenerator`（注入偏好域）。
/// 理由与既有纪律一致：`runConfig` 直接往 stdout `print`，测试既不好捕获输出、
/// 也不该碰跑测试进程的真实偏好域——「哪一行写了什么」必须能被断言。
final class MinutesConfigTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "mr-minutes-cli-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    private func prefs() -> RecorderPreferences {
        RecorderPreferences(defaults: defaults)
    }

    /// 找「纪要模型：」那一行。找不到返回空串——断言会以「不包含」的形式失败，
    // 但报错信息要说清楚是哪一行不存在。
    private func minutesLine(_ lines: [String]) -> String {
        lines.first { $0.contains("纪要模型：") } ?? "<没有纪要模型行>"
    }

    private func keyLine(_ lines: [String]) -> String {
        lines.first { $0.contains("纪要 API 密钥：") } ?? "<没有密钥行>"
    }

    // MARK: - config show

    /// 默认（没配过）= local，且说清「录音不出本机」。
    func test_showLines_defaultToLocal() {
        let lines = MeetingRecorderCLI.configShowLines(prefs: prefs())
        XCTAssertTrue(minutesLine(lines).contains("local"), "：\(minutesLine(lines))")
        XCTAssertTrue(minutesLine(lines).contains("本地 FoundationModels"))
    }

    /// 云端配齐：显示模型名与主机，密钥只露打码值。
    func test_showLines_cloudConfigured_masksKey() {
        let p = prefs()
        p.minutesProvider = .cloudAPI
        p.minutesAPIBaseURL = "https://api.deepseek.com/v1"
        p.minutesAPIKey = "sk-1234567890abcdef"
        p.minutesModel = "deepseek-chat"

        let lines = MeetingRecorderCLI.configShowLines(prefs: prefs())
        let model = minutesLine(lines)
        XCTAssertTrue(model.contains("api"), "：\(model)")
        XCTAssertTrue(model.contains("deepseek-chat"), "模型名要显示：\(model)")
        XCTAssertTrue(model.contains("api.deepseek.com"), "主机要显示：\(model)")

        let key = keyLine(lines)
        XCTAssertTrue(key.contains("sk-…cdef"), "密钥只露打码值：\(key)")
        // **绝不出现明文**。这一条是硬底线：config show 的输出会被贴进
        //  issue、聊天窗口、日志——明文密钥出现在任何一处都等于泄露。
        XCTAssertFalse(key.contains("1234567890ab"), "密钥中段绝不出现：\(key)")
        XCTAssertFalse(lines.joined().contains("sk-1234567890abcdef"),
                       "任何一行都不得包含密钥明文")
    }

    /// 云端没配齐：**显式列出缺什么**。显示成光秃秃一个「api」
    /// 会让用户以为配好了，而第一次 minutes 才报错。
    func test_showLines_cloudIncomplete_saysWhatsMissing() {
        let p = prefs()
        p.minutesProvider = .cloudAPI
        p.minutesAPIKey = "sk-abc"

        let lines = MeetingRecorderCLI.configShowLines(prefs: prefs())
        let model = minutesLine(lines)
        XCTAssertTrue(model.contains("未配齐"), "：\(model)")
        XCTAssertTrue(model.contains("Base URL"), "要列出缺项：\(model)")
        XCTAssertTrue(model.contains("模型名"), "要列出缺项：\(model)")
        XCTAssertFalse(model.contains("API Key"), "已设的项不该列为缺失：\(model)")
    }

    // MARK: - 生成器选择

    /// 云端没配齐 → 抛错，且错误里带命令。**不返回本地生成器**——
    /// 用户选了云端却拿到本地产出，是署名不同的谎报。
    func test_makeGenerator_blocksWhenCloudIncomplete() {
        let p = prefs()
        p.minutesProvider = .cloudAPI
        p.minutesAPIKey = "sk-abc"

        XCTAssertThrowsError(try MeetingRecorderCLI.makeMinutesGenerator(preferences: p)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("Base URL"), "错误要说缺什么：\(message)")
            XCTAssertTrue(message.contains("config set minutes-url"),
                          "错误要带要敲的命令：\(message)")
        }
    }

    /// 云端配齐 → 云端生成器（displayName 带模型名与主机）。
    func test_makeGenerator_usesCloudWhenComplete() throws {
        let p = prefs()
        p.minutesProvider = .cloudAPI
        p.minutesAPIBaseURL = "https://api.deepseek.com/v1"
        p.minutesAPIKey = "sk-abc"
        p.minutesModel = "deepseek-chat"

        let generator = try MeetingRecorderCLI.makeMinutesGenerator(preferences: p)
        XCTAssertTrue(generator.displayName.contains("deepseek-chat"),
                      "：\(generator.displayName)")
        XCTAssertTrue(generator.displayName.contains("api.deepseek.com"))
    }

    /// 默认 → 本地生成器，绝不抛错（本机不支持 Apple Intelligence 时它是
    /// isAvailable == false 的本地实现，由 orchestrator 走降级——那是既有行为）。
    func test_makeGenerator_defaultsToLocalWithoutThrowing() {
        XCTAssertNoThrow(try MeetingRecorderCLI.makeMinutesGenerator(preferences: prefs()))
    }

    // MARK: - 补配指引

    /// 缺什么列什么，每条命令带示例值——只说「缺 Base URL」的话，
    /// 用户还得去猜那一层填到哪儿（含不含 /v1 是真实卡过点的地方）。
    func test_setupHint_listsCommandsForMissingItems() {
        // `all` 是**行数组**，`contains` 在这里是元素相等不是子串包含——
        // 先拼成一整段再断言，否则「行里含有这句」永远为假。
        let all = MeetingRecorderCLI.minutesCloudSetupHint(
            missing: ["Base URL", "API Key", "模型名"]).joined(separator: "\n")
        XCTAssertTrue(all.contains("config set minutes-url"))
        XCTAssertTrue(all.contains("config set minutes-key"))
        XCTAssertTrue(all.contains("config set minutes-model"))
        XCTAssertTrue(all.contains("https://api.deepseek.com/v1"), "URL 要带示例值")

        let onlyKey = MeetingRecorderCLI.minutesCloudSetupHint(missing: ["API Key"])
            .joined(separator: "\n")
        XCTAssertTrue(onlyKey.contains("config set minutes-key"))
        XCTAssertFalse(onlyKey.contains("minutes-url"), "不缺的项不该列")
    }

    // MARK: - 用法文本

    /// 四个新命令必须写进用法文本——「文档里有、命令不存在」和
    /// 「命令存在、帮助里找不到」是同一种漂移的两半。
    func test_usageText_documentsMinutesConfig() {
        let usage = MeetingRecorderCLI.usageText()
        XCTAssertTrue(usage.contains("config set minutes "))
        XCTAssertTrue(usage.contains("minutes-url"))
        XCTAssertTrue(usage.contains("minutes-key"))
        XCTAssertTrue(usage.contains("minutes-model"))
        XCTAssertTrue(usage.contains("config unset"))
    }

    // MARK: - 菜单栏图标开关

    /// `config show` 里必须有一行说清图标此刻显不显示。
    /// 默认（没设过）写「显示」——写「隐藏」会让用户以为图标已经没了，
    /// 跑去到处找原因，而真正的默认值恰恰是显示的。
    func test_showLines_statusIconDefaultsToShown() {
        let lines = MeetingRecorderCLI.configShowLines(prefs: prefs())
        let line = lines.first { $0.contains("菜单栏图标：") } ?? "<没有菜单栏图标行>"
        XCTAssertTrue(line.contains("显示"), "：\(line)")
        XCTAssertFalse(line.contains("隐藏"), "没设过时必须写显示：\(line)")
    }

    /// 关掉之后那一行要变成「隐藏」——只写不读的实现在这里露馅。
    func test_showLines_statusIconReflectsTheSetting() {
        let p = prefs()
        p.showsStatusBarIcon = false

        let line = MeetingRecorderCLI.configShowLines(prefs: prefs())
            .first { $0.contains("菜单栏图标：") } ?? "<没有菜单栏图标行>"
        XCTAssertTrue(line.contains("隐藏"), "：\(line)")
    }

    /// 用法文本必须写这个键——「命令存在、帮助里找不到」会让用户
    /// 以为只能去 GUI 里改，而 CLI 这条路本来就在。
    func test_usageText_documentsStatusIconConfig() {
        let usage = MeetingRecorderCLI.usageText()
        XCTAssertTrue(usage.contains("config set status-icon on|off"))
        XCTAssertTrue(usage.contains("config set status-icon"))
    }
}
