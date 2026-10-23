import SwiftUI
import MRCore
import MRSession

/// 录音设置的**归类**与折叠摘要。
///
/// ## 为什么要重新归类
///
/// 改动之前，四个全局偏好（16 位录音、单声道 24 kHz、静默录制、转写引擎）
/// 与「标题前缀」「开始录制」并排躺在顶栏那一行里。看起来像是「每场录制前都要过一遍」
/// 的东西，实际上它们**改一次长期生效**——是设置，不是每次的操作。
///
/// 平铺的真实代价有两个，都不在「好不好看」这一层：
///
/// 1. **顶栏是高频区。** 开始/暂停/停止要在这里够得着，而四个低频开关与它们同权重，
///    视觉重心被拽走，「开始录制」反而不像主操作。
/// 2. **信息量与占位不成正比。** 每一项的标签都带着「（约省一半）」「（约再省 2/3）」
///    这类说明，长度是按钮的两三倍，于是四个开关在 1000pt 宽的窗口里排成一条长链，
///    挤压了真正会变的那部分（「将保存为 xxx」）。
///
/// 所以归类的**第一原则是按「归属与频率」分，而不是按「类型」平铺**。
///
/// 而顶栏只保留一组**折叠摘要**：折叠态用一个标签把三项当前取值写出来，
/// 信息没有丢，只是不再各占一行——展开与否是用户的决定，不是界面的默认状态。
///
/// ## 摘要为什么是纯值
///
/// `summary(pcm16:mono24k:engine:hidesCountdown:)` 刻意不碰 `workspace`、不碰磁盘。
/// 「折叠时那一行到底写了什么」是一条**规格**（它会被用户当成状态读），
/// 必须能被断言，而不能只能靠截图目测。
struct RecordingSettingSummary: Equatable {

    /// 音频格式的那一截，例如「24 kHz 单声道 · 16 位」。
    var format: String
    /// 引擎名，例如「苹果原生」。
    var engine: String
    /// 静默录制开着吗——只影响是否显示那个图标，**不写进文字**。
    ///
    /// 理由：一个「静默录制中」的标签恰恰是这个开关要消除的可见性。
    /// 它开着的时候，提醒它的唯一方式是一个图标，而不是把状态写出来。
    var isConcealed: Bool

    /// 从四个偏好推出摘要。**唯一的出处**，顶栏标签与面板标题都调它。
    static func summary(
        pcm16: Bool,
        mono24k: Bool,
        engine: TranscriptionEngine,
        hidesCountdown: Bool
    ) -> RecordingSettingSummary {
        RecordingSettingSummary(
            format: formatText(pcm16: pcm16, mono24k: mono24k),
            engine: engine.displayName,
            isConcealed: hidesCountdown
        )
    }

    /// 格式那一截。
    ///
    /// **「源采样率」不是一个偷懒的占位符，它是在不说谎。** 省多少完全取决于
    /// 设备给的格式：有些麦克风（如 AirPods）本身就只给 24 kHz 单声道，
    /// 那时「我」轨没有采样率与声道可降。所以关掉降采样时只能写「源采样率」，
    /// 写死成「48 kHz 立体声」会在 AirPods 上变成一句假话——
    /// 而这类「界面上写着一个具体数字，实际不是那样」的错最难被用户自己发现。
    ///
    /// 位深那一截不受设备影响：写出去的就是 `pcm16 ? 16 位 : 32 位浮点`，
    /// 所以这里可以给准数。
    static func formatText(pcm16: Bool, mono24k: Bool) -> String {
        let rate = mono24k ? "24 kHz 单声道" : "源采样率"
        let depth = pcm16 ? "16 位" : "32 位浮点"
        return "\(rate) · \(depth)"
    }

    /// 顶栏标签的完整文字。
    var labelText: String { "\(format) · \(engine)" }
}

/// 录音设置面板。挂在顶栏那个按钮的 `popover` 里。
///
/// ## 为什么不是再开一个「设置」窗口
///
/// 三个理由，都是具体的：
///
/// 1. **没有多出一个窗口要管。** 这三项没有一样是需要「离开当前任务去做」的：
///    改完立刻就该回到录音。窗口会让人以为设置完还有别的步骤。
/// 2. **它只在 idle 时有内容。** 录制中这三项都不作用于正在录的这场（每场按
///    开始录制时的设置），弹出一个全灰的面板不如不出。
/// 3. **设置窗口是第二个入口，而且更全。** 这里只放「录之前随手改」的那几项，
///    密钥、服务商预设、测试连接与长说明都在设置窗口（⌘,）。
///
/// ## 排版（2026-10-22 重做）
///
/// 与设置窗口**同一套零件**（`SettingsCard` / `SettingsRow`）：分组卡片、
/// 一行一句说明、长解释收进「说明」就地展开。
/// 改动前这里是「一列小标题 + 一串 checkbox + 每项挂一条长 tooltip」，
/// 与窗口是两种长相，而 tooltip 悬停时会盖住下面的设置项。
struct RecordingSettingsPanel: View {

    @ObservedObject var workspace: MeetingWorkspace

