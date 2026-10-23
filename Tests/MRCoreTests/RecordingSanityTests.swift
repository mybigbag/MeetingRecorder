import XCTest
@testable import MRCore

/// 录制结束后的自检：发现「确实录了，但内容是空的」。
///
/// 为什么需要它：系统音频授权未生效时，录制会**正常完成**——时长正确、帧数正确、
/// manifest 写着 `finalized`、退出码 0，只有一个问题：每个采样都是零。
/// 使用者要等到回听、或者转写出空文稿时才会发现，那时会议已经结束了。
///
/// 这类「静默成功」必须在**收尾那一刻**就说出来，因为这是唯一还能重录的时机。
final class RecordingSanityTests: XCTestCase {

    private func track(
        _ id: String, frames: Int = 48000, peak: Double = 0.03
    ) -> RecordingSanity.Track {
        RecordingSanity.Track(
            id: id,
            role: id == "system" ? .systemAudio : .microphone,
            frames: frames, peakAmplitude: peak)
    }

    // MARK: - 正常情况不该打扰

    func testHealthyTracksProduceNoWarnings() {
        let warnings = RecordingSanity.warnings(tracks: [track("mic"), track("system")])
        XCTAssertTrue(warnings.isEmpty, "两轨都正常时不该有告警：\(warnings)")
    }

    func testVeryQuietButNonZeroTrackIsNotFlagged() {
        // 极小声但非零（例如对方只是敲键盘）不该被判成故障——
        // 判据是「是否全零」，不是「是否够响」。
        let warnings = RecordingSanity.warnings(tracks: [track("mic", peak: 0.0000001)])
        XCTAssertTrue(warnings.isEmpty, "非零就是有内容，不该误报：\(warnings)")
    }

    // MARK: - 全零必须告警

    func testAllZeroTrackIsFlagged() {
        let warnings = RecordingSanity.warnings(tracks: [track("mic"), track("system", peak: 0)])
        XCTAssertEqual(warnings.count, 1, "只有 system 轨全零，应恰好报一条：\(warnings)")
        XCTAssertTrue(warnings[0].contains("system"), "必须点名是哪一轨：\(warnings[0])")
    }

    func testAllZeroWarningSaysSamplesAreAllZero() {
        let warnings = RecordingSanity.warnings(tracks: [track("system", peak: 0)])
        XCTAssertTrue(warnings[0].contains("全零"),
                      "要说清「全是零」而不是含糊的「没有声音」：\(warnings[0])")
    }

    func testAllZeroSystemTrackWarningPointsAtAuthorization() {
        let warnings = RecordingSanity.warnings(tracks: [track("system", peak: 0)])
        XCTAssertTrue(warnings[0].contains("权限"),
                      "系统音频轨全零几乎都是授权问题，要直接给出方向：\(warnings[0])")
    }

    func testBothTracksAllZeroProducesTwoWarnings() {
        let warnings = RecordingSanity.warnings(tracks: [track("mic", peak: 0), track("system", peak: 0)])
        XCTAssertEqual(warnings.count, 2, "两轨都全零要分别报：\(warnings)")
    }

    // MARK: - 与「完全没采到」区分开

