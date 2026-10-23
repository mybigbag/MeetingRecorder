import Foundation
import MRCore

/// 保留策略的执行层：哪些场次的音频可以移入废纸篓，以及真的移走它们。
///
/// ## 为什么「设置档位」与「执行清理」是两个动作
///
/// 改一个下拉框的期望是「以后按这个规则办」，不是「帮我清一批」。
/// 更实际的原因——**设档位的那一下用户没在用这个功能**，
/// 他不会预料到有东西会在那一刻消失。所以这一类只做 plan，删的动作必须显式发起。
///
/// ## 四条纪律（与 `RetentionPolicy` 的保守取向一致）
///
/// 1. **manifest 读不出来的一律跳过**，不用目录 mtime 猜。猜错的方向不对称：
///    往老猜会删掉刚录的会议，往新猜只是少删一场（用户无感）。
/// 2. **`state == .recording` 永不删**——可能正在录，也可能是崩溃残留。
/// 3. **没有转写稿的默认不删**。方案写的是「只留转写稿与波形」，
///    反过来读就是：没有转写稿 → 删了等于彻底没了。需要时由
///    `includeUntranscribed` 显式开口子（CLI 有，GUI 不给——GUI 少一次点击就多一次误操作）。
/// 4. **目录里有其它 `.wav` 产物（合并导出）时整场跳过**。
///    只删 manifest 登记过的轨文件——扫目录会把用户自己放进去的 `我的备份.wav` 也删掉。
///
/// 附带的一条：删走**废纸篓**而不是直接抹掉，与 `SessionLibrary.delete` 同一纪律。
/// 代价是「清了但磁盘没腾出来」，这是对的：腾磁盘是用户自己清空废纸篓的动作。
public struct SessionRetentionCleaner {

    public let store: SessionStore
    private let fileManager: FileManager

    /// 判断「现在几点」的方式抽成注入的闭包。抽它不是为了可测性好看——
    /// 时钟回拨、跨夏令时这些边界必须能被钉住，而它们只有在「时间可控」时才测得到。
    private let now: () -> Date

    /// 「把一个文件移走」的动作。抽出来是因为**它是本项目唯一会删用户录音的地方**，
    /// 而「删」有两种截然不同的实现：
    ///
    /// - `trashItem` → 废纸篓，用户能捞回来（生产必须走这条）
    /// - `removeItem` → 直接抹掉，用户无法反悔
    ///
    /// 两者在**文件都不见了**这件事上完全一致，所以任何「原路径不存在了」
    /// 的断言都区分不了它们。而端到端地去读 `~/.Trash` 又不可靠：
    /// 那是 macOS 的真实行为，在无头 / 权限受限的环境里会静默失效——
    /// 实测过一次，同一条「直接抹掉」的变异在命令行连跑 4 次都红，
    /// 放进完整跑批却稳定绿，而代码本身没有任何问题。
    ///
    /// 所以把动作本身变成注入点：测试能直接断言「调的是哪一个」，
    /// 不依赖任何系统行为。
    public typealias TrashAction = (URL) throws -> URL

    private let trash: TrashAction

    /// 生产默认的删除动作：**移到废纸篓**，并返回它的新位置。
    ///
    /// 暴露成静态成员是因为它是本项目唯一会删用户录音的动作，
    /// 而「移到废纸篓」与「直接抹掉」在「原路径不见了」这件事上完全一致——
    /// 端到端地读 `~/.Trash` 又依赖 macOS 的真实行为（实测会在无头环境里
    /// 静默失效，让一条正确的判据变成永远绿的东西）。
    /// 于是判据落在**动作自己的返回值**上：`trashItem` 成功时给出的
    /// `resultingItemURL` 是一个真实存在、且不同于原路径的位置；
    /// `removeItem` 压根没有这个返回值。
    public static func defaultTrash(_ url: URL, fileManager: FileManager = .default) throws -> URL {
        var resulting: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL? ?? url
    }

    public init(store: SessionStore,
                fileManager: FileManager = .default,
                now: @escaping () -> Date = { Date() },
                trash: TrashAction? = nil) {
        self.store = store
        self.fileManager = fileManager
        self.now = now
        if let trash {
            self.trash = trash
        } else {
            let fm = fileManager
            self.trash = { try Self.defaultTrash($0, fileManager: fm) }
        }
    }

