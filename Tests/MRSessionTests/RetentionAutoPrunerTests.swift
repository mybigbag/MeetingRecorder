import XCTest
@testable import MRSession
import MRCore

/// 按保留策略自动清理（`RetentionAutoPruner`）。
///
/// ## 这组用例要挡住什么
///
/// 自动清理是全工具里**唯一会在用户不在场时删数据**的路径。手动清理有确认弹窗、
/// 有 `--yes`、有预演；自动清理一样都没有。所以这里的每一条断言都不是形式主义：
///
/// 1. **默认不自动删。** 全新安装 + 旧会议 = 一个字节都不能少。
/// 2. **授权与规则分开。** 只设档位（30 天）而不打开自动清理 → 什么都不删。
///    反过来只开自动清理而不设档位 → 也什么都不删。两个开关各管一半。
/// 3. **每天至多一次。** 同一天第二次触发必须被挡，且**这个挡闸不能靠时间戳比较**。
/// 4. **静默失败要能被看见。** 没清理时也要有一句能解释的话。
/// 5. **判据不重复。** 「删哪些」只能是 `SessionRetentionCleaner` 的判据；
///    本层一旦自己判一遍年龄，两套判法早晚会漂移，而漂移的方向是「多删」。
final class RetentionAutoPrunerTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var prefs: RecorderPreferences!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-autoprune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "mr-autoprune-prefs-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        prefs = RecorderPreferences(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        prefs = nil
        suiteName = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    private func makeSession(title: String, ageDays: Double,
                             transcript: Bool = true,
                             trackBytes: Int = 4096) throws -> String {
        let started = Date().addingTimeInterval(-ageDays * 86_400)
        let store = SessionStore(root: root)
        let (id, dir) = try store.createSession(
            title: title, date: started, writeInitialManifest: false)
        var m = RecordingManifest(sessionID: id, title: title,
                                  startedAt: started, state: .finalized)
        m.endedAt = started.addingTimeInterval(1800)
        m.tracks = [
            TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                          sampleRate: 24000, channels: 1, sampleFormat: .pcm16,
                          framesWritten: 24000),
            TrackManifest(id: "system", role: .systemAudio, fileName: "system.wav",
                          sampleRate: 24000, channels: 1, sampleFormat: .pcm16,
                          framesWritten: 24000),
        ]
        try store.save(m, sessionDirectory: dir)
        try Data(repeating: 0, count: trackBytes)
            .write(to: dir.appendingPathComponent("mic.wav"))
        try Data(repeating: 0, count: trackBytes)
            .write(to: dir.appendingPathComponent("system.wav"))
        if transcript {
            try "# 稿\n".write(to: dir.appendingPathComponent("transcript.md"),
                               atomically: true, encoding: .utf8)
        }
        return id
    }

    private func wavPaths(_ sessionID: String) -> [String] {
        let dir = root.appendingPathComponent(sessionID)
        return ["mic.wav", "system.wav"].map { dir.appendingPathComponent($0).path }
    }

    private func pruner(now: @escaping () -> Date = { Date() }) -> RetentionAutoPruner {
        RetentionAutoPruner(cleaner: SessionRetentionCleaner(store: SessionStore(root: root)),
                            preferences: prefs, now: now)
    }

    // MARK: - 默认关

    /// **全新安装 + 一万年前的老会议 + 已转写 = 一个字节都不能少。**
    ///
    /// 这是整组用例的根。它红了，其余用例都失去意义——
    /// 「默认会删」的情况下，「开了开关才删」那些断言是空洞的。
    func testFreshInstallNeverDeletesAnything() throws {
        let id = try makeSession(title: "一万年前的老会议", ageDays: 3650)

        let attempt = pruner().runIfDue()

        XCTAssertFalse(attempt.didRun)
        for path in wavPaths(id) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "默认配置下自动清理绝不能删任何文件：\(path)")
        }
        XCTAssertNil(prefs.lastAutoPruneDate,
                     "没真跑过就不该写「今天跑过了」——否则用户会以为清理功能跑过了")
    }

    /// 跳过原因必须**说清是开关关着**，而不是笼统的「没删任何东西」。
    ///
    /// 自动路径与手动路径最大的差别就在这：手动那次用户在场、会追问；
    /// 自动这次用户不在场，沉默会被读成故障。
    func testDefaultOffReportsThatTheSwitchIsOff() {
        let attempt = pruner().runIfDue()
        XCTAssertEqual(attempt.skipReason, .autoPruneDisabled)
        XCTAssertTrue(attempt.summary.contains("关"),
                      "要说清是开关关着：\(attempt.summary)")
    }

    /// 「跳过」时不能有清理结果——两者同时存在的话，
    /// 界面会把一次失败报成「清理了 0 场，成功」。
    func testSkippedAttemptCarriesNoOutcome() {
        let attempt = pruner().runIfDue()
        XCTAssertFalse(attempt.didRun)
        XCTAssertNil(attempt.outcome)
    }

    // MARK: - 授权与规则分开

    /// **只设档位、不开自动清理 → 什么都不删。**
    ///
    /// 这是「授权与规则分开」那条决定的核心。用户为了「看看效果」把档位设成 30 天，
    /// 他期望的是「以后某天清一批」，而如果这一下就等于授权了自动删，
    /// 那他唯一做过的动作是选了个下拉框。
    func testSettingThePolicyAloneDoesNotEnableAutomaticDeletion() throws {
        let id = try makeSession(title: "老会议", ageDays: 200)
        prefs.retentionPolicy = .days(30)

        let attempt = pruner().runIfDue()

        XCTAssertFalse(attempt.didRun)
        XCTAssertEqual(attempt.skipReason, .autoPruneDisabled,
                       "档位已设但自动清理没开时，跳过的理由必须说清是开关关着")
        for path in wavPaths(id) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
    }

    /// 反过来只开自动清理而不设档位 → 也什么都不删。
    ///
    /// 两个开关各管一半，少任何一个都不成立。这条钉住「空档位」这一侧。
    func testEnablingAutoPruneAloneWithNoPolicyDeletesNothing() throws {
        let id = try makeSession(title: "老会议", ageDays: 200)
        prefs.autoPruneEnabled = true

        let attempt = pruner().runIfDue()

        XCTAssertFalse(attempt.didRun)
        XCTAssertEqual(attempt.skipReason, .policyDeletesNothing(.off))
        for path in wavPaths(id) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
    }

    /// 两个都开 + 到档 + 已转写 → 真删。
    ///
    /// 前面三条都在钉「不该删」，这条钉「该删时确实删了」。
    /// 少了它，一个恒返回「跳过」的实现能让整组测试全绿。
    func testBothEnabledWithAnEligibleSessionActuallyDeletes() throws {
        let id = try makeSession(title: "老会议", ageDays: 200)
        prefs.retentionPolicy = .days(30)
        prefs.autoPruneEnabled = true

        let attempt = pruner().runIfDue()

        XCTAssertTrue(attempt.didRun)
        XCTAssertEqual(attempt.outcome?.deleted.count, 1)
        for path in wavPaths(id) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "两个开关都开且到档时，确实该删：\(path)")
        }
        // manifest 与转写稿必须留下——保留策略的全部意义就在这里。
        let dir = root.appendingPathComponent(id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("transcript.md").path))
    }

    /// 没转写过的会议不删。**默认这一条在任何档位、任何开关下都成立。**
    ///
    /// 自动路径尤其要守住它：手动那次用户在场、看得见确认弹窗；
    /// 自动那次没有弹窗，一个「没稿子的会议被清掉」会静静发生。
    func testUntranscribedSessionsAreNeverAutoDeleted() throws {
        let id = try makeSession(title: "没转写", ageDays: 400, transcript: false)
        prefs.retentionPolicy = .days(7)
        prefs.autoPruneEnabled = true

        let attempt = pruner().runIfDue()

        XCTAssertTrue(attempt.didRun, "这次调度本身应当执行过（只是没东西可删）")
        XCTAssertTrue(attempt.outcome?.deleted.isEmpty ?? false)
        for path in wavPaths(id) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "没转写过的会议删掉就没有内容了，任何情况下都不能删")
        }
    }

    // MARK: - 每天至多一次

    /// 同一天第二次触发被挡，且**盘上不再变化**。
    func testSecondRunOnTheSameDayIsBlocked() throws {
        _ = try makeSession(title: "第一场", ageDays: 200)
        prefs.retentionPolicy = .days(30)
        prefs.autoPruneEnabled = true

        let first = pruner().runIfDue()
        XCTAssertTrue(first.didRun)

        // 第一场之后再来一场旧的：同一天里它不该被清掉。
        let secondID = try makeSession(title: "第二场", ageDays: 210)
        let second = pruner().runIfDue()

        XCTAssertFalse(second.didRun)
        XCTAssertEqual(second.skipReason,
                       .alreadyRanToday(RetentionAutoPruner.todayStamp()))
        for path in wavPaths(secondID) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "同一天里第二次触发不该再删——用户对「为什么这时又少了文件」毫无预期")
        }
    }

    /// **跨天后要能再跑。** 只写「今天跑过了」而不判日期的话，
    /// 自动清理会在第一天之后就永久停摆，而界面上看不出任何异常。
    func testItRunsAgainTheNextDay() throws {
        prefs.retentionPolicy = .days(30)
        prefs.autoPruneEnabled = true

        let today = Date()
        let later = today.addingTimeInterval(86_400)

        XCTAssertTrue(pruner(now: { today }).runIfDue().didRun)
        XCTAssertFalse(pruner(now: { today }).runIfDue().didRun, "同一天第二次被挡")
        let id = try makeSession(title: "隔天新增的老会议", ageDays: 300)
        XCTAssertTrue(pruner(now: { later }).runIfDue().didRun, "跨天后必须能再跑")
        for path in wavPaths(id) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "跨天后的那次调度应当真删")
        }
    }

    /// 「今天没有可删的」也算跑过了。
    ///
    /// 少了这条，用户上午启动应用（没东西可删）、下午转写一场、
    /// 傍晚又来一场 30 天前的老会议——那一场就会因为「今天已经跑过」而留到明天。
    /// 而他等的是「超过 30 天就清」，不是「每天碰巧在启动那一刻清」。
    func testAnEmptyRunStillCountsAsHavingRunToday() throws {
        prefs.retentionPolicy = .days(30)
        prefs.autoPruneEnabled = true
        _ = try makeSession(title: "刚录的", ageDays: 1)   // 没到档

        let attempt = pruner().runIfDue()

        XCTAssertTrue(attempt.didRun)
        XCTAssertTrue(attempt.outcome?.deleted.isEmpty ?? false)
        XCTAssertEqual(prefs.lastAutoPruneDate, RetentionAutoPruner.todayStamp(),
                       "跑了就算数，哪怕一场都没删——否则同一天会反复扫库")
        XCTAssertFalse(pruner().runIfDue().didRun, "空跑一次之后当天不该再跑")
    }

    // MARK: - 坏档位

    /// **坏键必须让自动路径拒绝执行，而且要说清为什么。**
    ///
    /// 与手动路径同一条纪律，但自动路径更需要它：没人点确认时，
    /// 静默什么都不做会被读成「功能坏了」——于是用户可能去手动清一把，
    /// 而那正是最危险的时刻（他刚看到「怎么没动静」）。
    func testUnrecognizedPolicyRefusesAndExplains() throws {
        let id = try makeSession(title: "老会议", ageDays: 300)
        defaults.set("60", forKey: RecorderPreferences.retentionPolicyKey)
        prefs.autoPruneEnabled = true

        let attempt = pruner().runIfDue()

        XCTAssertFalse(attempt.didRun)
        XCTAssertEqual(attempt.skipReason, .unrecognizedPolicy)
        XCTAssertTrue(attempt.summary.contains("已拒绝执行"), attempt.summary)
        for path in wavPaths(id) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
        XCTAssertNil(prefs.lastAutoPruneDate,
                     "拒绝执行不该被记成「今天跑过了」——那会让它此后当天不再重试")
    }

    /// 「坏键」的判定优先于「档位清不了任何东西」。
    ///
    /// 顺序反了的话，用户看到的是「档位是关闭」——而他明明在设置里写了个
    /// 60，那是一条**需要他去修的错误**，不是一条不需要管的默认值。
    func testUnrecognizedPolicyOutranksTheDisabledPolicyMessage() {
        defaults.set("60", forKey: RecorderPreferences.retentionPolicyKey)
        prefs.autoPruneEnabled = true

        let reason = RetentionAutoPruner.skipReason(
            autoPruneEnabled: true, policy: nil,
            hasUnrecognizedPolicy: true, lastRunDay: nil, today: "2026-10-09")

        XCTAssertEqual(reason, .unrecognizedPolicy)
    }

    /// 开关关着时，坏键**不**被报出来——授权优先于一切内部状态。
    func testDisabledSwitchOutranksEveryOtherReason() {
        defaults.set("60", forKey: RecorderPreferences.retentionPolicyKey)
        // autoPruneEnabled 保持默认 false

        let reason = RetentionAutoPruner.skipReason(
            autoPruneEnabled: false, policy: nil,
            hasUnrecognizedPolicy: true,
            lastRunDay: "2026-10-09", today: "2026-10-09")

        XCTAssertEqual(reason, .autoPruneDisabled)
    }

    // MARK: - 报告文案

    /// 「删到了」与「没删到」在界面上必须长得不一样。
    ///
    /// 两句话如果都是「自动清理完成」，用户第二天看到老录音还在，
    /// 只会得出「这功能坏了」的结论。
    func testReportDistinguishesDeletedFromNothingToDo() throws {
        prefs.retentionPolicy = .days(30)
        prefs.autoPruneEnabled = true

        // 没到档的一场：跑了但没删到
        _ = try makeSession(title: "刚录的", ageDays: 1)
        let empty = pruner().runIfDue()
        let emptyText = RetentionAutoPruner.report(for: empty)
        XCTAssertNotNil(emptyText)
        XCTAssertTrue(emptyText!.contains("没有需要清理"),
                      "没删到东西要说清「今天没有需要清理的」：\(emptyText!)")
        XCTAssertFalse(emptyText!.contains("已按保留策略清理"),
                       "没删到东西时不能报成清理成功——那会让用户以为文件被莫名清了")
    }

    func testReportNamesHowManySessionsAndHowMuchWasFreed() throws {
        prefs.retentionPolicy = .days(30)
        prefs.autoPruneEnabled = true
        _ = try makeSession(title: "老1", ageDays: 200, trackBytes: 4096)
        _ = try makeSession(title: "老2", ageDays: 210, trackBytes: 4096)

        let text = RetentionAutoPruner.report(for: pruner().runIfDue())

        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("2 场"), "要说清清了几场：\(text!)")
        XCTAssertTrue(text!.contains("废纸篓"),
                      "必须说明删除走废纸篓且清空后不可恢复：\(text!)")
        XCTAssertTrue(text!.contains("转写稿保留"), "要说清留下什么：\(text!)")
    }

    /// 跳过的报告里**不能**出现「清理了 0 场」这种读法。
    func testSkipReportNeverSoundsLikeASuccessfulCleanup() {
        let attempt = RetentionAutoPruner.Attempt(
            didRun: false, skipReason: .autoPruneDisabled, outcome: nil)
        let text = RetentionAutoPruner.report(for: attempt)
        XCTAssertNotNil(text)
        XCTAssertFalse(text!.contains("已按保留策略清理"))
        XCTAssertFalse(text!.contains("腾出"))
    }

    // MARK: - 偏好层

    func testAutoPruneDefaultsToOffAndDoesNotWriteOnRead() {
        XCTAssertFalse(prefs.autoPruneEnabled)
        XCTAssertNil(defaults.object(forKey: RecorderPreferences.autoPruneEnabledKey),
                     "读一次偏好不该顺手把它写下来")
        XCTAssertNil(prefs.lastAutoPruneDate)
    }

    func testAutoPruneRoundTrips() {
        prefs.autoPruneEnabled = true
        XCTAssertTrue(RecorderPreferences(defaults: defaults).autoPruneEnabled)
        prefs.autoPruneEnabled = false
        XCTAssertFalse(RecorderPreferences(defaults: defaults).autoPruneEnabled)
    }

    /// `dayStamp` 必须在**显式传入的时区**下取值。
    ///
    /// 退化示例：删掉 `f.timeZone = calendar.timeZone`，本用例在非本地时区下变红。
    /// 这条不是洁癖：「今天跑过了吗」在跨时区时判错一天，
    /// 后果是自动清理整整推迟一天，或者在同一天里跑两次。
    func testDayStampFollowsTheGivenCalendarTimeZone() throws {
        var calUTC = Calendar(identifier: .gregorian)
        calUTC.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calTokyo = Calendar(identifier: .gregorian)
        calTokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))

        // 2026-10-09 20:00 UTC = 2026-10-10 05:00 东京
        let instant = Date(timeIntervalSince1970: 1_791_576_000)
        let inUTC = RecorderPreferences.dayStamp(for: instant, calendar: calUTC)
        let inTokyo = RecorderPreferences.dayStamp(for: instant, calendar: calTokyo)

        XCTAssertEqual(inUTC, "2026-10-09")
        XCTAssertEqual(inTokyo, "2026-10-10",
                       "同一个瞬间在不同时区应当是不同的一天——判错会让清理推迟或重复一天")
        XCTAssertNotEqual(inUTC, inTokyo)
    }
}