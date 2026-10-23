import SwiftUI
import MRSession

/// 主窗口。
///
/// 布局是「上＝操作，左＝列表，右＝详情」：
/// 录音是唯一需要随时够得着的操作，所以放顶栏；列表与详情是典型的浏览结构。
///
/// **`workspace` 由外面传进来，自己不持有。** 状态栏菜单与全局快捷键也要
/// 「开始/暂停/停止」这场录音，它们必须和这个窗口操作同一个对象；
/// 如果 `workspace` 建在视图里，状态栏就只能再建一个，两边状态永不互通。
struct MeetingRecorderRootView: View {

    @ObservedObject var workspace: MeetingWorkspace
    @StateObject private var player = TrackPlayer()
    @State private var showingError = false

    var body: some View {
        VStack(spacing: 0) {
            RecordingBarView(workspace: workspace) {
                // 录完立刻刷新，新会议要出现在列表顶部。
                // **走异步版**：这一步会重扫 `~/Documents`，而同步版会在主线程上做
                // 权限探测（`open`），撞上 TCC 弹窗就会把界面卡住。
                Task { await workspace.refreshAsync() }
            }
            Divider()

            // 图标被用户关掉时的常驻横幅。放在这里（顶栏正下方）而不是
            // 设置窗口深处，是因为「关掉后想恢复」的场景里用户第一眼
            // 看到的就是主窗口——详见 StatusBarIconBanner 的说明。
            StatusBarIconBanner(workspace: workspace)

            // 图标与窗口不在同一块屏时的提示（macOS 26 每屏各有菜单栏，
            // 状态栏项跟随 key window 所在屏）。放在横幅下面：两条提示
            // 讲的是两件事，但都指向「菜单栏上那个图标」，挨着放才不割裂。
            StatusIconScreenNotice(workspace: workspace)

            HStack(spacing: 0) {
                MeetingListView(workspace: workspace)
                    .frame(width: 300)
                Divider()
                MeetingDetailView(workspace: workspace, player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        // 用 .task 而不是 .onAppear：首次启动时读 `~/Documents` 会触发
        // 「访问文稿文件夹」授权弹窗，而那个读取在弹窗未决时会阻塞。
        // 放主线程的后果是窗口根本不显示（实测堆栈卡在 open()）。
        .task { await workspace.refreshAsync() }
        .onChange(of: workspace.selectedID) { _, _ in
            loadPlayerForSelection()
        }
        .onChange(of: workspace.lastError) { _, newValue in
            showingError = (newValue != nil)
        }
        .alert("需要注意", isPresented: $showingError) {
            Button("知道了") { workspace.clearError() }
        } message: {
            Text(workspace.lastError ?? "")
        }
    }

    /// 切换会议时重新载入播放器。
    /// **必须显式清空**——否则播的会是上一场的音频，而界面显示的是这一场。
    private func loadPlayerForSelection() {
        guard let meeting = workspace.selectedMeeting else {
            player.clear()
            return
        }
        player.load(sessionID: meeting.id, directory: meeting.directory)
    }
}
