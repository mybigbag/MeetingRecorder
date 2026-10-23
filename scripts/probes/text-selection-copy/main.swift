// ⚠️ 2026-10-22 起，纪要卡片**不再用 `.textSelection`**（它只能选中一行），
// 改成了单个 `NSTextView`。要验「跨行划选 + ⌘C」请看
// `scripts/probes/minutes-selection-copy/`——那边的判据是结论性的
// （旧实现复现 bug、新实现跨段 6 行）。
// 本文件保留是因为它记录了「SwiftUI 文本选择层不认合成拖拽」这条事实。
//
// 探针：会议纪要「划词选中 + ⌘C 复制」这条链路真的通吗。
//
// ## 为什么单测不够
//
// `.textSelection(.enabled)` 只是一行修饰符，编译永远通过。
// 真正决定「用户能不能把那句话复制走」的是一条链：
//
//   鼠标划选 → SwiftUI 的文本选择层拿到 first responder
//            → 主菜单「编辑 → 复制」匹配 keyEquivalent ⌘C
//            → sendAction(copy:) 沿响应链落到那个选择层
//            → 剪贴板里出现选中的那几个字
//
// 任何一环断了，表现都是同一个：**选了字、按 ⌘C、粘出来是空的（或还是旧内容）**。
// 而这件事没有别的观测面——所以只能在这里按一次真键盘。
//
// ## 怎么「真按」
//
// 与 `paste-dispatch` 探针同一套办法（CGEvent 要辅助功能权限，本项目拿不到）：
// `NSEvent.keyEvent(...)` 构造事件 + `NSApp.sendEvent()`，
// 派发路径与真实按键相同，只有「谁产生这个事件」不同。
// **必须跑真 `NSApplication.run()`**：手工 pump 时窗口拿不到 key 状态，
// 响应链断在窗口外，阳性对照也会失败——那是环境不对，不是 bug。
//
// ## 对照组（关键）
//
//   selectable  用生产同款 `.textSelection(.enabled)` → 期望复制成功
//   plain       同一段文字、**不加**选择修饰 → 期望复制不到（阴性）
//
// 只跑阳性的话，「复制成功」和「剪贴板里恰好还留着上次的旧内容」分不清。
// 阴性对照顺带证明探针真的能测出失败。
//
// ⚠️ 阴性那一路的判据是「剪贴板里**不是**我们的探针文本」，
// 不是「剪贴板为空」：清空剪贴板后 ⌘C 不生效时它确实是空的，
// 但把「空」当成判据会让「上次跑剩的内容」被当成失败，反之亦然。
//
// ## 用法
//
//   swift build
//   ./scripts/probes/text-selection-copy/run.sh
//
// ## 证据边界（**2026-10-22 实测：本机只能给出「无结论」**）
//
// 探针先用鼠标把文本拖一遍再按 ⌘C。实测两路结果完全一样（剪贴板仍是哨兵值）：
// 带 `.textSelection(.enabled)` 的文本没被复制走，不带的也没被复制走。
// 这说明**这个进程里根本没建立起选区**——SwiftUI 的文本选择层不认合成的
// 鼠标拖拽事件（`⌘A` 对静态文本也没有默认实现）。
//
// 于是它只能区分三件事，并且**不许把中间那种报成前后两种**：
//   LINK-OK        可选文本被复制走 → 链路成立
//   INCONCLUSIVE   两路一样 → 测不出结论（本机当前就是这一种）
//   PROBE-BROKEN   不可选文本也被复制走 → 探针失效
//
// 要拿到真结论只有一条路：人打开 App、用真鼠标划一句、按 ⌘C、粘到别处。
// **不许把这条写成「已验证」。**
// 布局（这行字在不在、有没有被挤掉）由 `meeting-detail-render` 探针负责，
// 两个探针各管一段，谁都不冒充对方。
import AppKit
import SwiftUI
@testable import MRGUI

setvbuf(stdout, nil, _IONBF, 0)

let mode = CommandLine.arguments.dropFirst().first ?? "selectable"
guard mode == "selectable" || mode == "plain" else {
    print("用法：\(CommandLine.arguments[0]) selectable|plain")
    exit(2)
}

/// 探针文本：带会话号，避免「读到上次残留」被误判成成功。
let probeText = "纪要探针-\(UUID().uuidString.prefix(8))"

