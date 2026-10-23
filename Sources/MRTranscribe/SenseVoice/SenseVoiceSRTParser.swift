import Foundation

/// 一条 SRT 字幕。
public struct SenseVoiceCaption: Equatable, Sendable {
    /// 归档里的序号。仅用于日志与排序，链路下游不依赖它（重排后会变）。
    public var index: Int
    public var start: Double
    public var end: Double
    public var text: String

    public init(index: Int, start: Double, end: Double, text: String) {
        self.index = index
        self.start = start
        self.end = end
        self.text = text
    }
}

/// 解析结果。**把「丢了多少」带出来**，而不是安静地少几条——
/// 一份看起来完整、实际被解析器吃掉一半段落的稿子，比明确报错危险得多。
public struct SenseVoiceSRTResult: Equatable, Sendable {
    public var captions: [SenseVoiceCaption]
    /// 缺时间码等原因整块跳过的数量
    public var skippedBlocks: Int
    /// 时间码倒挂（`end < start`）被夹正的条数
    public var invertedTimestamps: Int

    public init(captions: [SenseVoiceCaption], skippedBlocks: Int = 0, invertedTimestamps: Int = 0) {
        self.captions = captions
        self.skippedBlocks = skippedBlocks
        self.invertedTimestamps = invertedTimestamps
    }

    public var isEmpty: Bool { captions.isEmpty }
}

/// SenseVoice 运行时 `--srt` 输出的解析。
///
/// 为什么手写而不是上正则：这里要处理的输入是**我们自己的子进程**产生的、
/// 格式极其固定（序号 / `HH:MM:SS,mmm --> HH:MM:SS,mmm` / 文本）的东西。
/// 手写的另一个好处是每个分支都能被单测准确命中，而正则的失败方式通常是
/// 「某些奇怪输入下少匹配一条」——那正是最不该在这里出现的失败方式。
public enum SenseVoiceSRTParser {

    /// 解析 SRT 文本。
    ///
    /// 宽容策略（每条都有对应的测试）：
    /// - 空输入 → 0 条，**不算畸形**（静音时运行时的输出就是 0 字节，这是正常结果）
    /// - 缺时间码的块 → 跳过并计数
    /// - 段号行可有可无（缺了照解析）
    /// - `end < start` → **保留内容**、把 end 夹到 start 并计数。
    ///   时间戳可疑时扔掉内容是最坏的选择：时间戳可以后修，丢掉的话没人知道丢过。
    /// - 返回结果按 `start` 升序
    public static func parse(_ raw: String) -> SenseVoiceSRTResult {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var captions: [SenseVoiceCaption] = []
        var skipped = 0
        var inverted = 0

        for block in blocks(in: normalized) {
            var lines = block
            var declaredIndex: Int?

            if let first = lines.first,
               let parsed = Int(first.trimmingCharacters(in: .whitespaces)) {
                declaredIndex = parsed
                lines.removeFirst()
            }

            guard let timeLine = lines.first,
                  let range = parseTimeRange(timeLine) else {
                skipped += 1
                continue
            }
            lines.removeFirst()

            let start = range.start
            var end = range.end
            if end < start {
                end = start
                inverted += 1
            }

            captions.append(SenseVoiceCaption(
                index: declaredIndex ?? (captions.count + 1),
                start: start,
                end: end,
                text: joinCaptionLines(lines)))
        }

        captions.sort { $0.start < $1.start }
        return SenseVoiceSRTResult(
            captions: captions, skippedBlocks: skipped, invertedTimestamps: inverted)
    }

    // MARK: - 分块

    /// 按空行切块。用「逐行扫描 + 遇空白行收口」而不是 `components(separatedBy: "\n\n")`：
    /// 后者在空行里混了空格 / 制表符时会失效，而那种输入并不罕见。
    private static func blocks(in text: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    result.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: - 时间码

    struct TimeRange: Equatable {
        var start: Double
        var end: Double
    }

    /// 解析 `00:01:07,260 --> 00:01:37,260` 形式的行。
    ///
    /// 分隔符接受 `,` 与 `.`（不同工具的习惯不同）；毫秒位数 1~3 位都能换算——
    /// `,5` 是 0.5 秒而不是 5 毫秒，靠 `Double("07.5")` 这种直读自然得到正确结果。
    static func parseTimeRange(_ line: String) -> TimeRange? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        guard let start = parseTimestamp(parts[0]), let end = parseTimestamp(parts[1]) else {
            return nil
        }
        return TimeRange(start: start, end: end)
    }

    static func parseTimestamp(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let components = cleaned.components(separatedBy: ":")
        guard components.count == 3 else { return nil }
        guard let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]) else { return nil }
        guard hours >= 0, minutes >= 0, seconds >= 0 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    // MARK: - 文本

    /// 把一条字幕的多行文本拼成一行。
    ///
    /// 拼接规则按字符类型走：**中日韩字符之间不插空格，纯 ASCII 之间插一个空格，
    /// 混边界不插**。实测里 SenseVoice 每条只输出一行，所以这条规则在日常输入上是空操作；
    /// 它存在的意义是「万一某天开始折行」时不至于把 `the cat` 拼成 `thecat`，
    /// 也不至于把中文句子插成 `中 文 句 子`。
    static func joinCaptionLines(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            let stripped = stripTags(line).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }
            if result.isEmpty {
                result = stripped
                continue
            }
            if !isCJK(result.unicodeScalars.last) && !isCJK(stripped.unicodeScalars.first) {
                result += " "
            }
            result += stripped
        }
        return result
    }

    /// 剥掉 SenseVoice 的富文本标签（`<|zh|><|NEUTRAL|><|Speech|>` 之类）。
    ///
    /// 默认不带 `--keep-tags`，所以正常情况下看不到它们；但只要有人给运行时加了参数、
    /// 或者上游改了默认值，这些标签就会**直接出现在稿子里**。剥掉是廉价的保险。
    static func stripTags(_ text: String) -> String {
        guard text.contains("<|") else { return text }
        var result = ""
        var remainder = Substring(text)
        while let open = remainder.range(of: "<|") {
            result += remainder[remainder.startIndex..<open.lowerBound]
            let afterOpen = remainder[open.upperBound...]
            if let close = afterOpen.range(of: "|>") {
                remainder = afterOpen[close.upperBound...]
            } else {
                // 只有开标签没有闭标签：**整段丢掉**。
                //
                // 早先这里只 `break`，而循环外还有一句 `result += remainder`，
                // 于是被截断的标签内容又被原样接了回去（`截断的标签<|zh` → `截断的标签zh`）。
                // 那种输入只可能来自输出被截断，把尾巴当正文写进稿子是本末倒置。
                remainder = ""
                break
            }
        }
        result += remainder
        return result
    }

    static func isCJK(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        switch scalar.value {
        case 0x3000...0x303F,      // CJK 标点
             0x3040...0x30FF,      // 平假名 / 片假名
             0x3400...0x4DBF,      // CJK 扩展 A
             0x4E00...0x9FFF,      // CJK 基本区
             0xAC00...0xD7AF,      // 谚文音节
             0xF900...0xFAFF,      // CJK 兼容表意
             0xFF00...0xFFEF:      // 全角形式
            return true
        default:
            return false
        }
    }
}
