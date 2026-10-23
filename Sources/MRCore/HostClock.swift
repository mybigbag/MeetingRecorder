import Foundation
import Darwin

/// 单调时钟。
///
/// 会议录音的时间基准**只能**用它，绝不能用采样点数推算。
///
/// 依据来自实测：同一段录制里，音频的样本数会与真实时长对不上，且偏差随时长增长
/// （8 秒差 512 帧＝10.7ms，26 秒差 1024 帧＝21.3ms）。
///
/// 但要注意这**不是**时钟漂移。同样是 26 秒，全程静音时两轨差 1024 帧、
/// 全程有声时只差 512 帧——时钟频差不可能因为「有没有声音」而改变。
/// 偏差来自样本交付行为（聚合设备/tap 偶尔少交付 buffer）。
/// 所以时间基准**始终**只能是 `mHostTime`，采样点数仅用来查丢帧。
public enum HostClock {

    /// mach 时间基（numer/denom 决定 1 tick 等于多少纳秒）
    public static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// 每 tick 对应多少纳秒
    public static var nanosecondsPerTick: Double {
        guard timebase.denom != 0 else { return 1 }
        return Double(timebase.numer) / Double(timebase.denom)
    }

    /// 当前 mach 绝对时间（单调，不受系统时钟调整影响）
    public static func now() -> UInt64 { mach_absolute_time() }

    /// mHostTime → 秒（自机器启动起算，只用于做差值）
    public static func seconds(fromHostTime hostTime: UInt64) -> Double {
        Double(hostTime) * nanosecondsPerTick / 1_000_000_000
    }

    /// 两个 hostTime 之间的秒数，自动处理先后顺序
    public static func secondsBetween(_ a: UInt64, _ b: UInt64) -> Double {
        seconds(fromHostTime: a > b ? a - b : b - a)
    }

    /// 带符号差值：a - b（秒）
    public static func signedSeconds(from b: UInt64, to a: UInt64) -> Double {
        a >= b ? secondsBetween(b, a) : -secondsBetween(b, a)
    }
}
