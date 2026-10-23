// 探针：`NSWindow.isReleasedWhenClosed` 到底能不能被观测到差异？
//
// 为什么值得单独立一个探针：`GUIRunner.buildWindow()` 里有一行
// `window.isReleasedWhenClosed = false`。如果它真的在挡一个崩溃，就应该有一条
// 回归测试；如果观测不到差异，那它就只是语义纠正，**不能**在注释里说成
// 「关一次窗口就会双重释放」——那是没有证据的因果链，后人会当真。
//
// 用法（自包含）：
//
//   swiftc -O -o /tmp/mr-window-release-probe scripts/probes/window-release/main.swift
//   /tmp/mr-window-release-probe
//
// 实测结论（macOS 26.6.2 / Build 25G83）：
//
//   默认(true)   关窗前 retainCount≈721 → 关窗后 weakWindow 仍存活 → 丢掉强引用后仍存活
//   修复后(false) 关窗前 retainCount≈721 → 关窗后 weakWindow 仍存活 → 丢掉强引用后仍存活
//
//   跑真事件循环、排空 autorelease pool 之后，两种设置**依旧无法区分**。
//   NSWindow 被内部视图树间接持有，引用计数远大于 1，单发一次 release 落不到 0。
//
// 结论：
//   1. `isReleasedWhenClosed = false` **复现不出**任何可观测差异，因此写不出
//      「把修复退回去会红」的回归测试——只能断言这个标志位本身（见
//      `StatusBarLifecycleTests`，并已注明那是打桩不是行为证明）。
//   2. 保留这一行仍然是对的：它把「窗口不该自己释放自己」的语义写明确，
//      不依赖 AppKit 当前实现里「引用计数恰好很高」这个巧合。
import AppKit

setvbuf(stdout, nil, _IONBF, 0)

@MainActor
func pump(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    let app = NSApplication.shared
    while Date() < deadline {
        guard let event = app.nextEvent(
            matching: .any, until: deadline, inMode: .default, dequeue: true) else { break }
        app.sendEvent(event)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

/// - Parameter pumpRunLoop: true 时先跑一段真事件循环。
///   关窗多出来的那次 release 只有等 autorelease pool 排空才真正落到对象上；
///   不跑循环，引用计数虚高，差异根本不会显现——这正是第一版探针漏掉的变量。
@MainActor
func experiment(releasedWhenClosed: Bool, pumpRunLoop: Bool, label: String) {
    var window: NSWindow? = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window!.isReleasedWhenClosed = releasedWhenClosed
    window!.title = "probe"

    weak let weakWindow = window
    if pumpRunLoop { pump(0.1) }
    let before = CFGetRetainCount(window!)

    window!.close()
    if pumpRunLoop { pump(0.3) }
    let survivedClose = weakWindow != nil
    let countAfter = weakWindow.map { CFGetRetainCount($0) } ?? 0

    // 丢掉强引用——真正的过度释放点
    window = nil
    if pumpRunLoop { pump(0.3) }
    let survivedRelease = weakWindow != nil

    print("[\(label)] retainCount \(before) → \(countAfter)"
          + " ｜ 关窗后\(survivedClose ? "存活" : "已释放")"
          + " ｜ 丢掉强引用后\(survivedRelease ? "存活" : "已释放")")
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    print("=== window.isReleasedWhenClosed 可观测性 ===")

    print("\n-- 不跑事件循环 --")
    experiment(releasedWhenClosed: true, pumpRunLoop: false, label: "默认(true)  ")
    experiment(releasedWhenClosed: false, pumpRunLoop: false, label: "修复后(false)")

    print("\n-- 跑真事件循环（排空 autorelease pool）--")
    experiment(releasedWhenClosed: true, pumpRunLoop: true, label: "默认(true)  ")
    experiment(releasedWhenClosed: false, pumpRunLoop: true, label: "修复后(false)")

    print("\n两种设置若结果一致，说明这条差异观测不到；"
          + "不要为它写「退回去会红」的回归测试，也不要声称它挡住了一个崩溃。")
}
