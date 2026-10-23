import XCTest
@testable import MRCore

/// WAV 的 4 GiB 上限。
///
/// 这是长会议验证挖出来的真实缺陷：RIFF 的 `data` / `RIFF` 长度字段都是 UInt32，
/// 越界时 `UInt32(dataSize)` 会 **trap**——进程以 SIGTRAP(133) 崩溃，不是写出坏文件。
/// 换算成时长（48kHz）：立体声 float32 约 3.11 小时、单声道 float32 约 6.21 小时；
/// **位深减半后时长翻倍**，所以 16 位下分别是 6.21 / 12.43 小时。
///
/// 正常会议到不了，但"录一整天"会踩到，所以必须显式设限而不是让它崩。
final class WAVSizeLimitTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavlimit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func url(_ n: String) -> URL { dir.appendingPathComponent(n) }

    func testMaxDataBytesLeavesRoomForRIFFField() {
        // RIFF 总长字段 = 36 + dataSize，必须也在 UInt32 内
        XCTAssertLessThan(WAVWriter.maxDataBytes + 36, Int(UInt32.max),
                          "maxDataBytes 必须给 RIFF 总长字段留出空间，否则换个字段继续崩")
    }

    func testSizeLimitIsAboutThreeHoursForStereoFloat() {
        let bytesPerSecond = 48000 * 2 * 4
        let hours = Double(WAVWriter.maxDataBytes) / Double(bytesPerSecond) / 3600
        XCTAssertEqual(hours, 3.1, accuracy: 0.05,
                       "48kHz 立体声 float32 的上限应约 3.1 小时")
    }

    func testAppendStopsAtLimitAndFlagsIt() throws {
        // 人为把上限压到 4000 字节（1000 个 float），方便测
        let limit = 4000
        let w = try WAVWriter(
            url: url("limit.wav"), sampleRate: 48000, channels: 1,
            format: .float32, dataByteLimit: limit)

        // 一次写入远超上限的量
        let samples = [Float](repeating: 0.5, count: 5000)
        try w.append(samples)
        try w.finalize()
        w.close()

        XCTAssertTrue(w.didReachSizeLimit, "超出上限必须置位，不能静默丢弃")
        XCTAssertLessThanOrEqual(w.bytesWritten, limit, "写入字节数不得超过上限")
        XCTAssertEqual(w.bytesWritten, limit, "应写满到上限为止")

        let info = try WAVWriter.readHeader(at: url("limit.wav"))
        XCTAssertTrue(info.isConsistent, "头部声明长度必须与实际一致，否则文件不合法")
        XCTAssertEqual(info.dataSize, limit)
        XCTAssertLessThanOrEqual(info.dataSize, Int(UInt32.max))
    }

    func testSecondAppendAfterLimitIsNoop() throws {
        let limit = 400  // 100 个 float
        let w = try WAVWriter(
            url: url("noop.wav"), sampleRate: 48000, channels: 1,
            format: .float32, dataByteLimit: limit)

        try w.append([Float](repeating: 0.1, count: 120))
        XCTAssertTrue(w.didReachSizeLimit)
        let afterFirst = w.bytesWritten

        // 再写几次都不应改变文件长度
        try w.append([Float](repeating: 0.2, count: 500))
        try w.append([Float](repeating: 0.3, count: 500))
        XCTAssertEqual(w.bytesWritten, afterFirst, "触顶后继续写入必须是无操作")
        w.close()

        let info = try WAVWriter.readHeader(at: url("noop.wav"))
        XCTAssertTrue(info.isConsistent)
    }

    func testNormalWriteUnderLimitDoesNotFlag() throws {
        let w = try WAVWriter(
            url: url("ok.wav"), sampleRate: 48000, channels: 1,
            format: .float32, dataByteLimit: 1_000_000)
        try w.append([Float](repeating: 0.5, count: 1000))
        try w.finalize()
        w.close()
        XCTAssertFalse(w.didReachSizeLimit, "远未触顶时不应报警")
        XCTAssertEqual(try WAVWriter.readHeader(at: url("ok.wav")).dataSize, 4000)
    }

    func testMakeHeaderClampsOversizedDataSize() {
        // 直接喂一个越界长度也不能崩——这是最后一道闸
        let huge = Int(UInt32.max) + 100_000
        let d = WAVWriter.makeHeader(
            sampleRate: 48000, channels: 2, format: .float32, dataSize: huge)
        XCTAssertEqual(d.count, WAVWriter.headerSize)
        // 声明值必须是合法 UInt32，且不越界
        let declared = d[40..<44].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertLessThanOrEqual(declared, UInt32(WAVWriter.maxDataBytes))
    }

    func testDataByteLimitClampedToGlobalMax() throws {
        // 传入超过全局上限的值应被夹到全局上限，而不是照单全收
        let w = try WAVWriter(
            url: url("clamp.wav"), sampleRate: 48000, channels: 1,
            format: .float32, dataByteLimit: Int(UInt32.max))
        XCTAssertLessThanOrEqual(w.dataByteLimit, WAVWriter.maxDataBytes,
                                 "上限不得突破全局 maxDataBytes")
        w.close()
    }

    // MARK: - 实例上限时长

    /// 实例属性用的必须是**自己**的 `dataByteLimit`，不是全局 `maxDataBytes`。
    ///
    /// 这条是「参数化而不是写死」的第二道防线：静态方法按传入参数算，
    /// 而实例属性很容易图省事去读 `WAVWriter.maxDataBytes`——那样测试里收窄了上限
    /// 也看不出差别，而收窄上限正是测试唯一能验它的手段。
    ///
    /// 退化示例：把实例 `maxDurationHours` 里的 `dataByteLimit: dataByteLimit`
    /// 改成 `dataByteLimit: Self.maxDataBytes`，前两条断言会一起变红。
    func testInstanceMaxDurationUsesItsOwnDataByteLimit() throws {
        // 48000 采样/秒 × 1 声道 × 4 字节 = 192000 字节/秒 → 上限正好 25 秒
        let limit = 4_800_000
        let f32 = try WAVWriter(url: url("dur-f32.wav"), sampleRate: 48000, channels: 1,
                                format: .float32, dataByteLimit: limit)
        let p16 = try WAVWriter(url: url("dur-p16.wav"), sampleRate: 48000, channels: 1,
                                format: .pcm16, dataByteLimit: limit)
        defer { f32.close(); p16.close() }

        XCTAssertEqual(f32.maxDurationHours, 25.0 / 3600.0, accuracy: 1e-6,
                       "实例上限必须用它自己的 dataByteLimit（4800000 字节 = 25 秒）")
        XCTAssertEqual(p16.maxDurationHours, 50.0 / 3600.0, accuracy: 1e-6,
                       "16 位下同一字节上限对应两倍时长")
        XCTAssertEqual(p16.maxDurationHours, f32.maxDurationHours * 2, accuracy: 1e-9,
                       "位深减半，实例算出来的上限时长也要翻倍")

        // 与按全局上限算出来的值相差好几个数量级，能区分出「误用了 maxDataBytes」
        let global = WAVWriter.maxDurationHours(sampleRate: 48000, channels: 1, format: .float32)
        XCTAssertLessThan(f32.maxDurationHours, global / 100,
                          "实例值不该悄悄等于全局上限算出来的值")
    }
}
