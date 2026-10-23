// 探针：验证 ⌘V 真的能把剪贴板内容送进输入框，而不只是「菜单项存在」。
//
// ## 为什么单测菜单项还不够
//
// 2026-10-19 的真故障：设置窗口里粘贴 API Key 没反应。
// 根因是主菜单里没有「编辑」菜单组——⌘V 没有派发通路。
// 那次补了菜单项，单测也断言了「粘贴项在不在、键位对不对」。
//
// 但**菜单项存在 ≠ 内容进得去**。真正决定成败的是整条链路：
//
//   剪贴板 → NSMenu 匹配 keyEquivalent → sendAction(paste:)
//          → 响应链找到当前 first responder → 内容真的写进了输入框
//
// 任何一环断了，界面表现都是同一个：**按了没反应，什么都不发生**。
// 而单测只能看到第一环（本进程里有那个菜单项），看不到后面三环。
//
// ## 它怎么「真的按下 ⌘V」
//
// `CGEvent` 合成需要辅助功能权限（本项目已确认拿不到）。
// 改用 `NSEvent.keyEvent(...)` **构造**事件对象，再交给 `NSApp.sendEvent`：
// 派发路径与真实按键完全相同，只有「谁来产生那个事件」这一步不同。
//
// ## 为什么必须跑真 NSApplication.run()（第一版踩过的坑）
//
// 第一版在顶层 `MainActor.assumeIsolated` 里手工 pump，**测不出来**：
// 日志显示 `keyWindow: nil`、响应链断在窗口之外，于是阳性对照也粘不进去。
// AppKit 是在真事件循环里才把窗口排上键盘焦点的——手工 `sendEvent`
// 绕过的那一段，恰好就是派发链路的一部分。
//
// 结论直接写在这里：**这不是「探针测不出问题」，是「探针的环境不对」。**
// 假阴性比没有探针更糟——它会让人以为还有别的 bug 去查。
// 于是改成仿 `terminate-policy` 探针的做法：跑真 run()，
// 由 AppKit 自己做窗口激活与键盘焦点，再由定时器在 run() 内部派发事件。
//
// ## 对照组：这是本探针的关键
//
// 同一个探针按参数跑两遍（每遍单开进程，避免菜单状态互相污染）：
//
//   without-edit  主菜单**不带**编辑菜单 → 期望 ⌘V 进不去（阴性）
//   with-edit     主菜单**带**生产那份   → 期望内容真的进去了（阳性）
//
// 只跑阳性的话，「什么都没发生」和「发生对了」在日志里长得一样。
// 阴性对照证明的是：**这个探针真的能测出失败**。
//
// ## 用法
//
//   swift build                       # 先构建出 .o 与 .swiftmodule
//   ./scripts/probes/paste-dispatch/run.sh
//
// ## 证据边界（重要，别把一次成功当成常态）
//
// 它证明的是「这个进程里、这个主菜单下，⌘V 的派发链路是通的」。
// 真实 App 里的 SwiftUI `TextField` / `SecureField` 由系统渲染成
// `NSTextField`，派发路径与这里一致；但真实硬件事件还要经过事件队列，
// 那一段不在本探针范围内。
//
// **可复现性有限**：`isKeyWindow` 取决于探针进程能不能成为前台应用。
// 自动化会话里这一步不稳定——同一个二进制，时好时坏。
// 所以脚本区分三种结果并各走各的退出码：
//   对照成立 + 阳性通过（链路通）/ 探针失效（测不出失败）/ 环境不成立（本机此刻测不了）。
// 第三种**绝不能**报成第一种或第二种：前者会掩盖 bug，后者会让人去查不存在的 bug。
import AppKit
@testable import MRGUI

setvbuf(stdout, nil, _IONBF, 0)

let mode = CommandLine.arguments.dropFirst().first ?? "with-edit"
guard mode == "with-edit" || mode == "without-edit" else {
    print("用法：\(CommandLine.arguments[0]) with-edit|without-edit")
    exit(2)
}

