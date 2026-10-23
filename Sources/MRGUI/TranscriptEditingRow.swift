import SwiftUI
import MRCore

/// 编辑态的一段：正文是输入框，时间戳与说话人只读。
///
/// ## 为什么它必须是一个**独立**的 View
///
/// 输入框的文字绑在 `draft`（这一段自己的 `ObservableObject`）上，
/// 而 `draft` 只有这一行持有。于是「敲一个字」的重画范围是**一行**；
/// 若把这段代码留在 `MeetingDetailView` 的方法里，那个视图同时观察着
/// `workspace`，一次输入就会连累整页（1375 行）重算——这正是卡顿的来源。
///
/// ## 为什么时间戳不许改
///
/// 这里改的是「听出来的字」，不是「谁在什么时候说的」。
/// 允许改时间戳会让它和音频对不上，而界面上没有任何办法验证改得对不对。
struct TranscriptEditingRow: View {

    @ObservedObject var draft: TranscriptDraftSession.Draft

    let start: Double
    let speaker: String
    let track: String
    let manualEdit: TranscriptSegment.ManualEdit?
    let originalText: String?

    /// 打了一个字。由详情页转给草稿簿做「防抖提交」。
    let onEdit: () -> Void
    let onClear: () -> Void
    let onRestore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(TranscriptDocument.timestamp(start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .leading)
                .padding(.top, 5)

            Text(speaker)
                .font(.caption.weight(.semibold))
                .foregroundStyle(track == "mic" ? .primary : .secondary)
                .frame(width: 34, alignment: .leading)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                TextField(MeetingDetailView.clearedPlaceholder,
                          text: $draft.text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .lineLimit(1...8)
                    // 每次落键只通知「这一段变了」，不写盘、不动工作区。
                    .onChange(of: draft.text) { _, _ in onEdit() }
                    .accessibilityLabel("第 \(draft.index + 1) 段正文")

                HStack(spacing: 10) {
                    if let edit = manualEdit {
                        Label(edit == .cleared ? "已清空" : "已修正",
                              systemImage: edit == .cleared
                                ? "minus.circle" : "pencil.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if originalText != nil {
                        Button("恢复原文", action: onRestore)
                            .buttonStyle(.link)
                            .font(.caption)
                            .help(MeetingDetailView.restoreHelp(originalText: originalText))
                    }
                    Spacer(minLength: 0)
                    Button(action: onClear) {
                        Label("清空", systemImage: "eraser")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    // 判据用**草稿**里的文字，不是工作区里那份：
                    // 用户刚把这行删空、还没到提交点，按钮就该是禁用的。
                    .disabled(isDraftBlank)
                    .help("把这一段从稿子里去掉（不参与纪要生成）。随时可以「恢复原文」。")
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private var isDraftBlank: Bool {
        draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
