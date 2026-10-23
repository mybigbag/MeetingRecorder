import Foundation

/// 录音保留策略：**多久之前的音频可以删掉，只留转写稿**。
///
/// ## 这一档与 A / B / C / E 的性质差别
///
/// 那四档都是**压缩**：同一份内容占更小空间，音频还在、能回听，而且可逆
/// （格式信息都在 manifest 里，转回去即可）。
///
/// 这一档是**删除**。音频不存在了，而且：
///
/// - 做错的后果**听不出来**——界面上它只是「这一场没有音轨」，
///   可能几周后才发现某场会的录音没了；
/// - 不可逆——除了系统废纸篓，没有第二个找回入口。
///
/// 所以下面每一个默认值、每一条判据都倒向同一件事：**宁可少删，绝不误删。**
/// 这也是它默认关闭、且「设置档位」与「执行清理」刻意分成两个动作的原因
/// （后者见 `SessionRetentionCleaner`）。
public enum RetentionPolicy: Equatable, Hashable, Sendable {

    /// 什么都不删。**默认值。**
    ///
    /// 「永久保留」是这一档的**别名而不是另一档**：见 `selectableCases` 的说明。
    case off
    /// 超过这个天数前开始的会议，其音频可被清理。
    case days(Int)

    // MARK: - 档位集合

    /// 产品拍板的档位集合：关闭 / 7 / 30 / 90（2026-10-09 定稿）。
    ///
    /// ## 为什么「永久保留」不是一个独立档位
    ///
    /// 它与 `.off` 的清理结果**逐位相同**：`selects` 返回同一个 `false`，
    /// `isEnabled` 都是 `false`，`prune` 遇到它们都在执行前拒绝。
    /// 两个效果完全一样的选项并排摆在菜单里，用户只会推断出「它们之间有区别」，
    /// 然后花时间去猜是哪一种区别——而界面上 nowhere 有答案。
    ///
    /// 所以合并成一项，标题写「关闭（永久保留）」：想要「永久保留」这个语义的用户
    /// 在标题里就能看到，而落盘的 `keep` 仍然解析得到 `.off`，不会让旧偏好报错。
    ///
    /// 顺序即界面与 CLI 的展示顺序。
    public static let selectableCases: [RetentionPolicy] = [
        .off, .days(7), .days(30), .days(90)
    ]

    /// 三个可选天数。**只有这三个值是合法的 `days`**——
    /// 档位是有限集合而不是任意天数，因为每一档都要在界面上写清代价说明，
    /// 而「无级天数」意味着用户能组合出没人预想过的情况。
    public static let selectableDayCounts = [7, 30, 90]

    /// 「永久保留」一族的别名。**解析得到 `.off`，不是独立档位。**
    ///
    /// 单列出来是因为它们必须**继续被接受**：已经落盘的偏好里可能有这一串，
    /// 报「不认识」会让用户以为自己的设置坏了（而它表达的正是「不删」，
    /// 与 `.off` 是同一件事）。
    public static let foreverAliases = [
        "keep", "forever", "keep-forever", "keepforever",
        "永久", "永久保留", "保留全部", "永不删",
    ]

    /// 落盘与 CLI 用的名字。
    public var rawValue: String {
        switch self {
        case .off: return "off"
        case .days(let d): return String(d)
        }
    }

    public var displayName: String {
        switch self {
        // 括号里那半句是给「想永久保留」的人看的——见 selectableCases 的说明。
        case .off: return "关闭（永久保留）"
        case .days(let d): return "\(d) 天"
        }
    }

    /// 这条档位会不会主动删任何东西。
    public var isEnabled: Bool {
        switch self {
        case .off: return false
        case .days: return true
        }
    }

    // MARK: - 说明文案

