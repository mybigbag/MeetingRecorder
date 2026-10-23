import Foundation

/// 转写中间格式。所有引擎（苹果原生 / SenseVoice）都产出这个，
/// 上层（归并、渲染、导出）对它无感知。
public struct TranscriptSegment: Codable, Equatable, Sendable {

    /// 人工修改的痕迹。
    ///
    /// **必须记下来**：语音识别的错字是引擎说的，人工改过的是用户说的，
    /// 两者混在一份稿子里而不留标记，事后没人分得清「这句话到底是谁写的」。
    public enum ManualEdit: String, Codable, Equatable, Sendable {
        /// 人工改写过正文
        case corrected
        /// 人工清空：这一段被从稿子里去掉了（不参与纪要生成）
        case cleared
    }

    /// 相对会话开始的秒数
    public var start: Double
    public var end: Double
    public var text: String
    /// 来自哪条轨：mic / system
    public var track: String
    /// 说话人标签，默认取该轨角色的显示名
    public var speaker: String
    /// 同一时刻对方轨也有内容（双方抢话），归并时标记
    public var overlapping: Bool
    /// 人工修改的痕迹。`nil` = 引擎原始输出，没被动过。
    ///
    /// 是 `Optional` 因此**旧 transcript.json 没有这个键也能解码**
    /// （合成的 `init(from:)` 对 Optional 走 `decodeIfPresent`，
    /// 而带默认值的**非** Optional 属性反而会 `keyNotFound`——
    /// 这一点是加字段时最容易踩的坑）。
    public var manualEdit: ManualEdit?
    /// 引擎**第一次**被人工改写之前的原文。留着的唯一用途是「恢复原文」。
    public var originalText: String?

    public init(
        start: Double, end: Double, text: String, track: String,
        speaker: String, overlapping: Bool = false,
        manualEdit: ManualEdit? = nil, originalText: String? = nil
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.track = track
        self.speaker = speaker
        self.overlapping = overlapping
        self.manualEdit = manualEdit
        self.originalText = originalText
    }

