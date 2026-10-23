import Foundation

/// 会话状态机
public enum SessionState: String, Codable, Sendable {
    /// 正在录制
    case recording
    /// 已正常停止，音频完整
    case finalized
    /// 启动时发现处于 recording 但进程已不在 → 崩溃残留
    case crashed
    /// 崩溃后已修复音频头
    case recovered
    /// 已产出转写稿
    case transcribed

    /// 是否需要用户处理
    public var needsAttention: Bool { self == .crashed }
}

/// 音轨角色。**角色即说话人身份**——这是双轨方案最聪明的一手：
/// 把「谁在说」这个最难的问题（说话人分离）绕过去了，而且两人同时说话也不丢。
public enum TrackRole: String, Codable, Sendable {
    /// 本机麦克风 = 你
    case microphone
    /// 系统音频输出 = 对方
    case systemAudio

    public var displayName: String {
        switch self {
        case .microphone: return "我"
        case .systemAudio: return "对方"
        }
    }
}

public struct TrackManifest: Codable, Equatable, Sendable {
    /// 稳定标识，同时是文件名主干：mic / system
    public var id: String
    public var role: TrackRole
    public var fileName: String
    public var sampleRate: Double
    public var channels: Int
    /// 音频采样格式（位深）。
    ///
    /// 记它是因为**盘上别的地方查不到**：WAV 头里有，但 manifest 是「一眼看清这场会议
    /// 录成了什么」的地方，而位深恰好是可以被用户切换的那一项。缺了它，
    /// 「这个文件是 16 位还是 32 位」就得把每个 wav 读一遍才知道——
    /// 界面显示的音轨参数与文件真实格式也可能从此悄悄不一致。
    public var sampleFormat: WAVSampleFormat
    public var framesWritten: Int
    public var firstHostTime: UInt64
    public var lastHostTime: UInt64
    public var deviceUID: String?
    public var deviceName: String?
    public var warnings: [String]

    public init(
        id: String,
        role: TrackRole,
        fileName: String,
        sampleRate: Double,
        channels: Int,
        sampleFormat: WAVSampleFormat = .float32,
        framesWritten: Int = 0,
        firstHostTime: UInt64 = 0,
        lastHostTime: UInt64 = 0,
        deviceUID: String? = nil,
        deviceName: String? = nil,
        warnings: [String] = []
    ) {
        self.id = id
        self.role = role
        self.fileName = fileName
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleFormat = sampleFormat
        self.framesWritten = framesWritten
        self.firstHostTime = firstHostTime
        self.lastHostTime = lastHostTime
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.warnings = warnings
    }

    public var duration: Double { sampleRate > 0 ? Double(framesWritten) / sampleRate : 0 }

    /// 容忍字段缺失。manifest 是落盘的持久化格式，将来加字段时
    /// 旧文件必须仍能被读出来，否则一次升级就会让历史会议全部「损坏」。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decodeIfPresent(TrackRole.self, forKey: .role) ?? .microphone
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? "\(id).wav"
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 48000
        channels = try c.decodeIfPresent(Int.self, forKey: .channels) ?? 1
        // 容错解码，比 `decodeIfPresent(WAVSampleFormat.self)` 更宽：后者只挡「缺键」，
        // 挡不住「值不认识」——枚举原始值映射失败会抛 `dataCorrupted`，
        // 于是**一条轨道的一个字段就能让整场会议读不出来**（一条 pcm24 就会让历史录音集体变红）。
        // 所以这里先按字符串取，认不出就退回 `.float32`：宁可这一个字段显示得保守，
        // 也不能让整场录音从列表里消失。音频读取一律以 WAV 头为准（`WAVReader` 按格式码解析），
        // 不受这里影响。缺键 → `.float32` 对历史 manifest 是事实，不是近似
        //（引入这个字段之前，所有录音都是 float32）。类型不对（比如写成数字 16）同样不抛。
        let rawFormat = (try? c.decodeIfPresent(String.self, forKey: .sampleFormat)) ?? nil
        sampleFormat = rawFormat.flatMap(WAVSampleFormat.init(rawValue:)) ?? .float32
        framesWritten = try c.decodeIfPresent(Int.self, forKey: .framesWritten) ?? 0
        firstHostTime = try c.decodeIfPresent(UInt64.self, forKey: .firstHostTime) ?? 0
        lastHostTime = try c.decodeIfPresent(UInt64.self, forKey: .lastHostTime) ?? 0
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

/// 音轨标识。**同时是文件名主干**：`mic` → `mic.wav`，`system` → `system.wav`。
///
/// 之所以要有这个类型：轨 id 在**录音器、manifest、界面菜单**三处都要用，
/// 而它同时决定文件名——一处拼错，写出来的就是 `mic.wav` 与 manifest 里的
/// `mic `，于是「文件明明在、却读不出来」，且没有任何地方会报错。
/// 字面量散着写时这种不一致极难在 review 里看出来。
public enum TrackID: String, Codable, CaseIterable, Sendable {
    case mic
    case system

