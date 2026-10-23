import SwiftUI
import MRSession

/// 「在菜单栏显示图标」开关。**设置窗口与顶栏「录音设置」面板共用这一个视图。**
///
/// ## 为什么抽成共享视图，而不是两处各写一个 Toggle
///
/// 这个开关有三个入口（状态栏菜单、本视图的两个宿主），而**关掉它之后
/// 状态栏菜单就没了**——也就是说，用户恢复图标时能看到的只有这两个宿主。
/// 两处各写一份的话，迟早会漂：「⌘, 里说快捷键可用、面板里说会停录音」
/// 这种自相矛盾没有任何理由存在，而用户拿界面当唯一依据，没法知道哪个对。
/// 文案（`SettingsCopy.statusIconDetails`）、确认时机
/// （`shouldConfirmHidingIcon`）、弹窗正文全部只有一份。
///
/// ## 为什么关闭前要确认
///
/// 关掉图标的那一刻，菜单栏上唯一跟着录音走的东西（计时、红点）会一起消失。
/// 录音本身不受影响——快捷键与主窗口都不经过状态栏——但「录着录着发现
/// 菜单栏什么都没了」足以让人以为录崩了。这个误会只需要一次点击就能避免，
/// 所以值得；空闲时不确认，那时候菜单栏上本来也没有状态可看。
///
/// ## 排版
///
/// 用 `SettingsRow` 与设置窗口里其它行**同一套排版**：一行标题、一句常驻说明、
/// 右边一个开关。说明跟着当前状态说人话（开着讲「关了会怎样」，关着讲「怎么恢复」），
/// 不再挂在 hover 浮层上——浮层会盖住下面那一项。
struct StatusBarIconToggle: View {

    @ObservedObject var workspace: MeetingWorkspace
    /// 关闭图标的确认弹窗。只在「录制中关闭」这一种情况下出现。
    @State private var confirmingHide = false

    var body: some View {
        SettingsRow(title: SettingsCopy.statusIconTitle,
                    subtitle: SettingsCopy.statusIconOneLine(
                        showsIcon: workspace.showsStatusBarIcon),
                    details: SettingsCopy.statusIconDetails) {
            Toggle("", isOn: Binding(
                get: { workspace.showsStatusBarIcon },
                set: { newValue in
                    // 打开永远安全；关闭要先看是不是正在录。
                    // 确认时**不预置** `showsStatusBarIcon = false`——
                    // 那样用户点「取消」后勾选状态已经翻了，得靠别处改回来。
                    guard !newValue,
                          StatusItemController.shouldConfirmHidingIcon(
                              phase: workspace.recorder.phase)
                    else {
                        workspace.showsStatusBarIcon = newValue
                        return
                    }
                    confirmingHide = true
                }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .alert(StatusItemController.hideIconAlertTitle, isPresented: $confirmingHide) {
            Button("隐藏图标") { workspace.showsStatusBarIcon = false }
            Button("取消", role: .cancel) {}
        } message: {
            Text(StatusItemController.hideIconAlertMessage)
        }
    }
}
