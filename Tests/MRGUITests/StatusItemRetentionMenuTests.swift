import XCTest
import AppKit
import MRCore
import MRSession
@testable import MRGUI

/// 状态栏里的保留策略子菜单与「立即清理」入口（#26 D 档）。
///
/// ## 这一组要挡住什么
///
/// 三件事，屏幕上都看不出异常：
///
/// 1. **点「设成 30 天」顺手删了东西。** 这是纪律 1 的 GUI 侧回归——
///    用户点这一下时想的不是「帮我清一批」。
/// 2. **点档位菜单项静默无效。** 单选菜单的失效形态是「点了但什么也没变」，
///    没有报错、没有提示，而用户会以为设上了。
/// 3. **确认弹窗里的关键事实缺席。** 「会删几场」「不可恢复」只在弹窗里，
///    不抽成纯函数就只能靠人眼读——而人眼在这个项目里已经错过东西了。
@MainActor
final class StatusItemRetentionMenuTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var workspace: MeetingWorkspace!
    private var controller: StatusItemController!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-retention-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "mr-retention-menu-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        workspace = MeetingWorkspace(root: root,
                                     preferences: RecorderPreferences(defaults: defaults))
        controller = StatusItemController(workspace: workspace,
                                         hotKeyFailures: [], onShowWindow: {})
    }

    override func tearDown() async throws {
        controller = nil
        workspace = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    private func menu() -> NSMenu {
        let m = NSMenu()
        controller.menuNeedsUpdate(m)
        return m
    }

    private func retentionEntry(in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(
            mrFindMenuItem(in: menu, titleHasPrefix: StatusItemController.retentionMenuTitle),
            "状态栏菜单里必须有保留策略子菜单，实际只有：\(mrFlattenMenuTitles(menu))")
    }

    private func pruneItem(in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(
            mrFindMenuItem(in: menu, title: StatusItemController.pruneMenuTitle),
            "状态栏菜单里必须有「立即清理」入口，实际只有：\(mrFlattenMenuTitles(menu))")
    }

    // MARK: - 夹具

    /// 基准日用**真实现在**而不是固定时间戳：`MeetingWorkspace.retentionCleaner`
    /// 构造时没注入时钟（它自己 new 出来的），所以走 `Date()`。
    /// 用一个固定且可能落在未来的时间戳，测出来的是「未来开始的会议不该被清」——
    /// 断言会绿，但与它声称在测的东西无关。
    private func makeSession(title: String, ageDays: Double,
                             transcript: Bool = true,
                             compressed: Bool = false) throws -> String {
        let started = Date().addingTimeInterval(-ageDays * 86_400)
        let (id, dir) = try workspace.library.store.createSession(
            title: title, date: started, writeInitialManifest: false)
        var m = RecordingManifest(sessionID: id, title: title,
                                  startedAt: started, state: .finalized)
        m.endedAt = started.addingTimeInterval(1800)
        // 三项（位深/采样率/声道）一起改，才算「跑过 transcode --preset b-tier」。
        // 只改一项在现实里做不到，而判定查的就是三项。
        m.tracks = [TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                                  sampleRate: compressed ? 24000 : 48000,
                                  channels: 1,
                                  sampleFormat: compressed ? .pcm16 : .float32,
                                  framesWritten: (compressed ? 24000 : 48000))]
        try workspace.library.store.save(m, sessionDirectory: dir)
        try Data(repeating: 0, count: 2048).write(to: dir.appendingPathComponent("mic.wav"))
        if transcript {
            try "# 稿\n".write(to: dir.appendingPathComponent("transcript.md"),
                               atomically: true, encoding: .utf8)
        }
        return id
    }

    // MARK: - 子菜单

    /// 入口常驻，标题带当前档位。
    func testRetentionSubmenuIsPresentAndShowsTheCurrentPolicy() throws {
        let entry = try retentionEntry(in: menu())
        XCTAssertNotNil(entry.submenu)
        XCTAssertTrue(entry.title.contains(RetentionPolicy.off.displayName),
                      "标题应显示当前档位（默认关闭）：\(entry.title)")
    }

    /// 子菜单里四项都在，且**恰好当前那个被打勾**。
    ///
    /// 四项 = 关闭（含「永久保留」）/ 7 / 30 / 90。曾经是五项，
    /// 多出来的「永久保留」与「关闭」清理结果完全相同——
    /// 两个等价的选项并排摆着，用户只会以为它们之间有区别。
    func testSubmenuListsEveryTierAndTicksTheCurrentOne() throws {
        for policy in RetentionPolicy.selectableCases {
            workspace.retentionPolicy = policy
            let sub = try XCTUnwrap(try retentionEntry(in: menu()).submenu)
            XCTAssertEqual(sub.items.count, 4,
                           "四个档位（关闭 / 7 / 30 / 90）都必须列出来，"
                           + "且不能有第二个与「关闭」等价的选项")
            for p in RetentionPolicy.selectableCases {
                let item = try XCTUnwrap(sub.items.first { $0.title == p.displayName })
                XCTAssertEqual(item.state, p == policy ? .on : .off,
                               "「\(p.displayName)」的勾选状态不对（当前 \(policy)）")
            }
        }
    }

    /// **菜单里不许有两个效果相同的档位。**
    ///
    /// 这条守卫的是产品决定本身。菜单项是按 `displayName` 查找的
    /// （下面 `testClickingAPolicyActuallyChangesThePreference` 就靠标题找），
    /// 两个档位同名 → `first(where:)` 只命中一个，另一个变成永远点不到的死项，
    /// 而菜单看起来完全正常。
    func testNoTwoMenuItemsOfferTheSameBehaviour() throws {
        workspace.retentionPolicy = .days(30)
        let sub = try XCTUnwrap(try retentionEntry(in: menu()).submenu)
        var seen: [String: RetentionPolicy] = [:]
        for p in RetentionPolicy.selectableCases {
            XCTAssertNil(seen[p.displayName],
                         "「\(p.displayName)」出现了两次，其中一个必然点不到")
            seen[p.displayName] = p
        }
        XCTAssertEqual(sub.items.count, seen.count,
                       "菜单项数必须与可选档位数一致——多出来的项没有 representedObject，点了静默无效")
    }

    /// 合并后的标题必须仍能让「想永久保留」的用户认出自己那一档。
    func testMergedOffLabelStillMentionsForever() throws {
        workspace.retentionPolicy = .off
        let entry = try retentionEntry(in: menu())
        XCTAssertTrue(entry.title.contains("永久保留"),
                      "「关闭」这一项的标题要让用户找到「永久保留」：\(entry.title)")
        let sub = try XCTUnwrap(entry.submenu)
        XCTAssertNotNil(sub.items.first { $0.title.contains("永久保留") })
    }

    /// 每项都要带 `representedObject`，否则点击后无从知道选了哪个。
    /// 退化示例：删掉这一行，菜单仍建得出来、勾选也正确，但点击静默无效。
    func testEveryPolicyItemCarriesItsRawValue() throws {
        let sub = try XCTUnwrap(try retentionEntry(in: menu()).submenu)
        for p in RetentionPolicy.selectableCases {
            let item = try XCTUnwrap(sub.items.first { $0.title == p.displayName })
            XCTAssertEqual(item.representedObject as? String, p.rawValue,
                           "「\(p.displayName)」没带 rawValue，点击后会静默无效")
        }
    }

    /// 走真实的 target/action。
    func testClickingAPolicyActuallyChangesThePreference() throws {
        let sub = try XCTUnwrap(try retentionEntry(in: menu()).submenu)
        let thirty = try XCTUnwrap(sub.items.first { $0.title == RetentionPolicy.days(30).displayName })

        _ = NSApp.sendAction(try XCTUnwrap(thirty.action), to: thirty.target, from: thirty)

        XCTAssertEqual(workspace.retentionPolicy, .days(30))
        XCTAssertEqual(RecorderPreferences(defaults: defaults).retentionPolicy, .days(30),
                       "必须落盘，否则下一场录制还用旧档位")
    }

    /// **点档位不删任何东西。** 纪律 1 的 GUI 侧回归（M-D1）。
    func testSelectingAPolicyDeletesNothing() throws {
        let id = try makeSession(title: "老会议", ageDays: 200)
        let wav = workspace.library.store.directory(forSessionID: id)
            .appendingPathComponent("mic.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))

        let sub = try XCTUnwrap(try retentionEntry(in: menu()).submenu)
        let seven = try XCTUnwrap(sub.items.first { $0.title == RetentionPolicy.days(7).displayName })
        _ = NSApp.sendAction(try XCTUnwrap(seven.action), to: seven.target, from: seven)

        XCTAssertEqual(workspace.retentionPolicy, .days(7))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path),
                      "设档位的那一刻**不能**删掉任何文件——用户点这一下想的不是「帮我清一批」")
    }

    /// 档位单选**不带浮层**，代价在「按下确认之前」说。
    ///
    /// 2026-10-22 之前每个档位挂着一整段 `menuHelp`：一悬停就弹出一块多行浮层，
    /// 盖住下面的「立即清理」——原话是「hover 说明还会遮挡设置项」。
    /// 现在档位项只有标题，讲代价的地方是 `retentionConfirmationText`
    /// （带场次数、体积、废纸篓），那才是用户做决定的那一刻。
    ///
    /// 文案本身没删：`RetentionPolicy.menuHelp` 仍被 `mr retain` 的 CLI 提示用着。
    func testPolicyItemsCarryNoTooltip() throws {
        let sub = try XCTUnwrap(try retentionEntry(in: menu()).submenu)
        for p in RetentionPolicy.selectableCases {
            let item = try XCTUnwrap(sub.items.first { $0.title == p.displayName })
            XCTAssertNil(item.toolTip,
                         "「\(p.displayName)」上还挂着浮层，悬停会盖住下面的条目")
        }
    }

    /// **「设档位」与「执行清理」是两件事——靠菜单结构表达，不靠浮层。**
    ///
    /// 少了这条区分，用户会以为选完就已经清过了（磁盘纹丝不动 → 「这功能坏了」）。
    /// 原来这句话写在入口的 tooltip 里；现在两者在**「存储与清理」那个子菜单**里
    /// 并排出现：上面是档位单选，下面是「立即清理…」，中间那条分隔线就是语义。
    ///
    /// ⚠️ 注意层级：`retentionEntry` 是里面那层「保留策略：30 天」，
    /// 它的子菜单里**只有**档位；「立即清理」在外层（存储与清理）里。
    /// 拿错层会得到「prune 不见了」——而产品本身没问题（本地一次误判）。
    func testSelectingAPolicyIsASeparateActionFromPruning() throws {
        workspace.retentionPolicy = .days(30)
        let storage = try XCTUnwrap(
            mrFindMenuItem(in: menu(), titleHasPrefix: "\(StatusItemController.storageMenuTitle)："),
            "状态栏菜单里必须有「存储与清理」分组")
        let storageTitles = try XCTUnwrap(storage.submenu).items.map(\.title)
        XCTAssertTrue(storageTitles.contains(StatusItemController.pruneMenuTitle),
                      "执行清理要与档位同组、独立成一行：\(storageTitles)")

        let retentionTitles = try XCTUnwrap(try retentionEntry(in: menu()).submenu)
            .items.map(\.title)
        XCTAssertTrue(retentionTitles.contains(RetentionPolicy.days(30).displayName),
                      "档位单选要在：\(retentionTitles)")
        XCTAssertFalse(retentionTitles.contains(StatusItemController.pruneMenuTitle),
                       "清理动作不该混进「选档位」这一层：\(retentionTitles)")
    }

    // MARK: - 「立即清理」入口

    func testPruneEntryExists() throws {
        XCTAssertNotNil(try pruneItem(in: menu()))
    }

    /// 档位为关闭时禁用，但**入口仍在**。
    ///
    /// 藏起来是不行的：用户恰恰是在「打开它发现没地方设」时才需要知道它存在。
    func testPruneEntryIsDisabledWhenPolicyCannotDeleteAnything() throws {
        workspace.retentionPolicy = .off
        XCTAssertFalse(try pruneItem(in: menu()).isEnabled,
                       "「关闭」清不了任何东西，应当禁用")
        workspace.retentionPolicy = .days(30)
        XCTAssertTrue(try pruneItem(in: menu()).isEnabled)
    }

    // MARK: - 确认文案

    /// 空账时给一句话说明，而不是一个空弹窗。
    func testConfirmationTextExplainsWhenThereIsNothingToDo() {
        let plan = SessionRetentionCleaner.Plan(policy: .days(30), sessions: [],
                                                 rootNote: "存储根目录还不存在")
        let text = StatusItemController.retentionConfirmationText(plan: plan)
        XCTAssertTrue(text.contains("没有要清理的内容"))
        XCTAssertTrue(text.contains("存储根目录还不存在"))
    }

    /// 确认文案里必须同时出现：**会删几场**、**移入废纸篓**、**不可恢复**。
    ///
    /// 这是用户按下确认前看到的最后一条信息，缺任何一条他都可能在不知情的
    /// 情况下放弃掉一次本该做的清理，或者在知情的情况下放弃一次本该做的清理。
    func testConfirmationTextCarriesTheThreeEssentialFacts() throws {
        workspace.retentionPolicy = .days(30)
        _ = try makeSession(title: "老会议", ageDays: 200)
        _ = try makeSession(title: "老会议2", ageDays: 150)
        let plan = try workspace.retentionPlan()

        let text = StatusItemController.retentionConfirmationText(plan: plan)

        XCTAssertTrue(text.contains("2 场"), "要说出会删几场：\(text)")
        XCTAssertTrue(text.contains("废纸篓"), "要说明删除走废纸篓：\(text)")
        XCTAssertTrue(text.contains("找不回"), "要说明清空废纸篓后不可恢复：\(text)")
        XCTAssertTrue(text.contains("保留"), "要说明转写稿与 manifest 保留：\(text)")
        XCTAssertTrue(text.contains("transcode"),
                      "要提示先压体积再清理的顺序：\(text)")
    }

    /// 跳过的场次要在弹窗里**逐条列出原因**。
    ///
    /// 只给一个「跳过了 N 场」的话，用户无法判断「我那场为什么没被清」——
    /// 而这正是他点这个功能时最想知道的事。
    func testConfirmationTextListsSkipReasons() throws {
        workspace.retentionPolicy = .days(30)
        _ = try makeSession(title: "没到档", ageDays: 3)
        _ = try makeSession(title: "没转写", ageDays: 200, transcript: false)
        _ = try makeSession(title: "到档了", ageDays: 200)
        let plan = try workspace.retentionPlan()

        let text = StatusItemController.retentionConfirmationText(plan: plan)

        XCTAssertTrue(text.contains("跳过"), "有跳过的场次时必须说出来：\(text)")
        XCTAssertTrue(text.contains("没到档"))
        XCTAssertTrue(text.contains("没转写"))
    }

    /// 跳过的场次超过 5 个时给个汇总，不要把弹窗撑到 50 行。
    func testConfirmationTextSummarisesWhenManySessionsAreSkipped() throws {
        workspace.retentionPolicy = .days(30)
        // 一场到档的（撑起非空账），加9 场没到档的（撑起跳过列表）
        _ = try makeSession(title: "到档了", ageDays: 200)
        for i in 0..<9 {
            _ = try makeSession(title: "近\(i)", ageDays: Double(i % 3))
        }
        let plan = try workspace.retentionPlan()
        XCTAssertGreaterThan(plan.skipped.count, 5)

        let text = StatusItemController.retentionConfirmationText(plan: plan)

        XCTAssertTrue(text.contains("另外"))
        XCTAssertTrue(text.contains("另外 \(plan.skipped.count - 5) 场"))
    }

    // MARK: - 顺序提醒（transcode 在前还是 prune 在前）

    /// 没压过的场次必须在**确认弹窗里**就说出「先压能多省多少」。
    ///
    /// 位置是关键：清理完再提醒是废话，那时候已经压不成了。
    func testConfirmationWarnsAboutUncompressedSessions() throws {
        workspace.retentionPolicy = .days(30)
        _ = try makeSession(title: "原始格式", ageDays: 200)

        let plan = try workspace.retentionPlan()
        let text = StatusItemController.retentionConfirmationText(plan: plan)

        XCTAssertTrue(text.contains("还没压过"), "必须点明这几场还没压：\n\(text)")
        XCTAssertTrue(text.contains("transcode"), "必须给出可执行的下一条命令")
        XCTAssertTrue(text.contains("多腾约"),
                      "必须给数字。原来说法只有一句泛泛的「顺序反了会删原始体积」，"
                      + "用户不知道差的是 2.4 MiB 还是 14.3 MiB")
    }

    /// 压过的场次**不该**再被提醒。
    ///
    /// 反向同样重要：一直说「还能再省 4 倍」是在骗人，那 4 倍已经省过了。
    func testConfirmationDoesNotWarnWhenAlreadyCompressed() throws {
        workspace.retentionPolicy = .days(30)
        _ = try makeSession(title: "压过了", ageDays: 200, compressed: true)

        let plan = try workspace.retentionPlan()
        let text = StatusItemController.retentionConfirmationText(plan: plan)

        XCTAssertFalse(text.contains("还没压过"),
                       "已经压过就不该再被提醒顺序：\n\(text)")
        XCTAssertTrue(text.contains("已经压过了"),
                      "该明确说「不用先转码」，而不是什么都不提")
    }

    /// 只有一半压过也算「还没压过」。
    ///
    /// 判据是「至少有一条轨还是原始格式」——按整体判断会漏掉这一批。
    func testConfirmationCountsPartiallyCompressedSessions() throws {
        workspace.retentionPolicy = .days(30)
        _ = try makeSession(title: "两场都没压", ageDays: 200)
        _ = try makeSession(title: "压过了", ageDays: 210, compressed: true)

        let plan = try workspace.retentionPlan()
        XCTAssertEqual(plan.uncompressedPrunable.count, 1)
        let text = StatusItemController.retentionConfirmationText(plan: plan)
        XCTAssertTrue(text.contains("1 场"), "应当只算那一场：\n\(text)")
    }
}