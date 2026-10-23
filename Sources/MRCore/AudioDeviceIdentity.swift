import Foundation

/// 判断两个音频设备的 UID 是否指向**同一台物理设备**。
///
/// **为什么需要它**：macOS 给同一台物理设备的方向各发一个 UID，用 `:input` /
/// `:output` 后缀区分。AirPods 在本机实测为 `AC-90-85-B5-57-20:input` 与
/// `AC-90-85-B5-57-20:output`——同一台设备，两个方向。
///
/// 这件事对「探测麦克风能不能用」是决定性的：当默认输入与默认输出是同一台设备时，
/// 系统会给这条麦克风启用回声消除（AEC），把**本机自己播放的声音**从麦克风信号里
/// 抹掉。而 `doctor` 探测麦克风用的恰好就是一段系统提示音——于是这个探测在原理上
/// 就不成立：它测到的东西与「麦克风能不能录到你」无关。
///
/// 实测（AirPods 同时作输入与输出，同一段提示音）：
/// - 系统音频轨峰值 0.296～0.638
/// - 麦克风轨只剩 0.0005～0.024（被压制 20 dB 以上），其中一次恰好是**全零**
/// - 而同一副 AirPods 录真人说话，麦克风轨峰值 0.263
///
/// 也就是说：共用设备时 `micProbe` 会随机落在「有数据」与「全零」之间，
/// 两者都不代表麦克风的好坏。**一个会自己变来变去的诊断，比一个说
/// 「无法判断」的诊断更糟**——所以要能把它识别出来。
///
/// 这一层是纯字符串逻辑，不碰任何系统 API，因此可以完整单元测试。
public enum AudioDeviceIdentity {

    /// 去掉表示方向的 `:input` / `:output` 后缀，得到物理设备的身份。
    ///
    /// 只认这两个后缀，不能笼统地截到最后一个冒号：UID 里本来就可能含冒号
    /// （如 `AppleUSBAudioEngine:Vendor:Product:1234`），那样会把不同设备
    /// 误判成同一台，进而错误地放弃麦克风轨的探测。
    public static func physicalBase(_ uid: String) -> String {
        let folded = uid.lowercased()
        for suffix in [":input", ":output"] where folded.hasSuffix(suffix) {
            return String(folded.dropLast(suffix.count))
        }
        return folded
    }

    /// 两个 UID 是否指向同一台物理设备。
    ///
    /// 任一为空一律判「不是」：拿不到设备身份时不许凭猜下结论。退回保守口径
    /// （仍按普通设备处理、提示音探测照做），比凭一个空串把它们划成同一台更安全。
    public static func sharesPhysicalDevice(_ a: String, _ b: String) -> Bool {
        let x = physicalBase(a)
        let y = physicalBase(b)
        return !x.isEmpty && x == y
    }
}
