import SwiftUI
import AppKit

/// 只读、但**整块内容共用一条选区**的富文本视图。
///
/// ## 为什么不能用 `.textSelection(.enabled)`
///
/// 那是 SwiftUI 的**逐 Text** 选择：每个 `Text` 是一个独立的选择层，
/// 鼠标从一个 `Text` 拖到下一个时选区**当场断掉**，于是用户只能选中一行。
/// 纪要卡片是「摘要 + 议题 + 决议 + 待办」好几个 `Text` 摞起来的，
/// 反馈的「只能复制一行」就是这个原因——不是复制按钮坏了，
/// 而是根本选不中第二行。
///
/// 把整张卡片的内容渲染成**一个** `NSTextView` 之后，选区是文本视图自己的，
/// 跨行、跨段、跨小节都是同一条选区；⌘C、⌘A、右键「复制」也全由 AppKit
/// 原生提供（`mainMenu` 里必须有「编辑」组，见 `AppDelegate.editMenu()`）。
///
/// ## ⚠️ `sizeThatFits` 里**一个字节都不许改视图状态**
///
/// 2026-10-22 反馈「纪要内容偏左、右边一片空白」。根因不是布局算错，
/// 而是**测量函数带了副作用**：
///
/// SwiftUI 量一个 `NSViewRepresentable` 时会拿**很多个**提议宽度挨个问一遍
/// （实测一轮是 `0 → ∞ → 702 → 582 → nil → 306 → 449`，然后整轮重来），
/// 只有中间那个 `702` 才是真正要用的宽度，前后几个都是祖先视图在猜理想尺寸。
/// 上一版在 `sizeThatFits` 里直接把 `textView.frame` 与 `containerSize`
/// 改成了提议宽度，于是**最后被问的那个 449 留在了视图上**：宿主确实被拉宽到
/// 702，里面的文本却按 449 折行——右边空出 253 pt。
///
/// 更糟的是它会**自我维持**：下一轮测量读到的是 449 那份高度，结论又变，
/// SwiftUI 于是再量一轮，永远收敛不到 702。实测那 0.8 秒里这个循环跑了十几轮。
///
/// 所以现在：测量只读一具**独立的**（不显示的）布局管理器，视图的 frame
/// 只在 `layout()` 里按 `bounds.width` 设定——那里拿到的宽度是最终的。
///
/// ## 为什么手搓 TextKit 1 的存储栈
///
/// `NSTextView(frame:)` 在新系统上默认走 TextKit 2，`layoutManager` 为 nil，
/// 而 SwiftUI 需要一个**确定的**高度（`sizeThatFits`）。显式给一套
/// `NSTextStorage + NSLayoutManager + NSTextContainer` 之后，
/// 「算出来的高度」与「画出来的高度」来自同一份文本存储，不会差一截。
struct SelectableRichText: NSViewRepresentable {

    let attributed: NSAttributedString

    func makeNSView(context: Context) -> RichTextHostView {
        RichTextHostView(attributed: attributed)
    }

    func updateNSView(_ host: RichTextHostView, context: Context) {
        // 内容没变就一个字都不动：这里是选区能活过重绘的唯一原因。
        // 无条件 `setAttributedString` 会把用户正在拖的选区**每帧清掉**，
        // 看起来就像「选不中」。
        host.replaceContent(with: attributed)
    }

    /// 只回答「这个宽度下要多高」，**不碰任何视图状态**（理由见类型注释）。
    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView host: RichTextHostView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: host.height(forWidth: width))
    }
}

/// 承载文本视图的宿主：**宽度永远等于自己拿到的宽度**，高度按文本算。
///
/// 单独一个 class 而不是把逻辑全塞在 `NSViewRepresentable` 里，是因为
/// 「跟着自己的真实宽度排版」只能写在 `layout()` 里——而 `sizeThatFits`
/// 拿到的是提议宽度，两者不是一回事（见上）。
final class RichTextHostView: NSView {

