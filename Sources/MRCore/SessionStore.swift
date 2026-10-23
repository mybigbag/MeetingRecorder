import Foundation

/// 会议存储布局：
///
/// ```
/// <root>/
///   2026-09-27-143012-产品评审/
///     manifest.json      会话元数据 + 状态机
///     mic.wav            我的音轨
///     system.wav         对方音轨
///     transcript.md      转写稿
///     transcript.json    结构化转写（喂给别的工具）
/// ```
///
/// 每场会议一个**纯文件夹**，无数据库。可 grep、可打包、可直接拷走。
public struct SessionStore {

    public let root: URL
    private let fileManager: FileManager

    public static let manifestFileName = "manifest.json"
    public static let transcriptMarkdownName = "transcript.md"
    public static let transcriptJSONName = "transcript.json"

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    /// 默认根目录：~/Documents/MeetingRecorder
    ///
    /// 可以用环境变量 `MEETING_RECORDER_ROOT` 覆盖。两个理由：
    ///  1. 有人希望会议库放在别处（外置盘、同步盘），不该逼他们改代码；
    ///  2. 图形界面启动时不带参数，所以 CLI 的 `--root` 对它无效。
    ///     加上这个变量之后，界面也能被指向任意目录——自动化冒烟测试
    ///     就是靠它绕开「文稿」文件夹那个必须人工点击的 TCC 弹窗。
    public static let rootEnvironmentKey = "MEETING_RECORDER_ROOT"

