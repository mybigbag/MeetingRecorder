import XCTest
@testable import MRCore

/// C 档转码（`AudioTranscoder`）的用例。
///
/// ## 这个模块为什么值得这么多用例
///
/// 转码是**唯一会批量改写用户已有录音**的功能。别的功能写坏了，最坏是这一次录音
/// 或这一次转写不对劲；转码写坏了，用户的 3.28 GiB 存量会被批量改成错的格式，
/// 而且**改完之后没有任何地方会报错**——文件照样能播，界面照样显示时长，
/// 只是内容与原始录音不再一致。所以这里的重点不是「功能能用」，
/// 而是「它不该在不通知用户的情况下改变东西」。
///
/// 每条用例都带一条「退化示例」，说明改坏哪里会红。
final class AudioTranscoderTests: XCTestCase {

    // MARK: - 夹具

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-transcode-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func url(_ name: String) -> URL {
        dir.appendingPathComponent(name)
    }

    /// 写一个 WAV 并回读校验过（头部真的对得上）后才返回。
    @discardableResult
    private func makeWAV(
        _ name: String,
        seconds: Double,
        rate: Double,
        channels: Int,
        format: WAVSampleFormat,
        generator: (Int) -> Float
    ) throws -> URL {
        let target = url(name)
        let writer = try WAVWriter(url: target, sampleRate: rate,
                                   channels: channels, format: format)
        let frames = Int(rate * seconds)
        // 按帧生成，保证每帧的各声道都有确定值（降混结果才可预期）
        var block: [Float] = []
        block.reserveCapacity(48000 * channels)
        for f in 0..<frames {
            for c in 0..<channels {
                block.append(generator(f * channels + c))
            }
            if block.count >= 48000 * channels {
                try writer.append(block)
                block.removeAll(keepingCapacity: true)
            }
        }
        if !block.isEmpty { try writer.append(block) }
        try writer.finalize()
        writer.close()
        return target
    }

    /// 双声道：左声道 1 kHz 正弦、右声道静音。
    ///
    /// 刻意用**单边**信号：这样「有没有做降混」是能被看出来的（不做降混时
    /// 静音的右声道会与左声道交错，FIR 把两者平均成半幅），
    /// 而恒定值输入会被低通滤波器的通带增益掩盖过去——本项目已经踩过一次
    /// 「用常量输入验降混，删掉降混照样绿」的坑。
    private func stereoLeftOnly(frame: Int) -> Float {
        Float(0.5 * sin(2 * Double.pi * 1000 * Double(frame) / 48000))
    }

    // MARK: - 目标格式决策（纯函数）

    /// B 档：48 kHz 立体声 → 16 位 · 24 kHz · 单声道。
    func testBTierTargetIsMono24kPCM16() throws {
        let source = try XCTUnwrap(WAVWriter.readHeader(
            at: makeWAV("s.wav", seconds: 1, rate: 48000, channels: 2,
                        format: .float32, generator: { _ in 0 })))
        let target = AudioTranscoder.target(for: .bTier, source: source)
        XCTAssertEqual(target.sampleRate, 24000)
        XCTAssertEqual(target.channels, 1)
        XCTAssertEqual(target.format, .pcm16)
        // 退化示例：把 `min(源率, 24000)` 写成常量 24000 → 16 kHz 源会被升采样，这条变红
    }

    /// B 档对**低采样率源不升采样**：16 kHz 源保持 16 kHz。
    ///
    /// 这是「不升采样」纪律在预设层的体现。升采样不会凭空造出信息，
    /// 只会让文件变大，并给下游一个「这文件带宽到 12 kHz」的假印象。
    func testBTierDoesNotUpsampleLowRateSource() throws {
        let source = try XCTUnwrap(WAVWriter.readHeader(
            at: makeWAV("s16.wav", seconds: 1, rate: 16000, channels: 2,
                        format: .float32, generator: { _ in 0 })))
        XCTAssertEqual(AudioTranscoder.target(for: .bTier, source: source).sampleRate, 16000)
        // 退化示例：`min` 去掉 → 变成 24000，这条变红
    }

