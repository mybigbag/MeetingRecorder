import Foundation

/// 一条音轨**写进文件**的格式：采样率 + 声道数（位深由 `WAVSampleFormat` 单独表达）。
///
/// 与「源格式」分开成一个类型，是因为它们**含义不同、错配的后果很隐蔽**：
/// - 源格式（设备给的）用来解释采集回调里的交错缓冲区；
/// - 写入格式（这个类型）决定 WAV 头，也决定 `manifest.framesWritten / sampleRate`
///   算出来的时长。
///
/// 两者混用最典型的症状是：文件明明是 24 kHz，manifest 却记 48 kHz，
/// 于是界面上显示的时长只有真实时长的**一半**——而没有任何地方会报错。
public struct TrackWriteFormat: Equatable, Sendable {

    public var sampleRate: Double
    public var channels: Int

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = max(1, sampleRate)
        self.channels = max(1, channels)
    }

    /// 「单声道 + 24 kHz」档的目标采样率。**唯一定义处**。
    ///
    /// 定成常量而不是在各处写 `24000`：这个数会同时出现在格式决策、真机用例断言、
    /// 界面提示文案里，散开写就一定会有一处忘记改。
    ///
    /// 为什么是 24 kHz 而不是 16 kHz：实测两者对转写的影响都是 1100 字差 3 字（99.7%），
    /// 而 24 kHz 的带宽到 12 kHz、留住了齿音与辅音的高频线索，代价只是 16 kHz 方案的 1.5 倍体积。
    public static let mono24kSampleRate: Double = 24000

    /// 由**源格式**与开关推出写入格式。纯函数，所以能被单测钉住——
    /// 「哪个参数决定哪种格式」是本轮唯一会直接改变用户录音文件形态的逻辑。
    ///
    /// 两条规则，各自有明确的理由：
    /// - **不开开关时原样返回**：默认一个字节都不动。省空间这件事必须由用户主动要，
    ///   与 A 档（16 位）同一条纪律——升级一次应用就悄悄换掉用户的录音规格，
    ///   属于「没人发现、发现了也追溯不回来」的改动。
    /// - **不做升采样**：源采样率低于 24 kHz 时保持源率。插值不会凭空造出信息，
    ///   只会让文件变大，且给下游一个「这文件带宽到 12 kHz」的假印象。
    public static func resolve(
        sourceSampleRate: Double,
        sourceChannels: Int,
        mono24k: Bool
    ) -> TrackWriteFormat {
        guard mono24k else {
            return TrackWriteFormat(sampleRate: sourceSampleRate, channels: sourceChannels)
        }
        // 源率非法（<= 0）时按目标率走，不把 0 传下去——
        // `TrackRecorder` 另有一道 guard，但格式决策本身不该产出非法值。
        let rate = sourceSampleRate > 0
            ? min(sourceSampleRate, mono24kSampleRate)
            : mono24kSampleRate
        return TrackWriteFormat(sampleRate: rate, channels: 1)
    }

    /// 详情页那种挤在一行里的地方的短名
    public var displayName: String {
        "\(Int(sampleRate)) Hz · \(channels == 1 ? "单声道" : "\(channels) 声道")"
    }

    /// 「这一轨录成了什么格式」的一句话描述，给录制完成的汇报用。
    ///
    /// **主位永远是写入格式**——用户在「录制完成」时想知道的是**盘上那个文件**长什么样，
    /// 而不是设备给了他什么。源格式只在两者不同时放进括号，因为「降没降」也要一眼看得到。
    ///
    /// 之所以抽成函数而不是在 CLI 里拼字符串：实测踩过一次歧义。原先那行打的是
    /// `TrackStats` 里的**源格式**，于是开了单声道 24 kHz 之后看到「48000Hz 2ch」
    /// 会以为开关没生效，其实盘上已经是 24k 单声道了。这种「数字看着对、含义全错」
    /// 的东西必须有单测钉住。
    public func describe(sourceSampleRate: Double, sourceChannels: Int) -> String {
        guard sourceSampleRate != sampleRate || sourceChannels != channels else {
            return displayName
        }
        return "\(displayName)（源 \(Int(sourceSampleRate)) Hz · \(sourceChannels) 声道）"
    }
}
