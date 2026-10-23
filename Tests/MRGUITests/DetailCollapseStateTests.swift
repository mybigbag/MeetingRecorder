import XCTest
@testable import MRGUI
import MRCore
import MRSession
import MRMinutes

/// 详情页三栏折叠的状态管理（`DetailCollapseState`）。
///
/// ## 折叠是为「一眼看到想看的那一栏」服务的
///
/// 一场一小时的会议转写稿动辄几百段，音轨占着两整块波形，
/// 纪要也可能很长。不折就得滚过所有不关心的东西。
///
/// 两条不变量，**缺一条这个功能就不成立**：
///
/// 1. **按会议记**，不是一个全局开关——切到下一场时不该把上一场的
///    折叠意图一起带走，回来的路上又得再点一次，正是折叠想省掉的那一下。
/// 2. **按区块记**，不是一个 Bool——折了转写稿不代表该折音轨。
///    常见意图恰恰是「音轨留着随时能听、纪要留着随时能看、转写稿折起来」。
final class DetailCollapseStateTests: XCTestCase {

    private let a = "2026-10-19-143012-版本下线评审"
    private let b = "2026-10-19-160000-另一场"

    // MARK: - 默认状态

    /// **打开一场会议：音轨与转写稿折着，纪要展开。**
    ///
    /// 2026-10-22 改动针对的就是这条。理由写在
    /// `DetailSection.isCollapsedByDefault` 里：三栏的「打开目的」不一样——
    /// 纪要是这场会讲了什么（要先看），转写稿是核对用的底稿（几百段），
    /// 音轨只在要听的时候才需要（播放控制条本来就不在折叠里）。
    ///
    /// 退化示例：把默认写反（全展开），用户每次打开都得先滚过整篇原文才看得到纪要。
    func testDefaultsCollapseTracksAndTranscriptOnly() {
        let state = DetailCollapseState()
        for session in [a, b] {
            XCTAssertTrue(state.isCollapsed(.tracks, in: session), "音轨默认应折叠")
            XCTAssertTrue(state.isCollapsed(.transcript, in: session), "转写稿默认应折叠")
            XCTAssertFalse(state.isCollapsed(.minutes, in: session), "纪要默认必须展开")
        }
    }

    /// 默认值不许依赖「有没有人碰过」——新建出来的状态就该是那三句话。
    func testDefaultIsIndependentPerSection() {
        XCTAssertTrue(DetailSection.tracks.isCollapsedByDefault)
        XCTAssertTrue(DetailSection.transcript.isCollapsedByDefault)
        XCTAssertFalse(DetailSection.minutes.isCollapsedByDefault)
    }

    // MARK: - 按会议独立

    /// **改 A 的折叠不许顺带改 B。**
    ///
    /// 这是整个类型存在的理由。退化示例：把 `overrides` 换成一个 `Bool`，
    /// `isCollapsed` 无视 `sessionID` 直接返回它——编译照过、界面照常折叠，
    /// 只有本用例会红。真实症状是：在 A 展开转写稿去看 B，B 也展开了。
    func testChangingOneSessionDoesNotAffectAnother() {
        var state = DetailCollapseState()
        state.setCollapsed(false, for: .transcript, in: a)   // 在 A 展开
        XCTAssertFalse(state.isCollapsed(.transcript, in: a))
        XCTAssertTrue(state.isCollapsed(.transcript, in: b), "A 的改动绝不能影响 B")
    }

    /// 切走再回来，**用户的意图还在**。
    ///
    /// 折叠/展开都是「这一场的这一栏」的意图，往返一圈不该被重置。
    func testExplicitChoiceSurvivesVisitingAnotherMeeting() {
        var state = DetailCollapseState()
        state.setCollapsed(false, for: .transcript, in: a)   // 在 A 展开
        state.setCollapsed(false, for: .transcript, in: b)   // 去看了 B 也展开
        XCTAssertFalse(state.isCollapsed(.transcript, in: a), "回来时 A 必须仍是展开的")
        XCTAssertFalse(state.isCollapsed(.transcript, in: b))
    }