    /// A 档：只改位深，采样率与声道都保留。
    func testPCM16TargetKeepsSourceRateAndChannels() throws {
        let source = try XCTUnwrap(WAVWriter.readHeader(
            at: makeWAV("s2.wav", seconds: 1, rate: 48000, channels: 2,
                        format: .float32, generator: { _ in 0 })))
        let target = AudioTranscoder.target(for: .pcm16, source: source)
        XCTAssertEqual(target.sampleRate, 48000)
        XCTAssertEqual(target.channels, 2)
        XCTAssertEqual(target.format, .pcm16)
    }

    /// 源已经是 24 kHz 单声道时，B 档**不降采样**、只降位深。
    func testBTierKeepsAlreadyMono24kSource() throws {
        let source = try XCTUnwrap(WAVWriter.readHeader(
            at: makeWAV("s3.wav", seconds: 1, rate: 24000, channels: 1,
                        format: .float32, generator: { _ in 0 })))
        let target = AudioTranscoder.target(for: .bTier, source: source)
        XCTAssertEqual(target.sampleRate, 24000)
        XCTAssertEqual(target.channels, 1)
        XCTAssertEqual(target.format, .pcm16)
        // 这就是「收益取决于设备给的源格式」那条文档结论在代码里的落点：
        // AirPods 那种源只省得下位深那一半，所以 UI 上的数必须带前提。
    }

    // MARK: - 两条必须拒绝的路径

    /// 源与目标完全相同 → 拒绝，而不是产出一个逐字节相同的副本。
    ///
    /// 退化示例：去掉这道 guard → 会产出一个「成功」结果，而 manifest 的格式字段
    /// 一个字节都没变，用户以为转过了。
    func testIdenticalFormatIsRejected() throws {
        let src = try makeWAV("same.wav", seconds: 1, rate: 48000, channels: 2,
                              format: .float32, generator: { _ in 0.1 })
        XCTAssertThrowsError(
            try AudioTranscoder.transcode(source: src, destination: url("out.wav"),
                                          preset: .lossless32)
        ) { error in
            guard case MRError.invalidArgument(let why) = error else {
                return XCTFail("期望 invalidArgument，实际 \(error)")
            }
            XCTAssertTrue(why.contains("不会有任何变化"), "实际：\(why)")
        }
    }

    /// 显式给出升采样的目标 → 必须拒绝。
    ///
    /// 这条只有走**显式 Target 入口**才测得到：`Preset` 永远不产出升采样，
    /// 用预设路径试的话这道 guard 不可达，而不可达的分支等于没有分支。
    func testUpsamplingTargetIsRejected() throws {
        let src = try makeWAV("up.wav", seconds: 1, rate: 48000, channels: 2,
                              format: .float32, generator: { _ in 0.1 })
        let reader = try WAVReader(url: src)
        defer { reader.close() }
        XCTAssertThrowsError(
            try AudioTranscoder.transcode(
                reader: reader,
                sourceSampleRate: 48000, sourceChannels: 2,
                sourceFormat: .float32, sourceFrames: reader.frameCount,
                destination: url("up-out.wav"),
                target: AudioTranscoder.Target(sampleRate: 96000, channels: 1, format: .pcm16))
        ) { error in
            guard case MRError.invalidArgument(let why) = error else {
                return XCTFail("期望 invalidArgument，实际 \(error)")
            }
            XCTAssertTrue(why.contains("不支持升采样"), "实际：\(why)")
        }
        // 退化示例：把 `<=` 改成 `<` 或去掉 → 这里会真的产出一个 96 kHz 文件
    }

    /// 失败时目标文件必须被清掉，绝不留半成品。
    func testFailureLeavesNoPartialDestination() throws {
        // 目标目录不存在 → `WAVWriter` 初始化就抛，目标文件压根不该出现
        let src = try makeWAV("f.wav", seconds: 1, rate: 48000, channels: 2,
                              format: .float32, generator: { _ in 0.1 })
        let bad = dir.appendingPathComponent("nope/deep/out.wav")
        XCTAssertThrowsError(
            try AudioTranscoder.transcode(source: src, destination: bad, preset: .bTier))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
    }

    // MARK: - 核心不变量

