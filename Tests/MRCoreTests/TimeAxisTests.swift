import XCTest
@testable import MRCore

/// 时间轴与漂移。
///
/// 这是整套系统**唯一**会让成品「看起来能用但结果错」的地方：
/// 样本数会偏离真实时长（8 秒差 10.7ms、26 秒差 21.3ms），且这个偏差随内容变化
/// （同样 26 秒，静音差 1024 帧、有声只差 512 帧），不是恒定的时钟漂移。
/// 所以这里测的不是"能不能算"，而是"算的是不是对的基准"。
final class TimeAxisTests: XCTestCase {

    // MARK: - HostClock

    func testTimebaseIsUsable() {
        XCTAssertGreaterThan(HostClock.nanosecondsPerTick, 0, "纳秒/tick 必须为正")
        XCTAssertLessThan(HostClock.nanosecondsPerTick, 1e9, "纳秒/tick 不可能超过 1 秒")
    }

    func testNowIsMonotonic() {
        let a = HostClock.now()
        Thread.sleep(forTimeInterval: 0.02)
        let b = HostClock.now()
        XCTAssertGreaterThan(b, a, "单调时钟必须递增")
    }

    func testSecondsBetweenIsSymmetric() {
        let a = HostClock.now()
        Thread.sleep(forTimeInterval: 0.05)
        let b = HostClock.now()
        XCTAssertEqual(HostClock.secondsBetween(a, b), HostClock.secondsBetween(b, a), accuracy: 1e-12)
    }

    func testSecondsBetweenMatchesWallClock() {
        let a = HostClock.now()
        Thread.sleep(forTimeInterval: 0.25)
        let b = HostClock.now()
        XCTAssertEqual(HostClock.secondsBetween(a, b), 0.25, accuracy: 0.05,
                       "mach 时钟换算到秒应贴近真实时间")
    }

    func testSignedSecondsHandlesDirection() {
        let a = HostClock.now()
        Thread.sleep(forTimeInterval: 0.03)
        let b = HostClock.now()
        XCTAssertGreaterThan(HostClock.signedSeconds(from: a, to: b), 0)
        XCTAssertLessThan(HostClock.signedSeconds(from: b, to: a), 0)
    }

    // MARK: - 帧数折算（踩过的坑）

    func testFramesFromByteCountAccountsForChannels() {
        // 非交错格式下每个 buffer 是一个通道，字节数除 4 得到「该通道采样数」
        XCTAssertEqual(TrackStats.frames(fromByteCount: 3840, channels: 1), 960)
        XCTAssertEqual(TrackStats.frames(fromByteCount: 3840, channels: 2), 480)
        XCTAssertEqual(TrackStats.frames(fromByteCount: 3840, channels: 4), 240)
    }

    func testFramesFromByteCountGuardsBadInput() {
        XCTAssertEqual(TrackStats.frames(fromByteCount: 0, channels: 2), 0)
        XCTAssertEqual(TrackStats.frames(fromByteCount: 100, channels: 0), 0)
        XCTAssertEqual(TrackStats.frames(fromByteCount: -10, channels: 2), 0)
    }

    func testDoubleCountingChannelsGivesWrongDuration() {
        // 显式钉死这个坑：立体声轨若拿采样数当帧数，时长会翻倍
        let stats = TrackStats(sampleRate: 48000, channels: 2, frames: 48000 * 5, totalSamples: 48000 * 10)
        XCTAssertEqual(stats.sampleDerivedDuration, 5.0, accuracy: 1e-9)
        let naive = Double(stats.totalSamples) / stats.sampleRate     // 错误算法
        XCTAssertEqual(naive, 10.0, accuracy: 1e-9)
        XCTAssertNotEqual(stats.sampleDerivedDuration, naive)
    }

    // MARK: - 实测数据的回归