    /// 单个档位的说明。**CLI 提示用它**（`mr retain --help` / 交互式清理）。
    ///
    /// 2026-10-22 起 GUI 菜单项不再挂这段文字：菜单里一悬停就弹浮层，
    /// 会盖住下面的条目（用户反馈原话）。图形界面上讲代价的地方是
    /// 「按下确认之前」那个弹窗（`retentionConfirmationText`），
    /// 那里带着场次数、体积与废纸篓去向——比一段静态说明更有用。
    ///
    /// 每一条都必须把「不可恢复」说出来——用户按下确认时看到的最后一句话
    /// 应当是这个事实，而不是「确定要继续吗」。
    public var menuHelp: String {
        switch self {
        case .off:
            return "不自动清理任何音频（也就是永久保留）。历史录音会一直留着，占着磁盘。"
                + "选 7 / 30 / 90 天其中一档即开始按年龄清理。"
        case .days(let d):
            return "开始时间早于 \(d) 天前的会议，其音频文件会被移入废纸篓，"
                + "manifest 与转写稿保留。**这一档会删数据，删掉后只能从废纸篓找回。**"
                + "只清理已经转写过的会议——没转写的删了就没有内容了。"
                + "设置档位本身不会立刻删任何东西，要删请用「立即清理」。"
        }
    }

    // MARK: - 解析

    /// 从 `rawValue` 或别名解析。**认不出来就返回 nil，绝不回退到默认档。**
    ///
    /// 与 `TranscriptionEngine` / `MonoDownmixStrategy` 的纪律一致，但这里的理由更硬：
    /// 回退到 `.off` 会让用户以为「我设了一个月」而实际什么都没删；
    /// 回退到 `.days(30)` 更糟——**那会直接开始删文件**。
    ///
    /// 所以 `SessionRetentionCleaner` 读到 nil 时必须拒绝执行，而不是当成关闭。
    public init?(resolving raw: String?) {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        // 精确命中 `rawValue` 就到此为止。**这里必须 `return`**：
        // 少了它会落进下面的别名 switch，而那个 switch 会给同一个值重新判一次
        // （`off` 与天数档都会走一遍，最后可能返回 nil）——
        // 症状是「刚设的档位读回来是 nil」，而且只在部分档位上出现，极难定位。
        if let exact = RetentionPolicy.selectableCases.first(where: { $0.rawValue == key }) {
            self = exact
            return
        }
        // 「永久保留」族 → 关闭。见 selectableCases 的说明：它们是同一个意思。
        if RetentionPolicy.foreverAliases.contains(key) {
            self = .off
            return
        }
        switch key {
        // 关闭
        case "none", "disabled", "关", "不删", "关闭": self = .off
        // 天数：数字与「数字 d」
        default:
            let digits = key.hasSuffix("d") ? String(key.dropLast()) : key
            if let n = Int(digits), RetentionPolicy.selectableDayCounts.contains(n) {
                self = .days(n)
            } else if let n = RetentionPolicy.localizedDayAlias(key) {
                self = .days(n)
            } else {
                return nil
            }
        }
    }

    /// 中文别名（「一周」「一个月」「三个月」）。单独抽出来是因为它们
    /// 在 `resolving` 的 switch 里塞不下一行，而在 CLI 的错误提示里要逐字出现。
    public static func localizedDayAlias(_ raw: String) -> Int? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "一周", "1周", "七天": return 7
        case "一个月", "1个月", "30天": return 30
        case "三个月", "3个月", "一季", "90天": return 90
        default: return nil
        }
    }

    // MARK: - 判定

    /// 这个档位是否把「开始于 `startedAt` 的会议」列入清理。
    ///
    /// - 边界用 **`>=`**（够 N 天就清），不是 `>`。差1 秒的那一场留给用户感知不到，
    ///   而用 `>` 会让「7 天」在整点时刻变成「8 天才清」，用户会以为功能坏了。
    /// - **未来时间（`age < 0`，时钟回拨）永不命中**。往老猜的方向是不对称的：
    ///   猜错只会少删一场（用户无感），猜反会删掉刚录的会议。
    /// - `.off` 返回 false，与年龄无关。
    public func selects(startedAt: Date, now: Date, ageTolerance: TimeInterval = 0) -> Bool {
        guard case .days(let d) = self, d > 0 else { return false }
        let age = now.timeIntervalSince(startedAt) + ageTolerance
        return age >= Double(d) * 86_400
    }
}