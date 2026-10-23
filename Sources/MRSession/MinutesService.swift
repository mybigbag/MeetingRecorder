import Foundation
import MRCore
import MRMinutes

/// 会议纪要的落盘与编排衔接层。
///
/// 这一层把纯逻辑的 `MinutesOrchestrator` 接到项目真实的存储布局上：
/// 读 `transcript.json` → 生成纪要 → 写 `minutes.md` / `minutes.json`。
///
/// 它刻意不知道「用的是哪个模型」——模型藏在 `MinutesGenerator` 协议后面。
/// 本地 FoundationModels 不可用（设备或设置不支持）时，`MinutesOrchestrator`
/// 会抛 `MinutesError.modelUnavailable`，这里**捕获后走降级**：写一份只含原稿、
/// 明确标注「未生成摘要」的纪要文件。**绝不假装生成**，这是项目反复强调的诚实纪律。
public struct MinutesService {

    public struct Outcome {
        public var result: MinutesResult
        public var markdownURL: URL
        public var jsonURL: URL
    }

    public static let minutesMarkdownName = "minutes.md"
    public static let minutesJSONName = "minutes.json"

    public var store: SessionStore
    public var chunker: TranscriptChunker

    public init(store: SessionStore, chunker: TranscriptChunker = TranscriptChunker()) {
        self.store = store
        self.chunker = chunker
    }

    /// 为一场**已转写**的会议生成纪要。
    ///
    /// - Parameters:
    ///   - sessionID: 会话 ID（目录名）
    ///   - generator: 纪要生成器（本地模型、或将来云端实现）
    /// - Returns: 落盘结果
    /// - Throws: 读取/写入失败会上抛；模型相关错误已在此降级处理
    public func generate(
        sessionID: String,
        generator: any MinutesGenerator
    ) async throws -> Outcome {
        let directory = store.directory(forSessionID: sessionID)

        // 必须已有转写稿——纪要层吃的是 TranscriptDocument，不负责录音与转写。
        let jsonURL = directory.appendingPathComponent(SessionStore.transcriptJSONName)
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw MRError.io(
                path: directory.path,
                reason: "尚未转写，无法生成纪要。请先 `transcribe \(sessionID)`。")
        }
        let data = try Data(contentsOf: jsonURL)
        // 必须与转写产出方（Transcript.swift 的 `json()`，使用 `.iso8601`）一致。
        // 否则真实 transcript.json（generatedAt 是 ISO 字符串）会解码失败。
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(TranscriptDocument.self, from: data)

        let orchestrator = MinutesOrchestrator(generator: generator, chunker: chunker)
        let result: MinutesResult
        do {
            result = try await orchestrator.generate(for: document)
        } catch MinutesError.modelUnavailable {
            // 本地模型没就绪（设备不支持 / Apple Intelligence 没开）：
            // 降级为「仅原稿」的诚实纪要。**不假装生成**，这是项目反复强调的纪律。
            result = DegradedMinutes.build(from: document)
        }
        // 其余错误（`apiCall`：网络 / 鉴权 / 限流 / 响应不合法）**上抛，不写文件**。
        // 用户显式选了云端并花了钱，一次 401 如果被降级稿悄悄接住，
        // 看到的会是「这场没有摘要」——一次网络故障就这样伪装成模型判断。

        let markdownURL = directory.appendingPathComponent(Self.minutesMarkdownName)
        let outJSONURL = directory.appendingPathComponent(Self.minutesJSONName)
        try markdown(for: result, sessionID: sessionID, title: document.title)
            .write(to: markdownURL, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(result).write(to: outJSONURL)

        return Outcome(result: result, markdownURL: markdownURL, jsonURL: outJSONURL)
    }

