import XCTest
@testable import MRCore

/// 「源格式 + 开关 → 写入格式」这条决策。
///
/// 单独测它是因为**它是本轮唯一直接改变用户录音文件形态的逻辑**：
/// 错了不会报错，只会让文件变成另一副样子（声道数少一半、时长换算错一倍）。
final class TrackWriteFormatTests: XCTestCase {

    /// 默认（开关关闭）必须**原样返回**源格式。
    ///
    /// 这是「默认不能悄悄降质量」这条纪律在格式决策层的落点。
    ///
    /// 退化示例：把 `guard mono24k else` 那句删掉、直接走降级分支，
    /// 本用例立刻变红——而不勾开关的用户会静默拿到 24 kHz 单声道的录音。
    func testSwitchOffKeepsSourceFormat() {
        let stereo = TrackWriteFormat.resolve(
            sourceSampleRate: 48000, sourceChannels: 2, mono24k: false)
        XCTAssertEqual(stereo.sampleRate, 48000)
        XCTAssertEqual(stereo.channels, 2, "开关关闭时声道数必须原样保留")

        let mono = TrackWriteFormat.resolve(
            sourceSampleRate: 44100, sourceChannels: 1, mono24k: false)
        XCTAssertEqual(mono.sampleRate, 44100, "开关关闭时采样率也不能被动")
        XCTAssertEqual(mono.channels, 1)
    }

    /// 开关打开：48 kHz **立体声**（系统音频轨）→ 24 kHz、**单声道**。
    ///
    /// 退化示例：只降采样不降混（`channels: sourceChannels`），
    /// 体积只能降到 1/4 而不是 1/8 的那一半，且本用例变红。
    func testSwitchOnCollapsesStereoSystemTrack() {
        let write = TrackWriteFormat.resolve(
            sourceSampleRate: 48000, sourceChannels: 2, mono24k: true)
        XCTAssertEqual(write.sampleRate, 24000)
        XCTAssertEqual(write.channels, 1, "系统音频轨必须合并成单声道，否则第二声道是纯冗余")
    }

    /// 开关打开：48 kHz **单声道**（麦克风轨）→ 只降采样，声道不变。
    func testSwitchOnDownsamplesMonoMicTrack() {
        let write = TrackWriteFormat.resolve(
            sourceSampleRate: 48000, sourceChannels: 1, mono24k: true)
        XCTAssertEqual(write.sampleRate, 24000)
        XCTAssertEqual(write.channels, 1)
    }

    /// 源采样率**低于** 24 kHz 时保持源率，不做升采样。
    ///
    /// 插值不会凭空造出信息，只会让文件变大，还让下游误以为「这文件带宽到 12 kHz」。
    /// 16 kHz 的 USB 会议麦克风是真实存在的设备。
    ///
    /// 退化示例：把 `min(...)` 改成直接写 `mono24kSampleRate`，本用例变红。
    func testLowRateSourceIsNotUpsampled() {
        for rate in [16000.0, 22050.0, 8000.0] {
            let write = TrackWriteFormat.resolve(
                sourceSampleRate: rate, sourceChannels: 1, mono24k: true)
            XCTAssertEqual(write.sampleRate, rate, "源率 \(rate) 不该被升到 24 kHz")
            XCTAssertEqual(write.channels, 1)
        }
    }

    /// 正好等于 24 kHz 时保持不变（边界不该出现「升一点点」或「降一点点」）。
    func testExactlyTargetRateIsUnchanged() {
        let write = TrackWriteFormat.resolve(
            sourceSampleRate: 24000, sourceChannels: 2, mono24k: true)
        XCTAssertEqual(write.sampleRate, 24000)
        XCTAssertEqual(write.channels, 1, "采样率已达标，但声道仍要合并")
    }

    /// 目标采样率常量本身：**24000**，且只有一处定义。
    ///
    /// 这个数会同时出现在格式决策、真机用例断言、界面提示文案里。
    /// 把它钉成常量并在这里断言，是为了让「有人顺手改成 16000」时至少有一条用例会红。
    func testTargetSampleRateIsPinned() {
        XCTAssertEqual(TrackWriteFormat.mono24kSampleRate, 24000)
        XCTAssertEqual(
            TrackWriteFormat.resolve(sourceSampleRate: 96000, sourceChannels: 2, mono24k: true)
                .sampleRate,
            TrackWriteFormat.mono24kSampleRate,
            "96 kHz 设备也必须落到这个常量，而不是别的数")
    }

