import Foundation

/// 用户可见的偏好设置。
///
/// **只依赖 Foundation**，所以能在无头环境里直接测。
///
/// 落盘用的是**注入进来的 `UserDefaults`**，不是写死 `.standard`。
/// 这不是为了好看：测试必须跑在自己的 suite 里。这条教训来自上一轮状态栏事故——
/// 当时为了「清理残留注册」反复执行 `lsregister -u`，反而给被测的 bundle id
/// 添了一条 `launch-disabled` 状态，**诊断动作本身改变了被测对象**，
/// 后面半小时的观察全建立在被污染的数据上。测试污染比测试缺失更难查。
public struct RecorderPreferences {

    /// 「录制期间在状态栏隐藏录制迹象」的键。
    ///
    /// 单独列成常量，测试要拿它去断言「真的写进去了」，
    /// 而不是靠「读回来是 true」——后者在一个只存在内存里的实现上同样成立。
    public static let hidesStatusBarCountdownKey = "hidesStatusBarCountdown"

    /// 「菜单栏是否显示本应用的图标与菜单」的键。
    ///
    /// 与上面那条的**默认值相反**：这一项默认「显示」。理由很直接——
    /// 关掉它之后，菜单栏上再也没有本应用的痕迹，而「图标怎么没了」
    /// 是这个开关自己造出来的症状。默认显示，这个症状就不会自己出现。
    public static let showsStatusBarIconKey = "showsStatusBarIcon"

    /// 「录音用 16 位整数 PCM」的键。
    public static let pcm16RecordingKey = "pcm16Recording"

    /// 「录音降成单声道 + 24 kHz」的键。
    public static let mono24kRecordingKey = "mono24kRecording"

    /// 「转写用哪个引擎」的键。值取 `TranscriptionEngine.rawValue`。
    ///
    /// 这是**全局**的引擎选择（不是每场会议勾选）：改一次，之后所有 `transcribe` 都听它的。
    public static let transcriptionEngineKey = "transcriptionEngine"

    /// 「录音降混策略」的键。值取 `MonoDownmixStrategy.rawValue`。
    public static let downmixStrategyKey = "downmixStrategy"

    /// 「录音保留策略」的键。值取 `RetentionPolicy.rawValue`。
    public static let retentionPolicyKey = "retentionPolicy"

    /// 「会议纪要用哪个模型层」的键。值取 `MinutesProvider.rawValue`。
    ///
    /// 与 `transcriptionEngine` 同一套纪律：**默认 `.local`**（本地
    /// FoundationModels，录音不出本机）。换云端是隐私决策，必须用户显式配置
    /// 并主动开启，详见 `MinutesProvider`。
    public static let minutesProviderKey = "minutesProvider"

    /// 「云端纪要 API 的 Base URL」的键。形如 `https://api.deepseek.com/v1`。
    ///
    /// 只存「填到含版本号的那一层」，请求时追加 `/chat/completions`。
    /// 空串 / 纯空白视为**未设置**（与「键不存在」等价），便于界面里清空输入框。
    public static let minutesAPIBaseURLKey = "minutesAPIBaseURL"

    /// 「云端纪要 API 的密钥」的键。
    ///
    /// 与 Base URL 同一条存法：空串视为未设置。**任何界面与 `config show`
    /// 都只显示「已设置 / 未设置」，绝不打印明文**——打码逻辑见
    /// `maskedMinutesAPIKey`。
    public static let minutesAPIKeyKey = "minutesAPIKey"

    /// 「云端纪要 API 的模型名」的键。形如 `deepseek-chat` / `glm-5` / `qwen-max`。
    public static let minutesModelKey = "minutesModel"

    /// 「自动清理」的键。
    ///
    /// **默认 `false`**：保留档位只决定「按什么规则清」，什么时候清必须另有一次授权。
    /// 两者绑定在一起的话，用户「试一下 30 天」这个动作会在几周后变成一批录音消失，
    /// 而他从没在那个时刻收到过任何提示。
    public static let autoPruneEnabledKey = "autoPruneEnabled"

