import Foundation
import Combine
import MRCore

/// 编辑转写稿时的**草稿簿**：每段一份独立的可观察文本 + 一个防抖提交闸门。
///
/// ## 它解决的是「打字卡十秒」这件事
///
/// 1375 段的一场会（本机真实存在的场次），原来的写法有两个致命点：
///
/// 1. **每个键都直接写工作区**。`setTranscriptText` 会编码整份 `transcript.json`
///    （prettyPrinted，290 KB）+ 重渲染整份 `transcript.md` + 两次原子写，
///    全在主线程；与此同时 `transcript` 是 `@Published`，
///    一次赋值就把整个详情页重算一遍——1375 行输入框全部重新布局。
///    每秒打十个字，就是每秒十次全量重排。
/// 2. **每行都绑在工作区上**。`get` 读 `workspace.transcript`，
///    所以那一行必须跟着工作区一起重算，想只刷新一行都做不到。
///
/// 现在：输入只改这一行自己的 `Draft`（只有那一行重画），
/// 停顿 `debounce` 秒之后才把**这一段**的最终文本交给工作区写盘一次。
///
/// ## 为什么防抖之后仍然「不丢字」
///
/// 提交点有四个：停顿到点、退出编辑、切换会议、App 将要退出（`flush()`）。
/// 最坏情况是「打完最后一个字立刻拔电源」，丢的是最后 0.35 秒内的那几个字——
/// 与「每键写盘」相比，这是拿可忽略的窗口换掉肉眼可见的卡顿。
@MainActor
final class TranscriptDraftSession {

    /// 一段的草稿。
    ///
    /// 做成**独立**的 `ObservableObject` 而不是放在会话的一个数组里：
    /// 数组的 `@Published` 会让所有行一起重画，那就等于没优化。
    final class Draft: ObservableObject, Identifiable {
        let index: Int
        @Published var text: String

        var id: Int { index }

        init(index: Int, text: String) {
            self.index = index
            self.text = text
        }
    }

    let drafts: [Draft]

    /// 停顿多久之后提交。0.35 秒是「一个词的间隔」与「一次重排的代价」之间的取舍：
    /// 再短就会在连续输入时频繁触发，再长会让「退出编辑前的最后一句」更容易丢。
    let debounce: TimeInterval

    /// 真正写盘的动作（工作区那一份）。返回 `false` 表示没写成功。
    var commit: ((Int, String) -> Bool)?
    /// 写盘失败后取回「磁盘上那份」的正文，用来把输入框回滚。
    var diskText: ((Int) -> String?)?

    /// 待提交的段落下标。
    private var pending: Set<Int> = []
    private var scheduled: Task<Void, Never>?

    /// 已经提交过几次。测试用它证明「打十个字只写一次盘」。
    private(set) var commitCount = 0

    init(document: TranscriptDocument, debounce: TimeInterval = 0.35) {
        self.drafts = document.segments.enumerated().map {
            Draft(index: $0.offset, text: $0.element.text)
        }
        self.debounce = debounce
    }

    var hasPending: Bool { !pending.isEmpty }

    // MARK: - 输入

    /// 某一段被改了一个字。**只记下待提交，不写盘。**
    func noteChange(at index: Int) {
        guard drafts.indices.contains(index) else { return }
        pending.insert(index)
        scheduled?.cancel()
        let delay = debounce
        scheduled = Task { [weak self] in
            // `Task.sleep` 被取消时立刻抛出，所以连续输入只会留下最后一个计时器。
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.commitPending()
        }
    }

    /// 这一段不要了：清空/恢复原文之前先撤掉它的待提交，
    /// 否则 0.35 秒后会把用户刚清掉的文字**写回去**。
    func cancelPending(at index: Int) {
        pending.remove(index)
        if pending.isEmpty { scheduled?.cancel() }
    }

    /// 清空/恢复原文之后，把草稿同步成新的正文。
    ///
    /// 必须同步，不能靠行视图重读工作区：那一行现在只认草稿，
    /// 不同步的话它会一直显示旧文字，而磁盘上已经是新的了。
    func syncDraft(at index: Int, to text: String) {
        guard drafts.indices.contains(index), drafts[index].text != text else { return }
        drafts[index].text = text
        pending.remove(index)
    }

    // MARK: - 提交

    /// 立刻提交所有待提交的段。退出编辑、切会议、退出 App 时调用。
    func flush() {
        scheduled?.cancel()
        scheduled = nil
        commitPending()
    }

    private func commitPending() {
        guard !pending.isEmpty else { return }
        let indices = pending.sorted()
        pending.removeAll()
        for (position, index) in indices.enumerated() {
            guard drafts.indices.contains(index) else { continue }
            let text = drafts[index].text
            commitCount += 1
            guard commit?(index, text) ?? true else {
                // 写盘失败：工作区已经把内存退回「磁盘上那份」，输入框也要退回去——
                // 否则界面上留着一段其实没存下来的字，刷新一次就凭空复原。
                if let disk = diskText?(index) { drafts[index].text = disk }
                // 后面那几段**重新排回队里**：一次失败不该把它们悄悄丢掉。
                // 不排回去的话，用户改的三段里只有第一段报错、后两段无声消失。
                pending.formUnion(indices[(position + 1)...])
                return
            }
        }
    }
}