@MainActor
final class Probe: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private var field: NSTextField?
    private let withEdit = (mode == "with-edit")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 激活策略与生产代码一致（`.regular`，有 Dock 图标）。
        // **必须一致**：`.accessory` 下窗口拿不到 key 状态，
        // 那正是第一版探针假阴性的来源之一。
        NSApp.activate(ignoringOtherApps: true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "粘贴探针（\(mode)）"
        window.isReleasedWhenClosed = false

        let field = NSTextField(string: "")
        field.frame = NSRect(x: 20, y: 40, width: 280, height: 24)
        field.isEditable = true
        field.isSelectable = true

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        view.addSubview(field)
        window.contentView = view

        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.field = field

        NSApp.mainMenu = Self.makeMenu(includingEdit: withEdit)

        // 交给真事件循环排空，让 AppKit 完成窗口激活与布局。
        // **可能要重试**：同机若已有别的窗口（哪怕是这个探针上一次跑剩的）
        // 抢着键盘焦点，本窗口就拿不到 key 状态。实测残留进程会让第一次
        // `isKeyWindow` 为 false——那是环境没就绪，不是「⌘V 坏了」。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.attempt(remaining: 5)
        }
    }

    /// 窗口拿到键盘焦点才试。最多试 5 次（每次等 0.5s）。
    private func attempt(remaining: Int) {
        guard let window else { return }
        if window.isKeyWindow,
           let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: field ?? NSView()) {
            print("[\(mode)] 环境成立：key window ✓，焦点在输入框的 NSTextView 上 ✓")
            fire()
            return
        }
        guard remaining > 0 else {
            // 到这里仍然不成立就是真问题，但**仍然不能下结论**：
            // 分不清「派发坏了」与「环境没就绪」时，诚实报「测不出结论」。
            print("❌ 连续 5 次都没拿到 key window（isKeyWindow=\(window.isKeyWindow)）。")
            print("   这个探针测不出结论——宁可报错，也不要给一个假阴性。")
            NSApp.terminate(nil)
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.attempt(remaining: remaining - 1)
        }
    }

    /// 造一份主菜单。`includingEdit` 决定装不装生产代码里的「编辑」菜单。
    private static func makeMenu(includingEdit: Bool) -> NSMenu {
        let menu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        menu.addItem(appMenuItem)

        if includingEdit {
            let editMenuItem = NSMenuItem()
            editMenuItem.submenu = AppDelegate.editMenu()
            menu.addItem(editMenuItem)
        }
        return menu
    }

    private func fire() {
        guard let field, let window else { return }
        // 焦点判据是「**first responder 在这个字段的子树里**」，
        // 不是「first responder 就是这个字段」：
        // NSTextField 拿到焦点后，真正响应键盘的是它内部那个 NSTextView
        // （实测 firstResponder 就是 NSTextView，而 isKeyWindow 为 true）。
        // 拿 `=== field` 去卡会把「环境正常」误判成「环境不成立」。
        guard window.isKeyWindow,
              let responder = window.firstResponder as? NSView,
              responder === field || responder.isDescendant(of: field) else {
            print("❌ 环境不成立：isKeyWindow=\(window.isKeyWindow)，"
                  + "firstResponder=\(String(describing: window.firstResponder))。")
            print("   这个探针测不出结论——宁可报错，也不要给一个假阴性。")
            exit(1)
        }
        print("[\(mode)] 环境成立：key window ✓，焦点在输入框的 NSTextView 上 ✓")

        let payload = "sk-paste-probe-\(UUID().uuidString.prefix(8))"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)

        // keyCode 9 = V（物理键位，与键盘布局无关）
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil, characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9)!
        NSApp.sendEvent(event)

        // 走真事件循环等派发落地（手工 pump 在这里不成立，
        // 见文件头「为什么必须跑真 NSApplication.run()」）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.report(payload: payload)
        }
    }

    private func report(payload: String) {
        guard let field else { return }
        let got = field.stringValue
        let pasted = got == payload
        print("[\(mode)] \(pasted ? "内容进去了" : "内容没进去")")
        print("   期望「\(payload)」")
        print("   实得「\(got.isEmpty ? "(空)" : got)」")
        // **结论交给脚本读输出，不靠退出码。**
        //
        // 实测：`exit(n)` 在真 `NSApplication.run()` 里拿回来的永远是 0——
        // run() 还没返回，主 actor 上这一行就被别的东西抢先收走了。
        // 退出码既然不可靠，就不要在它身上押注：让脚本 grep 结论行，
        // 那是眼睛能核对的东西。
        NSApp.terminate(nil)
    }
}

// 整个探针跑在主 actor 上：`NSApplication` 与 `AppDelegate` 都是主 actor 隔离的，
// 而 main.swift 的顶层代码本来就跑在主线程——编译器不认这一点，用
// `assumeIsolated` 把「必须在主线程」这件事写明（与 `GUIRunner.run()` 同一理由）。
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = Probe()
    application.delegate = delegate
    // delegate 必须是强引用：NSApplication.delegate 是 weak，
    // 局部变量出作用域就释放，`applicationDidFinishLaunching` 永远不会被调到。
    withExtendedLifetime(delegate) { application.run() }
}