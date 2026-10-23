import SwiftUI
import AppKit
import MRSession
import MRCore
import MRMinutes

/// 右栏：会议详情。
struct MeetingDetailView: View {

    @ObservedObject var workspace: MeetingWorkspace
    @ObservedObject var player: TrackPlayer

    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var confirmingDelete = false
    @State private var exportFormat: MeetingWorkspace.ExportFormat = .markdown

    /// 哪一场会议的哪些区块被折叠了。**按会议 × 区块记，不是一个全局开关**——
    /// 理由见 `DetailCollapseState`。
    @State private var collapse = DetailCollapseState()
    /// 复制纪要后的短暂反馈（按钮变「已复制」）。
    @State private var minutesCopied = false
    @State private var copyFeedback: Task<Void, Never>?
    /// 勘误表是否展开。默认收起：它是对照用的，不是纪要正文。
    @State private var showsCorrections = false
    /// 转写稿是否处于「可编辑」状态。
    ///
    /// 刻意做成**显式开关**而不是「点一下某段就变成输入框」：
    /// 转写稿默认是读的，误触一次就把只读文本变成输入框，光标还可能已经落在
    /// 某句话中间——用户以为自己只是在滚动。
    @State private var editingTranscript = false
    /// 编辑态的草稿簿。`nil` = 不在编辑。
    ///
    /// **刻意不用 `@ObservedObject`/`@StateObject` 观察它**：
    /// 详情页一旦观察这个对象，任何一段被改都会让整页重算（1375 行），
    /// 那就把「只重画一行」这件事又毁掉了。行视图自己拿着那段草稿去观察。
    @State private var editSession: TranscriptDraftSession?
    /// 转写稿里有人工修改时，重新转写前要先问一次（转写会整篇覆盖）。
    @State private var confirmingRetranscribe = false

    /// 折叠状态的初值。
    ///
    /// 生产路径一律走默认（全部展开）——**不预置任何折叠**：
    /// 用户还没看过内容，没人会主动去折一个自己没读过的长文本。
    /// 这个入口只给渲染探针用：折叠态是折叠能力的核心用例，
    /// 而「折叠后操作按钮还在不在」只能靠眼睛看
    /// （按钮藏起来时界面上没有任何报错，断言照样全绿）。
    init(workspace: MeetingWorkspace,
         player: TrackPlayer,
         initialCollapse: DetailCollapseState = DetailCollapseState(),
         initialEditingTranscript: Bool = false) {
        self.workspace = workspace
        self.player = player
        _collapse = State(initialValue: initialCollapse)
        // 同上：编辑态的排版（输入框、清空/恢复按钮、行高）只能靠眼睛看，
        // 而这个状态是私有的 `@State`，探针从外部设不进来。
        _editingTranscript = State(initialValue: initialEditingTranscript)
    }

    var body: some View {
        Group {
            if let meeting = workspace.selectedMeeting {
                detail(for: meeting)
            } else {
                placeholder
            }
        }
        // 换一场会议时退出编辑态：留着的话，切过去的第一屏就是一堆输入框，
        // 而用户以为自己只是点了左边列表。
        //
        // 退出前**必须 flush**：草稿是防抖提交的，不 flush 就把最后几个字
        // 连同「用户已经改过」这件事一起丢在上一场里。
        .onChange(of: workspace.selectedID) { _, _ in
            endEditing()
        }
        // 转写一开始就退出编辑并落盘：转写跑完会用新稿整篇覆盖，
        // 这时草稿簿里的内容已经不属于任何一份稿子了。
        .onChange(of: workspace.transcriptPhase.isRunning) { _, running in
            if running { endEditing() }
        }
        .onChange(of: editingTranscript, initial: true) { _, _ in
            syncEditingSession()
        }
        // 稿子是异步加载的：编辑态可能比稿子先到（渲染探针就是这种时序）。
        .onChange(of: workspace.transcript?.segments.count, initial: true) { _, _ in
            syncEditingSession()
        }
    }

    // MARK: - 整体