    /// 界面上的显示名。取自 `TrackRole.displayName`，让「谁在说」只有一个出处。
    public var displayName: String {
        switch self {
        case .mic: return TrackRole.microphone.displayName
        case .system: return TrackRole.systemAudio.displayName
        }
    }

    /// **正在录制**时的 SF Symbol（SF Symbols 名称，与本项目无关）。
    ///
    /// 收在类型上而不是散在界面里：图标与轨是一一对应的，
    /// 而「对方轨来自系统音频」这件事很容易在画界面时被写成麦克风图标——
    /// 用户看到会以为麦克风被关了，实际是对方那轨。
    public var activeIcon: String {
        switch self {
        case .mic: return "mic"
        case .system: return "speaker.wave.2"
        }
    }

    /// **已静音**时的 SF Symbol。必须是该轨自己的 `slash` 版本，
    /// 不存在跨轨复用的余地。
    public var mutedIcon: String {
        switch self {
        case .mic: return "mic.slash"
        case .system: return "speaker.slash"
        }
    }
}

/// 一次暂停。
///
/// ⚠️ **时间是墙钟偏移，不是音频时间轴上的位置。**
/// 暂停期间根本不写盘，所以音频里没有这一段——「在 12:30 处暂停 3 分钟」
/// 说的是真实世界的 12:30，而那一刻在音频里对应的是 12:30 减掉之前的暂停总长。
/// 这两个数不能混，混了就会拿错误的秒数去播放器里跳。
public struct PauseSpan: Codable, Equatable, Sendable {

    /// 开始暂停时，距会话起点（`startedAt`）的真实秒数
    public var startedAfter: Double
    /// 暂停持续秒数
    public var duration: Double

    /// **哪一轨**被停掉了。`nil` = 两条轨都停了（全局暂停）。
    ///
    /// **旧 manifest 里没有这个键，一律解成 `nil`**，也就是「全局暂停」——
    /// 这正是旧数据的真实含义（那时只有一个暂停按钮，必然同时停两轨）。
    /// 若反过来把缺键解成"未知"，历史会议的 `pausedTotal` 就会变成 0，
    /// 时长凭空多出暂停的那一大段，比字段缺失本身更糟。
    ///
    /// 用轨 id（`mic` / `system`）而不是 `TrackRole`：轨 id 是文件名主干、
    /// 与盘上文件一一对应，而角色是语义标签——将来同一角色拆成多轨时，
    /// 只有轨 id 能唯一指认。
    public var trackID: String?

    public init(startedAfter: Double, duration: Double, trackID: String? = nil) {
        self.startedAfter = startedAfter
        self.duration = duration
        self.trackID = trackID
    }

    /// 容忍字段缺失（同本文件其它落盘类型的纪律）：
    /// 缺 `trackID` 的旧记录解成全局暂停，见上面那个字段的说明。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAfter = try c.decode(Double.self, forKey: .startedAfter)
        duration = try c.decode(Double.self, forKey: .duration)
        trackID = try c.decodeIfPresent(String.self, forKey: .trackID)
    }

    /// 停的是不是这一轨。`nil`（全局）匹配任何一轨。
    public func affects(trackID id: String) -> Bool {
        self.trackID == nil || self.trackID == id
    }
}

/// 每场会议一份 manifest。刻意用人类可读的 JSON 而不是数据库：
/// 可 grep、可移植、能被别的工具直接消费，也不需要任何运行时依赖。
public struct RecordingManifest: Codable, Equatable, Sendable {

    public static let currentVersion = 1

    public var version: Int
    public var sessionID: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var state: SessionState
    public var tracks: [TrackManifest]
    public var notes: [String]
    /// 录制期间的暂停。空的表示全程连续。
    ///
    /// 落盘而不是只放在内存里：听录音的人遇到一段「跳过去」的地方必须能查到原因，
    /// 否则只能猜是录音坏了、还是当时确实没人说话。
    public var pauses: [PauseSpan]

    public init(
        version: Int = RecordingManifest.currentVersion,
        sessionID: String,
        title: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        state: SessionState = .recording,
        tracks: [TrackManifest] = [],
        notes: [String] = [],
        pauses: [PauseSpan] = []
    ) {
        self.version = version
        self.sessionID = sessionID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
        self.tracks = tracks
        self.notes = notes
        self.pauses = pauses
    }

    public var duration: Double {
        let end = endedAt ?? Date()
        return max(0, end.timeIntervalSince(startedAt))
    }

    /// 暂停总时长（秒）——**只算全局暂停**（`trackID == nil`）。
    ///
    /// ⚠️ **分轨静音不在这里。** 两者对时长的含义恰好相反：
    /// - **全局暂停**：数据被丢弃，两条音频里都**没有**那一段 → 要从时长里扣掉。
    /// - **分轨静音**：写入静音帧，音频里**有**那一段（只是一片静音）→ 扣掉就错了。
    ///
    /// 把两者混在一起算，会让「我轨静音 10 分钟」被算成「这场会只有 5 分钟」——
    /// 而文件明明是 15 分钟。历史 manifest 的记录 `trackID` 全为 `nil`，
    /// 所以这个口径对旧数据与「只有全局暂停」的旧行为完全一致。
    public var pausedTotal: Double {
        pauses.reduce(0) { $0 + (($1.trackID == nil) ? max(0, $1.duration) : 0) }
    }