    /// 「上次自动清理的日期」的键。值是 `yyyy-MM-dd`（本地时区）。
    ///
    /// 存在的理由是**幂等**：同一天里无论触发几次（启动、录完一场、打开窗口），
    /// 最多只真跑一次清理。少了它，每次转写完成都会扫一遍全库并可能删东西，
    /// 而用户对「为什么这时又少了几个文件」毫无预期。
    public static let lastAutoPruneDateKey = "lastAutoPruneDate"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 录制期间是否在状态栏隐藏「正在录」的迹象（计时、红色圆点、暂停标识、提示语）。
    ///
    /// **默认 `false`，也就是照旧看得见。** 这个默认值是有意选的：
    /// 开关的用途是「不想让别人看到」，不是「不让自己看到」。
    /// 一旦默认打开，忘记录着音的人只会更多——那是个比「被看见」严重得多的后果
    /// （一整场会议没录到，而没有任何地方提示过）。
    ///
    /// 键不存在时 `bool(forKey:)` 返回 `false`，正好等于默认值，
    /// 所以不需要额外 `register(defaults:)`。这条也有测试钉着。
    public var hidesStatusBarCountdown: Bool {
        get { defaults.bool(forKey: Self.hidesStatusBarCountdownKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.hidesStatusBarCountdownKey) }
    }

    /// 菜单栏上是否显示本应用的图标与菜单。**默认 `true`，也就是显示。**
    ///
    /// ## 为什么默认值与「静默录制」相反
    ///
    /// 上面那个开关默认关：它的用途是「不想让别人看见」，默认打开只会让
    /// 忘记自己在录音的人更多。而这一项默认开：关掉它之后菜单栏上**什么都不会剩**，
    /// 「图标不见了」正是这个开关自己要造出来的症状——默认显示，这个症状
    /// 就不会自己出现。用户仍然可以主动关掉它（菜单太挤、不想被同事看见）。
    ///
    /// ## 读法：键缺失时返回 `true`
    ///
    /// `bool(forKey:)` 在键缺失时返回 `false`，正好与这里要的默认值相反，
    /// 所以先问一次 `object(forKey:)`：**读路径不写键**（与
    /// `transcriptionEngine` 同一条纪律——「读一次偏好不该顺手把它写下来」，
    /// 否则「默认值」的断言第二次跑会因为键已存在而不成立）。
    ///
    /// 关掉它**不影响录音本身**：全局快捷键（⌥⌘R / ⌥⌘P / ⌥⌘S / ⌥⌘M）
    /// 与主窗口都不经过状态栏。想恢复：设置窗口（⌘,）或主窗口顶栏「录音设置」。
    public var showsStatusBarIcon: Bool {
        get {
            if defaults.object(forKey: Self.showsStatusBarIconKey) == nil { return true }
            return defaults.bool(forKey: Self.showsStatusBarIconKey)
        }
        nonmutating set { defaults.set(newValue, forKey: Self.showsStatusBarIconKey) }
    }

    /// 录音是否存成 **16 位整数 PCM**（体积约为 32 位浮点的一半）。
    ///
    /// **默认 `false`，也就是照旧 32 位浮点无损录制。**
    ///
    /// 这个默认值比上面那个更硬：打开它会**降低录音精度**。实测（4 条真实录音
    /// 约 1100 字、生产同款转写链路）16 位对识别结果的影响是 1100 字差 1 字，
    /// 但那是这一版测出来的结论，换了引擎就不一定还成立。**升级一次应用就顺手
    /// 把用户的录音质量换掉，是那种「没人发现、发现了也追溯不回来」的改动**——
    /// 被换掉的那批音频已经录完了，没有任何办法补回来。
    ///
    /// 所以省空间这件事必须用户自己点头。开关就摆在开始录制按钮旁边。
    ///
    /// 顺带一个非体积的收益：单个 WAV 的 4 GiB 上限对应的时长会翻倍
    /// （48kHz 立体声 3.11 → 6.22 小时）。
    public var pcm16Recording: Bool {
        get { defaults.bool(forKey: Self.pcm16RecordingKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.pcm16RecordingKey) }
    }