    /// 用真实探针数据做回归：麦克风 1ch、系统音频 2ch，均 48kHz，并发 5 秒。
    func testRealProbeNumbersReproduce() {
        let mic = TrackStats(sampleRate: 48000, channels: 1, frames: 240128, totalSamples: 240128)
        let sys = TrackStats(sampleRate: 48000, channels: 2, frames: 479232 / 2, totalSamples: 479232)

        XCTAssertEqual(mic.sampleDerivedDuration, 5.0027, accuracy: 1e-3)
        XCTAssertEqual(sys.sampleDerivedDuration, 4.992, accuracy: 1e-3)

        // 若忘了除通道数，系统轨会算出 9.98 秒——将近两倍
        let naiveSystem = Double(sys.totalSamples) / sys.sampleRate
        XCTAssertEqual(naiveSystem, 9.984, accuracy: 1e-3)
        XCTAssertGreaterThan(naiveSystem / sys.sampleDerivedDuration, 1.99)
    }

    // MARK: - accumulate

    func testAccumulateTracksFramesAndHostTime() {
        var s = TrackStats(sampleRate: 48000, channels: 2)
        s.accumulate(channelByteCounts: [1920, 1920], startHostTime: 1_000_000)
        XCTAssertEqual(s.frames, 480, "480 字节/通道 ÷ 4 = 480 帧")
        XCTAssertEqual(s.totalSamples, 960)
        XCTAssertEqual(s.firstHostTime, 1_000_000)

        // 480 帧 @48k = 0.01 秒，lastHostTime 应前移对应 tick 数
        let expectedTicks = UInt64((0.01 / (HostClock.nanosecondsPerTick / 1e9)).rounded())
        XCTAssertEqual(s.lastHostTime, 1_000_000 + expectedTicks)
    }

    func testAccumulateKeepsFirstHostTime() {
        var s = TrackStats(sampleRate: 48000, channels: 1)
        s.accumulate(channelByteCounts: [1920], startHostTime: 111)
        s.accumulate(channelByteCounts: [1920], startHostTime: 999)
        XCTAssertEqual(s.firstHostTime, 111, "首个 hostTime 一旦确定不应被后续覆盖")
        XCTAssertEqual(s.frames, 960)
    }

