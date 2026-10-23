import Foundation

/// 录制结束后的自检：发现「确实录了，但内容是空的」。
///
/// 为什么需要它：系统音频授权未生效时，录制会**正常完成**——时长正确、帧数正确、
/// manifest 写着 `finalized`、退出码 0，只有一个问题：每个采样都是零。
/// 使用者要等到回听、或者转写出空文稿时才会发现，那时会议已经结束了。
///
/// 这类「静默成功」必须在**收尾那一刻**说出来，因为这是唯一还能重录的时机。
///
/// 与 `CaptureReadiness` 的分工：那个管「录之前能不能录」，
/// 这个管「录完之后录到了没有」。两者都不能只验链路，必须验内容。
public enum RecordingSanity {

    public struct Track: Equatable {
        public var id: String
        /// 这一轨是谁。**必须由调用方明确给出**，不许靠 id 字符串去猜。
        ///
        /// 因为两种轨的「全零」含义完全不同、排查方向也不同：系统音频轨可以靠
        /// 自播提示音确诊，麦克风轨不行（详见 `warnings`）。猜错就会给出方向相反的
        /// 建议——这正是本文件曾经犯过的错。
        public var role: TrackRole
        public var frames: Int
        /// 该轨出现过的最大绝对采样值。全零即「录到了，但内容是空的」。
        public var peakAmplitude: Double
        /// 全零的**原因已经查明**（目前只有一种：降混把多声道抵消成了静音）。
        ///
        /// 有它时不再输出「可能是权限未生效」那套猜测——实测踩过：反相内容经
        /// `average` 降混后整轨归零，于是同时收到「抵消告警」与「全零告警」，
        /// 而后者会把人引去查权限（明明权限没问题），白跑一趟 `doctor`。
        ///
        /// 代价也要说清：**全零时无法从产物反推是哪种原因**，所以只能由录制侧
        /// 在现场判定后传进来，而不是事后分析文件。
        public var allZeroCause: AllZeroCause?

        public enum AllZeroCause: String, Equatable, Sendable {
            /// 降混时两声道互相抵消。
            case downmixCancellation
        }

        public init(
            id: String, role: TrackRole, frames: Int, peakAmplitude: Double,
            allZeroCause: AllZeroCause? = nil
        ) {
            self.id = id
            self.role = role
            self.frames = frames
            self.peakAmplitude = peakAmplitude
            self.allZeroCause = allZeroCause
        }

        /// 有帧数，但每个采样都是零。
        ///
        /// 注意零帧**不算**：那属于「根本没采到」，原因与处置都不同。
        public var isAllZero: Bool { frames > 0 && peakAmplitude == 0 }
    }

    /// 逐轨检查，返回可读的告警（空数组 = 一切正常）。
    ///
    /// 判据刻意用「是否全零」而不是「是否够响」：对方只敲键盘也是有效内容，
    /// 不该被判成故障。
    public static func warnings(tracks: [Track]) -> [String] {
        var out: [String] = []
        for t in tracks {
            if t.frames == 0 {
                out.append(
                    "音轨 \(t.id) 没有采到任何音频（一帧都没有）。"
                    + "检查设备是否被切走、以及程序是否有对应权限。")
            } else if t.isAllZero {
                // 原因已查明时**只说那个原因**，不再并列猜测 ——
                // 两条告警指向同一件事，却把排查方向引向两个完全不同的 place，
                // 用户会先去查那个看起来更常见的（权限），白跑一趟。
                if t.allZeroCause == .downmixCancellation {
                    out.append(Self.cancelledByDownmix(t.id))
                } else {
                    out.append(t.role == .systemAudio
                        ? systemTrackAllZero(t.id)
                        : microphoneTrackAllZero(t.id))
                }
            }
        }
        return out
    }

    /// 全零的原因已确诊为「降混抵消」时的文案。
    ///
    /// 刻意**不提权限**：实测反相内容经 `average` 降混后整轨归零，
    /// 同时收到「全零」与「抵消」两条告警，而前者会让人去查权限 ——
    /// 权限明明是好的。指错方向比多报一条更贵。
    private static func cancelledByDownmix(_ id: String) -> String {
        "音轨 \(id) 的采样值**全零**——时长和帧数都正常，但内容是空的。"
        + "原因已查明：多声道在降混时互相抵消了（源各声道都有声音，合并后为零），"
        + "不是权限问题、不必去查「屏幕与系统音频录制」。"
        + "改用只取第 1 声道即可避免：菜单「格式 → 降混策略」，"
        + "或执行 `meeting-recorder config set downmix first-channel`。"
    }

    /// 系统音频轨全零。两种成因（这一段确实没出声 / 权限未生效）数据上无法区分，
    /// 但**提示音能把它俩分开**：喂了声音仍然全零就是权限问题。所以给「跑 doctor」这条路。
    private static func systemTrackAllZero(_ id: String) -> String {
        "音轨 \(id) 的采样值**全零**——时长和帧数都正常，但内容是空的。"
        + "系统音频轨有两种可能：这一整段确实没有系统声音（线下会议、电脑没出声），"
        + "或「屏幕与系统音频录制」权限未生效——两者从录音数据上无法区分。"
        + "跑一次 `doctor` 可以区分：它会主动播一段提示音，喂了声音仍然全零，才是权限问题。"
    }

    /// 麦克风轨全零。**不能照搬系统音频轨那套建议。**
    ///
    /// 麦克风的判据是「人有没有说话」，播提示音替代不了：实测默认输入是 AirPods 时，
    /// 它会切到 24kHz 通话模式并开启回声消除，把系统播放的声音**整段滤掉**——
    /// 链路完全正常也会得到全零。当时那段提示音在系统音频轨上是 0.053 的 RMS，
    /// 在麦克风轨上是 0.000000。所以这里既不给「跑 doctor 确诊」这条错路，
    /// 也不断言麦克风坏了，而是给出唯一可靠的验证方式：说句话再录一次。
    private static func microphoneTrackAllZero(_ id: String) -> String {
        "音轨 \(id) 的采样值**全零**——时长和帧数都正常，但内容是空的。"
        + "麦克风轨有两种可能，从录音数据上无法区分：这一整段你确实没说话，"
        + "或麦克风授权 / 输入设备有问题。"
        + "注意播提示音**不能**用来区分——默认输入若是带回声消除的耳机（如 AirPods），"
        + "系统播放的声音会被它滤掉，链路正常时也照样全零。"
        + "最直接的验证：对着当前默认输入设备说一句话再录 10 秒，看这一段有没有信号。"
        + "若说话也录不到，再到「系统设置 → 隐私与安全性 → 麦克风」确认本 app 已勾选，"
        + "并确认默认输入没有被切到连续互通设备。"
    }
}