    // MARK: - 计划（一个字节都不写）

    /// 单场会议的判定结果。
    public struct SessionPlan: Equatable, Sendable {
        public var sessionID: String
        public var title: String
        public var startedAt: Date
        /// 会被删掉的文件名（只是 `manifest.tracks` 里的那些）
        public var filesToDelete: [String]
        /// 这些文件的**实际磁盘字节数**合计，不用 manifest 的估算——
        /// manifest 记的是写入时的帧数，与盘上现状可能已经不一致（手工改过、被外部转过）。
        public var reclaimableBytes: Int
        /// 会被移入废纸篓的完整路径
        public var paths: [String]

        /// 不会删任何东西的场次：原因必须可读，不能是一个空条目。
        public var skipReason: String?
        /// 已转写过（`transcript.md` 或 `transcript.json` 任一存在）
        public var hasTranscript: Bool

        /// 这场**还没压过**（位深/采样率/声道至少有一项还是原始的）。
        ///
        /// 留着这个标记是因为删除与压缩的**顺序反了会白省**：先删后压，
        /// 省掉的是原始体积（32 位 48 kHz 立体声），而不是压后的 1/6。
        /// 而 `prune` 是不可逆的——用户清完之后再想起来「该先压」，已经没得压了。
        /// 这不是文案提醒能解决的问题，必须在报告里把「这场还能再省 N 倍」说出来。
        ///
        /// 判定口径与 `SessionAudioTranscoder` **同源**（都用 `bTier` 预设），
        /// 刻意不复用「文件头看起来是什么格式」——manifest 记的是转码器**回写后**的值，
        /// 两边同源才不会一个说压过一个说没压。
        public var isUncompressed: Bool

        /// 逐轨的源格式与盘上字节。压缩比按每轨各自的源格式加权算，
        /// 而不是取一个统一的「6 倍」——两条轨的源格式可以不同
        /// （麦克风常给单声道，系统轨是 2 声道），取统一值会报出一个假的收益。
        public struct SourceFormat: Equatable, Sendable {
            public var sampleRate: Double
            public var channels: Int
            public var format: WAVSampleFormat
            public var bytesOnDisk: Int

            public init(sampleRate: Double, channels: Int,
                        format: WAVSampleFormat, bytesOnDisk: Int) {
                self.sampleRate = sampleRate
                self.channels = channels
                self.format = format
                self.bytesOnDisk = bytesOnDisk
            }
        }

        public var sourceFormats: [SourceFormat]

        /// 已经压过这场能省下多少倍。仅在 `isUncompressed` 时有意义。
        public var potentialCompressionRatio: Double? {
            guard isUncompressed, reclaimableBytes > 0, !sourceFormats.isEmpty else {
                return nil
            }
            var before = 0.0
            var after = 0.0
            for t in sourceFormats {
                let target = AudioTranscoder.Target(
                    sampleRate: TrackWriteFormat.resolve(
                        sourceSampleRate: t.sampleRate,
                        sourceChannels: t.channels,
                        mono24k: true).sampleRate,
                    channels: TrackWriteFormat.resolve(
                        sourceSampleRate: t.sampleRate,
                        sourceChannels: t.channels,
                        mono24k: true).channels,
                    format: .pcm16)
                let bytes = Double(max(1, t.bytesOnDisk))
                // 字节数 ∝ 位深 × 采样率 × 声道
                let sourceFactor = Double(t.format.bitsPerSample)
                    * t.sampleRate * Double(t.channels)
                let targetFactor = Double(target.format.bitsPerSample)
                    * target.sampleRate * Double(target.channels)
                guard sourceFactor > 0 else { continue }
                before += bytes
                after += bytes * (targetFactor / sourceFactor)
            }
            guard before > 0, after > 0, after < before else { return nil }
            return before / after
        }

        public var isPrunable: Bool { skipReason == nil && !filesToDelete.isEmpty }

