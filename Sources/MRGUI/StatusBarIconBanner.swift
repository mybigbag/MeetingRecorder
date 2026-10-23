import SwiftUI
import MRSession

/// 主窗口里常驻的「菜单栏图标被关了」横幅。
///
/// ## 为什么需要它
///
/// 关掉图标之后，能把它开回来的入口只剩两处：设置窗口（⌘,）与顶栏
/// 「录音设置」面板。**状态栏菜单这条路亲手被用户关掉了**。而「关掉 →
/// 想恢复」这个动作的典型场景是：用户顺手点了关闭，重启一次 App 想恢复
/// 默认（2026-10-20 记录的实际路径），或者过几天回来找入口。
/// 这两种情况下他第一眼看到的是**主窗口**——如果主窗口上什么都没有，
/// 他没有任何可见的线索知道「是我关的」以及「在哪开回来」，
/// 剩下的只有试错（重启、重装、来问人）。
///
/// 所以这个横幅的判据只有一条：**图标关着就一直显示**。
/// 它不弹窗、不自动消失、不需要 dismiss——用户把图标开回来的那一刻
/// 它自己消失，那是唯一的退出条件。
///
/// ## 为什么不放在设置窗口里让用户自己去找
///
/// 「放了个入口」和「用户在需要时看得见入口」是两件事。设置窗口要点 ⌘,
/// 要知道里面有「菜单栏」组，要知道组里有什么；而横幅把这三步缩成一次点击。
/// 弹窗更不行——每次开窗口都弹一次是骚扰，而且「我知道了」点完就没了，
/// 下次还是找不到。
struct StatusBarIconBanner: View {

    @ObservedObject var workspace: MeetingWorkspace

    /// 标题行。抽成常量是为了让测试能断言「用户读到的第一句话是什么」——
    /// 文案内联在 body 里的话，改动它只会改渲染，没有任何东西会红。
    static let title = "菜单栏图标已隐藏"

    /// 正文。两件事必须写进去，少任何一件用户都会慌：
    /// 1. **录音不受影响**——他此刻最怕的是「关了图标是不是把录音也关了」；
    /// 2. **还有别的恢复入口**——横幅只是最显眼的那个，不是唯一的那个。
    ///    写全是为了让用户知道「哦还有设置窗口这条路」，下次不用靠横幅也行。
    static let message = "菜单栏上不再有本应用的图标。录音不受影响：全局快捷键与主窗口照常。"

    /// 恢复按钮。直接生效、**不弹确认**：打开图标是纯增益操作，
    /// 没有可后悔的余地（与 `StatusBarIconToggle` 里「只有关闭才确认」一致）。
    static let restoreTitle = "恢复图标"

    var body: some View {
        if !workspace.showsStatusBarIcon {
            HStack(spacing: 10) {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.orange)
                    .help("菜单栏图标当前处于隐藏状态")

                Text(Self.title + "——" + Self.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button(Self.restoreTitle) {
                    // 打开永远安全——这条路径上没有确认弹窗，
                    // 与 StatusBarIconToggle 的判定保持一致
                    //（只有「关闭」才可能弹，而且只在录制中弹）。
                    workspace.showsStatusBarIcon = true
                }
                .controlSize(.small)
                .help("在菜单栏重新显示本应用的图标与菜单")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.10))
        }
    }
}
