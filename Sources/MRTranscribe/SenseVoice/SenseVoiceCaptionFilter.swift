import Foundation
import MRCore

/// 字幕清洗的结果。
public struct SenseVoiceCaptionCleanup: Equatable, Sendable {
    public var captions: [SenseVoiceCaption]
    /// 纯标点 / 纯空白、**没有任何实义字符**的条目，被丢弃的数量。
    public var droppedEmpty: Int
    /// 实义单元数 ≤ `SenseVoiceCaptionFilter.shortCaptionThreshold` 的条目数量。
    /// **不丢弃**，只计数——见下方说明。
    public var suspiciouslyShort: Int

    public var isEmpty: Bool { captions.isEmpty }
}

/// 段落清洗。
///
/// **只丢「没有任何实义字符」的条目**（`。`、`……` 这种），其余一律保留。
///
/// 为什么不做更激进的「短段丢弃」：真机实测里，非语音段会产生 `I.`、`Yeah。` 这类幻觉，
/// 但它们和真实的 `好`、`嗯`、`对` 在形状上完全一样——长度、时长、置信度都不足以区分。
/// 一个「短于 N 秒就丢」的规则会同时干掉真话和幻觉，而**丢掉用户说过的话**是
/// 比多几条噪声严重得多的错误：噪声用户能一眼看出并忽略，被删掉的那句他永远不会知道。
/// 所以这里只**计数并报出来**，把它做成可见的问题，而不是替用户做决定。
///
/// **「按能量丢」也不行——这条当时只是判断，2026-09-29 量过了，判断成立。**
/// 两场真机录音里各段的 RMS：
///
/// | 来源 | 段 | RMS(dBFS) |
/// |---|---|---|
/// | 无语音录音（70 s）上的幻觉 | `He.` / `い。` / `一。` | **-55.4 / -55.6 / -41.4** |
/// | 真实会议（915.7 s）里最静的真实短句 | `然后。` / `啊。` / `Oh.` / `好。` | **-52.5 / -52.1 / -50.8 / -49.2** |
///
/// 两组**几乎完全重叠**，不存在能把它们分开的阈值。整轨层面才有分离
/// （无语音轨 20 ms 帧中只有 6.1% 高于 -35 dBFS，真实轨是 52%~61%），
/// 但那是**产品行为变更**、不是清洗层的事，且本轮样本只有两场，不足以定阈值——
/// 所以只由 `SenseVoiceInference.shortOnlyNote` 如实**说出来**，不动数据。
public enum SenseVoiceCaptionFilter {

    /// 实义单元数 ≤ 这个值即视为「可疑短段」。
    ///
    /// `好` / `嗯` / `对` 落在这一档，`Yeah。` / `I.` / `Okay.` 也落在这一档——
    /// 正是「无法区分」这件事本身。
    public static let shortCaptionThreshold = 2

    public static func clean(_ captions: [SenseVoiceCaption]) -> SenseVoiceCaptionCleanup {
        var kept: [SenseVoiceCaption] = []
        var dropped = 0
        var short = 0

        for var caption in captions {
            // 解析器已经剥过标签，这里再剥一次是幂等的保险：清洗不假定上游一定做过。
            caption.text = SenseVoiceSRTParser.stripTags(caption.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let units = contentUnitCount(of: caption.text)
            if units == 0 {
                dropped += 1
                continue
            }
            if units <= shortCaptionThreshold { short += 1 }
            kept.append(caption)
        }

        return SenseVoiceCaptionCleanup(
            captions: kept, droppedEmpty: dropped, suspiciouslyShort: short)
    }

    /// 实义**单元**数 = 剔除标点与空白之后，剩下的实义单元个数。
    ///
    /// 单元的口径按文字系统分：
    /// - **连续 ASCII 字母 / 数字算一个单元**（`Yeah` = 1，不是 4；`3 千 5` = 3，因为空格断开）
    /// - 其余每个实义字符各算一个单元（中文一字一单元、`♪` 一单元）
    ///
    /// 为什么要这么分，而不是简单地数字符：SenseVoiceSmall 是**五语种**模型，
    /// 英文稿子与中文稿子混在同一条链路上。只数字符的话，判据在中文上成立
    /// （`好` = 1）而在英文上直接失效——`Yeah` 有 4 个字符，一个词的英文幻觉
    /// 永远不会被计入「可疑短段」，正是最该被看见的那一类。
    /// 按「词 / 字」混合计数，两种语言的判据才对得齐。
    ///
    /// **刻意不把「符号」算作无实义**（`♪`、`€`、`+=` 这类）。理由与整个清洗层一致：
    /// 这里的分界线只划在**一眼可判**的地方。`。` 一定是噪声，`♪` 不一定——
    /// 误删的代价（用户永远不知道少了一句）远高于多留一行的代价。
    /// 所以边界尽量往「保留」一侧靠，把不确定的交给「可疑短段」计数去暴露。
    public static func contentUnitCount(of text: String) -> Int {
        var units = 0
        var insideASCIIWord = false
        for scalar in text.unicodeScalars {
            if CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                insideASCIIWord = false
                continue
            }
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                // 一个 ASCII 词的**首字母**才让计数 +1，后续字母接在同一单元里
                if !insideASCIIWord {
                    units += 1
                    insideASCIIWord = true
                }
            } else {
                units += 1
                insideASCIIWord = false
            }
        }
        return units
    }
}