        public static func skipped(sessionID: String,
                                   title: String,
                                   startedAt: Date,
                                   reason: String,
                                   hasTranscript: Bool,
                                   isUncompressed: Bool = false) -> SessionPlan {
            SessionPlan(sessionID: sessionID, title: title, startedAt: startedAt,
                        filesToDelete: [], reclaimableBytes: 0, paths: [],
                        skipReason: reason, hasTranscript: hasTranscript,
                        isUncompressed: isUncompressed, sourceFormats: [])
        }
    }

    public struct Plan: Equatable, Sendable {
        public var policy: RetentionPolicy
        public var sessions: [SessionPlan]
        /// 目标不存在时（根目录没建起来）给出的说明
        public var rootNote: String?

        public var prunable: [SessionPlan] { sessions.filter(\.isPrunable) }
        public var skipped: [SessionPlan] { sessions.filter { !$0.isPrunable } }

        public var reclaimableBytes: Int { prunable.reduce(0) { $0 + $1.reclaimableBytes } }

        public var sessionCount: Int { prunable.count }

        /// 会被删、但**还没压过**的场次。
        ///
        /// 这批是顺序反了就白省的那批：它们才是「先转码再清理」能多省下的部分。
        public var uncompressedPrunable: [SessionPlan] {
            prunable.filter(\.isUncompressed)
        }

        /// 「先压后删」总共能多腾出多少字节。
        public var additionalBytesIfCompressedFirst: Int {
            uncompressedPrunable.reduce(0) { acc, sp in
                guard let r = sp.potentialCompressionRatio else { return acc }
                return acc + Int(Double(sp.reclaimableBytes) - Double(sp.reclaimableBytes) / r)
            }
        }

        /// 一场都不会删。GUI 据此灰掉确认按钮，CLI 据此提前收工。
        public var isEmpty: Bool { prunable.isEmpty }

        /// 显式 init。**不写的话成员级 init 是 internal**，
        /// 而 GUI 测试要能造一个空 Plan 来验「没有要清理的内容」那句话。
        public init(policy: RetentionPolicy,
                    sessions: [SessionPlan],
                    rootNote: String? = nil) {
            self.policy = policy
            self.sessions = sessions
            self.rootNote = rootNote
        }
    }

    /// 算一遍「会删掉什么」，不写任何字节。
    public func plan(policy: RetentionPolicy,
                     includeUntranscribed: Bool = false) throws -> Plan {
        guard fileManager.fileExists(atPath: store.root.path) else {
            return Plan(policy: policy, sessions: [],
                        rootNote: "存储根目录还不存在：\(store.root.path)")
        }
        let ids = (try? store.listSessionIDs()) ?? []
        let current = now()
        var sessions: [SessionPlan] = []
        for id in ids {
            sessions.append(planSession(id: id, policy: policy,
                                        includeUntranscribed: includeUntranscribed,
                                        now: current))
        }
        // 最新的排在前面，与 `SessionLibrary.list()` 的顺序一致——
        // 两份列表顺序不同会让用户在两边对照时怀疑其中一个坏了。
        sessions.sort { a, b in
            a.startedAt != b.startedAt ? a.startedAt > b.startedAt : a.sessionID > b.sessionID
        }
        return Plan(policy: policy, sessions: sessions, rootNote: nil)
    }

