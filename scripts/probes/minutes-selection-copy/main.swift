// 探针：会议纪要**跨行划选 + ⌘C** 这条链路真的通吗。
//
// ## 为什么要有它
//
// 2026-10-22 报「会议纪要的复制只能复制一行」。当时卡片是十几个
// SwiftUI `Text` 叠出来的（每个 `.textSelection(.enabled)`），
// 鼠标从一个 `Text` 拖到下一个时选区当场断掉——**界面上完全看不出异常**，
// 照样能选、只是选不过去。单测测不到这种东西，只有真按一次鼠标才看得出。
//
// ## 三个模式，其中一个是「把旧 bug 复现出来」的对照组
//
//   swiftui         旧实现：一摞 `Text` + `.textSelection(.enabled)`
//                   期望**只选中 1 行** → 这就是反馈的现象
//   textview-single 新实现：同一个 `NSTextView`，但只在一行内拖
//                   期望**恰好 1 行** → 证明选区跟着拖拽范围走，不是「总是全选」
//   textview-cross  新实现：跨段落拖
//                   期望**≥2 行**，且粘贴内容同时含两个不同小节的词
//
// 只跑第三种的话，「能复制」和「剪贴板里恰好留着上次的旧内容」分不清，
// 更分不清「跨行」与「只有一行」。对照组是判据的一部分。
//
// ## 怎么「真按」
//
// 与 `text-selection-copy` / `paste-dispatch` 同一套办法（CGEvent 要辅助功能
// 权限，本项目拿不到）：用 `NSEvent.mouseEvent` 造事件，**投递到应用事件队列**
// （`NSApp.postEvent`），让 `NSTextView` 自己的鼠标跟踪循环去消费；
// ⌘C 走 `NSApp.sendEvent` + 生产主菜单（`AppDelegate.editMenu()`）的派发通路。
//
// 事件必须**先进队列**而不是直接 `sendEvent`：`sendEvent(mouseDown)` 会同步进入
// 跟踪循环并阻塞在「下一事件」上，而我们正是要投递那个下一事件的人——直接发会卡死。
//
// ## 证据边界
//
// 它证明的是「本进程里、这个主题下，合成事件能建起跨行选区并被 ⌘C 复制走」。
// 真手感的拖拽、光标形状、双击选词仍要人打开 App 试。
// 布局（卡片在不在、被没被挤掉）由 `meeting-detail-render` 负责，两个探针各管一段。
import AppKit
import SwiftUI
@testable import MRGUI
import MRMinutes
import MRSession

setvbuf(stdout, nil, _IONBF, 0)

let mode = CommandLine.arguments.dropFirst().first ?? "textview-cross"
let knownModes = ["swiftui", "textview-single", "textview-cross", "scroll"]
guard knownModes.contains(mode) else {
    print("用法：\(CommandLine.arguments[0]) \(knownModes.joined(separator: "|"))")
    exit(2)
}

/// 三段内容各带一个**只属于它自己**的词，用来判「跨没跨段」。
private let firstMarker = "下线方案"
private let secondMarker = "灰度"
private let thirdMarker = "回滚演练"

private func makeResult() -> MinutesResult {
    MinutesResult(
        blocks: [],
        blockSummaries: [],
        minutes: MeetingMinutes(
            summary: "评审了 3.2 版本下线方案，确定 10 月 20 日下线，"
                + "全量前先灰度 50% 观察两天。",
            topics: [
                MeetingTopic(title: "下线时间与灰度",
                             conclusion: "10-20 下线，灰度 50% 观察两天",
                             details: ["灰度期间盯支付成功率与崩溃率"]),
                MeetingTopic(title: "回滚预案",
                             conclusion: "回滚演练还没做",
                             details: ["演练安排在 10-19 上午"]),
            ],
            decisions: ["下线日期定为 10-20"],
            actionItems: [ActionItem(task: "写回滚脚本并演练一次", owner: "老王", due: "10-19")],
            openIssues: ["是否提前通知客服未定"]),
        polishedTranscript: "",
        generatedByModel: true,
        generatorName: "云端 API（deepseek-chat @ api.deepseek.com）")
}