    /// 正文是不是「没有内容」。
    ///
    /// 判据是**去掉空白后为空**，不是 `isEmpty`：清空一段后若只剩用户误打的空格，
    /// 按 `isEmpty` 会把它当成有内容，于是「这一段我明明清掉了」在稿子里仍然占一行。
    public var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct TranscriptDocument: Codable, Equatable, Sendable {

    public static let currentVersion = 1

    public var version: Int
    public var sessionID: String
    public var title: String
    public var language: String
    public var engine: String
    public var generatedAt: Date
    public var segments: [TranscriptSegment]

    public init(
        version: Int = TranscriptDocument.currentVersion,
        sessionID: String,
        title: String,
        language: String,
        engine: String,
        generatedAt: Date = Date(),
        segments: [TranscriptSegment] = []
    ) {
        self.version = version
        self.sessionID = sessionID
        self.title = title
        self.language = language
        self.engine = engine
        self.generatedAt = generatedAt
        self.segments = segments
    }

    /// 把两条轨的转写结果归并成一条时间线。
    ///
    /// 双轨的价值就在这里：**音轨本身即说话人身份**，归并只是按时间排序，
    /// 不需要任何声纹分离。两人同时说话时两条都保留并互相标记。
    public static func merge(
        sessionID: String,
        title: String,
        language: String,
        engine: String,
        tracks: [(track: String, speaker: String, segments: [TranscriptSegment])],
        generatedAt: Date = Date()
    ) -> TranscriptDocument {
        var all: [TranscriptSegment] = []
        for t in tracks {
            for var s in t.segments {
                s.track = t.track
                s.speaker = s.speaker.isEmpty ? t.speaker : s.speaker
                all.append(s)
            }
        }
        all.sort { a, b in
            if a.start != b.start { return a.start < b.start }
            return a.track < b.track
        }

        // 去回声必须排在标记抢话**之前**：被删掉的那一段不该再参与「双方抢话」的
        // 判定，否则一句话和它的回声会互相把对方标成 ⚡，稿子上凭空多出抢话符号。
        all = dropCrossTrackEcho(all)

        // 标记抢话：与「上一条不同轨」的段落时间上有重叠
        for i in all.indices {
            for j in all.indices where j < i && all[j].track != all[i].track {
                if all[i].start < all[j].end && all[j].start < all[i].end {
                    all[i].overlapping = true
                    all[j].overlapping = true
                }
            }
        }

        return TranscriptDocument(
            sessionID: sessionID, title: title, language: language,
            engine: engine, generatedAt: generatedAt, segments: all)
    }

    // MARK: - 人工修改

    /// 人工修改过的段落数（改写 + 清空）。
    public var manualEditCount: Int {
        segments.filter { $0.manualEdit != nil }.count
    }

    /// 被人工清空的段落数。
    public var clearedCount: Int {
        segments.filter { $0.manualEdit == .cleared }.count
    }

    /// 还有没有「能拿去生成纪要」的内容。
    ///
    /// **不能用 `segments.isEmpty` 代替**：用户可以逐段清空，段数还在、内容全没了。
    /// 那时如果照旧往下跑，模型拿到的是一串只有「我：」「对方：」的空行，
    /// 生成出一份看起来正常、其实什么都没说的纪要。
    public var hasSpeakableText: Bool {
        segments.contains { !$0.isBlank }
    }

    /// 改写某一段的正文。返回 `nil` 表示**什么都没变**（下标越界，或内容与当前一致）。
    ///
    /// 返回 `nil` 时调用方不该落盘——按一次方向键就重写一遍 transcript.json
    /// 是纯粹的磁盘噪音。
    ///
    /// ## 两条隐藏规则
    ///
    /// 1. **原文只在第一次修改时留存**。连续改三次，`originalText` 仍是引擎那一份；
    ///    每次都覆盖的话，「恢复原文」就变成了「恢复上一步」，而用户点它是想回到
    ///    识别结果本身。
    /// 2. **改回与原文一致时清掉修改痕迹**。稿子回到原样，却还挂着「已修改」标记，
    ///    下次重新转写时会被当成「有改动，要不要确认覆盖」——一个假的改动标记
    ///    会让人以为自己的东西随时会被冲掉。
    public func settingText(_ text: String, at index: Int) -> TranscriptDocument? {
        guard segments.indices.contains(index) else { return nil }
        let current = segments[index]
        if current.text == text { return nil }

        var copy = self
        var seg = current
        // 先留存原文，再覆盖正文——顺序反了就没有「原文」可留。
        if seg.originalText == nil { seg.originalText = current.text }
        seg.text = text

        if seg.isBlank {
            seg.manualEdit = .cleared
        } else if let original = seg.originalText, original == text {
            // 改回去了，等于没改过。
            seg.manualEdit = nil
            seg.originalText = nil
        } else {
            seg.manualEdit = .corrected
        }

        copy.segments[index] = seg
        return copy
    }

    /// 清空某一段（正文置空，段落本身留着）。
    public func clearingText(at index: Int) -> TranscriptDocument? {
        settingText("", at: index)
    }

    /// 恢复某一段的引擎原文。没有原文可恢复时返回 `nil`。
    public func restoringOriginalText(at index: Int) -> TranscriptDocument? {
        guard segments.indices.contains(index),
              let original = segments[index].originalText else { return nil }
        return settingText(original, at: index)
    }

    /// 「说话人：正文」逐行渲染，**跳过正文为空的段落**。
    ///
    /// 渲染成 `我：` 的空行是纯噪音：模型看到一串空说话人标签，
    /// 只能猜「这里是不是有人说了什么」。清空的意义就是不进纪要。
    ///
    /// 三处共用这一个函数（分块、降级稿、纯文本导出）——各写一遍的话，
    /// 「清空的段到底算不算内容」会有三种答案。
    public static func dialogueText(_ segments: [TranscriptSegment]) -> String {
        segments.filter { !$0.isBlank }
            .map { "\($0.speaker)：\($0.text)" }
            .joined(separator: "\n")
    }

    // MARK: - 跨轨回声去重

    /// 判定「跨轨重复」的门槛。
    ///
    /// 集中成常量而不是散在函数体里：测试直接引用它们，改一个数的时候
    /// 不会出现「代码改了、用例里的期望值没改」的那种假绿。
    public enum EchoRule {
        /// 归一化后至少这么长才参与去重。
        ///
        /// 短句不去重是刻意的。「嗯」「对」「好的」两个人同时说是常事，
        /// 那是真实的双方发声，不是回声。宁可留着一句重复，也不能删掉一句真话。
        public static let minimumLength = 6
        /// 时间窗重叠占**较短那段**的比例下限。
        ///
        /// 用「占较短那段」而不是「占任一段」：一句 30 秒的话和它 3 秒的残片
        /// 不该被判成重复，而回声的时长几乎和原声一样。
        public static let overlapRatio = 0.5
        /// 文本相似度下限（字符二元组 Dice 系数）
        public static let similarity = 0.75
        /// 两条起点相差小于这个值就分不出先后，此时改按轨别裁决
        public static let startTolerance = 0.25
        /// 系统轨的标识。分不出先后时保留它（见 `dropCrossTrackEcho` 的说明）
        public static let systemTrackID = "system"
    }

    /// 去掉「同一句话被两条轨各转一遍」的重复。
    ///
    /// **用扬声器开会时的物理链条**：系统音频轨是直接从系统输出抓的数字信号；
    /// 麦克风除了本人，还会收到扬声器放出来的对方声音——那一路是**回声**，
    /// 必然比系统轨晚到，内容几乎一样。两轨各自转写一遍，稿子里同一句话就出现
    /// 两次，一次标「我」一次标「对方」，整份稿子没法读。这正是用户报的第 3 条。
    ///
    /// 三条判据**同时**成立才判为重复，少一条都会误删：
    ///  1. 来自**不同的轨**——同一轨内部的重复是引擎输出噪声，不归这里管；
    ///  2. 时间窗重叠比例 ≥ `EchoRule.overlapRatio`；
    ///  3. 归一化文本相似度 ≥ `EchoRule.similarity`，且长度 ≥ `EchoRule.minimumLength`。
    ///
    /// **保留哪一条：保留先开始的那条。** 回声要走「扬声器 → 空气 → 麦克风」这一段，
    /// 到达必然晚于直接抓取的数字信号，所以先到的那条是原声。
    /// 起点相差小于 `EchoRule.startTolerance` 时先后不可靠，此时保留系统轨——
    /// 数字信号没有房间混响和衰减，是同一句话里更干净的那一份。
    ///
    /// **已知边界，不要装作不存在**：如果会议软件把本人的声音也回放进系统输出（罕见），
    /// 本人说的话会在两轨重复，而这里会保留系统轨、标成「对方」。
    /// 那种情况下两轨本来就都受了污染，没有更好的判据可用。
    ///
    /// - Parameter segments: 已按开始时间排好序的段落
    public static func dropCrossTrackEcho(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var kept: [TranscriptSegment] = []
        for candidate in segments {
            // 裁决是在「候选者 vs 已留下来的某一条」之间做的，所以有两种结局：
            // 候选者输（它不进 kept），或者候选者赢（它进 kept，而输的那条要从
            // kept 里**移除**）。只写前一种是不够的——那样在「系统轨晚到、且起点
            // 分不出先后」时会把两条都留下。
            var loserIndex: Int?
            var candidateLoses = false

            for (index, other) in kept.enumerated() where other.track != candidate.track {
                guard overlapRatio(candidate, other) >= EchoRule.overlapRatio else { continue }
                guard isEchoText(candidate.text, other.text) else { continue }

                if survives(candidate, against: other) {
                    loserIndex = index
                } else {
                    candidateLoses = true
                }
                break
            }

            if let loserIndex { kept.remove(at: loserIndex) }
            if !candidateLoses { kept.append(candidate) }
        }
        return kept
    }

    /// 两者之间留谁：先开始的那个。分不出先后时留系统轨。
    private static func survives(
        _ candidate: TranscriptSegment, against other: TranscriptSegment
    ) -> Bool {
        let gap = candidate.start - other.start
        if abs(gap) >= EchoRule.startTolerance { return gap < 0 }
        return candidate.track == EchoRule.systemTrackID
    }

    /// 两段的时间重叠占**较短那段**的比例（0…1）。
    public static func overlapRatio(_ a: TranscriptSegment, _ b: TranscriptSegment) -> Double {
        let overlap = min(a.end, b.end) - max(a.start, b.start)
        guard overlap > 0 else { return 0 }
        let shorter = min(a.end - a.start, b.end - b.start)
        guard shorter > 0 else { return 1 }
        return min(1, overlap / shorter)
    }

    /// 两句话是不是「同一句」。
    ///
    /// 长度门槛在这一层挡住短应答——见 `EchoRule.minimumLength` 的说明。
    public static func isEchoText(_ a: String, _ b: String) -> Bool {
        let x = normalized(a)
        let y = normalized(b)
        guard x.count >= EchoRule.minimumLength, y.count >= EchoRule.minimumLength else {
            return false
        }
        return textSimilarity(x, y) >= EchoRule.similarity
    }

    /// 归一化：去空白、去标点、转小写。
    ///
    /// 回声那一路经过房间声学，转写结果常差一两个标点或语气词，比的是内容不是排版。
    public static func normalized(_ text: String) -> String {
        let dropped = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return text.lowercased().unicodeScalars
            .filter { !dropped.contains($0) }
            .map(String.init)
            .joined()
    }

    /// 字符二元组上的 Dice 系数（0…1）。
    ///
    /// 用二元组而不是逐字多重集合：后者会把「我明天去」和「去天我明」判成完全一样，
    /// 二元组保住了字序。
    public static func textSimilarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a)
        let y = Array(b)
        guard x.count >= 2, y.count >= 2 else { return 0 }

