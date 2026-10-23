import Foundation
import MRCore
import MRTranscribe

/// 「一场会议的音轨 → 转写稿文件」的编排。
///
/// 抽成独立一层有具体理由：这段逻辑（逐轨转写 → 按 hostTime 对齐 → 归并 → 落盘 → 改状态）
/// 原先只存在于 CLI 内部。GUI 需要**逐字一样**的语义——时间轴对齐差一毫秒就不该存在两套实现，
/// 而复制一份必然随时间漂移。所以放在这里，两个前端都调它。
///
/// 有意不在这里做任何输出：进度通过 `Progress` 事件回给调用方，
/// CLI 打成文字、GUI 画成进度条，各自决定。
public struct SessionTranscriber {

    /// 单轨稿的文件名（不含扩展名）：`transcript-mic`。
    ///
    /// 单一出处：CLI 打印、GUI 显示、文件名拼装都从这里取。
    /// 各处各拼一遍的话，`transcript-<轨>` 与 `transcript_<轨>` 会同时存在，
    /// 而用户无法从两个都像的文件名里判断哪个是刚生成的。
    public static func singleTrackFileStem(trackIDs: [String]) -> String {
        (["transcript"] + trackIDs.sorted()).joined(separator: "-")
    }

    public struct Configuration {
        public var language: String
        /// 用哪个转写引擎。默认 `.apple`（全局配置 `RecorderPreferences.transcriptionEngine`
        /// 的镜像；调用方应把全局偏好透传进来，不要每场单独传）。
        public var engine: TranscriptionEngine
        /// 超过该时长才分段（秒）。默认 `.infinity` 即不分段。
        ///
        /// 这是实测结论而非保守估计：分段要多花约 5 倍时间、16 倍内存，
        /// 而单段直转对 2 小时音频仍只要 56 秒、本进程内存恒定 24 MB。
        public var segmentThreshold: Double
        public var maxSegment: Double
        /// 保留切片文件（排查用）
        public var keepSlices: Bool
        /// 驱动器工厂。默认（nil）走 `TranscriptionEngineResolver` 的常规解析。
        ///
        /// 存在的理由是一个具体的坑：SenseVoice 的资产落在
        /// `~/Library/Application Support` 下，于是任何用例的结果都会
        /// **随开发机有没有装过模型而变化**——装了模型的机器上，一个「引擎未就绪」
        /// 的用例会突然走到真推理上去。这类「只在我的机器上是绿的」用例没有价值，
        /// 所以留一个把资产目录隔离掉的缝。
        public var makeDriver: ((TranscriptionEngine, String) -> any TranscriptionEngineDriver)?

        /// 只转写这些轨。`nil` 或空集 = 全部。
        ///
        /// ## 为什么值得有这个参数
        ///
        /// 真实会议库里**有相当比例的场次只有一条轨是有效的**——本机 4 条真实录音里
        /// 就有 3 场的 system 轨是 100% 静音（当时系统音频采集没起来）。
        /// 对这类场次做整场双轨转录有两处浪费：引擎对空轨照样跑一遍完整推理（时间翻倍），
        /// 以及空轨也被写进稿子、与真轨归并后时间轴上多出一堆无内容段落。
        ///
        /// ## 它刻意**不做**的两件事
        ///
        /// - **不覆盖整场稿。** 产物写 `transcript-<轨>.md`，
        ///   `transcript.md` 一个字节都不动。覆盖它会把另一条轨的内容永久抹掉，
        ///   而界面上「已转写」的标记还亮着。
        /// - **不改 `manifest.state`。** 只转了一半却标成 `.transcribed`，
        ///   界面上就显示成「已转写」，而用户根本没意识到缺了一半。
        public var trackFilter: Set<String>?

        public init(
            language: String = "zh-CN",
            engine: TranscriptionEngine = .apple,
            segmentThreshold: Double = .infinity,
            maxSegment: Double = 300,
            keepSlices: Bool = false,
            trackFilter: Set<String>? = nil,
            makeDriver: ((TranscriptionEngine, String) -> any TranscriptionEngineDriver)? = nil
        ) {
            self.language = language
            self.engine = engine
            self.segmentThreshold = segmentThreshold
            self.maxSegment = maxSegment
            self.keepSlices = keepSlices
            self.trackFilter = trackFilter
            self.makeDriver = makeDriver
        }

        /// 本次是不是**整场**转写（而非按轨筛选）。
        ///
        /// 单独抽出来是因为它同时决定三件事：产物文件名、manifest 状态改不改、
        /// 要不要加「没做跨轨去重」的说明。这三件必须同源——
        /// 任一处按「单轨」处理而另一处按「整场」，就会出现
        /// 「文件名是单轨的、状态标成整场已转写」这种自相矛盾。
        public var isWholeSession: Bool { trackFilter?.isEmpty ?? true }
    }