    public static func defaultRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment[rootEnvironmentKey],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Documents/MeetingRecorder", isDirectory: true)
    }

    public func ensureRoot() throws {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: root.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw MRError.io(path: root.path, reason: "该路径存在但不是目录")
            }
            return
        }
        do { try fileManager.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { throw MRError.io(path: root.path, reason: error.localizedDescription) }
    }

    // MARK: - 标题

    /// 不给标题时的前缀。
    public static let defaultTitleBase = "会议"

    /// 标题里的时间后缀，格式 `yyyyMMddHHmm`。
    ///
    /// 只用**分钟**精度，与「会议202607271624」这种读法一致。
    /// 序号的意义在于「列表里能一眼分清并排序」，而不是当成唯一键——
    /// 唯一性由目录名保证（它带秒，且同名会追加 `-2`）。
    ///
    /// 时区必须显式跟随 `calendar`，不能靠 DateFormatter 的默认值：
    /// 默认是系统时区，跨时区运行时同一个 `Date` 会算出不同的小时。
    public static func titleStamp(for date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyyMMddHHmm"
        return f.string(from: date)
    }

    /// 自动标题 = 前缀 + 时间后缀，例如「会议202607271624」。
    ///
    /// **这是默认标题的唯一出处**：CLI 的 `record` 与界面的「开始录制」都调它。
    /// 两边各写一遍时间格式，早晚会漂成两种样子。
    public static func autoTitle(
        base: String = defaultTitleBase,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmed.isEmpty ? defaultTitleBase : trimmed
        return prefix + titleStamp(for: date, calendar: calendar)
    }

    /// 生成会话 ID（= 目录名）。格式 `<yyyy-MM-dd-HHmmss>-<slug>`
    public static func makeSessionID(title: String, date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone   // 必须显式跟随，否则用系统时区，跨时区会错开小时
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = f.string(from: date)
        let slug = slugify(title)
        return slug.isEmpty ? stamp : "\(stamp)-\(slug)"
    }

    /// 标题 → 文件名安全片段。保留中日韩字符（转写稿是中文的，slug 用中文更好读）。
    public static func slugify(_ raw: String, maxLength: Int = 40) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        var out = ""
        for scalar in raw.unicodeScalars {
            if illegal.contains(scalar) || scalar == " " {
                out.append("-")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        // 折叠连续的 -
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        if out.count > maxLength { out = String(out.prefix(maxLength)) }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        return out
    }

    /// 创建会话目录，并**立刻写入初始 manifest**。
    ///
    /// 立刻落盘不是可选项：崩溃恢复的全部依据就是「manifest 说在录、但进程没了」。
    /// 如果 manifest 等到录完才写，中途被杀的录音就永远找不回来。
    ///
    /// 同名时自动追加 -2 / -3，绝不覆盖已有会议。
    @discardableResult
    public func createSession(
        title: String,
        date: Date = Date(),
        writeInitialManifest: Bool = true
    ) throws -> (id: String, directory: URL) {
        try ensureRoot()
        let base = Self.makeSessionID(title: title, date: date)
        var candidate = base
        var n = 2
        while fileManager.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(n)"
            n += 1
            if n > 999 {
                throw MRError.io(path: root.path, reason: "同名会话过多，无法分配目录名")
            }
        }
        let dir = root.appendingPathComponent(candidate, isDirectory: true)
        do { try fileManager.createDirectory(at: dir, withIntermediateDirectories: false) }
        catch { throw MRError.io(path: dir.path, reason: error.localizedDescription) }

        if writeInitialManifest {
            let initial = RecordingManifest(
                sessionID: candidate, title: title, startedAt: date, state: .recording)
            try save(initial, sessionDirectory: dir)
        }
        return (candidate, dir)
    }

    public func directory(forSessionID id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    public func manifestURL(sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent(Self.manifestFileName)
    }

    public func manifestURL(forSessionID id: String) -> URL {
        manifestURL(sessionDirectory: directory(forSessionID: id))
    }

    /// 列出根目录下所有会话 ID，按名称（即时间）倒序，最新的在前
    public func listSessionIDs() throws -> [String] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let entries: [String]
        do { entries = try fileManager.contentsOfDirectory(atPath: root.path) }
        catch { throw MRError.io(path: root.path, reason: error.localizedDescription) }

        return entries
            .filter { !$0.hasPrefix(".") }
            .filter { fileManager.fileExists(atPath: manifestURL(forSessionID: $0).path) }
            .sorted(by: >)
    }

    public func loadManifest(forSessionID id: String) throws -> RecordingManifest {
        try RecordingManifest.read(from: manifestURL(forSessionID: id))
    }

    public func loadManifest(sessionDirectory: URL) throws -> RecordingManifest {
        try RecordingManifest.read(from: manifestURL(sessionDirectory: sessionDirectory))
    }

    public func save(_ manifest: RecordingManifest, sessionDirectory: URL) throws {
        try manifest.write(to: manifestURL(sessionDirectory: sessionDirectory))
    }

    public func trackURL(sessionDirectory: URL, fileName: String) -> URL {
        sessionDirectory.appendingPathComponent(fileName)
    }

    /// 人类可读摘要。
    ///
    /// - Parameter existingFileNames: **盘上真的存在的音轨文件名**。
    ///   给了就把不存在的那些标成「音频已被清理」。
    ///   不给（`nil`）则一律按 manifest 显示——那是「我不关心盘上状态」的场合，
    ///   恢复流程里的诊断输出就是。
    ///
    ///   ## 为什么要有这个参数
    ///
    ///   manifest 记的是「当初录了什么」，**不是「现在盘上有什么」**。
    ///   保留策略（`prune`）只删音频、故意留着 manifest，所以「manifest 说有、
    ///   盘上没有」从**罕见异常**变成了**清理之后的正常状态**。
    ///   而只按 manifest 显示的话，用户会看到
    ///   `[我] mic 600.0s 48000Hz 1ch`——一列像模像样的音轨，点进去什么都没有。
    ///   这与 `SessionLibrary.existingTracks` 早就处理掉的是同一类问题
    ///   （「列表上显示 2 轨却打不开文件，比显示 0 轨更让人困惑」），只是 CLI 这条路
    ///   一直没接上。实测发现的：prune 之后 `mr list` 仍然列着轨。
    public static func summary(of manifest: RecordingManifest,
                               existingFileNames: Set<String>? = nil) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = [
            "\(fmt.string(from: manifest.startedAt))  \(manifest.title)",
            "  状态: \(manifest.state.rawValue)   时长: \(formatDuration(manifest.duration))",
        ]
        for t in manifest.tracks {
            let gone = existingFileNames.map { !$0.contains(t.fileName) } ?? false
            lines.append("  [\(t.role.displayName)] \(t.id)  \(String(format: "%.1f", t.duration))s  "
                + "\(Int(t.sampleRate))Hz \(t.channels)ch"
                + (t.deviceName.map { "  (\($0))" } ?? "")
                + (gone ? "  ← 音频已被清理（转写稿保留）" : ""))
            for w in t.warnings { lines.append("      ⚠️ \(w)") }
        }
        if let existingFileNames, manifest.tracks.allSatisfy({ !existingFileNames.contains($0.fileName) }),
           !manifest.tracks.isEmpty {
            lines.append("  （这一场的音频都不在了，转写稿与 manifest 仍然保留）")
        }
        return lines.joined(separator: "\n")
    }

    public static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
