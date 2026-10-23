import Foundation
import Darwin
import MRCore
import MRMinutes

/// 会议库里的一个条目。
///
/// 刻意做成**值类型 + 零 UI 依赖**：「读磁盘目录 → 得到可展示的列表」这段逻辑
/// 不需要窗口也不需要任何权限，因此能在无头环境里被完整单元测试。
/// GUI 只负责把字段画出来，不做任何推导。
/// 一轨被静音的段数与总时长。
///
/// **段数与时长都要留**：只有时长的话，界面只能显示「我 静音 1:30」，
/// 听的人无从判断那是一段还是十段被掐掉的。
public struct MuteInfo: Equatable, Sendable {
    public var count: Int
    public var seconds: Double
    public init(count: Int, seconds: Double) {
        self.count = count
        self.seconds = seconds
    }
}

public struct MeetingSummary: Identifiable, Equatable, Sendable {

    /// 会话 ID（= 目录名）
    public var id: String
    public var title: String
    public var startedAt: Date
    /// 音轨时长（秒）。用**音轨**而不是 `endedAt - startedAt`：
    /// 后者对 `recording` 状态的会话会随时间增长，列表里的数字会自己跳动。
    public var duration: Double
    public var state: SessionState
    /// 实际存在的音轨数量（0 表示目录里没有可用的 wav）
    public var existingTrackCount: Int
    /// manifest 里记录的告警（采样全零、某轨无数据等）
    public var warnings: [String]
    public var hasTranscript: Bool
    public var directory: URL
    /// 非 nil 表示这一条读不出来。**不影响其它条目**——一个坏目录不该让整个列表消失。
    public var loadError: String?
    /// 全场静音（两轨一起）段数
    public var globalMuteCount: Int
    /// **全场**静音总时长（秒）。分轨静音不在其中，见 `RecordingManifest.pausedTotal`。
    public var pausedSeconds: Double
    /// 分轨静音，键是轨 id（`mic` / `system`）。
    ///
    /// 与 `pausedSeconds` 分开，是因为两者对用户是两件事：
    /// 「全场静音了 1 分钟」和「只有我这轨静音了 3 分钟」需要分别告知，
    /// 混成一个数字就会让人以为是整场都没录到声音。
    ///
    /// **段数与时长都要留**：只有时长的话，界面只能显示「我 静音 1:30」，
    /// 听的人无从判断那是一段还是十段被掐掉的。
    public var mutedByTrack: [String: MuteInfo]

    public init(
        id: String,
        title: String,
        startedAt: Date,
        duration: Double,
        state: SessionState,
        existingTrackCount: Int,
        warnings: [String],
        hasTranscript: Bool,
        directory: URL,
        loadError: String? = nil,
        globalMuteCount: Int = 0,
        pausedSeconds: Double = 0,
        mutedByTrack: [String: MuteInfo] = [:]
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.state = state
        self.existingTrackCount = existingTrackCount
        self.warnings = warnings
        self.hasTranscript = hasTranscript
        self.directory = directory
        self.loadError = loadError
        self.globalMuteCount = globalMuteCount
        self.pausedSeconds = pausedSeconds
        self.mutedByTrack = mutedByTrack
    }

    /// manifest 读不出来时构造的占位条目。标题退回目录名，时间用目录的修改时间。
    public static func broken(id: String, directory: URL, reason: String, fallbackDate: Date) -> MeetingSummary {
        MeetingSummary(
            id: id, title: id, startedAt: fallbackDate, duration: 0,
            state: .crashed, existingTrackCount: 0, warnings: [],
            hasTranscript: false, directory: directory, loadError: reason)
    }

    /// 需要用户注意（崩溃残留，或读不出来）
    public var needsAttention: Bool { loadError != nil || state.needsAttention }

    public var durationText: String { SessionStore.formatDuration(duration) }

