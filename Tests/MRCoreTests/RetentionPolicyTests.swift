import XCTest
@testable import MRCore

/// 保留档位这个值类型（用例 D1 / D2 组）。
///
/// 测它的理由与「默认关」这件事本身有关：这一档是全工具里**唯一会删用户数据**的
/// 功能，所以「默认是关闭的」「拼错必须报错」「档位边界是 `>=` 不是 `>`」
/// 这些都不是实现细节，而是规格。少了它们，一条手滑的默认值就会开始删录音。
final class RetentionPolicyTests: XCTestCase {

    // MARK: - D1 档位与解析

    /// 键不存在时是 `.off`。D-01 纪律的根。
    func testDefaultIsOff() {
        XCTAssertNil(RetentionPolicy(resolving: nil),
                     "nil 输入不该解析成任何档位")
        XCTAssertEqual(RetentionPolicy.selectableCases.first, .off)
    }

    /// 四个产品档位（关闭 / 7 / 30 / 90），顺序即展示顺序。
    ///
    /// ## 为什么没有第五档「永久保留」
    ///
    /// 它与「关闭」的清理结果**逐位相同**：`selects` 对两者返回同一个 `false`，
    /// `isEnabled` 对两者都是 `false`，`prune` 遇到它们都在执行前就拒绝。
    /// 两个效果一样的选项摆在菜单里，用户会以为它们之间有区别——
    /// 而「我选了永久保留是不是就等于关闭了」这个问题，界面上 nowhere 有答案。
    /// 所以合并成一个，标题写清「关闭（永久保留）」。
    func testSelectableCasesMatchTheProductDecision() {
        XCTAssertEqual(RetentionPolicy.selectableCases,
                       [.off, .days(7), .days(30), .days(90)])
        XCTAssertEqual(RetentionPolicy.selectableDayCounts, [7, 30, 90])
    }

    /// **界面上不许出现两个「在任何年龄都判定相同」的档位。**
    ///
    /// 这是合并档位那个决定的守卫：把一个恒等档位加回 `selectableCases` 时它会红。
    ///
    /// ## 判据为什么是「存在某个年龄不同」
    ///
    /// 前两版都栽在这里，值得写下来：
    ///
    /// - 第一版写「任意时间点判定都不同」→ **过强**。一场3 天大的会议，
    ///   「7 天」与「30 天」都返回 `false`，那是**正确**的，不是等价。
    /// - 第二版改成「在一场一万年前的会议上判定不同」→ **方向相反地错**：
    ///   一万年前的会议对三个天数档**全是 `true`**。恒等的是「不删」那一档
    ///   与它的别名（任何年龄都是 `false`），而两个阈值不同的天数档
    ///   只在「夹在两个阈值之间」那段区间里分出高下。
    ///
    /// 正确的不变式是：**存在某个年龄，两者判定不同**。
    /// 恒等的两个档位在任何年龄都相同，于是必然找不到这样的年龄。
    func testNoTwoSelectablePoliciesAgreeAtEveryAge() {
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        // 扫 0…200 天，覆盖「夹在任意两个阈值之间」的所有区间。
        let ages: [TimeInterval] = (0...200).map { Double($0) }
        for i in 0..<RetentionPolicy.selectableCases.count {
            for j in (i + 1)..<RetentionPolicy.selectableCases.count {
                let a = RetentionPolicy.selectableCases[i]
                let b = RetentionPolicy.selectableCases[j]
                let differsSomewhere = ages.contains { day in
                    let started = anchor.addingTimeInterval(-day * 86_400)
                    return a.selects(startedAt: started, now: anchor)
                        != b.selects(startedAt: started, now: anchor)
                }
                XCTAssertTrue(differsSomewhere,
                              "「\(a.displayName)」与「\(b.displayName)」在 0…200 天里的"
                              + "**每一个**年龄上判定都相同——它们对用户是同一个选项，"
                              + "不该并排出现在菜单里")
            }
        }
    }

    /// 「不删」那一档与任何一个天数档都必须在某个年龄上分出高下。
    ///
    /// 这是上面那条守卫最要紧的一个实例，单独钉住：它就是本次要修的那个问题
    /// （「关闭」与「永久保留」并排）。写成实例是因为上面那条在集合变大时
    /// 只会报出「第 i 与第 j 对」——直接点名能让失败信息一眼看出问题所在。
    func testTheNeverDeletePolicyIsNeverEquivalentToADayTier() {
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        for tier in RetentionPolicy.selectableDayCounts {
            let policy = RetentionPolicy.days(tier)
            let differs = (0...(tier + 1)).contains { day in
                let started = anchor.addingTimeInterval(-Double(day) * 86_400)
                return RetentionPolicy.off.selects(startedAt: started, now: anchor)
                    != policy.selects(startedAt: started, now: anchor)
            }
            XCTAssertTrue(differs,
                          "「关闭」与「\(policy.displayName)」在任何年龄上判定都相同——"
                          + "它们对用户是同一个选项")
        }
    }

