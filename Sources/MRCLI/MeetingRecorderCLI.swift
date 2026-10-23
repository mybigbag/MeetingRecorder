import Foundation
import CoreAudio
import os
import MRCore
import MRCapture
import MRTranscribe
import MRSession
import MRMinutes

/// 命令行前端。
///
/// 入口分派在 `main.swift`：不带参数（双击 .app）走 GUI，带参数走这里。
/// 因此这里**没有** `@main`，也**不读** `CommandLine.arguments`——
/// 参数一律由调用方传入。自己读会让 GUI 那条路径拿到错误的参数集。
///
/// 设计原则：录制与转写分离。录完再转，录制期间不占算力、不影响会议本身。
public enum MeetingRecorderCLI {

    /// 返回值即进程退出码，由 `main.swift` 交给 `exit()`。
    ///
    /// 刻意用返回值而不是直接 `exit()`：退出码在这里只表示意图，
    /// 「什么时候真正结束进程」是入口的事。
    public static func run(_ rawArgs: [String]) async -> Int32 {
        var args = rawArgs
        guard let command = args.first else {
            printUsage()
            return 0
        }
        args.removeFirst()

        // `-h` / `--help` 出现在**子命令后面**时，此前没有任何处理：`record --help`
        // 只被当成「一个多余的开关」而忽略，于是**直接开录**——实测就这样往真实会议库
        // 里写进了 2 分钟无用录音（约 68 MB，含真实环境音）。这不是「用户敲错了命令」，
        // 是这段分派缺了一条最基本的读法：任何命令后面跟 `--help` 都该打印用法。
        // 命中时只打印用法：不碰采集设备、不建目录、不写日志文件。
        if Self.wantsHelp(args) {
            printUsage()
            return 0
        }

        do {
            switch command {
            case "record":      try await runRecord(args)
            case "transcribe":  try await runTranscribe(args)
            case "transcode":   try runTranscode(args)
            case "merge":       try runMerge(args)
            case "prune":try runPrune(args)
            case "list":        try runList(args)
            case "recover":     try runRecover(args)
            case "devices":     try runDevices()
            case "minutes":     try await runMinutes(args)
            case "config":      try runConfig(args)
            case "model":       try await runModel(args)
            case "doctor":      return try await runDoctor()
            case "version", "--version", "-V": return Self.runVersion()
            case "help", "-h", "--help": printUsage()
            default:
                FileHandle.standardError.write(Data("未知命令：\(command)\n\n".utf8))
                printUsage()
                return 2
            }
            return 0
        } catch {
            let message = "❌ \(error)"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            // `open -n -a` 启动的 app 没有终端，stderr 全部丢失。
            // 失败原因必须能留下来，否则后台录制出问题只能靠猜。
            Self.appendToLogFileIfRequested(message, in: rawArgs)
            return 1
        }
    }