    /// 「静音 2 段 · 共 1:30」，带轨名。没静音过则返回 nil。
    ///
    /// 有它才能解释音频里那段突兀的空白——否则听的人只会怀疑录音坏了。
    /// **分轨静音必须带上轨名**（「我 静音 3 段 · 共 1:30」）：
    /// 同样的现象，出在「我」这轨意味着是环境吵，出在「对方」那轨意味着对方没说话，
    /// 结论完全相反。
    public var pauseText: String? {
        var parts: [String] = []
        if globalMuteCount > 0 {
            parts.append(
                "全场静音 \(globalMuteCount) 段 · 共 \(SessionStore.formatDuration(pausedSeconds))")
        }
        for id in TrackID.allCases {
            guard let info = mutedByTrack[id.rawValue], info.seconds > 0.001 else { continue }
            parts.append(
                "\(id.displayName) 静音 \(info.count) 段 · 共 \(SessionStore.formatDuration(info.seconds))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "　")
    }
}

/// 会议库：磁盘上的会话目录 ↔ 可展示的列表。
public struct SessionLibrary {

    /// 会议根目录的可达性。
    ///
    /// 必须区分 `missing` 与 `permissionDenied`，因为它们在界面上长得一模一样
    /// （都是「什么都没有」），含义却完全相反：
    /// 前者是「你还没录过音」，后者是「你有录音但系统没让我看」。
    /// 把后者显示成前者，就是**用空白界面骗用户说数据没了**。
    ///
    /// 这个区分之所以必要：macOS 的 TCC 在拒绝访问 `~/Documents` 时，
    /// `fileExists` 会返回 **false**——和「目录真的不存在」完全无法区分。
    /// 所以这里不看 `fileExists`，而是直接尝试打开目录拿 errno。
    public enum Access: Equatable, Sendable {
        /// 可读（目录可能为空，也可能有内容）
        case ok
        /// 目录不存在。首次使用就是这样。
        case missing
        /// 目录存在，但被系统隐私保护挡住（TCC）
        case permissionDenied
        case failed(reason: String)
    }

    public let store: SessionStore
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.store = SessionStore(root: root, fileManager: fileManager)
        self.fileManager = fileManager
    }

    public var root: URL { store.root }

    /// 探测根目录的可达性。
    public func accessStatus() -> Access {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: store.root.path, isDirectory: &isDirectory)

        // 关键：即使 `fileExists` 说「不存在」，也再试一次真正打开。
        // TCC 拒绝时它就是这么撒谎的——返回 false 而不是抛错。
        let openErrno = attemptOpen(store.root.path)

        if let errno = openErrno {
            // EACCES(13) / EPERM(1) = 有东西挡着，而不是没有
            if errno == EACCES || errno == EPERM {
                return .permissionDenied
            }
            if errno == ENOENT {
                return .missing
            }
            return .failed(reason: String(cString: strerror(errno)))
        }

        guard exists else {
            // 能打开却「不存在」——不正常，但别把它当成 permissionDenied
            return .missing
        }
        guard isDirectory.boolValue else {
            return .failed(reason: "该路径存在但不是目录")
        }
        return .ok
    }

