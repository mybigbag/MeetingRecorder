import XCTest
@testable import MRCore

/// 采集能力的就绪度判定。
///
/// 这个类型存在的理由是一次真实的误判：`doctor` 曾经只检查到「tap 创建成功」就报全绿，
/// 而当时 coreaudiod 已经卡死、真实录制 100% 失败。**诊断工具撒谎比没有诊断工具更糟**，
/// 它会让人把故障环境当成好的，然后在更晚、代价更高的地方才暴露问题。
///
/// 判定必须同时满足两个要求：
/// 1. **没真的跑通 IOProc 并收到 buffer，不许说 ready。**
/// 2. **要能表达「半坏」**——只剩麦克风轨时，录出来只有自己的声音、听不到对方，
///    对会议录音来说这是降级而不是可用。混在「ready」里同样是撒谎。
final class CaptureReadinessTests: XCTestCase {

    private func input(
        isAppBundle: Bool = true,
        tapCreated: Bool = true,
        system: CaptureReadiness.Probe = .notAttempted,
        mic: CaptureReadiness.Probe = .notAttempted,
        probeTonePlayed: Bool = false,
        deviceEnumeration: Bool = true,
        sharedDevice: Bool = false
    ) -> CaptureReadiness.Input {
        CaptureReadiness.Input(
            isAppBundle: isAppBundle, tapCreated: tapCreated,
            systemProbe: system, micProbe: mic,
            probeTonePlayed: probeTonePlayed,
            deviceEnumerationWorked: deviceEnumeration,
            inputSharesOutputDevice: sharedDevice)
    }

    private func text(_ r: CaptureReadiness.Report) -> String {
        ([r.headline] + r.details).joined(separator: "\n")
    }

    // MARK: - ready 的唯一条件：两轨都真的收到 buffer

    func testReadyOnlyWhenBothTracksProducedData() {
        XCTAssertEqual(
            CaptureReadiness.assess(input(system: .warmed, mic: .warmed)).verdict,
            .ready)
    }

    func testReadyRequiresActualBufferNotJustLinkSetup() {
        // 本文件的核心断言：链路搭好但没收到数据，绝不能说 ready。
        // 权限未授予时正是「链路全通 + 缓冲区全零」这个表现。
        XCTAssertNotEqual(
            CaptureReadiness.assess(input(system: .noData, mic: .noData)).verdict,
            .ready)
    }

    func testSingleTrackIsDegradedNotReady() {
        // 只有麦克风：录得到自己，录不到对方——对会议录音而言是降级。
        let micOnly = CaptureReadiness.assess(input(system: .noData, mic: .warmed))
        XCTAssertEqual(micOnly.verdict, .degraded)

        // 只有系统音频：录得到对方，录不到自己。
        let systemOnly = CaptureReadiness.assess(input(system: .warmed, mic: .noData))
        XCTAssertEqual(systemOnly.verdict, .degraded)
    }

    func testDegradedReportNamesWhichTrackIsMissing() {
        let micOnly = CaptureReadiness.assess(input(system: .noData, mic: .warmed))
        XCTAssertTrue(text(micOnly).contains("系统音频"),
                      "降级必须指明缺的是哪一轨，否则用户不知道该修什么")

        let systemOnly = CaptureReadiness.assess(input(system: .warmed, mic: .noData))
        XCTAssertTrue(text(systemOnly).contains("麦克风"),
                      "降级必须指明缺的是哪一轨")
    }

    // MARK: - 明确故障

    func testBothTracksTimingOutIsBroken() {
        let report = CaptureReadiness.assess(input(system: .timedOut, mic: .timedOut))
        XCTAssertEqual(report.verdict, .broken,
                       "两轨 HAL 都超时就是 coreaudiod 级卡死，必须判 broken")
    }

    func testHALTimeoutReportNamesTheRecoveryCommand() {
        let report = CaptureReadiness.assess(input(system: .timedOut, mic: .timedOut))
        XCTAssertTrue(text(report).contains("killall coreaudiod"),
                      "既然是 HAL 卡死，就必须直接给出恢复命令，别让人去猜")
    }

    func testSingleTrackTimeoutStillSurfacesTheRecoveryHint() {
        // 只有一轨超时时整体未必是 broken（另一轨可能能用），
        // 但恢复提示不能因此丢掉——否则用户永远看不到这条线索。
        let report = CaptureReadiness.assess(input(system: .timedOut, mic: .warmed))
        XCTAssertTrue(text(report).contains("killall coreaudiod"),
                      "只要出现过 HAL 超时，就必须把恢复命令带出来")
    }

