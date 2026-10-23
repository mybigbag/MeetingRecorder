import SwiftUI
import MRSession

/// 「菜单栏图标没出现」的提示条。
///
/// ## 它现在回答什么
///
/// 一个问题：**系统到底有没有把这个应用登记进菜单栏**。
///
/// ## 2026-10-20 的语义变更（重要）
///
/// 这个提示原来回答的是「图标与窗口是不是在同一块屏」，
/// 并给一个「把窗口移过去」的动作。那套做法建立在两个**已被证伪**的前提上：
///
/// 1. 「状态栏项跟随 key window 所在屏」——**不成立**。实测状态栏项在
///    **每一块屏的菜单栏上各有一份**，始终同步：启动时两块屏的菜单栏项数
///    同时 +1，退出时同时 -1，两块屏的宽度签名完全一致。
///    「主副屏的状态栏图标是一致的」这个观察是对的。
/// 2. 「图标被排到另一块屏 → 把窗口搬过去就能看到」——**不成立**，
///    而且那个动作会**擅自搬走用户自己的窗口**，是一个有害副作用。
///
/// 现在它只在系统真的没登记这个项时出现，并说清原因与办法。
struct StatusIconScreenNotice: View {

    @ObservedObject var workspace: MeetingWorkspace

    var body: some View {
        if let hint = workspace.statusIconScreenHint {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("菜单栏图标没有出现")

                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.10))
        }
    }
}