    /// 转写过程中的事件。GUI 用它显示进度，CLI 用它打日志。
    public enum Progress {
        case engineReady(language: String)
        /// 开始处理某条轨（`index` 从 1 开始）
        case trackStarted(id: String, displayName: String, index: Int, total: Int)
        case segmentStarted(trackID: String, index: Int, total: Int, start: Double, end: Double)
        case trackFinished(id: String, displayName: String, segmentCount: Int,
                           elapsed: Double, notes: [String], failedSegments: Int)
        /// 某轨整体失败。**其它轨继续**——一轨坏掉不该让另一轨也拿不到稿子。
        case trackFailed(id: String, displayName: String, message: String)
        case trackSkipped(id: String, reason: String)
        case aligned(trackID: String, offset: Double)
        case finished(segmentCount: Int)
    }

    public struct Outcome {
        public var document: TranscriptDocument
        public var markdownURL: URL
        public var jsonURL: URL
        /// 每轨的结果摘要，供界面显示「这是对方轨，53 段」这类信息
        public var tracks: [TrackResult]
        /// 整体性的告警（例如没有任何一轨产出内容）
        public var warnings: [String]
    }

    public struct TrackResult {
        public var id: String
        public var displayName: String
        public var segmentCount: Int
        public var elapsed: Double
        public var notes: [String]
        public var failedSegments: Int
        public var errorMessage: String?
        public var producedNothing: Bool { segmentCount == 0 && errorMessage == nil }
    }

    public let store: SessionStore
    public let configuration: Configuration

    public init(store: SessionStore, configuration: Configuration = Configuration()) {
        self.store = store
        self.configuration = configuration
    }

    /// 某个引擎是否支持该语言。默认查**默认引擎**（苹果原生）。
    ///
    /// 刻意带上 `engine` 参数：引擎是可全局切换的，一个「恒查苹果」的静态方法
    /// 会在配置成别的引擎时给出错误答案。转写时真正的能力判定在 `transcribe` 内部
    /// 按实际选中的驱动器做，这里只是给调用方（脚本、界面）一个提前查询的口子。
    public static func isLanguageSupported(
        _ language: String, engine: TranscriptionEngine = .apple
    ) async -> Bool {
        await TranscriptionEngineResolver.driver(for: engine, language: language)
            .isLanguageSupported(language)
    }

    /// 某个引擎支持的语言列表。默认查**默认引擎**（苹果原生）。
    public static func supportedLanguages(
        engine: TranscriptionEngine = .apple
    ) async -> [String] {
        await TranscriptionEngineResolver.driver(for: engine, language: "zh-CN")
            .supportedLanguages()
    }

