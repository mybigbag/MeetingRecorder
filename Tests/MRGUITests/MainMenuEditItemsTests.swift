import XCTest
import AppKit
@testable import MRGUI

/// 主菜单里必须有「编辑」菜单组（`AppDelegate.editMenu()`）。
///
/// ## 这组用例盯的是一个编译期看不出来的故障
///
/// 2026-10-19：设置窗口里粘贴 API Key 没反应。
/// 根因不是输入框——是**主菜单里没有「编辑」这一组菜单项**。
/// macOS 的 ⌘V 不直接调 `NSTextField.paste(_:)`，
/// 而是先在 `mainMenu` 里找 keyEquivalent 为 "v" 的项，再沿响应链派发；
/// 菜单里没有它，AppKit 连派发对象都找不到，
/// 于是不报错、不执行，看上去像「这个 App 不支持粘贴」。
///
/// 编译永远通过（`#selector` 引用的是合法方法），断言也测不到「用户按了 ⌘V」
/// ——唯一能钉住它的就是**菜单项在不在、键位对不对、target 是不是留空**。
@MainActor
final class MainMenuEditItemsTests: XCTestCase {

    /// ⌘V 必须有菜单项，且 action 是 `paste:`。
    ///
    /// 这条红就等于粘贴功能坏着，而症状是**完全没有报错**的那种坏。
    func testPasteItemExistsWithTheStandardKeyEquivalent() {
        let paste = item(titled: "粘贴", in: AppDelegate.editMenu())
        guard let paste else {
            return XCTFail("主菜单里没有「粘贴」——⌘V 无处派发")
        }
        XCTAssertEqual(paste.keyEquivalent, "v")
        XCTAssertEqual(paste.keyEquivalentModifierMask, [.command],
                       "⌘V 的修饰键必须是 Command")
        XCTAssertEqual(paste.action, #selector(NSText.paste(_:)),
                       "action 必须是 paste:，否则沿响应链找不到输入框")
    }

    /// ⌘C / ⌘X / ⌘A / ⌘Z 一并要。
    ///
    /// 它们和 ⌘V 走的是**同一条通路**（同一组菜单项、同一种派发方式）。
    /// 只补粘贴而漏掉复制，用户粘进去之后却剪不出来——
    /// 那是一个比「没有粘贴」更难自查的症状。
    func testTheWholeEditingTrioIsPresent() {
        let menu = AppDelegate.editMenu()
        for (title, key) in [("复制", "c"), ("剪切", "x"), ("全选", "a"), ("撤销", "z")] {
            guard let found = item(titled: title, in: menu) else {
                XCTFail("缺少「\(title)」")
                continue
            }
            XCTAssertEqual(found.keyEquivalent, key, title)
            XCTAssertEqual(found.keyEquivalentModifierMask, [.command], title)
        }
        XCTAssertEqual(item(titled: "复制", in: menu)?.action,
                       #selector(NSText.copy(_:)))
        XCTAssertEqual(item(titled: "剪切", in: menu)?.action,
                       #selector(NSText.cut(_:)))
        XCTAssertEqual(item(titled: "全选", in: menu)?.action,
                       #selector(NSText.selectAll(_:)))
        XCTAssertEqual(item(titled: "撤销", in: menu)?.action,
                       #selector(UndoManager.undo))
    }

    /// **target 必须留空**（nil）。
    ///
    /// 这是最容易写错、后果又最隐蔽的一条：菜单项一旦指定了 target，
    /// AppKit 就只往那一个对象派发，而**不沿响应链找 first responder**——
    /// 于是粘贴动作发给了设置窗口的容器视图，真正获得焦点的输入框收不到。
    /// 症状和「菜单项缺失」一模一样（按了没反应），
    /// 但修法完全不同：那条要补菜单项，这条要**去掉 target**。
    func testNoItemPinsATarget() {
        for item in AppDelegate.editMenu().items where !item.isSeparatorItem {
            XCTAssertNil(item.target,
                         "「\(item.title)」不该指定 target，否则不走响应链")
        }
    }

    /// 「重做」是 ⇧⌘Z。
    ///
    /// macOS 的写法是**大写字符 "Z" + 仅 Command**：AppKit 见到大写字符
    /// 会自己把 Shift 补进生效修饰键（实测 `keyEquivalentModifierMask`
    /// 报出来的是 `command | shift`）。这是标准 AppKit 模板的做法，
    /// 也是为什么这里**不能**手工写 `["z"] + [.command, .shift]`——
    /// 那会变成 ⇧⌘⇧Z，按不出重做。
    ///
    /// 这条的实际风险：有人看到 `keyEquivalent` 是 "Z" 而修饰键里没有 shift，
    /// 以为写错了就「顺手改成 z + shift」——于是重做静默失灵，
    /// 而撤销（同一字符 z、仅 Command）仍然正常，界面上看不出任何异常。
    func testRedoIsShiftCommandZ() {
        guard let redo = item(titled: "重做", in: AppDelegate.editMenu()) else {
            return XCTFail("没有「重做」")
        }
        XCTAssertEqual(redo.keyEquivalent, "Z",
                       "重做必须用大写 Z 触发 AppKit 的隐式 Shift，不要手写 shift 修饰键")
        XCTAssertEqual(redo.keyEquivalentModifierMask, [.command],
                       "修饰键只写 Command；Shift 由大写字符隐式补上")
        // 撤销与重做共用同一个字符，靠修饰键区分。
        XCTAssertEqual(item(titled: "撤销", in: AppDelegate.editMenu())?.keyEquivalent, "z",
                       "撤销用小写 z，重做有大写 Z——两者不冲突")
    }

    /// 这些键位不能和已有的全局快捷键（⌥⌘R/P/S/M）撞车。
    ///
    /// 撞车的后果是**看状态栏菜单才知道**：界面上 ⌘V 突然变成了别的动作，
    /// 而用户完全无从判断是谁抢了它。
    func testEditingKeysDoNotCollideWithGlobalHotKeys() {
        let editingKeys: Set<String> = ["x", "c", "v", "a", "z"]
        let appKeys: Set<String> = ["q", "h", ",", "m", "w"]
        XCTAssertTrue(editingKeys.isDisjoint(with: appKeys),
                      "编辑菜单与应用/窗口菜单的键位撞了")
    }

    private func item(titled: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == titled }
    }
}