    func testTrackWithZeroFramesIsReportedSeparately() {
        let warnings = RecordingSanity.warnings(tracks: [track("system", frames: 0, peak: 0)])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("没有采到"),
                      "「一帧都没有」和「有帧但全零」原因不同，措辞必须能区分：\(warnings[0])")
    }

    func testZeroFrameTrackIsNotDescribedAsAllZero() {
        let warnings = RecordingSanity.warnings(tracks: [track("system", frames: 0, peak: 0)])
        XCTAssertFalse(warnings[0].contains("全零"),
                       "零帧时谈不上「采样全零」，别把两种故障混成一句：\(warnings[0])")
    }

    // MARK: - 麦克风轨的告警不能照搬系统音频轨那套

    func testMicrophoneAllZeroDoesNotAdviseUsingTheProbeTone() {
        // 实测踩过：默认输入是 AirPods 时，它会切到 24kHz 通话模式并开启回声消除，
        // 把系统播放的提示音**整段滤掉**——链路完全正常也得到全零。
        // 所以麦克风轨绝不能给出「播提示音确诊」这条错路。
        let warnings = RecordingSanity.warnings(tracks: [track("mic", peak: 0)])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertFalse(warnings[0].contains("主动播一段提示音"),
                       "麦克风轨不能建议「跑 doctor 播提示音确诊」，那条路对它是错的：\(warnings[0])")
    }

    func testMicrophoneAllZeroNamesSpeakingAsTheOnlyVerification() {
        let warnings = RecordingSanity.warnings(tracks: [track("mic", peak: 0)])
        XCTAssertTrue(warnings[0].contains("说一句话"),
                      "麦克风轨唯一可靠的验证是「说句话再录一次」：\(warnings[0])")
    }

    func testMicrophoneAllZeroNamesTheHarmlessExplanation() {
        // 「这一段没人说话」和「麦克风真的坏了」从录音数据上无法区分，
        // 所以必须把前者（完全正常）说出来，不许只报故障。
        let warnings = RecordingSanity.warnings(tracks: [track("mic", peak: 0)])
        XCTAssertTrue(warnings[0].contains("没说话"),
                      "必须把「你可能只是没说话」这个正常解释讲清楚：\(warnings[0])")
    }

    func testSystemTrackKeepsTheProbeToneAdvice() {
        // 系统音频轨正相反：提示音确实能确诊——tap 抓的是音频数据流，
        // 不经过麦克风，也就绕过了回声消除。
        let warnings = RecordingSanity.warnings(tracks: [track("system", peak: 0)])
        XCTAssertTrue(warnings[0].contains("提示音"),
                      "系统音频轨仍应给出「跑 doctor 播提示音」这条路：\(warnings[0])")
    }

    // MARK: - 边界

    func testEmptyTrackListProducesNoWarnings() {
        XCTAssertTrue(RecordingSanity.warnings(tracks: []).isEmpty)
    }

    func testIsAllZeroDefinition() {
        XCTAssertTrue(
            RecordingSanity.Track(id: "a", role: .microphone, frames: 10, peakAmplitude: 0).isAllZero)
        XCTAssertFalse(
            RecordingSanity.Track(id: "a", role: .microphone, frames: 10, peakAmplitude: 1e-9).isAllZero)
        XCTAssertFalse(
            RecordingSanity.Track(id: "a", role: .microphone, frames: 0, peakAmplitude: 0).isAllZero,
            "零帧不属于「全零」，那是另一种情况")
    }

    func testWarningsAreStableOrdered() {
        let tracks = [track("mic", peak: 0), track("system", peak: 0)]
        XCTAssertEqual(RecordingSanity.warnings(tracks: tracks),
                       RecordingSanity.warnings(tracks: tracks))
    }

    // MARK: - 全零的原因已查明：降混抵消

    /// 已知被抵消时，告警**必须说那个原因**，不能并列「可能是权限未生效」。
    ///
    /// 这条来自真机实测：反相内容经 `average` 降混后整轨归零，
    /// 同时收到「抵消」与「全零」两条告警 —— 而后者会把人引去查
    /// 「屏幕与系统音频录制」权限，权限明明是好的，白跑一趟 `doctor`。
    /// **指错方向比多报一条更贵。**
    func testKnownCancellationSaysSoInsteadOfBlamingPermissions() {
        let t = RecordingSanity.Track(
            id: "system", role: .systemAudio, frames: 48000, peakAmplitude: 0,
            allZeroCause: .downmixCancellation)
        let warnings = RecordingSanity.warnings(tracks: [t])

        XCTAssertEqual(warnings.count, 1, "同一件事只报一条，实际：\(warnings)")
        let text = warnings[0]
        XCTAssertTrue(text.contains("抵消"), "必须说出真实原因：\(text)")
        XCTAssertTrue(text.contains("不是权限"), "必须明确排除权限方向：\(text)")
        XCTAssertFalse(text.contains("doctor"),
                       "已知原因时不该再把用户引去跑 doctor：\(text)")
        XCTAssertFalse(text.contains("两种可能"),
                       "已知原因时不该并列猜测：\(text)")
    }

    /// 原因已知时仍要给出**可执行的下一步**——只说「被抵消了」用户仍不知道改哪里。
    func testKnownCancellationStillSaysHowToAvoidIt() {
        let t = RecordingSanity.Track(
            id: "system", role: .systemAudio, frames: 48000, peakAmplitude: 0,
            allZeroCause: .downmixCancellation)
        let text = RecordingSanity.warnings(tracks: [t])[0]
        XCTAssertTrue(text.contains("config set downmix first-channel"),
                      "必须给出可直接执行的命令：\(text)")
        XCTAssertTrue(text.contains("降混策略"), "必须指出菜单里的位置：\(text)")
        XCTAssertTrue(text.contains("system"), "必须点名是哪一轨：\(text)")
    }

    /// 未查明原因时**保持原样**走那两套猜测文案。
    ///
    /// 这条守住「新增字段没有把原有行为改掉」——默认 `allZeroCause == nil`
    /// 必须与改动前逐字一致。
    func testUnknownCauseStillProducesTheOriginalGuesses() {
        let system = RecordingSanity.warnings(tracks: [track("system", peak: 0)])
        XCTAssertEqual(system.count, 1)
        XCTAssertTrue(system[0].contains("两种可能"),
                      "未查明原因时必须并列两种可能：\(system[0])")
        XCTAssertTrue(system[0].contains("doctor"),
                      "未查明原因时必须给出 doctor 这条确诊路径：\(system[0])")

        let mic = RecordingSanity.warnings(tracks: [track("mic", peak: 0)])
        XCTAssertTrue(mic[0].contains("麦克风"), "麦克风轨要用自己那套文案：\(mic[0])")
    }

    /// 原因已查明**但这一轨不是全零**时，不该报「已查明」——
    /// 抵消可能只发生在部分时段（后面又录到声音了），全零才需要解释。
    func testKnownCancellationOnANonSilentTrackIsNotReported() {
        let t = RecordingSanity.Track(
            id: "system", role: .systemAudio, frames: 48000, peakAmplitude: 0.02,
            allZeroCause: .downmixCancellation)
        XCTAssertTrue(RecordingSanity.warnings(tracks: [t]).isEmpty,
                      "这一轨录到了声音，不需要解释为什么没声")
    }

    /// 零帧 + 已知原因：仍然报「一帧都没采到」。
    ///
    /// 「根本没采到」与「采到了但被抵消」是不同的事，处置也不同，
    /// 不能因为填了 `allZeroCause` 就改判。
    func testZeroFramesStillReportsNoAudioAtAll() {
        let t = RecordingSanity.Track(
            id: "system", role: .systemAudio, frames: 0, peakAmplitude: 0,
            allZeroCause: .downmixCancellation)
        let text = RecordingSanity.warnings(tracks: [t])[0]
        XCTAssertTrue(text.contains("一帧都没有"), "零帧必须报「没采到」：\(text)")
    }
}