    /// 反复点必须能来回切换，且**不留残留**。
    ///
    /// 从默认值点两次回到默认值，`overrideCount` 必须回到 0——
    /// 留着一条「等于默认值」的记录不影响显示，但会让「用户动过几处」
    /// 这类判断失真。
    func testTogglingTwiceReturnsToDefaultWithoutResidue() {
        var state = DetailCollapseState()
        state.toggle(.tracks, in: a)                        // 默认折叠 → 展开
        XCTAssertFalse(state.isCollapsed(.tracks, in: a))
        state.toggle(.tracks, in: a)                        // 再点 → 回到折叠
        XCTAssertTrue(state.isCollapsed(.tracks, in: a))
        state.toggle(.minutes, in: a)                       // 默认展开 → 折叠
        state.toggle(.minutes, in: a)                       // 再点 → 回到展开
        XCTAssertFalse(state.isCollapsed(.minutes, in: a))
        XCTAssertEqual(state.overrideCount, 0, "来回切换不该留下残留")
    }

    /// `setCollapsed` 要幂等，且值等于默认时不留记录。
    ///
    /// 退化示例：「总是 insert」的实现看不出问题，但「总是 remove」的实现
    /// 会让显式设定失效——那才是真 bug。
    func testSetCollapsedIsIdempotent() {
        var state = DetailCollapseState()
        state.setCollapsed(true, for: .tracks, in: a)       // 与默认相同
        state.setCollapsed(true, for: .tracks, in: a)
        XCTAssertTrue(state.isCollapsed(.tracks, in: a))
        XCTAssertEqual(state.overrideCount, 0, "与默认一致的值不该留下记录")

        state.setCollapsed(false, for: .tracks, in: a)      // 显式展开
        state.setCollapsed(false, for: .tracks, in: a)
        XCTAssertFalse(state.isCollapsed(.tracks, in: a), "显式展开必须真的能展开")
        XCTAssertEqual(state.overrideCount, 1)
    }

    // MARK: - 按区块独立

    /// **展开转写稿不许顺带展开音轨或折起纪要。**
    ///
    /// 这条比上一条更容易被实现破坏：把状态写成「只有 sessionID 的集合」
    /// 再用一个全局 section 变量，编译完全没问题，但「点开转写稿」
    /// 会把三栏一起带走——那不叫折叠，叫连带关闭。
    func testSectionsStayIndependent() {
        var state = DetailCollapseState()
        state.setCollapsed(false, for: .transcript, in: a)  // 展开转写稿
        XCTAssertFalse(state.isCollapsed(.transcript, in: a))
        XCTAssertTrue(state.isCollapsed(.tracks, in: a), "展开转写稿不该展开音轨")
        XCTAssertFalse(state.isCollapsed(.minutes, in: a), "展开转写稿不该折叠纪要")

        state.setCollapsed(true, for: .minutes, in: a)      // 折起纪要
        XCTAssertTrue(state.isCollapsed(.minutes, in: a))
        XCTAssertTrue(state.isCollapsed(.tracks, in: a))
        XCTAssertFalse(state.isCollapsed(.transcript, in: a), "折纪要不该动转写稿")
    }

    /// 三栏都折起来是真实需求（快速核对一个数字），且能只展开其中一栏。
    func testAllSectionsCanCollapseAndOneCanReopen() {
        var state = DetailCollapseState()
        for section in DetailSection.allCases {
            state.setCollapsed(true, for: section, in: a)
        }
        for section in DetailSection.allCases {
            XCTAssertTrue(state.isCollapsed(section, in: a), "\(section) 应该折着")
        }
        state.setCollapsed(false, for: .minutes, in: a)
        XCTAssertFalse(state.isCollapsed(.minutes, in: a))
        XCTAssertTrue(state.isCollapsed(.tracks, in: a))
        XCTAssertTrue(state.isCollapsed(.transcript, in: a))
    }

    /// 区块集合本身也要被钉住：三个都在、名字稳定。
    ///
    /// 少一个区块 = 那一栏没有折叠按钮，而界面上看不出任何异常。
    func testSectionSetCoversAllThreeColumns() {
        XCTAssertEqual(Set(DetailSection.allCases),
                       [.tracks, .minutes, .transcript])
    }
}

/// 转写稿标题旁那句段数提示（`MeetingDetailView.transcriptTitleHint`）。
///
/// 它是折叠状态下**唯一**关于正文的信息：正文收起来之后，
/// 用户点不点开全凭这一行判断。
final class TranscriptTitleHintTests: XCTestCase {

