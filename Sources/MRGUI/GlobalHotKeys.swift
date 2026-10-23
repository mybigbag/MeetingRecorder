import Foundation
import Carbon

/// 全局快捷键。
///
/// **为什么用 Carbon 的 `RegisterEventHotKey`，而不是 `NSEvent.addGlobalMonitorForEvents`：**
/// 后者需要「辅助功能」授权。那是一个比屏幕录制更敏感的权限，为了四个快捷键去要它
/// 并不合适；更糟的是用户拒绝之后它**静默失效**——回调根本不触发，没有任何报错，
/// 界面看起来完全正常。`RegisterEventHotKey` 不需要任何额外授权。
///
/// 代价要说清楚：注册上的组合会被**全局独占**，别的程序再也收不到它。
/// 所以只用 ⌥⌘ 这种少用的组合，并且**注册失败必须报出来**（见 `failures`）——
/// 否则用户会遇到「按了没反应，也不知道为什么」。
///
/// 另一个已知边界：系统保留的组合（例如被输入法抢走的）注册会失败，
/// 这时对应的功能仍然可以从状态栏菜单点。
@MainActor
final class GlobalHotKeys {

    /// 一个组合键
    struct Binding {
        /// 显示名，用于报错
        var name: String
        /// 显示用的键面，例如 `⌥⌘R`
        var display: String
        var keyCode: UInt32
        var modifiers: UInt32
        var action: () -> Void
    }

    /// 热键的签名（四个字符）。同一个进程内用来区分来源。
    ///
    /// 不是 `private`：测试要用真实签名注入事件（见 `StatusBarLifecycleTests`），
    /// 才能验证「事件 → handler → 动作」这段链路。
    /// `nonisolated`：它是个纯常量，还要能出现在非隔离上下文的默认参数里
    /// （Swift 6 下带主 actor 隔离的静态属性在那里会直接报错）。
    nonisolated static let signature: OSType = 0x4D52_484B   // 'MRHK'

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    /// 注册失败的组合（被别的程序占用、系统保留等）。**不静默**——
    /// 界面会把它显示出来，否则用户只会觉得「快捷键坏了」。
    private(set) var failures: [String] = []

    /// Carbon 的回调是 C 函数指针，不能捕获上下文，只能经这个静态引用找回自己。
    private static var current: GlobalHotKeys?

    init(bindings: [Binding]) {
        GlobalHotKeys.current = self

        for (index, binding) in bindings.enumerated() {
            let id = UInt32(index + 1)
            actions[id] = binding.action

            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: GlobalHotKeys.signature, id: id)
            let status = RegisterEventHotKey(
                binding.keyCode, binding.modifiers, hotKeyID,
                GetApplicationEventTarget(), 0, &ref)

            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                failures.append("\(binding.name) \(binding.display)")
            }
        }

        installHandler()
    }

    /// 装事件处理器。
    ///
    /// 必须装在 `GetApplicationEventTarget()` 上：Carbon 的事件目标会把热键事件
    /// 投递到**主线程的主事件循环**，也就是 `NSApplication.run()` 正在跑的那个循环。
    private func installHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID)
                guard err == noErr else { return OSStatus(eventNotHandledErr) }

                // 只认自己的签名。
                //
                // 这不是洁癖：热键事件是投到 `GetApplicationEventTarget()` 上的，
                // 同一个进程里任何一个组件（第三方库、以后新加的模块）注册的热键
                // 都会走到这里。不校验签名的话，它的 id 会直接命中我们的动作表——
                // 比如对方第一个热键的 id 也是 1，就会误触发「开始录制」。
                // 返回 `eventNotHandledErr` 而不是 `noErr`，让它继续往下传给真正的接收方。
                guard hotKeyID.signature == GlobalHotKeys.signature else {
                    return OSStatus(eventNotHandledErr)
                }

                // 这里确实在主 actor 上（见上面 `installHandler` 的说明）。
                // 用 `assumeIsolated` 而不是 `Task { @MainActor in }`：后者会把动作
                // 延后到下一个主循环周期，"按了暂停" 这种操作应当立刻反映到状态栏。
                // 如果哪天投递线程变了，`assumeIsolated` 会直接断言失败——
                // 这正是我们要的失败方式，而不是悄无声息地产生数据竞争。
                MainActor.assumeIsolated {
                    GlobalHotKeys.current?.actions[hotKeyID.id]?()
                }
                return noErr
            },
            1, &spec, nil, &eventHandler)

        if status != noErr {
            failures.append("快捷键监听安装失败（OSStatus \(status)）")
        }
    }

    /// 注销所有热键。不调用的话，程序退出后组合键要等到下一次登录才释放。
    func invalidate() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        GlobalHotKeys.current = nil
    }

    // MARK: - 组合

    /// Carbon 的修饰键常量与 AppKit 的不是一套，必须用 `cmdKey` / `optionKey`。
    static var commandOption: UInt32 { UInt32(cmdKey | optionKey) }

    // 键码用 Carbon 的 `kVK_*`（不是 AppKit 的键值），两者并不相同。
    static let keyR = UInt32(kVK_ANSI_R)
    static let keyP = UInt32(kVK_ANSI_P)
    static let keyS = UInt32(kVK_ANSI_S)
    static let keyM = UInt32(kVK_ANSI_M)
}