    /// 把一行消息追加到命令行里 `--log` 指定的文件（若提供了的话）
    static func appendToLogFileIfRequested(_ message: String, in argumentList: [String]) {
        guard let i = argumentList.firstIndex(of: "--log"), i + 1 < argumentList.count else { return }
        let path = (argumentList[i + 1] as NSString).expandingTildeInPath
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else { return }
        defer { try? handle.close() }
        // `FileHandle(forWritingTo:)` 打开后光标在**文件开头**，不是末尾。
        // 少了这一步，「追加」会变成从头覆盖，把上一次的失败原因抹掉。
        // 返回的新偏移量这里用不上，日志写入失败一律静默（原设计如此）。
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((message + "\n").utf8))
        try? handle.synchronize()
    }

    // MARK: - 参数解析

    /// 极简的 `--key value` / `--flag` 解析器。
    ///
    /// **已知限制（取舍，不是遗漏）**：
    /// - 不支持 `--flag=value` 写法——它会被当成一个未知键 `flag=value`，静默无效
    ///   （本项目文档一律用空格分隔，如 `--pcm16`）。
    /// - 未知的 `--xxx` 不会被拒绝，只是没有消费者。这样做是为了让 `--log` 这类
    ///   由入口层读取、本层不关心的参数能安全共存。
    struct Args {
        private var values: [String: String] = [:]
        private var flags: Set<String> = []
        var positional: [String] = []

        init(_ raw: [String]) {
            var i = 0
            while i < raw.count {
                let token = raw[i]
                if token.hasPrefix("--") {
                    let key = String(token.dropFirst(2))
                    if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") {
                        values[key] = raw[i + 1]
                        i += 2
                    } else {
                        flags.insert(key)
                        i += 1
                    }
                } else {
                    positional.append(token)
                    i += 1
                }
            }
        }

        func value(_ key: String) -> String? { values[key] }
        func has(_ key: String) -> Bool { flags.contains(key) || values[key] != nil }
        func double(_ key: String) -> Double? { values[key].flatMap(Double.init) }
    }

    static func rootURL(_ a: Args) -> URL {
        if let p = a.value("root") {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        return SessionStore.defaultRoot()
    }

    // MARK: - record

    /// 同时写终端与文件。`open` 启动的 app 没有终端，stdout 全部丢失——
    /// 录制这种长任务必须能留痕，否则出问题只能靠猜。
    struct Logger {
        private let handle: FileHandle?

        init(path: String?) {
            guard let path, !path.isEmpty else { handle = nil; return }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        }

        func log(_ message: String) {
            print(message)
            fflush(stdout)
            if let handle {
                try? handle.write(contentsOf: Data((message + "\n").utf8))
                try? handle.synchronize()
            }
        }

        func close() { try? handle?.close() }
    }

    /// 只由命令行参数决定的录制配置。
    ///
    /// 抽成纯函数是为了**能测**：`runRecord` 要真的去开设备、跑实时回调，单测碰不了；
    /// 但「哪个参数决定哪种格式」是纯逻辑，恰恰必须被钉住——`--f32` 曾经写在文档里
    /// 却根本没被解析，运行时静默按默认格式录，没有任何提示。
    static func recordConfiguration(from a: Args) throws -> DualTrackRecorder.Configuration {
        var config = DualTrackRecorder.Configuration()
        config.preferredInputUID = a.value("device")
        if a.has("no-self-audio") { config.systemAudioExcludesSelf = false }
        if let maxSeconds = a.double("max") { config.maxDuration = maxSeconds }

        // 两个格式参数是互斥的。都给了就是「你到底想要哪个」，报错比任选一个更诚实——
        // 静默取其一，脚本作者永远不会发现自己的参数没生效。
        if a.has("pcm16") && a.has("f32") {
            throw MRError.invalidArgument("--pcm16 与 --f32 不能同时给：一个是 16 位整数，一个是 32 位浮点")
        }
        // 显式指定，**不读偏好**。CLI 的输入是命令行本身——它会写脚本、进计划任务，
        // 行为必须只由参数决定，不能随某台机器上的偏好域漂移。
        if a.has("pcm16") { config.sampleFormat = .pcm16 }
        if a.has("f32") { config.sampleFormat = .float32 }

        // 采样率/声道这一维与位深**是独立的**，所以两组参数不互斥——
        // 「16 位 + 单声道 24 kHz」正是推荐组合，判成互斥会让它没法用一条命令表达。
        if a.has("mono24k") && a.has("fullband") {
            throw MRError.invalidArgument(
                "--mono24k 与 --fullband 不能同时给：一个要把录音降到单声道 24 kHz 省空间，一个要保留源的采样率与声道数")
        }
        if a.has("mono24k") { config.mono24k = true }
        if a.has("fullband") { config.mono24k = false }

        // 降混策略。**不设默认值**——不给参数时留 `nil`，由 `MeetingWorkspace`
        // 那层用偏好兜底。CLI 单独跑时没有 workspace，于是 `nil` 会落到
        // `Configuration.resolvedDownmix` 的 `.firstChannel`。
        // 这一点与上面两个格式参数**故意不同**：它们有「保守」与「激进」两个
        // 方向明确的选项，缺省即「不降」；降混策略的缺省是「实测更安全的那一侧」，
        // 写死在这里而不是走偏好，是为了让 `--help` 里的说明与实际行为同源。
        if let raw = a.value("downmix") {
            guard let strategy = MonoDownmixStrategy(resolving: raw) else {
                let legal = MonoDownmixStrategy.allCases
                    .map(\.rawValue).joined(separator: " | ")
                throw MRError.invalidArgument(
                    "--downmix 的值「\(raw)」不认识。合法值：\(legal)")
            }
            config.downmix = strategy
        }
        return config
    }

    static func runRecord(_ raw: [String]) async throws {
        let a = Args(raw)
        // 标题统一在这里生成：`--title` 只提供前缀，时间序号由 SessionStore 追加。
        // 手工写日期格式是这类「同一件事两处实现」最容易漂的地方。
        let title = SessionStore.autoTitle(base: a.value("title") ?? "")
        let store = SessionStore(root: rootURL(a))
        let log = Logger(path: a.value("log"))

        let config = try Self.recordConfiguration(from: a)

        let recorder = DualTrackRecorder(store: store, configuration: config)

        log.log("正在启动双轨录制…")
        let sessionID = try recorder.start(title: title)
        guard let dir = recorder.sessionDirectoryURL else {
            throw MRError.io(path: store.root.path, reason: "会话目录未创建")
        }

        log.log("  会话：\(sessionID)")
        log.log("  目录：\(dir.path)")
        log.log("  【我】= 麦克风　【对方】= 系统音频")
        // 录之前就说清楚会存成什么。位深只写进 WAV 头，录完才去读文件头才知道
        // 自己是不是少了一半空间——那时候已经不能改了。
        log.log("  存储格式：\(config.sampleFormat?.displayName ?? WAVSampleFormat.float32.displayName)"
                + (config.sampleFormat == .pcm16 ? "（体积约一半）" : "（无损，默认）"))
        // 采样率与声道**只写在 WAV 头里**，录完再去读文件头才知道自己少了一半空间——
        // 那时候已经不能改了。所以与位深同一条纪律：录之前就说清楚。
        // 用 `resolvedMono24k` 而不是 `config.mono24k == true`：默认值的定义只有一处。
        log.log("  采样率与声道："
                + (config.resolvedMono24k
                    ? "单声道 24 kHz（系统音频轨合并声道，体积约再降至 1/3；"
                      + "麦克风若本身就只给 24 kHz 单声道，该轨只省得下位深那一半）"
                    : "保持设备源格式（不降采样、不合并声道）"))

        // 不依赖 runloop —— `CFRunLoopRun` 在没有显式注册 source 时会立刻返回，
        // 实测导致录制只持续了几十毫秒就收尾。
        //
        // 用 continuation 挂起，而不是 `DispatchSemaphore.wait()`：后者在 async 函数里
        // 会**占死协作线程池的一条线程**（Swift 6 直接判为错误）。这里必须真的挂起，
        // 因为等待时长由用户按 Ctrl-C 的那一刻决定，可以是任意久。
        //
        // `gate` 保证恰好 resume 一次：信号与定时器谁先到都算数，后到的丢弃。
        // continuation 被 resume 两次会直接崩溃，所以这道闸门不是保险，是前提。
        let gate = OSAllocatedUnfairLock(initialState: false)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())

        // 扣掉准备阶段已消耗的时间：系统音频 tap 在首次可能要花上秒级，
        // 不扣的话设 16 秒会实际录到 18.8 秒。
        let alreadyUsed = recorder.elapsed
        let stopAfter: TimeInterval?
        if let seconds = a.double("seconds") {
            log.log(String(format: "  目标录制 %.0f 秒（启动已用 %.1f 秒）", seconds, alreadyUsed))
            stopAfter = max(0, seconds - alreadyUsed)
        } else if let maxDuration = config.maxDuration {
            log.log("  最长录制 \(Int(maxDuration)) 秒")
            stopAfter = max(0, maxDuration - alreadyUsed)
        } else {
            log.log("  按 Ctrl-C 停止录制")
            stopAfter = nil
        }

        // `signal(SIGINT, SIG_IGN)` 必须在建 source 之前：否则默认处置会先把进程干掉。
        signal(SIGINT, SIG_IGN)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish: @Sendable () -> Void = {
                let isFirst = gate.withLock { triggered -> Bool in
                    if triggered { return false }
                    triggered = true
                    return true
                }
                guard isFirst else { return }
                continuation.resume()
            }
            signalSource.setEventHandler(handler: finish)
            signalSource.resume()
            if let stopAfter {
                DispatchQueue.global().asyncAfter(deadline: .now() + stopAfter, execute: finish)
            }
        }

        signalSource.cancel()

        log.log("")
        log.log("正在收尾…")
        let result = try recorder.stop()

        log.log("")
        log.log("录制完成")
        log.log("  时长：\(SessionStore.formatDuration(result.drift.tracks.map(\.duration).max() ?? 0))")
        for track in result.drift.tracks {
            let s = track.stats
            let who = track.id == "mic" ? "我" : "对方"
            // `stats` 刻意留**源格式**（漂移要跟采集时钟比），`manifest` 才是**写入格式**。
            // 报告以写入格式为主位——用户此刻关心的是盘上那个文件；而「manifest 记 48k、
            // 文件是 24k」这类错配，正是在这一行露头的地方。
            let written = result.manifest.tracks.first { $0.id == track.id }
            let described = written.map {
                TrackWriteFormat(sampleRate: $0.sampleRate, channels: $0.channels)
                    .describe(sourceSampleRate: s.sampleRate, sourceChannels: s.channels)
            } ?? String(format: "%.0fHz %dch", s.sampleRate, s.channels)
            log.log(String(format: "  [%@] %@  %.1f 秒  %@  %d 帧",
                           who, track.id, s.clockDuration, described,
                           written?.framesWritten ?? s.frames))
        }
        if result.drift.tracks.count > 1 {
            log.log(String(format: "  两轨启动差：%.1f 秒　共同覆盖：%.1f 秒　时长差：%.1f 毫秒",
                           result.drift.startSkew, result.drift.overlapDuration,
                           result.drift.durationSkew * 1000))
        }
        for w in result.warnings { log.log("  ⚠️  \(w)") }
        log.log("  下一步：meeting-recorder transcribe \(result.sessionID)")
        log.close()
    }

    // MARK: - transcribe

    /// 轨 ID 的别名 → 规范 id。
    ///
    /// 收「我 / 对方 / me」是因为中文界面里用户脑子里的是「我」和「对方」，
    /// 而 `--track 我` 打不出来（终端里中文常常是麻烦的输入源），
    /// 所以至少要接受英文与拼音。**不做前缀匹配**：`s` 到底指 system 还是别的，
    /// 猜错的方向不对称——猜成 system 会转错一条轨，而用户以为转的是自己。
    static let trackIDAliases: [String: String] = [
        "mic": "mic", "me": "mic", "我": "mic",
        "system": "system", "对方": "system",
    ]

    /// `transcribe --track <id>` 的判据。**抽成纯函数**，
    /// 因为 `runTranscribe` 里那一段会真调引擎，单测碰不到。
    ///
    /// 两条错误路径各有各的理由，缺一条都会变成静默的行为：
    ///
    /// - **缺值**：`Args` 把 `--track` 单独出现记成 flag，`value("track")` 返回 nil，
    ///   与「压根没写」读法完全一样。静默走整场转写的话，用户会拿到一份双轨稿，
    ///   而他以为自己只转了一条——症状是「转写花了 3 倍时间」，原因查不出来。
    /// - **不认识的轨**：同理，`--track mci`（手滑）必须报错。
    static func trackFilterConfiguration(
        from a: Args, into config: inout SessionTranscriber.Configuration
    ) throws {
        if a.has("track"), a.value("track") == nil {
            throw MRError.invalidArgument(
                "--track 后面缺轨 ID。可选：mic（我）| system（对方）。"
                + "要转整场（两条轨都转，并做跨轨去重）就不要加这个参数。")
        }
        guard let raw = a.value("track") else { return }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let id = Self.trackIDAliases[key] else {
            throw MRError.invalidArgument(
                "轨 ID「\(raw)」不认识。可选：mic（我）| system（对方）。"
                + "（写错轨 ID 若被静默当成「整场」，你会拿到一份双轨稿，"
                + "却以为自己只转了一条。）")
        }
        config.trackFilter = [id]
    }

    /// 单轨转写时打在终端上的说明。**抽成返回值**，
    /// 这样「单轨不覆盖整场稿」这条最要紧的事实可以被断言，
    /// 而不是只能靠人眼扫过输出。
    static func singleTrackBanner(trackIDs: [String]) -> [String] {
        let ids = trackIDs.sorted().joined(separator: "、")
        let stem = SessionTranscriber.singleTrackFileStem(trackIDs: trackIDs)
        return [
            "转写中（语言来自 --lang，引擎来自全局设置，**只转写 \(ids) 这一条轨**）…",
            "  ⓘ 单轨稿写到 \(stem).md；整场稿 \(SessionStore.transcriptMarkdownName) "
                + "不会被改动，也不会被标记为「已转写」。",
        ]
    }

    static func runTranscribe(_ raw: [String]) async throws {
        let a = Args(raw)
        guard let target = a.positional.first else {
            throw MRError.io(path: "-", reason: "用法：transcribe <会话ID 或 目录路径>")
        }
        let store = SessionStore(root: rootURL(a))

        // 明确拒绝未实现的能力，而不是"提示一句然后照旧跑"——
        // 悄悄降级会让使用者以为拿到了 whisper 的结果。
        // 「用哪个引擎」现在是**全局配置项**（`config set engine <名字>`），不是转写时的开关，
        // 所以这里不接受 `--whisper`；whisper 本身也从未实现。
        if a.has("whisper") {
            throw MRError.transcription(
                reason: "whisper 引擎从未实现。引擎现在是全局配置项：用 `config set engine <apple|sensevoice>` "
                + "选择，默认 apple-speech。")
        }

        // 支持传会话 ID，也支持直接传目录路径。会话 ID 就是目录名。
        let dir: URL = target.contains("/")
            ? URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            : store.directory(forSessionID: target)
        let sessionID = dir.lastPathComponent

        if let manifest = try? store.loadManifest(sessionDirectory: dir),
           manifest.state == .recording {
            print("⚠️  该会话状态为「录制中」，先执行崩溃恢复再转写")
        }

        var config = SessionTranscriber.Configuration()
        config.language = a.value("lang") ?? "zh-CN"
        // 引擎来自**全局配置**，不是 CLI 参数：用户在一处改（`config set engine`），
        // 之后每场转写都听它的，不在每场命令里勾选。
        config.engine = RecorderPreferences().transcriptionEngine
        // 分段默认**关闭**——实测单段直转对 2 小时音频仍只要 56 秒、
        // 本进程内存恒定 24 MB（引擎在独立 XPC 进程里流式处理），
        // 而分段要多花 5 倍时间、16 倍内存。分段只在需要局部失败隔离时才开。
        if a.has("segment") { config.segmentThreshold = 600 }
        if let t = a.double("segment-threshold") { config.segmentThreshold = t }
        if a.has("no-segment") { config.segmentThreshold = .infinity }
        if let m = a.double("max-segment") { config.maxSegment = m }
        if a.has("keep-slices") { config.keepSlices = true }

        // `--track <id>`：只转写指定的那条轨。判据抽成纯函数，见 `trackFilterConfiguration`。
        try Self.trackFilterConfiguration(from: a, into: &config)

        let segmentLabel = config.segmentThreshold.isFinite
            ? String(format: "超过 %.0f 秒自动分段", config.segmentThreshold)
            : "关闭（单段直转）"
        if let filter = config.trackFilter, !filter.isEmpty {
            for line in Self.singleTrackBanner(trackIDs: Array(filter)) { print(line) }
        } else {
            print("转写中（语言 \(config.language)，引擎 \(config.engine.driverEngineID)，分段：\(segmentLabel)）…")
        }
        if config.engine.isOptIn {
            print("  ⓘ 已显式启用 opt-in 引擎 \(config.engine.displayName)；"
                + "退出默认请执行 `config set engine apple`。")
        }

        // 编排本身在 SessionTranscriber 里，**GUI 用的是同一份代码**。
        // 这里只负责把事件打成终端文字——任何时间轴规则都不在这一层。
        let transcriber = SessionTranscriber(store: store, configuration: config)
        let outcome = try await transcriber.transcribe(sessionID: sessionID) { event in
            switch event {
            case .engineReady:
                print("  时间基准已建立（各轨按 hostTime 对齐）")
            case let .trackStarted(id, displayName, _, _):
                print("  → \(id)（\(displayName)）…")
            case let .segmentStarted(_, index, total, start, end):
                print(String(format: "     第 %d/%d 段  %.0f–%.0f 秒…", index, total, start, end))
            case let .trackFinished(_, _, segmentCount, elapsed, notes, failedSegments):
                for note in notes { print("     · \(note)") }
                if failedSegments > 0 {
                    print("     ⚠️  \(failedSegments) 段转写失败，该轨文稿可能不完整")
                }
                print(String(format: "     得到 %d 段（%.1f 秒）", segmentCount, elapsed))
            case let .trackFailed(_, displayName, message):
                print("     ❌ \(displayName) 轨失败：\(message)")
            case let .trackSkipped(id, reason):
                print("  ⏭  跳过 \(id)：\(reason)")
            case let .aligned(trackID, offset):
                print(String(format: "     [%@] 已按 hostTime 平移 %.2f 秒对齐会话时间轴",
                             trackID, offset))
            case .finished:
                break
            }
        }

        for w in outcome.warnings { print("  ⚠️  \(w)") }

        print("""
        
        转写完成
          段落：\(outcome.document.segments.count)
          文稿：\(outcome.markdownURL.path)
          结构：\(outcome.jsonURL.path)
        """)

        // 链式纪要：转写完成后若显式要求，立即生成纪要（同一命令一气呵成）。
        //
        // **单轨下不生成。** `MinutesService` 读的是整场稿 `transcript.json`，
        // 而单轨转写既没写它、也没改 manifest 状态——于是这里生成的纪要
        // 会来自**上一次**的整场稿，而用户以为它基于刚才那条轨。
        // 那是一份看起来完全正常、内容却来自另一份稿子的纪要。
        if a.has("minutes") {
            if let filter = config.trackFilter, !filter.isEmpty {
                print("  ⚠️  单轨转写不生成纪要：纪要基于整场转写稿，"
                    + "而这次只转了 \(filter.sorted().joined(separator: "、"))。"
                    + "要生成纪要请先跑整场转写（不加 --track）。")
            } else {
                try await generateMinutesIfRequested(store: store, sessionID: sessionID)
            }
        }
    }

    // MARK: - minutes

    /// 为一场已转写的会议单独生成纪要。
    static func runMinutes(_ raw: [String]) async throws {
        let a = Args(raw)
        guard let target = a.positional.first else {
            throw MRError.io(path: "-", reason: "用法：minutes <会话ID 或 目录路径>")
        }
        let store = SessionStore(root: rootURL(a))
        let dir: URL = target.contains("/")
            ? URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            : store.directory(forSessionID: target)
        let sessionID = dir.lastPathComponent

        let outcome = try await MinutesService(store: store)
            .generate(sessionID: sessionID, generator: try Self.makeMinutesGenerator())
        reportMinutesOutcome(outcome)
    }

    /// 转写后链式生成纪要的共用逻辑。
    static func generateMinutesIfRequested(store: SessionStore, sessionID: String) async throws {
        let outcome = try await MinutesService(store: store)
            .generate(sessionID: sessionID, generator: try Self.makeMinutesGenerator())
        reportMinutesOutcome(outcome)
    }

    /// 按偏好选一个纪要生成器。
    ///
    /// 选型只有这一个位置（`MinutesGeneratorResolver`），CLI 与 GUI 共用。
    /// 云端三件套没配齐时在这里**抛错**——发生在写任何文件之前，
    /// 错误文案带上要敲的命令。绝不静默回退本地模型：用户选了云端，
    /// 拿到本地产出的纪要，是署名不同的谎报（与 SenseVoice 资产缺失时
    /// 「写文件前明确报错」同一条纪律）。
    ///
    /// 偏好是**注入的参数**而不是内部 `RecorderPreferences()`：测试必须能拿
    /// 自己的 suite 验证「配不齐时抛什么」，而 `.standard` 是跑测试这个进程的
    /// 真实偏好域——往里写会把用户的真设置改掉。
    static func makeMinutesGenerator(
        preferences: RecorderPreferences = RecorderPreferences()
    ) throws -> any MinutesGenerator {
        switch MinutesGeneratorResolver.resolve(preferences: preferences) {
        case let .ready(generator):
            return generator
        case let .blocked(reason):
            throw MRError.invalidArgument(reason)
        }
    }

    static func reportMinutesOutcome(_ outcome: MinutesService.Outcome) {
        if outcome.result.generatedByModel {
            print("✅ 纪要已生成（\(outcome.result.blocks.count) 段，\(outcome.result.generatorName)）")
        } else {
            print("⚠️  本地纪要模型不可用，已生成降级纪要（仅原稿，未生成摘要/待办）。")
            print("    在开启了 Apple Intelligence 的机器上重新运行即可自动启用。")
            print("    或配置云端模型 API：config set minutes api（详见 help minutes）。")
        }
        print("""
          纪要：\(outcome.markdownURL.path)
          结构：\(outcome.jsonURL.path)
        """)
    }

    // MARK: - prune（保留策略）

    /// `mr prune` 的全部参数决策。抽成纯函数以便单测——理由与
    /// `transcodeConfiguration` 完全一样：`runPrune` 会**删用户的录音**，
    /// 单测碰不了，但「哪个参数决定哪种行为」必须被钉住。
    struct PruneConfiguration: Equatable {
        /// `--days N` 的一次性覆盖。为 nil 表示用偏好里的档位。
        var daysOverride: Int?
        var dryRun = false
        var yes = false
        var includeUntranscribed = false
    }

    static func pruneConfiguration(from a: Args) throws -> PruneConfiguration {
        var config = PruneConfiguration()
        // `Args` 把「后面没有值」的 `--days` 记成**flag**，于是 `value("days")`
        // 返回 nil——与「用户压根没写 `--days`」读法完全一样。
        // 对一条会删数据的命令，这种静默降级比报错糟得多：
        // 用户以为在按某个天数清，实际走的是偏好里的档位（可能是另一个数）。
        if a.has("days"), a.value("days") == nil {
            throw MRError.invalidArgument(
                "--days 后面缺天数。合法值："
                + RetentionPolicy.selectableDayCounts.map(String.init).joined(separator: " | "))
        }
        if let raw = a.value("days") {
            // 只接受四个产品档位，不接受任意天数——与 `RetentionPolicy.selectableDayCounts`
            // 同一口径。`--days 60` 静默跑起来的话，用户以为在试一个数，
            // 实际上界面上永远不会有「60 天」这一档，两边对不上。
            guard let n = Int(raw), RetentionPolicy.selectableDayCounts.contains(n) else {
                let legal = RetentionPolicy.selectableDayCounts
                    .map(String.init).joined(separator: " | ")
                throw MRError.invalidArgument(
                    "--days 的值「\(raw)」不认识。合法值：\(legal)"
                    + "（保留策略只有这几档，不接受任意天数：每一档都要在界面上写清代价说明。）")
            }
            config.daysOverride = n
        }
        if a.has("dry-run") || a.has("plan") { config.dryRun = true }
        if a.has("yes") || a.has("y") { config.yes = true }
        if a.has("include-untranscribed") { config.includeUntranscribed = true }
        return config
    }

    /// 清理前的说明文本。**抽成纯函数**是为了让「默认不删东西」这件事能被断言——
    /// 它是这一整段最重要的行为，而它只体现在输出里。
    static func pruneHeaderText(policy: RetentionPolicy,
                                config: PruneConfiguration,
                                executing: Bool) -> String {
        var lines: [String] = []
        lines.append("保留档位：\(policy.displayName)"
            + (config.daysOverride != nil ? "（--days 覆盖，不改变设置）" : "（来自设置）"))
        lines.append("  \(policy.menuHelp)")
        if !executing {
            lines.append("模式：**预演**，一个文件都不会被删。先看账，确认无误再加 --yes。")
        } else {
            lines.append("模式：**执行**。删除走废纸篓，不是直接抹掉——清空废纸篓后就没有了。")
        }
        lines.append("范围：保留 manifest 与转写稿，只删 manifest 登记过的音轨文件。")
        lines.append("跳过：没转写过的会议、正在录的、manifest 读不出来的、"
            + "以及目录里有合并导出文件的。")
        return lines.joined(separator: "\n")
    }

    /// 定出 `prune` 这次用哪个档位。**抽成纯函数，且刻意不写偏好。**
    ///
    /// - Parameter prefs: 注入的偏好实例，便于单测断言「没有被改过」。
    /// - Throws: 偏好里是不认识的档位时抛出，**调用方必须因此拒绝执行**
    ///   （一个文件都不能删）。
    static func resolvePrunePolicy(
        prefs: RecorderPreferences,
        config: PruneConfiguration
    ) throws -> RetentionPolicy {
        // 坏键必须在这里就停住，**不能**当成关闭。
        // 与 `retentionPolicy` 返回可选是同一条纪律：回退到 `.off` 会让用户以为
        // 「我设了一个月」而实际什么都没删；回退到 30 天更糟——那会直接开始删。
        if config.daysOverride == nil, prefs.hasUnrecognizedRetentionPolicy() {
            let legal = RetentionPolicy.selectableCases
                .map(\.rawValue).joined(separator: " | ")
            throw MRError.invalidArgument(
                "设置里的保留档位不是认识的值，**已拒绝执行**（一个文件都没删）。"
                + "请先 `config set retention <值>`。合法值：\(legal)")
        }
        guard let override = config.daysOverride else { return prefs.resolvedRetentionPolicy() }

        // ⚠️ **这一支绝不落盘。** `--days` 是一次性覆盖：
        // 「我试着清一次」不该把长期设置也改掉。
        // 有测试钉住「调用这个函数之后偏好一个字节都没变」。
        return .days(override)
    }

    static func runPrune(_ raw: [String]) throws {
        let a = Args(raw)
        let config = try Self.pruneConfiguration(from: a)
        let prefs = RecorderPreferences()
        let store = SessionStore(root: rootURL(a))

        let policy = try Self.resolvePrunePolicy(prefs: prefs, config: config)

        guard policy.isEnabled else {
            let dayList = RetentionPolicy.selectableDayCounts.map(String.init)
            throw MRError.invalidArgument(
                "保留档位是「\(policy.displayName)」，不会删任何东西。"
                + "要按某个天数清一次，用 `prune --days <\(dayList.joined(separator: "|"))>`；"
                + "要长期生效，用 `config set retention <\(dayList.joined(separator: "|"))>`。")
        }

        // 没有 `--yes` 就只预演。**不是**默认执行：本命令删的是不可再生的数据，
        // 而 `prune` 是个短到会顺手敲的命令。
        let executing = config.yes && !config.dryRun
        let cleaner = SessionRetentionCleaner(store: store)
        let plan = try cleaner.plan(policy: policy,
                                    includeUntranscribed: config.includeUntranscribed)
        let outcome = try cleaner.run(policy: policy,
                                     includeUntranscribed: config.includeUntranscribed,
                                     dryRun: !executing)

        print(pruneHeaderText(policy: policy, config: config, executing: executing))
        print("")
        for note in outcome.notes { print("· \(note)") }
        print("")

        // 「还没压过」只存在于 plan 里（Outcome 是执行结果，不带格式信息）。
        // 在这里建索引给逐行输出查，避免为了显示一句提醒重跑一次 plan。
        let uncompressedByID = Dictionary(
            plan.uncompressedPrunable.map { ($0.sessionID, $0) },
            uniquingKeysWith: { a, _ in a })

        for s in outcome.sessions {
            if let reason = s.skippedReason {
                print("⏭\(s.title)（\(s.sessionID)）：\(reason)")
                continue
            }
            if let failed = s.failed {
                print("❌ \(s.title)（\(s.sessionID)）：\(failed)")
                continue
            }
            let verb = executing ? "已移入废纸篓" : "将会移入废纸篓"
            print("🗑 \(s.title)（\(s.sessionID)）："
                + "\(s.deletedFiles.joined(separator: "、")) — \(verb)，"
                + "约 \(Self.humanSize(s.freedBytes))")
            // 顺序提醒**逐场**给，而不是只在末尾汇总一句。
            // 汇总的话用户已经读到确认那一步了，逐场才看得出「哪几场顺序反了」。
            if let sp = uncompressedByID[s.sessionID],
               let ratio = sp.potentialCompressionRatio, ratio > 1.05 {
                // 按这一场自己算多腾多少，不引用全局汇总——
                // 汇总数里混着别的场，用户对不上「这一行说的多少」。
                let extra = Int(Double(sp.reclaimableBytes) - Double(sp.reclaimableBytes) / ratio)
                print("   ⚠️  这场还没压过：先 `transcode --preset b-tier` 还能再省约 "
                    + String(format: "%.1f", ratio)
                    + " 倍（压完再清，多腾 \(Self.humanSize(extra))）。删掉之后就压不成了。")
            }
        }

        print("")
        if plan.sessionCount == 0 {
            print("没有符合条件的会议（\(policy.displayName)）。")
            return
        }
        print("共\(executing ? "" : "将")清理 \(plan.sessionCount) 场、"
            + "\(plan.prunable.reduce(0) { $0 + $1.filesToDelete.count }) 个音频文件，"
            + "约 \(Self.humanSize(plan.reclaimableBytes))。")
        if executing {
            print("转写稿与 manifest 全部保留，列表里这几场会显示为「0 轨」。")
        } else {
            print("加 --yes 才会真的删。")
        }
        // 汇总一条**可执行**的顺序建议（只给数，不重复逐场的话）。
        let extra = plan.additionalBytesIfCompressedFirst
        if !executing, extra > 0 {
            print("")
            print("顺序建议：这 \(plan.uncompressedPrunable.count) 场还没压过。"
                + "先 `transcode --preset b-tier --all` 再清理，能多腾约 "
                + "\(Self.humanSize(extra))——"
                + "现在清掉的是原始体积，删完就压不成了。")
        }
        if !outcome.failed.isEmpty {
            print("⚠️  \(outcome.failed.count) 场没成功，已完成的不受影响。")
        }
    }

    static func humanSize(_ bytes: Int) -> String {
        let mib = Double(bytes) / 1_048_576
        return mib >= 1024
            ? String(format: "%.2f GiB", mib / 1024)
            : String(format: "%.1f MiB", mib)
    }

    // MARK: - transcode

    /// `mr transcode` 的全部参数决策。抽成纯函数以便单测——理由与
    /// `recordConfiguration` 完全一样：`runTranscode` 真的会去改写用户盘上的音频，
    /// 单测碰不了，但「哪个参数决定哪种行为」必须被钉住。
    ///
    /// 尤其 `--to` 拼错这件事：CLI 的 `Args` **不拒绝未知 `--xxx`**，
    /// 所以 `--to pcm-16` 会静默走默认值——用户以为转了 16 位，实际按 24 kHz 单声道转了。
    /// 这里显式校验并把合法值列出来。
    struct TranscodeConfiguration: Equatable {
        var preset: AudioTranscoder.Preset = .bTier
        var downmix: MonoDownmixStrategy = .firstChannel
        var dryRun = false
        var keepOriginal = false
        var allSessions = false
    }

    static func transcodeConfiguration(from a: Args) throws -> TranscodeConfiguration {
        var config = TranscodeConfiguration()
        if let raw = a.value("to") {
            // 接受三套写法：预设名（b / bTier）、录制参数同名写法（--to mono24k 之类不走这里，
            // 但 `--to pcm16` 与 `record --pcm16` 对齐，用户不需要记两套词）。
            let normalized = raw.lowercased()
            switch normalized {
            case "b", "btier", "b-tier", "24k", "mono24k":
                config.preset = .bTier
            case "pcm16", "a", "a-tier", "16":
                config.preset = .pcm16
            case "f32", "f32lossless", "lossless32", "lossless", "32":
                config.preset = .lossless32
            default:
                let legal = AudioTranscoder.Preset.allCases
                    .map(\.rawValue).joined(separator: " | ")
                throw MRError.invalidArgument(
                    "--to 的值「\(raw)」不认识。合法值：\(legal)。"
                    + "（也接受简写 b / pcm16 / f32。不认识的值会静默走默认档，"
                    + "所以这里直接报错而不是猜一个。）")
            }
        }
        if a.has("dry-run") || a.has("plan") { config.dryRun = true }
        if a.has("keep-original") { config.keepOriginal = true }
        // `--all` 走整库，所以 `keepOriginal` 在批量下必须拒绝：
        // 逐场留备份等于峰值磁盘翻倍，正是 E 档要解决的问题本身。
        if a.has("all") {
            config.allSessions = true
            if config.keepOriginal {
                throw MRError.invalidArgument(
                    "--all 不能与 --keep-original 同时给：整库留备份会让峰值磁盘占用翻倍，"
                    + "正好抵消掉这次转码要省的体积。要留备份就一场一场来。")
            }
            // `--all <场次>` 会被 `Args` **吞成 `--all` 的值**，positional 是空的。
            // 所以这里不能查 positional——那样这条检查永远不触发，
            // `--all 某一场` 会静默变成「转全部」，正是要防的那类坑。
            // 判据是「`--all` 后面跟了非 `--` token」。
            if let swallowed = a.value("all") {
                throw MRError.invalidArgument(
                    "--all 已经表示「全部会议」，它后面不该再跟值（读到的是「\(swallowed)」）。"
                    + "要转指定的一场，去掉 --all 直接写会话 ID 或目录路径。")
            }
        }
        if let raw = a.value("downmix") {
            switch raw.lowercased() {
            case "average", "avg", "平均": config.downmix = .average
            case "firstchannel", "first-channel", "first", "左声道":
                config.downmix = .firstChannel
            default:
                throw MRError.invalidArgument(
                    "--downmix 的值「\(raw)」不认识。合法值：average | first-channel")
            }
        }
        return config
    }

    /// 转码前的说明文本。**抽成纯函数**是为了让「dry-run 有没有明说一个字节都不写」
    /// 「降混在当前档位下是否真的生效」这两件事可以被断言，而不是只能靠人眼扫输出。
    static func transcodeHeaderText(_ config: TranscodeConfiguration) -> String {
        var lines: [String] = []
        lines.append("目标档位：\(config.preset.displayName)")
        lines.append("  \(config.preset.hint)")
        // 降混策略必须带上「在这一档下会不会真的生效」。
        // `--to pcm16` 保留源声道数 → 根本不进降混，此时用户以为系统轨被处理过了。
        let downmixApplies = config.preset != .pcm16 && config.preset != .lossless32
        lines.append("降混策略：\(config.downmix.displayName)"
            + (config.downmix == .average ? "（默认）" : "（避开反相抵消，但会丢掉其余声道）")
            + (downmixApplies ? "" : "——本档保留源声道数，该策略不会真正生效"))
        if config.dryRun { lines.append("模式：--dry-run，**一个字节都不会写**") }
        if config.keepOriginal { lines.append("备份：原文件保留为 .<文件名>.orig") }
        if config.allSessions { lines.append("范围：存储根目录下的**全部**会议") }
        return lines.joined(separator: "\n")
    }

    static func runTranscode(_ raw: [String]) throws {
        let a = Args(raw)
        let config = try Self.transcodeConfiguration(from: a)
        let store = SessionStore(root: rootURL(a))
        let transcoder = SessionAudioTranscoder(store: store)

        let ids: [String]
        if config.allSessions {
            ids = try store.listSessionIDs()
            guard !ids.isEmpty else {
                print("存储根目录下没有会议：\(store.root.path)")
                return
            }
            // 批量是**改写用户全部历史录音**的操作，dry-run 必须先跑。
            // 不做成「默认 dry-run」是因为那会让批量脚本永远跑不动；
            // 也不做成「必须 --yes」是因为 --dry-run 已经是显式动作了。
            if !config.dryRun {
                print("⚠️  即将改写 \(ids.count) 场会议的音频文件（原文件在校验通过后被替换）。")
                print("    先跑一次 --dry-run 看账，确认无误再执行。")
            }
        } else {
            guard let target = a.positional.first else {
                throw MRError.io(path: "-", reason:
                    "用法：transcode <会话ID 或 目录路径> [--to b|pcm16|f32] [--dry-run]")
            }
            ids = [target.contains("/")
                ? URL(fileURLWithPath: (target as NSString).expandingTildeInPath).lastPathComponent
                : target]
        }

        print(transcodeHeaderText(config))
        print("")

        var failedSessions: [String] = []
        for id in ids {
            do {
                let outcome = try transcoder.run(sessionID: id, preset: config.preset,
                                                downmix: config.downmix,
                                                dryRun: config.dryRun,
                                                keepOriginal: config.keepOriginal)
                reportTranscodeOutcome(outcome, dryRun: config.dryRun)
                if !outcome.failed.isEmpty { failedSessions.append(id) }
            } catch {
                // 一场失败不中断整批：批量迁移里最常见的失败是某一场缺 manifest，
                // 让它带走后面 21 场才是真的糟糕。
                let message = "❌ \(id)：\(error.localizedDescription)"
                FileHandle.standardError.write(Data((message + "\n").utf8))
                failedSessions.append(id)
            }
        }

        if ids.count > 1 || config.allSessions {
            print("")
            if failedSessions.isEmpty {
                print(config.dryRun
                    ? "全部 \(ids.count) 场已盘点完毕，未做任何改动。"
                    : "全部 \(ids.count) 场处理完毕。")
            } else {
                print("⚠️  \(failedSessions.count)/\(ids.count) 场有问题："
                    + failedSessions.joined(separator: "、"))
                if !config.dryRun {
                    print("    已完成的场次**不受影响**——每条轨都是各自校验通过后才替换的。")
                }
            }
        }
    }

    /// 单场转码的汇报。dry-run 与实跑共用同一份数据来源（`Outcome`），
    /// 只是措辞不同——两边若各算一遍，账就可能对不上，而这正是要展示给人看的东西。
    static func reportTranscodeOutcome(_ outcome: SessionAudioTranscoder.Outcome,
                                       dryRun: Bool) {
        print("【\(outcome.sessionID)】")
        for note in outcome.notes { print("  · \(note)") }

        var srcTotal = 0, dstTotal = 0
        for t in outcome.tracks {
            guard let r = t.result else {
                print(String(format: "  %@ %@", t.trackID, t.reason ?? t.failed ?? "已跳过"))
                continue
            }
            srcTotal += r.sourceBytes
            dstTotal += r.targetBytes
            let saved = r.sourceBytes - r.targetBytes
            let pct = r.sourceBytes > 0 ? Double(saved) / Double(r.sourceBytes) * 100 : 0
            print(String(format: "  %@ %@ → %@", t.trackID,
                         Self.describeFormat(r.sourceSampleRate, r.sourceChannels, r.sourceFormat),
                         r.target.shortName))
            print(String(format: "      %@ → %@（省 %.0f%%，%.1f → %.1f MiB）",
                         Self.mib(r.sourceBytes), Self.mib(r.targetBytes), pct,
                         Double(r.sourceBytes) / 1048576, Double(r.targetBytes) / 1048576))
            if t.backupPath != nil { print("      原文件已备份为 \(t.backupPath!)") }
        }
        if !outcome.failed.isEmpty {
            for f in outcome.failed {
                print("  ❌ \(f.trackID)：\(f.failed ?? "未知原因")")
            }
        }
        if srcTotal > 0 {
            let pct = Double(srcTotal - dstTotal) / Double(srcTotal) * 100
            print(String(format: "  合计 %@ → %@（省 %.0f%%）",
                         Self.mib(srcTotal), Self.mib(dstTotal), pct))
        }
        if dryRun {
            print("  （dry-run，未改动任何文件）")
        } else if outcome.isCompleteSuccess {
            print("  ✅ 转码完成" + (outcome.manifestUpdated ? "，manifest 已同步" : ""))
        }
        print("")
    }

    static func describeFormat(_ sampleRate: Double, _ channels: Int,
                               _ format: WAVSampleFormat) -> String {
        "\(format.shortDisplayName) · \(Int(sampleRate)) Hz · "
            + (channels == 1 ? "单声道" : "\(channels) 声道")
    }

    static func mib(_ bytes: Int) -> String {
        String(format: "%.1f MiB", Double(bytes) / 1048576)
    }

    // MARK: - merge

    /// `mr merge` 的全部参数决策。抽成纯函数以便单测，理由与
    /// `transcodeConfiguration` 完全一致：真正去改写/写盘的动作单测碰不了，
    /// 但「哪个参数决定哪种行为」必须被钉住。
    struct MergeConfiguration: Equatable {
        var mode: AudioTrackMerger.Mode = .stereoSplit
        var format: AudioTrackMerger.OutputFormat = .pcm16
        var overwrite = false
        /// 显式指定输出路径（GUI 与脚本用）
        var outputPath: String?
    }

    static func mergeConfiguration(from a: Args) throws -> MergeConfiguration {
        var config = MergeConfiguration()
        // `--mono` / `--stereo` 两个显式开关。与 transcode 的互斥报错同一纪律：
        // 都给了就是「你到底想要哪个」，静默取其一则脚本作者永远发现不了。
        if a.has("mono") && a.has("stereo") {
            throw MRError.invalidArgument("--mono 与 --stereo 不能同时给")
        }
        if a.has("mono") { config.mode = .monoMix }
        if a.has("stereo") { config.mode = .stereoSplit }
        // `--mode <值>` 是上面那对开关的另一种写法
        if let raw = a.value("mode") {
            switch raw.lowercased() {
            case "stereo", "split", "stereosplit": config.mode = .stereoSplit
            case "mono", "mix", "monomix": config.mode = .monoMix
            default:
                throw MRError.invalidArgument(
                    "--mode 的值「\(raw)」不认识。合法值：stereo | mono")
            }
        }
        if let raw = a.value("to") {
            switch raw.lowercased() {
            case "pcm16", "16", "16bit": config.format = .pcm16
            case "f32", "float32", "32", "lossless": config.format = .float32
            default:
                throw MRError.invalidArgument(
                    "--to 的值「\(raw)」不认识。合法值：pcm16 | f32"
                    + "（这是位深，与 --mono/--stereo 说的声道数是两件事，可以叠加）")
            }
        }
        if a.has("overwrite") { config.overwrite = true }
        config.outputPath = a.value("out")
        return config
    }

    /// 每条轨的平均电平行。抽成纯函数，因为这里曾有一个**只在静音轨上出现**的缺陷。
    ///
    /// 原写法：
    /// ```swift
    /// String(format: "    %@ 平均电平 %.5f%s", name, rms,
    ///          rms < 阈值 ? "  ← 全静音" : "")
    /// ```
    /// 三元的两个分支长度不同，编译器为两侧分别生成临时字符串，而**空串字面量
    /// 没有自己的存储** —— `%s` 于是读到已被复用的内存。实测 mic RMS 为 0 时
    /// 输出成 `mic 平均电平 0.00000厣悯`，尾部多出两个乱码汉字。
    ///
    /// 两条纪律：
    /// 1. 三元两侧都显式 `String`，让两边各有确定的存储；
    /// 2. 占位符用 `%@` 而不是 `%s`（后者收 C 字符串指针，传 Swift String 本就不稳）。
    ///
    /// 顺带显式 `Double(rms)`：`%.5f` 要的是 Double，让 Float 在可变参数里隐式提升
    /// 同样不是稳妥写法。
    static func trackLevelLine(name: String, rms: Float) -> String {
        let mark: String = rms < AudioTrackMerger.Result.silenceRMSThreshold
            ? "  ← 全静音" : ""
        return String(format: "    %@ 平均电平 %.5f%@", name, Double(rms), mark)
    }

    /// 合并前的说明文本。抽成纯函数，让「drain 会多写多少帧」这类话可被断言。
    static func mergeHeaderText(_ config: MergeConfiguration,
                                plan: SessionAudioExporter.Plan) -> String {
        var lines: [String] = []
        lines.append("合并方式：\(plan.mode.displayName)")
        lines.append("  \(plan.mode.hint)")
        lines.append("输出格式：\(plan.format.sampleFormat.displayName)"
            + " · \(Int(plan.outputSampleRate)) Hz · "
            + (plan.outputChannels == 1 ? "单声道" : "\(plan.outputChannels) 声道"))
        if plan.outputSampleRate < (plan.inputs.map(\.header.sampleRate).max() ?? 0) {
            let rates = plan.inputs
                .map { "\($0.label)=\(Int($0.header.sampleRate))Hz" }
                .joined(separator: " ")
            lines.append("  采样率取各轨最小值（\(rates) → \(Int(plan.outputSampleRate))Hz），**不升采样**。")
        }
        lines.append("将写：\(plan.destination.lastPathComponent)")
        lines.append(String(format: "  预计 %.1f MiB（各轨原始合计 %.1f MiB）",
                             Double(plan.estimatedBytes) / 1048576,
                             Double(plan.sourceBytes) / 1048576))
        if !plan.inputs.isEmpty {
            lines.append("参与合并的轨：")
            for input in plan.inputs {
                lines.append(String(format: "  %@  %@  %.3fs",
                                    input.label,
                                    Self.describeFormat(input.header.sampleRate,
                                                        input.header.channels,
                                                        input.format),
                                    input.header.duration))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func runMerge(_ raw: [String]) throws {
        let a = Args(raw)
        let config = try Self.mergeConfiguration(from: a)
        let store = SessionStore(root: rootURL(a))
        guard let target = a.positional.first else {
            throw MRError.io(path: "-", reason:
                "用法：merge <会话ID 或 目录路径> [--stereo|--mono] [--to pcm16|f32] [--out <路径>]")
        }
        let dir: URL = target.contains("/")
            ? URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            : store.directory(forSessionID: target)
        let sessionID = dir.lastPathComponent

        let exporter = SessionAudioExporter(store: store)
        let override: URL? = config.outputPath.map {
            URL(fileURLWithPath: (($0 as NSString).expandingTildeInPath))
        }
        let plan = try exporter.plan(sessionID: sessionID, mode: config.mode,
                                     format: config.format, destination: override)
        print(mergeHeaderText(config, plan: plan))
        print("")

        if plan.inputs.count < 2 {
            throw MRError.invalidArgument(
                "\(sessionID) 只有 \(plan.inputs.count) 条可用音轨，合并没有意义。"
                + "合并是把两条并成一条；只有一条时直接用原文件就好。")
        }
        if !plan.missingTracks.isEmpty {
            throw MRError.io(path: dir.path, reason:
                "以下音轨的文件不在盘上：\(plan.missingTracks.joined(separator: "、"))。"
                + "缺轨合并出来的文件会让人以为对方那一路没说话。")
        }

        let outcome = try exporter.merge(sessionID: sessionID, mode: config.mode,
                                         format: config.format, destination: override,
                                         overwrite: config.overwrite)
        for note in outcome.notes { print("  · \(note)") }
        if let r = outcome.result {
            print(String(format: "  %d 帧 · %.1f 秒 · 峰值 %.3f",
                         r.framesWritten, r.duration, r.peakAmplitude))
            for (name, rms) in zip(r.labels, r.perTrackRMS) {
                print(MeetingRecorderCLI.trackLevelLine(name: name, rms: rms))
            }
        }
        print("")
        print("已导出：\(outcome.destination.path)")
        print("提示：合并产物**不是**一条音轨，没有写进 manifest；删掉它不影响这场会议。")
    }

    // MARK: - list

    static func runList(_ raw: [String]) throws {
        let a = Args(raw)
        let store = SessionStore(root: rootURL(a))
        let ids = try store.listSessionIDs()

        if ids.isEmpty {
            print("还没有任何会议记录。目录：\(store.root.path)")
            return
        }
        print("共 \(ids.count) 场会议（目录：\(store.root.path)）\n")
        for id in ids {
            do {
                let m = try store.loadManifest(forSessionID: id)
                // **把「盘上真的有哪些轨」一起传进去。** manifest 记的是
                //「当初录了什么」，清理之后两者会不一致——只按 manifest 显示的话，
                // 用户会看到一列像模像样的音轨而盘上一个都没有。
                let dir = store.directory(forSessionID: id)
                let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                var line = SessionStore.summary(of: m, existingFileNames: existing)
                if m.state == .crashed || m.state == .recording { line = "⚠️  " + line }
                print(line)
            } catch {
                print("\(id)\n  ⚠️  manifest 不可读：\(error)")
            }
            print("")
        }
    }

    // MARK: - recover

    static func runRecover(_ raw: [String]) throws {
        let a = Args(raw)
        let store = SessionStore(root: rootURL(a))
        let report = try Recovery(store: store).scanAndRepair()

        print("扫描 \(report.scanned) 场会议")
        if report.recovered.isEmpty && report.failed.isEmpty {
            print("✅ 没有发现需要恢复的录音")
            return
        }
        for r in report.recovered {
            print("""

            🔧 已恢复 \(r.sessionID)
                目录：\(r.directory.path)
                时长：\(SessionStore.formatDuration(r.duration))
            """)
            for t in r.tracks {
                if let problem = t.problem {
                    print("      [\(t.id)] ⚠️  \(problem)")
                } else if t.headerRepaired {
                    print("      [\(t.id)] 帧数 \(t.framesBefore) → \(t.framesAfter)（音频头已修复）")
                } else {
                    print("      [\(t.id)] \(t.framesAfter) 帧，无需修复")
                }
            }
        }
        for (id, reason) in report.failed {
            print("\n❌ \(id) 恢复失败：\(reason)")
        }
    }

    // MARK: - devices

    static func runDevices() throws {
        let devices = AudioDevices.inputDevices()
        let defaultID = AudioDevices.defaultInputDeviceID()

        print("音频输入设备（共 \(devices.count) 个）\n")
        for d in devices {
            let isDefault = d.id == defaultID ? "  ← 当前默认" : ""
            print("  \(d.displayName)\(isDefault)")
            print("    UID：\(d.uid)")
            let fmt = AudioDevices.inputStreamFormat(deviceID: d.id)
            if let fmt {
                print(String(format: "    格式：%.0fHz %dch %@",
                             fmt.mSampleRate, fmt.mChannelsPerFrame,
                             AudioDevices.isFloat(fmt) ? "float" : "int"))
            }
            print("")
        }
        print("""
        提示：录制时用 --device <UID> 锁定设备。
        这台机器上存在连续互通麦克风时，系统默认输入可能被切走，
        不锁定会录出静音。
        """)
    }

    // MARK: - doctor

    static func runDoctor() async throws -> Int32 {
        print("会议录音器 · 能力自检\n")

        // 1. 运行形态
        let bundlePath = Bundle.main.bundlePath
        let isApp = bundlePath.hasSuffix(".app")
        print("[运行形态] \(isApp ? "✅ .app bundle" : "⚠️  裸可执行文件")")
        // 版本号放第一段：自检的第一问永远是「我手上这份是哪一版」。
        // 读的是 bundle 里的 Info.plist，不是源码常量——常量迟早会和包脱节。
        print("  版本：\(AppVersion.diagnosticLine())")
        if !isApp {
            print("""
              系统音频采集在 macOS 26 上**必须**从 .app bundle 运行，
              裸 CLI 拿不到权限，且失败是静默的（所有 API 返回 0、缓冲区全零）。
              请用 scripts/build-app.sh 打包后再试。
            """)
        }
        print("  路径：\(bundlePath)\n")

        // 2. 转写引擎
        print("[本地转写]")
        let configuredEngine = RecorderPreferences().transcriptionEngine
        print("  配置的引擎：\(configuredEngine.rawValue)（\(configuredEngine.displayName)）"
            + (configuredEngine.isOptIn ? "　⚠️ opt-in" : ""))
        if AppleSpeechTranscriber.isAvailable {
            let installed = await AppleSpeechTranscriber.installedLanguages()
            let supported = await AppleSpeechTranscriber.supportedLanguages()
            print("  ✅ 引擎可用（支持 \(supported.count) 种语言）")
            print("  已装：\(installed.joined(separator: ", "))")
            if !installed.contains("zh-CN") {
                print("  ⚠️  zh-CN 未安装，首次转写会自动下载")
            }
        } else {
            print("  ❌ 需要 macOS 26 或更高版本")
        }

        // SenseVoice（opt-in）的资产状态。只在**已经配了它或者资产已部分存在**时展开明细：
        // 默认用户永远用不到这个引擎，每次 doctor 都刷三行红字会让人以为出了问题。
        do {
            let paths = SenseVoicePaths()
            let state = SenseVoiceModelStore(paths: paths).state()
            let touchesSenseVoice = configuredEngine == .senseVoice
                || state.status(of: .runtime).isReady
                || !state.pendingDownloadable.isEmpty
            if touchesSenseVoice {
                let mark = state.isReady ? "✅ 资产齐全" : "⚠️  资产未就绪"
                print("  SenseVoice（opt-in）：\(mark)"
                    + (state.isReady
                        ? ""
                        : "（缺 \(state.pending.map(\.kind.displayName).joined(separator: "、"))）"))
                print("    落点：\(paths.baseDirectory.path)")
                if !state.isReady {
                    print("    修复：meeting-recorder model")
                }
            }
        }
        print("")

        // 3. 麦克风
        print("[麦克风]")
        let devices = AudioDevices.inputDevices()
        let micID = AudioDevices.defaultInputDeviceID()
        if devices.isEmpty {
            print("  ❌ 没有可用的输入设备")
        } else {
            for d in devices {
                let marker = d.id == micID ? " ← 默认" : ""
                print("  · \(d.displayName)（\(d.inputChannels)ch）\(marker)")
            }
        }

        // 默认输入与默认输出是不是**同一台物理设备**？
        //
        // 这一位决定麦克风轨的探针结果能不能算数：共用一台设备时（耳机等），
        // 系统会给这条麦克风启用回声消除，把本机播放的提示音抹掉——而提示音
        // 正是下面探测麦克风用的手段。实测那种设置下 micProbe 会在「有数据」
        // 与「全零」之间随机摆动，两种输出都遇到过，而麦克风本身是好的。
        let micUID = micID.flatMap { AudioDevices.info(deviceID: $0)?.uid }
        let outputInfo = AudioDevices.defaultOutputDeviceID()
            .flatMap { AudioDevices.info(deviceID: $0) }
        let sharesDevice = micUID.flatMap { m in
            outputInfo.map { AudioDeviceIdentity.sharesPhysicalDevice(m, $0.uid) }
        } ?? false
        if sharesDevice, let outputInfo {
            print("  ⓘ 默认输入与默认输出是同一台设备（\(outputInfo.displayName)）："
                + "系统会为它启用回声消除，提示音探测对这条麦克风不适用")
        }
        print("")

        // 4. 系统音频 tap（只验证链路是否搭得起来）
        print("[系统音频捕获]")
        var tapCreated = false
        var tap: SystemAudioTap?
        do {
            let created = try SystemAudioTap.create(
                name: "doctor-probe", excludingCurrentProcess: false)
            tap = created
            tapCreated = true
            print("  ✅ tap 与聚合设备创建成功")
            if let fmt = AudioDevices.inputStreamFormat(deviceID: created.aggregateDeviceID) {
                print(String(format: "  格式：%.0fHz %dch", fmt.mSampleRate, fmt.mChannelsPerFrame))
            }
        } catch {
            print("  ❌ tap 创建失败：\(error)")
        }
        print("")

        // 5. 真实采集探针：分别测两条轨能不能真的收到 buffer。
        //
        // 这一步不能省。tap 创建走的是读属性的轻量路径，而真实采集要走
        // AudioDeviceCreateIOProcIDWithBlock——后者才是会卡死的那一步。
        // 早先的 doctor 只验到 tap 创建就报全绿，而那台机器上录制 100% 失败。
        print("[真实采集探针]（把 IOProc 真的跑起来，等第一个 buffer）")
        var systemProbe: CaptureReadiness.Probe = .notAttempted
        var micProbe: CaptureReadiness.Probe = .notAttempted

        // 先让系统**真的发点声**。不这么做的话，「采样全零」有两个完全不同的成因——
        // 授权未生效、或当时系统确实没有音频输出——doctor 无从区分，只能给二义结论。
        // 实测踩过：系统安静时它报「采集降级、只有麦克风可用」，
        // 而同一份二进制在放声音时录得好好的。方向还是反的。
        let tonePlayer = playSystemToneForProbe()
        defer { if let tonePlayer, tonePlayer.isRunning { tonePlayer.terminate() } }
        let probeTonePlayed = tonePlayer != nil
        if probeTonePlayed {
            print("  （探测期间自动播放系统提示音，用来排除「当前没声音」这个干扰项）")
        }

        if let tap {
            systemProbe = IOProcProbe.run(deviceID: tap.aggregateDeviceID)
            print("  · 系统音频轨：\(describe(systemProbe, isSystemAudio: true))")
        } else {
            print("  · 系统音频轨：跳过（tap 未创建）")
        }

        if let micID {
            micProbe = IOProcProbe.run(deviceID: micID)
            print("  · 麦克风轨：\(describe(micProbe, isSystemAudio: false, sharedDevice: sharesDevice))")
        } else {
            print("  · 麦克风轨：跳过（没有可用输入设备）")
        }
        tap?.destroy()
        print("")

        // 6. 结论：判定必须保守，宁可说「未证实」也不许说 ready。
        //
        // `deviceEnumerationWorked` 用来分辨 HAL 卡死的**深度**：枚举也回不来，
        // 才是整个 audio 服务无响应；枚举正常而只有 IOProc 超时是较浅的一种。
        // 两者给出的恢复建议不同——浅的那种等几分钟就好，不需要 killall
        // （见 CaptureReadiness 里的说明）。
        let readiness = CaptureReadiness.assess(CaptureReadiness.Input(
            isAppBundle: isApp,
            tapCreated: tapCreated,
            systemProbe: systemProbe,
            micProbe: micProbe,
            probeTonePlayed: probeTonePlayed,
            deviceEnumerationWorked: !devices.isEmpty,
            inputSharesOutputDevice: sharesDevice))

        print("[结论] \(verdictLabel(readiness.verdict)) \(readiness.headline)")
        for d in readiness.details {
            print("  · \(d)")
        }
        print("")

        // 7. 休眠中的录音（崩溃残留）
        let store = SessionStore(root: SessionStore.defaultRoot())
        if let report = try? Recovery(store: store).scanAndRepair(), !report.recovered.isEmpty {
            print("[恢复]")
            for r in report.recovered {
                print("  🔧 发现并修复未完成录音：\(r.sessionID)")
            }
        } else {
            print("[恢复] 没有未完成的录音")
        }

        // 明确故障时以非零码退出，这样脚本可以写成 `doctor && record`。
        print("")
        switch readiness.verdict {
        case .broken:
            print("❌ 自检未通过，退出码 1。修好上面列出的问题再重跑。")
            return 1
        case .degraded:
            print("⚠️  仅一轨被证实可用，退出码 0。另一轨是否可用**尚未确认**"
                + "（不等于坏了，详见上面结论），正式录制前建议按结论里的方法验证一次。")
        case .partiallyVerified:
            print("✅ 自检通过，退出码 0。系统音频轨已确认可用；麦克风轨的结果无法用提示音"
                + "验证（输入与输出是同一台设备），但**没有任何故障证据**。"
                + "正式录制前建议先录 10 秒说句话确认一次。")
        case .unproven:
            print("⚠️  自检未能证实可用，退出码 0。正式录制前先跑 record --seconds 20 实测一次。")
        case .ready:
            print("✅ 自检通过。")
        }
        return 0
    }

    /// 把探针结果转成人话
    /// 探测系统音频轨时，主动让系统发出一点声音。
    ///
    /// 不这么做的话，「采样全零」有两个完全不同的成因——授权未生效、或当时系统
    /// 确实没有音频输出——doctor 无从区分，只能给二义结论。实测踩过：
    /// 系统安静时它报「采集降级、只有麦克风可用」，而同一份二进制在放声音时录得好好的。
    ///
    /// 几个刻意的选择：
    /// - 用 `/usr/bin/afplay` 播系统自带提示音。afplay 是**独立进程**，
    ///   所以即便 tap 把本进程排除掉，它的输出照样能被拾到。
    /// - 连播数次：单条提示音不到 1 秒，而探针窗口有 3 秒。
    /// - 音量压到 0.35：够被拾到，又不至于吓人。
    ///
    /// 返回 nil 表示没播成（系统提示音文件缺失或 afplay 起不来）。
    /// 此时判定会退回保守口径——全零只能算「未证实」，不能当故障。
    private static func playSystemToneForProbe() -> Process? {
        let candidates = [
            "/System/Library/Sounds/Ping.aiff",
            "/System/Library/Sounds/Tink.aiff",
            "/System/Library/Sounds/Pop.aiff",
        ]
        guard let tone = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }
        let script = "for _ in 1 2 3 4 5 6; do /usr/bin/afplay -v 0.35 '\(tone)'; done"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        return p
    }

    /// 把探针结果转成人话。
    ///
    /// 「全零」的解释**必须按轨分开**：系统音频轨探针期间自播过提示音，所以全零基本是
    /// 确定故障；麦克风轨没有这个手段，全零只能说「没拾到声音」。两者混用一句话，
    /// 就会把麦克风轨误报成故障。
    ///
    /// 还要再分一层：当输入与输出是同一台设备时（`sharedDevice`），提示音会被回声消除
    /// 抹掉，**麦克风轨的「有数据」与「全零」都说明不了问题**——实测同一环境两种结果都
    /// 出现过。此时如实说「无法验证」，不要给出一个会随机翻转的结论。
    /// 注意只对 `warmed` / `silent` 这么处理：`noData` / `timedOut` 是链路级问题，
    /// 与回声消除无关，照常报出来。
    private static func describe(
        _ probe: CaptureReadiness.Probe,
        isSystemAudio: Bool,
        sharedDevice: Bool = false
    ) -> String {
        if sharedDevice, !isSystemAudio {
            switch probe {
            case .warmed, .silent:
                return "· 无法验证（输入与输出是同一台设备，提示音会被回声消除抹掉；"
                    + "这不代表麦克风有问题）"
            case .noData:       return "⚠️ 链路通但没收到 buffer"
            case .timedOut:     return "❌ HAL 调用超时未返回"
            case .notAttempted: return "· 未执行"
            }
        }
        switch probe {
        case .warmed:       return "✅ 收到数据且采样非零"
        case .silent:       return isSystemAudio
            ? "⚠️  收到了 buffer，但采样值全零（已自播提示音仍全零，多半是授权未生效）"
            : "⚠️  收到了 buffer，但采样值全零（可能只是没人说话，也可能是授权/设备问题）"
        case .noData:       return "⚠️  链路通但没收到 buffer"
        case .timedOut:     return "❌ HAL 调用超时未返回"
        case .notAttempted: return "· 未执行"
        }
    }

    /// 把结论转成人话
    private static func verdictLabel(_ verdict: CaptureReadiness.Verdict) -> String {
        switch verdict {
        case .ready:                return "✅ 可用"
        case .partiallyVerified:    return "✅ 可用（有一轨未验证）"
        case .degraded:             return "⚠️  降级"
        case .unproven:             return "⚠️  未证实"
        case .broken:               return "❌ 不可用"
        }
    }

    // MARK: - model（SenseVoice 资产）

    /// SenseVoice 资产的查看 / 下载 / 安装 / 校验 / 删除。
    ///
    /// 为什么要一个独立命令，而不是让 `transcribe` 顺手把模型拉下来：
    /// 244 MiB 的下载必须发生在**用户明确选择的那一刻**。在一次转写里静默下载两分钟，
    /// 从用户视角与「程序卡住」完全无法区分；而下不下、下到哪个盘，是用户该决定的事。
    ///
    /// 用法：
    ///   model                       查看资产状态（同 status）
    ///   model status                查看资产状态
    ///   model download [--force]    下载权重 + VAD（约 244 MiB），并安装运行时
    ///   model install-runtime       只安装运行时二进制（2.9 MiB；可 --from <路径>）
    ///   model verify                全量 sha256 校验
    ///   model remove --yes          删除已下载的全部资产
    ///
    /// `paths` 可注入的理由只有一个：`remove` 那条**删除**分支的护栏
    /// （没有 `--yes` 就绝不执行）必须能被测到，而它的目标是一个真实的
    /// 244 MiB 目录——拿真目录去测「删掉了吗」是荒唐的。指向临时目录之后，
    /// 「文件还在/文件没了」就是一个可以断言的判据。
    static func runModel(
        _ raw: [String],
        paths: SenseVoicePaths = SenseVoicePaths()
    ) async throws {
        let a = Args(raw)
        let store = SenseVoiceModelStore(paths: paths)
        let action = a.positional.first ?? "status"

        switch action {
        case "status", "show":
            printStatus(paths: paths, store: store)
            return

        case "download":
            printStatus(paths: paths, store: store)
            let pending = store.state().pendingDownloadable
            if pending.isEmpty, !a.has("force") {
                print("\n✅ 权重与 VAD 已就绪，跳过下载（需要强制重下加 --force）。")
            } else {
                let total = pending.reduce(0) { $0 + $1.byteCount }
                print("\n开始下载 \(pending.count) 项，合计约 "
                    + "\(String(format: "%.0f", Double(total) / 1_048_576)) MiB…")
                let downloader = SenseVoiceDownloader(paths: paths)
                // 进度按**每项资产**各自记录。早先是一个 `lastPrinted` 在三项之间复用：
                // 权重打到 100 之后，VAD 的 5%~95% 一条都不会打（因为阈值已经被推到 100），
                // 只在收尾时冒出一行 100%——「进度看着不动」正是这段代码想避免的观感。
                var lastPrinted: [SenseVoiceAsset.Kind: Int] = [:]
                _ = try await downloader.installAll(force: a.has("force")) { progress in
                    let percent = progress.expectedBytes > 0
                        ? Int(Double(progress.receivedBytes) / Double(progress.expectedBytes) * 100)
                        : 0
                    // 每 5% 打一行。逐块打印会在终端刷出几万行，而完全不打印又
                    // 让两分钟的等待看起来像卡死。
                    let previous = lastPrinted[progress.kind] ?? -1
                    if percent >= previous + 5 || percent == 100 {
                        lastPrinted[progress.kind] = percent
                        print("  \(progress.kind.displayName)  \(percent)%")
                        // 必须显式 flush：stdout 被重定向到文件/管道时是**块缓冲**的，
                        // 不 flush 的话这 20 行进度会在下载结束后一次性冒出来——
                        // 那正是「看起来卡住」要避免的观感。
                        fflush(stdout)
                    }
                }
                print("✅ 权重与 VAD 下载并校验完成。")
            }
            // 运行时通常可以从本地副本装，所以放在权重之后、单独一步。
            if !store.state().status(of: .runtime).isReady {
                let installation = try await SenseVoiceDownloader(paths: paths)
                    .installRuntime(from: explicitRuntimePath(a))
                printRuntimeInstallation(installation)
            }
            print("")
            printStatus(paths: paths, store: store)

        case "install-runtime":
            let installation = try await SenseVoiceDownloader(paths: paths)
                .installRuntime(from: explicitRuntimePath(a))
            printRuntimeInstallation(installation)
            print("")
            printStatus(paths: paths, store: store)

        case "verify":
            let state = store.state()
            let failures = try store.verifyAll()
            for line in SenseVoiceModelReport.verification(failures: failures, state: state) {
                print(line)
            }
            if !failures.isEmpty {
                throw MRError.io(
                    path: paths.baseDirectory.path,
                    reason: "\(failures.count) 项资产的 sha256 与清单不符（见上）。"
                        + "修复**按项进行**：运行时用 `meeting-recorder model install-runtime`，"
                        + "权重 / VAD 用 `meeting-recorder model download`。"
                        + "不要用 `model remove --yes`——那会把三项一起删掉。")
            }
            // 「校验了 0 项」要以非 0 退出收场。
            //
            // 这条刻意从严：`model verify` 是给脚本用的「资产完好吗」的判据，
            // 而在一台什么都没装的机器上，所有项都会被跳过、`failures` 是空的——
            // 只按 failures 判断的话它会**退出码 0**，脚本据此认为「验证通过」，
            // 继续跑一场注定失败的转写。说不清「验过没有」的绿灯，比红灯更危险。
            if SenseVoiceModelReport.verifiedCount(state: state) == 0 {
                throw MRError.io(
                    path: paths.baseDirectory.path,
                    reason: "没有任何已就绪的资产，本次没有校验到东西（不是「通过」）。"
                        + "请先执行 `meeting-recorder model download`。")
            }

        case "remove":
            let base = paths.baseDirectory
            // 删除是不可逆的，且这里删的是一份 244 MiB 的资产——重下要时间。
            // 没有 `--yes` 一律只打印不执行。
            guard a.has("yes") else {
                print("将删除以下目录（含已下载的模型，重新下载需约 244 MiB 流量）：")
                print("  \(base.path)")
                print("")
                print("确认后请执行：meeting-recorder model remove --yes")
                return
            }
            guard FileManager.default.fileExists(atPath: base.path) else {
                print("目录不存在，无需删除：\(base.path)")
                return
            }
            do {
                try FileManager.default.removeItem(at: base)
            } catch {
                throw MRError.io(path: base.path,
                                 reason: "删除失败：\(error.localizedDescription)")
            }
            print("🗑️  已删除 \(base.path)")
            print("（这是应用数据目录，不含任何会议录音；录音库在 ~/Documents/MeetingRecorder）")

        default:
            throw MRError.invalidArgument(
                "未知的 model 子命令「\(action)」。用法：model [status | download [--force] | "
                    + "install-runtime [--from <路径>] | verify | remove --yes]")
        }
    }

    private static func printStatus(paths: SenseVoicePaths, store: SenseVoiceModelStore) {
        let engine = RecorderPreferences().transcriptionEngine
        for line in SenseVoiceModelReport.status(
            state: store.state(),
            paths: paths,
            configuredEngine: engine,
            ignoredRuntimeOverride: paths.ignoredRuntimeOverride()) {
            print(line)
        }
    }

    /// `--from <路径>` 指向的运行时二进制。未给出时返回 nil（走默认来源顺序）。
    private static func explicitRuntimePath(_ a: Args) -> URL? {
        guard let raw = a.value("from"), !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    private static func printRuntimeInstallation(
        _ installation: SenseVoiceDownloader.RuntimeInstallation
    ) {
        print("✅ 推理运行时已安装")
        print("   来源：\(installation.source.description)")
        print("   落点：\(installation.url.path)")
        // 从本地拷贝来源装的二进制可能是自建的（不是官方 0.2.6）。**这不影响使用**——
        // 运行时的门槛是「存在 + 可执行」，不是字节数（见 `SenseVoiceModelStore.runtimeStatus`）。
        // 早先这里写的是「请改用 model install-runtime 重新安装」，与「自建版本可用」的
        // 承诺直接矛盾：字节数门槛下自建版本根本装不上，用户照做只会被静默覆盖成官方件。
        if let mismatch = installation.digestMismatch {
            print("   ⓘ sha256 与官方 0.2.6 构建不一致（实际 \(mismatch)）。这不影响使用。")
            print("     要换回官方构建：`meeting-recorder model install-runtime`（不带 --from）。")
        }
    }

    // MARK: - config

    /// 全局配置的查看与修改。
    ///
    /// **转写引擎就在这一层选**，不是每场 `transcribe` 里加参数。理由：
    /// - 引擎是「这台机器怎么转写」的长期决定，不是某一场的属性；
    /// - 每场勾选会让同一批会议的稿子出自不同引擎，事后无法按引擎口径复现；
    /// - 与「静默录制」「16 位录音」一致——用户偏好集中在一处，持久化在偏好域里。
    ///
    /// 用法：
    ///   config                     显示全部配置
    ///   config show                同上
    ///   config get engine          只读当前引擎
    ///   config set engine <名字>    设引擎：apple | sensevoice
    /// `config show` 要打印的每一行。
    ///
    /// 抽成纯函数是为了**它能被测**：`runConfig` 直接往 stdout `print`，
    /// 测试既不好控制偏好域（`RecorderPreferences()` 读的是 `.standard`）、
    /// 也不好捕获输出。这里返回数组，测试就能逐行断言。
    /// 这也是「`16 位录音：开/关` 这行曾经只在文档里存在、代码里没人验过」的补课。
    static func configShowLines(prefs: RecorderPreferences) -> [String] {
        [
            "当前配置",
            "  转写引擎：\(prefs.transcriptionEngine.rawValue)"
                + "（\(prefs.transcriptionEngine.displayName)）"
                + (prefs.transcriptionEngine.isOptIn ? "　⚠️ opt-in" : ""),
            "  静默录制：\(prefs.hidesStatusBarCountdown ? "开" : "关")",
            // 菜单栏图标显隐。**默认显示**，所以这一行在没设过时写「显示」——
            // 写「关」会让用户以为图标已经没了，而去到处找原因。
            "  菜单栏图标：\(prefs.showsStatusBarIcon ? "显示" : "隐藏")",
            "  16 位录音：\(prefs.pcm16Recording ? "开" : "关")",
            "  单声道 24 kHz：\(prefs.mono24kRecording ? "开" : "关")",
            "  降混策略：\(prefs.downmixStrategy.rawValue)"
                + "（\(prefs.downmixStrategy.displayName)）"
                + (prefs.mono24kRecording ? "" : "　⚠️ 未开单声道 24 kHz 时不生效"),
            // 坏键要显式说出来，不能让它显示成「关」——那个读法会让用户以为
            // 「我设了一个月」而实际什么都没删。
            "  保留策略：\(prefs.resolvedRetentionPolicy().rawValue)"
                + "（\(prefs.resolvedRetentionPolicy().displayName)）"
                + (prefs.hasUnrecognizedRetentionPolicy()
                    ? "　⚠️ 设置里是认识不了的值，清理已拒绝执行" : ""),
            // 自动清理单独一行，且**默认关**。它与档位是两件事：
            // 档位是规则，这一项是「谁去执行」。
            "  自动清理：\(prefs.autoPruneEnabled ? "开（每天至多一次）" : "关")"
                + (prefs.autoPruneEnabled && prefs.resolvedRetentionPolicy().isEnabled
                    ? "" : "　⚠️ 需要同时设一个 7 / 30 / 90 天的档位才会真的删东西"),
            // 纪要模型层。默认 local；选 api 但没配齐时必须**显式说出缺什么**——
            // 显示成「api」会让用户以为配好了，而第一次 minutes 才报错。
            "  纪要模型：\(Self.minutesProviderLine(prefs))",
            "  纪要 API 密钥：\(prefs.maskedMinutesAPIKey)",
            "",
            "  可选引擎：\(TranscriptionEngine.allCases.map(\.rawValue).joined(separator: " | "))",
            "  可选降混：\(MonoDownmixStrategy.allCases.map(\.rawValue).joined(separator: " | "))",
            "  可选保留：\(RetentionPolicy.selectableCases.map(\.rawValue).joined(separator: " | "))",
            "  可选纪要模型：\(MinutesProvider.allCases.map(\.rawValue).joined(separator: " | "))",
        ]
    }

    /// 「纪要模型：」那一行。**绝不在这一行打印密钥明文**——只显示打码值。
    ///
    /// 抽成静态函数是为了它能被测：`config show` 的每一行都是用户当状态读的，
    /// 「密钥有没有泄露到输出里」必须能被断言，而不能只靠人眼扫。
    static func minutesProviderLine(_ prefs: RecorderPreferences) -> String {
        switch prefs.minutesProvider {
        case .local:
            return "\(MinutesProvider.local.rawValue)（本地 FoundationModels，录音不出本机）"
        case .cloudAPI:
            guard prefs.minutesCloudAPIIsComplete else {
                let missing = prefs.missingMinutesCloudAPIItems().joined(separator: "、")
                return "\(MinutesProvider.cloudAPI.rawValue)（云端 API，**未配齐：缺 \(missing)**）"
            }
            let host = URL(string: prefs.minutesAPIBaseURL ?? "")?.host ?? "?"
            return "\(MinutesProvider.cloudAPI.rawValue)（云端 API：\(prefs.minutesModel ?? "?") @ \(host)）"
        }
    }

    static func runConfig(_ raw: [String]) throws {
        let a = Args(raw)
        let prefs = RecorderPreferences()
        let action = a.positional.first ?? "show"

        switch action {
        case "show":
            for line in Self.configShowLines(prefs: prefs) { print(line) }

        case "get":
            guard let key = a.positional.dropFirst().first else {
                throw MRError.invalidArgument(
                "用法：config get <engine|downmix|retention|autoprune|status-icon|minutes>")
            }
            switch key {
            case "engine":
                print(prefs.transcriptionEngine.rawValue)
            case "downmix":
                print(prefs.downmixStrategy.rawValue)
            case "retention":
                print(prefs.resolvedRetentionPolicy().rawValue)
            case "autoprune":
                print(prefs.autoPruneEnabled ? "on" : "off")
            case "status-icon":
                print(prefs.showsStatusBarIcon ? "on" : "off")
            case "minutes":
                print(prefs.minutesProvider.rawValue)
            case "minutes-url":
                print(prefs.minutesAPIBaseURL ?? "")
            case "minutes-model":
                print(prefs.minutesModel ?? "")
            default:
                throw MRError.invalidArgument(
                    "未知配置项：\(key)（当前有 engine、downmix、retention、autoprune、status-icon、minutes；"
                    + "注意：minutes-key 不可读——密钥永不打印，只能查「设没设」：config show）")
            }

        case "set":
            let rest = Array(a.positional.dropFirst())
            guard rest.count >= 2 else {
                throw MRError.invalidArgument(
                    "用法：config set <engine|downmix|retention|autoprune|status-icon|minutes"
                    + "|minutes-url|minutes-key|minutes-model> <值>")
            }
            switch rest[0] {
            case "autoprune":
                // 只认 on / off。**不做模糊匹配**（"true"/"1"/"启用" 一律报错）——
                // 这一项授权的是「在用户不在场时删数据」，猜错的方向是不对称的：
                // 把「不认的值」猜成开，用户会在毫无预期的情况下丢掉录音。
                let value = rest[1].lowercased()
                guard value == "on" || value == "off" else {
                    throw MRError.invalidArgument(
                        "自动清理只接受 on 或 off，收到「\(rest[1])」。"
                        + "（这一项会在你不在场时删数据，所以不猜。）")
                }
                let enabling = value == "on"
                prefs.autoPruneEnabled = enabling
                print("✅ 自动清理已\(enabling ? "打开" : "关闭")")
                if enabling {
                    if prefs.hasUnrecognizedRetentionPolicy() {
                        print("   ⚠️ 设置里的保留档位是认识不了的值，自动清理会**拒绝执行**。"
                            + "请先 `meeting-recorder config set retention <档位>`。")
                    } else if !prefs.resolvedRetentionPolicy().isEnabled {
                        print("   ⚠️ 当前档位是「\(prefs.resolvedRetentionPolicy().displayName)」，"
                            + "清不了任何东西——打开它现在不会有任何效果。"
                            + "要先 `config set retention 7|30|90` 之一。")
                    } else {
                        print("   之后每天第一次触发时（启动应用 / 录完一场 / 转写完成）"
                            + "会按「\(prefs.resolvedRetentionPolicy().displayName)」自动清理一次。")
                    }
                }
                print("   这一步没有删掉任何文件。要现在清理就跑 `meeting-recorder prune --yes`。")
                return
            case "status-icon":
                // 只认 on / off，不做模糊匹配——与 autoprune 同一纪律。
                // 猜错的方向在这里是不对称的：一个没认出来的值被猜成「关」，
                // 用户的菜单栏图标会整个消失，而他找不到任何原因。
                let value = rest[1].lowercased()
                guard value == "on" || value == "off" else {
                    throw MRError.invalidArgument(
                        "菜单栏图标只接受 on 或 off，收到「\(rest[1])」。"
                        + "（关掉它菜单栏上就什么都不剩了，所以不猜。）")
                }
                let showing = value == "on"
                prefs.showsStatusBarIcon = showing
                print("✅ 菜单栏图标已\(showing ? "显示" : "隐藏")")
                if !showing {
                    print("   录音不受影响：全局快捷键（⌥⌘R / ⌥⌘P / ⌥⌘S / ⌥⌘M）与主窗口照常。")
                    print("   想恢复：config set status-icon on，或设置窗口（⌘,）→「菜单栏」。")
                }
                // **正在运行的应用实例不会感知这次写入**——它只在启动时读偏好。
                // 不说这一句，用户改完盯着菜单栏看「怎么没变」，会以为命令没生效。
                print("   对正在运行的应用下次启动生效；在设置窗口里改则立即生效。")
                return
            case "retention":
                guard let policy = RetentionPolicy(resolving: rest[1]) else {
                    let legal = RetentionPolicy.selectableCases
                        .map(\.rawValue).joined(separator: ", ")
                    throw MRError.invalidArgument(
                        "未知保留档位「\(rest[1])」。可选：\(legal)。"
                        + "（保留策略会**删数据**，所以拼错必须报错而不是猜一个档位。）")
                }
                prefs.retentionPolicy = policy
                print("✅ 保留策略已设为 \(policy.rawValue)（\(policy.displayName)）")
                print("   \(policy.menuHelp)")
                // 刻意**不在这里清理任何东西**：改一个下拉框的期望是
                // 「以后按这个规则办」，不是「帮我清一批」。
                print("   这一步没有删掉任何文件。要现在清理就跑 `meeting-recorder prune --yes`。")
                return
            case "downmix":
                // 精确匹配已知策略名，不做模糊回退——与 `set engine` 同一纪律。
                // 尤其不能回退到 `average`：那正是会丢数据的策略。
                guard let strategy = MonoDownmixStrategy(resolving: rest[1]) else {
                    let legal = MonoDownmixStrategy.allCases
                        .map(\.rawValue).joined(separator: ", ")
                    throw MRError.invalidArgument(
                        "未知降混策略「\(rest[1])」。可选：\(legal)")
                }
                prefs.downmixStrategy = strategy
                print("✅ 降混策略已设为 \(strategy.rawValue)（\(strategy.displayName)）")
                print("   \(strategy.menuHelp)")
                if !prefs.mono24kRecording {
                    print("   ⚠️ 「单声道 24 kHz」当前是关的，所以这个设置暂时不参与处理"
                        + "（源是单声道时不需要降混）。")
                }
                return
            case "minutes":
                // 精确匹配，不做模糊回退——写错一个字应当报错，
                // 而不是静默回退成本地（那会让用户以为云端已启用）。
                guard let provider = MinutesProvider(rawValue: rest[1]) else {
                    let legal = MinutesProvider.allCases.map(\.rawValue).joined(separator: ", ")
                    throw MRError.invalidArgument(
                        "未知纪要模型层「\(rest[1])」。可选：\(legal)。"
                        + "（默认 local；选 api 意味着转写稿会离开本机，所以不猜。）")
                }
                prefs.minutesProvider = provider
                print("✅ 纪要模型层已设为 \(provider.rawValue)（\(provider.displayName)）")
                print("   \(provider.menuHelp)")
                if provider == .cloudAPI {
                    if prefs.minutesCloudAPIIsComplete {
                        print("   三项配置已齐（URL / 密钥 / 模型名），minutes 会直接调用云端 API。")
                    } else {
                        let missing = prefs.missingMinutesCloudAPIItems()
                        print("   ⚠️ 还没配齐：缺 \(missing.joined(separator: "、"))。")
                        for line in Self.minutesCloudSetupHint(missing: missing) { print(line) }
                    }
                }
                return
            case "minutes-url":
                // 设置时就校验地址形态——等第一次 minutes 才报错的话，
                // 用户已经对着「调用失败」猜半天了。
                let probe = CloudAPIConfiguration(baseURL: rest[1], apiKey: "", model: "")
                if let problem = probe.urlProblem {
                    throw MRError.invalidArgument(
                        "\(problem)（收到：\(rest[1])）")
                }
                prefs.minutesAPIBaseURL = rest[1]
                print("✅ 纪要 API Base URL 已设为 \(probe.endpointString) 的宿主")
                print("   \(prefs.minutesAPIBaseURL ?? "")")
                if prefs.minutesProvider != .cloudAPI {
                    print("   ⚠️ 纪要模型层当前是 \(prefs.minutesProvider.rawValue)，这项暂不生效。"
                        + "要启用云端：config set minutes api")
                }
                return
            case "minutes-key":
                // 密钥是黑盒，不校验格式；但不接受空值——空密钥发出去
                // 只会得到一个 401，不如在这里就说清楚。
                let key = rest[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else {
                    throw MRError.invalidArgument(
                        "密钥不能为空。要清除已设的密钥用 config unset minutes-key。")
                }
                prefs.minutesAPIKey = key
                print("✅ 纪要 API 密钥已设置（\(prefs.maskedMinutesAPIKey)）")
                print("   只存本机偏好域；config show 与界面只显示打码值，绝不打印明文。")
                if prefs.minutesProvider != .cloudAPI {
                    print("   ⚠️ 纪要模型层当前是 \(prefs.minutesProvider.rawValue)，这项暂不生效。"
                        + "要启用云端：config set minutes api")
                }
                return
            case "minutes-model":
                let model = rest[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !model.isEmpty, !model.contains(where: \.isWhitespace) else {
                    throw MRError.invalidArgument(
                        "模型名「\(rest[1])」不合法：不能为空、不能含空格"
                        + "（模型名形如 deepseek-chat / glm-5 / qwen-max）。")
                }
                prefs.minutesModel = model
                print("✅ 纪要 API 模型名已设为 \(model)")
                if prefs.minutesProvider != .cloudAPI {
                    print("   ⚠️ 纪要模型层当前是 \(prefs.minutesProvider.rawValue)，这项暂不生效。"
                        + "要启用云端：config set minutes api")
                }
                return
            case "engine":
                break
            default:
                throw MRError.invalidArgument(
                    "未知配置项：\(rest[0])（当前有 engine、downmix、retention、autoprune、"
                    + "status-icon、minutes、minutes-url、minutes-key、minutes-model）")
            }
            let name = rest[1]
            // 必须精确匹配已知引擎名，不做前缀/大小写模糊——写错一个字应当报错，
            // 而不是静默回退成默认值，让人以为换成功了。
            guard let engine = TranscriptionEngine(rawValue: name) else {
                throw MRError.invalidArgument(
                    "未知引擎「\(name)」。可选：\(TranscriptionEngine.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            prefs.transcriptionEngine = engine
            print("✅ 转写引擎已设为 \(engine.rawValue)（\(engine.displayName)）")
            if engine.isOptIn {
                let paths = SenseVoicePaths()
                let state = SenseVoiceModelStore(paths: paths).state()
                if state.isReady {
                    print("   资产已就绪，可以直接转写。")
                } else {
                    for line in Self.senseVoiceActivationHint(state: state) { print(line) }
                }
            }

        case "unset":
            // 清除某个云端配置项。**只认那三个字符串键**——
            // 其它配置项（引擎、保留策略）的语义是「选一个档位」而不是「填一个值」，
            // 给它们加 unset 只会引入「清空后到底回不回到默认」的歧义。
            let rest = Array(a.positional.dropFirst())
            guard let key = rest.first else {
                throw MRError.invalidArgument(
                    "用法：config unset minutes-url|minutes-key|minutes-model")
            }
            switch key {
            case MinutesCloudAPIField.baseURL.rawValue:
                prefs.minutesAPIBaseURL = nil
                print("✅ 纪要 API Base URL 已清除")
            case MinutesCloudAPIField.apiKey.rawValue:
                prefs.minutesAPIKey = nil
                print("✅ 纪要 API 密钥已清除")
            case MinutesCloudAPIField.model.rawValue:
                prefs.minutesModel = nil
                print("✅ 纪要 API 模型名已清除")
            default:
                throw MRError.invalidArgument(
                    "只能 unset 纪要云端配置：minutes-url | minutes-key | minutes-model"
                    + "（收到「\(key)」）")
            }
            if prefs.minutesProvider == .cloudAPI, !prefs.minutesCloudAPIIsComplete {
                print("   ⚠️ 纪要模型层仍设着 api，但配置已不齐——minutes 会明确报错。")
                print("   要么补齐，要么 config set minutes local 回到本地模型。")
            }

        default:
            throw MRError.invalidArgument(
                "未知的 config 子命令「\(action)」。"
                + "用法：config [show | get <engine|downmix|retention|autoprune|minutes> "
                + "| set <engine|downmix|retention|autoprune|minutes|minutes-url"
                + "|minutes-key|minutes-model> <值> "
                + "| unset minutes-url|minutes-key|minutes-model]")
        }
    }

    /// `config set minutes api` 配不齐时的补配指引。
    ///
    /// **每条命令都带示例值**：只说「缺 Base URL」的话，用户还得去猜
    /// 那一层该填到哪儿（含不含 /v1 是真实发生过卡点的地方）。
    static func minutesCloudSetupHint(missing: [String]) -> [String] {
        var lines: [String] = []
        if missing.contains(MinutesCloudAPIField.baseURL.displayName) {
            lines.append("      config set minutes-url https://api.deepseek.com/v1"
                + "（填到含版本号的那一层；示例是 DeepSeek，其它服务商同理）")
        }
        if missing.contains(MinutesCloudAPIField.apiKey.displayName) {
            lines.append("      config set minutes-key <你的密钥>")
        }
        if missing.contains(MinutesCloudAPIField.model.displayName) {
            lines.append("      config set minutes-model deepseek-chat"
                + "（按服务商文档填，如 glm-5 / qwen-max）")
        }
        lines.append("      配齐之前 minutes 不会写任何文件——不会偷偷回退本地模型。")
        return lines
    }

    // MARK: - 帮助

    /// `config set engine sensevoice` 之后的激活提示。
    ///
    /// 抽成返回值而不是直接 `print`，理由与 `usageText()` 一样：这段文字**唯一的作用**
    /// 就是告诉用户下一步敲什么，所以「它到底说了什么」必须能被断言，而不是只能靠人眼。
    static func senseVoiceActivationHint(state: SenseVoiceInstallState) -> [String] {
        var lines: [String] = []
        lines.append("   ⚠️  该引擎的资产尚未就绪："
            + state.pending.map(\.kind.displayName).joined(separator: "、"))
        // 指向**具体命令**，而不是「去看状态并按提示安装」——后者要求用户再跑一条命令、
        // 再读一段输出，才拿到真正该敲的那一行。`model download` 是超集：
        // 它跳过已就绪的项，也顺带把运行时装上。
        lines.append("      执行 `meeting-recorder model download` 安装"
            + "（会跳过已就绪的项；权重约 "
            + "\(String(format: "%.0f", Double(SenseVoiceAssets.downloadableByteCount) / 1_048_576)) MiB）。")
        if state.runtimeMissing {
            lines.append("      若只缺运行时，`meeting-recorder model install-runtime`"
                + "（\(SenseVoiceAssets.runtime.humanSize)，通常不需要联网）更快。")
        }
        lines.append("      在资产就绪之前，转写会在**写任何文件之前**明确报错，"
            + "不会产出空稿或来自其它引擎的稿子。")
        return lines
    }

    /// `version` / `--version`：打印当前用的是哪一版。
    ///
    /// 版本号形如 `2.20261021.1654`，后两段就是这次改动完成的日期与时刻
    /// （规则见 `AppVersion` 与 `scripts/bump-version.sh`）。
    /// 这里**只读 bundle**：裸二进制没有 Info.plist，就如实说「未知」，
    /// 绝不回退成某个看起来正常的版本号——版本号撒谎比没有版本号更糟。
    static func runVersion() -> Int32 {
        print("会议录音器 \(AppVersion.diagnosticLine())")
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            print("  包：\(bundlePath)")
        } else {
            print("""
              未打包（裸可执行文件），因此没有版本号。
              查版本请走 ./mr version，或 ./scripts/build-app.sh 重新打包。
            """)
        }
        return 0
    }

    static func printUsage() {
        print(usageText())
    }

    /// 子命令的参数里是否出现了 `-h` / `--help`。
    ///
    /// **判据刻意从宽：只要有一个 token 恰好是 `-h` 或 `--help`，就当成求助。**
    ///
    /// 为什么不精确到「它是不是某个选项的值」——因为两侧的代价差得极远：
    /// - **漏判**（把求助当普通参数放过去）→ 命令照常执行。放在 `record` 上就是
    ///   **真的开录**：2026-09-29 就因此往真实会议库写进了 2 分钟、约 68 MB 无用录音。
    /// - **误判**（把值当成求助）→ 只打印一次用法，什么都不动、什么都不写。
    ///
    /// 唯一会被误判的形态是 `record --title -h` 这种「拿 `-h` 当标题」。它本来就病态：
    /// `Args` 只把「不以 `--` 开头」的下一个 token 当值，所以这种写法只能往标题里
    /// 塞一个单横线词。为一个病态写法保留「真的开录」的风险，不划算。
    ///
    /// 顺带说清 `--help` 作为值时**不存在**这个歧义：`record --title --help` 在
    /// `Args` 眼里同样是「title 是开关、help 是开关」——两边读法一致，
    /// 见 `MeetingRecorderArgumentTests.testHelpDetectionDoesNotContradictTheArgParser`。
    static func wantsHelp(_ raw: [String]) -> Bool {
        raw.contains { $0 == "-h" || $0 == "--help" }
    }

    /// 用法文本。**抽成返回值**而不是直接 `print`：这样「帮助里有没有 model 段、
    /// 有没有四个子命令」可以被断言到，而不是只能靠人眼扫一遍输出。
    static func usageText() -> String {
        """
        meeting-recorder —— macOS 本地会议录音与转写

        用法：
          meeting-recorder record [选项]              开始双轨录制（Ctrl-C 停止）
              --title <标题>        会议标题（默认「会议」）
              --device <UID>        锁定麦克风设备 UID（用 devices 查看）
              --seconds <秒>        录制指定时长后自动停止
              --max <秒>            最长录制时长保护
              --log <文件>          日志同时写入该文件（后台/无终端时必备）
              --root <目录>         存储根目录（默认 ~/Documents/MeetingRecorder）
              --no-self-audio       系统音频不排除本进程
              --pcm16               录音存成 16 位整数 PCM（体积约一半，精度减半）
              --f32                 显式指定 32 位浮点无损（默认；与 --pcm16 互斥）
              --mono24k             录音降成单声道 24 kHz（体积再降至约 1/3）
              --fullband            显式保留源的采样率与声道数（默认；与 --mono24k 互斥）
                                    --mono24k 与 --pcm16 可叠加，两条一起约降到 1/6。
                                    上面这些比例按「两条轨的源都是 48 kHz」算；省多少
                                    取决于麦克风给的格式——有些设备（如 AirPods）
                                    本身就只给 24 kHz 单声道，那种情况下双轨实测约 1/5。
          --downmix <策略>         多声道合并成单声道的方式：
                                first-channel（默认，只取第 1 声道）| average（各声道平均）
                                仅在源是多声道、且开了 --mono24k 时才生效（系统音频轨通常是
                                2 声道，所以那条轨会用到）。本机真机实测：average 在单边
                                有声时掉 6 dB，两个声道反相时还会互相抵消成静音——录音
                                看起来完全成功、只是没有声音，所以默认不用它。

          meeting-recorder transcribe <会话ID|目录>   转写并生成文稿
              --lang <语言>             默认 zh-CN
              --segment                 启用长音频分段（默认关闭）
              --segment-threshold <秒>  超过该时长才分段（隐含启用；--segment 默认 600）
              --max-segment <秒>        单段最长时长（默认 300）
              --keep-slices             保留切片文件（排查用）
              --no-segment              显式关闭分段（默认行为）
              --track <轨ID>            只转写这一条轨：mic（我）| system（对方）
              --minutes                 转写完成后立即生成会议纪要（见下面的 minutes 命令）
              --root <目录>

          转写引擎是**全局配置项**，不在本命令里选——见下面的 config 命令。
          默认 apple-speech（苹果原生、零下载、约 160×、出本机）。
          分段默认关闭。实测单段直转对 2 小时音频只用 56 秒、本进程内存恒定 24 MB
          （引擎在独立 XPC 进程内流式处理），分段反而多花约 5 倍时间与 16 倍内存。
          需要「某段失败不影响整条轨」的隔离时才开。

          --track 的用途：另一条轨其实是空的时，对它再跑一遍推理纯属浪费
          （本机 4 场真实录音里有 3 场的「对方」轨是全静音）。
          单轨稿写到 transcript-<轨ID>.md，**整场稿 transcript.md 一个字节都不动，
          也不会把这场标记成「已转写」**；单轨稿不做跨轨去重（一条轨没得比），
          所以用扬声器开会时同一句可能出现两次——要去重就跑不加 --track 的整场转写。
          写了不存在的轨会报错，不会静默转整场。

          meeting-recorder transcode <会话ID|目录>   把已录的音频转成目标格式（默认 B 档）
              --to <档位>              b（默认）| pcm16 | f32
              --downmix <策略>         first-channel（默认）| average
              --dry-run                只算账，一个字节都不写
              --keep-original          原文件另存为 .<文件名>.orig
              --all                    转存储根目录下的全部会议
              --root <目录>

          转码与录制走**同一段 DSP**（降混 → 重采样 → 写 WAV），
          所以「转出来的格式」与「开着对应档位实时录制的格式」不可能不一致。
          每条轨都是：写临时文件 → 校验 6 项（头部格式/帧数/头部与实际长度一致/
          时长差 ≤2 ms/峰值非零）→ 通过才**原子替换**原文件并同步 manifest。
          任何一项不过，原文件保持不变。**回退：转码只改封装格式，不改内容，
          与转写稿的时间轴仍然对得上。**
          --dry-run 会先告诉你「原格式 → 目标格式、原字节 → 新字节、省百分之几」，
          建议批量迁移前先跑一次。
          --all 不能与 --keep-original 同时给（整库留备份会让峰值磁盘翻倍）。

          meeting-recorder merge <会话ID|目录>       把两条轨合成一个可播放的文件
              --stereo                我=左声道、对方=右声道（默认，不丢信息）
              --mono                  所有人混成单声道（不可逆，只在设备只支持单声道时用）
              --mode <值>             stereo | mono（上面那对开关的另一种写法）
              --to <位深>             pcm16（默认）| f32
              --out <路径>            输出路径（默认写进会话目录，名为 <标题>-merged.wav）
              --overwrite             目标已存在时覆盖（默认报错，不静默覆盖）
              --root <目录>

          会议分两轨录是对的（说话人分得清），但**发给别人时对方要的是一个文件**。
          默认不混成单声道而是左右分置：混音之后两人同时说话会互相掩盖且不可逆，
          而耳机一戴就能分开听。想听单声道的人任何播放器的「下混」都能做。
          两轨起点不在同一时刻（实测 1～10 ms，系统音频冷启动慢的能到 1 秒以上），
          合并时按 hostTime 对齐——与转写稿的时间轴同源，所以听到的和文稿里的对得上。
          合并产物**不是一条音轨**，不会写进 manifest，删掉它不影响这场会议。

          meeting-recorder prune                      按保留策略清理旧音频（只删音频，留转写稿）
              --days <天数>            一次性按这个天数清，不改变设置：7 | 30 | 90
              --yes                    真的执行（不给就只预演，一个文件都不删）
              --dry-run                显式预演
              --include-untranscribed  连没转写过的会议一起清（默认不：删了就没内容了）
              --root <目录>

          ⚠️ 这是本工具里**唯一会删用户数据**的命令。删除走废纸篓，不是直接抹掉。
          保留档位本身**不会立刻清理**——它只决定「按什么规则清」。
          设档位的那一刻不会删掉任何东西。要现在清理就跑这条命令。
          默认档位是「关闭」，也就是什么都不删。
          跳过不动：没转写过的、正在录的、manifest 读不出来的、目录里有合并导出文件的。
          想要它每天自动跑一次：`config set autoprune on`（**默认关**，单独授权）。

          meeting-recorder minutes <会话ID|目录>    为已转写的会议生成纪要
              --root <目录>

          默认由本地 FoundationModels 在设备端生成（录音不出本机、零成本）；
          本机未启用 Apple Intelligence 时自动降级为仅保留原始转写稿。
          也可以配云端通用模型 API（OpenAI 兼容 /chat/completions，覆盖
          DeepSeek / GLM / Qwen / Kimi 等）——那是隐私决策，默认关闭：
            config set minutes api
            config set minutes-url <Base URL>     填到含版本号的那一层
            config set minutes-key <API Key>
            config set minutes-model <模型名>
          密钥只存本机偏好域；config show 与界面一律打码，绝不打印明文。
          云端调用失败（网络/鉴权/限流）会明确报错，不会偷偷写降级稿。

          meeting-recorder config                     查看全局配置
          meeting-recorder config get engine          只看当前转写引擎
          meeting-recorder config get retention       只看当前保留档位
          meeting-recorder config get minutes         只看当前纪要模型层
          meeting-recorder config set engine <名字>   设转写引擎：apple | sensevoice
          meeting-recorder config set downmix <策略>  设降混策略：
                                    first-channel（默认）| average
          meeting-recorder config set retention <档>  设保留档位（默认 off）：
                                    off（默认，不删＝永久保留）| 7 | 30 | 90
          设保留档位这一步**不会删掉任何文件**，只是把「以后该按什么规则清」记下来。
          「永久保留」不是独立档位：它与「关闭」的清理结果完全相同，都是什么都不删，
          所以合成一项；历史写法 `keep` / `forever` 仍然照旧解析成关闭。
          meeting-recorder config set autoprune on|off  是否每天自动清理一次（默认 off）
          自动清理是**单独一次授权**，与档位分开：档位说「按什么规则清」，
          这一项说「谁去清」。合成一项的话，「选个下拉框看看效果」就会变成
          几周后一批录音消失。打开后每天至多一次（启动 / 录完一场 / 转写完成时触发），
          没转写过的会议永远不会被自动清理。
          meeting-recorder config set status-icon on|off 菜单栏是否显示图标（默认 on）
          关掉后菜单栏上不再有本应用的图标与菜单，**录音不受影响**——
          全局快捷键（⌥⌘R / ⌥⌘P / ⌥⌘S / ⌥⌘M）与主窗口照常。
          想恢复：config set status-icon on，或设置窗口（⌘,）→「菜单栏」。
          注意：正在运行的应用实例只在启动时读偏好，本命令对它下次启动生效。
          meeting-recorder config set minutes <名字>   设纪要模型层：local（默认）| api
          meeting-recorder config set minutes-url <URL>   云端 API 的 Base URL
          meeting-recorder config set minutes-key <密钥>   云端 API 的密钥
          meeting-recorder config set minutes-model <名字> 云端 API 的模型名
          meeting-recorder config unset minutes-url|minutes-key|minutes-model
                                                  清除某一项云端配置

          纪要模型层是全局开关，与转写引擎同一套纪律：默认 local
          （本地 FoundationModels，录音不出本机）。选 api 意味着**转写稿会离开
          本机**发往第三方服务，所以必须用户逐项配齐后主动开启；三项缺任何一项，
          minutes 会在写任何文件之前明确报错并列出要敲的命令，绝不静默回退本地。

          引擎是全局开关（改一次，之后每场转写都听它的），不是每场勾选。
          sensevoice 是 opt-in：默认关，主要服务专有名词密集场景；使用前需先安装资产
          （见下面的 model 命令）。资产未就绪时转写会在写任何文件之前明确报错，
          不会产出空稿，也不会静默回退到苹果引擎。

          meeting-recorder model                      查看 SenseVoice 资产状态
          meeting-recorder model download             下载权重 + VAD（约 244 MiB，仅首次）
          meeting-recorder model install-runtime      安装推理运行时（2.9 MiB，通常用本地副本）
              --from <路径>         从指定文件安装（自建 / 异版本可用：门槛是「可执行」，
                                    不是字节数；sha256 与官方不符只提示、不阻断）
          meeting-recorder model verify               全量 sha256 校验
          meeting-recorder model remove --yes         删除已下载的资产

          资产落在 ~/Library/Application Support/meeting-recorder/sensevoice，
          与会议录音目录分开——「备份会议」不会因此多出 244 MiB。
          同一份资产的下载一次只允许一个：CLI 与界面同时点会有一边直接报错，
          不会两边一起写同一个临时文件。

          本仓库的可执行入口是根目录的 ./mr（它转调 .app 内的二进制；
          也可以直接用 .build/debug/meeting-recorder）。下文与所有错误提示里
          统一写作 meeting-recorder —— 若你的 PATH 里没有这个名字，把它换成 ./mr。

          meeting-recorder list                       列出所有会议
          meeting-recorder recover                    扫描并修复崩溃残留的录音
          meeting-recorder devices                    列出音频输入设备
          meeting-recorder doctor                     能力自检（权限、引擎、设备）
          meeting-recorder version                    打印当前版本号（后两段是这次改动
                                                      完成的日期与时刻）

        存储布局：每场会议一个文件夹，含 manifest.json / mic.wav / system.wav /
        transcript.md / transcript.json —— 无数据库，可直接拷贝、grep、归档。
        """
    }
}
