// 探针：关掉最后一个窗口之后，AppKit 到底会不会把应用收掉？
//
// 为什么值得单独立一个探针：这条分支**只有真 `NSApplication.run()` 才走得到**。
// 手工 pump `nextEvent`/`sendEvent` 走不到——阳性对照（委托返回 true）也观察不到
// 终止请求，说明那条路径压根没被触发。夹具立不住时，「观察到没退出」是假阴性。
// 所以这里每例单开一个进程，跑真 run()，并在 `--control` 那一例主动终止自己。
//
// 用法（自包含，不需要 MRGUI 的构建产物）：
//
//   swiftc -O -o /tmp/mr-terminate-probe scripts/probes/terminate-policy/main.swift
//   /tmp/mr-terminate-probe nomethod    # 委托不实现该方法 → 测 AppKit 默认行为
//   /tmp/mr-terminate-probe false       # 委托实现并返回 false（我们的实现）
//   /tmp/mr-terminate-probe true        # 阳性对照：必须观察到终止请求
//
// 实测结论（macOS 26.6.2 / Build 25G83）：
//
//   nomethod  responds=false  terminateRequested=0  → 不退出
//   false     responds=true   terminateRequested=0  → 不退出
//   true      responds=true   terminateRequested=1  → 退出     ← 对照有效
//
// 也就是说：**AppKit 在委托不实现该方法时，默认行为同样是「不退出」**。
// `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` 里的 `return false`
// 不是让程序活下去的原因，它是把意图写成代码（默认行为会随 AppKit 版本、
// 应用类型改变）。别把这段实测结论读成「我们靠这一行救回了程序」。
import AppKit

setvbuf(stdout, nil, _IONBF, 0)

@MainActor
class Base: NSObject, NSApplicationDelegate {
    var terminateRequested = false
    var window: NSWindow?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminateRequested = true
        return .terminateCancel          // 记录事实，但别真把探针进程干掉
    }

    func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 140),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}

/// 不实现 `applicationShouldTerminateAfterLastWindowClosed` —— 用来测 AppKit 的默认
final class NoMethod: Base {}

/// 我们的实现
final class ReturnsFalse: Base {
    @objc func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication) -> Bool { false }
}

/// 阳性对照：故意返回 true，必须观察到终止请求
final class ReturnsTrue: Base {
    @objc func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication) -> Bool { true }
}

@MainActor
func main() {
    let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "nomethod"
    let delegate: Base
    switch mode {
    case "false": delegate = ReturnsFalse()
    case "true":  delegate = ReturnsTrue()
    default:      delegate = NoMethod()
    }

    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    delegate.build()

    let responds = delegate.responds(
        to: NSSelectorFromString("applicationShouldTerminateAfterLastWindowClosed:"))

    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
        MainActor.assumeIsolated { delegate.window?.close() }
    }
    Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
        MainActor.assumeIsolated {
            print("RESULT mode=\(mode) responds=\(responds)"
                  + " terminateRequested=\(delegate.terminateRequested ? "1" : "0")"
                  + " isRunning=\(app.isRunning ? "1" : "0")"
                  + " windowAlive=\(delegate.window != nil ? "1" : "0")")
            exit(0)
        }
    }

    app.run()
    // 只有真的被终止才会到这里——那本身就是结论
    print("RESULT mode=\(mode) run() 返回了 → 应用被终止")
    exit(2)
}

MainActor.assumeIsolated { main() }