    private func document(segments: Int) -> TranscriptDocument {
        TranscriptDocument(
            sessionID: "s", title: "t", language: "zh-CN", engine: "apple",
            segments: (0..<segments).map { index in
                TranscriptSegment(
                    start: Double(index), end: Double(index) + 1,
                    text: "第 \(index) 段", track: "mic", speaker: "我")
            })
    }

    /// 有稿子就报段数。**没有这一行，折叠就没有任何判断依据**。
    func testShowsSegmentCount() {
        XCTAssertEqual(MeetingDetailView.transcriptTitleHint(document: document(segments: 128)),
                       "128 段")
    }

    /// 没稿子要说「未转写」，不是「0 段」。
    ///
    /// 「0 段」会被读成「转写过了但没识别到内容」，
    /// 而真实情况是压根没转写——用户会以为转写坏了。
    func testDistinguishesNotTranscribedFromEmpty() {
        XCTAssertEqual(MeetingDetailView.transcriptTitleHint(document: nil), "未转写")
    }

    /// 转写了但一个段都没有（全是静音）要说「0 段」。
    ///
    /// 与「未转写」必须分开：前者的下一步是「换个引擎重转」，
    /// 后者的下一步是「开始转写」。
    func testEmptyTranscriptSaysZeroSegments() {
        XCTAssertEqual(MeetingDetailView.transcriptTitleHint(document: document(segments: 0)),
                       "0 段")
    }
}

/// 音轨栏折叠时的两句提示（标题旁 + 折叠后那一行）。
final class TracksCollapseHintTests: XCTestCase {

    /// 有轨就报条数——折叠时用户要判断的是「里面有没有东西可看/可听」。
    func testShowsTrackCount() {
        XCTAssertEqual(MeetingDetailView.tracksTitleHint(availableTrackCount: 2), "2 条")
    }

    /// 一条都没有要说「无可播放音轨」，不能报「0 条」。
    ///
    /// 「0 条」会被读成「录到了但一条都用不了」，
    /// 而真实情况可能是音频已被清理策略删掉——用户该知道的是
    /// 「这里没什么可播的」，而不是「出了什么问题」。
    func testSaysNoPlayableTrackInsteadOfZero() {
        XCTAssertEqual(MeetingDetailView.tracksTitleHint(availableTrackCount: 0),
                       "无可播放音轨")
    }

    /// 折叠后那一行**必须说明播放控制还在**。
    ///
    /// 这是折叠音轨最容易出的错：播放条被折进去之后，
    /// 用户看到音频在响（声音是真的）而界面上一个活的控件都不剩，
    /// 会以为播放器坏了、只能展开去找。写清楚「播放、停止、进度条不受影响」
    /// 就把这件事说清了。
    func testCollapsedHintPromisesTransportBarStillWorks() {
        let hint = MeetingDetailView.tracksCollapsedHint(availableTrackCount: 2)
        XCTAssertTrue(hint.contains("播放"), hint)
        XCTAssertTrue(hint.contains("停止"), hint)
        XCTAssertTrue(hint.contains("进度条"), hint)
    }

    /// 没有可播放音轨时不要承诺播放控制可用——那是空头支票。
    func testCollapsedHintDoesNotPromisePlaybackWhenThereIsNoTrack() {
        let hint = MeetingDetailView.tracksCollapsedHint(availableTrackCount: 0)
        XCTAssertFalse(hint.contains("播放、停止"), hint)
        XCTAssertTrue(hint.contains("没有"), hint)
    }
}

/// 纪要栏折叠时的两句提示。
///
/// **降级稿在这里必须被点名两次**（标题旁 + 折叠后那一行）：
/// 它是本机（无 Apple Intelligence）默认会看到的那一份，
/// 而读起来和有摘要的稿子几乎一样——折叠之后用户看不到橙色警告，
/// 只能靠这两行字知道真相。
final class MinutesCollapseHintTests: XCTestCase {

