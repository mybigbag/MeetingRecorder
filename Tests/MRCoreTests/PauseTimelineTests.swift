import XCTest
@testable import MRCore

/// 暂停对时间轴的影响。
///
/// 暂停的语义是「这一段不要」：暂停期间不写盘，音频里没有这一段。
/// 于是产生一个必须显式处理的后果——**时钟跨度会比真实录到的内容长出一整段暂停**。
/// 不扣掉的话，「录 5 分钟、中途暂停 10 分钟」会算出 15 分钟时长，
/// `drift` 变成 −600 秒，漂移告警直接误报。
final class PauseTimelineTests: XCTestCase {

    /// 把秒换成 hostTime 的 tick 数
    private func ticks(_ seconds: Double) -> UInt64 {
        UInt64(seconds * 1_000_000_000 / HostClock.nanosecondsPerTick)
    }

    private let base: UInt64 = 1_000_000_000_000

    func testSpanIncludesPauseButClockDurationDoesNot() {
        // 实际录了 5 秒、暂停 10 秒、再录 5 秒：
        // 时钟跨度 20 秒，帧数只对应 10 秒
        let stats = TrackStats(
            sampleRate: 48000, channels: 1,
            frames: 48000 * 10,
            firstHostTime: base,
            lastHostTime: base + ticks(20),
            pausedSeconds: 10)

        XCTAssertEqual(stats.spanDuration, 20, accuracy: 0.01, "跨度含暂停")
        XCTAssertEqual(stats.clockDuration, 10, accuracy: 0.01, "内容时长不含暂停")
        XCTAssertEqual(stats.sampleDerivedDuration, 10, accuracy: 0.01)
    }

    /// 这条是核心：**暂停不能污染漂移**。
    ///
    /// 漂移的定义是「采样推算术与时钟术的差」。既然 `clockDuration` 已扣除暂停，
    /// 那么暂停多久都不该让它变大——这正是「把暂停建模进统计」的全部意义。
    func testPauseDoesNotPolluteDrift() {
        let stats = TrackStats(
            sampleRate: 48000, channels: 1,
            frames: 48000 * 10,
            firstHostTime: base,
            lastHostTime: base + ticks(610),    // 中途暂停了 10 分钟
            pausedSeconds: 600)

        XCTAssertEqual(stats.drift, 0, accuracy: 0.01)
        XCTAssertEqual(stats.driftRatio, 0, accuracy: 0.001)
    }

    /// 负的暂停时长（manifest 被手改坏）不能让内容时长虚增
    func testNegativePauseIsClamped() {
        let stats = TrackStats(
            sampleRate: 48000, channels: 1,
            frames: 48000 * 10,
            firstHostTime: base,
            lastHostTime: base + ticks(10),
            pausedSeconds: -100)

        XCTAssertEqual(stats.clockDuration, 10, accuracy: 0.01)
    }

    func testPausedSecondsDefaultsToZeroAndSurvivesEncoding() throws {
        let plain = TrackStats(sampleRate: 48000, channels: 2, frames: 100)
        XCTAssertEqual(plain.pausedSeconds, 0)

        let withPause = TrackStats(
            sampleRate: 44100, channels: 1, frames: 22050,
            firstHostTime: base, lastHostTime: base + ticks(2), pausedSeconds: 1.5)
        let data = try JSONEncoder().encode(withPause)
        let back = try JSONDecoder().decode(TrackStats.self, from: data)
        XCTAssertEqual(back, withPause)
    }

    /// 旧的 stats JSON（没有 `pausedSeconds` 这个键）必须还能读出来。
    ///
    /// 这是落盘类型的老规矩（见 `TrackManifest.init(from:)`）：
    /// 加字段不能让历史数据变成「损坏」。
    func testDecodesLegacyStatsWithoutPausedKey() throws {
        let legacy = """
        {"sampleRate":48000,"channels":1,"frames":48000,
         "totalSamples":48000,"firstHostTime":100,"lastHostTime":200}
        """
        let stats = try JSONDecoder().decode(TrackStats.self, from: Data(legacy.utf8))
        XCTAssertEqual(stats.pausedSeconds, 0)
        XCTAssertEqual(stats.frames, 48000)
    }

    // MARK: - manifest 一侧

    func testManifestWithoutPausesDecodesToEmptyArray() throws {
        // 上一版写出的 manifest 里没有 `pauses` 键
        let legacy = """
        {"version":1,"sessionID":"s","title":"会议",
         "startedAt":"2026-09-27T16:24:31.000Z","state":"finalized","tracks":[],"notes":[]}
        """
        let manifest = try RecordingManifest.decode(Data(legacy.utf8), path: "内存")
        XCTAssertTrue(manifest.pauses.isEmpty)
        XCTAssertEqual(manifest.pausedTotal, 0)
        XCTAssertEqual(manifest.recordedDuration, manifest.duration, accuracy: 0.001)
    }

    func testPausedTotalAndRecordedDuration() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = RecordingManifest(
            sessionID: "s", title: "会议",
            startedAt: started,
            endedAt: started.addingTimeInterval(600),   // 跨度 10 分钟
            state: .finalized,
            pauses: [
                PauseSpan(startedAfter: 60, duration: 90),
                PauseSpan(startedAfter: 300, duration: 30),
            ])

        XCTAssertEqual(manifest.pausedTotal, 120, accuracy: 0.001)
        XCTAssertEqual(manifest.duration, 600, accuracy: 0.001)
        // 真正录到的只有 8 分钟
        XCTAssertEqual(manifest.recordedDuration, 480, accuracy: 0.001)
    }

    /// 坏 manifest 里的负数暂停时长不能让 `recordedDuration` 比 `duration` 还大
    func testNegativePauseDoesNotInflateRecordedDuration() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = RecordingManifest(
            sessionID: "s", title: "会议",
            startedAt: started, endedAt: started.addingTimeInterval(60),
            state: .finalized,
            pauses: [PauseSpan(startedAfter: 10, duration: -30)])

        XCTAssertEqual(manifest.pausedTotal, 0)
        XCTAssertEqual(manifest.recordedDuration, 60, accuracy: 0.001)
    }

    func testPausesSurviveAManifestRoundTrip() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let original = RecordingManifest(
            sessionID: "s", title: "会议", startedAt: started,
            endedAt: started.addingTimeInterval(120), state: .finalized,
            pauses: [PauseSpan(startedAfter: 12.5, duration: 30.25)])

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("manifest.json")
        try original.write(to: url)
        let back = try RecordingManifest.read(from: url)

        XCTAssertEqual(back.pauses, original.pauses)
        XCTAssertEqual(back.pausedTotal, 30.25, accuracy: 0.001)
    }

    /// 暂停区间记的是**墙上时钟**偏移，不是音频时间轴上的位置。
    ///
    /// 这两者会差一个「之前所有暂停的总长」。混了就会拿错误的秒数去播放器里跳。
    func testPauseSpanOffsetIsWallClock() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = RecordingManifest(
            sessionID: "s", title: "会议", startedAt: started,
            endedAt: started.addingTimeInterval(600), state: .finalized,
            pauses: [PauseSpan(startedAfter: 120, duration: 60)])

        // 音频时间轴上的位置 = 墙钟偏移 − 它之前所有暂停（这里就这一次，之前为 0）
        let audioPosition = manifest.pauses[0].startedAfter
        XCTAssertEqual(audioPosition, 120, accuracy: 0.001)
        // 而音频总长 = 跨度 − 暂停
        XCTAssertEqual(manifest.recordedDuration, 540, accuracy: 0.001)
        XCTAssertLessThan(manifest.recordedDuration, manifest.duration)
    }
}