    func planSession(id: String,
                     policy: RetentionPolicy,
                     includeUntranscribed: Bool,
                     now: Date) -> SessionPlan {
        let dir = store.directory(forSessionID: id)

        func skip(_ reason: String, startedAt: Date = Date()) -> SessionPlan {
            .skipped(sessionID: id, title: id, startedAt: startedAt,
                     reason: reason,
                     hasTranscript: fileExistsTranscript(in: dir))
        }

        // 纪律 2：manifest 读不出来 → 跳过。**不用目录 mtime 猜年龄。**
        // 那个条目的 `startedAt` 是目录修改时间，往老猜会删掉刚录的会议。
        let manifest: RecordingManifest
        do { manifest = try store.loadManifest(forSessionID: id) }
        catch { return skip("manifest 读不出来（\(error.localizedDescription)）。年龄无从判断，跳过。") }

        let startedAt = manifest.startedAt
        let title = manifest.title.isEmpty ? id : manifest.title
        let hasTranscript = fileExistsTranscript(in: dir)

        // 纪律 4：录制中的不碰。
        if manifest.state == .recording {
            return .skipped(sessionID: id, title: title, startedAt: startedAt,
                            reason: "状态是「正在录制」——可能真的还在录，也可能是崩溃没被恢复。",
                            hasTranscript: hasTranscript)
        }

        // 纪律 3：没有转写稿的默认不删。
        if !hasTranscript && !includeUntranscribed {
            return .skipped(
                sessionID: id, title: title, startedAt: startedAt,
                reason: "还没转写过。删掉音频之后这场就只剩标题和时长了，没有内容可留。",
                hasTranscript: hasTranscript)
        }

        // 附加纪律：目录里还有别的 wav（合并导出）就整场跳过。
        if let merged = mergedArtifacts(in: dir, manifest: manifest) {
            return .skipped(
                sessionID: id, title: title, startedAt: startedAt,
                reason: "这场有合并导出的文件（\(merged)），很可能正被当作主要听音入口。"
                    + "删掉两条原轨会造成「mic 轨打不开」这种没法解释的现象。",
                hasTranscript: hasTranscript)
        }

        // 档位判定。`.off` 在这里返回 false，与年龄无关。
        guard policy.selects(startedAt: startedAt, now: now) else {
            return .skipped(sessionID: id, title: title, startedAt: startedAt,
                            reason: "还没到 \(policy.displayName)。",
                            hasTranscript: hasTranscript)
        }

        // 只删 manifest 登记过、且文件真的在盘上的轨文件。
        // 清单里不在的（用户手工删过）静默跳过——不是错误。
        var names: [String] = []
        var paths: [String] = []
        var bytes = 0
        var sourceFormats: [SessionPlan.SourceFormat] = []
        var stillUncompressed = false
        for t in manifest.tracks {
            let url = dir.appendingPathComponent(t.fileName)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            names.append(t.fileName)
            paths.append(url.path)
            bytes += size
            sourceFormats.append(.init(sampleRate: t.sampleRate, channels: t.channels,
                                       format: t.sampleFormat, bytesOnDisk: size))
            // 只要还有一条轨是原始格式，这场就仍算「没压过」。
            // 判「全部压过」比判「至少压过一条」保守：宁可多提醒一次顺序问题。
            if !Self.isCompressedToBTier(t) { stillUncompressed = true }
        }
        return SessionPlan(sessionID: id, title: title, startedAt: startedAt,
                           filesToDelete: names, reclaimableBytes: bytes, paths: paths,
                           skipReason: nil, hasTranscript: hasTranscript,
                           isUncompressed: stillUncompressed,
                           sourceFormats: sourceFormats)
    }

    /// 这条轨是否已经是「压过」的形态（pcm16 · 单声道 24 kHz）。
    ///
    /// 用 `TrackWriteFormat.resolve(mono24k: true)` 而不是硬编码 24000/1——
    /// 实时录制走的是同一个决策函数，两处同源才不会「录的时候按 A 判、
    /// 清理的时候按 B 判」而得出相反结论。
    static func isCompressedToBTier(_ t: TrackManifest) -> Bool {
        let w = TrackWriteFormat.resolve(sourceSampleRate: t.sampleRate,
                                          sourceChannels: t.channels,
                                          mono24k: true)
        return t.sampleFormat == .pcm16 && t.channels == w.channels && t.sampleRate == w.sampleRate
    }

    // MARK: - 执行

    public struct SessionOutcome: Equatable, Sendable {
        public var sessionID: String
        public var title: String
        public var deletedFiles: [String]
        public var freedBytes: Int
        public var failed: String?
        public var skippedReason: String?

        public var isSuccess: Bool { failed == nil && skippedReason == nil }
    }

    public struct Outcome: Equatable, Sendable {
        public var policy: RetentionPolicy
        public var dryRun: Bool
        public var sessions: [SessionOutcome]
        public var notes: [String]

        public var deleted: [SessionOutcome] { sessions.filter(\.isSuccess) }
        public var failed: [SessionOutcome] { sessions.filter { $0.failed != nil } }
        public var skipped: [SessionOutcome] { sessions.filter { $0.skippedReason != nil } }

