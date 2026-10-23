import Foundation

/// 应用版本号：**读运行时 bundle，不写死常量**。
///
/// ## 编号规则（2026-10-21 定）
///
///     MAJOR.YYYYMMDD.HHMM      例：2.20261021.1654
///
/// - 第一段是主线（大）版本，**只在明确要求时才改**；
/// - 第二段是这次修改**完成的日期**，第三段是**完成的时刻**。
///
/// 为什么小版本用时间而不是 `+1` 递增：这台机器上只有一份包在跑，
/// 「我看到的是不是最新的」只能靠时间回答。`2.0.7` 既不说明它比 `2.0.6` 新多少，
/// 也不说明两次之间隔了哪些改动；时间戳可以和文件修改时间、和对话记录直接对上。
///
/// 写进 `Info.plist` 的时机是**打包**（`scripts/bump-version.sh` 由
/// `scripts/build-app.sh` 自动调用，取源码里最新的修改时间）。所以版本号是
/// 「这份二进制对应的代码最后一次改动是什么时候」，重打包同一份代码**不会**变号——
/// 这一点很重要：版本号变了就一定是代码变了，用户不需要去猜。
public enum AppVersion {

    /// `Info.plist` 里给人看的那一项。
    public static let shortVersionKey = "CFBundleShortVersionString"
    /// `Info.plist` 里的构建号（这里用同一个时间戳的纯数字形式）。
    public static let buildKey = "CFBundleVersion"

    /// 拿不到 bundle 版本时的说法。
    ///
    /// 裸二进制（`.build/debug/meeting-recorder` 直接跑）没有 `Info.plist`。
    /// 这里**必须说实话**，不能回退成某个看起来正常的版本号——
    /// 版本号撒谎比没有版本号更糟：用户会拿它去判断「我装的是不是新的」。
    public static let unknown = "未知（裸二进制，未经打包）"

    // MARK: - 运行时读取

    /// 当前运行的可执行文件所属 bundle 的短版本号。
    public static func current(in bundle: Bundle = .main) -> String {
        shortVersion(from: bundle.infoDictionary)
    }

    /// 当前构建号。
    public static func buildNumber(in bundle: Bundle = .main) -> String {
        build(from: bundle.infoDictionary)
    }

    /// 一行版本文案：`v2.20261021.1654`。
    public static func display(in bundle: Bundle = .main) -> String {
        display(shortVersion: shortVersion(from: bundle.infoDictionary),
                build: build(from: bundle.infoDictionary))
    }

    /// 诊断用：`v2.20261021.1654（构建 202610211654）`。
    public static func diagnosticLine(in bundle: Bundle = .main) -> String {
        diagnosticLine(shortVersion: shortVersion(from: bundle.infoDictionary),
                       build: build(from: bundle.infoDictionary))
    }

    // MARK: - 纯逻辑（这些才是被测的部分）

    /// 从 `Info.plist` 字典里取短版本号；缺失或空白一律给 `unknown`。
    public static func shortVersion(from info: [String: Any]?) -> String {
        trimmed(info?[shortVersionKey])
    }

    public static func build(from info: [String: Any]?) -> String {
        trimmed(info?[buildKey])
    }

    /// 拼版本文案。空串按「未知」处理，不留一个只有 `v` 的孤零零的标签。
    public static func display(shortVersion: String, build: String) -> String {
        let v = shortVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return unknown }
        return "v" + v
    }

    public static func diagnosticLine(shortVersion: String, build: String) -> String {
        let v = shortVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = build.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return unknown }
        return b.isEmpty ? "v\(v)" : "v\(v)（构建 \(b)）"
    }

    /// 把时间点格式化成版本号：`2.20261021.1654`。
    ///
    /// `calendar` 可注入，测试里给一个固定时区才有确定性——
    /// 用 `.current` 写测试，跑在别的时区就会差一天，那种失败最费时间。
    public static func format(timestamp: Date, major: Int, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: timestamp)
        return String(format: "%d.%04d%02d%02d.%02d%02d",
                      major,
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0)
    }

    /// 构建号：与短版本同源，但只留数字（`202610211654`）。
    ///
    /// 用数字而不是再拼一遍点分字符串：有些工具会把构建号当整数比较，
    /// 带点的字符串在那条路上会解析失败。
    public static func buildNumber(timestamp: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: timestamp)
        return String(format: "%04d%02d%02d%02d%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// 版本号的数字段。非数字段丢掉，全部拿不到时返回空数组。
    public static func numericComponents(of version: String) -> [Int] {
        version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: true)
            .map { Int($0) }
            .compactMap { $0 }
    }

    /// `lhs` 是否比 `rhs` 新。
    ///
    /// 逐段比较、缺段当 0，所以 `2.0` < `2.20261021.1654` 成立。
    /// **任一侧解析不出数字就返回 false**（「不知道」不能伪装成「更新」）——
    /// 裸二进制（`未知`）与任何真实版本比都必须判「不比它新」。
    public static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = numericComponents(of: lhs)
        let b = numericComponents(of: rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 两组版本里较新的那个。用于「取源码时间戳与已写版本中较大者」，
    /// 让同一次改动重跑打包时版本号**不跳变**。
    public static func newer(_ lhs: String, _ rhs: String) -> String {
        if isNewer(lhs, than: rhs) { return lhs }
        if isNewer(rhs, than: lhs) { return rhs }
        return rhs
    }

    private static func trimmed(_ raw: Any?) -> String {
        guard let s = raw as? String else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