    /// 非法源采样率（0 / 负数）不许把非法值传下去——开关打开时按目标率走。
    ///
    /// 退化示例：去掉 `sourceSampleRate > 0` 的三元判断，`min(0, 24000)` 会得到 0，
    /// 而 `WAVWriter` 对采样率 0 是直接抛错的——症状会是「音轨初始化失败」，
    /// 却完全看不出与「设备报了个 0」有关。
    func testInvalidSourceRateFallsBackToTargetWhenSwitchOn() {
        for bad in [0.0, -48000.0] {
            let write = TrackWriteFormat.resolve(
                sourceSampleRate: bad, sourceChannels: 2, mono24k: true)
            XCTAssertEqual(write.sampleRate, TrackWriteFormat.mono24kSampleRate)
            XCTAssertEqual(write.channels, 1)
        }
    }

    /// 显示名要如实带上两个维度。
    func testDisplayNameMentionsBothDimensions() {
        XCTAssertEqual(
            TrackWriteFormat(sampleRate: 24000, channels: 1).displayName, "24000 Hz · 单声道")
        XCTAssertEqual(
            TrackWriteFormat(sampleRate: 48000, channels: 2).displayName, "48000 Hz · 2 声道")
    }

    // MARK: - 录制完成那一行的描述

    /// 源与写入**相同**时只有一段，不带括号。
    ///
    /// 退化示例：无条件加「（源 …）」，会让不开开关的普通录制也多出一段无信息量的文字，
    /// 用户会开始怀疑「是不是被改过」。
    func testDescribeHasNoParenthesisWhenSourceEqualsWrite() {
        let write = TrackWriteFormat(sampleRate: 48000, channels: 2)
        XCTAssertEqual(
            write.describe(sourceSampleRate: 48000, sourceChannels: 2),
            "48000 Hz · 2 声道")
    }

    /// 源与写入**不同**时：主位是**写入格式**，源格式进括号。
    ///
    /// 这个主次不能反。实测踩过：原先那行打的是 `TrackStats` 里的源格式，
    /// 开了单声道 24 kHz 之后看到「48000Hz 2ch」会以为开关没生效，
    /// 而盘上其实已经是 24k 单声道了。
    ///
    /// 退化示例：主位换成源格式（`describe` 里两个参数互换），断言立刻变红。
    func testDescribePutsWriteFormatFirstAndSourceInParenthesis() {
        let write = TrackWriteFormat(sampleRate: 24000, channels: 1)
        XCTAssertEqual(
            write.describe(sourceSampleRate: 48000, sourceChannels: 2),
            "24000 Hz · 单声道（源 48000 Hz · 2 声道）")
    }

    /// 只差一个维度也要带括号——不能只比采样率。
    ///
    /// 退化示例：把判断写成 `sourceSampleRate != sampleRate`（漏掉声道），
    /// 「48k 立体声 → 48k 单声道」这种只降声道的组合会被当成没变。
    func testDescribeDetectsChannelOnlyChange() {
        let write = TrackWriteFormat(sampleRate: 48000, channels: 1)
        XCTAssertEqual(
            write.describe(sourceSampleRate: 48000, sourceChannels: 2),
            "48000 Hz · 单声道（源 48000 Hz · 2 声道）")
    }

    /// 反向同理：只差采样率、声道相同，也要带括号。
    func testDescribeDetectsRateOnlyChange() {
        let write = TrackWriteFormat(sampleRate: 24000, channels: 1)
        XCTAssertEqual(
            write.describe(sourceSampleRate: 24000, sourceChannels: 1),
            "24000 Hz · 单声道",
            "源与写入完全相同，不该有括号")
        XCTAssertEqual(
            write.describe(sourceSampleRate: 16000, sourceChannels: 1),
            "24000 Hz · 单声道（源 16000 Hz · 1 声道）",
            "采样率不同（不升采样后保持 24000）也要带括号")
    }
}
