import Foundation
import MRCore

/// 按保留策略**自动**执行清理的调度器。
///
/// ## 为什么它单独一层，而不是给 `SessionRetentionCleaner` 加个 `runIfDue()`
///
/// 因为「能不能自动删」这件事的判定与「删什么」的判定必须分开，而且前者更严格：
///
/// 1. **授权与规则分开。** 档位说「按什么规则清」，`autoPruneEnabled` 说「谁去清」。
///    合成一项的后果很具体：用户为了「看看效果」把档位设成 7 天，几周后老录音
///    自动消失，而他唯一做过的动作是选了个下拉框。
/// 2. **每天至多一次。** 触发点有好几个（启动应用、录完一场、转写完成），
///    没有「今天跑过了吗」这道闸，每转写一场就会扫一遍全库并可能删东西，
///    而用户对「为什么这时又少了几个文件」毫无预期。
/// 3. **坏档位时不仅要拒绝删，还要说明为什么拒绝。** 与手动路径同一条纪律，
///    但自动路径更需要：没人点确认时，静默什么都不做会被读成「功能坏了」。
///
/// ## 它**不做**什么
///
/// 不决定删哪些文件——那是 `SessionRetentionCleaner.plan` 的事，且判据一条不改。
/// 本层只回答「现在该不该跑」。两套判据并存是不可能的：一旦这里自己判一遍年龄，
/// 它就会与清理器的判法漂移，而漂移的方向是「多删」。
public struct RetentionAutoPruner {

    /// 本地时区下的 `yyyy-MM-dd`。格式与 `RecorderPreferences.dayStamp` 同源，
    /// 这里只做一次转换，好让「今天」在同一天内取值恒定。
    public static func todayStamp(now: Date = Date(),
                                  calendar: Calendar = .current) -> String {
        RecorderPreferences.dayStamp(for: now, calendar: calendar)
    }

    /// 本次调度**不做**清理时的原因。**不做事也要能解释自己**——
    /// 这是自动路径与手动路径最大的差别：手动那次用户在场、会追问；
    /// 自动这次用户不在场，沉默会被读成故障。
    public enum SkipReason: Equatable, Sendable {
        /// 开关是关的（默认）。
        case autoPruneDisabled
        /// 档位是「关闭」——它清不了任何东西。
        case policyDeletesNothing(RetentionPolicy)
        /// 偏好里是不认识的档位，**拒绝执行**。与手动路径同一条纪律。
        case unrecognizedPolicy
        /// 今天已经跑过了。
        case alreadyRanToday(String)

        public var message: String {
            switch self {
            case .autoPruneDisabled:
                return "自动清理是关的（默认）。要开请在状态栏菜单里打开。"
            case .policyDeletesNothing(let policy):
                return "保留档位是「\(policy.displayName)」，不会删任何东西，所以不触发清理。"
            case .unrecognizedPolicy:
                return "设置里的保留档位是认识不了的值，**已拒绝执行**（一个文件都没删）。"
                    + "请先 `config set retention <档位>`。"
            case .alreadyRanToday(let day):
                return "今天（\(day)）已经自动清理过一次了，每天至多一次。"
            }
        }
    }

    /// 一次调度尝试的结果。
    public struct Attempt: Equatable, Sendable {
        public var didRun: Bool
        public var skipReason: SkipReason?
        /// 只在 `didRun == true` 时有值。
        public var outcome: SessionRetentionCleaner.Outcome?

        /// 用户该看到的一句话。**没清理也要有话说**，见 `SkipReason` 的说明。
        public var summary: String {
            guard !didRun, let reason = skipReason else { return "" }
            return reason.message
        }
    }

    public let cleaner: SessionRetentionCleaner
    private let preferences: RecorderPreferences
    private let now: () -> Date
    private let calendar: Calendar

    public init(cleaner: SessionRetentionCleaner,
                preferences: RecorderPreferences,
                now: @escaping () -> Date = { Date() },
                calendar: Calendar = .current) {
        self.cleaner = cleaner
        self.preferences = preferences
        self.now = now
        self.calendar = calendar
    }

