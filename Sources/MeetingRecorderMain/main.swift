import Foundation
import MRCLI
import MRGUI

// 整个项目唯一持有顶层代码的地方。
//
// 分派规则：**有参数走命令行，没参数走图形界面**。
// 双击 .app 时 `CommandLine.arguments` 只有一个元素（可执行文件自身），
// 所以「无参数」正好就是「双击启动」。
//
// 为什么不写成 `@main struct` + `static func main() async`：
// GUI 那条路要跑 `NSApplication.run()`，它永不返回。放进 async 上下文会让
// main actor 被永久占住，窗口根本出不来。顶层代码可以同步地调它。

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty {
    // ── LaunchServices 交接（必须在碰 AppKit 之前）──────────────────
    //
    // macOS 26 上，第三方状态栏项只有由 LaunchServices 启动时才会被系统登记。
    // 直接执行 `.app/Contents/MacOS/<二进制>` 启动 GUI，图标不会出现在菜单栏上，
    // 而且**这个 bundle id 从此被系统永久拒绝登记**——之后再 `open -a` 也救不回来
    // （实测：内置屏/外接屏的菜单栏项数都停在 10，不再 +1）。
    //
    // 详见 `LaunchServicesHandoff` 的完整实验记录。
    //
    // 判据是 `__CFBundleIdentifier`：LaunchServices 启动时它等于自己的 bundle id，
    // 直接执行时它等于父进程的 bundle id。
    switch LaunchServicesHandoff.currentVerdict(needsHandoff: true) {
    case .alreadyLaunched:
        // 正常路径：已经由 LaunchServices 启动，直接跑。
        break

    case .needsHandoff, .unknown:
        let bundlePath = Bundle.main.bundlePath
        if LaunchServicesHandoff.handoff(bundlePath: bundlePath) {
            // 交接成功：这个进程的任务就是把系统请来正确地启动我们。
            // 必须在碰 AppKit 之前退出——一旦建了 NSStatusItem，
            // 这个 bundle id 就被毒化了。
            exit(0)
        }
        // 交接失败。**不能继续跑 GUI**——那等于亲手毒化这个 bundle id，
        // 而且是不可逆的。宁可明确报错，也不要留下「窗口开着但图标永远出不来」
        // 的假正常状态。
        FileHandle.standardError.write(Data("""
        ❌ 无法通过 LaunchServices 启动本应用（交接失败）。
           直接执行 .app 内的二进制会让系统永久拒绝为本应用登记状态栏图标，
           因此这里选择不继续运行，而不是留下一个坏掉的状态。
           请改用以下任一方式启动：
             · 在访达里双击 \(URL(fileURLWithPath: bundlePath).lastPathComponent)
             · 终端执行： open -a \(bundlePath)

        """.utf8))
        exit(1)
    }

    // 阻塞直到用户退出应用
    GUIRunner.run()
} else {
    exit(MeetingRecorderCLI.runSynchronously(arguments))
}