    /// `.off` 的标题必须把「永久保留」这层意思说出来。
    ///
    /// 合并成一个选项之后，用户原来想选「永久保留」的心智必须还能落地：
    /// 他看到的标题里就有「永久保留」四个字。
    func testOffDisplayNameCarriesTheForeverMeaning() {
        XCTAssertTrue(RetentionPolicy.off.displayName.contains("永久保留"),
                      "合并后的标题必须仍能让用户找到「永久保留」这个意思："
                      + RetentionPolicy.off.displayName)
    }

    /// `rawValue` 写出读回一致。
    func testRawValuesRoundTrip() {
        for p in RetentionPolicy.selectableCases {
            XCTAssertEqual(RetentionPolicy(resolving: p.rawValue), p, "档位 \(p.rawValue)")
        }
    }

    /// **未知值返回 nil，绝不回退。** 这是 D1-05 / M-D9 的根——
    /// 回退到 `.off` 会让用户以为「我设了一个月」而实际什么都没删，
    /// 回退到 30 天则直接开始删。两个方向都不能接受。
    ///
    /// `0` 也在这个列表里：它**看起来**像「0 天」，而「0 天」不在四个产品档位内。
    /// 静默把它当成「关闭」的话，用户敲了 `config set retention 0` 得到的是
    /// 「什么都不删」，而他以为的是「立刻删掉全部」。这条不接受。
    func testUnknownValueDoesNotFallBackToAnyDefault() {
        for bad in ["60", "0", "45", "week", "", "  ", "7.5", "-7", "永久删除"] {
            XCTAssertNil(RetentionPolicy(resolving: bad),
                         "「\(bad)」不该解析成任何档位，更不该回退到默认")
        }
    }

    /// 中文与简写别名。
    ///
    /// `keep` / `forever` / `永久` 这一族**仍然被接受，但一律解析成 `.off`**。
    /// 它们不能报错：已经落盘的偏好里可能有这一串，报错会让用户以为自己的设置坏了，
    /// 而实际上它表达的正是「不删」——与 `.off` 同一件事。
    func testAliases() {
        XCTAssertEqual(RetentionPolicy(resolving: "forever"), .off)
        XCTAssertEqual(RetentionPolicy(resolving: "永久"), .off)
        XCTAssertEqual(RetentionPolicy(resolving: "永久保留"), .off)
        XCTAssertEqual(RetentionPolicy(resolving: "keep"), .off)
        XCTAssertEqual(RetentionPolicy(resolving: "none"), .off)
        XCTAssertEqual(RetentionPolicy(resolving: "关"), .off)
        XCTAssertEqual(RetentionPolicy(resolving: "7d"), .days(7))
        XCTAssertEqual(RetentionPolicy(resolving: "一周"), .days(7))
        XCTAssertEqual(RetentionPolicy(resolving: "一个月"), .days(30))
        XCTAssertEqual(RetentionPolicy(resolving: "三个月"), .days(90))
        XCTAssertEqual(RetentionPolicy(resolving: "一季"), .days(90))
    }

    /// 大小写与空白不敏感。
    func testParsingIsWhitespaceAndCaseInsensitive() {
        XCTAssertEqual(RetentionPolicy(resolving: " 30 "), .days(30))
        XCTAssertEqual(RetentionPolicy(resolving: "KEEP"), .off)
        XCTAssertEqual(RetentionPolicy(resolving: "Forever"), .off)
    }

    /// `isEnabled`：只有三个天数档会主动删东西。
    func testOnlyDayCountsAreEnabled() {
        XCTAssertFalse(RetentionPolicy.off.isEnabled,
                       "关闭（含「永久保留」这层意思）不删任何东西")
        XCTAssertTrue(RetentionPolicy.days(7).isEnabled)
        XCTAssertTrue(RetentionPolicy.days(30).isEnabled)
        XCTAssertTrue(RetentionPolicy.days(90).isEnabled)
    }