    // MARK: - HAL 超时的建议顺序（曾被写反，代价是多余的 killall）

    func testHALTimeoutAdvisesWaitingBeforeKillingAudioService() {
        // 两次实测卡死都自行缓解了，coreaudiod 进程号始终不变。
        // 所以「先等几分钟」必须排在 killall 之前——旧版把 killall 当第一条建议，
        // 会让人去做一次本可避免、且会中断全机音频的操作。
        let body = text(CaptureReadiness.assess(input(system: .timedOut, mic: .timedOut)))

        guard let wait = body.range(of: "先等")?.lowerBound else {
            return XCTFail("HAL 超时的建议里必须包含「先等待」这条路")
        }
        guard let kill = body.range(of: "killall")?.lowerBound else {
            return XCTFail("恢复命令仍需保留")
        }
        XCTAssertLessThan(wait, kill,
                          "「先等」必须出现在 killall 之前；顺序反了就会误导人做多余操作")
    }

    func testHALTimeoutAdviceNeverClaimsItCannotRecoverOnItsOwn() {
        // 明确锁住那句被推翻的话不许回来。
        let body = text(CaptureReadiness.assess(input(system: .timedOut, mic: .timedOut)))
        XCTAssertFalse(body.contains("不会自行恢复"),
                       "实测卡死会自行缓解，不许再写「不会自行恢复」")
    }

    // MARK: - 卡死的深度：枚举正常 vs 枚举也没回来

    func testShallowHALTimeoutWithWorkingEnumerationBlamesOnlyIOProc() {
        // 实测见过的中间态：设备照常枚举出来，只有 IOProc 创建超时。
        let report = CaptureReadiness.assess(
            input(system: .timedOut, mic: .timedOut, deviceEnumeration: true))
        XCTAssertEqual(report.verdict, .broken)
        XCTAssertTrue(text(report).contains("枚举"),
                      "枚举正常时必须点名「卡住的只是 IOProc 创建」，别笼统说 audio 服务卡死")
    }

    func testDeepHALTimeoutWithDeadEnumerationSaysWholeHALIsUnresponsive() {
        // 连枚举都回不来，才是整个 HAL 无响应。
        let report = CaptureReadiness.assess(
            input(system: .timedOut, mic: .timedOut, deviceEnumeration: false))
        XCTAssertEqual(report.verdict, .broken)
        let body = text(report)
        XCTAssertTrue(body.contains("HAL"),
                      "枚举也失败时要说明是 HAL 层整体无响应")
        XCTAssertTrue(body.contains("killall coreaudiod"),
                      "深层卡死必须直接给出恢复命令")
    }

    func testBothDepthsStayBrokenRegardlessOfEnumeration() {
        // 深度只改变「怎么恢复」，不改变「能不能用」——两种都不可用。
        XCTAssertEqual(
            CaptureReadiness.assess(
                input(system: .timedOut, mic: .timedOut, deviceEnumeration: true)).verdict,
            .broken)
        XCTAssertEqual(
            CaptureReadiness.assess(
                input(system: .timedOut, mic: .timedOut, deviceEnumeration: false)).verdict,
            .broken)
    }

    func testBareCLIWithoutAppBundleIsBroken() {
        let report = CaptureReadiness.assess(
            input(isAppBundle: false, tapCreated: false))
        XCTAssertEqual(report.verdict, .broken)
    }

    func testBareCLIProblemIsReportedBeforeAnythingElse() {
        let report = CaptureReadiness.assess(
            input(isAppBundle: false, tapCreated: false))
        XCTAssertTrue(text(report).contains(".app"),
                      "裸 CLI 是更根本的原因，必须先说；否则用户会去查权限而不是去打包")
    }

    func testBareCLIStaysBrokenEvenIfProbesSucceeded() {
        // 裸 CLI 下链路有时也能「全通」，但采集一定是全零——不能让成功假象覆盖形态问题。
        let report = CaptureReadiness.assess(
            input(isAppBundle: false, tapCreated: true, system: .warmed, mic: .warmed))
        XCTAssertEqual(report.verdict, .broken,
                       "非 .app 形态下链路全通也是假象，必须仍判 broken")
    }

