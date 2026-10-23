import XCTest
import MRCore
@testable import MRGUI

/// 详情页音轨卡第二行的参数串（`MeetingDetailView.trackInfoLine`）。
///
/// 为什么单测一个纯字符串函数：位深不显示时，16 位录的和 32 位录的在这一行里
/// **长得一模一样**——而精度是补不回来的，用户事后想知道「这场是不是非无损的」
/// 没有任何入口。manifest 特意加了 `sampleFormat` 字段，此前全仓库无消费者，
/// 这一行就是它的消费者。
///
/// SwiftUI 的 `Text` 在无头测试里读不到内容，所以把这一行的拼装抽成静态纯函数，
/// 这一条才测得成。
final class MeetingDetailViewInfoTests: XCTestCase {

    private func info(
        format: WAVSampleFormat, channels: Int = 1, deviceName: String? = nil
    ) -> TrackManifest {
        TrackManifest(
            id: "mic", role: .microphone, fileName: "mic.wav",
            sampleRate: 48000, channels: channels,
            sampleFormat: format, deviceName: deviceName)
    }

    /// 16 位与 32 位必须显示得出来，且用词是短名（详情行 `lineLimit(1)`，长名会顶到截断）。
    ///
    /// 退化示例：把 `trackInfoLine` 里的 `info.sampleFormat.shortDisplayName` 去掉，
    /// 本用例两条断言都变红。
    func testInfoLineShowsTheBitDepth() {
        XCTAssertTrue(MeetingDetailView.trackInfoLine(info(format: .pcm16)).contains("16 位"),
                      "16 位必须显示出来")
        XCTAssertTrue(MeetingDetailView.trackInfoLine(info(format: .float32)).contains("32 位浮点"),
                      "32 位要显示完整短名，否则用户看不出 16 位是「更差的那个」")
    }

    /// 采样率、声道数、设备名都在，且用 ` · ` 连接。
    func testInfoLineCarriesRateChannelsAndDevice() {
        let line = MeetingDetailView.trackInfoLine(
            info(format: .pcm16, channels: 2, deviceName: "MacBook 麦克风"))
        XCTAssertTrue(line.contains("48000 Hz"), line)
        XCTAssertTrue(line.contains("2 声道"), line)
        XCTAssertTrue(line.contains("MacBook 麦克风"), line)
        XCTAssertTrue(line.contains(" · "), "各段之间应当用分隔符连接：\(line)")
    }

    /// 没有设备名时不能留下多余的分隔符（结尾出现 `· ` 会像少了一段）。
    ///
    /// 退化示例：把 `if let name = info.deviceName { parts.append(name) }`
    /// 改成无条件 append `info.deviceName ?? ""`，本用例会变红
    /// （结尾会出现一个空段的分隔符）。
    func testInfoLineHasNoDanglingSeparatorWithoutDevice() {
        let line = MeetingDetailView.trackInfoLine(info(format: .pcm16, deviceName: nil))
        XCTAssertFalse(line.hasSuffix("· "), "结尾不该有多余分隔符：\(line)")
        XCTAssertFalse(line.hasSuffix(" ·"), "结尾不该有多余分隔符：\(line)")
        XCTAssertFalse(line.contains("·  ·"), "不该出现连续分隔符：\(line)")
        XCTAssertTrue(line.hasSuffix("16 位"), "最后一段应当是位深：\(line)")
    }

    /// 「合并音轨」按钮只在**真的有两轨**时出现。
    ///
    /// 单轨时给按钮是更差的体验：用户点了才知道没得合。
    /// 判据用 `existingTrackCount`（磁盘上真实存在的文件数）而不是 manifest 条数——
    /// manifest 记了轨但文件被删时，按 manifest 给按钮、点了却报「缺轨」。
    ///
    /// 退化示例：把判据改成 `!= 0`（单轨也给按钮），本用例红。
    func testMergeButtonOnlyAppearsWhenThereAreAtLeastTwoTracks() {
        XCTAssertFalse(MeetingDetailView.shouldOfferMerge(trackCount: nil),
                       "没选中会议时不该给按钮")
        XCTAssertFalse(MeetingDetailView.shouldOfferMerge(trackCount: 0))
        XCTAssertFalse(MeetingDetailView.shouldOfferMerge(trackCount: 1),
                       "单轨没有可合并的对象")
        XCTAssertTrue(MeetingDetailView.shouldOfferMerge(trackCount: 2))
        XCTAssertTrue(MeetingDetailView.shouldOfferMerge(trackCount: 3),
                      "将来若支持多轨合并，两轨以上的判断不该把它挡掉")
    }

