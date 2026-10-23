import SwiftUI
import MRSession
import MRCore

/// 顶栏：录音控制。
///
/// 每个状态都必须有明确的文字，尤其是 `preparing`——系统音频 tap 的准备
/// 在首次可能花上秒级，如果那时界面显示的还是「开始录制」按钮，
/// 用户会以为没点中，然后再点一次。
///
/// **暂停状态也要有明确文字。** 「已暂停」与「录制中」在界面上只差一个图标的话，
/// 用户会以为还在录——而暂停期间的数据是**真的被丢掉了**，事后无法补回。
struct RecordingBarView: View {

    @ObservedObject var workspace: MeetingWorkspace
    /// 录制结束的回调（用来刷新列表）
    var onSessionSaved: () -> Void

    @State private var titlePrefix = ""

    /// 设置面板是否展开。
    ///
    /// 存成 `@State` 而不是 `@Published`：它纯粹是这个视图的 UI 状态，
    /// 不需要别的视图观察，也不需要在视图重建后保留。
    @State private var showingSettings = false

    /// **必须观察 `recorder` 本身**，不能只观察 `workspace`。
    ///
    /// 这一行不是形式主义：本视图显示的每一个动态量（`phase`、`elapsed`、
    /// `warnings`、`mutedTrackIDs`）都挂在 `recorder` 上，而 `recorder` 是
    /// `workspace` 里的一个 `let` 属性——**它不是 `@Published`，
    /// `workspace` 的任何变化都不会带动它重绘**。
    ///
    /// 漏掉它时的症状极其恶劣：菜单里的 `Toggle` 绑定读的是
    /// `controller.mutedTrackIDs`，而视图从不因它改变而刷新，
    /// 于是「点了没反应 / 状态自相矛盾 / 第二次点击把界面卡住」——
    /// 全都是这条缺失观察链的产物，而且没有任何一处会报错。
    ///
    /// `workspace` 的观察**仍需保留**：`MeetingWorkspace` 发布的
    /// `meetings` / `access` / `selectedID` 在本视图的父级链上被用到，
    /// 去掉它会引入另一类"界面不更新"。
    @ObservedObject private var recorder: RecordingController

    init(workspace: MeetingWorkspace, onSessionSaved: @escaping () -> Void) {
        self.workspace = workspace
        // `workspace.recorder` 是 `let`，初始化期取一次即为同一实例，
        // 不存在"视图持有的是另一个对象"的问题。
        self.recorder = workspace.recorder
        self.onSessionSaved = onSessionSaved
    }

