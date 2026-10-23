import SwiftUI
import MRCore
import MRMinutes
import MRSession

/// 设置窗口的尺寸约定。
///
/// 宽度固定、**高度由内容决定**（不同分页的字段数不一样，高度差可达 200）。
/// 常量放在这里而不是视图与窗口控制器各写一遍：两处各写一个 560，
/// 改一处漏一处不会报错，只会让窗口和内容对不齐——这种漂移只能靠人眼发现。
enum SettingsLayout {
    /// 窗口宽度。**按「一行说明能读完」定**：620 在 11 pt 说明字下，
    /// 去掉留白与尾部控件后仍放得下 `SettingsCopy.oneLineBudget` 个汉字。
    /// 580 时云端那三项的说明会折成两行——一句话折行就等于没写一句话。
    static let width: CGFloat = 620

    /// 建窗时的临时高度。**不是最终尺寸**：窗口建好、内容布局完就按
    /// `fittingSize` 改成真实高度。给一个够大的值是为了「先量再调」时
    /// 内容不被压缩过——压缩过的视图量出来的高度是错的。
    static let provisionalHeight: CGFloat = 900

    /// 窗口内容应有的尺寸：宽度固定，高度取内容的 `fittingSize`。
    ///
    /// **这是唯一的判据来源**：窗口控制器与渲染探针都调它。
    /// 探针若自己再写一遍「按内容高度」，那它验证的就是探针自己——
    /// 窗口真被固定高度裁掉时，图照样是完整的。
    ///
    /// 量不出来（还没完成布局）时返回 `nil`，调用方保持原样：
    /// 把内容尺寸 set 成 0 会让窗口缩成一条线。
    @MainActor
    static func contentSize(for hosting: NSView) -> NSSize? {
        hosting.layoutSubtreeIfNeeded()
        let ideal = hosting.fittingSize
        guard ideal.height > 1 else { return nil }
        return NSSize(width: width, height: ideal.height)
    }
}

/// 设置窗口。**全进程唯一的「设置」主场**（⌘, / 状态栏菜单 / 顶栏面板都汇到这里）。
///
/// ## 结构（2026-10-22 重做）
///
/// 改动前是一长条纵向堆叠：模型层、云端三项、隐私、菜单栏全挤在一列里，
/// 每项说明都是一大段，还挂在 hover 浮层上——浮层会盖住下面的设置项。
/// 现在的结构是**分页 + 卡片 + 一行式设置行**：
///
/// ```
/// 设置                                    v2.…
/// [ 录音 | 会议纪要 | 通用 ]   ← 分页，每页一句话说明
/// ──────────────────────────────────────
/// 音频格式                     ← 卡片
///   16 位整数 PCM   体积减半…    [开关]
///   单声道 24 kHz   体积再降…    [开关]
///   降混策略        多声道合并…  [取第 1 声道 ▾]
/// 转写
///   转写引擎        决定识别…    [苹果原生 ▾]
/// ──────────────────────────────────────
/// 密钥只存在本机偏好域…
/// ```
///
/// 分页不是为了好看：一长条必须滚动，而本项目**不能用 `ScrollView`**
/// （离屏渲染不布局它的内容，界面复核会拍出整块空白）。分页让每页都在一屏内。
struct MinutesSettingsView: View {

    @ObservedObject var model: MinutesSettingsModel
    @ObservedObject private var workspace: MeetingWorkspace

    /// 右上角的版本号文案。
    ///
    /// 默认**真读 bundle**（`AppVersion`），而不是写死一个字符串——
    /// 写死的话，迟早会出现「界面说 2.0.3、包里是 2.20261021.1654」，
    /// 而用户正是拿这行字判断「我装的是不是最新的」。
    /// 探针进程没有 `Info.plist`，所以留了这个注入点给它传固定值。
    private let versionText: String