    /// 某一轨累计被静音的秒数（含全局暂停期间——那段时间它也没在录）。
    ///
    /// 与 `pausedTotal` 相反：这个数**不能**从时长里扣，它回答的是
    /// 「这一轨有多少时间是被人为掐掉的」，用于如实告知，
    /// 以及让波形/回放能画出「这段没录」的位置。
    public func mutedTotal(trackID: String) -> Double {
        pauses.reduce(0) { $0 + ($1.affects(trackID: trackID) ? max(0, $1.duration) : 0) }
    }

    /// 某一轨因分轨静音而少录的秒数（**不含**全局暂停）。
    ///
    /// 「因分轨静音而少录」才是用户真正想知道的量：这段时间音频文件里
    /// 是静音、没有任何有效内容。混进全局暂停会把「主动停掉」与
    /// 「顺手一起停了」说成一件事。
    public func soloMutedTotal(trackID: String) -> Double {
        pauses.reduce(0) {
            $0 + (($1.trackID == trackID) ? max(0, $1.duration) : 0)
        }
    }

    /// 真正录到的时长 = 墙上时钟跨度 − 暂停总长。
    ///
    /// 与 `tracks` 各自的内容时长相独立，用来在音轨信息缺失（崩溃残留、
    /// 文件被删）时仍能给出一个不含暂停的时长。
    public var recordedDuration: Double {
        max(0, duration - pausedTotal)
    }

    /// 容忍字段缺失，理由同 `TrackManifest.init(from:)`。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        sessionID = try c.decode(String.self, forKey: .sessionID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? sessionID
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        state = try c.decodeIfPresent(SessionState.self, forKey: .state) ?? .finalized
        tracks = try c.decodeIfPresent([TrackManifest].self, forKey: .tracks) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        // 旧 manifest 没有这个键，解成空数组而不是抛错——
        // 否则一次升级就会让所有历史会议变成「损坏」。
        pauses = try c.decodeIfPresent([PauseSpan].self, forKey: .pauses) ?? []
    }

    // MARK: - 读写

    /// 带毫秒的 ISO8601。默认的 `.iso8601` 策略会丢掉小数秒，
    /// 导致短短几秒的录音在时间跨度上出现可见的取整误差。
    private static let fractionFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionFormatter.string(from: date))
        }
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = fractionFormatter.date(from: text) { return date }
            // 兼容不带小数秒的旧格式
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "无法解析时间戳：\(text)")
        }
        return d
    }

    public func write(to url: URL) throws {
        do {
            let data = try Self.makeEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            throw MRError.io(path: url.path, reason: error.localizedDescription)
        }
    }

    public static func read(from url: URL) throws -> RecordingManifest {
        do {
            let data = try Data(contentsOf: url)
            return try decode(data, path: url.path)
        } catch let e as MRError {
            throw e
        } catch {
            throw MRError.io(path: url.path, reason: error.localizedDescription)
        }
    }

    /// 直接从内存解一份 manifest。
    ///
    /// 与落盘路径**共用同一个解码器**。测试里要验证「上一版写出的 JSON 还能不能读」，
    /// 如果测试自己拼一个 `JSONDecoder`，验的就是测试的解码器而不是产品的那一个。
    static func decode(_ data: Data, path: String) throws -> RecordingManifest {
        do {
            return try makeDecoder().decode(RecordingManifest.self, from: data)
        } catch let e as DecodingError {
            throw MRError.io(path: path, reason: "manifest 解析失败：\(describe(e))")
        }
    }

    /// 把 `DecodingError` 压成一句人话。
    ///
    /// 默认的 `"\(error)"` 会连 `UserInfo={NSJSONSerializationErrorIndex=3,
    /// NSDebugDescription=Unexpected character '}' around line 1, column 4.}`
    /// 一起打出来。界面上那是一整面墙，唯一能读懂的信息（"JSON 无效"）被埋在中间，
    /// 用户看到只会觉得程序坏了。这里只留能行动的部分，并带上出错字段的路径。
    static func describe(_ error: DecodingError) -> String {
        switch error {
        case let .dataCorrupted(context):
            let where_ = pathText(context.codingPath)
            return "JSON 无效或结构不对：\(context.debugDescription)\(where_)"
        case let .keyNotFound(key, context):
            return "缺少字段 `\(key.stringValue)`\(pathText(context.codingPath))"
        case let .typeMismatch(type, context):
            return "字段类型不对，期望 \(type)\(pathText(context.codingPath))"
        case let .valueNotFound(type, context):
            return "字段值为空，期望 \(type)\(pathText(context.codingPath))"
        @unknown default:
            return "\(error)"
        }
    }

    private static func pathText(_ path: [CodingKey]) -> String {
        guard !path.isEmpty else { return "" }
        return "（位置：\(path.map(\.stringValue).joined(separator: "."))）"
    }

    public mutating func addNote(_ note: String) {
        notes.append(note)
    }

    public func track(id: String) -> TrackManifest? { tracks.first { $0.id == id } }
}