    /// 现在该不该自动清理。**判据是纯的**，便于把每条边界都钉住。
    ///
    /// - Returns: `nil` 表示可以执行；非 nil 表示跳过，`reason` 说清为什么。
    public static func skipReason(
        autoPruneEnabled: Bool,
        policy: RetentionPolicy?,
        hasUnrecognizedPolicy: Bool,
        lastRunDay: String?,
        today: String
    ) -> SkipReason? {
        // 顺序即优先级，从「用户的显式选择」排到「防重复」。
        // 授权排第一：开关关着时，其余理由都是内部状态，不该出现在用户面前。
        guard autoPruneEnabled else { return .autoPruneDisabled }
        // 坏键先于档位读：它是「配置坏了」，而不是「配置没设」。
        // 两者在界面上都能表现为「没清」，但只有前者需要用户去修。
        if hasUnrecognizedPolicy { return .unrecognizedPolicy }
        guard let policy else { return .policyDeletesNothing(.off) }
        guard policy.isEnabled else { return .policyDeletesNothing(policy) }
        if lastRunDay == today { return .alreadyRanToday(today) }
        return nil
    }

    /// 跑一次自动清理（至多删一场都不多删）。
    ///
    /// **顺序是刻意的**：先判该不该跑，再跑，跑完**无论删没删到东西**都记今天。
    /// 最后半句很重要——今天本来就没有符合档位的会议时，把它记成「跑过了」，
    /// 否则用户新录一场再转写一次，就会在同一天里再触发一轮扫库。
    @discardableResult
    public func runIfDue(includeUntranscribed: Bool = false) -> Attempt {
        let stamp = Self.todayStamp(now: now(), calendar: calendar)
        let reason = Self.skipReason(
            autoPruneEnabled: preferences.autoPruneEnabled,
            policy: preferences.retentionPolicy,
            hasUnrecognizedPolicy: preferences.hasUnrecognizedRetentionPolicy(),
            lastRunDay: preferences.lastAutoPruneDate,
            today: stamp)
        guard let policy = preferences.retentionPolicy, reason == nil else {
            return Attempt(didRun: false,
                           skipReason: reason ?? .unrecognizedPolicy,
                           outcome: nil)
        }
        do {
            let outcome = try cleaner.run(policy: policy,
                                          includeUntranscribed: includeUntranscribed)
            preferences.lastAutoPruneDate = stamp
            return Attempt(didRun: true, skipReason: nil, outcome: outcome)
        } catch {
            // **失败不写「今天跑过了」。** 下次触发点还会再试一次；
            // 若在这里写上，用户会以为跑过了，而实际上什么都没清，
            // 且此后当天再也不重试——那正是「静默失败」的一种。
            return Attempt(didRun: false, skipReason: .autoPruneDisabled, outcome: nil)
        }
    }

    /// 跑完之后给用户看的一句话。**删到东西与没删到，说法必须不同。**
    ///
    /// 「今天清理了 3 场」和「今天没有需要清理的会议」在界面上长得一样，
    /// 用户会以为第二次没生效。
    public static func report(for attempt: Attempt) -> String? {
        if !attempt.didRun { return attempt.summary }
        guard let outcome = attempt.outcome else { return nil }
        if outcome.deleted.isEmpty {
            return "按当前档位，今天没有需要清理的旧音频。"
        }
        let sessions = outcome.deleted.count
        return "已按保留策略清理 \(sessions) 场旧录音的音频（转写稿保留），"
            + "共腾出约 \(humanSize(outcome.freedBytes))。删除走废纸篓，清空后不可恢复。"
    }

    public static func humanSize(_ bytes: Int) -> String {
        let mib = Double(bytes) / 1_048_576
        return mib >= 1024
            ? String(format: "%.2f GiB", mib / 1024)
            : String(format: "%.1f MiB", mib)
    }
}