    init(model: MinutesSettingsModel, versionText: String = AppVersion.display()) {
        self.model = model
        self.workspace = model.workspace
        self.versionText = versionText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar
            Divider()

            // **刻意不用 ScrollView**：它会让离屏渲染（本项目的界面复核手段）
            // 画不出内容，而且窗口不能缩到比内容更小。代价是「高度必须由内容决定」
            // ——2026-10-21 就踩到过写死 660 而真实内容 746，标题被顶出可视区，
            // 全程没有报错。现在高度由 `SettingsWindowController` 按 `fittingSize` 定。
            page
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            Divider()
            footer
        }
        .frame(width: SettingsLayout.width)
    }

    // MARK: - 头尾

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("设置")
                .font(.title3.weight(.semibold))
            // 这一行只回答一个真问题：**要不要按保存**。
            // 不重复分页说明里的内容——重复的说明就是「文案成堆」的起点。
            Text("改完立即生效，没有保存按钮。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        // 版本号**用 overlay 而不放进 HStack**：作为兄弟节点参与排版会把标题行挤窄，
        // 而它只是一行小字。overlay 不参与布局，标题排版逐像素不变。
        .overlay(alignment: .topTrailing) {
            Text(versionText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help("版本号后两段是这次改动完成的日期与时刻")
                .padding(.trailing, 16)
                .padding(.top, 14)
        }
    }

    /// 分页 + 这一页的一句话说明。
    ///
    /// 说明必须跟着页走：分段控件上只有「录音 / 会议纪要 / 通用」三个词，
    /// 而「通用」这种词本身不说明任何东西。
    private var tabBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsTabPicker(selection: $model.tab)
            Text(model.tab.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(SettingsCopy.privacyFootnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 分页

    @ViewBuilder
    private var page: some View {
        switch model.tab {
        case .recording: recordingPage
        case .minutes: minutesPage
        case .general: generalPage
        }
    }

    // MARK: - 录音

    private var recordingPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "音频格式") {
                SettingsRow(title: SettingsCopy.pcm16Title,
                            subtitle: SettingsCopy.pcm16OneLine,
                            details: SettingsCopy.pcm16Details) {
                    Toggle("", isOn: $workspace.pcm16Recording)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsRowDivider()
                SettingsRow(title: SettingsCopy.mono24kTitle,
                            subtitle: SettingsCopy.mono24kOneLine,
                            details: SettingsCopy.mono24kDetails) {
                    Toggle("", isOn: $workspace.mono24kRecording)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                // 降混策略只在单声道打开时才有意义。**灰掉不如不显示**：
                // 灰着的开关只会让人反复去点它——这条规则在面板里也一样。
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
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
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
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    // MARK: - 会议纪要

    private var minutesPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "生成方式") {
                SettingsChoiceRow(title: SettingsCopy.localMinutesTitle,
                                  subtitle: localMinutesSubtitle,
                                  selected: workspace.minutesProvider == .local) {
                    workspace.minutesProvider = .local
                }
                SettingsRowDivider()
                SettingsChoiceRow(title: SettingsCopy.cloudMinutesTitle,
                                  subtitle: SettingsCopy.cloudMinutesOneLine,
                                  selected: workspace.minutesProvider == .cloudAPI) {
                    workspace.minutesProvider = .cloudAPI
                }
            }

            if workspace.minutesProvider == .cloudAPI {
                cloudCard
            }
            // 本地档**不再另起一段脚注**：不可用的原因就写在行里，
            // 而「离线、不花钱」已经在那一行的说明里。同一件事说两遍
            // 是「文案成堆」的直接来路，且两处口径迟早会打架。
        }
    }

    /// 本地这一行的说明。**不可用时直接说原因**，不再包一层「可改用云端」——
    /// 原因文本自己就带着下一步，外面再包只会把卡片撑成三行。
    private var localMinutesSubtitle: String {
        guard let reason = workspace.localMinutesUnavailableReason else {
            return SettingsCopy.localMinutesOneLine
        }
        return "⚠️ \(reason)"
    }

    /// 云端服务的全部字段。
    private var cloudCard: some View {
        SettingsCard(title: "云端服务") {
            SettingsRow(title: "服务商",
                        subtitle: "一键填好地址与模型名（不碰密钥）") {
                HStack(spacing: 6) {
                    ForEach(MinutesServicePreset.allCases, id: \.self) { preset in
                        Button(preset.displayName) { model.apply(preset: preset) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            if let note = model.presetNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            SettingsRowDivider()
            SettingsRow(title: SettingsCopy.baseURLTitle,
                        subtitle: baseURLSubtitle,
                        details: SettingsCopy.baseURLDetails) {
                TextField("https://api.example.com/v1", text: $workspace.minutesAPIBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }

            SettingsRowDivider()
            SettingsRow(title: SettingsCopy.modelNameTitle,
                        subtitle: SettingsCopy.modelNameOneLine,
                        details: SettingsCopy.modelNameDetails) {
                TextField("deepseek-chat", text: $workspace.minutesModelName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }

            SettingsRowDivider()
            SettingsRow(title: SettingsCopy.apiKeyTitle,
                        subtitle: SettingsCopy.apiKeyOneLine,
                        details: SettingsCopy.apiKeyDetails) {
                HStack(spacing: 6) {
                    Group {
                        if model.revealsKey {
                            TextField("sk-…", text: $workspace.minutesAPIKey)
                        } else {
                            SecureField("sk-…", text: $workspace.minutesAPIKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 234)

                    Button {
                        model.revealsKey.toggle()
                    } label: {
                        Image(systemName: model.revealsKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(model.revealsKey ? "隐藏" : "显示")
                }
            }

            SettingsRowDivider()
            SettingsRow(title: SettingsCopy.testConnectionTitle,
                        subtitle: SettingsCopy.testConnectionOneLine,
                        details: SettingsCopy.testConnectionDetails) {
                Button {
                    model.runProbe()
                } label: {
                    if model.isProbing {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("测试中…")
                        }
                    } else {
                        Text("测试连接")
                    }
                }
                .disabled(!model.canProbe || model.isProbing)
            }

            // 状态与结论**贴在卡片底部**，不塞进某一行的尾部：
            // 它们是整张卡的结论（三项一起决定），挂在某个字段右侧会读成
            // 「只有那个字段有问题」。
            VStack(alignment: .leading, spacing: 4) {
                Text(model.statusLine)
                    .font(.caption2)
                    .foregroundStyle(model.statusIsWarning ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let conclusion = model.probeConclusion {
                    Label(conclusion,
                          systemImage: model.probeConclusionIsSuccess
                            ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.caption2)
                        .foregroundStyle(model.probeConclusionIsSuccess ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    /// Base URL 那一行说明：空 → 引导；非法 → 橙色；合法 → 常规说明。
    ///
    /// 空 URL 不报「拼不出合法地址」：那是语法错误，可用户根本没填，
    /// 报它等于拿编译器的话当产品文案。
    private var baseURLSubtitle: String {
        if workspace.minutesAPIBaseURL.isEmpty { return SettingsCopy.baseURLOneLine }
        if let problem = model.configuration.urlProblem { return "⚠️ \(problem)" }
        return "请求会自动追加 /chat/completions"
    }

    // MARK: - 通用

    private var generalPage: some View {
        // 两项**同在一张卡里**：它们讲的是同一件东西——菜单栏上露出多少。
        // 分成两张卡会让这一页看起来有两个互不相干的主题（正是「零散无体系」）。
        SettingsCard(title: "菜单栏") {
            StatusBarIconToggle(workspace: workspace)
            SettingsRowDivider()
            SettingsRow(title: SettingsCopy.concealTitle,
                        subtitle: SettingsCopy.concealOneLine,
                        details: SettingsCopy.concealDetails) {
                Toggle("", isOn: $workspace.hidesStatusBarCountdown)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }
}
