import SwiftUI
import MRSession
import MRCore

/// 左栏：会议列表。
struct MeetingListView: View {

    @ObservedObject var workspace: MeetingWorkspace

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
            Divider()
            footer
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("搜索标题", text: $workspace.searchText)
                .textFieldStyle(.plain)
            if !workspace.searchText.isEmpty {
                Button {
                    workspace.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if !workspace.hasScanned {
            // 首次启动还没扫过磁盘。**不能显示「还没有会议记录」**——
            // 那是把「还没查」说成了「没有」。
            scanningView
        } else if let message = workspace.emptyStateMessage {
            // 空列表的原因不止一种，必须分开说。
            // 统一显示「还没有会议记录」会把「没授权」伪装成「没数据」。
            EmptyStateView(
                message: message,
                needsPermission: workspace.needsPermissionGuidance,
                root: workspace.library.root,
                searchActive: !workspace.searchText.isEmpty,
                isScanning: workspace.isScanning,
                onRetry: { Task { await workspace.refreshAsync() } })
        } else {
            List(selection: $workspace.selectedID) {
                ForEach(workspace.visibleMeetings) { meeting in
                    MeetingRowView(
                        meeting: meeting,
                        isTranscribing: workspace.isTranscribing(sessionID: meeting.id))
                        .tag(meeting.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var scanningView: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("正在读取会议目录…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                workspace.revealRootInFinder()
            } label: {
                Label("显示目录", systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Text("\(workspace.meetings.count) 场")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// 列表里的一行
struct MeetingRowView: View {

    let meeting: MeetingSummary
    /// 这一场**正在转写**吗。
    ///
    /// 为什么列表要知道这件事：转写要跑几十秒，用户完全可以中途切到别的会议。
    /// 少了这个标记，切走的那一场就**彻底不可见**了——用户只记得「点了转写」，
    /// 却没有任何地方告诉他那件事还在进行，只能一场场切回去看。
    ///
    /// 传参数而不是让本视图自己去读 workspace：`MeetingRowView` 是纯值视图，
    /// 这样它能在无头环境里单独渲染做冒烟。
    let isTranscribing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(meeting.title)
                    .font(.body)
                    .lineLimit(1)
                if meeting.needsAttention {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if isTranscribing {
                    // 转圈而不是文字：行高只有一行，塞不下「正在转写…」。
                    // 与详情区那个大进度条是同一个语义，用同一个控件家族。
                    ProgressView()
                        .controlSize(.small)
                        .help("这场会议正在转写。可以切到别处，转完这里会自己变成「已转写」。")
                }
                if meeting.hasTranscript {
                    Image(systemName: "text.alignleft")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text(Self.stamp(meeting.startedAt))
                Text("·")
                Text(meeting.durationText)
                Text("·")
                Text("\(meeting.existingTrackCount) 轨")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

/// 空态。**未授权与「确实没有记录」在这里分开呈现。**
struct EmptyStateView: View {

    let message: String
    let needsPermission: Bool
    let root: URL
    let searchActive: Bool
    let isScanning: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: needsPermission ? "lock.fill" : "tray")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)

            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)

            if needsPermission {
                Text("在「系统设置 → 隐私与安全性 → 文件与文件夹」里\n允许「会议录音器」访问「文稿」文件夹。")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)

                HStack(spacing: 8) {
                    Button("打开系统设置") { openPrivacySettings() }
                        .buttonStyle(.borderedProminent)
                    Button("重试") { onRetry() }
                        .disabled(isScanning)
                }
                .controlSize(.small)
            } else if searchActive {
                Text("换个关键词试试")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                // 目录可能是刚被别的进程写入的（比如命令行录了一场），
                // 所以这里也给一个手动的重新扫描入口，而不是靠在 onAppear 里自动跑。
                Button("重新扫描") { onRetry() }
                    .controlSize(.small)
                    .disabled(isScanning)
            }

            Text(root.path)
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .lineLimit(3)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 这里**刻意不放 `.onAppear(perform: onRetry)`**。
        // 曾经有过，后果很严重：空态在首次布局时就出现，于是 onAppear 在主线程上
        // 立刻触发一次同步扫描，`open()` 撞上未决的 TCC 弹窗就阻塞住，
        // 窗口卡在布局阶段根本显示不出来——双击之后什么都没有。
        // 重试必须是用户主动的动作，而且要走异步路径。
    }

    private func openPrivacySettings() {
        // 直达「文件与文件夹」隐私面板，省得用户自己翻
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
        NSWorkspace.shared.open(url)
    }
}
