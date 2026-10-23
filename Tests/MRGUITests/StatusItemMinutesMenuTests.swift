import XCTest
import AppKit
import MRCore
@testable import MRGUI
import MRSession

/// 状态栏菜单里的「会议纪要」单选：本地 / 云端 API。
///
/// 为什么单独钉一组：这个入口是 2026-10-19 补的——此前纪要配置只存在于
/// 主窗口顶栏的 popover，而「用户翻遍菜单找不到纪要」正是当时报的症状
/// （功能上线了，入口却只有一处，且是最不可能被找到的那处）。这里钉住三件事：
/// 菜单里找得到、点得动（target/action 接对）、勾选与标题跟偏好走。
///
/// 与「转写引擎」那组同构：菜单每次弹出前重建，所以所有状态必须在
/// `menuNeedsUpdate` 里现读 `workspace`，而不是建菜单时抄一份。
@MainActor
final class StatusItemMinutesMenuTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var workspace: MeetingWorkspace!
    private var controller: StatusItemController!
    /// 「打开设置补全配置…」点没被点过。菜单里没法输入密钥，
    /// 这一项是云端缺项时唯一的出路，必须真的接上。
    private var didAskToShowWindow = false
    /// 同上，送去的是**设置窗口**（2026-10-22 起）。
    private var didAskToShowSettings = false

    override func setUp() async throws {
        _ = NSApplication.shared

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-minutes-menu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 偏好跑在自己的 suite 里，绝不碰 `.standard`：写进去会跨用例残留，
        // 「默认是本地」这种断言第二次跑就不成立。
        suiteName = "mr-minutes-menu-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        workspace = MeetingWorkspace(
            root: root, preferences: RecorderPreferences(defaults: defaults))
        didAskToShowWindow = false
        didAskToShowSettings = false
        controller = StatusItemController(
            workspace: workspace, hotKeyFailures: [],
            onShowWindow: { [weak self] in self?.didAskToShowWindow = true },
            onShowSettings: { [weak self] in self?.didAskToShowSettings = true })
    }

    override func tearDown() async throws {
        controller = nil
        workspace = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    // MARK: - 入口存在性与默认态

    /// 「录音设置」里必须有「会议纪要」入口，且默认勾本地。
    ///
    /// 默认态是隐私立场：会议录音是最敏感的数据，把转写稿送到第三方服务器
    /// 必须是用户显式点头的结果。默认勾云端等于替用户做了这个决定。
    func testMinutesEntryExistsUnderRecordingSettingsWithLocalChecked() {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        let entry = mrFindMenuItem(
            in: menu, titleHasPrefix: "\(StatusItemController.minutesMenuTitle)：")
        XCTAssertNotNil(entry,
            "「录音设置」里必须有纪要入口，实际只有：\(mrFlattenMenuTitles(menu))")
        XCTAssertEqual(entry?.title, "会议纪要：本地 FoundationModels",
                       "默认本地，且标题要写出当前取值")

        let local = mrFindMenuItem(in: menu, title: MinutesProvider.local.displayName)
        let cloud = mrFindMenuItem(in: menu, title: MinutesProvider.cloudAPI.displayName)
        XCTAssertEqual(local?.state, .on, "默认勾本地")
        XCTAssertEqual(cloud?.state, .off, "云端默认不勾")
    }

    // MARK: - 点击切换（走真实 target/action）

    /// 点「云端模型 API」要真的改偏好——不是把属性直接设成 .cloudAPI。
    /// 后者证明不了菜单项接对了，「点了没反应」正是这里唯一会坏的形态。
    func testClickingCloudAPISwitchesProviderAndChecksIt() throws {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let cloud = try XCTUnwrap(
            mrFindMenuItem(in: menu, title: MinutesProvider.cloudAPI.displayName))
        let action = try XCTUnwrap(cloud.action, "云端项没有接动作")
        XCTAssertNotNil(cloud.target, "云端项没有 target，点了不会有反应")

        _ = NSApp.sendAction(action, to: cloud.target, from: cloud)
        XCTAssertEqual(workspace.minutesProvider, .cloudAPI)

        // 菜单每次弹出前重建：重新走一遍，勾选必须现读偏好
        let reopened = NSMenu()
        controller.menuNeedsUpdate(reopened)
        XCTAssertEqual(
            mrFindMenuItem(in: reopened, title: MinutesProvider.cloudAPI.displayName)?.state,
            .on, "切到云端之后菜单上必须勾上")
        XCTAssertEqual(
            mrFindMenuItem(in: reopened, title: MinutesProvider.local.displayName)?.state,
            .off, "单选：勾了云端就不能同时勾本地")
    }

    /// 从云端点回本地：隐私回退路径必须通。
    func testClickingBackToLocalRevertsProvider() throws {
        workspace.minutesProvider = .cloudAPI
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let local = try XCTUnwrap(
            mrFindMenuItem(in: menu, title: MinutesProvider.local.displayName))

        _ = NSApp.sendAction(try XCTUnwrap(local.action), to: local.target, from: local)
        XCTAssertEqual(workspace.minutesProvider, .local,
                       "改主意选回本地必须生效——云端是 opt-in，回头也必须是 opt-out")
    }

    /// 历史遗留 / 陌生值回退本地，绝不静默选中会把数据传出本机的那一档。
    func testUnknownProviderValueFallsBackToLocal() throws {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let cloud = try XCTUnwrap(
            mrFindMenuItem(in: menu, title: MinutesProvider.cloudAPI.displayName))
        // 把真实菜单项的 representedObject 换成坏值再点，走的是与用户
        // 完全相同的那条派发路径（不需要引用私有 selector——`private`
        // 符号在 `@testable` 下也不可见）。
        cloud.representedObject = "cloudapi-typo"

        _ = NSApp.sendAction(try XCTUnwrap(cloud.action), to: cloud.target, from: cloud)
        XCTAssertEqual(workspace.minutesProvider, .local,
                       "陌生值必须回退本地，不能静默选中会把数据传出本机的那一档")
    }

    // MARK: - 缺项提示与引导

    /// 选了云端但没配齐：标题当场写「还缺 X」，并给出直达动作。
    ///
    /// 只显示「云端模型 API」的话，用户选完去跑 `minutes` 才报错——
    /// 那感觉像「刚配好又坏了」，而缺什么本来当场就能说。
    func testCloudEntryTitleShowsMissingItemsUntilComplete() {
        workspace.minutesProvider = .cloudAPI
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        let entry = mrFindMenuItem(
            in: menu, titleHasPrefix: "\(StatusItemController.minutesMenuTitle)：")
        XCTAssertEqual(entry?.title, "会议纪要：云端模型 API（还缺 Base URL、API Key、模型名）")

        // 逐项配齐，标题跟着变干净
        workspace.minutesAPIBaseURL = "https://api.deepseek.com/v1"
        let afterURL = NSMenu()
        controller.menuNeedsUpdate(afterURL)
        XCTAssertEqual(
            mrFindMenuItem(in: afterURL,
                           titleHasPrefix: "\(StatusItemController.minutesMenuTitle)：")?.title,
            "会议纪要：云端模型 API（还缺 API Key、模型名）")

        workspace.minutesAPIKey = "sk-test-key"
        workspace.minutesModelName = "deepseek-chat"
        let complete = NSMenu()
        controller.menuNeedsUpdate(complete)
        XCTAssertEqual(
            mrFindMenuItem(in: complete,
                           titleHasPrefix: "\(StatusItemController.minutesMenuTitle)：")?.title,
            "会议纪要：云端模型 API",
            "配齐之后标题不该再挂警告")
    }

    /// 「打开主窗口补全配置…」：云端缺项时存在且接对了动作；配齐后消失。
    func testMissingSetupItemOpensSettingsWindowAndDisappearsWhenComplete() throws {
        workspace.minutesProvider = .cloudAPI
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        let go = try XCTUnwrap(
            mrFindMenuItem(in: menu, titleHasPrefix: "打开设置补全配置"),
            "云端缺项时必须给一个直达动作——菜单里没法安全输入密钥。"
                + "实际菜单：\(mrFlattenMenuTitles(menu))")
        XCTAssertTrue(
            go.title.contains("还缺"), "缺哪几项要写进标题，不靠浮层：\(go.title)")
        _ = NSApp.sendAction(try XCTUnwrap(go.action), to: go.target, from: go)
        XCTAssertTrue(
            didAskToShowSettings,
            "点了就要把**设置窗口**带出来——那三项输入框在它的「会议纪要」页里")

        workspace.minutesAPIBaseURL = "https://api.deepseek.com/v1"
        workspace.minutesAPIKey = "sk-test-key"
        workspace.minutesModelName = "deepseek-chat"
        let complete = NSMenu()
        controller.menuNeedsUpdate(complete)
        XCTAssertNil(
            mrFindMenuItem(in: complete, titleHasPrefix: "打开设置补全配置"),
            "配齐之后这一项不该再占位置")
    }

    /// 本地档没有缺项概念：不该出现引导项，标题也不带警告。
    func testLocalEntryHasNoSetupGuidance() {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        XCTAssertNil(mrFindMenuItem(in: menu, titleHasPrefix: "打开设置补全配置"))
        XCTAssertEqual(
            mrFindMenuItem(in: menu,
                           titleHasPrefix: "\(StatusItemController.minutesMenuTitle)：")?.title,
            "会议纪要：本地 FoundationModels")
    }
}