    private var controller: RecordingController { recorder }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controlRow
            // SenseVoice 的资产状态占**第二行**，而不是挤在那一排全局偏好里：
            // 它是一块可变高度的内容（状态 + 体积 + 进度条），塞进 HStack 会把
            // 旁边的「16 位录音」「静默录制」推来推去——那几个开关不该因为
            // 另一个引擎的下载进度而左右移动。
            // 只在 `idle` 出现：录制中那一行要留给计时与停止按钮。
            if case .idle = controller.phase {
                SenseVoiceAssetsView(engine: workspace.transcriptionEngine)
            }
        }
        .onChange(of: controller.phase) { _, newPhase in
            if case .finished = newPhase { onSessionSaved() }
        }
    }

    private var controlRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)

            switch controller.phase {
            case .idle:
                idleControls
            case .preparing:
                ProgressView().controlSize(.small)
                Text("正在准备音频设备…").font(.callout)
                Spacer()
                Button("取消") { controller.stop() }
            case .recording:
                liveIndicator(paused: false)
                Spacer()
                trackMenu
                Button {
                    controller.pause()
                } label: {
                    Label("暂停", systemImage: "pause.fill")
                }
                .help("两轨一起静音。可用左边「音轨」菜单只掐掉其中一轨。")
                stopButton
            case .paused:
                liveIndicator(paused: true)
                Spacer()
                // **这里刻意不显示音轨菜单。**
                // 暂停期间两轨本来就都被静音，菜单里每一项都是「已静音」，
                // 取消勾选会让那一轨在暂停期间**开始录音**——那就不是暂停了。
                // 用户若想让某轨在继续后仍保持静音，继续之后再去菜单里关它。
                Button {
                    controller.resume()
                } label: {
                    Label("继续", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                stopButton
            case .stopping:
                ProgressView().controlSize(.small)
                Text("正在保存…").font(.callout)
                Spacer()
            case .finished(let sessionID):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("已保存").font(.body.weight(.medium))
                Text(sessionID).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !controller.warnings.isEmpty {
                    Label("\(controller.warnings.count) 条提示", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .help(controller.warnings.joined(separator: "\n"))
                }
                Button("好") { controller.acknowledge() }
            case .failed(let message):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(message).font(.callout).lineLimit(2)
                Spacer()
                Button("好") { controller.acknowledge() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 各状态

    private var idleControls: some View {
        Group {
            TextField("", text: $titlePrefix, prompt: Text("标题前缀（可留空）"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            Button {
                // 标题的时间序号由状态机统一追加，这里只给前缀。
                // 两个调用方（这个按钮、状态栏菜单）各拼一次时间格式的话，
                // 早晚会漂成两种样子。
                workspace.startRecording(titleBase: titlePrefix)
            } label: {
                Label("开始录制", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            // 把「会存成什么名字」直接摆出来，免得用户以为时间要自己手打
            Text("将保存为 \(workspace.pendingTitle(for: titlePrefix))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            // ── 四个全局偏好收进这一个按钮 ──────────────────────────
            //
            // 改动前这里是四个平铺的开关（16 位录音 / 单声道 24 kHz /
            // 静默录制 / 引擎选择）加一句常驻说明。它们改一次长期生效，
            // 却被摆在「每场都要用」的高频区，还把「开始录制」的主操作
            // 挤到了视觉的次要位置。详见 `RecordingSettingsPanel` 的类型注释。
            //
            // **折叠态仍然把当前取值写在标签上**，所以「折叠」不等于「信息丢失」：
            // 用户不展开也知道现在录出来是什么格式、用哪个引擎。
            settingsEntry

            // 说明文字从顶栏移进了设置面板（那里有一处常驻位置）。
            // 顶栏最稀缺的是横向空间，而那行字不变、不影响任何决策。
            // 留一个图标入口：想看解释的人点得到，不想看的人不用读。
        }
    }

    /// 「录音设置」入口按钮。标签即摘要。
    private var settingsEntry: some View {
        Button {
            showingSettings = true
        } label: {
            HStack(spacing: 5) {
                // 静默录制开着时显示这个图标——**只用一个图标，不写文字**：
                // 一个「静默录制中」的标签恰恰是这个开关要消除的可见性。
                if settingSummary.isConcealed {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("静默录制已开启：录制期间菜单栏上只留中性图标。")
                }
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(settingSummary.labelText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .controlSize(.small)
        .fixedSize()
        .help("录音设置：音质规格、转写引擎、静默录制、菜单栏图标。点开可逐项调整。")
        .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
            RecordingSettingsPanel(workspace: workspace)
        }
    }

    private var settingSummary: RecordingSettingSummary {
        RecordingSettingSummary.summary(
            pcm16: workspace.pcm16Recording,
            mono24k: workspace.mono24kRecording,
            engine: workspace.transcriptionEngine,
            hidesCountdown: workspace.hidesStatusBarCountdown)
    }

    /// 录制中 / 已暂停。两者的计时**是同一个数**。
    ///
    /// **注意：静音期间计时照走**——写的是静音帧，文件长度不变，
    /// 内容时长自然也不减。这与旧版「暂停即掐掉、计时停住」不同，
    /// 但后者无法支撑分轨静音（两轨文件长度必须一致，否则时间轴错位）。
    private func liveIndicator(paused: Bool) -> some View {
        Group {
            if paused {
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                Text("已暂停").font(.body.weight(.medium)).foregroundStyle(.orange)
                Text("两轨都静音，这一段听不到声音")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text("录制中").font(.body.weight(.medium))
            }
            Text(Self.clock(controller.elapsed))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var stopButton: some View {
        Button {
            controller.stop()
        } label: {
            Label("停止", systemImage: "stop.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    // MARK: - 音轨菜单

    /// 分轨静音入口。
    ///
    /// **菜单标题本身要显示当前状态**，而不只是「音轨」两个字：
    /// 会议进行中没人会去点开菜单逐项确认，标题上的「我 已静音」才是
    /// 唯一一眼可见的信息。少了它，用户会在录完两小时后才发现麦克风早就关了。
    ///
    /// ## 为什么用 `Button` 而不是 `Toggle`
    ///
    /// 一开始这里用的是 `Toggle(isOn: 自定义 Binding)`。**它会卡死**——
    /// 第二次点击菜单时界面无响应。原因是 macOS 上 `Menu` 内的 `Toggle`
    /// 在「菜单关闭」与「绑定值变更」同时发生时会发生重入：菜单为了反映新的
    /// 绑定值去重建自己，而重建又触发一次状态同步，于是反复自我重建、
    /// 主线程被占满，表现为整个 App 卡住。
    ///
    /// `Button` + 对勾是菜单项的标准形态，没有绑定、没有重入，
    /// 而且外观与系统菜单完全一致。**勾选态由标题栏图标与文字一并表达**
    ///（「音轨 · 1 已静音」），信息没有丢失。
    private var trackMenu: some View {
        Menu {
            trackToggle(TrackID.mic)
            trackToggle(TrackID.system)

            Divider()

            // 两轨都静音 = 全局暂停，与顶栏「暂停」指同一件事，这里不重复给入口。
            Text("两轨都关 = 全局暂停（顶栏「暂停」）")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } label: {
            Label(menuTitle, systemImage: menuIcon)
                .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help("""
            分轨开关：只掐掉其中一轨，另一轨继续录。\
            被掐掉的那一段在音频里是**静音**，文件长度不变——\
            所以两轨的时间轴始终对齐，回放与转写都不会错位。

            适合「我这边环境突然变吵」时单独关掉麦克风，\
            对方说什么照录不误。若要两轨都停，用顶栏的「暂停」。

            ⚠️ 静音期间的数据**无法恢复**，事后补不回来。
            """)
    }

    /// 单个音轨的开关项。
    ///
    /// **用该轨自己的图标表达该轨的状态**，不画对勾、不画通用图标。
    ///
    /// 第一版这里用的是「对勾 + 文字 + 标题栏统一 `mic.slash`」，三处都是错的：
    /// 1. 静音了反而打勾 → 看的人只会理解成「这轨在录」，
    ///    而菜单标题又写着「已静音」，**同一屏里自相矛盾**；
    /// 2. 标题栏图标对两轨一律用 `mic.slash` → 关掉「对方」也显示麦克风被关，
    ///    而对方轨来自系统音频、与麦克风毫无关系；
    /// 3. 「打勾 = 静音」这个约定本身就不是菜单项的惯例——
    ///    系统菜单里打勾一律表示「该项处于激活状态」。
    ///
    /// 现在静音轨显示 `mic.slash` / `speaker.slash`，在录轨显示原图标，
    /// 一眼可辨且不需要解释。
    private func trackToggle(_ track: TrackID) -> some View {
        let muted = controller.mutedTrackIDs.contains(track.rawValue)
        return Button {
            controller.setMuted(!muted, trackID: track.rawValue)
        } label: {
            Label(
                muted ? "\(track.displayName)（已静音）" : track.displayName,
                systemImage: muted ? track.mutedIcon : track.activeIcon)
        }
        .disabled(!controller.canToggleTracks)
        .help(helpText(for: track, muted: muted))
    }

    /// 提示语。**必须把"为什么不能点"说清楚**——
    /// 暂停期间这两项是不可点的（暂停已经静音了两轨），若只写一句"已暂停"
    /// 而不解释，用户只会以为菜单坏了。
    private func helpText(for track: TrackID, muted: Bool) -> String {
        guard controller.canToggleTracks else {
            return controller.isPaused
                ? "已暂停：两轨都在静音。继续录制之后才能单独切换某一轨。"
                : "当前状态不能切换音轨。"
        }
        return muted
            ? "\(track.displayName) 已静音，这段时间不会录到声音。点一下恢复录制。"
            : "\(track.displayName) 正在录制。点一下静音这一轨。"
    }

    private var mutedCount: Int { controller.mutedTrackIDs.count }

    /// 菜单标题。只说数量，不指名具体哪一轨——具体是哪一轨由菜单项自己表达。
    private var menuTitle: String {
        mutedCount == 0 ? "音轨"
            : (mutedCount == 1 ? "音轨 · 1 已静音" : "音轨 · 全部静音")
    }

    /// 菜单标题图标。
    ///
    /// 两轨都静音时用 `mic.slash` 是刻意的：**全局静音**是"录音这件事本身"
    /// 被暂停，此刻并不区分是哪一轨——显示一个中性图标比显示"麦克风被关"准确。
    /// 只静音一轨时用 `dot.radiowaves.left.and.right`（通用"活动"图标），
    /// 同样不冒充具体是哪一轨。
    private var menuIcon: String {
        mutedCount == 0 ? "slider.horizontal.3"
            : (mutedCount == 1 ? "waveform.badge.minus" : "mic.slash")
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

/// 全局转写引擎选择器。
///
/// 单独抽成一个视图，是为了能**脱离整条顶栏**单独渲染做冒烟：
/// 顶栏里还有标题输入框，`ImageRenderer` 离屏渲染它时会触发
/// 「Accessing FocusState's value outside of the body of a View」警告——
/// 那个警告来自输入框，与本控件无关，不该混在一起。
struct TranscriptionEnginePicker: View {

    @Binding var engine: TranscriptionEngine

    var body: some View {
        Picker("引擎", selection: $engine) {
            ForEach(TranscriptionEngine.allCases, id: \.self) { candidate in
                Text(candidate.displayName).tag(candidate)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .help("""
            转写引擎，全局设置——改一次，之后每一场转写都用它（不是每场单独勾选）。
            默认「苹果原生」：零模型下载、约 160 倍实时、录音出本机。
            「SenseVoice」是 opt-in：需下载约 244 MiB 模型（仅首次），更吃内存，
            主要服务专有名词密集场景；选中后下面会出现资产状态与下载入口。
            资产没装好时转写会在写任何文件之前明确报错——不会产出空稿，
            也不会静默改用苹果引擎（那会让你拿到一份署名不同的稿子）。
            命令行等价命令：config set engine <apple|sensevoice>。
            """)
    }
}
