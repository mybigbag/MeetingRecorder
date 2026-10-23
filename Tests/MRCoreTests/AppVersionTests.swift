import XCTest
@testable import MRCore

/// 版本号的格式与比较。
///
/// 这一层看起来只是拼字符串，测它是因为版本号**是用户判断「我装的是不是最新的」
/// 的唯一依据**。拼错一段、少一位、时区偏一小时，都不会有编译错误、
/// 也不会崩，只会让用户对着一个看起来正常的数字做错判断——
/// 所以格式本身就得钉在测试里。
final class AppVersionTests: XCTestCase {

    // MARK: - 固定时间点（用固定时区，否则换台机器跑就换一天）

    private func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        // 固定东八区：这条测试不该在 CI 的西半球机器上失败。
        c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar().date(from: DateComponents(
            year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: - 格式

    /// 规则正身：`MAJOR.YYYYMMDD.HHMM`。
    func testFormatsAsMajorDateAndTime() {
        let v = AppVersion.format(timestamp: date(2026, 10, 21, 16, 54), major: 2, calendar: calendar())
        XCTAssertEqual(v, "2.20261021.1654")
    }

    /// 月、日、时、分**必须补零**。不补的话 `2026-1-2 03:04` 会变成 `2.202612.34`，
    /// 读起来像另一个日期，逐段比较也会错（`.34` 与 `.0304` 不是一回事）。
    func testPadsSingleDigitComponents() {
        let v = AppVersion.format(timestamp: date(2026, 1, 2, 3, 4), major: 2, calendar: calendar())
        XCTAssertEqual(v, "2.20260102.0304")
    }

    /// 大版本由调用方给，函数不替用户拍板——「大版本只在我要求时改」。
    func testMajorIsPassedInNotAssumed() {
        let v = AppVersion.format(timestamp: date(2027, 3, 9, 8, 5), major: 3, calendar: calendar())
        XCTAssertEqual(v, "3.20270309.0805")
    }

    /// 构建号与短版本同源、只留数字。
    func testBuildNumberIsDigitsOnlyAndMatchesTheTimestamp() {
        let t = date(2026, 10, 21, 16, 54)
        XCTAssertEqual(AppVersion.buildNumber(timestamp: t, calendar: calendar()), "202610211654")
    }

    /// 三段结构不能漂：多一段少一段，`isNewer` 的逐段比较就换了含义。
    func testVersionHasExactlyThreeSegments() {
        let v = AppVersion.format(timestamp: date(2026, 10, 21, 16, 54), major: 2, calendar: calendar())
        let parts = v.split(separator: ".")
        XCTAssertEqual(parts.count, 3, v)
        XCTAssertEqual(parts[1].count, 8, "日期段必须是 YYYYMMDD：\(v)")
        XCTAssertEqual(parts[2].count, 4, "时刻段必须是 HHMM：\(v)")
    }

    // MARK: - 比较

    func testLaterMinuteIsNewer() {
        XCTAssertTrue(AppVersion.isNewer("2.20261021.1655", than: "2.20261021.1654"))
        XCTAssertFalse(AppVersion.isNewer("2.20261021.1654", than: "2.20261021.1655"))
    }

    func testLaterDayIsNewerEvenWithAnEarlierTime() {
        XCTAssertTrue(AppVersion.isNewer("2.20261022.0900", than: "2.20261021.2359"))
    }

    /// 缺段当 0：`2.0` 比任何带日期的版本都旧。
    func testUndatedLegacyVersionIsOlderThanAnyDatedOne() {
        XCTAssertTrue(AppVersion.isNewer("2.20261021.1654", than: "2.0"))
        XCTAssertFalse(AppVersion.isNewer("2.0", than: "2.20261021.1654"))
    }

    /// 相同版本互不为「更新」——否则重打包会把「变号」当成「有新东西」。
    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(AppVersion.isNewer("2.20261021.1654", than: "2.20261021.1654"))
    }

    /// 「不知道」不能伪装成「更新」：裸二进制（`未知…`）与任何版本比较都必须为 false。
    /// 这条是**方向性**的防线——判成 true 会让用户以为手上这份是最新的。
    func testUnknownVersionIsNeverNewer() {
        XCTAssertFalse(AppVersion.isNewer(AppVersion.unknown, than: "2.20261021.1654"))
        XCTAssertFalse(AppVersion.isNewer("2.20261021.1654", than: AppVersion.unknown))
        XCTAssertFalse(AppVersion.isNewer("", than: ""))
    }

    func testNewerPicksTheLargerOne() {
        XCTAssertEqual(AppVersion.newer("2.20261021.1654", "2.20261020.1000"), "2.20261021.1654")
        XCTAssertEqual(AppVersion.newer("2.20261020.1000", "2.20261021.1654"), "2.20261021.1654")
        // 相等时返回后者（结果一样，关键是别崩、别返回空）
        XCTAssertEqual(AppVersion.newer("2.0", "2.0"), "2.0")
    }

    func testNumericComponentsDropsNonNumericSegments() {
        XCTAssertEqual(AppVersion.numericComponents(of: "2.20261021.1654"), [2, 20261021, 1654])
        XCTAssertEqual(AppVersion.numericComponents(of: "2.0"), [2, 0])
        XCTAssertEqual(AppVersion.numericComponents(of: AppVersion.unknown), [])
    }

    // MARK: - 展示

    func testDisplayAddsAValuePrefixOnly() {
        XCTAssertEqual(AppVersion.display(shortVersion: "2.20261021.1654", build: "202610211654"),
                       "v2.20261021.1654")
    }

    /// 空版本不许渲染成一个孤零零的 `v`。
    func testBlankVersionFallsBackToTheHonestUnknown() {
        XCTAssertEqual(AppVersion.display(shortVersion: "", build: ""), AppVersion.unknown)
        XCTAssertEqual(AppVersion.display(shortVersion: "  ", build: "x"), AppVersion.unknown)
        XCTAssertEqual(AppVersion.diagnosticLine(shortVersion: "", build: "1"), AppVersion.unknown)
    }

    func testDiagnosticLineCarriesTheBuildNumber() {
        XCTAssertEqual(
            AppVersion.diagnosticLine(shortVersion: "2.20261021.1654", build: "202610211654"),
            "v2.20261021.1654（构建 202610211654）")
        // 没有构建号时不留一个空括号
        XCTAssertEqual(AppVersion.diagnosticLine(shortVersion: "2.0", build: ""), "v2.0")
    }

    /// 从 Info.plist 字典里取键；缺失时给空串（由展示层决定怎么兜底）。
    func testReadsKeysFromTheInfoDictionary() {
        let info: [String: Any] = [
            AppVersion.shortVersionKey: "2.20261021.1654",
            AppVersion.buildKey: "202610211654",
        ]
        XCTAssertEqual(AppVersion.shortVersion(from: info), "2.20261021.1654")
        XCTAssertEqual(AppVersion.build(from: info), "202610211654")
        XCTAssertEqual(AppVersion.shortVersion(from: nil), "")
        XCTAssertEqual(AppVersion.build(from: [:]), "")
    }

    // MARK: - 打包清单本身必须合规

    /// 读仓库里真正的 `app/Info.plist`：**版本号格式必须是本规则定义的格式**。
    ///
    /// 这条守的不是逻辑，而是「有人手改了 plist」这种事故——手改出来的
    /// `2.1` 不会让任何测试红，只会让用户的版本判断失去意义。
    func testShippedInfoPlistUsesTheDateBasedVersion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MRCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let plist = root.appendingPathComponent("app/Info.plist")
        let data = try Data(contentsOf: plist)
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
        let info = try XCTUnwrap(obj as? [String: Any])

        let short = AppVersion.shortVersion(from: info)
        let parts = short.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "版本号必须是 MAJOR.YYYYMMDD.HHMM，实际：\(short)")
        guard parts.count == 3 else { return }
        XCTAssertEqual(parts[1].count, 8, short)
        XCTAssertEqual(parts[2].count, 4, short)
        XCTAssertTrue(Int(parts[0]) != nil, "大版本必须是整数：\(short)")

        // 构建号与短版本同源：日期段 + 时刻段拼起来（**不含**大版本，
        // 大版本改了不该让构建号的形状变化）
        let expectedBuild = String(parts[1]) + String(parts[2])
        let build = AppVersion.build(from: info)
        XCTAssertEqual(build, expectedBuild,
                       "构建号应与短版本同源（日期+时刻，纯数字）：\(short) / \(build)")
    }
}
