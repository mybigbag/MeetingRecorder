import SwiftUI

/// 设置界面的**共用零件**。
///
/// ## 为什么要一套零件
///
/// 2026-10-22 收到的评价是「像临时堆积起来的，设置项零散无体系，
/// 说明文案杂乱成堆，hover 说明还会遮挡设置项」。这不是某一屏没排好，
/// 而是**三个界面各写各的**：设置窗口自己画分组、顶栏面板自己画分组、
/// 状态栏菜单又是另一套。三处的间距、字号、行高、说明位置全不一样。
///
/// 所以先把「一行设置长什么样」定死，三处都只许用这一套：
///
/// - **一项 = 一行**：左边标题 + 一句说明（`subtitle`），右边控件；
/// - 说明**常驻、只占一行**，不再是 hover 才出现的浮层——
///   浮层会盖住下面的设置项，而且用户根本不知道该往哪悬停；
/// - 真正长的解释（历史沿革、实测数字）收进「说明」这个**就地展开**里：
///   点开撑高，点回收起，不做浮层、不做第二扇窗。
///
/// ## 为什么不用 `Form`
///
/// `Form` 会按平台风格接管标签宽度、行高与分组留白，三处就又会各漂一套。
/// 这里要的是「同一份排版在窗口与 popover 里长得一样」，自绘更可控。

// MARK: - 卡片

/// 一组设置：组标题 + 一块圆角底。
struct SettingsCard<Content: View>: View {

    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.045)))
        }
    }
}

/// 卡片内的行分隔线。**由调用方显式插入**：
/// 靠 `ForEach` 自动加的话，条件渲染的行（如只在单声道时出现的降混策略）
/// 会多出一条悬空的分隔线。
struct SettingsRowDivider: View {
    var body: some View {
        Divider().opacity(0.5).padding(.leading, 12)
    }
}

// MARK: - 行

/// 一项设置：标题 + 一句说明 + 尾部控件。
///
/// `details` 有值时标题旁会出现「说明」，点开在**行内**展开长文案。
/// 这是本轮对「hover 说明遮挡设置项」的正面回答：要读解释就占它该占的高度，
/// 不读就一行也不占。
struct SettingsRow<Control: View>: View {

    let title: String
    /// 一句说明。**必须能一行读完**（窗口 620 宽下约 24 个汉字）。
    var subtitle: String?
    /// 长解释。历史沿革、实测数字这类「想查的时候才看」的内容。
    var details: String?
    /// 控件是否禁用（禁用时整行降低对比度，避免「看着能点其实不能」）。
    var isEnabled: Bool = true

    @ViewBuilder var control: Control

    /// 初态是否展开说明。**默认 false**；只给渲染探针用——
    /// 展开态是这一轮新加的排版（行长、行距都变），
    /// 不拍一张图就发现不了「展开后整卡挤成一团」。
    var initiallyShowsDetails: Bool = false

    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.callout)
                            .foregroundStyle(isEnabled ? .primary : .secondary)
                        if let details, !details.isEmpty {
                            Button(showsDetails ? "收起" : "说明") {
                                showsDetails.toggle()
                            }
                            .buttonStyle(.link)
                            .font(.caption2)
                            .help("展开这条设置的完整说明")
                        }
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            // **最多两行**：这一行是「一句说明」，三行以上就是文档，
                            // 一屏里几项都这样就是用户说的「文案杂乱成堆」。
                            // 真需要三行的内容属于 `details`。
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                control
                    .controlSize(.small)
                    .disabled(!isEnabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if showsDetails, let details {
                Text(details)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .onAppear {
            // 探针注入的初态。放在 onAppear 而不是自定义 init 里：
            // `@State` 的初值只在首次生效，用 init 写得再对，复用时也不会重算。
            if initiallyShowsDetails { showsDetails = true }
        }
    }
}

/// 单选行（本地 / 云端、引擎这类「几个里选一个」）：**整行可点**。
///
/// 整行点击区不是细节：只有小圆点可点时，用户会以为文字只是标题，
/// 于是点一下没反应就去怀疑界面坏了。
struct SettingsChoiceRow: View {

    let title: String
    var subtitle: String?
    let selected: Bool
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

// MARK: - 页面顶部的分段

/// 设置窗口里的分页。
///
/// 三页而不是一长条：一长条必须滚动，而本项目**不能用 `ScrollView`**
/// ——离屏渲染路径不布局它的内容，界面复核会拍出一整块空白
/// （2026-10-19 就踩过，断言全绿而图是空的）。分页让每页都在一屏内，
/// 高度仍由内容决定。
enum SettingsTab: String, CaseIterable, Identifiable {
    case recording
    case minutes
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: return "录音"
        case .minutes: return "会议纪要"
        case .general: return "通用"
        }
    }

    /// 这一页讲什么。**写出来**：分段控件只有三个词，
    /// 而「通用」这种词本身不说明任何内容。
    var subtitle: String {
        switch self {
        case .recording: return "音频格式与转写引擎。改动只影响之后新录的会议。"
        case .minutes: return "用哪个模型把转写稿变成纪要，以及它要不要联网。"
        case .general: return "菜单栏图标、录制时露出多少痕迹。"
        }
    }
}

/// 顶部的分页选择器。
struct SettingsTabPicker: View {

    @Binding var selection: SettingsTab

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(SettingsTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
