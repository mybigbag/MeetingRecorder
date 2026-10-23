import XCTest
@testable import MRCore

/// 分段链路的前置能力：WAV 读取、静音检测、切片。
///
/// 这三块是「长会议分段」的地基。之前 `Segmenter` 是孤儿代码——
/// 它要静音区间，却没有任何代码算静音。这里补的就是那条断链。
final class SegmentationTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private let rate: Double = 48000

    /// 生成「有声 + 静音」交替的单声道信号。
    /// - Parameter pattern: (时长秒, 是否有声) 序列
    private func toneAndSilence(
        _ pattern: [(Double, Bool)], amplitude: Float = 0.4, rate: Double? = nil
    ) -> [Float] {
        let sr = rate ?? self.rate
        var out: [Float] = []
        var phase = 0.0
        for (seconds, loud) in pattern {
            let frames = Int(seconds * sr)
            for _ in 0..<frames {
                let v = loud ? amplitude * Float(sin(2 * Double.pi * 440 * phase / sr)) : 0
                out.append(v)
                phase += 1
            }
        }
        return out
    }

    private func write(
        _ samples: [Float], channels: Int = 1, name: String, rate: Double? = nil
    ) throws -> URL {
        let u = url(name)
        let w = try WAVWriter(
            url: u, sampleRate: rate ?? self.rate, channels: channels, format: .float32)
        try w.append(samples)
        try w.finalize()
        w.close()
        return u
    }

    // MARK: - WAVReader

    func testReadBackMatchesWrittenSamplesExactly() throws {
        let samples = toneAndSilence([(0.2, true), (0.1, false)], amplitude: 0.37)
        let u = try write(samples, name: "roundtrip.wav")

        let r = try WAVReader(url: u)
        defer { r.close() }
        XCTAssertEqual(r.channels, 1)
        XCTAssertEqual(r.sampleRate, rate)
        XCTAssertEqual(r.frameCount, samples.count)

        let read = try r.readFrames(startingAt: 0, count: samples.count)
        XCTAssertEqual(read.count, samples.count)
        for i in 0..<samples.count {
            XCTAssertEqual(read[i], samples[i], accuracy: 1e-7,
                           "float32 往返必须逐点精确，下标 \(i)")
        }
    }

    func testPartialReadFromMiddleIsOffsetCorrectly() throws {
        // 前半静音、后半有声：从中间读应当只拿到有声部分
        let samples = toneAndSilence([(0.5, false), (0.5, true)])
        let u = try write(samples, name: "mid.wav")

        let r = try WAVReader(url: u)
        defer { r.close() }

        let mid = try r.read(start: 0.5, end: 1.0)
        XCTAssertEqual(mid.count, Int(0.5 * rate))
        let peak = mid.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.3, "从 0.5 秒起应读到有声段")

        let head = try r.read(start: 0, end: 0.5)
        XCTAssertEqual(head.map { abs($0) }.max() ?? 1, 0, accuracy: 1e-9,
                       "0–0.5 秒是静音，读出应为全零")
    }

    func testReadBeyondEndReturnsAvailableOnly() throws {
        let samples = toneAndSilence([(0.1, true)])
        let u = try write(samples, name: "short.wav")
        let r = try WAVReader(url: u)
        defer { r.close() }

        let over = try r.readFrames(startingAt: 0, count: samples.count * 3)
        XCTAssertEqual(over.count, samples.count, "越界读取只返回实际可读部分，不报错")
    }

    func testReaderRejectsNonWAV() throws {
        let u = url("bad.wav")
        try Data("not a wav file at all, just text".utf8).write(to: u)
        XCTAssertThrowsError(try WAVReader(url: u))
    }

    // MARK: - SilenceDetector

    func testDetectsSingleSilenceGap() {
        // 1s 有声 + 2s 静音 + 1s 有声
        let d = SilenceDetector(sampleRate: rate, channels: 1)
        d.append(toneAndSilence([(1.0, true), (2.0, false), (1.0, true)]))
        let silences = d.finish()

        XCTAssertEqual(silences.count, 1, "应识别出一段静音")
        guard let s = silences.first else { return }
        // 静音实际在 [1.0, 3.0]，两端各收缩 0.05
        XCTAssertEqual(s.lowerBound, 1.05, accuracy: 0.06)
        XCTAssertEqual(s.upperBound, 2.95, accuracy: 0.06)
    }

    func testIgnoresSilenceShorterThanMinimum() {
        let settings = SilenceDetector.Settings(minSilenceSeconds: 0.5)
        let d = SilenceDetector(sampleRate: rate, channels: 1, settings: settings)
        // 中间只有 0.2 秒静音，低于 0.5 秒门槛
        d.append(toneAndSilence([(1.0, true), (0.2, false), (1.0, true)]))
        XCTAssertTrue(d.finish().isEmpty, "短于门槛的静音不应成为切点")
    }

    func testDetectsMultipleGaps() {
        let d = SilenceDetector(sampleRate: rate, channels: 1)
        d.append(toneAndSilence([
            (0.5, true), (1.0, false), (0.5, true), (1.5, false), (0.5, true),
        ]))
        let silences = d.finish()
        XCTAssertEqual(silences.count, 2)
        XCTAssertLessThan(silences[0].lowerBound, silences[1].lowerBound, "区间应按时间升序")
    }

    func testStreamingInChunksMatchesSingleFeed() {
        let samples = toneAndSilence([(1.0, true), (1.5, false), (1.0, true)])

        let whole = SilenceDetector(sampleRate: rate, channels: 1)
        whole.append(samples)
        let a = whole.finish()

        // 故意用非窗口整数倍的块长，验证跨块拼窗口不出错
        let chunked = SilenceDetector(sampleRate: rate, channels: 1)
        var i = 0
        let chunk = 7777
        while i < samples.count {
            let take = min(chunk, samples.count - i)
            chunked.append(Array(samples[i..<(i + take)]))
            i += take
        }
        let b = chunked.finish()

        XCTAssertEqual(a.count, b.count, "分块喂入与整段喂入结果必须一致")
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.lowerBound, y.lowerBound, accuracy: 1e-6)
            XCTAssertEqual(x.upperBound, y.upperBound, accuracy: 1e-6)
        }
    }

    func testFinishIsIdempotent() {
        let d = SilenceDetector(sampleRate: rate, channels: 1)
        d.append(toneAndSilence([(1.0, true), (1.0, false), (1.0, true)]))
        let first = d.finish()
        let second = d.finish()
        XCTAssertEqual(first.count, second.count, "重复 finish 不应重复累积静音段")
    }

    func testStereoChannelsHandled() {
        // 立体声：每帧 2 个采样。静音应仍被识别，且时间轴按帧而非采样数计。
        let pattern: [(Double, Bool)] = [(0.5, true), (1.0, false), (0.5, true)]
        var stereo: [Float] = []
        var phase = 0.0
        for (seconds, loud) in pattern {
            for _ in 0..<Int(seconds * rate) {
                let v: Float = loud ? 0.4 * Float(sin(2 * Double.pi * 440 * phase / rate)) : 0
                stereo.append(v); stereo.append(v)
                phase += 1
            }
        }
        let d = SilenceDetector(sampleRate: rate, channels: 2)
        d.append(stereo)
        let silences = d.finish()
        XCTAssertEqual(silences.count, 1)
        XCTAssertEqual(silences[0].lowerBound, 0.55, accuracy: 0.06,
                       "立体声下时间轴必须按帧算，不能被通道数放大")
    }

    func testNoSilenceInContinuousTone() {
        let d = SilenceDetector(sampleRate: rate, channels: 1)
        d.append(toneAndSilence([(2.0, true)]))
        XCTAssertTrue(d.finish().isEmpty)
    }

    func testDbFSBounds() {
        XCTAssertEqual(SilenceDetector.dbFS(0), -160, "零幅度兜底，避免 log(0)")
        XCTAssertEqual(SilenceDetector.dbFS(1.0), 0, accuracy: 1e-9)
        XCTAssertEqual(SilenceDetector.dbFS(0.5), 20 * log10(0.5), accuracy: 1e-9)
    }

    // MARK: - AudioSlicer

    func testSliceExtractsRequestedRange() throws {
        // 0–0.5 静音，0.5–1.5 有声，1.5–2.0 静音
        let samples = toneAndSilence([(0.5, false), (1.0, true), (0.5, false)])
        let src = try write(samples, name: "src.wav")
        let dst = url("slice.wav")

        let info = try AudioSlicer.slice(source: src, to: dst, start: 0.5, end: 1.5)

        XCTAssertEqual(info.duration, 1.0, accuracy: 0.01)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.sampleRate, rate)
        XCTAssertTrue(info.isConsistent, "切片文件必须 finalize，头部长度与实际一致")

        let r = try WAVReader(url: dst)
        defer { r.close() }
        let body = try r.readFrames(startingAt: 0, count: r.frameCount)
        let peak = body.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.3, "切出的应是有声段")
        // 整体能量应接近原始正弦幅度，说明两端没有混进大段静音
        let rms = (body.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, body.count))).squareRoot()
        XCTAssertGreaterThan(rms, 0.2, "切片应基本被有声内容填满")
    }

    func testSlicePreservesStereoAndFormat() throws {
        let frames = Int(0.5 * rate)
        var stereo: [Float] = []
        for i in 0..<frames { stereo.append(Float(sin(Double(i) * 0.01))); stereo.append(0.25) }
        let src = try write(stereo, channels: 2, name: "st.wav")

        let dst = url("st-slice.wav")
        let info = try AudioSlicer.slice(source: src, to: dst, start: 0.1, end: 0.4)
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.audioFormatID, 3, "切片应保持 float32 格式")
        XCTAssertEqual(info.duration, 0.3, accuracy: 0.01)
    }

    func testSliceClampsToFileBounds() throws {
        let samples = toneAndSilence([(0.3, true)])
        let src = try write(samples, name: "clamp.wav")
        let dst = url("clamp-slice.wav")
        // 请求远超文件长度
        let info = try AudioSlicer.slice(source: src, to: dst, start: 0, end: 99)
        XCTAssertEqual(info.duration, 0.3, accuracy: 0.02, "应被夹到文件实际长度")
    }

    func testInspectReportsSourceFacts() throws {
        let samples = toneAndSilence([(0.25, true)])
        let src = try write(samples, name: "inspect.wav")
        let info = try AudioSlicer.inspect(src)
        XCTAssertEqual(info.duration, 0.25, accuracy: 0.01)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.sampleRate, rate)
        XCTAssertEqual(info.format, .float32)
    }

    // MARK: - SegmentPlan（三者串起来）

    func testPlanDoesNotScanWhenShort() throws {
        let src = try write(toneAndSilence([(1.0, true)]), name: "shortplan.wav")
        let plan = SegmentPlan(segmenter: Segmenter(maxSegment: 300))
        let out = try plan.plan(forFileAt: src)

        XCTAssertFalse(out.didSegment)
        XCTAssertEqual(out.segments.count, 1)
        XCTAssertTrue(out.silences.isEmpty, "短音频不应触发静音扫描")
        XCTAssertEqual(out.segments[0].end, 1.0, accuracy: 0.01)
    }

    func testPlanFindsCutsAtSilenceInLongAudio() throws {
        // 每 60 秒有声之间插 2 秒静音，总长约 8 分钟（> 300 秒上限）。
        // 用 8kHz 生成，只为把测试耗时压下来——分段逻辑与采样率无关。
        let sr = 8000.0
        var pattern: [(Double, Bool)] = []
        for _ in 0..<8 { pattern.append((60, true)); pattern.append((2, false)) }
        let src = try write(toneAndSilence(pattern, rate: sr), name: "long.wav", rate: sr)

        let plan = SegmentPlan(segmenter: Segmenter(maxSegment: 300, minSegment: 10))
        let out = try plan.plan(forFileAt: src)

        XCTAssertTrue(out.didSegment, "8 分钟音频必须被切段")
        XCTAssertGreaterThanOrEqual(out.segments.count, 2)
        XCTAssertEqual(out.segments.first?.start, 0)
        XCTAssertEqual(out.segments.last?.end ?? 0, out.duration, accuracy: 0.05,
                       "最后一段必须覆盖到文件结尾")

        // 段之间必须首尾相接、不重叠、不跳空
        for i in 1..<out.segments.count {
            XCTAssertEqual(out.segments[i].start, out.segments[i - 1].end, accuracy: 1e-6,
                           "段 \(i) 与上一段之间不应有缝隙")
        }
        // 每段都不得突破上限
        for (i, seg) in out.segments.enumerated() {
            XCTAssertLessThanOrEqual(seg.duration, 300 + 1e-6, "第 \(i) 段超出上限")
        }
        // 切点应落在静音附近（60 秒有声之后）
        let secondCut = out.segments.first?.end ?? 0
        XCTAssertGreaterThan(secondCut, 55, "切点不应早于第一段有声内容结束")
    }

    func testPlanLastSegmentMergedWhenTooShort() throws {
        // 305 秒有声 + 3 秒静音 + 5 秒有声：
        // 理想切点在 300，静音中点在搜索窗口内；余下不足 minSegment 时应并入前段
        let sr = 8000.0
        let pattern: [(Double, Bool)] = [(305, true), (3, false), (5, true)]
        let src = try write(toneAndSilence(pattern, rate: sr), name: "tail.wav", rate: sr)

        let plan = SegmentPlan(segmenter: Segmenter(maxSegment: 300, minSegment: 20))
        let out = try plan.plan(forFileAt: src)

        XCTAssertEqual(out.segments.last?.end ?? 0, out.duration, accuracy: 0.05)
        for (i, seg) in out.segments.enumerated() where i < out.segments.count - 1 {
            XCTAssertGreaterThanOrEqual(seg.duration, 1.0, "非尾段不该被切得过短")
        }
    }
}