    func testAccumulateIgnoresEmptyBuffers() {
        var s = TrackStats(sampleRate: 48000, channels: 2)
        s.accumulate(channelByteCounts: [], startHostTime: 5)
        s.accumulate(channelByteCounts: [0, 0], startHostTime: 5)
        XCTAssertEqual(s.frames, 0)
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.firstHostTime, 0, "空 buffer 不应污染起始时间")
    }

    // MARK: - 漂移

    func testDriftIsSampleMinusClock() {
        let start: UInt64 = 10_000_000
        let tickSeconds = HostClock.nanosecondsPerTick / 1e9
        // 真实过去 5.00 秒
        let end = start + UInt64((5.0 / tickSeconds).rounded())
        // 但采样数只够 4.99 秒
        let stats = TrackStats(
            sampleRate: 48000, channels: 1, frames: 239520,
            firstHostTime: start, lastHostTime: end)

        XCTAssertEqual(stats.clockDuration, 5.0, accuracy: 1e-6)
        XCTAssertEqual(stats.sampleDerivedDuration, 4.99, accuracy: 1e-6)
        XCTAssertEqual(stats.drift, -0.01, accuracy: 1e-3)
        XCTAssertEqual(stats.driftRatio, -0.002, accuracy: 1e-4)
    }

    func testDriftReportMeasuresSkew() {
        let t0: UInt64 = 1_000_000
        let tickSeconds = HostClock.nanosecondsPerTick / 1e9
        func ticks(_ sec: Double) -> UInt64 { UInt64((sec / tickSeconds).rounded()) }

        let mic = TrackStats(sampleRate: 48000, channels: 1, frames: 240128,
                             firstHostTime: t0, lastHostTime: t0 + ticks(5.00))
        let sys = TrackStats(sampleRate: 48000, channels: 2, frames: 239616,
                             firstHostTime: t0 + ticks(1.6), lastHostTime: t0 + ticks(6.6))

        let report = DriftReport(tracks: [
            .init(id: "mic", stats: mic),
            .init(id: "system", stats: sys),
        ])
        XCTAssertEqual(report.startSkew, 1.6, accuracy: 1e-3)
        XCTAssertEqual(report.overlapDuration, 3.4, accuracy: 1e-3,
                       "共同覆盖窗口 = 后启动者的起点 到 先结束者的终点")
        XCTAssertTrue(report.isUsable, "两轨都有数据 → 时间轴同源可用，起点差不算错误")
    }

    func testReportNotUsableWhenATrackIsEmpty() {
        let tickSeconds = HostClock.nanosecondsPerTick / 1e9
        let t0: UInt64 = 1_000_000
        let mic = TrackStats(sampleRate: 48000, channels: 1, frames: 48000,
                             firstHostTime: t0, lastHostTime: t0 + UInt64((1.0 / tickSeconds).rounded()))
        // 系统音频轨一帧都没有 —— 权限未授予的典型表现
        let dead = TrackStats(sampleRate: 48000, channels: 2)

        let report = DriftReport(tracks: [
            .init(id: "mic", stats: mic), .init(id: "system", stats: dead),
        ])
        XCTAssertFalse(report.isUsable, "有轨完全没数据必须被识别出来")
        XCTAssertEqual(report.overlapDuration, 0)
    }

    func testSingleTrackReportIsUsable() {
        let s = TrackStats(sampleRate: 48000, channels: 1, frames: 100,
                           firstHostTime: 1, lastHostTime: 2)
        XCTAssertTrue(DriftReport(tracks: [.init(id: "mic", stats: s)]).isUsable)
    }

    // MARK: - hostTime 对齐

    func testAlignmentOffsetIsZeroForEarliestTrack() {
        let base: UInt64 = 5_000_000
        XCTAssertEqual(TrackAlignment.offset(trackFirstHostTime: base, sessionBase: base), 0)
    }

    func testAlignmentOffsetMatchesHostTimeDifference() {
        let tickSeconds = HostClock.nanosecondsPerTick / 1e9
        let base: UInt64 = 5_000_000
        let later = base + UInt64((1.6 / tickSeconds).rounded())
        XCTAssertEqual(TrackAlignment.offset(trackFirstHostTime: later, sessionBase: base),
                       1.6, accuracy: 1e-6)
    }

    func testAlignmentOffsetGuardsMissingData() {
        XCTAssertEqual(TrackAlignment.offset(trackFirstHostTime: 0, sessionBase: 100), 0)
        XCTAssertEqual(TrackAlignment.offset(trackFirstHostTime: 100, sessionBase: 0), 0)
    }

    func testSessionBasePicksEarliestValidHostTime() {
        XCTAssertEqual(TrackAlignment.sessionBase(hostTimes: [300, 0, 100, 200]), 100)
        XCTAssertEqual(TrackAlignment.sessionBase(hostTimes: [0, 0]), 0)
        XCTAssertEqual(TrackAlignment.sessionBase(hostTimes: []), 0)
    }

    func testShiftNeverGoesNegative() {
        XCTAssertEqual(TrackAlignment.shift(0.5, by: -1.0), 0)
        XCTAssertEqual(TrackAlignment.shift(1.0, by: 1.6), 2.6, accuracy: 1e-9)
    }

    /// 端到端语义：两轨各自转写后，加上偏移应落到同一条时间线上。
    /// 麦克风 0.0 秒说的话与系统音频 0.0 秒说的话，其实是同一时刻的两边。
    func testOffsetMakesTwoTracksComparable() {
        let tickSeconds = HostClock.nanosecondsPerTick / 1e9
        let micStart: UInt64 = 1_000_000
        let sysStart = micStart + UInt64((1.6 / tickSeconds).rounded())

        let base = TrackAlignment.sessionBase(hostTimes: [micStart, sysStart])
        XCTAssertEqual(base, micStart)

        let micOffset = TrackAlignment.offset(trackFirstHostTime: micStart, sessionBase: base)
        let sysOffset = TrackAlignment.offset(trackFirstHostTime: sysStart, sessionBase: base)
        XCTAssertEqual(micOffset, 0, accuracy: 1e-9)
        XCTAssertEqual(sysOffset, 1.6, accuracy: 1e-6)

        // 麦克风第 2 秒 与 系统音频轨内第 0.4 秒 → 会话时间线都是 2.0 秒
        let micSessionTime = TrackAlignment.shift(2.0, by: micOffset)
        let sysSessionTime = TrackAlignment.shift(0.4, by: sysOffset)
        XCTAssertEqual(micSessionTime, 2.0, accuracy: 1e-6)
        XCTAssertEqual(sysSessionTime, 2.0, accuracy: 1e-6)
        XCTAssertEqual(micSessionTime, sysSessionTime, accuracy: 1e-6)
    }
}