    func testTapFailureWithNoWorkingMicIsBroken() {
        let report = CaptureReadiness.assess(
            input(tapCreated: false, system: .notAttempted, mic: .noData))
        XCTAssertEqual(report.verdict, .broken,
                       "系统音频 tap 建不起来、麦克风也没数据 —— 什么录不了")
    }

    func testTapFailureButWorkingMicIsDegraded() {
        let report = CaptureReadiness.assess(
            input(tapCreated: false, system: .notAttempted, mic: .warmed))
        XCTAssertEqual(report.verdict, .degraded,
                       "系统音频不可用但麦克风能录 —— 还能录，只是不完整")
    }

    // MARK: - 链路通但未证实

    func testNothingProvenIsUnproven() {
        XCTAssertEqual(
            CaptureReadiness.assess(input(system: .notAttempted, mic: .notAttempted)).verdict,
            .unproven)
        XCTAssertEqual(
            CaptureReadiness.assess(input(system: .noData, mic: .noData)).verdict,
            .unproven)
    }

    func testUnprovenReportMentionsPermission() {
        let report = CaptureReadiness.assess(input(system: .noData, mic: .noData))
        XCTAssertTrue(text(report).contains("权限"),
                      "没有数据最常见的原因就是权限未授予，必须往这个方向引导排查")
    }

    // MARK: - 静默失败：缓冲区到了，但采样值全是零

    func testSilentTrackIsNotReady() {
        // 这是实测踩到的真实故障：链路全通、buffer 按时到达、帧数完全正确，
        // 但采样值全是零。上一版的 doctor 到这一步会报「✅ 收到数据」。
        let report = CaptureReadiness.assess(input(system: .silent, mic: .warmed))
        XCTAssertNotEqual(report.verdict, .ready,
                          "缓冲区到了不等于有数据；全零必须判为不可用")
    }

    func testSilentSystemTrackWithWorkingMicIsDegraded() {
        let report = CaptureReadiness.assess(input(system: .silent, mic: .warmed))
        XCTAssertEqual(report.verdict, .degraded)
    }

    func testSilentTrackReportSaysSamplesAreAllZero() {
        let report = CaptureReadiness.assess(input(system: .silent, mic: .warmed))
        XCTAssertTrue(text(report).contains("全零"),
                      "必须明确说出「采样全零」，否则用户会以为链路有问题去查错方向")
    }

    func testSilentSystemTrackReportPointsAtPermission() {
        let report = CaptureReadiness.assess(input(system: .silent, mic: .warmed))
        XCTAssertTrue(text(report).contains("权限"),
                      "系统音频轨全零最常见的原因就是授权没生效，必须往这个方向引导")
    }

    func testBothSilentIsUnproven() {
        let report = CaptureReadiness.assess(input(system: .silent, mic: .silent))
        XCTAssertEqual(report.verdict, .unproven,
                       "两轨都全零：没有任何一轨被证实能出数据")
    }

    func testSilentMicWithWorkingSystemIsDegraded() {
        let report = CaptureReadiness.assess(input(system: .warmed, mic: .silent))
        XCTAssertEqual(report.verdict, .degraded)
        XCTAssertTrue(text(report).contains("麦克风"), "必须点名缺的是麦克风轨")
    }

    // MARK: - 自播测试音：把「全零」从二义变成确诊
    //
    // 这是本文件里第二重要的开关。系统轨采到全零有两个完全不同的成因：
    //   ① 授权没生效（必须去修）
    //   ② 探测时系统本来就没在出声（完全正常）
    // 二者单看数据无法区分。doctor 实测踩过：系统安静时报「采集降级」，
    // 而同一份二进制在放声音时录得好好的——**方向还是反的**。
    //
    // 解法是探测期间主动播一段系统提示音：喂了声音还是全零，②就被排除掉了。

    func testSilentSystemTrackWithTonePlayedIsBroken() {
        let report = CaptureReadiness.assess(
            input(system: .silent, mic: .warmed, probeTonePlayed: true))
        XCTAssertEqual(report.verdict, .broken,
                       "已经喂了提示音还是全零，这不再是环境问题，是必须修的故障")
    }

    func testSilentSystemTrackWithoutToneCannotBeCalledBroken() {
        // 反向要求：没播过测试音时，全零完全可能是「当时没声音」，
        // 此时把它说成故障就是又一次撒谎——只不过方向相反。
        let report = CaptureReadiness.assess(
            input(system: .silent, mic: .warmed, probeTonePlayed: false))
        XCTAssertEqual(report.verdict, .degraded)
    }