    /// 折叠态那个标签要显示的摘要。
    private var summary: RecordingSettingSummary {
        RecordingSettingSummary.summary(
            pcm16: workspace.pcm16Recording,
            mono24k: workspace.mono24kRecording,
            engine: workspace.transcriptionEngine,
            hidesCountdown: workspace.hidesStatusBarCountdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                SettingsCard(title: "音频格式") {
                    SettingsRow(title: SettingsCopy.pcm16Title,
                                subtitle: SettingsCopy.pcm16OneLine,
                                details: SettingsCopy.pcm16Details) {
                        Toggle("", isOn: $workspace.pcm16Recording)
                            .toggleStyle(.switch).labelsHidden()
                    }
                    SettingsRowDivider()
                    SettingsRow(title: SettingsCopy.mono24kTitle,
                                subtitle: SettingsCopy.mono24kOneLine,
                                details: SettingsCopy.mono24kDetails) {
                        Toggle("", isOn: $workspace.mono24kRecording)
                            .toggleStyle(.switch).labelsHidden()
                    }
                    if workspace.mono24kRecording {
                        SettingsRowDivider()
                        SettingsRow(title: SettingsCopy.downmixTitle,
                                    subtitle: SettingsCopy.downmixOneLine,
                                    details: SettingsCopy.downmixDetails(
                                        workspace.downmixStrategy,
                                        allCases: MonoDownmixStrategy.allCases)) {
                            Picker("", selection: $workspace.downmixStrategy) {
                                ForEach(MonoDownmixStrategy.allCases, id: \.self) { strategy in
                                    Text(strategy.displayName).tag(strategy)
                                }
                            }
                            .pickerStyle(.menu).labelsHidden().fixedSize()
                        }
                    }
                }

                SettingsCard(title: "转写") {
                    SettingsRow(title: SettingsCopy.engineTitle,
                                subtitle: SettingsCopy.engineOneLine,
                                details: SettingsCopy.engineDetails) {
                        Picker("", selection: $workspace.transcriptionEngine) {
                            ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                                Text(engine.displayName).tag(engine)
                            }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                }

                minutesCard

                SettingsCard(title: "通用") {
                    StatusBarIconToggle(workspace: workspace)
                    SettingsRowDivider()
                    SettingsRow(title: SettingsCopy.concealTitle,
                                subtitle: SettingsCopy.concealOneLine,
                                details: SettingsCopy.concealDetails) {
                        Toggle("", isOn: $workspace.hidesStatusBarCountdown)
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
            .padding(14)

            Divider()
            footer
        }
        .frame(width: 420)
    }

    // MARK: - 组装

    /// 标题行：标题即摘要。
    ///
    /// 摘要必须**就在这一行**：这个面板是折叠入口，用户不点开也该知道
    /// 现在录出来是什么规格。齿轮按钮直通设置窗口——面板只有 420 宽，
    /// 放不下服务商预设与「测试连接」，而「填完没法当场验」正是配错的来源。
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("录音设置").font(.body.weight(.medium))
            Spacer()
            Text(summary.labelText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                workspace.onOpenSettings?()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("打开设置窗口（⌘,）：密钥、服务商预设、测试连接")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 会议纪要：这里只放「用谁」，配置细节都在设置窗口。
    private var minutesCard: some View {
        SettingsCard(title: "会议纪要") {
            SettingsRow(title: "生成方式",
                        subtitle: workspace.minutesProvider == .cloudAPI
                            ? SettingsCopy.cloudMinutesOneLine
                            : SettingsCopy.localMinutesOneLine) {
                Picker("", selection: $workspace.minutesProvider) {
                    ForEach(MinutesProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }

            // 云端档在这里**只说缺什么**，不给输入框：420 宽塞三个输入框会挤成
            // 一行一个小框，而填完也没法当场测。真要配就走设置窗口。
            if workspace.minutesProvider == .cloudAPI {
                SettingsRowDivider()
                HStack(alignment: .center, spacing: 8) {
                    Text(cloudHint)
                        .font(.caption2)
                        .foregroundStyle(cloudHintIsWarning ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("去配置…") { workspace.onOpenSettings?() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var cloudHint: String {
        if workspace.minutesCloudAPIIsComplete {
            return "已配齐（密钥 \(workspace.maskedMinutesAPIKey)），生成时转写稿会发往该服务。"
        }
        let missing = workspace.missingMinutesCloudAPIItems.joined(separator: "、")
        return "⚠️ 还缺：\(missing)。三项齐了才能生成。"
    }

    private var cloudHintIsWarning: Bool { !workspace.minutesCloudAPIIsComplete }

    /// 底部那一句常驻说明。
    ///
    /// 改动前它是顶栏最右端的一句常驻小字，常年占着最稀缺的横向空间。
    /// 移到这里之后**仍然一直可见**（面板只比顶栏多一次点击），但不再与高频操作争位置。
    private var footer: some View {
        Text("本机麦克风记「我」，系统音频记「对方」。设置只作用于之后新录的会议。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    // MARK: - 文案
    //
    // 全部搬到 `SettingsCopy`（唯一出处）。这里原来还有四个转发用的静态属性
    // （`pcm16Help` / `mono24kHelp` / `concealHelp` / `downmixHelp`），
    // 2026-10-22 起没有任何调用点了——转发层只剩「两份名字」这一个副作用。
}
