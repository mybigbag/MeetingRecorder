import XCTest
@testable import MRCore

/// 会议纪要配置项（本地 / 云端 API 四件套）的落盘。
///
/// 这一层测的不是「UserDefaults 转发能不能用」，而是三条**默认值即规格**：
/// 1. 默认必须是 `local`——升级一次应用就悄悄把默认换成「把录音传到云上」
///    是那种「没人发现、发现了也追溯不回来」的改动；
/// 2. 读一次偏好不该把键写下来（否则默认值的断言第二次跑不成立）；
/// 3. 存了不认识的值必须回退 `local`，绝不能静默选中云端那一档。
final class MinutesPreferencesTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "mr-minutes-prefs-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    // MARK: - 提供商

    /// 全新安装默认本地，且读不写键。
    func testMinutesProviderDefaultsToLocalWithoutWriting() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        XCTAssertEqual(prefs.minutesProvider, .local, "默认必须是本地模型")
        XCTAssertNil(
            defaults.object(forKey: RecorderPreferences.minutesProviderKey),
            "读一次偏好不该顺手把它写下来")
    }

    func testMinutesProviderIsPersistedAndSurvivesANewInstance() throws {
        RecorderPreferences(defaults: defaults).minutesProvider = .cloudAPI
        XCTAssertEqual(
            defaults.string(forKey: RecorderPreferences.minutesProviderKey),
            MinutesProvider.cloudAPI.rawValue)
        XCTAssertEqual(
            RecorderPreferences(defaults: defaults).minutesProvider, .cloudAPI)
    }

    func testMinutesProviderCanBeSetBackToLocal() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.minutesProvider = .cloudAPI
        prefs.minutesProvider = .local
        XCTAssertEqual(prefs.minutesProvider, .local)
        XCTAssertEqual(RecorderPreferences(defaults: defaults).minutesProvider, .local)
    }

    /// 不认识的値回退本地——绝不能因为一个坏键就把转写稿传到云上。
    func testUnknownMinutesProviderFallsBackToLocal() throws {
        defaults.set("openai", forKey: RecorderPreferences.minutesProviderKey)
        XCTAssertEqual(RecorderPreferences(defaults: defaults).minutesProvider, .local)

        defaults.set("API", forKey: RecorderPreferences.minutesProviderKey)  // 大小写不匹配
        XCTAssertEqual(RecorderPreferences(defaults: defaults).minutesProvider, .local)
    }

    // MARK: - 三个字符串配置项

    /// 空串 / 纯空白 = 未设置。界面里清空输入框必须真的清掉，
    /// 而不是留下一个「看起来配了、跑起来报错」的空白键。
    func testBlankStringsAreTreatedAsUnset() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.minutesAPIBaseURL = "https://api.deepseek.com/v1"
        XCTAssertEqual(prefs.minutesAPIBaseURL, "https://api.deepseek.com/v1")

        prefs.minutesAPIBaseURL = "   "
        XCTAssertNil(prefs.minutesAPIBaseURL)
        XCTAssertNil(defaults.string(forKey: RecorderPreferences.minutesAPIBaseURLKey),
                     "空白值必须移除键，而不是存一个空串")

        prefs.minutesAPIKey = "sk-test"
        prefs.minutesAPIKey = ""
        XCTAssertNil(prefs.minutesAPIKey)

        prefs.minutesModel = "deepseek-chat"
        prefs.minutesModel = ""
        XCTAssertNil(prefs.minutesModel)
    }

    /// 存的时候去首尾空白——用户从网页复制配置时带上换行太常见了。
    func testValuesAreTrimmedOnWrite() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.minutesAPIBaseURL = "  https://api.deepseek.com/v1\n"
        prefs.minutesAPIKey = "  sk-abc  "
        prefs.minutesModel = " deepseek-chat "

        XCTAssertEqual(prefs.minutesAPIBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(prefs.minutesAPIKey, "sk-abc")
        XCTAssertEqual(prefs.minutesModel, "deepseek-chat")
    }

    func testCloudAPIConfigurationSurvivesANewInstance() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.minutesAPIBaseURL = "https://api.deepseek.com/v1"
        prefs.minutesAPIKey = "sk-abc123"
        prefs.minutesModel = "deepseek-chat"

        let reloaded = RecorderPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.minutesAPIBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(reloaded.minutesAPIKey, "sk-abc123")
        XCTAssertEqual(reloaded.minutesModel, "deepseek-chat")
        XCTAssertTrue(reloaded.minutesCloudAPIIsComplete)
    }

    /// 三个键互不串键。判据是逐个开、逐步验其余两个——
    /// 只断言「键名不同」对常量几乎永真，接错了照样全绿。
    func testTheThreeCloudKeysDoNotInterfere() throws {
        let prefs = RecorderPreferences(defaults: defaults)

        prefs.minutesAPIBaseURL = "https://api.deepseek.com/v1"
        XCTAssertNil(prefs.minutesAPIKey, "设 URL 不该顺手设上 Key")
        XCTAssertNil(prefs.minutesModel, "设 URL 不该顺手设上模型名")

        prefs.minutesAPIKey = "sk-abc123"
        XCTAssertEqual(prefs.minutesAPIBaseURL, "https://api.deepseek.com/v1")
        XCTAssertNil(prefs.minutesModel, "设 Key 不该把模型名挤掉")

        prefs.minutesModel = "deepseek-chat"
        XCTAssertEqual(prefs.minutesAPIBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(prefs.minutesAPIKey, "sk-abc123")

        XCTAssertEqual(
            Set([
                RecorderPreferences.minutesAPIBaseURLKey,
                RecorderPreferences.minutesAPIKeyKey,
                RecorderPreferences.minutesModelKey,
            ]).count, 3, "三个键名必须互不相同")
    }

    // MARK: - 齐全度与打码

    func testMissingItemsListsExactlyWhatIsAbsent() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        XCTAssertEqual(prefs.missingMinutesCloudAPIItems(),
                       ["Base URL", "API Key", "模型名"],
                       "全新安装时三项全缺")
        XCTAssertFalse(prefs.minutesCloudAPIIsComplete)

        prefs.minutesAPIKey = "sk-abc123"
        XCTAssertEqual(prefs.missingMinutesCloudAPIItems(), ["Base URL", "模型名"])

        prefs.minutesAPIBaseURL = "https://api.deepseek.com/v1"
        XCTAssertEqual(prefs.missingMinutesCloudAPIItems(), ["模型名"])

        prefs.minutesModel = "deepseek-chat"
        XCTAssertEqual(prefs.missingMinutesCloudAPIItems(), [])
        XCTAssertTrue(prefs.minutesCloudAPIIsComplete)
    }

    /// 打码必须**遮住中间**。保留头尾只为让用户认出「是不是那一把」，
    /// 多露一个字符都是把密钥往日志里送。
    func testMaskedKeyHidesTheMiddle() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        XCTAssertEqual(prefs.maskedMinutesAPIKey, "未设置")

        prefs.minutesAPIKey = "sk-1234567890abcdef"
        let masked = prefs.maskedMinutesAPIKey
        XCTAssertTrue(masked.hasPrefix("sk-"), "保留头部，便于认出是哪一把")
        XCTAssertTrue(masked.hasSuffix("cdef（已设置）"), "保留尾部")
        XCTAssertFalse(masked.contains("1234567890ab"), "中间必须遮住")

        // 短密钥全遮：那种长度下保留头尾等于没遮
        prefs.minutesAPIKey = "short"
        XCTAssertEqual(prefs.maskedMinutesAPIKey, "•••••")
        XCTAssertFalse(prefs.maskedMinutesAPIKey.contains("h"), "短密钥一个字符都不能露")
    }

    func testClearRemovesEverything() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.minutesAPIBaseURL = "https://api.deepseek.com/v1"
        prefs.minutesAPIKey = "sk-abc123"
        prefs.minutesModel = "deepseek-chat"

        prefs.clearMinutesCloudAPIConfiguration()

        XCTAssertNil(prefs.minutesAPIBaseURL)
        XCTAssertNil(prefs.minutesAPIKey)
        XCTAssertNil(prefs.minutesModel)
        XCTAssertFalse(prefs.minutesAPIKeyIsSet)
        XCTAssertFalse(prefs.minutesCloudAPIIsComplete)
    }
}