        var remaining: [String: Int] = [:]
        for i in 0..<(y.count - 1) {
            remaining[String(y[i]) + String(y[i + 1]), default: 0] += 1
        }
        var shared = 0
        for i in 0..<(x.count - 1) {
            let gram = String(x[i]) + String(x[i + 1])
            if let left = remaining[gram], left > 0 {
                shared += 1
                remaining[gram] = left - 1
            }
        }
        return 2.0 * Double(shared) / Double((x.count - 1) + (y.count - 1))
    }

    // MARK: - 渲染

    public func markdown() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# \(title)\n\n"
        out += "- 会话：`\(sessionID)`\n"
        out += "- 时间：\(fmt.string(from: generatedAt))\n"
        out += "- 语言：\(language)　引擎：\(engine)\n"
        out += "- 时长：\(SessionStore.formatDuration(segments.map(\.end).max() ?? 0))　段落：\(segments.count)\n\n"
        out += "> 双轨录制：**我** = 本机麦克风，**对方** = 系统音频输出。\n"
        out += "> 标注 ⚡ 的段落表示双方在同一时间段都有发言。\n"
        // 人工修改必须在文件里留痕。这份 .md 是用户拿去转发的东西，
        // 读的人有权知道哪几句不是引擎听出来的。
        if manualEditCount > 0 {
            let cleared = clearedCount
            out += "> \n> ✍️ 本稿有 \(manualEditCount) 段人工修改"
            out += cleared > 0 ? "（其中 \(cleared) 段已清空，不参与纪要生成）。\n" : "。\n"
        }
        out += "\n---\n\n"

        if segments.isEmpty {
            out += "_（没有识别到任何语音内容）_\n"
            return out
        }

        var lastSpeaker = ""
        for s in segments {
            let stamp = Self.timestamp(s.start)
            let marker = s.overlapping ? " ⚡" : ""
            if s.speaker != lastSpeaker {
                out += "\n**\(s.speaker)**\(marker)\n\n"
                lastSpeaker = s.speaker
            }
            // 清空的段落也留一行，但写明「已清空」而不是留白。
            // 留白读起来像「这句话没转出来」，而事实是「这里原来有内容、被删掉了」——
            // 两种情况的处理方式完全不同（前者要重转，后者不用）。
            out += "`\(stamp)`\(marker) \(s.isBlank ? "（已人工清空）" : s.text)\n\n"
        }
        return out
    }

    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    public func json() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    /// 纯文本（便于 grep）。空段落不占行——导出是为了搜内容，空行只会碍事。
    public func plainText() -> String {
        Self.dialogueText(segments)
    }
}
