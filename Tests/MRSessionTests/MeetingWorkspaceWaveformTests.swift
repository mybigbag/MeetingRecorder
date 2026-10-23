import XCTest
@testable import MRSession
import MRCore

/// 波形的加载与生命周期。
///
/// 波形要通读整个 WAV，是详情页里唯一的重 IO，所以单独归一组测：
///  - 切会议时必须清干净，否则显示的是**上一场**的波形（与「详情迟到结果」同类的问题）
///  - 重复选中同一场不能重算（几百 MB 的读盘不能随便重复）
///  - 单条轨出问题只影响那一条
///
/// 夹具直接构造 `MeetingSummary`，不走 `refreshAsync`——那条路会自动选中第一条并
/// 顺手触发一次波形加载，会把断言时机搅浑。
@MainActor
final class MeetingWorkspaceWaveformTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-waveform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 夹具

    /// 写一条真实的 WAV 轨。
    ///
    /// 波形用确定性的三角包络（0 → 峰值 → 0），峰值出现在中段，
    /// 所以「整条的最大绝对采样值」就等于传进来的 `amplitude`，可以直接断言。
    private func writeTrack(
        _ directory: URL,
        name: String,
        seconds: Double,
        channels: Int = 1,
        amplitude: Float
    ) throws {
        let frames = max(1, Int(seconds * 48000))
        var samples: [Float] = []
        samples.reserveCapacity(frames * channels)
        for index in 0..<frames {
            let shape = Float(index) / Float(frames - 1)
            let envelope = shape < 0.5 ? shape * 2 : (1 - shape) * 2
            let value = amplitude * envelope
            for _ in 0..<channels { samples.append(value) }
        }
        let url = directory.appendingPathComponent(name)
        let writer = try WAVWriter(url: url, sampleRate: 48000, channels: channels)
        try writer.append(samples)
        try writer.finalize()
        writer.close()
    }

    /// 造一场会议，返回可以直接喂给 `loadWaveformsAsync` 的摘要。
    private func makeMeeting(
        title: String,
        seconds: Double = 2,
        tracks: [(id: String, channels: Int, amplitude: Float)]
    ) throws -> MeetingSummary {
        let store = SessionStore(root: root)
        let (id, dir) = try store.createSession(title: title, date: Date())
        var manifest = try store.loadManifest(forSessionID: id)
        manifest.state = .finalized
        manifest.endedAt = Date().addingTimeInterval(seconds)
        manifest.tracks = []
        for track in tracks {
            try writeTrack(dir, name: "\(track.id).wav", seconds: seconds,
                           channels: track.channels, amplitude: track.amplitude)
            manifest.tracks.append(TrackManifest(
                id: track.id,
                role: track.id == "mic" ? .microphone : .systemAudio,
                fileName: "\(track.id).wav",
                sampleRate: 48000,
                channels: track.channels,
                framesWritten: Int(seconds * 48000)))
        }
        try store.save(manifest, sessionDirectory: dir)
        return MeetingSummary(
            id: id, title: title, startedAt: Date(), duration: seconds,
            state: .finalized, existingTrackCount: tracks.count, warnings: [],
            hasTranscript: false, directory: dir)
    }

    // MARK: - 基本加载

    func testLoadsEveryTrack() async throws {
        let meeting = try makeMeeting(
            title: "甲", tracks: [("mic", 1, 1.0), ("system", 2, 0.25)])
        let workspace = MeetingWorkspace(root: root)

        await workspace.loadWaveformsAsync(for: meeting)

        XCTAssertEqual(Set(workspace.waveforms.keys), ["mic", "system"])
        XCTAssertEqual(workspace.waveforms["mic"]?.peaks.count, MeetingWorkspace.waveformBuckets)
        XCTAssertFalse(workspace.isLoadingWaveforms, "算完了就不能还挂着「进行中」")
    }

    func testReferenceAmplitudeKeepsTheRealLevel() async throws {
        // 两轨幅度差 4 倍。若把每条轨都归一化到自己的峰值再展示，
        // 「对方」那条会被放大到和「我」一样高，等于视觉上抹掉了音量差。
        let meeting = try makeMeeting(
            title: "乙", tracks: [("mic", 1, 1.0), ("system", 2, 0.25)])
        let workspace = MeetingWorkspace(root: root)

        await workspace.loadWaveformsAsync(for: meeting)

        XCTAssertEqual(workspace.waveforms["mic"]?.referenceAmplitude ?? -1, 1.0, accuracy: 0.02)
        XCTAssertEqual(workspace.waveforms["system"]?.referenceAmplitude ?? -1, 0.25, accuracy: 0.02)
    }

    func testAllZeroTrackIsReportedAsSilent() async throws {
        let meeting = try makeMeeting(
            title: "丙", tracks: [("mic", 1, 0.0), ("system", 2, 0.4)])
        let workspace = MeetingWorkspace(root: root)

        await workspace.loadWaveformsAsync(for: meeting)

        XCTAssertEqual(workspace.waveforms["mic"]?.isSilent, true)
        XCTAssertEqual(workspace.waveforms["system"]?.isSilent, false)
    }

    // MARK: - 局部失败

    func testMissingTrackFileDoesNotTakeDownTheOtherTrack() async throws {
        let store = SessionStore(root: root)
        let (id, dir) = try store.createSession(title: "丁", date: Date())
        var manifest = try store.loadManifest(forSessionID: id)
        manifest.state = .finalized
        // manifest 声称有 system 轨，但文件根本不写
        try writeTrack(dir, name: "mic.wav", seconds: 1, amplitude: 0.6)
        manifest.tracks = [
            TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                          sampleRate: 48000, channels: 1, framesWritten: 48000),
            TrackManifest(id: "system", role: .systemAudio, fileName: "system.wav",
                          sampleRate: 48000, channels: 2, framesWritten: 48000),
        ]
        try store.save(manifest, sessionDirectory: dir)

        let meeting = MeetingSummary(
            id: id, title: "丁", startedAt: Date(), duration: 1,
            state: .finalized, existingTrackCount: 1, warnings: [],
            hasTranscript: false, directory: dir)
        let workspace = MeetingWorkspace(root: root)

        await workspace.loadWaveformsAsync(for: meeting)

        XCTAssertNotNil(workspace.waveforms["mic"], "一条轨读不出来不该把另一条也拖没")
        XCTAssertNil(workspace.waveforms["system"])
    }

    func testBrokenManifestYieldsNoWaveforms() async throws {
        let store = SessionStore(root: root)
        let (id, dir) = try store.createSession(title: "戊", date: Date())
        try writeTrack(dir, name: "mic.wav", seconds: 1, amplitude: 0.5)
        try Data("{ 这不是 JSON".utf8)
            .write(to: dir.appendingPathComponent(SessionStore.manifestFileName))

        let meeting = MeetingSummary(
            id: id, title: "戊", startedAt: Date(), duration: 1,
            state: .finalized, existingTrackCount: 1, warnings: [],
            hasTranscript: false, directory: dir)
        let workspace = MeetingWorkspace(root: root)

        await workspace.loadWaveformsAsync(for: meeting)

        XCTAssertTrue(workspace.waveforms.isEmpty)
        XCTAssertFalse(workspace.isLoadingWaveforms, "失败也必须把「进行中」摘掉，否则界面永远在转")
    }

    // MARK: - 生命周期

    func testSwitchingAwayClearsTheWaveforms() async throws {
        let first = try makeMeeting(title: "己", tracks: [("mic", 1, 0.7)])
        let second = try makeMeeting(title: "癸", tracks: [("mic", 1, 0.3)])
        let workspace = MeetingWorkspace(root: root)

        await workspace.loadWaveformsAsync(for: first)
        XCTAssertFalse(workspace.waveforms.isEmpty)
        XCTAssertEqual(workspace.waveformSessionID, first.id)

        workspace.selectedID = second.id

        XCTAssertTrue(workspace.waveforms.isEmpty,
                      "切场必须立刻清空，否则新标题下会短暂显示上一场的曲线")
        XCTAssertEqual(workspace.waveformSessionID, first.id,
                       "归属仍停在上一场——界面正是靠这个差值显示「正在计算」而不是「没有波形」")
    }

    /// 用「改掉盘上的数据后结果应当不变」来证明真的没有重读磁盘。
    func testSameSessionIsNotRecomputed() async throws {
        let meeting = try makeMeeting(title: "庚", tracks: [("mic", 1, 0.9)])
        let workspace = MeetingWorkspace(root: root)

        await workspace.loadWaveformsAsync(for: meeting)
        let first = try XCTUnwrap(workspace.waveforms["mic"]?.referenceAmplitude)

        // 把文件换成幅度完全不同的内容，再请求一次
        try writeTrack(meeting.directory, name: "mic.wav", seconds: 1, amplitude: 0.1)
        await workspace.loadWaveformsAsync(for: meeting)

        XCTAssertEqual(workspace.waveforms["mic"]?.referenceAmplitude, first,
                       "同一场不该重算——通读几百 MB 不是能随便重复的事")
    }

    func testSwitchingSessionLoadsTheNewOne() async throws {
        let first = try makeMeeting(title: "辛", tracks: [("mic", 1, 0.9)])
        let second = try makeMeeting(title: "壬", tracks: [("mic", 1, 0.2)])
        let workspace = MeetingWorkspace(root: root)

        await workspace.loadWaveformsAsync(for: first)
        XCTAssertEqual(workspace.waveforms["mic"]?.referenceAmplitude ?? -1, 0.9, accuracy: 0.02)

        workspace.selectedID = nil
        await workspace.loadWaveformsAsync(for: second)

        XCTAssertEqual(workspace.waveforms["mic"]?.referenceAmplitude ?? -1, 0.2, accuracy: 0.02,
                       "换一场之后必须换成新的波形")
    }
}
