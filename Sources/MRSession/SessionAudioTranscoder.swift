import Foundation
import MRCore

/// 整场会议的离线转码：把两条（或多条）轨统一转成目标格式，并同步 manifest。
///
/// ## 为什么单独一层，不能让 CLI 直接调 `AudioTranscoder`
///
/// 因为**批量改写用户已有录音**这件事有三道纪律，每一道都必须在「整场」这一层才成立：
///
/// 1. **原文件在验证通过之前必须完好**。做法是写临时文件 → 校验 → 原子替换，
///    全程原文件都在（只有 `replaceItem` 那一瞬是切换）。
///    任何一步失败就删掉临时文件走人，原文件连一个字节都没动。
/// 2. **manifest 必须跟着改**。漏改的后果不是「显示不对」而是**数据不一致**：
///    `framesWritten / sampleRate` 算出的时长会变成真实时长的 1/2 或 2 倍，
///    而文件本身照样能播、界面照样显示时长——没有任何地方会报错。
/// 3. **已转写过的场次要提醒**。转写稿里带的是**旧格式下的时间轴与文本**；
///    音频换了格式之后那份文稿仍然有效（文本没变），但「逐字时间戳」的精度会受轻微影响。
///    这件事必须说出来，而不是让用户自己发现。
public struct SessionAudioTranscoder {

    public let store: SessionStore
    /// 时长守住的判据。零相位 FIR 的尾部补零会让时长**略长**约半个窗宽
    /// （48 kHz → 24 kHz 下约 1.3 ms），所以判据是「不超过 2 ms」而不是「恰好相等」，
    /// 也不是宽松的 5%——宽松的判据连「24k 写成 48k」这种双倍错误都抓不住。
    public static let durationToleranceSeconds: Double = 0.002

    public init(store: SessionStore) {
        self.store = store
    }

    // MARK: - 计划（一个字节都不写）

    public struct TrackPlan: Equatable, Sendable {
        public var trackID: String
        public var fileName: String
        public var sourcePath: String
        public var exists: Bool
        /// 目标已经是这个格式 → 本轨无事可做（`estimate` 仍会给出数字，调用方据此跳过）
        public var alreadyConverted: Bool
        public var estimate: AudioTranscoder.TranscodeResult
        /// `alreadyConverted` 时为 nil（不写一个字节，所以没有结果）
        public var skipReason: String?
    }

    public struct Plan: Equatable, Sendable {
        public var sessionID: String
        public var title: String
        public var tracks: [TrackPlan]
        public var hasTranscript: Bool

        /// 全部轨都已转过 → 整场无事可做
        public var isNoop: Bool { tracks.allSatisfy(\.alreadyConverted) }

        public var sourceBytes: Int {
            tracks.filter { !$0.alreadyConverted && $0.exists }
                .reduce(0) { $0 + $1.estimate.sourceBytes }
        }

        public var targetBytes: Int {
            tracks.filter { !$0.alreadyConverted && $0.exists }
                .reduce(0) { $0 + $1.estimate.targetBytes }
        }

        public var savedBytes: Int { max(0, sourceBytes - targetBytes) }

        /// 缺失的轨（文件不在盘上）。非空时应视为**不要开始**：
        /// 缺一条轨就转这一场，会留下一场「一半新一半旧」的会议，比不转更难解释。
        public var missingTracks: [TrackPlan] { tracks.filter { !$0.exists } }
    }