    private func result(generatedByModel: Bool) -> MinutesResult {
        MinutesResult(
            blocks: [], blockSummaries: [],
            minutes: MeetingMinutes(summary: generatedByModel ? "定 10-20 下线" : ""),
            polishedTranscript: "正文",
            generatedByModel: generatedByModel,
            generatorName: generatedByModel ? "云端 API（deepseek-chat）" : "")
    }

    func testIdleWithoutResultSaysNotGenerated() {
        XCTAssertEqual(MeetingDetailView.minutesTitleHint(phase: .idle, result: nil), "未生成")
    }

    func testRunningSaysRunning() {
        XCTAssertEqual(MeetingDetailView.minutesTitleHint(phase: .running(summary: "总结中"), result: nil),
                       "生成中…")
    }

    func testFailedSaysFailed() {
        XCTAssertEqual(MeetingDetailView.minutesTitleHint(phase: .failed("401"), result: nil),
                       "生成失败")
    }

    /// 正常稿说「已生成」，降级稿说「降级稿」——**两者绝不能混**。
    ///
    /// 混了就是把一份「模型没跑起来」的稿子说成正常稿，
    /// 而用户会据此以为「这次会议没有结论」。
    func testDegradedIsNeverReportedAsGenerated() {
        XCTAssertEqual(
            MeetingDetailView.minutesTitleHint(phase: .idle,
                                               result: result(generatedByModel: false)),
            "降级稿")
        XCTAssertEqual(
            MeetingDetailView.minutesTitleHint(phase: .idle,
                                               result: result(generatedByModel: true)),
            "已生成")
    }

    /// 折叠后那一行在降级时必须带警告，不能只是一句中性说明。
    func testCollapsedHintNamesDegradedDraft() {
        let hint = MeetingDetailView.minutesCollapsedHint(
            phase: .idle, result: result(generatedByModel: false))
        XCTAssertTrue(hint.contains("降级"), hint)
        XCTAssertTrue(hint.contains("未生成摘要"), hint)
    }

    func testCollapsedHintIsNeutralForHealthyDraft() {
        let hint = MeetingDetailView.minutesCollapsedHint(
            phase: .idle, result: result(generatedByModel: true))
        XCTAssertFalse(hint.contains("降级"), hint)
        XCTAssertTrue(hint.contains("摘要"), hint)
    }

    /// 折叠时正在生成：要指向进度，而不是说「还没有纪要」。
    ///
    /// 后者会让用户以为刚才那次生成失败了，而它正在跑。
    func testCollapsedHintPointsAtProgressWhileRunning() {
        let hint = MeetingDetailView.minutesCollapsedHint(phase: .running(summary: "总结中"), result: nil)
        XCTAssertTrue(hint.contains("正在生成"), hint)
        XCTAssertFalse(hint.contains("还没有纪要"), hint)
    }

    /// 折叠时失败：要指向失败原因与重试入口。
    func testCollapsedHintPointsAtFailure() {
        let hint = MeetingDetailView.minutesCollapsedHint(phase: .failed("401 未授权"), result: nil)
        XCTAssertTrue(hint.contains("失败原因"), hint)
        XCTAssertTrue(hint.contains("重试"), hint)
    }
}
/// 转写稿正文「到底折不折」（`MeetingDetailView.transcriptShowsCollapsedBody`）。
///
/// 默认折叠之后新出现的一个坑：**没稿子的会议也会被折起来**。
/// 那时折叠提示写的是「展开可读全文」，而里面既没有全文，
/// 也看不到「点右上开始转写」这句唯一的指引——用户只会以为转写坏了。
final class TranscriptCollapseRuleTests: XCTestCase {

    /// 有稿子 + 用户/默认要折 → 折。
    func testCollapsesWhenThereIsADocument() {
        XCTAssertTrue(MeetingDetailView.transcriptShowsCollapsedBody(
            requested: true, hasDocument: true))
    }

    /// **没有稿子就不折**：折叠只收「已有的成稿」。
    func testNeverCollapsesWithoutADocument() {
        XCTAssertFalse(MeetingDetailView.transcriptShowsCollapsedBody(
            requested: true, hasDocument: false))
    }

    /// 用户明确展开时，有稿子也不折。
    func testRespectsExplicitExpansion() {
        XCTAssertFalse(MeetingDetailView.transcriptShowsCollapsedBody(
            requested: false, hasDocument: true))
    }
}