    /// 渲染 `minutes.md`：**纪要在前，原料在后**。
    ///
    /// 旧版把「标点修复正文」放在最前面，等于让读者先滚过整场会议的原文
    /// 才看到结论——而这份文件的唯一用途就是「看结论」。正文留在最后，
    /// 需要核对原话时往下翻即可。
    func markdown(for result: MinutesResult, sessionID: String, title: String) -> String {
        var out = "# 会议纪要：\(title)\n\n"
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        out += "- 会话：`\(sessionID)`\n"
        out += "- 生成：\(fmt.string(from: Date()))\n"
        out += "- 模型：\(Self.modelDescription(result))\n"
        out += "- 分段：\(result.blocks.count) 段\n\n"

        if !result.generatedByModel {
            out += "> ⚠️ 本地纪要模型不可用。以下仅为原始转写稿，标点未经修复，未生成任何摘要或待办。\n\n"
        }

        let m = result.minutes
        out += "## 摘要\n\n\(m.summary.isEmpty ? "（无）" : m.summary)\n\n"

        if !m.topics.isEmpty {
            out += "## 议题\n\n"
            for (i, topic) in m.topics.enumerated() {
                out += "### \(MinutesPlainText.topicHeading(topic, index: i))\n\n"
                if !topic.conclusion.isEmpty {
                    out += "\(MinutesPlainText.topicConclusionLabel)\(topic.conclusion)\n"
                }
                if !topic.details.isEmpty {
                    out += "\n" + topic.details.map { "- \($0)" }.joined(separator: "\n") + "\n"
                }
                out += "\n"
            }
        }

        // 旧纪要只有要点、没有议题（新纪要的 keyPoints 为空），两种都能读。
        if !m.keyPoints.isEmpty {
            out += "## 要点\n\n"
            out += m.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }

        out += "## 决议\n\n"
        out += m.decisions.isEmpty ? "（无）\n" : m.decisions.map { "- \($0)" }.joined(separator: "\n") + "\n"
        out += "\n## 待办\n\n"
        if m.actionItems.isEmpty {
            out += "（无）\n"
        } else {
            // 与界面卡片、「复制纪要」共用同一份渲染（`MinutesPlainText.actionItemLine`）。
            // 三处各写一遍的话，「负责人未指定」迟早会漂成三种说法，
            // 而用户是拿这三份东西互相对照着看的。
            for item in m.actionItems {
                out += "- \(MinutesPlainText.actionItemLine(item))\n"
            }
        }

        if !m.openIssues.isEmpty {
            out += "\n## 未决事项\n\n"
            out += "> 讨论过但没有结论、或需要上级/外部决定的事。**不是已定事项**，不要照着执行。\n\n"
            out += m.openIssues.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }

        // 勘误表：让用户能核对模型到底改了哪些词。
        // 没有这一节，纪要里出现的正确术语就无法与转写稿对上，
        // 用户只会觉得「原文说的是 A，纪要写的是 B」。
        if !result.corrections.isEmpty {
            out += "\n## 转写勘误（\(result.corrections.count) 处）\n\n"
            out += "语音识别错误已按上下文纠正，纪要正文用的是纠正后的写法：\n\n"
            for c in result.corrections {
                let reason = c.reason.isEmpty ? "" : "（\(c.reason)）"
                out += "- `\(c.original)` → `\(c.corrected)`\(reason)\n"
            }
        }

        out += "\n## 原文（标点修复）\n\n"
        out += result.polishedTranscript.isEmpty ? "（无内容）" : result.polishedTranscript
        out += "\n"
        return out
    }

    /// 「模型：」那一行的内容。**写生成器的真名**（`MinutesResult.generatorName`），
    /// 不写死「本地 FoundationModels」——云端接入后，一份纪要必须能自证
    /// 「这是哪台服务、哪个模型产出的」。降级稿显示为降级。
    ///
    /// **降级稿不能报「本地模型」**：那一栏上方刚说过「模型不可用」，
    /// 下面紧跟一句「模型：本地模型」就是自相矛盾——
    /// 读者得到的信息会变成「本地模型跑过了，只是没出摘要」。
    ///
    /// 公开是因为**三处渲染共用这一份判据**：落盘 Markdown、界面卡片、
    /// 复制出去的纯文本。三处各写一遍的话，漂的方向必然是
    /// 「某一处悄悄把降级稿说成了正常稿」——那正是本项目最忌讳的那类谎报。
    public static func modelDescription(_ result: MinutesResult) -> String {
        if result.generatedByModel {
            return result.generatorName.isEmpty ? "本地模型" : result.generatorName
        }
        return "降级（本地模型不可用，未生成摘要）"
    }
}