    /// 录音是否存成 **单声道 + 24 kHz**（系统音频轨由立体声合并，两条轨都降到 24 kHz）。
    ///
    /// **默认 `false`，也就是照旧保留源的采样率与声道数。**
    ///
    /// 这个默认值与 `pcm16Recording` 同一条理由，但**更硬**：位深降级影响的是精度，
    /// 而这一项同时改掉**采样率与声道数**——用户拿到的是一副形态不同的录音，
    /// 且已经录完的那些**补不回来**。升级一次应用就顺手把用户的录音规格换掉，
    /// 是那种「没人发现、发现了也追溯不回来」的改动。所以必须用户自己点头。
    ///
    /// 与位深**相互独立**：两者可以自由组合。体积上
    /// 「16 位 + 48 kHz 立体声」约 989 MiB/小时，再叠加本项后约 **330 MiB/小时**（约合现状的 1/6）。
    /// 识别质量上，实测（4 条真实录音约 1100 字、生产同款链路）24 kHz 单声道与
    /// 原格式相差 3 个字（99.7%），与位深降级同一量级。
    public var mono24kRecording: Bool {
        get { defaults.bool(forKey: Self.mono24kRecordingKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.mono24kRecordingKey) }
    }

    /// 转写引擎的**全局**选择。默认 `.apple`（苹果原生）。
    ///
    /// 设计纪律（与「静默录制」「16 位录音」一致）：默认值本身就是规格——
    /// 默认必须是苹果原生（零下载、约 160×、出本机）。任何「我们觉得 SV 更准」
    /// 都不是把默认换掉的借口：升级一次应用就顺手把用户的引擎换掉，被换掉的那批
    /// 会议已经录完了，且 SV 还有英文词 / ITN 退步、242 MB 下载、内存涨到 300~400 MB
    /// 的代价，用户完全不知情。要换，用户自己 `config set engine sensevoice`。
    ///
    /// 读的时候**不写键**：缺失键返回 `.apple`，与「读一次偏好不该顺手把它写下来」
    /// 的纪律一致（否则默认值的断言第二次跑会因为键已存在而不成立）。
    /// 存了一个不认识的引擎名（含旧文档里的 `whisper`）一律回退 `.apple`——
    /// 不能因为读到一个陌生名字就崩，或静默选了更重的引擎。
    public var transcriptionEngine: TranscriptionEngine {
        get { TranscriptionEngine(resolving: defaults.string(forKey: Self.transcriptionEngineKey)) }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.transcriptionEngineKey) }
    }

    /// 由偏好推出该用哪种采样格式。**格式只有一个出处**，避免各调用方自己判一次。
    public var sampleFormat: WAVSampleFormat {
        pcm16Recording ? .pcm16 : .float32
    }

    /// 多声道降成单声道时用哪种策略。
    ///
    /// **默认 `.firstChannel`（只取第 1 声道），不是 `.average`。**
    ///
    /// 这个默认值是**改过的**，原默认是 `average`，依据是本机真机实测的四种工况
    /// （`Tests/MRCoreTests/DownmixStrategyDefaultTests.swift` 里钉着判据）：
    ///
    /// | 源的两声道内容 | `average` | `firstChannel` |
    /// |---|---|---|
    /// | 同相（L = R） | 0.00 dB | 0.00 dB |
    /// | 单边（仅 L 有声） | **−6.02 dB** | 0.00 dB |
    /// | **反相（L = −R）** | **全静音（−∞ dB）** | 0.00 dB |
    /// | 宽立体声（440/880 Hz） | −3.01 dB | 0.00 dB（但丢掉右声道内容） |
    ///
    /// 决定性的是第三行：反相内容（某些播放器/会议软件的输出就是 L = −R）
    /// 经 `average` 会**互相抵消成一条纯静音轨**，而录音仍然「成功」——
    /// 帧数正常、时长正常、manifest 正常，没有任何地方会报错。
    /// 上一轮量到的「平均降混掉 6 dB」只是它的温和版本。
    ///
    /// 代价要说清楚：`firstChannel` 在宽立体声工况下会**丢掉右声道的内容**。
    /// 本机实测的系统音频 tap 在同相与单边两种工况下与 `average` 等价或更好，
    /// 所以这个代价换来的安全性是值得的。**真的需要保留双声道内容时用
    /// `config set downmix average` 切回去**，并且系统会明确告知反相风险。
    ///
    /// 与 `mono24kRecording` 独立：源本来就是单声道时降混根本不发生，这个键无意义；
    /// 但它**不是** `mono24kRecording` 的子开关，两个都可自由设置。
    public var downmixStrategy: MonoDownmixStrategy {
        get {
            // 存了不认识的名字（含旧文档里可能出现的 `average2` 之类）一律回退默认，
            // 与 `transcriptionEngine` 同一纪律：不能因为读到一个陌生值就崩，
            // 更不能静默选一个会丢数据的策略。
            MonoDownmixStrategy(
                resolving: defaults.string(forKey: Self.downmixStrategyKey))
                ?? .firstChannel
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.downmixStrategyKey) }
    }

    /// 录音保留策略：**默认 `.off`，也就是什么都不删。**
    ///
    /// ## 为什么这一项的读法与上面几项不同：返回可选
    ///
    /// `transcriptionEngine` 与 `downmixStrategy` 读到不认识的字符串会回退到默认档，
    /// 那一项读法在这里**是错的**。这一项的回退方向是有代价的：
    ///
    /// - 回退 `.off` → 用户以为「我设了一个月」，实际什么都没删；
    /// - 回退 `.days(30)` → **直接开始删文件**。
    ///
    /// 所以这里**认不出来就返回 nil**，由 `SessionRetentionCleaner` 拒绝执行。
    /// 少删一场用户无感，误删一场没法挽回——这个不对称决定了读法。
    ///
    /// 设置这一项**不会删掉任何东西**，它只决定「什么时候有人来执行清理」。
    /// 真正的清理是一次独立动作（`prune` / 菜单里的「立即清理」）。
    public var retentionPolicy: RetentionPolicy? {
        get { RetentionPolicy(resolving: defaults.string(forKey: Self.retentionPolicyKey)) }
        nonmutating set {
            // 写 `nil` = 移除键（回到「没设置过」，行为上与 `.off` 一样）。
            // 写具体档位（含 `.off`）则真的写下去——这样「用户明确关掉了它」
            // 与「从来没有这个键」在 `config show` 里长得一样，
            // 而这两种情况的处理方式本来就一样——都什么都不删。
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Self.retentionPolicyKey)
            } else {
                defaults.removeObject(forKey: Self.retentionPolicyKey)
            }
        }
    }

    /// 解析得到可执行的档位。`nil` 表示「设置里写的是不认识的值」，
    /// 调用方**必须**拒绝执行而不是当成关闭——见上面那条不对称的说明。
    ///
    /// 键完全不存在时返回 `.off`（首次运行的正常状态）。
    public func resolvedRetentionPolicy() -> RetentionPolicy {
        guard defaults.object(forKey: Self.retentionPolicyKey) != nil else { return .off }
        return retentionPolicy ?? .off
    }

    /// 偏好里存着不认识的档位吗？供 CLI 在执行前明确报错。
    public func hasUnrecognizedRetentionPolicy() -> Bool {
        defaults.object(forKey: Self.retentionPolicyKey) != nil
            && retentionPolicy == nil
    }

    /// 是否在没人手动点的情况下自动清理旧音频。**默认 `false`。**
    ///
    /// 与档位**刻意分开**。档位回答「按什么规则清」，这一项回答「谁去清」；
    /// 前者是规则，后者是一次授权。合成一项的后果很具体：
    /// 用户为了「看看效果」把档位设成 7 天，几周后老录音自动消失，
    /// 而他唯一做过的动作是「选了个下拉框」。
    ///
    /// 键不存在时 `bool(forKey:)` 返回 `false`，正好等于默认值。
    public var autoPruneEnabled: Bool {
        get { defaults.bool(forKey: Self.autoPruneEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.autoPruneEnabledKey) }
    }

    /// 上次自动清理是哪一天（`yyyy-MM-dd`），没跑过是 nil。
    ///
    /// 存**日期字符串**而不是时间戳：这一项只回答「今天跑过没有」，
    /// 存时间戳会诱使调用方去算时长差，而那个差值在本工具里毫无用处。
    public var lastAutoPruneDate: String? {
        get { defaults.string(forKey: Self.lastAutoPruneDateKey) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Self.lastAutoPruneDateKey)
            } else {
                defaults.removeObject(forKey: Self.lastAutoPruneDateKey)
            }
        }
    }

    /// 本地时区下的「今天」，格式 `yyyy-MM-dd`。
    ///
    /// 单独抽出来是因为它有**两个**必须显式做的选择，漏掉任一个都会让
    /// 「今天跑过了吗」在跨时区或改系统语言时给出错误的答案：
    /// locale 必须是 `en_US_POSIX`（否则用哪种数字/年月顺序取决于用户语言），
    /// 时区必须跟随传入的 `calendar`（不能取 `DateFormatter` 的默认系统时区）。
    public static func dayStamp(for date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - 会议纪要（本地 / 云端 API）

    /// 纪要模型层的**全局**选择。默认 `.local`。
    ///
    /// 读的时候**不写键**（与 `transcriptionEngine` 一致）：缺失键返回 `.local`。
    /// 存了不认识的值一律回退 `.local`——绝不能静默选中会把转写稿传出本机的那一档。
    public var minutesProvider: MinutesProvider {
        get { MinutesProvider(resolving: defaults.string(forKey: Self.minutesProviderKey)) }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.minutesProviderKey) }
    }

    /// 云端纪要 API 的 Base URL（已去首尾空白）。未设置 / 空串 → nil。
    public var minutesAPIBaseURL: String? {
        get { Self.nonEmpty(defaults.string(forKey: Self.minutesAPIBaseURLKey)) }
        nonmutating set { Self.store(newValue, forKey: Self.minutesAPIBaseURLKey, in: defaults) }
    }

    /// 云端纪要 API 的密钥。未设置 / 空串 → nil。
    ///
    /// **任何地方都不要把它打印出来**——展示用 `maskedMinutesAPIKey`。
    public var minutesAPIKey: String? {
        get { Self.nonEmpty(defaults.string(forKey: Self.minutesAPIKeyKey)) }
        nonmutating set { Self.store(newValue, forKey: Self.minutesAPIKeyKey, in: defaults) }
    }

    /// 云端纪要 API 的模型名。未设置 / 空串 → nil。
    public var minutesModel: String? {
        get { Self.nonEmpty(defaults.string(forKey: Self.minutesModelKey)) }
        nonmutating set { Self.store(newValue, forKey: Self.minutesModelKey, in: defaults) }
    }

    /// 密钥是否已设置。**只回答「有没有」，不回答「是什么」**——
    /// 界面与 `config show` 都靠它显示「已设置」，从而不必接触明文。
    public var minutesAPIKeyIsSet: Bool {
        minutesAPIKey != nil
    }

    /// 打码后的密钥，供界面与 `config show` 显示。
    ///
    /// 保留头 3 尾 4（`sk-…9f2a`）是为了让用户能认出「是不是那一把」；
    /// 太短的密钥（≤8 字符）干脆全遮——那种长度下保留头尾等于没遮。
    public var maskedMinutesAPIKey: String {
        guard let key = minutesAPIKey else { return "未设置" }
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        let head = key.prefix(3)
        let tail = key.suffix(4)
        return "\(head)…\(tail)（已设置）"
    }

    /// 云端 API 三件套（Base URL / Key / 模型名）是否齐全。
    public var minutesCloudAPIIsComplete: Bool {
        missingMinutesCloudAPIItems().isEmpty
    }

    /// 缺哪些配置项（给人看的名字）。齐全时返回空数组。
    ///
    /// 顺序固定：URL → Key → 模型。报错文案与设置界面的勾选提示共用它，
    /// 避免两边列出不同的清单。名字取自 `MinutesCloudAPIField.displayName`——
    /// 那是显示名的唯一出处。
    public func missingMinutesCloudAPIItems() -> [String] {
        var missing: [String] = []
        if minutesAPIBaseURL == nil { missing.append(MinutesCloudAPIField.baseURL.displayName) }
        if minutesAPIKey == nil { missing.append(MinutesCloudAPIField.apiKey.displayName) }
        if minutesModel == nil { missing.append(MinutesCloudAPIField.model.displayName) }
        return missing
    }

    /// 清空三个云端配置项（`config unset` 用）。幂等——本来没设也不报错。
    public func clearMinutesCloudAPIConfiguration() {
        minutesAPIBaseURL = nil
        minutesAPIKey = nil
        minutesModel = nil
    }

    // MARK: - 内部

    /// 去首尾空白；纯空白 / 空串 → nil。
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 存字符串类配置项：空串 / 纯空白 = 移除键（回到「没设置过」），
    /// 与 `retentionPolicy` 写 nil 同一套语义。界面里清空输入框因此真的能清掉。
    private static func store(_ value: String?, forKey key: String, in defaults: UserDefaults) {
        if let trimmed = nonEmpty(value) {
            defaults.set(trimmed, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