@MainActor
final class Probe: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private var hosting: NSHostingView<AnyView>?
    private let selectable = (mode == "selectable")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        // 只放一行文本、居中：拖拽坐标要落在这行字上，
        // 多摆几个元素只会让「拖空了」和「选择层不认合成事件」混在一起。
        let body = Group {
            if selectable {
                Text(probeText).font(.body).textSelection(.enabled)
            } else {
                Text(probeText).font(.body)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        let hosting = NSHostingView(rootView: AnyView(body))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "纪要选词探针（\(mode)）"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.hosting = hosting

        // 走**生产那份**主菜单：⌘C 的派发通路就是它。
        // 自己另写一份菜单等于验证了一份不存在的通路。
        let menu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        menu.addItem(appMenuItem)
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = AppDelegate.editMenu()
        menu.addItem(editMenuItem)
        NSApp.mainMenu = menu

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.attempt(remaining: 5)
        }
    }

    private func attempt(remaining: Int) {
        guard let window else { return }
        if window.isKeyWindow {
            fire()
            return
        }
        guard remaining > 0 else {
            print("[\(mode)] ❌ 环境不成立：连续 5 次没拿到 key window。")
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

    private func fire() {
        guard let window else { return }
        print("[\(mode)] 环境成立：key window ✓")

        // 剪贴板先放一个**已知的旧内容**：这样「⌘C 没生效」和
        // 「⌘C 生效但复制到空」都能被区分开。
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("PROBE-SENTINEL", forType: .string)

        // **必须先用鼠标拖一次**。
        //
        // 第一版直接按 ⌘A + ⌘C，两路都拿不到内容——但那不是「⌘C 坏了」，
        // 而是**根本没有选区**：SwiftUI 的文本选择层要靠一次真实的鼠标交互
        // 才建立选区与选择状态，`⌘A` 在这种静态文本上没有默认实现。
        // 没有选区时按 ⌘C 什么都不做，任何实现都会这样。
        dragSelect(in: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.send(key: "c", keyCode: 8)   // ⌘C 复制
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.report()
            }
        }
    }

    /// 在探针文本那一行上从左拖到右（一次真实的手势）。
    ///
    /// 坐标要在**文本行**上：卡片内 padding 16、标题在上、正文在其下一行。
    /// 用 `NSApp.sendEvent` 直接投递，绕开 CGEvent 的辅助功能权限要求
    /// （与 `paste-dispatch` 探针同一套理由）。
    private func dragSelect(in window: NSWindow) {
        let y = window.contentLayoutRect.height / 2
        let from = NSPoint(x: 18, y: y)
        let to = NSPoint(x: window.contentLayoutRect.width - 40, y: y)
        let steps: [(NSEvent.EventType, NSPoint)] = [
            (.leftMouseDown, from),
            (.leftMouseDragged, NSPoint(x: (from.x + to.x) / 2, y: y)),
            (.leftMouseDragged, to),
            (.leftMouseUp, to),
        ]
        for (type, point) in steps {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// keyCode 是**物理键位**，与键盘布局无关：0 = A、8 = C。
    private func send(key: String, keyCode: UInt16) {
        guard let window else { return }
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil, characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: keyCode)!
        NSApp.sendEvent(event)
    }

    /// 结论有**三种**，必须分开报（与 `paste-dispatch` 探针同一纪律）：
    ///
    /// - `LINK-OK`：可选文本被复制走了 → 链路成立；
    /// - `INCONCLUSIVE`：两路结果一样 → **测不出结论**；
    /// - `PROBE-BROKEN`：不可选文本也被复制走了 → 探针本身失效。
    ///
    /// 中间那一种绝不能报成前两种之一：把「测不出」报成「坏了」会让人去查
    /// 一个不存在的 bug，报成「通过」则会掩盖真故障。
    private func report() {
        let got = NSPasteboard.general.string(forType: .string) ?? "(空)"
        let copied = got.contains(probeText)

        print("[\(mode)] 期望：\(selectable ? "剪贴板里出现" : "剪贴板里**不**出现")「\(probeText)」")
        print("[\(mode)] 实得：\(got)")
        if selectable {
            print(copied ? "CONCLUSION: LINK-OK"
                         : "CONCLUSION: INCONCLUSIVE")
        } else {
            print(copied ? "CONCLUSION: PROBE-BROKEN"
                         : "CONCLUSION: LINK-OK")
        }
        // 结论由脚本读输出行判定，不靠退出码（真 run() 里 exit(n) 拿回来永远是 0）。
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = Probe()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