    /// 尝试以只读打开。成功返回 nil，失败返回 errno。
    private func attemptOpen(_ path: String) -> Int32? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return errno }
        close(fd)
        return nil
    }

    /// 扫描全部会议，按开始时间**倒序**（最新在前）。
    ///
    /// 单条失败只影响那一条，其余照常返回——这是刻意的：
    /// 一个写到一半的 manifest 不该让用户看不到自己所有的会议。
    public func list() -> [MeetingSummary] {
        let ids: [String]
        do { ids = try store.listSessionIDs() }
        catch { return [] }

        let entries = ids.map { summary(forSessionID: $0) }
        return entries.sorted { a, b in
            if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
            return a.id > b.id
        }
    }

    /// 读单个会话。永不抛错——失败被折进 `loadError`。
    public func summary(forSessionID id: String) -> MeetingSummary {
        let dir = store.directory(forSessionID: id)
        do {
            let manifest = try store.loadManifest(forSessionID: id)
            return MeetingSummary(
                id: id,
                title: manifest.title.isEmpty ? id : manifest.title,
                startedAt: manifest.startedAt,
                duration: Self.audioDuration(of: manifest),
                state: manifest.state,
                existingTrackCount: existingTracks(of: manifest, in: dir),
                warnings: manifest.notes + manifest.tracks.flatMap(\.warnings),
                hasTranscript: hasTranscript(in: dir),
                directory: dir,
                globalMuteCount: manifest.pauses.count { $0.trackID == nil },
                pausedSeconds: manifest.pausedTotal,
                mutedByTrack: Self.soloMutes(of: manifest))
        } catch {
            return .broken(
                id: id, directory: dir, reason: "\(error)",
                fallbackDate: modificationDate(of: dir))
        }
    }

    /// 分轨静音汇总（**排除**全场静音的记录）。
    ///
    /// 必须排除：一条 `trackID == nil` 的记录表示两轨都静音了，
    /// 而它已经由 `pausedSeconds` 计入全局口径。若同时算进每轨，
    /// 界面会显示「全场静音 1:30　我 静音 1:30」——同一件事被报了两遍，
    /// 且让人以为「我」轨被多掐了一次。
    static func soloMutes(of manifest: RecordingManifest) -> [String: MuteInfo] {
        var result: [String: MuteInfo] = [:]
        for span in manifest.pauses {
            guard let trackID = span.trackID else { continue }
            let seconds = max(0, span.duration)
            let existing = result[trackID]
            result[trackID] = MuteInfo(
                count: (existing?.count ?? 0) + 1,
                seconds: (existing?.seconds ?? 0) + seconds)
        }
        return result
    }

    /// 音轨时长取最长的一条。manifest 的 `endedAt` 在录制中会持续增长，不能用来算时长。
    static func audioDuration(of manifest: RecordingManifest) -> Double {
        let trackLongest = manifest.tracks.map(\.duration).max() ?? 0
        if trackLongest > 0 { return trackLongest }
        // 没有音轨信息时退回时间戳（已 finalized 的会话至少能给出个近似值）。
        // 用 `recordedDuration` 而不是 `duration`：后者含暂停，会让列表里的
        // 时长比音频实际长度多出一整段暂停，和旁边显示的音轨时长自相矛盾。
        guard manifest.endedAt != nil else { return 0 }
        return manifest.recordedDuration
    }

    /// manifest 说有、且文件**真的在**的音轨数。
    ///
    /// 这两者会不一致（录到一半被杀、用户手工删了 wav），
    /// 而列表上显示「2 轨」却打不开文件，比显示「0 轨」更让人困惑。
    func existingTracks(of manifest: RecordingManifest, in dir: URL) -> Int {
        manifest.tracks.filter {
            fileManager.fileExists(atPath: dir.appendingPathComponent($0.fileName).path)
        }.count
    }

    public func hasTranscript(in dir: URL) -> Bool {
        fileManager.fileExists(
            atPath: dir.appendingPathComponent(SessionStore.transcriptMarkdownName).path)
    }

    func modificationDate(of url: URL) -> Date {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
    }

    // MARK: - 读取内容

    public func manifest(forSessionID id: String) throws -> RecordingManifest {
        try store.loadManifest(forSessionID: id)
    }

    /// 读已有的转写稿。没有就返回 nil。
    public func transcript(forSessionID id: String) -> TranscriptDocument? {
        let url = store.directory(forSessionID: id)
            .appendingPathComponent(SessionStore.transcriptJSONName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TranscriptDocument.self, from: data)
    }

    /// 读一场已生成的纪要（`minutes.json`）。没有或读不出来返回 nil。
    ///
    /// 与 `transcript(forSessionID:)` 同一条读法。注意 `MinutesResult` 的
    /// 自定义 `init(from:)` 容得下缺 `generatorName` 的旧文件——
    /// 那是后加的溯源字段，不能因为它让读旧纪要直接崩。
    public func minutes(forSessionID id: String) -> MinutesResult? {
        let url = store.directory(forSessionID: id)
            .appendingPathComponent(MinutesService.minutesJSONName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MinutesResult.self, from: data)
    }

    public func trackURL(forSessionID id: String, fileName: String) -> URL {
        store.directory(forSessionID: id).appendingPathComponent(fileName)
    }

    // MARK: - 修改

    /// 删除整场会议（含音频）。用系统废纸篓而不是直接抹掉：
    /// 录音是**不可再生**的数据，误删一次就没了，而回收站给了最后一次反悔机会。
    public func delete(sessionID id: String) throws {
        let dir = store.directory(forSessionID: id)
        guard fileManager.fileExists(atPath: dir.path) else {
            throw MRError.io(path: dir.path, reason: "会话不存在")
        }
        var resulting: NSURL?
        do {
            try fileManager.trashItem(at: dir, resultingItemURL: &resulting)
        } catch {
            throw MRError.io(path: dir.path, reason: "移入废纸篓失败：\(error.localizedDescription)")
        }
    }

    /// 改标题。只改 manifest 里的 `title`，**不动目录名**——
    /// 目录名是会话 ID，转写稿、manifest 内部、用户脚本都可能已经引用它。
    public func rename(sessionID id: String, to newTitle: String) throws {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MRError.io(path: id, reason: "标题不能为空")
        }
        var manifest = try store.loadManifest(forSessionID: id)
        manifest.title = trimmed
        try store.save(manifest, sessionDirectory: store.directory(forSessionID: id))
    }

    /// 把一份**人工修改过**的转写稿写回磁盘（`transcript.json` + `transcript.md`）。
    ///
    /// ## 为什么必须两份一起写
    ///
    /// `transcript.json` 是数据源（纪要生成读它），`transcript.md` 是人读的那一份
    /// （导出、在访达里打开、发给别人）。只写 json 的话，用户在访达里打开的还是
    /// 改之前的稿子，而界面上显示的是改之后的——**两份文件互相打脸**，
    /// 且没有任何地方会报错。
    ///
    /// ## 为什么用 `atomic`
    ///
    /// 写盘发生在用户每次改动之后（不是退出时统一写），中途失败直接留下半份
    /// 文件的话，下次打开这场会议会读不出转写稿——一次错字修正换来整场稿子消失，
    /// 代价不对等。
    public func saveTranscript(_ document: TranscriptDocument, forSessionID id: String) throws {
        let directory = store.directory(forSessionID: id)
        let jsonURL = directory.appendingPathComponent(SessionStore.transcriptJSONName)
        let markdownURL = directory.appendingPathComponent(SessionStore.transcriptMarkdownName)
        do {
            try document.json().write(to: jsonURL, options: .atomic)
            try document.markdown().write(to: markdownURL, atomically: true, encoding: .utf8)
        } catch {
            throw MRError.io(path: directory.path,
                             reason: "转写稿保存失败：\(error.localizedDescription)")
        }
    }

    /// 转写稿是不是比纪要**新**（＝纪要生成之后又有人改过稿子）。
    ///
    /// 判据用文件 mtime 比较，不靠内存里的标志：关掉 App 再打开、或者用 CLI 改了稿子，
    /// 内存标志早没了，而「纪要基于旧稿」这个事实还在。mtime 也不依赖任何缓存。
    ///
    /// **读不到 mtime 时判 `false`**（＝不报警）：这是提示，不是判据本身，
    /// 报假警会训练用户忽略这个警告。真正要防的是「确实改过却不说」，
    /// 那种情况文件一定在、mtime 一定读得到。
    public func transcriptIsNewerThanMinutes(sessionID id: String) -> Bool {
        let directory = store.directory(forSessionID: id)
        let transcriptURL = directory.appendingPathComponent(SessionStore.transcriptJSONName)
        let minutesURL = directory.appendingPathComponent(MinutesService.minutesJSONName)
        guard let t = modificationDateIfPresent(transcriptURL),
              let m = modificationDateIfPresent(minutesURL) else { return false }
        return t > m
    }

    private func modificationDateIfPresent(_ url: URL) -> Date? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }
}