        public var freedBytes: Int { deleted.reduce(0) { $0 + $1.freedBytes } }
        public var deletedFileCount: Int { deleted.reduce(0) { $0 + $1.deletedFiles.count } }

        /// 「一场都没失败，且至少删掉了东西」。
        /// 注意**不是**「没有失败」——全场都被跳过时 `failed` 也为空，但那时什么都没做，
        /// 报成成功就是撒谎（与 `SessionAudioTranscoder.Outcome.isCompleteSuccess` 同纪律）。
        public var isCompleteSuccess: Bool {
            failed.isEmpty && !deleted.isEmpty
        }
    }

    /// 执行清理。
    ///
    /// - Parameter dryRun: 只走 `plan`，一个字节都不写。
    public func run(policy: RetentionPolicy,
                    includeUntranscribed: Bool = false,
                    dryRun: Bool = false) throws -> Outcome {
        let plan = try self.plan(policy: policy, includeUntranscribed: includeUntranscribed)
        var notes: [String] = []

        if let note = plan.rootNote { notes.append(note) }
        if !policy.isEnabled {
            notes.append("保留策略是「\(policy.displayName)」，不会删任何东西。")
        }
        if dryRun {
            notes.append("模式：--dry-run，**一个文件都不会被删**。")
        }
        if !includeUntranscribed {
            notes.append("默认只清理已经转写过的会议（没转写的删了就没有内容了）。"
                + "要连没转写的一起清，加 --include-untranscribed。")
        }

        var outcomes: [SessionOutcome] = []
        for sp in plan.sessions {
            if let reason = sp.skipReason {
                outcomes.append(SessionOutcome(sessionID: sp.sessionID, title: sp.title,
                                               deletedFiles: [], freedBytes: 0,
                                               failed: nil, skippedReason: reason))
                continue
            }
            if sp.filesToDelete.isEmpty {
                outcomes.append(SessionOutcome(
                    sessionID: sp.sessionID, title: sp.title, deletedFiles: [], freedBytes: 0,
                    failed: nil,
                    skippedReason: "音频文件已经不在盘上（之前清过了）。"))
                continue
            }
            if dryRun {
                outcomes.append(SessionOutcome(sessionID: sp.sessionID, title: sp.title,
                                               deletedFiles: sp.filesToDelete,
                                               freedBytes: sp.reclaimableBytes,
                                               failed: nil, skippedReason: nil))
                continue
            }
            // 真的删。**逐文件、一场失败不中断整批**。
            var deleted: [String] = []
            var freed = 0
            var failure: String?
            for (name, path) in zip(sp.filesToDelete, sp.paths) {
                do {
                    let resulting = try trash(URL(fileURLWithPath: path))
                    deleted.append(name)
                    freed += (try? fileManager.attributesOfItem(
                        atPath: resulting.path)[.size] as? Int) ?? 0
                } catch let e {
                    failure = "\(name)：\(e.localizedDescription)"
                    break
                }
            }
            outcomes.append(SessionOutcome(sessionID: sp.sessionID, title: sp.title,
                                           deletedFiles: deleted, freedBytes: freed,
                                           failed: failure, skippedReason: nil))
        }
        return Outcome(policy: policy, dryRun: dryRun, sessions: outcomes, notes: notes)
    }

    // MARK: - 辅助

    /// 转写稿是否存在。**md 与 json 任一存在就算有**——与
    /// `SessionAudioTranscoder.hasTranscript` 同口径，理由也一样：
    /// 只认 json 会把「只有 md 稿」的场次误判成没转写过，于是那场永不被清理。
    func fileExistsTranscript(in dir: URL) -> Bool {
        [SessionStore.transcriptMarkdownName, SessionStore.transcriptJSONName].contains {
            fileManager.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    /// 目录里除manifest 登记的轨之外还有哪些 `.wav`。返回第一个（用于说明）。
    func mergedArtifacts(in dir: URL, manifest: RecordingManifest) -> String? {
        let known = Set(manifest.tracks.map(\.fileName))
        let entries = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries.first { name in
            let lower = name.lowercased()
            return lower.hasSuffix(".wav") && !known.contains(name)
        }
    }
}