    /// 算一遍「转完会怎样」，不写任何字节。
    public func plan(sessionID: String,
                     preset: AudioTranscoder.Preset,
                     downmix: MonoDownmixStrategy = .firstChannel) throws -> Plan {
        let manifest = try store.loadManifest(forSessionID: sessionID)
        let dir = store.directory(forSessionID: sessionID)
        var plans: [TrackPlan] = []
        for t in manifest.tracks {
            let file = store.trackURL(sessionDirectory: dir, fileName: t.fileName)
            let exists = FileManager.default.fileExists(atPath: file.path)
            var estimate = AudioTranscoder.TranscodeResult(
                preset: preset, sourceSampleRate: t.sampleRate, sourceChannels: t.channels,
                sourceFormat: t.sampleFormat, target: .init(sampleRate: 1, channels: 1, format: t.sampleFormat),
                sourceFrames: t.framesWritten, targetFrames: 0, peakAmplitude: 0, downmix: downmix)
            var already = false
            var reason: String?
            if exists {
                let header = try WAVWriter.readHeader(at: file)
                // manifest 记的格式可能与文件真实格式不一致（老场子、或手工改过），
                // 所以这里用**文件头**算，而不是信 manifest。
                let sourceFormat = AudioTranscoder.sourceFormat(of: header)
                estimate = AudioTranscoder.estimate(source: header, preset: preset,
                                                     sourceFormat: sourceFormat)
                if estimate.target.isSameFormat(asSourceRate: header.sampleRate,
                                                sourceChannels: header.channels,
                                                sourceFormat: sourceFormat) {
                    already = true
                    reason = "已经是 \(estimate.target.shortName)"
                }
            } else {
                reason = "文件不在盘上（\(t.fileName)）"
            }
            plans.append(TrackPlan(trackID: t.id, fileName: t.fileName,
                                   sourcePath: file.path, exists: exists,
                                   alreadyConverted: already,
                                   estimate: estimate, skipReason: reason))
        }
        return Plan(sessionID: sessionID, title: manifest.title, tracks: plans,
                    hasTranscript: Self.hasTranscript(inDirectory: dir))
    }

