import XCTest
import AppKit
import MRCore
@testable import MRGUI
import MRMinutes
import MRSession

/// 会议纪要设置界面的逻辑层。
///
/// 这一组守着三件事：
/// 1. **状态行说人话**：缺什么、指向哪儿、缺了会不会被说清楚；
/// 2. **测试连接能用**：按钮的可用条件、结论呈现；
/// 3. **结论不过期**：改任一项配置后，上一次的绿色「连接成功」必须立刻作废。
///
/// 第 3 条是安全性质的：带着过期结论去跑会议，用户会在几分钟后拿到 401，
/// 而那正是这个界面本来要帮他避免的事。
@MainActor
final class MinutesSettingsModelTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var workspace: MeetingWorkspace!

    override func setUp() async throws {
        _ = NSApplication.shared

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-minutes-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "mr-minutes-settings-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        workspace = MeetingWorkspace(
            root: root, preferences: RecorderPreferences(defaults: defaults))
    }

    override func tearDown() async throws {
        workspace = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    /// 注入假探测器的 model：**绝不真发网络请求**。
    private func makeModel(
        outcome: MinutesAPIProbe.Outcome = .ok(model: "m", latencyMs: 12, reply: "就绪")
    ) -> MinutesSettingsModel {
        MinutesSettingsModel(workspace: workspace) { _ in outcome }
    }

    private func configureCloudComplete() {
        workspace.minutesProvider = .cloudAPI
        workspace.minutesAPIBaseURL = "https://api.deepseek.com/v1"
        workspace.minutesAPIKey = "sk-abcdefghijklmnop"
        workspace.minutesModelName = "deepseek-chat"
    }

    // MARK: - 状态行

    /// 本地档的状态行**跟着这台机器的实际能力走**。
///
/// 两条分支都断言，而不是只测「能跑」那一条：本机跑不了 Apple Intelligence 时
/// 那一行必须变成警告并指出替代方案，而把它写成只在某台机器上成立的断言，
/// 换个设备就成了假绿。
func testLocalStatusReflectsThisMachineCapability() {
    let model = makeModel()
    if workspace.localMinutesUnavailableReason == nil {
        XCTAssertTrue(model.statusLine.contains("不出本机"), model.statusLine)
        XCTAssertTrue(model.statusLine.contains("零成本"), model.statusLine)
        XCTAssertFalse(model.statusIsWarning)
    } else {
        XCTAssertTrue(model.statusIsWarning, "本机跑不了本地纪要就该是警告色")
        XCTAssertTrue(model.statusLine.contains("Apple Intelligence"), model.statusLine)
        XCTAssertTrue(model.statusLine.contains("云端"), "要给出下一步：\(model.statusLine)")
    }
}

    /// 本机不支持 Apple Intelligence 时，本地这一行**必须说出来**。
    /// 不说的话，用户选本地、生成后只看到原稿，会以为功能坏了。
    func testLocalStatusWarnsWhenThisMachineCannotRunIt() throws {
        guard let reason = workspace.localMinutesUnavailableReason else {
            throw XCTSkip("本机支持 Apple Intelligence，无需这条降级提示")
        }
        let model = makeModel()
        XCTAssertTrue(model.statusIsWarning, "本机跑不了就该是警告色")
        XCTAssertTrue(model.statusLine.contains("Apple Intelligence"))
        XCTAssertTrue(model.statusLine.contains("云端"), "要给出下一步：改用云端")
        XCTAssertFalse(reason.isEmpty)
    }

    func testCloudStatusListsExactlyWhatIsMissing() {
        workspace.minutesProvider = .cloudAPI
        let model = makeModel()

        XCTAssertTrue(model.statusIsWarning)
        XCTAssertTrue(model.statusLine.contains("Base URL"), model.statusLine)
        XCTAssertTrue(model.statusLine.contains("API Key"), model.statusLine)
        XCTAssertTrue(model.statusLine.contains("模型名"), model.statusLine)
    }

    func testCloudStatusShowsHostAndMaskedKeyWhenComplete() {
        configureCloudComplete()
        let model = makeModel()

        XCTAssertFalse(model.statusIsWarning)
        XCTAssertTrue(model.statusLine.contains("api.deepseek.com"), model.statusLine)
        XCTAssertTrue(model.statusLine.contains("离开本机") || model.statusLine.contains("发往"),
                      model.statusLine)
        XCTAssertFalse(model.statusLine.contains("sk-abcdefghijklmnop"), "密钥绝不进状态行")
        XCTAssertTrue(model.statusLine.contains(workspace.maskedMinutesAPIKey))
    }

    /// 明文 http 指向远端要在填的时候就拦下——等到生成时报错就晚了。
    func testPlainHTTPToRemoteHostShowsWarningInStatus() {
        workspace.minutesProvider = .cloudAPI
        workspace.minutesAPIBaseURL = "http://api.example.com/v1"
        workspace.minutesAPIKey = "k"
        workspace.minutesModelName = "m"
        let model = makeModel()

        XCTAssertTrue(model.statusIsWarning)
        XCTAssertTrue(model.statusLine.contains("明文"), model.statusLine)
        XCTAssertFalse(model.canProbe, "这种地址不该让用户去测")
    }

    // MARK: - 测试连接

    func testProbeIsDisabledUntilEverythingIsFilled() {
        workspace.minutesProvider = .cloudAPI
        let model = makeModel()
        XCTAssertFalse(model.canProbe, "三项没齐不该能测")

        workspace.minutesAPIBaseURL = "https://api.deepseek.com/v1"
        workspace.minutesAPIKey = "sk-x"
        XCTAssertFalse(model.canProbe, "还缺模型名")

        workspace.minutesModelName = "deepseek-chat"
        XCTAssertTrue(model.canProbe)
    }

    func testRunningProbeReachesTheConclusion() async {
        configureCloudComplete()
        let model = makeModel()

        model.runProbe()
        await XCTAssertEventually("探测后应给出结论") { model.probeConclusion != nil }

        XCTAssertTrue(model.probeConclusionIsSuccess)
        XCTAssertTrue(model.probeConclusion?.contains("连接成功") == true)
        XCTAssertFalse(model.isProbing)
    }

    func testFailedProbeIsShownAsFailureNotSuccess() async {
        configureCloudComplete()
        let model = makeModel(outcome: .failed(reason: "密钥无效（HTTP 401）"))

        model.runProbe()
        await XCTAssertEventually("失败也要给出结论") { model.probeConclusion != nil }

        XCTAssertFalse(model.probeConclusionIsSuccess)
        XCTAssertTrue(model.probeConclusion?.contains("401") == true)
    }

    func testProbeIsNotSentWhenConfigurationIsIncomplete() async {
        workspace.minutesProvider = .cloudAPI
        let model = makeModel()

        model.runProbe()
        // 空转一轮：不该有任何结论出现
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertNil(model.probeConclusion)
        XCTAssertFalse(model.isProbing)
    }

    // MARK: - 结论作废（最要紧的一条）

    /// 测通了之后改密钥 → 旧的成功结论必须立刻消失。
    ///
    /// 不作废的话，界面上会挂着一个绿色的「连接成功」而实际已经填错了，
    /// 用户带着这个错觉去跑会议，几分钟后拿到 401——正是这个界面
    /// 本来要帮他避免的事。
    func testChangingTheKeyInvalidatesAPreviousSuccess() async {
        configureCloudComplete()
        let model = makeModel()
        model.runProbe()
        await XCTAssertEventually("先测通") { model.probeConclusionIsSuccess }

        workspace.minutesAPIKey = "sk-wrong-key"
        XCTAssertNil(model.probeConclusion, "改了配置还挂着上次的成功结论 = 骗人")
        XCTAssertFalse(model.probeConclusionIsSuccess)
    }

    func testChangingURLOrModelAlsoInvalidatesTheConclusion() async {
        configureCloudComplete()
        let model = makeModel()
        model.runProbe()
        await XCTAssertEventually("先测通") { model.probeConclusionIsSuccess }

        workspace.minutesAPIBaseURL = "https://api.moonshot.cn/v1"
        XCTAssertNil(model.probeConclusion, "换地址后旧结论不再作数")

        model.runProbe()
        await XCTAssertEventually("换地址后重新测通") { model.probeConclusionIsSuccess }
        workspace.minutesModelName = "kimi-k2"
        XCTAssertNil(model.probeConclusion, "换模型后旧结论同样作废")
    }

    func testSwitchingProviderAlsoInvalidatesTheConclusion() async {
        configureCloudComplete()
        let model = makeModel()
        model.runProbe()
        await XCTAssertEventually("先测通") { model.probeConclusionIsSuccess }

        workspace.minutesProvider = .local
        XCTAssertNil(model.probeConclusion)
    }

    /// 没测过时不要反复触发界面刷新（每个按键都会发一次）。
    func testIdleProbePhaseStaysIdleWhileTyping() {
        let model = makeModel()
        model.revealsKey.toggle()
        model.revealsKey.toggle()
        XCTAssertNil(model.probeConclusion)
        XCTAssertFalse(model.isProbing)
    }

    // MARK: - 服务商预设

    func testApplyingPresetFillsURLAndModelButNeverTheKey() {
        workspace.minutesAPIKey = "sk-user-own-key"
        let model = makeModel()

        model.apply(preset: .deepSeek)

        XCTAssertEqual(workspace.minutesAPIBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(workspace.minutesModelName, "deepseek-chat")
        XCTAssertEqual(workspace.minutesAPIKey, "sk-user-own-key", "预设绝不能碰密钥")
        XCTAssertNotNil(model.presetNote, "要告诉用户密钥去哪申请")
    }

    func testPresetPutsTheConfigurationIntoAProbeableState() {
        workspace.minutesProvider = .cloudAPI
        workspace.minutesAPIKey = "sk-x"
        let model = makeModel()
        model.apply(preset: .zhipu)

        XCTAssertTrue(model.canProbe, "点一下预设就该能直接测——URL 与模型名都是对的")
        XCTAssertTrue(model.statusLine.contains("open.bigmodel.cn"), model.statusLine)
    }

    /// 本机自建（ollama）**不需要密钥**——它根本不校验。
    /// 界面逼用户编一个假 key 上去，只会让「配齐」变成一个仪式。
    func testOllamaPresetIsUsableWithNoKeyAtAll() {
        workspace.minutesProvider = .cloudAPI
        let model = makeModel()
        model.apply(preset: .ollama)

        XCTAssertTrue(model.canProbe, "本机自建不该被密钥拦住")
        XCTAssertFalse(model.statusIsWarning, model.statusLine)
        XCTAssertFalse(model.statusLine.contains("API Key"), model.statusLine)
    }

    // MARK: - 密钥显示

    func testKeyRevealIsOffByDefaultAndCanBeTurnedBack() {
        let model = makeModel()
        XCTAssertFalse(model.revealsKey, "默认必须藏着")

        model.revealsKey = true
        XCTAssertTrue(model.revealsKey)
        model.hideKey()
        XCTAssertFalse(model.revealsKey, "下次输入应回到隐藏态")
    }

    // MARK: - 设置窗口本体

    /// 窗口可以反复打开、且复用同一个对象——用户填一半关掉再回来，
    /// 草稿必须还在（这是 `SettingsWindowController` 单例存在的理由）。
    func testSettingsWindowIsReusedAcrossShows() {
        let controller = SettingsWindowController.shared
        controller.closeForTesting()

        controller.show(workspace: workspace)
        controller.show(workspace: workspace)
        controller.closeForTesting()
    }
}

// MARK: - 轮询助手

/// 轮询到条件成立或超时。**不用 expectation**：注入的探测器闭包是
/// `@Sendable`，在里面 fulfill 一个 XCTestExpectation 会引入非 Sendable
/// 捕获（项目守 0 warning）。
///
/// 做成断言而不是返回 Bool：`XCTAssertTrue(await …)` 编译不过——
/// XCTest 的断言参数是 autoclosure，装不下 `await`。
@MainActor
private func XCTAssertEventually(
    _ message: String = "",
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ predicate: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(predicate(), message, file: file, line: line)
}