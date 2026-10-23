import XCTest
import MRGUI

/// LaunchServices 交接的判据测试。
///
/// ## 为什么这组测试重要
///
/// 2026-10-20 反馈「勾选显示后，状态栏还是没有显示图标，两个屏幕都没有」。
/// 根因查到最后是：**不经 LaunchServices 直接执行 `.app` 内的二进制**，
/// 会让系统**永久拒绝**为这个 bundle id 登记状态栏项。
///
/// 实测（macOS 26.6.2，双屏；判据是按屏分组的菜单栏项数，不能用名字 grep——
/// 内置屏那层的 `kCGWindowName` 会退化成 `Item-0`，那样是假阴性）：
///
/// | 操作                                    | 内置屏 | 外接屏 |
/// |-----------------------------------------|--------|--------|
/// | 基线                                     | 10     | 10     |
/// | 全新 id + `open -a`                     | **11** | **11** |
/// | 退出                                      | 10     | 10     |
/// | 直接执行 .app 内二进制（GUI 模式）        | 10     | 10     |
/// | 退出后改用 `open -a`（同一个 id）         | 10     | 10     | ← **永久毒化**
///
/// 交接机制就是为堵这个洞而存在的：**它必须在碰 AppKit 之前判定并交出去**。
/// 判错了方向，代价是把 bundle id 永久毒化。
final class LaunchServicesHandoffTests: XCTestCase {

    // MARK: - 判据

    /// 正常路径：LaunchServices 启动时，环境变量里的 bundle id 就是自己的。
    /// 这时**绝不能**交接——交接会变成「自己启动自己」的无限循环。
    func testAlreadyLaunchedByLaunchServicesDoesNotHandOff() {
        let verdict = LaunchServicesHandoff.verdict(
            processBundleIdentifier: "com.pxing.mr",
            environmentBundleIdentifier: "com.pxing.mr",
            bundlePath: "/Applications/MeetingRecorder.app",
            needsHandoff: true)
        XCTAssertEqual(verdict, .alreadyLaunched)
    }

    /// 直接执行时，环境变量里是**父进程**的 bundle id ≠ 自己的 → 必须交接。
    func testDirectExecutionIsDetectedByMismatchedEnvironmentIdentifier() {
        let verdict = LaunchServicesHandoff.verdict(
            processBundleIdentifier: "com.pxing.mr",
            environmentBundleIdentifier: "com.tencent.workbuddy.mac",
            bundlePath: "/Applications/MeetingRecorder.app",
            needsHandoff: true)
        XCTAssertEqual(verdict, .needsHandoff)
    }

    /// CLI 模式**不需要**交接。
    ///
    /// 这条不是随便定的：实测 CLI 模式直接执行**不毒化** bundle id
    /// （登记数仍能 +1），毒化的触发条件是「GUI 模式 + 非 LaunchServices 启动」
    /// 这个组合。交接到 CLI 上只会平白多起一个进程。
    func testCommandLineModeNeverHandsOff() {
        let verdict = LaunchServicesHandoff.verdict(
            processBundleIdentifier: "com.pxing.mr",
            environmentBundleIdentifier: "com.tencent.workbuddy.mac",
            bundlePath: "/Applications/MeetingRecorder.app",
            needsHandoff: false)
        XCTAssertEqual(verdict, .alreadyLaunched)
    }

    /// 裸二进制（不在 .app 里）不需要交接。
    ///
    /// 裸二进制**没有 bundle id**，没有可被系统拒绝登记的身份，
    /// 无从毒化。而 `mr` 这条路正是裸二进制。
    func testBareBinaryOutsideAnAppBundleNeverHandsOff() {
        let verdict = LaunchServicesHandoff.verdict(
            processBundleIdentifier: nil,
            environmentBundleIdentifier: "com.tencent.workbuddy.mac",
            bundlePath: "/opt/homebrew/bin",
            needsHandoff: true)
        XCTAssertEqual(verdict, .alreadyLaunched)
    }

    /// 判不出来时**按需要交接处理**。
    ///
    /// 理由：交接是幂等且安全的（真由 LaunchServices 启动时它什么也不做），
    /// 而漏交接的代价是这个 bundle id 被永久毒化。宁可多交一次，不可漏一次。
    func testUndecidableCasesLeanTowardsHandingOff() {
        // 环境变量缺失
        XCTAssertEqual(
            LaunchServicesHandoff.verdict(
                processBundleIdentifier: "com.pxing.mr",
                environmentBundleIdentifier: nil,
                bundlePath: "/Applications/MeetingRecorder.app",
                needsHandoff: true),
            .unknown)
        // 自己的 bundle id 读不到
        XCTAssertEqual(
            LaunchServicesHandoff.verdict(
                processBundleIdentifier: nil,
                environmentBundleIdentifier: "com.tencent.workbuddy.mac",
                bundlePath: "/Applications/MeetingRecorder.app",
                needsHandoff: true),
            .unknown)
        // 环境变量是空串（同样是「读不到」）
        XCTAssertEqual(
            LaunchServicesHandoff.verdict(
                processBundleIdentifier: "com.pxing.mr",
                environmentBundleIdentifier: "",
                bundlePath: "/Applications/MeetingRecorder.app",
                needsHandoff: true),
            .unknown)
    }

    /// `unknown` 与 `needsHandoff` 在调用方那里必须**走同一条路**。
    ///
    /// 这一条钉的是「调用点的分支写全了」——漏掉 `.unknown` 那一支，
    /// 编译能过、测试也能过，但真出现「环境变量缺失」时就会直接跑 GUI，
    /// 把 bundle id 毒化掉。所以这里显式比对两个分支的处置。
    func testUnknownAndNeedsHandoffMustBeTreatedTheSameWay() {
        let unknown = LaunchServicesHandoff.verdict(
            processBundleIdentifier: "com.pxing.mr",
            environmentBundleIdentifier: nil,
            bundlePath: "/Applications/MeetingRecorder.app",
            needsHandoff: true)
        let needsHandoff = LaunchServicesHandoff.verdict(
            processBundleIdentifier: "com.pxing.mr",
            environmentBundleIdentifier: "com.tencent.workbuddy.mac",
            bundlePath: "/Applications/MeetingRecorder.app",
            needsHandoff: true)
        // 两个都不是「已经由 LaunchServices 启动」——调用方对它们的处置必须一致
        XCTAssertNotEqual(unknown, .alreadyLaunched)
        XCTAssertNotEqual(needsHandoff, .alreadyLaunched)
    }

    // MARK: - 交接本身

    /// 交接到一个**不存在的路径**必须返回 false。
    ///
    /// 返回 false 意味着调用方会**报错退出**而不是继续跑 GUI——
    /// 这正是我们要的行为：宁可明确失败，也不要毒化 bundle id。
    func testHandoffToAMissingBundlePathFails() {
        let ok = LaunchServicesHandoff.handoff(
            bundlePath: "/tmp/definitely-not-here-\(UUID().uuidString).app")
        XCTAssertFalse(ok, "交接到一个不存在的 bundle 必须失败——失败时调用方会退出，绝不继续跑 GUI")
    }

    /// 交接用的 `open` 不存在时必须返回 false（而不是抛异常）。
    func testHandoffWithAMissingOpenBinaryFails() {
        let ok = LaunchServicesHandoff.handoff(
            bundlePath: "/tmp/whatever.app",
            openPath: "/definitely/not/here/open")
        XCTAssertFalse(ok)
    }
}
