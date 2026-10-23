import XCTest
@testable import MRCore

/// WAV 读写与崩溃修复。
///
/// 崩溃恢复能不能成立，全看 `repairHeader` 能不能从「头是空的、数据是全的」
/// 这个状态里把真实长度算出来。所以要专门测「写了数据但没有 finalize」。
final class WAVFileTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wav-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func url(_ name: String = "t.wav") -> URL { dir.appendingPathComponent(name) }

    private func sine(frames: Int, channels: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<(frames * channels)).map { i in
            amplitude * Float(sin(2 * Double.pi * 440 * Double(i / channels) / 48000))
        }
    }

    // MARK: - 基本写入

    func testWriteFloat32ProducesValidHeader() throws {
        let w = try WAVWriter(url: url(), sampleRate: 48000, channels: 2, format: .float32)
        try w.append(sine(frames: 4800, channels: 2))
        try w.finalize()
        let framesWritten = w.framesWritten
        w.close()

        let info = try WAVWriter.readHeader(at: url())
        XCTAssertEqual(info.audioFormatID, 3, "float32 应为 IEEE float（格式码 3）")
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.sampleRate, 48000)
        XCTAssertEqual(info.bitsPerSample, 32)
        XCTAssertEqual(info.frameCount, framesWritten)
        XCTAssertEqual(info.frameCount, 4800)
        XCTAssertEqual(info.dataSize, 4800 * 2 * 4)
        XCTAssertEqual(info.duration, 0.1, accuracy: 1e-9)
    }

    func testWritePCM16HeaderAndSize() throws {
        let w = try WAVWriter(url: url(), sampleRate: 16000, channels: 1, format: .pcm16)
        try w.append(sine(frames: 1600, channels: 1))
        w.close()

        let info = try WAVWriter.readHeader(at: url())
        XCTAssertEqual(info.audioFormatID, 1, "pcm16 应为格式码 1")
        XCTAssertEqual(info.bitsPerSample, 16)
        XCTAssertEqual(info.frameCount, 1600)
        XCTAssertEqual(info.dataSize, 1600 * 2)
    }

    func testFileSizeMatchesHeader() throws {
        let w = try WAVWriter(url: url(), sampleRate: 48000, channels: 1, format: .float32)
        try w.append(sine(frames: 2400, channels: 1))
        w.close()

        let info = try WAVWriter.readHeader(at: url())
        XCTAssertTrue(info.isConsistent, "头声明的长度应与文件实际长度一致")
        XCTAssertEqual(info.fileSize, WAVWriter.headerSize + 2400 * 4)
    }

    /// **同一段音频**，pcm16 写出来的文件必须恰好是 float32 的一半。
    ///
    /// 上面几条各自验了头字段、数据量、clamp，但没有一条把它们乘起来——
    /// 而用户按下「16 位录音」之后唯一会去看的东西就是文件大小。
    /// 这条是「省一半空间」那句承诺在代码里的落点。
    func testPCM16HalvesTheFileSizeAtTheSameFrameCount() throws {
        let samples = sine(frames: 48000, channels: 2)

        let f32 = try WAVWriter(url: url("f32.wav"), sampleRate: 48000, channels: 2, format: .float32)
        try f32.append(samples)
        f32.close()

        let p16 = try WAVWriter(url: url("p16.wav"), sampleRate: 48000, channels: 2, format: .pcm16)
        try p16.append(samples)
        p16.close()

        let a = try WAVWriter.readHeader(at: url("f32.wav"))
        let b = try WAVWriter.readHeader(at: url("p16.wav"))

        XCTAssertEqual(a.frameCount, b.frameCount, "两种格式装的是同一段音频")
        XCTAssertEqual(b.dataSize * 2, a.dataSize, "pcm16 的数据量必须恰好是一半")

        // 整个文件也满足同一个关系，只差一个 44 字节的头：
        //   p16 总长 × 2 = (44 + 4N) × 2 = 88 + 8N = (44 + 8N) + 44 = f32 总长 + 头
        let f32Bytes = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url("f32.wav").path)[.size] as? Int)
        let p16Bytes = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url("p16.wav").path)[.size] as? Int)
        XCTAssertEqual(p16Bytes * 2, f32Bytes + WAVWriter.headerSize)
    }

    /// **帧数的换算必须跟着位深走。**
    ///
    /// `framesWritten` 是按**写入字节数**反推的（`dataBytesWritten / (声道 × 字节/采样)`），
    /// 位深就在分母里。这里给两种格式喂**同样多的采样**，帧数必须相同——
    /// 若分母被写死（例如恒用 4 字节），16 位那一路的帧数会凭空减半，
    /// 症状是「录了多久」整体差一倍。
    ///
    /// 刻意与上面那条分开：上面验的是**文件头里**的帧数（读者按头里的位深自己算），
    /// 这条验的是**写入器**自己报的帧数。两边各自算错且互相抵消时，只有分别断言才抓得住。
    ///
    /// （这条以前挂在 `TrackRecorderFormatTests` 名下，却只断言了 `bytesPerSample`
    /// 这个枚举属性——把 `framesWritten` 的分母改错它照样全绿。挪到这里才真的验到东西。）
    func testFrameCountIsComputedFromTheFormatBytesPerSample() throws {
        // 2400 帧 × 2 声道 = 4800 个交错采样，两种格式喂同一段。
        let samples = sine(frames: 2400, channels: 2)

        let f32 = try WAVWriter(url: url("f32frames.wav"), sampleRate: 48000, channels: 2,
                                format: .float32)
        try f32.append(samples)
        let p16 = try WAVWriter(url: url("p16frames.wav"), sampleRate: 48000, channels: 2,
                                format: .pcm16)
        try p16.append(samples)
        defer { f32.close(); p16.close() }

        XCTAssertEqual(f32.framesWritten, 2400)
        XCTAssertEqual(p16.framesWritten, 2400, "16 位不能让帧数减半")
        // 同一帧数下，写入字节数应恰好差一倍（2 vs 4 字节/采样 × 2 声道）。
        XCTAssertEqual(p16.bytesWritten * 2, f32.bytesWritten)
    }

    /// 16 位到底丢了多少精度：往返之后每个采样的误差必须落在量化界内。
    ///
    /// 这条把「精度减半」从一句形容词变成一个数，也是「16 位录音听得出区别吗」
    /// 这类问题唯一诚实的答案。
    ///
    /// **界不是「一个 LSB」，而是「缩放偏差 + 半个 LSB」，因为写入与读取的
    /// 缩放系数不一样**：
    ///   - 写：`Int16(round(v * 32767))`
    ///   - 读：`Float(n) / 32768.0`
    ///
    /// 正负满量程都能表示的前提下，两边各自都是常见写法（读侧用 32768 是为了
    /// 让 -32768 不溢出），但配在一起就留下一个**固定方向的增益偏差**：
    /// 回放幅度比原始小约 1/32768（-0.003%，约 -90 dB）。听感上无关紧要，
    /// 数值上是系统性的——所以这里按真实界断言，而不是按「一个 LSB」的理想值。
    /// （初版就是按一个 LSB 写的，被第 20 个采样打红，才发现这个不对称。）
    func testPCM16RoundTripStaysWithinTheQuantisationBound() throws {
        let original: [Float] = (0..<2000).map { i in
            Float(sin(2 * Double.pi * 440 * Double(i) / 48000)) * 0.8
        }
        let w = try WAVWriter(url: url("roundtrip.wav"), sampleRate: 48000, channels: 1,
                              format: .pcm16)
        try w.append(original)
        w.close()

        let reader = try WAVReader(url: url("roundtrip.wav"))
        defer { reader.close() }
        let back = try reader.readFrames(startingAt: 0, count: original.count)

        XCTAssertEqual(reader.format, .pcm16, "读回来应当认得这是 16 位")
        XCTAssertEqual(back.count, original.count, "采样数量应当一一对应")

        let scaleBias = 1.0 / 32768.0      // 写 ×32767、读 ÷32768 的固定比值偏差
        let halfLSB = 1.0 / 65536.0        // 量化到最近整数的舍入
        var maxError = 0.0
        for (i, pair) in zip(original, back).enumerated() {
            let bound = abs(Double(pair.0)) * scaleBias + halfLSB
            let error = abs(Double(pair.0) - Double(pair.1))
            XCTAssertLessThanOrEqual(error, bound,
                "第 \(i) 个采样误差 \(error) 超出量化界 \(bound)")
            maxError = max(maxError, error)
        }
        // 满量程附近的误差应当在 4.6e-5 量级（= scaleBias + halfLSB）
        XCTAssertLessThan(maxError, 5e-5, "误差比量化界还大，说明转换实现有问题")

        // **误差必须真的存在。** 一个把 pcm16 当 float32 写的实现能让上面全部通过
        // （误差恒为 0 当然不超界），却一个字节都没省。
        // 体积那几条测试也能抓住它，但这条是从数值侧独立验一次。
        XCTAssertGreaterThan(maxError, 0, "零误差说明根本没做 16 位量化")
    }

    func testPCM16ClampsOutOfRangeSamples() throws {
        let w = try WAVWriter(url: url(), sampleRate: 48000, channels: 1, format: .pcm16)
        // 故意给超出 [-1, 1] 的值，写 PCM16 前必须 clamp，否则整数溢出会变成噪声
        try w.append([0.0, 1.0, -1.0, 5.0, -5.0, 0.5])
        w.close()

        let data = try Data(contentsOf: url())
        XCTAssertEqual(data.count, WAVWriter.headerSize + 6 * 2)
        func i16(_ i: Int) -> Int16 {
            let off = WAVWriter.headerSize + i * 2
            let raw = UInt16(data[off]) | (UInt16(data[off + 1]) << 8)
            return Int16(bitPattern: raw)
        }
        XCTAssertEqual(i16(0), 0)
        XCTAssertEqual(i16(1), 32767)
        XCTAssertEqual(i16(2), -32767)
        XCTAssertEqual(i16(3), 32767, "5.0 必须被 clamp 到最大值而不是溢出")
        XCTAssertEqual(i16(4), -32767)
    }

    func testReopeningSameURLTruncates() throws {
        let u = url()
        let first = try WAVWriter(url: u, sampleRate: 48000, channels: 1, format: .float32)
        try first.append(sine(frames: 1000, channels: 1))
        first.close()

        let second = try WAVWriter(url: u, sampleRate: 48000, channels: 1, format: .float32)
        try second.append(sine(frames: 100, channels: 1))
        second.close()

        let info = try WAVWriter.readHeader(at: u)
        XCTAssertEqual(info.frameCount, 100, "重开同一路径必须截断，不能追加到旧数据后")
    }

    func testEmptyFileIsStillValidWAV() throws {
        let w = try WAVWriter(url: url(), sampleRate: 48000, channels: 2, format: .float32)
        w.close()
        let info = try WAVWriter.readHeader(at: url())
        XCTAssertEqual(info.frameCount, 0)
        XCTAssertEqual(info.dataSize, 0)
        XCTAssertTrue(info.isConsistent)
    }

    func testInvalidParametersRejected() {
        XCTAssertThrowsError(try WAVWriter(url: url(), sampleRate: 0, channels: 2)) { e in
            guard let mr = e as? MRError, case .invalidWAV = mr else {
                return XCTFail("采样率 0 应抛 invalidWAV，实际 \(e)")
            }
        }
        XCTAssertThrowsError(try WAVWriter(url: url(), sampleRate: 48000, channels: 0)) { e in
            guard let mr = e as? MRError, case .invalidWAV = mr else {
                return XCTFail("通道数 0 应抛 invalidWAV，实际 \(e)")
            }
        }
    }

    // MARK: - 崩溃场景

    /// 核心用例：进程在 finalize 之前被杀掉。
    /// 头部声明的 data 长度是 0（占位值），但文件里已经躺着一堆音频数据。
    func testCrashBeforeFinalizeLeavesStaleHeader() throws {
        let u = url()
        let w = try WAVWriter(url: u, sampleRate: 48000, channels: 1, format: .float32)
        try w.append(sine(frames: 48000, channels: 1))   // 写满 1 秒，但不 finalize
        w.abort()   // 模拟进程被杀：句柄关掉，头保持占位值

        let stale = try WAVWriter.readHeader(at: u)
        XCTAssertEqual(stale.dataSize, 0, "未 finalize 时头部 data 长度仍是占位 0")
        XCTAssertFalse(stale.isConsistent, "应被识别为头部与实际不一致")
        XCTAssertEqual(stale.frameCount, 0, "此时按头部读会得到 0 帧——这就是崩溃后看起来「录音是空的」的原因")
    }

    func testRepairHeaderRecoversRealLength() throws {
        let u = url()
        let w = try WAVWriter(url: u, sampleRate: 48000, channels: 1, format: .float32)
        try w.append(sine(frames: 48000, channels: 1))
        w.abort()   // 同样不 finalize

        let repaired = try WAVWriter.repairHeader(at: u)
        XCTAssertEqual(repaired.frameCount, 48000, "按文件实际长度反推出的帧数必须正确")
        XCTAssertEqual(repaired.duration, 1.0, accuracy: 1e-9)
        XCTAssertTrue(repaired.isConsistent)

        // 修复后应能正常读回
        let reread = try WAVWriter.readHeader(at: u)
        XCTAssertEqual(reread.frameCount, 48000)
        XCTAssertTrue(reread.isConsistent)
    }

    func testRepairIsIdempotent() throws {
        let u = url()
        let w = try WAVWriter(url: u, sampleRate: 48000, channels: 2, format: .float32)
        try w.append(sine(frames: 7200, channels: 2))
        w.abort()

        let a = try WAVWriter.repairHeader(at: u)
        let b = try WAVWriter.repairHeader(at: u)
        XCTAssertEqual(a.frameCount, b.frameCount)
        XCTAssertEqual(b.frameCount, 7200)
    }

    func testRepairOnAlreadyValidFileChangesNothing() throws {
        let u = url()
        let w = try WAVWriter(url: u, sampleRate: 48000, channels: 1, format: .float32)
        try w.append(sine(frames: 1000, channels: 1))
        try w.finalize()
        w.close()

        let info = try WAVWriter.repairHeader(at: u)
        XCTAssertEqual(info.frameCount, 1000)
        XCTAssertTrue(info.isConsistent)
    }

    func testRepairRejectsNonWAV() throws {
        let u = url("bad.wav")
        try Data("这不是一个 WAV 文件，只是一段随便的文本内容来凑够长度".utf8).write(to: u)
        XCTAssertThrowsError(try WAVWriter.repairHeader(at: u)) { e in
            guard let mr = e as? MRError, case .invalidWAV = mr else {
                return XCTFail("非 WAV 应抛 invalidWAV，实际 \(e)")
            }
        }
    }

    func testReadRejectsTooShortFile() throws {
        let u = url("short.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: u)   // "RIFF" 只有 4 字节
        XCTAssertThrowsError(try WAVWriter.readHeader(at: u))
    }

    // MARK: - 格式码

    func testFormatIdentifiers() {
        XCTAssertEqual(WAVSampleFormat.pcm16.audioFormatID, 1)
        XCTAssertEqual(WAVSampleFormat.pcm16.bitsPerSample, 16)
        XCTAssertEqual(WAVSampleFormat.pcm16.bytesPerSample, 2)
        XCTAssertEqual(WAVSampleFormat.float32.audioFormatID, 3)
        XCTAssertEqual(WAVSampleFormat.float32.bitsPerSample, 32)
        XCTAssertEqual(WAVSampleFormat.float32.bytesPerSample, 4)
    }

    func testLargeWriteSpansManyAppends() throws {
        // 模拟真实录制：48kHz 单声道，每秒回调约 50 次，持续 10 秒
        let w = try WAVWriter(url: url(), sampleRate: 48000, channels: 1, format: .float32)
        var total = 0
        for _ in 0..<500 {
            let chunk = sine(frames: 960, channels: 1)
            try w.append(chunk)
            total += 960
        }
        try w.finalize()
        XCTAssertEqual(w.framesWritten, total)
        w.close()

        let info = try WAVWriter.readHeader(at: url())
        XCTAssertEqual(info.frameCount, 480_000)
        XCTAssertEqual(info.duration, 10.0, accuracy: 1e-9)
    }

    // MARK: - 4 GiB 上限对应的时长（随位深变化）

    /// 位深减半 → 上限时长翻倍。
    ///
    /// 这四个数直接决定触顶告警与 GUI 帮助文案里该怎么告诉用户，也是两者
    /// 共用的唯一出处（`WAVWriter.maxDurationHours`）。刻意填四组而不是一两组：
    /// 单声道/立体声 × 两种位深，任何一组把参数配错（比如声道数没进分母、
    /// 位深没进分母）都会让至少一组对不上。
    ///
    /// 退化示例：把静态方法分母里的 `format.bytesPerSample` 去掉，
    /// pcm16 的两组会立刻变成 float32 的值，本用例变红。
    func testMaxDurationHoursDoublesWhenBitDepthHalves() {
        let micF32 = WAVWriter.maxDurationHours(sampleRate: 48000, channels: 1, format: .float32)
        let micP16 = WAVWriter.maxDurationHours(sampleRate: 48000, channels: 1, format: .pcm16)
        let sysF32 = WAVWriter.maxDurationHours(sampleRate: 48000, channels: 2, format: .float32)
        let sysP16 = WAVWriter.maxDurationHours(sampleRate: 48000, channels: 2, format: .pcm16)

        XCTAssertEqual(micF32, 6.21, accuracy: 0.05, "48kHz 单声道 float32 约 6.21 小时")
        XCTAssertEqual(micP16, 12.43, accuracy: 0.05, "48kHz 单声道 pcm16 约 12.43 小时")
        XCTAssertEqual(sysF32, 3.11, accuracy: 0.05, "48kHz 立体声 float32 约 3.11 小时")
        XCTAssertEqual(sysP16, 6.21, accuracy: 0.05, "48kHz 立体声 pcm16 约 6.21 小时")

        XCTAssertEqual(micP16, micF32 * 2, accuracy: 0.01, "位深减半，上限时长必须翻倍")
        XCTAssertEqual(sysP16, sysF32 * 2, accuracy: 0.01)
    }

    // MARK: - 量化（NaN / 满量程 / 写入后生效值）

    /// 量化必须把非有限值当静音丢掉，且不能伤到合法的满量程。
    ///
    /// 不能依赖 `min`/`max` 的 NaN 语义：Swift 的 `min(1.0, .nan)` 返回 `1.0`
    /// （不传播 NaN），于是 NaN 会被钳成满量程 → `Int16(32767)`，听感上是一记爆音，
    /// 而 32 位浮点路径是原样保留的——这是 16 位**独有**的失真。
    ///
    /// 反向那一半同样重要：修 non-finite 不能顺手把**合法**的 ±1.0 也改掉，
    /// 那会让满量程信号凭空变小。
    ///
    /// 退化示例：删掉 `guard v.isFinite else { return 0 }`，
    /// 前三条断言变红（NaN/±∞ 会被钳成 ±32767）。
    func testQuantizeTreatsNonFiniteAsSilenceButKeepsFullScale() {
        XCTAssertEqual(WAVWriter.quantizeToInt16(.nan), 0, "NaN 必须当静音，不能钳成满量程爆音")
        XCTAssertEqual(WAVWriter.quantizeToInt16(.infinity), 0)
        XCTAssertEqual(WAVWriter.quantizeToInt16(-.infinity), 0)

        XCTAssertEqual(WAVWriter.quantizeToInt16(1.0), 32767, "合法满量程不能被顺手改掉")
        XCTAssertEqual(WAVWriter.quantizeToInt16(-1.0), -32767)
    }

    /// 自检用的「写入后实际生效值」必须反映量化损失。
    ///
    /// 16 位会把 |v| < 0.5/32767 ≈ 1.53e-5 的采样量化成 0。自检的峰值若按量化前的
    /// float 算，一整段被量化成静音的录音会被 `RecordingSanity.isAllZero` 判成「有内容」。
    ///
    /// 退化示例：把 `effectiveAfterQuantisation` 改成直接返回入参，
    /// 第一条断言变红。
    func testEffectiveAfterQuantisationReflectsTheLoss() {
        XCTAssertEqual(WAVWriter.effectiveAfterQuantisation(1e-5), 0,
                       "低于半个 LSB 的采样写进 16 位文件后就是 0")
        XCTAssertGreaterThan(WAVWriter.effectiveAfterQuantisation(0.5), 0)
    }
}