    /// 这场有没有转写稿。**md 与 json 任一存在就算有**。
    ///
    /// 刻意与 `SessionLibrary` 同口径（那边看的是 `transcript.md`）：只认 json 的话，
    /// 一场有 md 稿的会议会被判成「没转写过」，于是不给出那条精度提醒。
    /// 判定宽松一边的代价只是多打一行提示，而漏掉提示的代价是用户事后才发现。
    static func hasTranscript(inDirectory dir: URL) -> Bool {
        [SessionStore.transcriptMarkdownName, SessionStore.transcriptJSONName].contains {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    // MARK: - 执行

    public struct TrackOutcome: Equatable, Sendable {
        public var trackID: String
        public var result: AudioTranscoder.TranscodeResult?
        public var skipped: Bool
        public var reason: String?
        public var failed: String?
        /// `--keep-original` 时留下的备份路径（未开启则为 nil）
        public var backupPath: String?

        public init(trackID: String,
                    result: AudioTranscoder.TranscodeResult?,
                    skipped: Bool,
                    reason: String? = nil,
                    failed: String? = nil,
                    backupPath: String? = nil) {
            self.trackID = trackID
            self.result = result
            self.skipped = skipped
            self.reason = reason
            self.failed = failed
            self.backupPath = backupPath
        }
    }

    public struct Outcome: Equatable, Sendable {
        public var sessionID: String
        public var preset: AudioTranscoder.Preset
        public var tracks: [TrackOutcome]
        public var manifestUpdated: Bool
        public var notes: [String]

        public var succeeded: [TrackOutcome] { tracks.filter { $0.result != nil && $0.failed == nil } }
        public var failed: [TrackOutcome] { tracks.filter { $0.failed != nil } }

        /// 「全部该转的都转成了、且一条都没失败」。注意**不是**「没有失败」——
        /// 一场里所有轨都已转过时 `failed` 也为空，但那时什么都没做，不该算成功。
        public var isCompleteSuccess: Bool {
            failed.isEmpty && !succeeded.isEmpty && !tracks.allSatisfy(\.skipped)
        }
    }

    /// 转一场。
    ///
    /// - Parameter dryRun: 只走 `plan` 并把结果折成 `Outcome`，一个字节都不写。
    /// - Parameter keepOriginal: 校验通过后**先把原文件复制一份**成 `.{fileName}.orig`
    ///   再原子替换。备份是「复制」而不是「先移走」——移动会让原文件在替换前有
    ///   一瞬不存在，把「全程原文件完整存在」这条纪律破掉。代价是峰值磁盘占用翻倍，
    ///   所以默认关：批量迁移 3.28 GiB 时开它等于先把磁盘填满。
    public func run(sessionID: String,
                    preset: AudioTranscoder.Preset,
                    downmix: MonoDownmixStrategy = .firstChannel,
                    dryRun: Bool = false,
                    keepOriginal: Bool = false) throws -> Outcome {
        let plan = try plan(sessionID: sessionID, preset: preset, downmix: downmix)
        var notes: [String] = []

        if !plan.missingTracks.isEmpty {
            notes.append("跳过：\(plan.missingTracks.map(\.trackID).joined(separator: "、")) "
                + "的音频文件不在盘上。转一半会留下一场「一半新一半旧」的会议，比不转更难解释。")
        }
        if plan.isNoop {
            notes.append("无需转码：所有轨都已经是目标格式。")
        }
        if plan.hasTranscript {
            notes.append("这场已转写过。转写稿的**文本与时间轴仍然有效**"
                + "（音频内容没变，只是换了封装格式），但逐字时间戳的精度会有亚毫秒级差异。")
        }
        if dryRun {
            return Outcome(sessionID: sessionID, preset: preset,
                           tracks: plan.tracks.map {
                               TrackOutcome(trackID: $0.trackID,
                                            result: $0.alreadyConverted ? nil : $0.estimate,
                                            skipped: $0.alreadyConverted || !$0.exists,
                                            reason: $0.skipReason, failed: nil)
                           },
                           manifestUpdated: false, notes: notes)
        }

        let dir = store.directory(forSessionID: sessionID)
        var outcomes: [TrackOutcome] = []
        var manifest = try store.loadManifest(forSessionID: sessionID)
        var manifestChanged = false

        for tp in plan.tracks {
            guard tp.exists else {
                outcomes.append(TrackOutcome(trackID: tp.trackID, result: nil,
                                             skipped: true, reason: tp.skipReason, failed: nil))
                continue
            }
            guard !tp.alreadyConverted else {
                outcomes.append(TrackOutcome(trackID: tp.trackID, result: nil,
                                             skipped: true, reason: tp.skipReason, failed: nil))
                continue
            }
            let src = URL(fileURLWithPath: tp.sourcePath)
            // 临时名必须与目标不同名，且**不能**是 .wav——`WAVReader` 只按内容解析，
            // 但用户 / `SessionLibrary` 会按扩展名找文件，留一个 .wav 后缀的垃圾会
            // 被当成「第三条轨」。
            let tmp = dir.appendingPathComponent(".\(tp.fileName).transcode-tmp")
            try? FileManager.default.removeItem(at: tmp)

            do {
                let r = try AudioTranscoder.transcode(source: src, destination: tmp,
                                                      preset: preset, downmix: downmix)
                // —— 校验：这一段是整件事的核心。过了才替换，过不了就原样退出。——
                let problems = try verify(result: r, temporaryFile: tmp)
                guard problems.isEmpty else {
                    try? FileManager.default.removeItem(at: tmp)
                    outcomes.append(TrackOutcome(
                        trackID: tp.trackID, result: nil, skipped: false, reason: nil,
                        failed: "校验未通过，原文件保持不变：\(problems.joined(separator: "；"))"))
                    continue
                }
                // 备份走**复制**而不是移动：移动会让原文件在替换前有一瞬不存在。
                var backupPath: String?
                if keepOriginal {
                    let backup = dir.appendingPathComponent(".\(tp.fileName).orig")
                    try? FileManager.default.removeItem(at: backup)
                    do {
                        try FileManager.default.copyItem(at: src, to: backup)
                        backupPath = backup.path
                    } catch {
                        // 备份不下来就不转。宁可这一轨保持原样，也不做一次「撤不回去」的改写。
                        try? FileManager.default.removeItem(at: tmp)
                        outcomes.append(TrackOutcome(
                            trackID: tp.trackID, result: nil, skipped: false, reason: nil,
                            failed: "备份原文件失败，已放弃本轨（\(error.localizedDescription)）"))
                        continue
                    }
                }
                // 原子替换：原文件在这一瞬之前一直完整存在。
                //
                // **参数顺序极易写反，而且写反的后果是删掉用户的录音。**
                // `replaceItemAt(A, withItemAt: B)` 的语义是「用 **B** 的内容替换 **A**，
                // 然后 **B 消失**」——不是「把 B 搬到 A」。实测确认：
                // 反着写（`replaceItemAt(tmp, withItemAt: src)`）之后
                // `mic.wav` 不见了、临时文件原地留下。
                //
                // 对照实验（2026-10-04，`/tmp/rex`）：
                //   orig.txt = "AAA"、.tmp.txt = "BBBB"
                //   replaceItemAt(.tmp.txt, withItemAt: orig.txt)
                //   → orig.txt 消失，.tmp.txt = "AAA"
                // 所以正确的写法是**让原文件当第一个参数**（被替换方），
                // 临时文件当第二个（提供内容、用完即弃）。
                _ = try FileManager.default.replaceItemAt(src, withItemAt: tmp)
                updateManifest(&manifest, trackID: tp.trackID, result: r)
                manifestChanged = true
                // 源本来是静音：这不是故障，但**必须说出来**。
                // 静默转完会让用户以为「这场没声音是因为系统音频没录到」，
                // 而真实原因（采集没起来）藏在几十天前的某个时刻，没人会记得。
                if r.sourceIsSilent {
                    notes.append("\(tp.trackID) 这条轨源文件本身是全静音的"
                        + "（通常是当时系统音频采集没起来），转码后仍然是静音。"
                        + "体积会变小，但里面没有声音——这不是转码的问题。")
                }
                outcomes.append(TrackOutcome(trackID: tp.trackID, result: r,
                                             skipped: false, reason: nil, failed: nil,
                                             backupPath: backupPath))
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                outcomes.append(TrackOutcome(trackID: tp.trackID, result: nil, skipped: false,
                                             reason: nil,
                                             failed: "\(error.localizedDescription)"))
            }
        }

        if manifestChanged {
            try store.save(manifest, sessionDirectory: dir)
        }
        return Outcome(sessionID: sessionID, preset: preset, tracks: outcomes,
                       manifestUpdated: manifestChanged, notes: notes)
    }

    // MARK: - 校验与 manifest

    /// 转码结果的校验。**返回问题列表而不是 `Bool`**：
    /// 出错时用户要看到「到底哪几项不对」，只给一个 false 会让人无从下手。
    private func verify(result: AudioTranscoder.TranscodeResult,
                        temporaryFile: URL) throws -> [String] {
        var problems: [String] = []
        let header = try WAVWriter.readHeader(at: temporaryFile)

        if header.sampleRate != result.target.sampleRate {
            problems.append("文件头采样率 \(Int(header.sampleRate)) Hz ≠ 目标 \(Int(result.target.sampleRate)) Hz")
        }
        if header.channels != result.target.channels {
            problems.append("文件头声道数 \(header.channels) ≠ 目标 \(result.target.channels)")
        }
        if header.bitsPerSample != result.target.format.bitsPerSample
            || header.audioFormatID != result.target.format.audioFormatID {
            problems.append("文件头位深/格式码与目标 \(result.target.format.displayName) 不符")
        }
        if header.frameCount != result.targetFrames {
            problems.append("文件头帧数 \(header.frameCount) ≠ 写入帧数 \(result.targetFrames)")
        }
        if !header.isConsistent {
            problems.append("头部声明的长度与文件实际长度不一致")
        }
        // 时长必须守住。这是最容易错也最容易验的一项：
        // 24k 写成 48k（或反过来）会让它正好差一倍，而文件照样能播。
        if abs(result.durationDelta) > Self.durationToleranceSeconds {
            problems.append(String(format: "时长差 %.1f ms 超过 %.1f ms（源 %.4f s → 目标 %.4f s）",
                                   result.durationDelta * 1000, Self.durationToleranceSeconds * 1000,
                                   result.sourceDuration, result.targetDuration))
        }
        // 「把声音弄丢了」必须挡住：源有内容、转码后全零 = 读或写坏了。
        // 体积和时长都会「看起来正常」，只有内容会露馅。
        //
        // 判据是 `sourcePeak > 0 && targetPeak == 0`，**不是**「目标为 0」。
        // 后者会在源本身全静音时报成故障——本机真实会议库里有 3 条 100% 静音轨
        // （系统音频采集没起来留下的空轨），E 档整库实跑时它们把批量迁移顶挂了，
        // 而转成任何格式它们都是全零，那**不是**故障。
        if result.lostSignal {
            problems.append(String(format: "转码后丢了声音：源峰值 %.6f → 目标峰值 0",
                                   result.sourcePeakAmplitude))
        }
        return problems
    }

    private func updateManifest(_ manifest: inout RecordingManifest,
                                trackID: String,
                                result: AudioTranscoder.TranscodeResult) {
        guard let i = manifest.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        manifest.tracks[i].sampleRate = result.target.sampleRate
        manifest.tracks[i].channels = result.target.channels
        manifest.tracks[i].sampleFormat = result.target.format
        manifest.tracks[i].framesWritten = result.targetFrames
        // 时间戳**不动**：它记的是「采集时第几个 hostTime」，与文件格式无关。
        // 改它会让这条轨与另一条轨的对齐关系平移几毫秒。
    }
}
