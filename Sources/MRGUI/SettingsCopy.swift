import Foundation
import MRCore

/// 设置文案的**唯一出处**。
///
/// ## 为什么要有这一个文件
///
/// 改动前，同一项设置在三个地方各有各的说法：设置窗口一句、顶栏面板一句、
/// 状态栏菜单一句。三处长短不一、详略不一，用户拿界面当唯一依据，
/// 遇到两种说法时无法判断哪个对。
///
/// 现在每一项只有两个字段：
///
/// - `oneLine` —— **一行读完**的说明，界面常驻显示（不再是 hover 浮层，
///   浮层会盖住下面的设置项）；
/// - `details` —— 长解释（历史沿革、实测数字、边界条件），收进「说明」里
///   就地展开，需要时才占高度。
///
/// 菜单里只放 `oneLine`（菜单项浮层一大坨会挡住选项，而且菜单不是读文档的地方）。
enum SettingsCopy {

    /// 常驻说明的字数上限，按「汉字当量」算（ASCII 记半个）。
    ///
    /// 这个数字不是审美偏好，是**排版约束**：设置窗口宽 580，去掉左右留白与
    /// 尾部控件后一行大约放得下 24 个汉字。超了就折成两行、三行，一屏里几项
    /// 都折行，读起来正是「文案杂乱成堆」。
    ///
    /// 有测试逐条量它（`SettingsCopyTests`）。要写更长的，去 `details`。
    static let oneLineBudget = 24

