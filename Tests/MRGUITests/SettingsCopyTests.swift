import XCTest
import MRCore
@testable import MRGUI

/// 设置文案的**排版纪律**：常驻说明一行读完，长解释收进「说明」。
///
/// ## 这一组守的是什么
///
/// 2026-10-22 收到的评价是「说明文案杂乱成堆不简洁清晰」。查下来是两件事：
///
/// 1. **每一行都塞一整段**（七八十字、三四行），一屏五六行，眼睛找不到落点；
/// 2. 这些段子还挂在 **hover 浮层**上，一悬停就盖住下面的设置项。
///
/// 改法是把文案劈成两半：`oneLine`（常驻、一行、进字数预算）与
/// `details`（点「说明」就地展开）。这一组钉住的是**第一条**——
/// 第二条（菜单里不许有浮层）由 `MenuTooltipPolicyTests` 钉。
///
/// ## 为什么是字数而不是行数
///
/// 「几行」要在真实窗口里量，而量出来的结果依赖字体、缩放、动态字体设置，
/// 写进断言只会天天红。字数（汉字当量）是**排版约束的可测代理**：
/// 620 宽的窗口去掉留白与控件后，一行大约 24 个汉字。超了必然折行。
@MainActor
final class SettingsCopyTests: XCTestCase {

    /// 所有**常驻显示**的一行说明。新增设置项时必须加在这里——
    /// 漏了就等于漏了预算检查，而漏检的那一行正是会折成三行的那一行。
    private var oneLiners: [(name: String, text: String)] {
        [
            ("pcm16", SettingsCopy.pcm16OneLine),
            ("mono24k", SettingsCopy.mono24kOneLine),
            ("downmix", SettingsCopy.downmixOneLine),
            ("engine", SettingsCopy.engineOneLine),
            ("localMinutes", SettingsCopy.localMinutesOneLine),
            ("cloudMinutes", SettingsCopy.cloudMinutesOneLine),
            ("baseURL", SettingsCopy.baseURLOneLine),
            ("modelName", SettingsCopy.modelNameOneLine),
            ("apiKey", SettingsCopy.apiKeyOneLine),
            ("testConnection", SettingsCopy.testConnectionOneLine),
            ("statusIcon(on)", SettingsCopy.statusIconOneLine(showsIcon: true)),
            ("statusIcon(off)", SettingsCopy.statusIconOneLine(showsIcon: false)),
            ("conceal", SettingsCopy.concealOneLine),
        ]
    }

    /// 每一句常驻说明都必须在一行内读完。
    func testEveryOneLinerFitsTheLineBudget() {
        for (name, text) in oneLiners {
            let length = SettingsCopy.visibleLength(text)
            XCTAssertLessThanOrEqual(
                length, SettingsCopy.oneLineBudget,
                "「\(name)」的常驻说明有 \(length) 个汉字当量，超过 \(SettingsCopy.oneLineBudget)：\(text)")
            XCTAssertFalse(text.isEmpty, "「\(name)」的常驻说明不能为空")
        }
    }

    /// 常驻说明只能是**一句话**：不许换行、不许 Markdown 记号。
    ///
    /// `Text` 只认纯文本，`**` 会原样印在界面上（渲染图才能看见的那种错）；
    /// 换行则说明「一句话」这个前提已经不成立，该搬去 `details`。
    ///
    /// 中点分隔（「免费 · 离线 · 不出本机」）是**允许**的：单选行的那两句
    /// 是三个并列属性，用中点比写成一串逗号更好扫读。
    func testOneLinersArePlainSingleSentence() {
        for (name, text) in oneLiners {
            XCTAssertFalse(text.contains("\n"), "「\(name)」的常驻说明不该换行：\(text)")
            XCTAssertFalse(text.contains("**"), "「\(name)」里不许有 Markdown 记号：\(text)")
        }
    }

    /// 长解释确实比常驻说明长——否则「展开」是个空动作，
    /// 用户点开只看到同一句话，会以为按钮坏了。
    func testDetailsAreLongerThanTheirOneLiners() {
        let pairs: [(name: String, oneLine: String, details: String)] = [
            ("pcm16", SettingsCopy.pcm16OneLine, SettingsCopy.pcm16Details),
            ("mono24k", SettingsCopy.mono24kOneLine, SettingsCopy.mono24kDetails),
            ("downmix", SettingsCopy.downmixOneLine,
             SettingsCopy.downmixDetails(.firstChannel,
                                         allCases: MonoDownmixStrategy.allCases)),
            ("engine", SettingsCopy.engineOneLine, SettingsCopy.engineDetails),
            ("baseURL", SettingsCopy.baseURLOneLine, SettingsCopy.baseURLDetails),
            ("modelName", SettingsCopy.modelNameOneLine, SettingsCopy.modelNameDetails),
            ("apiKey", SettingsCopy.apiKeyOneLine, SettingsCopy.apiKeyDetails),
            ("testConnection", SettingsCopy.testConnectionOneLine,
             SettingsCopy.testConnectionDetails),
            ("statusIcon", SettingsCopy.statusIconOneLine(showsIcon: true),
             SettingsCopy.statusIconDetails),
            ("conceal", SettingsCopy.concealOneLine, SettingsCopy.concealDetails),
        ]
        for (name, oneLine, details) in pairs {
            XCTAssertGreaterThan(
                SettingsCopy.visibleLength(details),
                SettingsCopy.visibleLength(oneLine) * 2,
                "「\(name)」的展开说明不比常驻那一句长多少，「说明」按钮等于没用")
        }
    }

    /// 一条说明只能有**一个出处**。
    ///
    /// 这条挡的是「同一个开关在三个界面各写一段」的老毛病：那种漂移在编译期
    /// 完全合法，只有用户读到两份不一致的说法时才会发现。
    func testStatusIconCopyHasASingleSource() {
        XCTAssertEqual(
            StatusItemController.statusIconHelp, SettingsCopy.statusIconDetails,
            "状态栏与设置窗口必须引用同一份「隐藏图标」说明")
    }
}