    /// 转写一场会议。产出 `transcript.md` 与 `transcript.json`，并把 manifest 状态改为 `transcribed`。
    ///
    /// - Parameter sessionID: 会话 ID（目录名）
    /// - Parameter onProgress: 进度回调，在调用方线程上同步触发
    /// - Returns: 结果。**即使某轨失败也会返回**，失败信息在 `tracks[].errorMessage` 里。
    ///
    /// ## 按轨筛选（`configuration.trackFilter`）
    ///
    /// 指定之后行为有**三处**不同，缺一不可：
    /// 1. 只对选中的轨调引擎；
    /// 2. 产物写 `transcript-<轨>.md`，整场稿一个字节不动；
    /// 3. **不改 `manifest.state`**，并加一条说明讲清这份稿子没做什么。
    @discardableResult
    public func transcribe(
        sessionID: String,
        onProgress: ((Progress) -> Void)? = nil
    ) async throws -> Outcome {

        let directory = store.directory(forSessionID: sessionID)
        var manifest = try store.loadManifest(sessionDirectory: directory)
        let wholeSession = configuration.isWholeSession

        // 筛选要在**任何文件写入之前**做完，而且不认识的轨要报错。
        // 静默转成「转全部」是最糟的读法：用户敲 `--track mci`（手滑）拿到一份
        // 完整双轨稿，而以为自己只是重转了「我」那条——
        // 随后在「转写花了 3 倍时间」里找不到任何原因。
        let selectedTracks: [TrackManifest]
        if let filter = configuration.trackFilter, !filter.isEmpty {
            let available = manifest.tracks.map(\.id)
            let unknown = filter.subtracting(Set(available)).sorted()
            guard unknown.isEmpty else {
                throw MRError.invalidArgument(
                    "这场会议没有 \(unknown.map { "「\($0)」" }.joined(separator: "、")) "
                    + "这条音轨。可选：\(available.map { "「\($0)」" }.joined(separator: "、"))。")
            }
            // 按 manifest 的原顺序，而不是按筛选集给的顺序——
            // 进度条上的「第 1/2 条」必须与界面上的轨卡顺序一致。
            selectedTracks = manifest.tracks.filter { filter.contains($0.id) }
        } else {
            selectedTracks = manifest.tracks
        }

        let driver = configuration.makeDriver?(
            configuration.engine, configuration.language)
            ?? TranscriptionEngineResolver.driver(
                for: configuration.engine, language: configuration.language)

        guard await driver.isLanguageSupported(configuration.language) else {
            let available = await driver.supportedLanguages()
            throw MRError.transcription(
                reason: "引擎（\(configuration.engine.displayName)）不支持语言 \(configuration.language)。可用：\(available.joined(separator: ", "))")
        }

        // 先把引擎准备就绪，再动任何一条轨。
        //
        // 这一步不能省：逐轨转写是**单轨失败不中断**的（一轨坏掉不该连累另一轨），
        // 于是「引擎根本不可用」（比如没接完的骨架、资产装不上）会在每一轨各失败一次，
        // 最后留下一份空稿、退出码还是 0——那等于把「引擎坏了」说成「这场没人说话」。
        // 把 readiness 提到循环之前，这类失败在写任何文件之前就明确抛错、退出码非 0。
        try await driver.prepare()
        onProgress?(.engineReady(language: configuration.language))

        var segConfig = SegmentedTranscriber.Configuration()
        segConfig.segmentThreshold = configuration.segmentThreshold
        segConfig.maxSegment = configuration.maxSegment
        segConfig.keepSlices = configuration.keepSlices
        let segmented = SegmentedTranscriber(configuration: segConfig)

        // 各轨起点不同，转写结果是相对**本轨起点**的秒数，必须按 hostTime 平移
        // 才能归并到同一条时间线。会话基准取所有轨中最早的那个。
        //
        // 基准取**全部**轨而不是被选中的那些：单轨稿的时间必须与整场稿一致，
        // 否则同一场会议在两个文件里对不上时间，而用户会以为是转写错了。
        let sessionBase = TrackAlignment.sessionBase(
            hostTimes: manifest.tracks.map(\.firstHostTime))

        var merged: [(track: String, speaker: String, segments: [TranscriptSegment])] = []
        var trackResults: [TrackResult] = []
        var warnings: [String] = []
        let total = selectedTracks.count

        for (index, track) in selectedTracks.enumerated() {
            let display = track.role.displayName
            onProgress?(.trackStarted(id: track.id, displayName: display,
                                      index: index + 1, total: total))

            let url = store.trackURL(sessionDirectory: directory, fileName: track.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                onProgress?(.trackSkipped(id: track.id, reason: "音频文件不存在"))
                trackResults.append(TrackResult(
                    id: track.id, displayName: display, segmentCount: 0,
                    elapsed: 0, notes: [], failedSegments: 0,
                    errorMessage: "音频文件不存在：\(track.fileName)"))
                continue
            }

            let startedAt = Date()
            do {
                let outcome = try await segmented.transcribe(
                    fileURL: url, trackID: track.id, speaker: display,
                    engine: { file, trackID, speaker in
                        try await driver.transcribe(
                            fileURL: file, trackID: trackID, speaker: speaker)
                    },
                    progress: { index, total, start, end in
                        onProgress?(.segmentStarted(
                            trackID: track.id, index: index, total: total,
                            start: start, end: end))
                    })

                var segments = outcome.segments
                let elapsed = Date().timeIntervalSince(startedAt)

                // 引擎自己的诊断（例如「丢了几条纯标点空段」「VAD 切了几段」）拼在
                // 分段器的话之后。必须在这次转写**刚刚结束**时读——下一次调用会覆盖它。
                // 少了这一段，「这次少了几条」就只能靠猜，而猜测出来的原因通常是错的。
                var notes = outcome.notes
                if let diagnostics = driver as? TranscriptionEngineDiagnostics {
                    notes.append(contentsOf: diagnostics.lastNotes)
                }

                // 按 hostTime 平移，归到会话时间轴
                let offset = TrackAlignment.offset(
                    trackFirstHostTime: track.firstHostTime, sessionBase: sessionBase)
                if offset != 0 {
                    segments = segments.map { segment in
                        var s = segment
                        s.start = TrackAlignment.shift(s.start, by: offset)
                        s.end = max(s.start, TrackAlignment.shift(s.end, by: offset))
                        return s
                    }
                    onProgress?(.aligned(trackID: track.id, offset: offset))
                }

                onProgress?(.trackFinished(
                    id: track.id, displayName: display, segmentCount: segments.count,
                    elapsed: elapsed, notes: notes,
                    failedSegments: outcome.failedSegments))
                merged.append((track.id, display, segments))
                trackResults.append(TrackResult(
                    id: track.id, displayName: display, segmentCount: segments.count,
                    elapsed: elapsed, notes: notes,
                    failedSegments: outcome.failedSegments, errorMessage: nil))
            } catch {
                // 单轨失败不中断：另一轨的稿子仍然有价值，丢掉才是浪费
                onProgress?(.trackFailed(id: track.id, displayName: display,
                                         message: "\(error)"))
                warnings.append("音轨 \(display) 转写失败：\(error)")
                trackResults.append(TrackResult(
                    id: track.id, displayName: display, segmentCount: 0,
                    elapsed: Date().timeIntervalSince(startedAt), notes: [],
                    failedSegments: 0, errorMessage: "\(error)"))
            }
        }

        let transcribedCount = merged.reduce(0) { $0 + $1.segments.count }
        let document = TranscriptDocument.merge(
            sessionID: manifest.sessionID,
            title: manifest.title,
            language: configuration.language,
            engine: driver.engineID,
            tracks: merged)

        // 去重删掉了多少必须说出来。沉默地删内容是最糟的一种行为：
        // 用户会以为转写漏了，而不是知道有一段被判成回声。
        let removedEcho = transcribedCount - document.segments.count
        if removedEcho > 0 {
            warnings.append(
                "已去掉 \(removedEcho) 段重复内容：用扬声器开会时，对方的声音会经扬声器漏进麦克风，"
                + "两轨各转一遍就会把同一句话记两次。改用耳机可从根本上避免。")
        }

        // 单轨稿要说清它是单轨稿，以及**它没做什么**。
        //
        // 后半句是关键：用户用扬声器开会时，同一句话会在 mic 轨里出现两次
        // （一次是本人，一次是经扬声器漏进来的回声）。这份稿子没去过重，
        // 而文档不会主动说这件事——用户会把重复当成引擎出错。
        if !wholeSession {
            let selectedIDs = selectedTracks.map(\.id)
            let ids = selectedIDs.joined(separator: "、")
            warnings.append(
                "这是**单轨稿**，只转写了 \(ids)。"
                + "写到 \(Self.singleTrackFileStem(trackIDs: selectedIDs)).md，"
                + "整场转写稿（\(SessionStore.transcriptMarkdownName)）未被改动。")
            warnings.append(
                "单轨稿**不做跨轨去重**（也就没有回声/重复内容可去）："
                + "用扬声器开会时对方的话会经扬声器漏进麦克风，"
                + "这份稿子里同一句可能出现两次。要去重请跑整场转写（不加 --track）。")
        }

        // 全部音轨都没产出内容时要说出来。否则用户拿到一份空文稿，
        // 会以为转写功能坏了，而不是「这段录音本来就没声音」。
        if !trackResults.isEmpty, trackResults.allSatisfy(\.producedNothing) {
            warnings.append(wholeSession
                ? "所有音轨都没有识别到语音内容。可能是录音期间确实无人说话，"
                    + "也可能录音本身是空轨（授权未生效时录制会正常完成但缓冲全零）。"
                // 单轨下说「所有音轨」是错的：被排除的那条轨根本没进这次转写，
                // 用户会以为它也被查过且是空的。
                : "这条轨没有识别到语音内容。可能是这期间确实无人说话，"
                    + "也可能它本身是空轨（例如系统音频采集当时没起来）。")
        }

        // 落盘。单轨稿用带轨名的文件名——**绝不能覆盖整场稿**。
        let stem = wholeSession
            ? String(SessionStore.transcriptMarkdownName
                .replacingOccurrences(of: ".md", with: ""))
            : Self.singleTrackFileStem(trackIDs: selectedTracks.map(\.id))
        let markdownURL = directory.appendingPathComponent("\(stem).md")
        let jsonURL = directory.appendingPathComponent("\(stem).json")
        do {
            try document.markdown().write(to: markdownURL, atomically: true, encoding: .utf8)
            try document.json().write(to: jsonURL)
        } catch {
            throw MRError.io(path: directory.path,
                             reason: "转写稿写入失败：\(error.localizedDescription)")
        }

        // 只有**整场**转写才改状态。只转了一半却标成 `.transcribed`，
        // 界面上就显示成「已转写」，而用户根本没意识到缺了另一条轨。
        if wholeSession {
            manifest.state = .transcribed
            try store.save(manifest, sessionDirectory: directory)
        }
        onProgress?(.finished(segmentCount: document.segments.count))

        return Outcome(
            document: document, markdownURL: markdownURL, jsonURL: jsonURL,
            tracks: trackResults, warnings: warnings)
    }
}