    private func detail(for meeting: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(meeting)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    tracksSection(meeting)
                    // 纪要放在转写稿**上方**，不是下面。
                    //
                    // 一场一小时的会议转写稿动辄几百段，卡片式地铺在它下面意味着
                    // 每次想看纪要都得先滚过整篇原文——而纪要才是先看的那一份。
                    // 顺序反过来之后，转写稿即使默认展开，纪要也已经在第一屏。
                    minutesSection(meeting)
                    transcriptSection(meeting)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            toolbar(meeting)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("在左侧选一场会议")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 头部

    private func header(_ meeting: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if renaming {
                HStack(spacing: 8) {
                    TextField("标题", text: $draftTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(meeting) }
                    Button("保存") { commitRename(meeting) }
                        .buttonStyle(.borderedProminent)
                    Button("取消") { renaming = false }
                }
            } else {
                HStack(spacing: 8) {
                    Text(meeting.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Button {
                        draftTitle = meeting.title
                        renaming = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("重命名（不改目录名）")
                }
            }

            HStack(spacing: 10) {
                Label(Self.stamp(meeting.startedAt), systemImage: "calendar")
                Label(meeting.durationText, systemImage: "clock")
                Label(Self.stateText(meeting.state), systemImage: Self.stateIcon(meeting.state))
                if let pauseText = meeting.pauseText {
                    // 必须显示出来。静音的那一段里**根本没有人声**——
                    // 听的人遇到一段突兀的空白，只能靠这行字知道原因，
                    // 否则只会怀疑录音坏了。
                    Label(pauseText, systemImage: "pause.circle")
                }
                if meeting.loadError == nil {
                    Text(meeting.id)
                        .textSelection(.enabled)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let reason = meeting.loadError {
                Label("manifest 读不出来：\(reason)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(meeting.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 音轨与播放

    /// 音轨区。**波形可折叠，播放控制条始终在。**
    ///
    /// 折叠的是两块波形卡（那才是占地方的部分），**播放控制条留在外面**：
    /// 它有播放头、有「停止」，是「正在发生的事」。
    /// 把它折进去的话，音频还在播而界面上一个活的控件都不剩——
    /// 用户会以为播放器不见了，只能先展开才知道还在放。
    ///
    /// 同一个理由，转写稿折叠时进度条与失败原因也留在外面。
    private func tracksSection(_ meeting: MeetingSummary) -> some View {
        let playableTracks = playableTrackIDs
        let collapsed = collapse.isCollapsed(.tracks, in: meeting.id)
        return VStack(alignment: .leading, spacing: 10) {
            collapsibleHeader(
                section: .tracks,
                sessionID: meeting.id,
                title: "音轨",
                systemImage: "waveform",
                hint: Self.tracksTitleHint(availableTrackCount: playableTracks.count),
                expandHelp: "展开音轨与波形",
                collapseHelp: "收起音轨与波形（播放控制仍在下方可用）",
                collapsed: collapsed)

            // 播放控制条在折叠之外——见上面的理由。
            transportBar

            if collapsed {
                Text(Self.tracksCollapsedHint(availableTrackCount: playableTracks.count))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 12) {
                    ForEach(TrackPlayer.Track.allCases, id: \.self) { track in
                        trackCard(track, meeting: meeting)
                    }
                }
            }
        }
    }

    /// 盘上真有文件的轨 id。
    ///
    /// **判据是文件存在，不是 manifest 条数**：录音被清理过之后
    /// manifest 里仍有两条轨而盘上一个都没有，而折叠提示要报的是
    /// 「用户能播几条」——报 manifest 条数会给出一个假承诺。
    private var playableTrackIDs: [String] {
        Self.availableTrackIDs(manifest: workspace.manifest,
                               existingTrackIDs: workspace.availableTrackIDs)
    }

    /// 播放控制条。**不参与折叠**——单独抽出来就是为了让这一点在代码上显形。
    private var transportBar: some View {
        HStack(spacing: 10) {
            Button {
                // 三态：播放中 → 暂停；已暂停 → 继续；都没 → 两轨一起播。
                // 原来只有「播放 / 停止」两态，暂停只能靠停，
                // 而 `stop()` 会把播放头归零——于是每次都得从头听。
                if player.isPlaying {
                    player.pause()
                } else if player.isPaused {
                    player.resume()
                } else {
                    player.play(Set(TrackPlayer.Track.allCases))
                }
            } label: {
                Label(Self.transportTitle(player),
                      systemImage: Self.transportSymbol(player))
            }
            .disabled(player.duration == 0)
            .help(Self.transportHelp(player))

            // 「停止」保留下来：暂停是「接着听」，停止是「回到开头」，
            // 两件事都得有。全改成暂停就再也回不到开头了。
            if player.canStop {
                Button {
                    player.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .help("停止并回到开头（暂停是接着听，这是回到起点）")
            }

            Text(Self.clock(player.position))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { player.position },
                    set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.01))
                .disabled(player.duration == 0)

            Text(Self.clock(player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// 音轨标题旁那句「2 条 · 可播放」。**给折叠一个可数的理由**——
    /// 只写「音轨」的话，用户无从判断里面有没有东西。
    static func tracksTitleHint(availableTrackCount: Int) -> String {
        availableTrackCount > 0 ? "\(availableTrackCount) 条" : "无可播放音轨"
    }

    /// 折叠态那一行。**说清楚折掉的是什么、还剩什么**——
    /// 只写「已折叠」的话，用户会以为整栏（含播放控制）都没了。
    static func tracksCollapsedHint(availableTrackCount: Int) -> String {
        availableTrackCount > 0
            ? "已折叠波形。展开可单轨播放与调音量；上面的播放、停止、进度条不受影响。"
            : "已折叠。这场会议没有可播放的音轨。"
    }

    private func trackCard(_ track: TrackPlayer.Track, meeting: MeetingSummary) -> some View {
        let info = workspace.manifest?.track(id: track.rawValue)
        let available = player.canPlay(track)
        let isPlayingThis = player.playing.contains(track)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    player.toggleTrack(track)
                } label: {
                    Image(systemName: isPlayingThis ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .disabled(!available)
                .help(Self.trackButtonHelp(player: player, track: track))

                Text(track.displayName).font(.body.weight(.medium))
                Spacer()
                if let info {
                    Text(SessionStore.formatDuration(info.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let info {
                Text(Self.trackInfoLine(info))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let reason = player.loadErrors[track] {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: track == .mic
                           ? Binding(get: { player.micGain }, set: { player.micGain = $0 })
                           : Binding(get: { player.systemGain }, set: { player.systemGain = $0 }),
                           in: 0...1)
                }
            }

            waveform(for: track, meeting: meeting)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 波形条。
    ///
    /// 三种状态必须分开：**算完了 / 还在算 / 这一轨真没有**。
    /// 统一留白会把「还在算」伪装成「这一轨坏了」。
    ///
    /// 判「还在算」要同时看 `waveformSessionID`：切场的那一瞬间波形已经被清空、
    /// 新的还没算出来，只看空不空就会当场宣称「没有波形」。
    @ViewBuilder
    private func waveform(for track: TrackPlayer.Track, meeting: MeetingSummary) -> some View {
        if let envelope = workspace.waveforms[track.rawValue] {
            VStack(alignment: .leading, spacing: 4) {
                WaveformView(
                    peaks: envelope.peaks,
                    progress: playProgress,
                    onSeek: { fraction in
                        guard player.duration > 0 else { return }
                        player.seek(to: fraction * player.duration)
                    })

                HStack(spacing: 4) {
                    // 归一化前的幅度必须显示出来。少了它，一条极轻的音轨
                    // 会被放大到和正常音量一样高，那是视觉上的谎报。
                    Text("峰值 \(String(format: "%.2f", envelope.referenceAmplitude))")
                    if envelope.isSilent {
                        Text("· 这一轨没有声音")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        } else if workspace.isLoadingWaveforms || workspace.waveformSessionID != meeting.id {
            waveformPlaceholder("正在计算波形…")
        } else {
            waveformPlaceholder("没有可显示的波形")
        }
    }

    /// 播放进度 0...1。用整场的最长轨做分母，与底部进度条保持同一根尺子。
    private var playProgress: Double? {
        guard player.duration > 0 else { return nil }
        return min(max(player.position / player.duration, 0), 1)
    }

    private func waveformPlaceholder(_ text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.04))
            Text(text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(height: 44)
    }

    // MARK: - 转写

    /// 转写稿区。**正文可折叠，操作按钮始终在。**
    ///
    /// 折叠只收起**正文**，标题行（转写 / 单轨转写）与运行中的进度、失败原因
    /// 一律留在外面。收起正文时把进度条一起藏掉的话，
    /// 用户会以为转写停了——那是一个会让人中断工作的假信号。
    ///
    /// **默认折叠**（2026-10-22 起的默认），但只折「已经有稿子」的那种：
    /// 没转写过的会议折起来等于把「点右上开始转写」这句话藏了，
    /// 用户看到的是一行「已折叠」，而里面其实什么都没有。
    private func transcriptSection(_ meeting: MeetingSummary) -> some View {
        let collapsed = Self.transcriptShowsCollapsedBody(
            requested: collapse.isCollapsed(.transcript, in: meeting.id),
            hasDocument: workspace.transcript != nil)
        // 转写在跑的时候**不让编辑**：跑完会用新稿整篇覆盖 `transcript`，
        // 这时正在打字的改动会当场消失，而用户只会看到自己刚打的字没了。
        let editing = editingTranscript && !workspace.transcriptPhase.isRunning
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                collapsibleHeader(
                    section: .transcript,
                    sessionID: meeting.id,
                    title: "转写稿",
                    systemImage: "text.alignleft",
                    hint: Self.transcriptTitleHint(document: workspace.transcript),
                    expandHelp: "展开转写稿全文",
                    collapseHelp: "收起转写稿全文（纪要已在上方，无需滚动）",
                    collapsed: collapsed)

                Spacer()

                if !workspace.transcriptPhase.isRunning {
                    // 人工修正入口。**只在有稿子时给**——没稿子时「编辑」是一个
                    // 点了什么都不会发生的按钮。
                    if workspace.transcript != nil {
                        Button {
                            // 转写稿默认是折着的，而「编辑」按钮在折叠之外。
                            // 不先展开的话，点下去**界面上什么都不变**——
                            // 用户会以为按钮坏了，然后再点一次退出编辑态。
                            if !editing {
                                collapse.setCollapsed(false, for: .transcript, in: meeting.id)
                            }
                            editingTranscript.toggle()
                        } label: {
                            Label(editing ? "完成" : "编辑",
                                  systemImage: editing
                                    ? "checkmark.circle" : "square.and.pencil")
                        }
                        .controlSize(.small)
                        .help(Self.editToggleHelp(editing: editing))
                    }

                    Button {
                        // 有人工修改时先问一次：重新转写是**整篇覆盖**，
                        // 改过的字会被引擎重新听出来的字顶掉，而且没有撤销。
                        if (workspace.transcript?.manualEditCount ?? 0) > 0 {
                            confirmingRetranscribe = true
                        } else {
                            editingTranscript = false
                            workspace.runTranscription()
                        }
                    } label: {
                        Label(workspace.transcript == nil ? "开始转写" : "重新转写",
                              systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)

                    // 按轨转写。**放在菜单里而不是再摆两个按钮**：
                    // 界面宽度有限，而这一组入口的正常使用频率是
                    // 「整场转写」压倒性地高、「只转一条」偶尔为之。
                    Menu {
                        // 只列**盘上真的有文件**的轨。按 manifest 列会给出一个
                        // 点了必然报「音频文件不存在」的选项。
                        ForEach(MeetingDetailView.availableTrackIDs(
                            manifest: workspace.manifest,
                            existingTrackIDs: workspace.availableTrackIDs), id: \.self) { id in
                            Button {
                                workspace.runTranscription(onlyTrackIDs: [id])
                            } label: {
                                Text("只转写「\(MeetingDetailView.trackDisplayName(id: id, manifest: workspace.manifest))」")
                            }
                        }
                    } label: {
                        Label("单轨转写", systemImage: "list.bullet.rectangle")
                    }
                    .controlSize(.small)
                    .disabled(!MeetingDetailView.shouldOfferSingleTrackTranscription(
                        manifest: workspace.manifest,
                        existingTrackIDs: workspace.availableTrackIDs))
                    .help("""
                        只转写一条轨，写到 transcript-<轨>.md。\
                        整场转写稿不会被改动，也不会被标记为「已转写」。\
                        什么时候值得用：另一条轨其实是空的\
                        （本机 4 场真实录音里有 3 场的「对方」轨是全静音，\
                        当时系统音频采集没起来），对空轨再跑一遍推理纯属浪费时间。
                        """)
                }
            }

            // 进度与失败**留在折叠之外**：折叠的是「已有的长文本」，
            // 不是「正在发生的事」。
            switch workspace.transcriptPhase {
            case .running(let summary):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .done, .idle:
                EmptyView()
            }

            if collapsed {
                // 折叠时如果还处在编辑态，要说清楚「改动已经存盘」——
                // 输入框被收起来很容易被理解成「刚才打的字没了」。
                Text(editing
                     ? "已折叠。展开后可继续修正正文（改动已经存盘）。"
                     : "已折叠。展开可读全文（时间戳、说话人、重叠标记）。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if let document = workspace.transcript {
                if document.segments.isEmpty {
                    Text("这场会议没有识别到语音内容。可能是录音期间无人说话，"
                         + "也可能是录音本身是空轨。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    if editing {
                        Text(Self.editModeHint(manualEditCount: document.manualEditCount,
                                               clearedCount: document.clearedCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if editing, let session = editSession {
                        // 编辑态：每行一份独立草稿（只有被改的那行重画），
                        // 并且用 `LazyVStack` —— 1375 段的一场会，
                        // 一次性建出 1375 个 `NSTextField` 是「一进编辑就卡死」的主因。
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(session.drafts) { draft in
                                editableRow(draft, session: session, document: document)
                            }
                        }
                    } else {
                        // 阅读态同样是懒加载：这一屏只需要看得见的那十几行。
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(document.segments.enumerated()), id: \.offset) { _, segment in
                                segmentRow(segment)
                            }
                        }
                    }
                }
            } else if !workspace.transcriptPhase.isRunning {
                Text("还没有转写稿。点右上「开始转写」在本机生成（离线，不上传）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        // 覆盖前必须问。走的是与「删除」同一套口径：破坏性动作先说清代价。
        .confirmationDialog(
            "重新转写会覆盖这份稿子？",
            isPresented: $confirmingRetranscribe) {
                Button("覆盖并重新转写", role: .destructive) {
                    editingTranscript = false
                    workspace.runTranscription()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(Self.retranscribeWarning(
                    manualEditCount: workspace.transcript?.manualEditCount ?? 0))
            }
    }

    // MARK: - 折叠提示

    /// 转写稿正文到底折不折。
    ///
    /// 折叠只收「**已有成稿**」——这是三栏折叠共用的同一条原则
    /// （进度、失败原因、播放控制在任何状态下都不进折叠）。
    /// 没稿子时折起来，用户看到的是「已折叠。展开可读全文」，
    /// 而里面既没有全文也没有「开始转写」的指引。
    static func transcriptShowsCollapsedBody(requested: Bool, hasDocument: Bool) -> Bool {
        requested && hasDocument
    }

    /// 标题旁边那句「共 N 段」。**给折叠一个可数的理由**——
    /// 只写「转写稿」的话，用户无从判断里面有多少东西可看。
    ///
    /// 人工修正的段数挂在这里：它是一份稿子的「成色」，而编辑态一退出
    /// 界面上就再也没有别的地方说得出来。
    static func transcriptTitleHint(document: TranscriptDocument?) -> String {
        guard let document else { return "未转写" }
        guard !document.segments.isEmpty else { return "0 段" }
        let edited = document.manualEditCount
        let base = "\(document.segments.count) 段"
        return edited > 0 ? base + " · 人工修正 \(edited) 段" : base
    }

    // MARK: - 纪要

    /// 纪要栏。**独立成栏，放在转写稿上方**，自带标题行与两个动作：
    /// 生成/重新生成、复制。**正文可折叠。**
    ///
    /// 「生成纪要」原来挤在转写稿标题行里——那时它是转写稿的附属动作，
    /// 而它产出的是**另一个东西**，用户得先在脑子里跨过一次跳转才能找到它。
    /// 归到纪要这一栏之后，「没有纪要 → 点这里生成」是自解释的。
    ///
    /// 折叠时**进度与失败原因留在外面**，与转写稿同一条理由：
    /// 折叠的是「已有的成稿」，不是「正在发生的事」。
    private func minutesSection(_ meeting: MeetingSummary) -> some View {
        let collapsed = collapse.isCollapsed(.minutes, in: meeting.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                collapsibleHeader(
                    section: .minutes,
                    sessionID: meeting.id,
                    title: "会议纪要",
                    systemImage: "text.badge.checkmark",
                    hint: Self.minutesTitleHint(phase: workspace.minutesPhase,
                                                 result: workspace.minutesResult),
                    expandHelp: "展开会议纪要",
                    collapseHelp: "收起会议纪要（转写稿与音轨不受影响）",
                    collapsed: collapsed)

                Spacer()

                // 复制。**只在真有纪要时给**——没有内容时给一个复制按钮，
                // 点了只能复制一句「还没有纪要」，那不是错但也没有用。
                if workspace.minutesResult != nil {
                    Button {
                        copyMinutes(meeting)
                    } label: {
                        Label(minutesCopied ? "已复制" : "复制",
                              systemImage: minutesCopied ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)
                    .help("复制纪要内容（摘要、议题、决议、待办、未决事项），可直接粘贴到聊天或邮件")
                }

                // 生成纪要。**要有转写稿才给**——纪要层吃的是转写稿，
                // 没稿子时给按钮等于给一个必然报错的入口。
                if workspace.transcript != nil {
                    Button {
                        workspace.runMinutes()
                    } label: {
                        Label(workspace.minutesPhase.isRunning
                              ? "正在生成…"
                              : (workspace.minutesResult == nil ? "生成纪要" : "重新生成纪要"),
                              systemImage: "text.badge.checkmark")
                    }
                    .controlSize(.small)
                    .disabled(workspace.minutesPhase.isRunning)
                    .help(Self.minutesButtonHelp)
                }
            }

            // 进度与失败**留在折叠之外**：折叠的是「已有的成稿」，
            // 不是「正在发生的事」。
            switch workspace.minutesPhase {
            case .running(let summary):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .done, .idle:
                EmptyView()
            }

            if collapsed {
                Text(Self.minutesCollapsedHint(phase: workspace.minutesPhase,
                                                result: workspace.minutesResult,
                                                transcriptChanged: workspace.transcriptChangedAfterMinutes))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                minutesBody
            }
        }
    }

    /// 纪要标题旁的状态摘要。**折叠后这是唯一能判断「要不要展开」的信息**，
    /// 必须说清是「没生成」「生成中」还是「已生成」，更要说清降级稿——
    /// 降级稿读起来和有摘要的稿子几乎一样，折叠后用户更容易把它当真。
    static func minutesTitleHint(phase: MeetingWorkspace.MinutesPhase,
                                 result: MinutesResult?) -> String {
        switch phase {
        case .running:
            return "生成中…"
        case .failed:
            return "生成失败"
        case .done, .idle:
            guard let result else { return "未生成" }
            return result.generatedByModel ? "已生成" : "降级稿"
        }
    }

    /// 折叠态那一行。**降级稿必须在这里再说一次**——
    /// 它是本机（无 Apple Intelligence）**默认会看到**的那一份，
    /// 而折叠之后用户看不到橙色警告，只能靠这行字知道真相。
    ///
    /// 同理，「稿子改过、纪要基于旧稿」这条提示也必须在这里出现：
    /// 它和降级稿一样，收起来就彻底看不见了。
    static func minutesCollapsedHint(phase: MeetingWorkspace.MinutesPhase,
                                     result: MinutesResult?,
                                     transcriptChanged: Bool = false) -> String {
        switch phase {
        case .running:
            return "已折叠。正在生成，展开可看进度。"
        case .failed:
            return "已折叠。上方红色那行是失败原因，展开可重试。"
        case .done, .idle:
            guard let result else { return "已折叠。还没有纪要，生成后展开可读。" }
            // 两件事可以同时成立（降级稿 + 稿子后来改过），谁都不许把对方吃掉：
            // 只说降级，用户不知道稿子已变；只说变过，用户会以为这是一份真纪要。
            let stale = "⚠️ 转写稿在这份纪要生成之后改过，建议重新生成。"
            guard result.generatedByModel else {
                return "已折叠。⚠️ 这是一份降级稿（本地模型当时不可用，未生成摘要），"
                     + "展开可读原始转写稿。" + (transcriptChanged ? stale : "")
            }
            if transcriptChanged {
                return "已折叠。" + stale + "展开可核对。"
            }
            return "已折叠。展开可读摘要、议题、决议与待办。"
        }
    }

    /// 纪要栏正文：**生成中 / 失败 / 空 / 已有纪要** 四态分开。
    ///
    /// **统一留白会把「还没生成过」伪装成「生成失败」**——用户看到一片空白
    /// 只会反复去点按钮。与波形区三态分开是同一条理由。
    @ViewBuilder
    private var minutesBody: some View {
        switch workspace.minutesPhase {
        case .running(let summary):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .done, .idle:
            if let result = workspace.minutesResult {
                minutesCard(result)
            } else {
                // 空态给一句话，而不是留白。这一栏是独立成栏的，
                // 什么都不写的话用户会以为这一栏坏了。
                Text("还没有纪要。转写完成后点右上「生成纪要」——"
                     + "摘要、议题、决议与待办会出现在这里。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 已有纪要的展示卡。内容取自 `minutes.json`——
    /// 标点修复正文不进卡片（它太长，卡片放摘要/议题/决议/待办，
    /// 完整正文在 minutes.md 里，窗口底部「在访达中显示」一指就到）。
    ///
    /// ## 整张卡片是**一个**文本视图
    ///
    /// 原来是十几个 `Text` 叠出来的，每个都是独立的选择层：用户从「摘要」
    /// 往「议题」拖，选区在边界上当场断掉，复制出来永远只有一行。
    /// 现在内容由 `MinutesCardText` 渲染成**一段** `NSAttributedString`，
    /// 交给 `SelectableRichText` 变成一个 `NSTextView`——
    /// 跨十几个段落也是一条连续选区，⌘A、⌘C、右键复制全部原生。
    private func minutesCard(_ result: MinutesResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SelectableRichText(attributed: MinutesCardText.render(
                result,
                transcriptChanged: workspace.transcriptChangedAfterMinutes,
                showsCorrections: showsCorrections))

            // 勘误表：让「纪要里的术语」与「转写稿里的错字」能对上。
            // 默认收起——它是对照用的，不是纪要内容；但必须可见，
            // 否则模型改了哪些词就完全是个黑盒。
            if !result.corrections.isEmpty {
                Button {
                    showsCorrections.toggle()
                } label: {
                    Text(Self.correctionsToggleLabel(count: result.corrections.count,
                                                     shows: showsCorrections))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(showsCorrections
                      ? "收起勘误表（它不属于纪要内容，也不在「复制」里）"
                      : "展开看看模型把哪几个词纠正了")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 勘误表开关的文案。**展开之后不能再写「（点开核对）」**——
    /// 一个已经打开的开关上写着「点开」，用户会以为刚才那次点击没生效。
    static func correctionsToggleLabel(count: Int, shows: Bool) -> String {
        shows ? "收起勘误表" : "已纠正 \(count) 处语音识别错误（点开核对）"
    }

    /// 复制纪要到剪贴板，**只复制纪要本身**。
    ///
    /// 不复制 `minutes.md` 的全文：那份开头带会话 ID 与生成时间、
    /// 中间还嵌着整篇标点修复正文，粘进群聊等于把文件头和三千字原料一起发出去。
    /// 渲染规则见 `MinutesPlainText.render(_:title:)`。
    private func copyMinutes(_ meeting: MeetingSummary) {
        guard let result = workspace.minutesResult else { return }
        let text = MinutesPlainText.render(result, title: meeting.title)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // **必须先看写入结果**：剪贴板不可用时（无 GUI 会话、
        // 别的进程独占）返回 false，而那时界面若还显示「已复制」就是撒谎。
        guard pasteboard.setString(text, forType: .string) else { return }

        // 反馈会自己退回去。**不复位的话这个按钮会永远停在「已复制」**，
        // 下一次复制（内容可能已经变了）看上去像是没生效。
        copyFeedback?.cancel()
        minutesCopied = true
        copyFeedback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            minutesCopied = false
        }
    }

    /// 「生成纪要」按钮的说明。**把两种模型层的差别写在提示里**——
    /// 用户点下去之前有权知道这一份纪要会不会离开本机。
    static var minutesButtonHelp: String {
        """
        用当前设置的纪要模型层生成本场会议的摘要、要点、决议与待办。
        默认本地 FoundationModels（录音不出本机）；若在设置里选了云端 API，
        转写稿会发送到所配置的第三方服务。
        """
    }

    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(TranscriptDocument.timestamp(segment.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .leading)

            Text(segment.speaker)
                .font(.caption.weight(.semibold))
                .foregroundStyle(segment.track == "mic" ? .primary : .secondary)
                .frame(width: 34, alignment: .leading)

            // 清空的段落不显示空白，显示一句明确的说明。留白读起来像
            // 「这句没转出来」，而事实是「这里的内容被删掉了」——
            // 前者要重转，后者什么都不用做。
            Text(segment.isBlank ? "（已清空，不参与纪要生成）" : segment.text)
                .font(.body)
                .foregroundStyle(segment.isBlank ? .tertiary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if segment.overlapping {
                Text("⚡")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("这一时段双方都在说话")
            }
            if let edit = segment.manualEdit {
                Text(edit == .cleared ? "已清空" : "已修正")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("这一段是人工改过的，不是语音识别的原始结果")
            }
        }
    }

    // MARK: - 转写稿的人工修正

    /// 编辑态的一段。真正的行视图在 `TranscriptEditingRow`——
    /// 它必须独立成一个 View，才能让「打字」只重画这一行。
    @ViewBuilder
    private func editableRow(_ draft: TranscriptDraftSession.Draft,
                             session: TranscriptDraftSession,
                             document: TranscriptDocument) -> some View {
        if document.segments.indices.contains(draft.index) {
            let segment = document.segments[draft.index]
            TranscriptEditingRow(
                draft: draft,
                start: segment.start,
                speaker: segment.speaker,
                track: segment.track,
                manualEdit: segment.manualEdit,
                originalText: segment.originalText,
                onEdit: { session.noteChange(at: draft.index) },
                onClear: { clearSegment(draft.index, session: session) },
                onRestore: { restoreSegment(draft.index, session: session) })
        }
    }

    /// 清空一段。
    ///
    /// 顺序不能反：**先撤掉这一段的待提交，再让工作区动盘**。
    /// 反过来的话，0.35 秒后那次防抖提交会把用户刚清掉的文字写回去——
    /// 界面上看起来像「清空没生效」，而磁盘上其实是内容又回来了。
    private func clearSegment(_ index: Int, session: TranscriptDraftSession) {
        session.cancelPending(at: index)
        workspace.clearTranscriptSegment(at: index)
        syncDraft(index, session: session)
    }

    /// 恢复引擎原文。与清空同一套顺序纪律。
    private func restoreSegment(_ index: Int, session: TranscriptDraftSession) {
        session.cancelPending(at: index)
        workspace.restoreTranscriptSegment(at: index)
        syncDraft(index, session: session)
    }

    /// 把草稿拉回工作区那份真实内容（写盘失败时工作区不会前进，这里也就还原成旧文字）。
    private func syncDraft(_ index: Int, session: TranscriptDraftSession) {
        guard let segments = workspace.transcript?.segments,
              segments.indices.contains(index) else { return }
        session.syncDraft(at: index, to: segments[index].text)
    }

    // MARK: - 编辑态的开合

    /// 让草稿簿与「要不要编辑」保持一致。四个入口都调它（首次出现、切换开关、
    /// 稿子加载完、转写开始），因为它必须**幂等**：做两遍和做一遍结果一样。
    private func syncEditingSession() {
        let shouldEdit = editingTranscript
            && !workspace.transcriptPhase.isRunning
            && workspace.transcript != nil
        guard shouldEdit, let document = workspace.transcript else {
            editSession?.flush()
            editSession = nil
            return
        }
        // 已经建好就不重建：重建等于把用户正在改的文字扔掉，
        // 而且会换掉每个 `Draft` 的身份，输入框当场失去焦点。
        guard editSession == nil else { return }
        editSession = makeSession(document: document)
    }

    private func makeSession(document: TranscriptDocument) -> TranscriptDraftSession {
        let session = TranscriptDraftSession(document: document)
        // 提交 = 工作区那份「写盘 + 失败回滚」的既有路径，语义不变，
        // 只是**从每个键一次变成停顿时一次**。
        //
        // 必须带**这份稿子自己的** sessionID：flush 可能发生在用户切走之后，
        // 那时按 `selectedID` 写会写进另一场会议的 transcript.json。
        let sessionID = document.sessionID
        session.commit = { [weak workspace] index, text in
            workspace?.setTranscriptText(at: index, to: text, forSessionID: sessionID) ?? false
        }
        session.diskText = { [weak workspace] index in
            guard let segments = workspace?.transcript?.segments,
                  segments.indices.contains(index) else { return nil }
            return segments[index].text
        }
        return session
    }

    /// 退出编辑：先把没提交的改动写下去，再拆掉草稿簿。
    ///
    /// 调用点有四个（点「完成」、切会议、转写开始、视图消失），
    /// 每一个都可能是「用户最后一次输入」之后的那一下。
    private func endEditing() {
        editSession?.flush()
        editSession = nil
        editingTranscript = false
    }

    static var clearedPlaceholder: String { "（空）" }

    static func editToggleHelp(editing: Bool) -> String {
        editing
            ? "退出编辑，回到阅读视图"
            : "手动修正语音识别的错字；也可以把整段清空（不参与纪要生成）"
    }

    static func editModeHint(manualEditCount: Int, clearedCount: Int) -> String {
        var text = "直接改文字即可，停顿半秒内自动存盘（没有「保存」按钮）。"
            + "时间戳与说话人只读。"
        if clearedCount > 0 {
            text += "已清空 \(clearedCount) 段（清空的段落不参与纪要生成）。"
        } else if manualEditCount > 0 {
            text += "已修正 \(manualEditCount) 段。"
        }
        return text
    }

    /// 「恢复原文」的提示。行视图里拿不到整段 `TranscriptSegment`（它只认草稿），
    /// 所以真正干活的是这个只吃 `originalText` 的版本。
    static func restoreHelp(originalText: String?) -> String {
        guard let originalText else { return "恢复语音识别的原文" }
        return "恢复语音识别的原文：\(originalText)"
    }

    static func restoreHelp(_ segment: TranscriptSegment) -> String {
        restoreHelp(originalText: segment.originalText)
    }

    static func retranscribeWarning(manualEditCount: Int) -> String {
        "这份稿子里有 \(manualEditCount) 处人工修改，重新转写会整篇覆盖它们，"
        + "且无法撤销。只想改个别错字的话，用「编辑」直接改更快。"
    }

    // MARK: - 底部工具条

    private func toolbar(_ meeting: MeetingSummary) -> some View {
        HStack(spacing: 10) {
            Button {
                workspace.revealInFinder(sessionID: meeting.id)
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }

            Spacer()

            // 合并两轨成一个文件。放在这里而不是状态栏菜单：这是「发给别人」的动作，
            // 而发给别人的场景人正站在会议详情页上。
            if MeetingDetailView.shouldOfferMerge(trackCount: workspace.selectedMeeting?.existingTrackCount) {
                Button {
                    exportMergedAudio(meeting)
                } label: {
                    Label("合并音轨", systemImage: "waveform.badge.plus")
                }
                .help("把两条轨合成一个文件：我=左声道、对方=右声道")
            }

            if workspace.transcript != nil {
                Picker("", selection: $exportFormat) {
                    ForEach(MeetingWorkspace.ExportFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
                .frame(width: 170)

                Button {
                    exportTranscript(meeting)
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
            }

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .confirmationDialog(
                "删除「\(meeting.title)」？",
                isPresented: $confirmingDelete) {
                    Button("移到废纸篓", role: .destructive) {
                        workspace.delete(sessionID: meeting.id)
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("录音与转写稿会一起移到废纸篓（可以再捞回来）。")
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - 小工具

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.headline)
    }

    /// 三栏共用的折叠标题行。
    ///
    /// ## 为什么要抽出来
    ///
    /// 三处各写一遍箭头按钮的话，改一次要改三处——而**漏掉一处的后果不是
    /// 编译错误，是那个区块悄悄没有折叠**，界面上完全看不出异常。
    /// 抽成一处之后，「折叠按钮长什么样、折叠了还剩什么」只有一个答案。
    ///
    /// ## 为什么整块标题区都可点
    ///
    /// 折叠三角只有十几个像素，让用户瞄准它是白给的摩擦。
    /// `.contentShape(Rectangle())` 把命中区扩到整块标题，
    /// 点空白处和点字效果一样。
    private func collapsibleHeader(section: DetailSection,
                                   sessionID: String,
                                   title: String,
                                   systemImage: String,
                                   hint: String,
                                   expandHelp: String,
                                   collapseHelp: String,
                                   collapsed: Bool) -> some View {
        Button {
            collapse.toggle(section, in: sessionID)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                sectionTitle(title, systemImage: systemImage)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? expandHelp : collapseHelp)
        .accessibilityLabel(collapsed ? "展开\(title)" : "收起\(title)")
    }

    private func commitRename(_ meeting: MeetingSummary) {
        workspace.rename(sessionID: meeting.id, to: draftTitle)
        renaming = false
    }

    /// 把转写稿另存一份。
    ///
    /// **面板默认指向这场会议自己的目录**，与「合并音频」同一条纪律：
    /// 会议目录里的 `transcript.md` 是原始产物，用户另存时最自然的起点
    /// 就是这一场自己的目录——从那儿挑一个位置，或者原地另存一份。
    ///
    /// 此前这里只设了文件名、没设 `directoryURL`（2026-10-15 修）。
    /// 没设的后果不是「打开文稿根目录」这么温和：`NSSavePanel` 会记住
    /// **上一次保存的位置**，于是面板打开在某个毫不相关的会议目录下，
    /// 而用户要导出的是今天这一场。同一个坑 `exportMergedAudio` 早就修过、
    /// 还写了回归测试，这边漏了——相邻两个功能，一个修了一个没修，
    /// 屏幕上看不出任何报错，只有保存位置不对。
    private func exportTranscript(_ meeting: MeetingSummary) {
        let panel = NSSavePanel()
        panel.title = "导出转写稿"
        panel.nameFieldStringValue = "\(meeting.title).\(exportFormat.fileExtension)"
        panel.canCreateDirectories = true
        if let directory = Self.sessionSavePanelDirectory(sessionDirectory: meeting.directory) {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.exportTranscriptSafe(to: url, format: exportFormat)
    }

    /// 合并两轨成一个文件。
    ///
    /// 存盘面板默认指向**这场会议自己的目录**，与 CLI 的 `mr merge`（不带 `--out`）
    /// 落在同一个位置。此前这里只设了文件名、没设 `directoryURL`，
    /// 面板会打开上次用的位置或「文稿」根目录——于是同一个功能在命令行与界面下
    /// 落到两个地方，产物散落，而注释里写着「默认指向会话目录」，说的却是没做的事。
    private func exportMergedAudio(_ meeting: MeetingSummary) {
        let panel = NSSavePanel()
        panel.title = "导出合并音频"
        panel.nameFieldStringValue = SessionAudioExporter.mergedFileName(title: meeting.title)
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.wav]
        if let directory = Self.sessionSavePanelDirectory(sessionDirectory: meeting.directory) {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.mergeTracksSafe(sessionID: meeting.id, to: url)
        // 合并成功且用户选了默认路径时，直接在访达里指出来——
        // 「导出完成」用户还得自己找文件，是最容易漏掉的一步。
        if workspace.lastError == nil {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// 两个导出（转写稿、合并音频）共用的「面板该打开哪个目录」。
    ///
    /// 抽成静态函数是为了能测——`NSSavePanel` 在无头测试里点不出来，
    /// 而「默认目录对不对」恰恰是这条路上唯一会静默错掉的东西。
    ///
    /// ## 为什么两个导出必须共用同一个函数
    ///
    /// 2026-10-15 之前的教训：`exportMergedAudio` 修了「没设 `directoryURL`」
    /// 这个坑还写了回归测试，而隔壁的 `exportTranscript` 漏了同一处修复。
    /// 症状是导出转写稿时面板打开在**上次保存过的某个会议目录**下
    /// （`NSSavePanel` 会记住上次位置），与要导出的那一场毫不相干。
    /// 两个相邻功能各写一份默认目录逻辑，迟早漂成两种行为——
    /// 共用一处，改的时候只有一处要记得。
    ///
    /// 返回 `nil` 表示不设 `directoryURL`（目录不在了）。**不能返回不存在的目录**：
    /// 面板拿到那种 `directoryURL` 会静默退回自己的默认位置，等于没设，
    /// 而调用方看不出任何区别。
    static func sessionSavePanelDirectory(sessionDirectory: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionDirectory.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return sessionDirectory
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - 播放按钮的三态文案

    /// 底部播放按钮的标题。抽成静态函数是为了能测——
    /// 「什么时候该显示继续」这种判据藏在视图里就只能靠肉眼看了。
    static func transportTitle(_ player: TrackPlayer) -> String {
        if player.isPlaying { return "暂停" }
        if player.isPaused { return "继续" }
        return "两轨同时播放"
    }

    static func transportSymbol(_ player: TrackPlayer) -> String {
        player.isPlaying ? "pause.fill" : "play.fill"
    }

    static func transportHelp(_ player: TrackPlayer) -> String {
        if player.isPlaying { return "暂停。停下来之后可以从这里接着听" }
        if player.isPaused { return "从 \(clock(player.position)) 接着听" }
        return "同时播放两条轨，用来听谁在什么时候接了话"
    }

    /// 单轨播放按钮的说明。这条按钮是三态复用同一个图标的，
    /// 光看图标分不出「从头播」还是「接着播」，得靠提示说明白。
    static func trackButtonHelp(player: TrackPlayer, track: TrackPlayer.Track) -> String {
        let name = track.displayName
        if player.playing.contains(track) { return "暂停「\(name)」" }
        if player.paused.contains(track) {
            return "继续播放「\(name)」（从 \(clock(player.position)) 接着听）"
        }
        if player.isPlaying {
            return "加入播放「\(name)」，从 \(clock(player.position)) 开始与其它轨对齐"
        }
        return "播放「\(name)」"
    }

    /// 是否该显示「合并音轨」按钮。抽成静态函数是为了能测。
    ///
    /// 判据是**已存在的轨数**（`existingTrackCount`，数的是磁盘上真实文件），
    /// 不是 manifest 里的条数：manifest 记了轨但文件被删掉时，
    /// 按 manifest 判断会给出按钮、点了却报「缺轨」。
    ///
    /// 单轨时不给按钮：合并两轨成「一个文件」对单轨没有意义，
    /// 而让用户点了才发现没得合是更差的体验。
    static func shouldOfferMerge(trackCount: Int?) -> Bool {
        (trackCount ?? 0) >= 2
    }

    // MARK: - 单轨转写

    /// 盘上真的有文件的轨 id，按 manifest 的顺序。
    ///
    /// 判据是**文件存在**而不是 manifest 条数：录音被清理过（保留策略只删音频、
    /// 留 manifest 与转写稿）之后，manifest 里仍有两条轨而盘上一个都没有。
    /// 按 manifest 列菜单会给出一个必然报「音频文件不存在」的选项——
    /// 而报错的形态是用户点完才知道，不点就不知道。
    static func availableTrackIDs(manifest: RecordingManifest?,
                                  existingTrackIDs: Set<String>) -> [String] {
        guard let manifest else { return [] }
        return manifest.tracks
            .map(\.id)
            .filter { existingTrackIDs.contains($0) }
    }

    /// 是否该给「单轨转写」这个菜单。
    ///
    /// 只有**一条**轨可用时不给：那时「单轨」与「整场」是同一件事，
    /// 让用户通过一个多一层菜单的入口去做同一件事没有意义。
    /// 两条以上才给——那时候它省的是「对空轨白跑一遍推理」。
    static func shouldOfferSingleTrackTranscription(manifest: RecordingManifest?,
                                                     existingTrackIDs: Set<String>) -> Bool {
        availableTrackIDs(manifest: manifest, existingTrackIDs: existingTrackIDs).count >= 2
    }

    /// 轨的显示名。**按 role 取，不按 id 猜。**
    ///
    /// `TrackRole` 的 `rawValue` 是 `microphone` / `systemAudio`，
    /// 而轨道 id 是 `mic` / `system`——两套命名。写 `id == "mic" ? "我" : ...`
    /// 这种映射在 id 改名时会静默给出错误的名字，而用户看到的是
    /// 「对方」标在一条其实是自己麦克风的轨上。
    static func trackDisplayName(id: String, manifest: RecordingManifest?) -> String {
        guard let track = manifest?.tracks.first(where: { $0.id == id }) else {
            // manifest 读不到时退回 id 本身。**显示一个 ID 好过显示一个猜错的名字。**
            return id
        }
        return track.role.displayName
    }

    /// 轨道卡第二行的参数串：采样率 · 声道 · 位深 · 设备名。
    ///
    /// 抽成静态函数是为了能测——SwiftUI 的 `Text` 在无头测试里读不到内容，
    /// 而这一行正是用户事后分辨「这场是不是非无损的」的唯一入口：
    /// 位深不显示的话，16 位录的和 32 位录的在 app 里长得一模一样，
    /// 而精度是补不回来的。manifest 的 `sampleFormat` 就由这里消费。
    static func trackInfoLine(_ info: TrackManifest) -> String {
        var parts = ["\(Int(info.sampleRate)) Hz", "\(info.channels) 声道",
                     info.sampleFormat.shortDisplayName]
        if let name = info.deviceName { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func stateText(_ state: SessionState) -> String {
        switch state {
        case .recording: return "录制中"
        case .finalized: return "已完成"
        case .crashed: return "崩溃残留"
        case .recovered: return "已修复"
        case .transcribed: return "已转写"
        }
    }

    static func stateIcon(_ state: SessionState) -> String {
        switch state {
        case .recording: return "record.circle"
        case .finalized: return "checkmark.circle"
        case .crashed: return "exclamationmark.triangle"
        case .recovered: return "wrench.and.screwdriver"
        case .transcribed: return "text.alignleft"
        }
    }
}
