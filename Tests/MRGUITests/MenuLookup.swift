import AppKit

/// 在菜单里**递归**按标题找菜单项。
///
/// ## 为什么必须递归，而不是只查顶层
///
/// 2026-10-14 之前，状态栏菜单里的设置项是平铺的，测试与 GUI 探针都用
/// `menu.items.first { $0.title == … }` 在顶层找。那次归类把它们收进了
/// 「录音设置 / 存储与清理 / 隐私」三个子菜单，于是 24 条用例集体变红——
/// 而**功能一条没坏**，坏的是查找路径。
///
/// 这正是这条辅助存在的理由：菜单被重新归类是**产品决定**，会让它变；
/// 而「这个开关还在、还接对动作、勾选状态跟不跟偏好走」是**不变量**，不该变。
/// 所以断言写成「在整棵菜单树里找得到」，无论它在一级还是三级。
///
/// ## 为什么递归而不是「按层级数找」
///
/// 写死「在子菜单的子菜单里找」等于把这次归类的形状也钉进测试，
/// 下次调整层级又得全改一遍。递归只依赖「找得到」这一件事。
///
/// - Parameters:
///   - menu: 任意层级的菜单。
///   - title: 要找的标题，**精确匹配**（调用方用 `hasPrefix` 处理带摘要的入口）。
///   - whereToStop: 递归深度上限。菜单树只有两层，8 足够；
///     设上限是为了在出现环时能终止，而不是把测试挂死。
func mrFindMenuItem(
    in menu: NSMenu,
    title: String,
    whereToStop depth: Int = 8
) -> NSMenuItem? {
    if let hit = menu.items.first(where: { $0.title == title }) { return hit }
    guard depth > 0 else { return nil }
    for item in menu.items {
        guard let sub = item.submenu,
                  let hit = mrFindMenuItem(in: sub, title: title, whereToStop: depth - 1)
        else { continue }
        return hit
    }
    return nil
}

/// 递归找出标题带某个前缀的菜单项（用于「降混策略：只取第 1 声道」这类
/// 标题里带当前取值的入口）。
func mrFindMenuItem(
    in menu: NSMenu,
    titleHasPrefix prefix: String,
    whereToStop depth: Int = 8
) -> NSMenuItem? {
    if let hit = menu.items.first(where: { $0.title.hasPrefix(prefix) }) { return hit }
    guard depth > 0 else { return nil }
    for item in menu.items {
        guard let sub = item.submenu,
                  let hit = mrFindMenuItem(in: sub, titleHasPrefix: prefix, whereToStop: depth - 1)
        else { continue }
        return hit
    }
    return nil
}

/// 把一棵菜单树摊平成「标题」的数组，用于失败信息。
///
/// 报错时只打顶层标题的话，用户看到的是一串「录音设置 / 存储与清理 / 隐私」，
/// 看不到设置项自己叫什么——于是「实际只有」这句话等于没给线索。
func mrFlattenMenuTitles(_ menu: NSMenu, depth: Int = 8) -> [String] {
    var out: [String] = []
    // 写成嵌套函数而不是 `let walk: (NSMenu, Int) -> Void = { … walk(…) }`：
    // 后者会捕获自己，而 Swift 不允许在声明处引用尚未初始化的局部变量，
    // 编译直接报 "use of local variable before its declaration"。
    func walk(_ m: NSMenu, _ d: Int) {
        for item in m.items {
            out.append(item.title)
            if d > 0, let sub = item.submenu { walk(sub, d - 1) }
        }
    }
    walk(menu, depth)
    return out
}