import AppKit
import Foundation

/// 「不经 LaunchServices 启动」的侦测与交接。
///
/// ## 这是什么毛病
///
/// macOS 26 上，第三方 `NSStatusBar` 项**只有由 LaunchServices 启动时**
/// （Finder 双击、`open -a`、LaunchServices API）才会被系统登记进菜单栏。
/// 直接执行 `.app/Contents/MacOS/<二进制>` 启动的进程**不会**被登记——
/// 窗口不出现、图标不在菜单栏上，而且 `NSStatusItem.isVisible` 照样读回 `true`。
///
/// 更糟的是：**这样启动过一次之后，这个 bundle id 就被系统永久拒绝登记了。**
/// 之后再用 `open -a` 启动同一个 id 也不行——记录是按 bundle id 存的，
/// `defaults delete` / `lsregister -u` + `-f` / 换路径 / 重启 ControlCenter
/// 全试过，都清不掉。唯一有效的解法是换一个从未被直接执行过的 bundle id。
///
/// 2026-10-20 用受控对照实验量到了这条链（干净判据是**按屏分组的菜单栏项数**，
/// 不能用名字 grep——主屏那层的 `kCGWindowName` 会退化成 `Item-0`，
/// 那样会把「已登记」误判成「没登记」，是假阴性）：
///
///   | 操作                                   | 内置屏 | 外接屏 |
///   |----------------------------------------|--------|--------|
///   | 基线                                    | 10     | 10     |
///   | 全新 id + `open -a`                    | **11** | **11** |
///   | 退出                                     | 10     | 10     |
///   | 直接执行 .app 内二进制（GUI 模式）      | 10     | 10     |
///   | 退出后改用 `open -a`（同一个 id）        | 10     | 10     | ← **永久毒化**
///
/// 顺带澄清两件事：
/// - CLI 模式**直接执行不毒化**（实测登记数 11）。毒化的触发条件是
///   「GUI 模式 + 非 LaunchServices 启动」这个组合。
/// - **主屏和副屏的表现完全一致**。同一项在两块屏上各有一份，项数同步增减。
///   所以「状态栏图标只在一块屏上」这种症状是不存在的——要么两块都有，要么两块都没有。
///
/// ## 为什么用环境变量判「是不是被 LaunchServices 启动的」
///
/// `__CFBundleIdentifier`：
/// - 由 LaunchServices 启动时，它等于**进程自己的** bundle id；
/// - 直接执行时，它等于**父进程**的 bundle id（实测父进程是 WorkBuddy 时为
///   `com.tencent.workbuddy.mac`）。
///
/// 这是唯一不碰 AppKit 就能判定的信号——`NSRunningApplication` 那条路太晚：
/// `applicationDidFinishLaunching` 时 `runningApplications(withBundleIdentifier:)`
/// 已经返回 `true` 了，拦不住毒化。
public enum LaunchServicesHandoff {

    /// 侦测结果。
    public enum Verdict: Equatable {
        /// 已经由 LaunchServices 启动（或本来就不需要交接）：直接往下走。
        case alreadyLaunched
        /// 不是由 LaunchServices 启动：必须交接出去。
        case needsHandoff
        /// 判不出来（环境变量缺失、bundle id 读不到）：**按需要交接处理**。
        ///
        /// 理由：交接是**幂等且安全**的——真由 LaunchServices 启动时它什么也不做；
        /// 而漏交接的代价是这个 bundle id 被永久毒化。宁可多交一次，不可漏一次。
        case unknown
    }

    /// 判当前进程是不是由 LaunchServices 启动。
    ///
    /// 拆成静态函数、只吃字符串，是为了能测：真进程的 `ProcessInfo` 在测试里
    /// 改不动（环境变量一改就影响整个测试进程）。
    ///
    /// `bundlePath` 用来判「是否真在 .app bundle 内」。裸二进制没有 bundle id，
    /// 无从毒化，也就不需要交接——那种情况返回 `alreadyLaunched`。
    public static func verdict(
        processBundleIdentifier: String?,
        environmentBundleIdentifier: String?,
        bundlePath: String?,
        needsHandoff: Bool
    ) -> Verdict {
        guard needsHandoff else { return .alreadyLaunched }
        // 不在 .app 里 → 没有 bundle id，没有可被毒化的身份 → 无需交接
        guard let bundlePath, bundlePath.hasSuffix(".app") else { return .alreadyLaunched }
        guard let processBundleIdentifier, !processBundleIdentifier.isEmpty else {
            return .unknown
        }
        guard let environmentBundleIdentifier, !environmentBundleIdentifier.isEmpty else {
            return .unknown
        }
        return environmentBundleIdentifier == processBundleIdentifier
            ? .alreadyLaunched
            : .needsHandoff
    }

    /// 当前进程的真实判定。`needsHandoff` 由调用方给出（GUI 才需要）。
    public static func currentVerdict(needsHandoff: Bool) -> Verdict {
        verdict(
            processBundleIdentifier: Bundle.main.bundleIdentifier,
            environmentBundleIdentifier: ProcessInfo.processInfo
                .environment["__CFBundleIdentifier"],
            bundlePath: Bundle.main.bundlePath,
            needsHandoff: needsHandoff)
    }

    /// 交接给 LaunchServices：把这个 bundle 重新拉起来，让系统正式登记它。
    ///
    /// 用 `/usr/bin/open -a`——它走的就是 LaunchServices（与访达双击同一条路），
    /// 而且**同步返回**：`open` 成功把请求交给 LaunchServices 就退出，
    /// 不需要等应用真的起来。
    ///
    /// 返回 `true` 表示已成功发起交接（调用方应当立刻退出）。
    /// 返回 `false` 表示交接没成功——**这时绝不能继续跑 GUI**：
    /// 继续跑就等于把 bundle id 毒化掉，而毒化是不可逆的。
    @discardableResult
    public static func handoff(bundlePath: String, openPath: String = "/usr/bin/open") -> Bool {
        guard FileManager.default.isExecutableFile(atPath: openPath) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openPath)
        process.arguments = ["-a", bundlePath]
        do {
            try process.run()
            // `open` 很快就会退出（把请求交给 LaunchServices 后即返回）。
            // 等它退完才能确认它**接受**了这个 bundle——如果 bundle 路径不对，
            // `open` 会以非零退出并往 stderr 打一行原因。
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