    /// **每一个 selectable 档位的名字都必须唯一。**
    ///
    /// GUI 的菜单项是按 `displayName` 查找的（`StatusItemController` 建菜单、
    /// 测试也按标题找）。两个档位同名 → `first(where:)` 只会命中其中一个，
    /// 另一个变成永远点不到的死项，而菜单看起来完全正常。
    func testSelectableDisplayNamesAreUnique() {
        let names = RetentionPolicy.selectableCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "档位标题重了：\(names)")
    }

    /// 每个会删东西的档位，说明里必须出现「不可恢复 / 废纸篓」这类事实。
    /// 用户按下确认前看到的最后一句话应当是这个，而不是「确定要继续吗」。
    func testMenuHelpStatesIrreversibility() {
        for p in [RetentionPolicy.days(7), .days(30), .days(90)] {
            let help = p.menuHelp
            XCTAssertTrue(help.contains("废纸篓") || help.contains("不可恢复"),
                          "「\(p.displayName)」的说明没提不可逆：\(help)")
            XCTAssertTrue(help.contains("不会立刻删"),
                          "「\(p.displayName)」的说明必须说清设档位不会立刻删东西：\(help)")
        }
    }

    /// `.off` 的说明要给出「不删」这件事的实际后果，不能只说「关闭」。
    func testOffHelpExplainsTheConsequence() {
        XCTAssertTrue(RetentionPolicy.off.menuHelp.contains("不自动清理"))
    }

    // MARK: - D2 年龄判定

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 正好 N 天整**要选中**——边界是 `>=`。
    /// 用 `>` 的话「7 天」在整点时刻会变成「8 天才清」，用户会以为功能坏了。
    func testExactlyNDaysOldIsSelected() {
        let start = now.addingTimeInterval(-7 * 86_400)
        XCTAssertTrue(RetentionPolicy.days(7).selects(startedAt: start, now: now))
        XCTAssertTrue(RetentionPolicy.days(30)
            .selects(startedAt: now.addingTimeInterval(-30 * 86_400), now: now))
    }

    /// 差 1 秒不选中。
    func testOneSecondYoungerIsNotSelected() {
        let start = now.addingTimeInterval(-7 * 86_400 + 1)
        XCTAssertFalse(RetentionPolicy.days(7).selects(startedAt: start, now: now))
    }

    /// **未来时间（时钟回拨）永不选中。**
    ///
    /// 方向不对称：把明天开始的会议当成「够 N 天」会删掉刚录的东西，
    /// 而少删一场用户根本感知不到。所以这里必须是 false。
    func testFutureStartIsNeverSelected() {
        let future = now.addingTimeInterval(3600)
        for p in RetentionPolicy.selectableDayCounts.map({ RetentionPolicy.days($0) }) {
            XCTAssertFalse(p.selects(startedAt: future, now: now),
                           "「\(p.displayName)」不该选中一场开始时间在未来的会议")
        }
    }

    /// 关闭态恒空，且不看年龄——录了一万年的会议也不删。
    func testOffSelectsNothingNoMatterHowOld() {
        let ancient = now.addingTimeInterval(-3650 * 86_400)
        XCTAssertFalse(RetentionPolicy.off.selects(startedAt: ancient, now: now))
    }

    /// `ageTolerance` 是显式参数而不是藏起来的偏移——它存在只是为了让
    /// 「整点时刻」的语义能被测试精确描述，不该被任何调用方真的用上。
    func testAgeToleranceIsExplicitlyInjectable() {
        let start = now.addingTimeInterval(-7 * 86_400 + 10)
        XCTAssertFalse(RetentionPolicy.days(7).selects(startedAt: start, now: now))
        XCTAssertTrue(RetentionPolicy.days(7)
            .selects(startedAt: start, now: now, ageTolerance: 10))
    }

    // MARK: - 偏好的落盘

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "mr-retention-prefs-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    /// 全新安装读到 `.off`，而且**读一次不写键**。
    func testFreshInstallResolvesToOffAndDoesNotWrite() {
        let prefs = RecorderPreferences(defaults: defaults)
        XCTAssertEqual(prefs.resolvedRetentionPolicy(), .off)
        XCTAssertFalse(prefs.hasUnrecognizedRetentionPolicy())
        XCTAssertNil(defaults.object(forKey: RecorderPreferences.retentionPolicyKey),
                     "读一次偏好不该顺手把它写下来")
    }

    func testEachPolicyRoundTripsThroughDefaults() {
        let prefs = RecorderPreferences(defaults: defaults)
        for p in RetentionPolicy.selectableCases {
            prefs.retentionPolicy = p
            XCTAssertEqual(prefs.resolvedRetentionPolicy(), p)
            XCTAssertFalse(prefs.hasUnrecognizedRetentionPolicy())
        }
    }

    /// **坏键必须能被独立识别出来**，不能被 `.off` 掩盖。
    ///
    /// 这条是 M-D9 的落点：清理执行前要靠它拒绝运行。
    func testUnrecognizedStoredValueIsReportedRatherThanMaskedAsOff() {
        let prefs = RecorderPreferences(defaults: defaults)
        defaults.set("60", forKey: RecorderPreferences.retentionPolicyKey)
        XCTAssertNil(prefs.retentionPolicy, "读出来应当是 nil，而不是某个默认档")
        XCTAssertTrue(prefs.hasUnrecognizedRetentionPolicy(),
                      "坏键必须能被独立识别——否则清理会把它当成「关」而照常执行")
    }

    /// 写 nil 移除键，回到「没设置过」。
    func testWritingNilRemovesTheKey() {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.retentionPolicy = .days(30)
        XCTAssertNotNil(defaults.object(forKey: RecorderPreferences.retentionPolicyKey))
        prefs.retentionPolicy = nil
        XCTAssertNil(defaults.object(forKey: RecorderPreferences.retentionPolicyKey))
        XCTAssertEqual(prefs.resolvedRetentionPolicy(), .off)
    }
}