import XCTest
@testable import MRCore

/// 波形包络。
///
/// 全部用**真实写出的 WAV 文件**驱动，不 mock 文件系统——这一层真正的风险恰恰在
/// 「跨块流式读取时帧号有没有算对」，把文件 mock 掉就等于把要测的东西测没了。
final class WaveformEnvelopeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("waveform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 写一个 WAV。`samples` 是**交错**采样。
    @discardableResult
    private func writeWAV(
        _ samples: [Float],
        channels: Int = 1,
        sampleRate: Double = 48000,
        name: String = "t.wav"
    ) throws -> URL {
        let url = root.appendingPathComponent(name)
        let writer = try WAVWriter(url: url, sampleRate: sampleRate, channels: channels)
        if !samples.isEmpty { try writer.append(samples) }
        try writer.finalize()
        writer.close()
        return url
    }

    // MARK: - 退化输入

    func testEmptyFileGivesFlatEnvelope() throws {
        let url = try writeWAV([])
        let envelope = try WaveformEnvelope.compute(from: url, buckets: 8)

        XCTAssertEqual(envelope.peaks.count, 8, "桶数必须与请求一致，界面才好直接画")
        XCTAssertEqual(envelope.peaks, [Float](repeating: 0, count: 8))
        XCTAssertEqual(envelope.referenceAmplitude, 0)
        XCTAssertTrue(envelope.isSilent)
    }

    func testAllZeroSamplesGiveFlatEnvelope() throws {
        let url = try writeWAV([Float](repeating: 0, count: 1000))
        let envelope = try WaveformEnvelope.compute(from: url, buckets: 10)

        XCTAssertEqual(envelope.referenceAmplitude, 0)
        XCTAssertTrue(envelope.isSilent, "全零音轨必须是平的，不能把数值噪声放大成波形")
        XCTAssertEqual(envelope.peaks, [Float](repeating: 0, count: 10))
    }

    func testZeroBucketsGivesEmptyArray() throws {
        let url = try writeWAV([0.5, 0.5])
        let envelope = try WaveformEnvelope.compute(from: url, buckets: 0)
        XCTAssertTrue(envelope.peaks.isEmpty)
    }

    func testSilentFactoryHandlesNonPositiveBucketCount() {
        XCTAssertEqual(WaveformEnvelope.Envelope.silent(buckets: 4).peaks.count, 4)
        XCTAssertTrue(WaveformEnvelope.Envelope.silent(buckets: -3).peaks.isEmpty)
    }

    // MARK: - 幅度语义

    func testNegativeSamplesCountAsMagnitude() throws {
        let url = try writeWAV([-0.7, 0.3, -0.2])
        let envelope = try WaveformEnvelope.compute(from: url, buckets: 1)
        XCTAssertEqual(envelope.referenceAmplitude, 0.7, accuracy: 1e-6)
    }

    func testLoudestChannelWins() throws {
        let url = try writeWAV([0.5, 0.9, 0.5, 0.9], channels: 2)
        let envelope = try WaveformEnvelope.compute(from: url, buckets: 1)

        XCTAssertEqual(envelope.referenceAmplitude, 0.9, accuracy: 1e-6)
        XCTAssertEqual(envelope.peaks[0], 1.0, accuracy: 1e-6)
    }

    func testSoundOnlyInRightChannelIsNotMissed() throws {
        // 左声道全零、右声道有声音。只看 0 通道会把这轨判成全零。
        let url = try writeWAV([0, 0.8, 0, 0.8], channels: 2)
        let envelope = try WaveformEnvelope.compute(from: url, buckets: 1)

        XCTAssertEqual(envelope.referenceAmplitude, 0.8, accuracy: 1e-6,
                       "只看第 0 通道会漏掉只出现在右声道的声音")
    }

    func testEnvelopeIsNormalizedToReference() throws {
        // 最高 0.25 → 归一化后峰值应为 1.0，同时把原始幅度单独报出来。
        let url = try writeWAV([0.1, 0.25, 0.05])
        let envelope = try WaveformEnvelope.compute(from: url, buckets: 1)

        XCTAssertEqual(envelope.peaks[0], 1.0, accuracy: 1e-6)
        XCTAssertEqual(envelope.referenceAmplitude, 0.25, accuracy: 1e-6,
                       "归一化前的幅度必须保留，否则轻声音轨会被放大成正常音量")
    }

    // MARK: - 分桶

    func testRampPartitionsIntoStrictlyIncreasingBuckets() throws {
        // 每帧幅度随帧号单调递增。若分桶漏帧或重叠，桶间就不再严格递增。
        let frames = 1000
        let samples = (0..<frames).map { Float($0 + 1) / Float(frames) }
        let url = try writeWAV(samples)

        let envelope = try WaveformEnvelope.compute(from: url, buckets: 10)

        XCTAssertEqual(envelope.referenceAmplitude, 1.0, accuracy: 1e-5)
        XCTAssertEqual(envelope.peaks.count, 10)
        for bucket in 1..<envelope.peaks.count {
            XCTAssertGreaterThan(envelope.peaks[bucket], envelope.peaks[bucket - 1],
                                 "第 \(bucket) 桶没比前一桶高，说明分桶漏帧或重叠了")
        }
        XCTAssertEqual(envelope.peaks[9], 1.0, accuracy: 1e-5, "末桶必须吃到最后一帧")
    }

    func testBucketCountNotDividingFrameCountStillCoversEveryBucket() throws {
        // 1000 帧分 7 桶除不尽，余数必须落进最后一桶，不能凭空丢帧。
        let frames = 1000
        let samples = (0..<frames).map { Float($0 + 1) / Float(frames) }
        let url = try writeWAV(samples)

        let envelope = try WaveformEnvelope.compute(from: url, buckets: 7)

        XCTAssertEqual(envelope.peaks.count, 7)
        for bucket in envelope.peaks.indices {
            XCTAssertGreaterThan(envelope.peaks[bucket], 0,
                                 "第 \(bucket) 桶是空的，说明有帧没被任何桶覆盖")
        }
        for bucket in 1..<envelope.peaks.count {
            XCTAssertGreaterThan(envelope.peaks[bucket], envelope.peaks[bucket - 1])
        }
    }

    func testMoreBucketsThanFrames() throws {
        let url = try writeWAV([1.0, 0.5])
        let envelope = try WaveformEnvelope.compute(from: url, buckets: 10)

        XCTAssertEqual(envelope.peaks.count, 10, "桶数必须与请求一致")
        XCTAssertEqual(envelope.referenceAmplitude, 1.0, accuracy: 1e-6)
        XCTAssertEqual(envelope.peaks.filter { $0 > 0 }.count, 2,
                       "两帧两桶，多出来的桶应当是空的，且没有帧被丢掉")
    }

    /// 跨块是这一层最容易写错的地方。
    ///
    /// 100000 帧超过了 `WAVReader` 默认的 48000 帧块大小，会被切成 3 块。
    /// 如果每一块都从帧号 0 重新计数，波形就会变成三段重复的短斜坡——
    /// 看起来仍然「像波形」，肉眼根本发现不了。所以用严格单调性钉死它。
    func testFrameCounterSurvivesChunkBoundaries() throws {
        let frames = 100_000
        let samples = (0..<frames).map { Float($0 + 1) / Float(frames) }
        let url = try writeWAV(samples)

        let envelope = try WaveformEnvelope.compute(from: url, buckets: 100)

        XCTAssertEqual(envelope.referenceAmplitude, 1.0, accuracy: 1e-5)
        XCTAssertEqual(envelope.peaks.count, 100)
        for bucket in 1..<envelope.peaks.count {
            XCTAssertGreaterThan(envelope.peaks[bucket], envelope.peaks[bucket - 1],
                                 "第 \(bucket) 桶没比前一桶高，说明跨块时帧号被重新计数了")
        }
    }

    func testStereoChunkBoundaryKeepsChannelAlignment() throws {
        // 交错写入的立体声跨块时，帧号累计必须按帧而不是按采样。
        // 这里让两个通道幅度不同：若按采样数计数，后半段的桶会整体错位。
        let frames = 100_000
        var samples: [Float] = []
        samples.reserveCapacity(frames * 2)
        for index in 0..<frames {
            let value = Float(index + 1) / Float(frames)
            samples.append(value)          // 左：递增
            samples.append(value / 2)      // 右：左的一半
        }
        let url = try writeWAV(samples, channels: 2, name: "stereo.wav")

        let envelope = try WaveformEnvelope.compute(from: url, buckets: 50)

        XCTAssertEqual(envelope.referenceAmplitude, 1.0, accuracy: 1e-5)
        for bucket in 1..<envelope.peaks.count {
            XCTAssertGreaterThan(envelope.peaks[bucket], envelope.peaks[bucket - 1])
        }
    }
}