    /// 转码 48 kHz 立体声 → 24 kHz 单声道 16 位。
    /// 头部、字节数、时长、峰值四件事必须同时成立。
    func testTranscodeProducesTheDeclaredFormat() throws {
        let src = try makeWAV("core.wav", seconds: 3, rate: 48000, channels: 2,
                              format: .float32, generator: stereoLeftOnly)
        let dst = url("core-out.wav")
        let r = try AudioTranscoder.transcode(source: src, destination: dst, preset: .bTier)

        let header = try WAVWriter.readHeader(at: dst)
        XCTAssertEqual(header.sampleRate, 24000)
        XCTAssertEqual(header.channels, 1)
        XCTAssertEqual(header.bitsPerSample, 16)
        XCTAssertEqual(header.audioFormatID, 1)
        XCTAssertEqual(header.frameCount, r.targetFrames)
        XCTAssertEqual(header.frameCount, 3 * 24000, "3 秒 24 kHz 应为 72000 帧")

        // 字节数必须精确等于 44 + 帧数 × 声道 × 位深
        let size = try XCTUnwrap(FileManager.default
            .attributesOfItem(atPath: dst.path)[.size] as? Int)
        XCTAssertEqual(size, WAVWriter.headerSize + header.frameCount * 1 * 2)
        // 退化示例：写入格式与 `WAVWriter` 声明不一致 → 字节数立刻对不上

        // 时长必须守住（这是「24k/48k 写反」最直接的表现）
        XCTAssertEqual(r.sourceDuration, 3, accuracy: 0.001)
        XCTAssertEqual(r.targetDuration, 3, accuracy: 0.005)
        XCTAssertLessThan(abs(r.durationDelta), 0.005, "时长差应亚毫秒级")

        // 内容不能被洗掉
        XCTAssertGreaterThan(r.peakAmplitude, 0.2)
    }

    /// **与实时录制路径逐样本一致**——本模块存在的主要理由。
    ///
    /// 「转码出来的格式 = 开着 B 档实时录出来的格式」本来是个需要验证的命题；
    /// 因为两条路走的是同一段 DSP，它变成了一条可以断言的事实。
    /// 这条断言一旦变红，说明有人给两条路加上了不同的东西
    /// （不同的低通、不同的降混公式、不同的位深舍入），
    /// 而那类差异**只会在真机上暴露**。
    func testTranscodeIsSampleIdenticalToTheRealtimePipeline() throws {
        let frames = 48000 * 2
        var source: [Float] = []
        source.reserveCapacity(frames * 2)
        for f in 0..<frames {
            source.append(0.5 * Float(sin(2 * Double.pi * 1000 * Double(f) / 48000)))
            source.append(0)
        }
        let src = url("same-pipeline.wav")
        let w = try WAVWriter(url: src, sampleRate: 48000, channels: 2, format: .float32)
        try w.append(source)
        try w.finalize()
        w.close()

        let dst = url("same-pipeline-out.wav")
        let r = try AudioTranscoder.transcode(source: src, destination: dst, preset: .bTier)

        // 手工跑一遍「实时那条链」：TrackSamplePipeline → 同一段变换
        var pipeline = TrackSamplePipeline(
            sourceSampleRate: 48000, sourceChannels: 2,
            writeFormat: TrackWriteFormat(sampleRate: 24000, channels: 1))
        var expected = pipeline.process(source)
        expected += pipeline.flush()

        // 从 16 位文件读回来（会经过量化），再逐点比
        let reader = try WAVReader(url: dst)
        defer { reader.close() }
        let actual = try reader.readFrames(startingAt: 0, count: r.targetFrames)

        XCTAssertEqual(actual.count, expected.count,
                       "样本数不同：\(actual.count) vs \(expected.count)")
        let n = min(actual.count, expected.count)
        var worst: Float = 0
        for i in 0..<n {
            let diff = abs(WAVWriter.effectiveAfterQuantisation(expected[i]) - actual[i])
            if diff > worst { worst = diff }
        }
        // 差值上界就是 16 位量化误差（1/32768），不是「差不多就行」
        XCTAssertLessThanOrEqual(worst, 1.0 / 32767,
                                 "最大逐样本差 \(worst) 超过量化误差界")
    }