    // MARK: - 导出的默认落盘位置

    /// **存盘面板必须默认打开这场会议自己的目录。**
    ///
    /// 这是一条真缺陷的回归。第一次是合并音频：CLI 的 `mr merge` 不带 `--out` 时写入
    /// `<会话目录>/<标题>-merged.wav`，而 GUI 走 `NSSavePanel` 且**从没设过
    /// `directoryURL`**——面板会落在上次用的位置或「文稿」根目录。
    /// 代码里的注释写着「默认指向会话目录」，注释却在说一件没做的事。
    ///
    /// 后果是产物散落在各处：用户导出五场，五个文件在五个地方，
    /// 而「这场会的合并文件」最自然的归属就是这场会的目录。
    ///
    /// 第二次是导出转写稿（2026-10-15）：同一个坑在隔壁功能又踩了一次，
    /// 而症状更隐蔽——`NSSavePanel` 会**记住上次保存的位置**，
    /// 于是面板打开在某个毫不相干的会议目录下，用户要导出的却是今天这一场。
    /// 相邻两个功能，一个修了一个没修，屏幕上不报任何错。
    ///
    /// 判据是「等于该场目录」，不是「包含该场目录」——面板落到会议库的上一级
    /// 同样算错，那是另一个更让人找不到的位置。
    func testSavePanelDefaultsToTheSessionDirectory() throws {
        // 必须**真的把目录建出来**。写一个不存在的路径再断言等于目录，
        // 测到的是「实现对不存在目录的处理」——而那正是下一条用例的职责。
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-merge-dir-\(UUID().uuidString)", isDirectory: true)
        let dir = base.appendingPathComponent("2026-10-09-143012-产品评审", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertEqual(MeetingDetailView.sessionSavePanelDirectory(sessionDirectory: dir),
                       dir)
    }

    /// 目录不存在时不能返回它——`NSSavePanel` 拿到一个不存在的 `directoryURL`
    /// 会静默退回默认位置，等于没设。这条不能靠「上层保证目录存在」：
    /// 清理后的场次目录可能真的不在（用户手工删过）。
    func testSavePanelDirectoryIsNilWhenTheDirectoryIsMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-no-such-dir-\(UUID().uuidString)", isDirectory: true)
        XCTAssertNil(MeetingDetailView.sessionSavePanelDirectory(sessionDirectory: missing))
    }

    /// 目录判据是**目录**，不是「路径上有这个东西」。
    ///
    /// 退化示例：把 `fileExists(atPath:isDirectory:)` 换成 `fileExists(atPath:)`，
    /// 下面这条会红——同一个路径作为普通文件存在时，`isDirectory` 为 false，
    /// 而把它当目录设给面板，面板会打不开或悄悄跳走。
    func testSavePanelDirectoryRejectsAFileAtTheSamePath() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-merge-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let asFile = base.appendingPathComponent("notadir")
        try Data([0x00]).write(to: asFile)

        XCTAssertNil(MeetingDetailView.sessionSavePanelDirectory(sessionDirectory: asFile),
                     "那是个文件，不能当目录返回")
    }

    /// **两个导出必须共用同一个目录判据。**
    ///
    /// 这条挡的不是今天的 bug，而是它**为什么会发生**：两个相邻功能各写一份
    /// 默认目录逻辑，改一处漏一处。现在它们共用 `sessionSavePanelDirectory`，
    /// 于是「导出的默认落点」只有一个实现——要改只有一处要改。
    ///
    /// 判据是**行为相同**，不是「代码里都调了同一个函数」：后者在实现换成
    /// 两份等价代码时照样绿，而行为已经可以各自漂移了。
    func testBothExportsResolveTheSameDefaultDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-shared-dir-\(UUID().uuidString)", isDirectory: true)
        let session = base.appendingPathComponent("2026-10-15-113000-复盘会议", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // 同一个会话目录，两条导出路径给出的默认位置必须逐字相同。
        let resolved = MeetingDetailView.sessionSavePanelDirectory(sessionDirectory: session)
        XCTAssertEqual(resolved, session)

        // 换成另一个场次也不能串——默认位置跟着**当前选中的那一场**走。
        let other = base.appendingPathComponent("2026-10-09-155445-另一场", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertEqual(MeetingDetailView.sessionSavePanelDirectory(sessionDirectory: other), other)
        XCTAssertNotEqual(resolved, other,
                          "两场会议的默认目录不能是同一个——那正是用户报的现象")
    }
}