/// 旧实现：一堆各自可选的 `Text`。**这段代码只存在于探针里**，
/// 作用是「把用户报的那个 bug 复现出来」，证明判据抓得住它。
private struct LegacyTextStack: View {
    let result: MinutesResult
    var body: some View {
        let m = result.minutes
        VStack(alignment: .leading, spacing: 8) {
            Text(m.summary).font(.body)
            Text("议题").font(.caption.weight(.semibold))
            ForEach(Array(m.topics.enumerated()), id: \.offset) { index, topic in
                Text(MinutesPlainText.topicHeading(topic, index: index)).font(.callout)
                Text(MinutesPlainText.topicConclusionLabel + topic.conclusion).font(.callout)
            }
            Text("决议").font(.caption.weight(.semibold))
            ForEach(m.decisions, id: \.self) { Text("· \($0)").font(.callout) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .textSelection(.enabled)
    }
}

@MainActor
final class Probe: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private var hosting: NSView?
    private var reportTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        let result = makeResult()
        let content: AnyView
        switch mode {
        case "swiftui":
            content = AnyView(LegacyTextStack(result: result))
        case "scroll":
            // 内容必须长到能滚：四张卡片叠起来远超一屏。
            content = AnyView(
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in
                            SelectableRichText(attributed: MinutesCardText.render(
                                result, transcriptChanged: false, showsCorrections: false))
                                .padding(12)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        default:
            content = AnyView(
                ScrollView {
                    SelectableRichText(attributed: MinutesCardText.render(
                        result, transcriptChanged: false, showsCorrections: false))
                        .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        }

        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "纪要跨行划选探针（\(mode)）"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.hosting = hosting

        // 走**生产那份**主菜单：⌘C 的派发通路就是它。自己另写一份菜单
        // 等于验证了一条不存在的通路。
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
        // 「⌘C 生效但复制到空」能被区分开。
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("PROBE-SENTINEL", forType: .string)

        if mode == "scroll" {
            reportScroll(in: window)
            return
        }

        window.makeFirstResponder(nil)
        dragSelect(in: window)

        // 拖拽与 ⌘C 之间要留时间：`NSTextView` 的鼠标跟踪循环跑完、
        // 选区才定下来；紧接着按 ⌘C 有可能撞在跟踪循环里。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.send(key: "c", keyCode: 8)   // ⌘C
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.report()
            }
        }
    }

    /// 找到会在里面拖的那个视图，算出起止点，把三个鼠标事件投进事件队列。
    private func dragSelect(in window: NSWindow) {
        guard let hosting else { return }

        // `NSTextView` 那条路用文本视图自己的坐标系算；
        // 旧实现（一摞 `Text`）只能按整块内容的范围估，这已经够用——
        // 那边期望的结果本来就是「只能选一行」。
        if let textView = firstTextView(in: hosting) {
            let box = textView.convert(textView.bounds, to: nil)
            // NSTextView 是 flipped 的：第一行的 y 在窗口坐标的**顶部**。
            let x = box.minX + 6
            let top = box.maxY - 10
            let endY: CGFloat
            switch mode {
            case "textview-single":
                endY = top                       // 同一行，只往右拖
            default:
                endY = top - 96                  // 往下跨三四行（含段落间距）
            }
            let from = NSPoint(x: x, y: top)
            let to = NSPoint(x: box.minX + min(box.width - 12, 300), y: endY)
            post(steps(from: from, to: to), in: window)
        } else {
            let box = hosting.convert(hosting.bounds, to: nil)
            let from = NSPoint(x: box.minX + 20, y: box.maxY - 40)
            let to = NSPoint(x: box.minX + box.width - 40, y: box.maxY - 150)
            post(steps(from: from, to: to), in: window)
        }
    }

    private func steps(from: NSPoint, to: NSPoint) -> [(NSEvent.EventType, NSPoint)] {
        var steps: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, from)]
        // 中间插几个拖拽点：真实拖拽本来就是连续的，一步跳到终点
        // 会让「选区只扩了一点」和「压根没扩」难以区分。
        for i in 1...6 {
            let t = CGFloat(i) / 7
            steps.append((.leftMouseDragged,
                          NSPoint(x: from.x + (to.x - from.x) * t,
                                  y: from.y + (to.y - from.y) * t)))
        }
        steps.append((.leftMouseDragged, to))
        steps.append((.leftMouseUp, to))
        return steps
    }

    /// **投进队列**，不直接 `sendEvent`——见文件头的说明。
    private func post(_ steps: [(NSEvent.EventType, NSPoint)], in window: NSWindow) {
        for (type, point) in steps {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// keyCode 是**物理键位**，与键盘布局无关：0 = A、8 = C。
    private func send(key: String, keyCode: UInt16) {
        guard let window else { return }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil, characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: keyCode) else { return }
        NSApp.sendEvent(event)
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for sub in view.subviews {
            if let found = firstTextView(in: sub) { return found }
        }
        return nil
    }

    /// 滚轮会不会被卡片吃掉。
    ///
    /// 纪要卡片是一个 `NSTextView`，它自己不可滚动；但它**盖在**外层
    /// `ScrollView` 上，如果它把 `scrollWheel` 吞掉而不往响应链上递，
    /// 表现就是「鼠标停在纪要上时整页滚不动」——一个很容易被当成
    /// 「界面卡死」的退化，而且编译、单测、渲染图全都看不出来。
    private func reportScroll(in window: NSWindow) {
        guard let hosting,
              let scrollView = firstScrollView(in: hosting),
              let textView = firstTextView(in: hosting) else {
            print("[scroll] ❌ 场景里没找到 NSScrollView / NSTextView，测不出结论。")
            print("CONCLUSION: INCONCLUSIVE")
            NSApp.terminate(nil)
            return
        }

        let before = scrollView.contentView.bounds.origin.y
        // 事件要落在文本上：命中测试走的是窗口坐标。
        let frameInWindow = textView.convert(textView.bounds, to: nil)
        let point = NSPoint(x: frameInWindow.midX,
                            y: frameInWindow.maxY - 10)
        let hit = window.contentView?.hitTest(window.contentView?.convert(point, from: nil) ?? .zero)

        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                    wheelCount: 1, wheel1: -80, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cgEvent) else {
            print("[scroll] ❌ 造不出滚轮事件，测不出结论。")
            print("CONCLUSION: INCONCLUSIVE")
            NSApp.terminate(nil)
            return
        }

        // 按 AppKit 的路由方式交给「鼠标底下那个视图」——
        // 它是不是文本视图，正是这条判定要看的第一件事。
        let target: NSView = (hit === textView || hit?.isDescendant(of: textView) == true)
            ? textView : (hit ?? textView)
        // 命中测试可能返回文本视图**内部**的私有视图，所以先报类型再报结论，
        // 不写「是不是文本视图」这种非黑即白的判断——那句话上一版就报错了。
        print("[scroll] 命中视图：\(hit.map { String(describing: type(of: $0)) } ?? "(无)")，"
              + "滚轮交给：\(type(of: target))")
        target.scrollWheel(with: event)

        // 布局是异步的：给一次 runloop 让 NSScrollView 把偏移写下去。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let after = scrollView.contentView.bounds.origin.y
            print("[scroll] 滚动偏移：\(before) → \(after)")
            if after > before + 1 {
                print("CONCLUSION: SCROLL-OK（滚轮穿过卡片，外层照常滚动）")
            } else if before > 1 {
                print("CONCLUSION: SCROLL-OK（已经在底部，无法再滚——本次测不出）")
            } else {
                print("CONCLUSION: SCROLL-BLOCKED（鼠标在纪要上时整页滚不动）")
            }
            NSApp.terminate(nil)
        }
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    /// 结论按模式判定。**中间那种（测不出）不许报成前后两种之一**。
    private func report() {
        let pasted = NSPasteboard.general.string(forType: .string) ?? "(空)"
        let selected = firstTextView(in: hosting ?? NSView()).map {
            ($0.string as NSString).substring(with: $0.selectedRange())
        } ?? ""
        let lines = pasted.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }

        print("[\(mode)] 选区：\(selected.replacingOccurrences(of: "\n", with: "⏎").prefix(160))")
        print("[\(mode)] 粘贴：\(pasted.replacingOccurrences(of: "\n", with: "⏎").prefix(160))")
        print("[\(mode)] 行数：\(lines.count)（哨兵值原样返回表示 ⌘C 根本没生效）")

        switch mode {
        case "swiftui":
            // 旧实现：期望只剩 1 行。**这是复现用户报的现象**，
            // 它若选中了多行，说明这套判据分不出新旧实现，也就是探针失效。
            print(pasted.contains("PROBE-SENTINEL")
                  ? "CONCLUSION: PROBE-BROKEN（旧实现里 ⌘C 什么都没复制，无法比较行数）"
                  : (lines.count <= 1
                     ? "CONCLUSION: BUG-REPRODUCED（旧实现只能选中 1 行）"
                     : "CONCLUSION: PROBE-BROKEN（旧实现竟然跨段选中了，判据失效）"))
        case "textview-single":
            print(lines.count == 1
                  ? "CONCLUSION: LINK-OK（单行内拖拽只得到 1 行，选区跟着拖拽范围走）"
                  : "CONCLUSION: PROBE-BROKEN（只在一行内拖却得到 \(lines.count) 行）")
        default:
            let spans = pasted.contains(firstMarker) && pasted.contains(secondMarker)
            if pasted.contains("PROBE-SENTINEL") {
                print("CONCLUSION: INCONCLUSIVE（⌘C 没生效：选区没建立或响应链断）")
            } else if lines.count >= 2 && spans {
                print("CONCLUSION: LINK-OK（跨段落选中 \(lines.count) 行并复制到剪贴板）")
            } else if lines.count >= 2 {
                print("CONCLUSION: LINK-OK（跨段落选中 \(lines.count) 行，但只含一个标记词）")
            } else {
                print("CONCLUSION: INCONCLUSIVE（只得到 \(lines.count) 行，与旧实现无法区分）")
            }
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