    /// 分块大小不得改变输出（流式状态必须跨块保存）。
    func testChunkSizeDoesNotChangeTheOutput() throws {
        let src = try makeWAV("chunk.wav", seconds: 2, rate: 48000, channels: 2,
                              format: .float32, generator: stereoLeftOnly)

        var reference: [Float] = []
        for chunk in [1, 7, 512, 48000, 1_000_000] {
            let dst = url("chunk-\(chunk).wav")
            let r = try AudioTranscoder.transcode(source: src, destination: dst,
                                                  preset: .bTier, chunkFrames: chunk)
            let reader = try WAVReader(url: dst)
            let got = try reader.readFrames(startingAt: 0, count: r.targetFrames)
            reader.close()
            if chunk == 1 {
                reference = got
                XCTAssertFalse(reference.isEmpty)
            } else {
                XCTAssertEqual(got.count, reference.count, "chunkFrames=\(chunk) 样本数不同")
                let n = min(got.count, reference.count)
                var worst: Float = 0
                for i in 0..<n {
                    let diff = abs(got[i] - reference[i])
                    if diff > worst { worst = diff }
                }
                XCTAssertEqual(worst, 0, "chunkFrames=\(chunk) 输出与整块不一致，最大差 \(worst)")
            }
        }
        // 退化示例：把 `pending` / `stream` 的跨块状态去掉 → chunk=7 与整块不一致
    }

    /// `.firstChannel` 必须真的绕开反相抵消。
    ///
    /// 用 `bTier` 档而不是 `pcm16`：降混只发生在**降到单声道**的那条路径上，
    /// 而 `pcm16` 刻意保留源声道数——拿它测降混会得到「当然没抵消」的错误结论
    /// （这正是本条第一次写成 `pcm16` 时失败的原因：那条路径压根没有降混这一步）。
    func testFirstChannelStrategyAvoidsCancellation() throws {
        // 反相双声道：每个帧 L=0.4 / R=-0.4，平均必然抵消
        let src = try makeWAV("phase.wav", seconds: 1, rate: 48000, channels: 2,
                              format: .float32) { i in
            i % 2 == 0 ? 0.4 : -0.4
        }
        let avg = try AudioTranscoder.transcode(source: src,
                                                destination: url("avg.wav"),
                                                preset: .bTier,
                                                downmix: .average)
        let first = try AudioTranscoder.transcode(source: src,
                                                  destination: url("first.wav"),
                                                  preset: .bTier,
                                                  downmix: .firstChannel)
        XCTAssertEqual(avg.target.channels, 1, "前提：这条路径必须真的降到单声道")
        XCTAssertLessThan(avg.peakAmplitude, 0.01,
                          "反相内容被平均抵消了，峰值 \(avg.peakAmplitude)")
        XCTAssertGreaterThan(first.peakAmplitude, 0.3, "取第一声道时不该被抵消")
        XCTAssertEqual(first.downmix, .firstChannel)
        // 退化示例：把 `.firstChannel` 也实现成 `.average` → 上面那条变红
    }

    /// 16 位量化会把峰值压到 1.0 之外的值——必须夹住，否则听感是一记爆音。
    func testTranscodeClampsOverRangeSamples() throws {
        // 输入 1.8（超出 [-1, 1]）——这不是正常录音会有的值，
        // 但量化函数必须夹住而不是回绕（回绕 = 爆音）。
        let src = try makeWAV("clip.wav", seconds: 1, rate: 48000, channels: 1,
                              format: .float32) { _ in 1.8 }
        let dst = url("clip-out.wav")
        let r = try AudioTranscoder.transcode(source: src, destination: dst, preset: .pcm16)
        XCTAssertLessThanOrEqual(r.peakAmplitude, 1.0)
        let reader = try WAVReader(url: dst)
        defer { reader.close() }
        let got = try reader.readFrames(startingAt: 0, count: 64)
        XCTAssertFalse(got.contains { $0 < -0.99 }, "出现了负向爆音（回绕）")
    }

    // MARK: - 预估必须与实转对得上