    /// 一行说明的可见长度（汉字当量）。全角字符记 2、半角记 1，最后除以 2。
    static func visibleLength(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1.isASCII ? 1 : 2) } / 2
    }

    // MARK: - 录音：音频格式

    static let pcm16Title = "16 位整数 PCM"
    static let pcm16OneLine = "体积减半，转写质量几乎无差"
    static let pcm16Details = """
        打开后新录的音频存成 16 位整数 PCM，体积约为现在的一半\
        （双轨合计约 1978 MiB/小时 → 989 MiB/小时）。代价是精度减半：实测对转写结果\
        几乎没有影响，但不是零，而且那次比对用的是外部工具生成的 16 位文件、\
        不是这个开关自己写的（两者都是 16 位量化，量级相同）。默认关闭，用无损的 32 位浮点。
        只影响之后新录的：正在录的这场、以及历史录音都不动——每场按它开始录制时的设置。
        """

    static let mono24kTitle = "单声道 24 kHz"
    static let mono24kOneLine = "体积再降约 2/3，省多少看设备给的格式"
    static let mono24kDetails = """
        打开后新录的音频降成「单声道 + 24 kHz」：系统音频轨合并成单声道，\
        两条轨都降到 24 kHz。体积再降到约 1/3（16 位同时打开时，双轨合计\
        约 989 MiB/小时 → 330 MiB/小时）。
        ⚠️ 省多少取决于麦克风给的格式：上面这些数按「两条轨的源都是 48 kHz」算。\
        有些麦克风（如 AirPods）本身就只给 24 kHz 单声道，那时「我」轨没有采样率与\
        声道可降、只剩位深那一半，整场实测约降到 1/5 而不是 1/6——\
        开完发现没省这么多，是设备如此，不是开关没生效。
        代价是识别质量：实测约 1100 字差 3 个字（99.7%），与位深降级同一量级。
        合并声道的方式由「降混策略」决定，默认只取第 1 声道\
        （本机实测：各声道平均在单边有声时掉 6 dB，反相内容上会整轨抵消成静音）。
        默认关闭。只影响之后新录的：正在录的这场、以及历史录音都不动——\
        每场按它开始录制时的设置。
        """

    static let downmixTitle = "降混策略"
    static let downmixOneLine = "多声道合并成单声道时取哪一路"
    static func downmixDetails(_ strategy: MonoDownmixStrategy,
                               allCases: [MonoDownmixStrategy]) -> String {
        let list = allCases
            .map { "· \($0.displayName)：\($0.menuHelp)" }
            .joined(separator: "\n")
        return """
            只在「单声道 24 kHz」打开、且源本身是多声道时才生效\
            （系统音频轨在本机是 2 声道，所以那条轨会用到）。当前：\(strategy.displayName)。
            \(list)
            """
    }

    // MARK: - 录音：转写

    static let engineTitle = "转写引擎"
    static let engineOneLine = "决定识别质量与速度，改一次长期生效"
    static let engineDetails = """
        苹果原生引擎开机即用、离线、不下载任何模型。SenseVoice 需要先下载模型\
        （在顶栏设置里能看到进度与体积），识别中文口语更稳，首次使用要多一步下载。
        这里改的是全局默认值：之后每一场转写都用它，已转写的历史稿不动。
        """

    // MARK: - 会议纪要

    static let localMinutesTitle = MinutesProvider.local.displayName
    static let localMinutesOneLine = "免费 · 离线 · 转写稿不出本机"
    static let cloudMinutesTitle = MinutesProvider.cloudAPI.displayName
    static let cloudMinutesOneLine = "质量通常更好 · 转写稿会发往你填的服务"

    static let baseURLTitle = "Base URL"
    static let baseURLOneLine = "填到含版本号那一层，例如 …/v1"
    static let baseURLDetails = """
        填到含版本号那一层，**不要带 /chat/completions**——请求时自己会追加。
        例：https://api.deepseek.com/v1
        例：https://api.openai.com/v1
        例：https://dashscope.aliyuncs.com/compatible-mode/v1
        局域网里的服务请填 IP，不要填 localhost：本应用与「测试连接」是同一进程，
        localhost 只在服务跑在本机时才对。
        """

    static let modelNameTitle = "模型名"
    static let modelNameOneLine = "服务端要的模型标识"
    static let modelNameDetails = """
        逐字照服务商文档抄。例：deepseek-chat、gpt-4o-mini、qwen-plus。
        填错时服务端一般回 404 或「model not found」，「测试连接」会把原始报错带回来。
        用「服务商」里的预设按钮可以一次填好地址与模型名（不碰密钥）。
        """

    static let apiKeyTitle = "API Key"
    static let apiKeyOneLine = "只存本机，界面与日志一律打码"
    static let apiKeyDetails = """
        只存在本机偏好域（`mr config show` 里也是打码的），不会写进
        minutes.md / minutes.json，也不会随纪要请求发到别处——它只发给你填的这个服务。
        换服务商时记得同时换 Key：预设只填地址与模型名，不碰密钥。
        """

    static let testConnectionTitle = "测试连接"
    static let testConnectionOneLine = "只发一句固定短句，不发送任何会议内容"
    static let testConnectionDetails = """
        用当前的地址、模型名与 Key 发一句固定的「你好」，看服务端回不回。
        失败时把原始状态码与报错带回来——照着报错改，比猜快：
        401/403 是 Key 不对；404 多半是模型名或地址写错；超时是网络或代理。
        """

    // MARK: - 通用

    static let statusIconTitle = "在菜单栏显示图标"
    static func statusIconOneLine(showsIcon: Bool) -> String {
        showsIcon ? "关闭后菜单栏无图标，录音与快捷键不受影响"
                  : "已隐藏；勾选即恢复（另一个入口是设置窗口 ⌘,）"
    }
    /// 长解释。**两个入口（设置窗口、顶栏面板）与状态栏菜单共用这一份**，
    /// 其中「快捷键不受影响」与「怎么恢复」两件事必须在，否则用户关掉图标会慌。
    static let statusIconDetails = """
        关闭后菜单栏上不再有本应用的图标与菜单。录音不受影响：\
        全局快捷键（⌥⌘R 开始 / ⌥⌘P 暂停 / ⌥⌘S 停止 / ⌥⌘M 显示窗口）与主窗口照常。\
        想恢复：设置窗口（⌘,）或主窗口顶栏「录音设置」，其中都有「菜单栏」这一组。
        """

    static let concealTitle = "录制时隐藏菜单栏迹象"
    static let concealOneLine = "录制期间只留中性波形图标，不显示计时"
    static let concealDetails = """
        打开后，录制期间菜单栏上只留中性的波形图标：不显示计时、不变红、\
        鼠标移上去也不提录制。菜单（就是这里）仍如实显示状态。
        录制中打开它，屏幕上不会有任何反馈——那是这个开关的预期行为。
        """

    // MARK: - 底线说明

    /// 设置窗口底部那一句。只讲**承诺**，不讲实现。
    static let privacyFootnote =
        "密钥只存在本机偏好域：界面、日志、config show 一律打码，"
        + "不会写进 minutes.md / minutes.json，也不会随纪要请求发出去。"
}