    func testTonePlayedDoesNotUpgradeNoDataToBroken() {
        // 测试音只能证明「有声音却没被拾到」。一个 buffer 都没收到（noData）
        // 是另一类问题，证据不同，不该被这一位顺带升级成确诊。
        let report = CaptureReadiness.assess(
            input(system: .noData, mic: .warmed, probeTonePlayed: true))
        XCTAssertEqual(report.verdict, .degraded)
    }

    func testTonePlayedOnlyAppliesToSystemTrack() {
        // 麦克风轨的判据是「人有没有说话」，放一段提示音不能替代，
        // 所以这一位不得把麦克风轨的全零也说成确诊。
        let report = CaptureReadiness.assess(
            input(system: .warmed, mic: .silent, probeTonePlayed: true))
        XCTAssertEqual(report.verdict, .degraded,
                       "麦克风全零不能因为「播过提示音」就当作确诊")
    }

    func testProvenSilentIsAlsoBrokenWhenNeitherTrackWorks() {
        let report = CaptureReadiness.assess(
            input(system: .silent, mic: .noData, probeTonePlayed: true))
        XCTAssertEqual(report.verdict, .broken)
    }

    func testProvenSilentReportNamesTheConfirmedCause() {
        let report = CaptureReadiness.assess(
            input(system: .silent, mic: .warmed, probeTonePlayed: true))
        let t = text(report)
        XCTAssertTrue(t.contains("提示音"),
                      "确诊报告必须说明「已经播过提示音」，否则读者无从判断结论为何是确定的")
        XCTAssertTrue(t.contains("全零"))
    }

    // MARK: - 输入与输出是同一台设备：麦克风轨的探测在原理上不成立
    //
    // 实测（AirPods 同时作输入与输出，同一段提示音）：
    //   系统轨峰值 0.296～0.638；麦克风轨只剩 0.0005～0.024，其中一次恰好全零。
    //   同一副 AirPods 录真人说话，麦克风轨峰值 0.263——是提示音泄漏的 10 倍以上。
    //
    // 结论：共用设备时 micProbe 会在 warmed / silent 之间随机翻转，两次都实测到过，
    // 而麦克风一直是好的。诊断工具自己摇摆，比它老实说「无法判断」更糟。

    func testSharedInputOutputDoesNotReportDegraded() {
        let report = CaptureReadiness.assess(
            input(system: .warmed, mic: .silent, sharedDevice: true))
        XCTAssertEqual(report.verdict, .partiallyVerified,
                       "同一台设备时的「全零」是回声消除的预期结果，不是降级")
    }

    func testSharedInputOutputNeverClaimsBothTracksVerified() {
        // 即便这一轮恰好读到非零，那也是回声消除的残留或环境噪声，不能当成
        // 「提示音被麦克风拾到了」，所以不构成「两轨都验证过」。
        let report = CaptureReadiness.assess(
            input(system: .warmed, mic: .warmed, sharedDevice: true))
        XCTAssertNotEqual(report.verdict, .ready,
                          "共设备时麦克风轨从未被真正验证，不许报 ready")
        XCTAssertEqual(report.verdict, .partiallyVerified)
    }

    func testSharedInputOutputStillReportsLinkLevelFailures() {
        // 放宽的**只有**「收到了 buffer」两种情况。noData / timedOut 是链路级问题，
        // 与回声消除无关，必须照旧报出来——否则就是拿新规则掩盖旧故障。
        XCTAssertEqual(
            CaptureReadiness.assess(
                input(system: .warmed, mic: .noData, sharedDevice: true)).verdict,
            .degraded)
        XCTAssertEqual(
            CaptureReadiness.assess(
                input(system: .warmed, mic: .timedOut, sharedDevice: true)).verdict,
            .degraded)
    }

    func testSharedInputOutputReportTellsHowToActuallyVerifyTheMic() {
        let report = CaptureReadiness.assess(
            input(system: .warmed, mic: .silent, sharedDevice: true))
        let t = text(report)
        XCTAssertTrue(t.contains("未验证"),
                      "必须说清是「未验证」而不是「有问题」，否则用户会去改系统设置")
        XCTAssertTrue(t.contains("说话"),
                      "必须给出唯一可靠的验证办法：录一次说话")
        XCTAssertFalse(t.contains("降级"),
                       "这一档不是降级，措辞里不许出现")
    }