    /// `estimate` 不读音频内容，给出的帧数与字节数必须与真实转码一致。
    ///
    /// 批量迁移先要能便宜地把账算清楚（3.28 GiB 逐场真转一遍再发现不划算就太晚了），
    /// 所以「预估准不准」是这条功能的信任基础：差一点点都会让用户对不上账。
    func testEstimateMatchesTheRealTranscode() throws {
        let src = try makeWAV("est.wav", seconds: 3, rate: 48000, channels: 2,
                              format: .float32, generator: stereoLeftOnly)
        let header = try XCTUnwrap(WAVWriter.readHeader(at: src))
        let e = AudioTranscoder.estimate(source: header, preset: .bTier, sourceFormat: .float32)

        let dst = url("est-out.wav")
        let r = try AudioTranscoder.transcode(source: src, destination: dst, preset: .bTier)

        // 帧数只差 FIR 尾部补的零（129 抽头 → 64 源样本 → 32 输出样本）
        XCTAssertEqual(r.targetFrames, e.targetFrames, accuracy: 64,
                       "预估与实转的帧数差应只在 FIR 尾部窗口内")
        XCTAssertEqual(r.sourceBytes, e.sourceBytes)
        // 预估刻意**不算**尾部那几个样本，所以它报的目标字节数只会略小
        XCTAssertLessThanOrEqual(e.targetBytes, r.targetBytes)
        XCTAssertEqual(r.sourceFrames, e.sourceFrames)
    }

    /// 48 kHz 立体声转 B 档，体积比必须是 1/8（**不是** 1/6）。
    ///
    /// 1/6 是**双轨合计**的口径（mic 轨本来就单声道，只省位深那一半）。
    /// 单看立体声轨：÷2 位深 × ÷2 声道 × ÷2 采样率 = 1/8。
    /// 这条断言是为了钉住「别把双轨口径套到单轨上」——本项目已经因为
    /// 「把 system 单轨的压缩比乘 1.5 当双轨值」把整张表算低过 25%。
    func testStereoTrackShrinksToOneEighth() throws {
        let src = try makeWAV("eighth.wav", seconds: 1, rate: 48000, channels: 2,
                              format: .float32, generator: stereoLeftOnly)
        let dst = url("eighth-out.wav")
        let r = try AudioTranscoder.transcode(source: src, destination: dst, preset: .bTier)
        XCTAssertEqual(r.sizeFactor, 0.125, accuracy: 0.002)
    }

    /// 已转成 16 位 24 kHz 单声道的文件，再用 B 档转应当被拒绝（无事可做）。
    func testAlreadyConvertedMono24kIsRejected() throws {
        let src = try makeWAV("done.wav", seconds: 1, rate: 24000, channels: 1,
                              format: .pcm16, generator: { _ in 0.3 })
        XCTAssertThrowsError(
            try AudioTranscoder.transcode(source: src, destination: url("done-out.wav"),
                                          preset: .bTier)
        ) { error in
            guard case MRError.invalidArgument(let why) = error else {
                return XCTFail("期望 invalidArgument，实际 \(error)")
            }
            XCTAssertTrue(why.contains("不会有任何变化"), "实际：\(why)")
        }
    }

    /// 转码结果必须能被再读回来（写出的文件是合法 WAV，不是「看起来像」）。
    func testOutputIsReadableAndRoundTrips() throws {
        let src = try makeWAV("rt.wav", seconds: 2, rate: 48000, channels: 2,
                              format: .float32, generator: stereoLeftOnly)
        let dst = url("rt-out.wav")
        _ = try AudioTranscoder.transcode(source: src, destination: dst, preset: .bTier)
        let reader = try WAVReader(url: dst)
        defer { reader.close() }
        XCTAssertEqual(reader.format, .pcm16)
        XCTAssertEqual(reader.channels, 1)
        XCTAssertEqual(reader.sampleRate, 24000)
        XCTAssertTrue(reader.info.isConsistent, "头部声明的长度与文件实际长度不一致")
        let all = try reader.readFrames(startingAt: 0, count: reader.frameCount)
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.contains { $0 != 0 }, "全零——转码把内容洗掉了")
    }
}
