import Foundation

/// 会议详情右栏里可折叠的区块。
///
/// **只有一个集合会不够用**：转写稿折了不代表音轨该折——
/// 常见意图恰恰是「纪要留着随时能看，音轨与转写稿收起来」。
/// 把三个区块塞进同一个 Bool，折叠一个就把另外两个也带走，
/// 那不叫折叠，叫连带关闭。
enum DetailSection: String, CaseIterable, Hashable {
    /// 音轨与播放。
    case tracks
    /// 会议纪要。
    case minutes
    /// 转写稿正文。
    case transcript

    /// 打开一场会议时，这一栏**默认是折着的**吗。
    ///
    /// 2026-10-22 起的要求：「打开会议详情，音轨和转写稿默认折叠」。
    /// 理由是这三栏的**打开目的不一样**：
    ///
    /// - 纪要 = 这场会讲了什么 → 打开就要看，必须展开；
    /// - 音轨 = 要听才展开，波形只是占地方（播放控制条本来就不在折叠里）；
    /// - 转写稿 = 几百段的原文，是「核对用的底稿」，不是第一眼要读的东西。
    ///
    /// 反过来（默认全展开）的代价很具体：一场一小时的会议，转写稿几百段，
    /// 用户每次打开都得先滚过整篇原文才看得到纪要——而纪要在最上面，
    /// 于是一打开就被堆到屏外。
    var isCollapsedByDefault: Bool {
        switch self {
        case .minutes: return false
        case .tracks, .transcript: return true
        }
    }
}

/// 哪一场会议的哪个区块被折叠了。
///
/// ## 为什么是「按会议 × 区块」而不是一个 Bool
///
/// 折叠的意图属于「这一场的这一栏」。两个方向都必须是独立的：
///
/// - **按会议**：切到下一场时不该把上一场的折叠意图带走——
///   回来时又得再点一次，正是折叠想省掉的那一下。
///   用全局 `Bool` 的版本还有个更隐蔽的坏处：
///   看完 B 场的纪要、想回头核对 A 场某一句时，发现 A 已经被展开了，
///   于是又滚一遍几百段——折叠反而制造了新的滚动。
/// - **按区块**：见 `DetailSection` 的说明。
///
/// ## 为什么存的是「覆盖值」而不是「折叠集合」
///
/// 有默认折叠的栏之后，「折叠集合」表达不了「用户把它展开了」——
/// 空集合既可能是「没动过」也可能是「全部展开」，两者行为不同。
/// 所以这里存的是**用户显式改过的那些**：没有记录就按
/// `DetailSection.isCollapsedByDefault` 走，有记录按记录走。
///
/// 记录值等于默认值时**立刻删掉**（规范化），于是「点开再点回」
/// 不会留下残留，`overrideCount` 也能当「用户动过几处」读。
struct DetailCollapseState: Equatable {

    /// 一个区块的折叠身份：**哪一场的哪一栏**。
    struct Key: Hashable {
        let sessionID: String
        let section: DetailSection
    }

    /// 用户**显式改过**的 (会议, 区块) → 是否折叠。
    /// 值为 `true` = 用户折起来了，`false` = 用户展开了（覆盖默认折叠）。
    private(set) var overrides: [Key: Bool] = [:]

    init() {}

    /// 这个区块是不是折叠着。
    func isCollapsed(_ section: DetailSection, in sessionID: String) -> Bool {
        overrides[Key(sessionID: sessionID, section: section)]
            ?? section.isCollapsedByDefault
    }

    /// 切换一个区块的折叠状态。
    mutating func toggle(_ section: DetailSection, in sessionID: String) {
        setCollapsed(!isCollapsed(section, in: sessionID), for: section, in: sessionID)
    }

    /// 显式设置折叠状态。批量初始化 / 渲染探针注入时用。
    ///
    /// 不提供的话调用方只能「先 toggle 再判断原来是什么」——那很难读对。
    /// 结果与默认值一致时删除记录（规范化），见类型注释。
    mutating func setCollapsed(_ isCollapsed: Bool,
                                for section: DetailSection,
                                in sessionID: String) {
        let key = Key(sessionID: sessionID, section: section)
        if isCollapsed == section.isCollapsedByDefault {
            overrides.removeValue(forKey: key)
        } else {
            overrides[key] = isCollapsed
        }
    }

    /// 用户显式改过几处。测试与探针读它判断「有没有残留」。
    var overrideCount: Int { overrides.count }
}