    /// 真正显示、可划选的那个文本视图。
    let textView: NSTextView

    /// 只用来量高度，**从不显示**。与显示那份共享同一个文本存储，
    /// 所以量出来的行数与画出来的行数必然一致。
    private let measuringLayoutManager: NSLayoutManager
    private let measuringContainer: NSTextContainer
    /// 量过的高度，按宽度缓存。
    ///
    /// **不是单个值**：SwiftUI 一轮里会拿好几个不同宽度轮着问
    /// （`702 → 582 → 306 → 449`），只记最后一个等于每次全部重排。
    /// 条目数很小（一轮也就 4～5 个宽度），但每个都是整篇文本的排版，
    /// 值得缓存住。
    private var heightCache: [CGFloat: CGFloat] = [:]
    /// 上一次**交给视图**的那份内容。
    ///
    /// 判断「内容变了没有」不能拿 `textView.textStorage` 去比：`NSTextView`
    /// 会在排版时**改写**存储里的属性（实测 `isEqual` 返回 false，而内容其实一样），
    /// 于是每次 SwiftUI 重算 body 都判定「变了」→ 重建 → **把用户正在拖的选区清掉**。
    /// 记住自己交进去的那一份，跟新的比，才是「内容到底变没变」。
    private var lastApplied: NSAttributedString

    init(attributed: NSAttributedString) {
        let storage = NSTextStorage(attributedString: attributed)

        // 显示的这一套（TextKit 1）
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize.zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // 只读展示不需要撤销栈与各种自动替换，那些只会拖慢布局。
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        // 量高度的那一套：独立布局管理器 + 不跟随视图的容器
        measuringLayoutManager = NSLayoutManager()
        storage.addLayoutManager(measuringLayoutManager)
        measuringContainer = NSTextContainer(
            containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        measuringContainer.widthTracksTextView = false
        measuringContainer.lineFragmentPadding = 0
        measuringLayoutManager.addTextContainer(measuringContainer)

        lastApplied = attributed

        super.init(frame: .zero)
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不经 storyboard 使用") }

    /// 与 `NSTextView` 一致的方向：否则宿主比文本高时，文本会贴着**底边**排，
    /// 上面空一截（这正是「内容偏下」的那种观感）。
    override var isFlipped: Bool { true }

    /// 这个宽度下文本要多高。**纯函数**：不改 frame、不改 bounds、不触发绘制。
    func height(forWidth width: CGFloat) -> CGFloat {
        // 取整到 0.5 pt 再当键：SwiftUI 给的宽度偶尔带小数，没必要为 0.3 pt 重排。
        let key = (max(width, 1) * 2).rounded() / 2
        if let cached = heightCache[key] { return cached }
        measuringContainer.containerSize = NSSize(width: key,
                                                  height: CGFloat.greatestFiniteMagnitude)
        measuringLayoutManager.ensureLayout(for: measuringContainer)
        let height = ceil(measuringLayoutManager.usedRect(for: measuringContainer).maxY)
        heightCache[key] = height
        return height
    }

    /// 内容换了才重建，顺带清掉旧选区（旧下标可能已经越界）。
    func replaceContent(with attributed: NSAttributedString) {
        // 与**自己上一次交进去的那份**比（理由见 `lastApplied`）。
        guard !lastApplied.isEqual(to: attributed) else { return }
        guard let storage = textView.textStorage else { return }
        lastApplied = attributed
        storage.setAttributedString(attributed)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // 文本换了，高度缓存作废。
        heightCache.removeAll(keepingCapacity: true)
        needsLayout = true
    }

    /// **宽度只认 `bounds.width`**——它由 SwiftUI 最终定下来，
    /// 而不是测量阶段「顺便问一句」的那个提议宽度。
    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0.5 else { return }
        let height = height(forWidth: width)
        let target = NSRect(x: 0, y: 0, width: width, height: height)
        if textView.frame != target { textView.frame = target }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
}