    func testSharedInputOutputDoesNotSuppressSystemTrackDiagnosis() {
        // 共设备只影响麦克风轨的解读。系统轨已喂提示音仍全零，仍是确诊故障，
        // 不能被这条新规则顺带洗白。
        let report = CaptureReadiness.assess(
            input(system: .silent, mic: .silent, probeTonePlayed: true, sharedDevice: true))
        XCTAssertEqual(report.verdict, .broken)
    }

    func testUnsharedDevicesKeepTheOldStrictBehaviour() {
        // 输入与输出是两台不同设备时（如内置麦克风 + 扬声器），提示音本该传到麦克风，
        // 所以「全零」仍是可信的信号，不能被新规则放宽。
        let report = CaptureReadiness.assess(
            input(system: .warmed, mic: .silent, sharedDevice: false))
        XCTAssertEqual(report.verdict, .degraded)
        XCTAssertTrue(text(report).contains("麦克风"), "仍须点名缺的是麦克风轨")
    }

    func testPartiallyVerifiedIsUsable() {
        // 它和 ready 一样「可以开始录」，只是有一轨没被验证——脚本里 doctor && record
        // 的写法不该在这一档被拦住。
        let report = CaptureReadiness.assess(
            input(system: .warmed, mic: .silent, sharedDevice: true))
        XCTAssertTrue(report.isUsable)
    }

    // MARK: - 报告本身的完整性

    func testEveryVerdictCarriesNonEmptyHeadlineAndDetails() {
        let all: [CaptureReadiness.Input] = [
            input(system: .warmed, mic: .warmed),
            input(system: .warmed, mic: .noData),
            input(system: .noData, mic: .warmed),
            input(system: .noData, mic: .noData),
            input(system: .silent, mic: .warmed),
            input(system: .warmed, mic: .silent),
            input(system: .silent, mic: .silent),
            input(system: .silent, mic: .noData),
            input(system: .notAttempted, mic: .notAttempted),
            input(system: .timedOut, mic: .timedOut),
            input(system: .timedOut, mic: .warmed),
            input(tapCreated: false, mic: .noData),
            input(tapCreated: false, mic: .warmed),
            input(isAppBundle: false, tapCreated: false),
            input(system: .warmed, mic: .silent, sharedDevice: true),
            input(system: .warmed, mic: .warmed, sharedDevice: true),
        ]
        for i in all {
            let r = CaptureReadiness.assess(i)
            XCTAssertFalse(r.headline.isEmpty, "verdict=\(r.verdict) 的结论不能是空串")
            XCTAssertFalse(r.details.isEmpty, "verdict=\(r.verdict) 必须给出可操作的细节")
            for d in r.details {
                XCTAssertFalse(d.trimmingCharacters(in: .whitespaces).isEmpty,
                               "细节里不该有空行占位")
            }
        }
    }

    func testOnlyReadyMayUseTheAllClearCheckmark() {
        // 约束的是**结论文本**：只有 ready 才配说「都验证过了」。
        // `partiallyVerified` 虽然同样可用，但它的 headline 必须说清「有一轨没验证」，
        // 所以不许带 ✅——标签上的 ✅ 由 CLI 自己加，且会附上「有一轨未验证」。
        let all: [CaptureReadiness.Input] = [
            input(system: .warmed, mic: .warmed),
            input(system: .warmed, mic: .noData),
            input(system: .noData, mic: .warmed),
            input(system: .noData, mic: .noData),
            input(system: .silent, mic: .warmed),
            input(system: .warmed, mic: .silent),
            input(system: .silent, mic: .silent),
            input(system: .silent, mic: .noData),
            input(system: .notAttempted, mic: .notAttempted),
            input(system: .timedOut, mic: .timedOut),
            input(tapCreated: false, mic: .noData),
            input(isAppBundle: false, tapCreated: false),
            input(system: .warmed, mic: .silent, sharedDevice: true),
            input(system: .warmed, mic: .warmed, sharedDevice: true),
        ]
        for i in all {
            let r = CaptureReadiness.assess(i)
            if r.verdict != .ready {
                XCTAssertFalse(r.headline.contains("✅"),
                               "非 ready 的结论不能带 ✅：\(r.headline)")
            }
        }
    }

    func testAssessmentIsPureAndRepeatable() {
        let i = input(system: .timedOut, mic: .noData)
        XCTAssertEqual(CaptureReadiness.assess(i), CaptureReadiness.assess(i),
                       "同样输入必须得到同样结论，否则这个判定没法被测试")
    }
}
