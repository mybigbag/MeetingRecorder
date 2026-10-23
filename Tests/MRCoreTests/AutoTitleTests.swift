import XCTest
@testable import MRCore

/// 自动标题：「会议202607271624」。
///
/// 这个格式是给人看的**序号**：列表里一眼分清、按时间排得开。
/// 唯一性不靠它——那是目录名的事（带秒，且同名会追加 `-2`）。
final class AutoTitleTests: XCTestCase {

    /// 固定时区，否则同一份断言会在别的机器上飘
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.date(from: iso)!
    }

    func testStampMatchesTheReadableForm() {
        // 用户给的例子就是这个形状
        let d = date("2026-07-27T16:24:31+08:00")
        XCTAssertEqual(SessionStore.titleStamp(for: d, calendar: calendar), "202607271624")
    }

    func testAutoTitleIsPrefixPlusStamp() {
        let d = date("2026-07-27T16:24:31+08:00")
        XCTAssertEqual(
            SessionStore.autoTitle(base: "会议", date: d, calendar: calendar),
            "会议202607271624")
        XCTAssertEqual(
            SessionStore.autoTitle(base: "产品评审", date: d, calendar: calendar),
            "产品评审202607271624")
    }

    func testEmptyOrBlankBaseFallsBackToDefault() {
        let d = date("2026-07-27T16:24:31+08:00")
        for base in ["", "   ", "\n"] {
            XCTAssertEqual(
                SessionStore.autoTitle(base: base, date: d, calendar: calendar),
                "会议202607271624",
                "前缀是「\(base)」时应当退回默认前缀")
        }
    }

    /// 时区必须跟随日历。
    ///
    /// `DateFormatter` 默认用系统时区，所以「同一时刻在不同时区的机器上」
    /// 会算出不同的小时。会议标题里的时间应当是**用户当地的**那个时间，
    /// 而这件事必须由日历显式带进来，不能靠全局默认值。
    func testStampFollowsCalendarTimeZone() {
        let d = date("2026-07-27T16:24:31+08:00")

        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        XCTAssertEqual(SessionStore.titleStamp(for: d, calendar: calendar), "202607271624")
        XCTAssertEqual(SessionStore.titleStamp(for: d, calendar: tokyo), "202607271724")
    }

    /// 分钟精度：同一分钟内多次调用结果相同，跨分钟才变。
    ///
    /// 这不是瑕疵而是取舍——「分钟」是给人读的序号该有的粒度。
    /// 但**唯一性不能指望它**，所以这里显式钉住这个行为，
    /// 免得以后有人误以为它能当唯一键用。
    func testMinuteGranularityIsDeliberate() {
        let a = date("2026-07-27T16:24:01+08:00")
        let b = date("2026-07-27T16:24:59+08:00")
        let c = date("2026-07-27T16:25:00+08:00")

        XCTAssertEqual(
            SessionStore.autoTitle(base: "会议", date: a, calendar: calendar),
            SessionStore.autoTitle(base: "会议", date: b, calendar: calendar))
        XCTAssertNotEqual(
            SessionStore.autoTitle(base: "会议", date: b, calendar: calendar),
            SessionStore.autoTitle(base: "会议", date: c, calendar: calendar))
    }

    /// 北京时间 0 点要写成 0000，不能变成 2400 或 12 小时制
    func testMidnightIsZeroNotTwentyFour() {
        let d = date("2026-07-27T00:05:00+08:00")
        XCTAssertEqual(SessionStore.titleStamp(for: d, calendar: calendar), "202607270005")
    }

    /// 标题里的时间序号不影响目录名的唯一性——目录名仍然带秒。
    func testSessionIDStillCarriesSeconds() {
        let a = date("2026-07-27T16:24:01+08:00")
        let b = date("2026-07-27T16:24:59+08:00")
        let title = SessionStore.autoTitle(base: "会议", date: a, calendar: calendar)
        XCTAssertEqual(
            SessionStore.makeSessionID(title: title, date: a, calendar: calendar),
            "2026-07-27-162401-会议202607271624")
        XCTAssertNotEqual(
            SessionStore.makeSessionID(title: title, date: a, calendar: calendar),
            SessionStore.makeSessionID(title: SessionStore.autoTitle(
                base: "会议", date: b, calendar: calendar), date: b, calendar: calendar))
    }

    /// 标题里的时间序号必须能过 slug（它会进目录名）
    func testAutoTitleSurvivesSlugify() {
        let d = date("2026-07-27T16:24:31+08:00")
        let title = SessionStore.autoTitle(base: "会议", date: d, calendar: calendar)
        XCTAssertEqual(SessionStore.slugify(title), "会议202607271624")
    }
}
