import XCTest
import CoreAudio
@testable import MRCapture
import MRCore

/// `TrackRecorder` 的**存储格式**——用户唯一能感知的那部分音轨参数。
///
/// 为什么值得测：位深是「16 位录音」这个开关的最后一站。前面几层（偏好 → 配置 →
/// 协调器）都只是在传递一个枚举值，**真正决定文件大小的是这里写盘用的格式**。
/// 一旦这一段断掉，症状是「勾了开关、文件大小纹丝不动」——界面上没有任何异常，
/// 只有磁盘占用不说话。
///
/// 不需要任何权限：构造 `TrackRecorder` 只创建文件和 WAV 头，不碰 Core Audio。
/// （`start()` 才需要设备，本文件一条都不调。）
final class TrackRecorderFormatTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-track-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeRecorder(
        name: String, format: WAVSampleFormat, channels: Int = 1
    ) throws -> (TrackRecorder, URL) {
        let url = dir.appendingPathComponent(name)
        let recorder = try TrackRecorder(
            id: "mic", role: .microphone, deviceID: 0, deviceName: nil,
            fileURL: url, sourceSampleRate: 48000, sourceChannels: channels,
            sourceIsInterleaved: true, format: format)
        return (recorder, url)
    }

    // MARK: - 参数真的落到了文件

    /// 构造时给的格式必须体现在**文件头**里，不只是存在属性上。
    ///
    /// 只断言属性等于 `.pcm16` 是不够的：真正决定体积的是 `WAVWriter` 用的格式。
    /// 属性与写入格式分了家的实现（比如构造器忘了把参数转手给 writer）
    /// 在那种断言下完全看不出来。
    func testPCM16LandsInTheFileHeader() throws {
        let (recorder, url) = try makeRecorder(name: "pcm16.wav", format: .pcm16)

        XCTAssertEqual(recorder.sampleFormat, .pcm16, "构造器参数应当被记下来")

        let header = try WAVWriter.readHeader(at: url)
        XCTAssertEqual(header.audioFormatID, 1, "pcm16 的格式码是 1（整数 PCM）")
        XCTAssertEqual(header.bitsPerSample, 16)
    }

    /// 不传格式时仍然是 32 位浮点。
    ///
    /// 这是「默认不能悄悄降质量」那条规定在**实现层**的落点：偏好层的默认是关，
    /// 但万一有什么路径绕过偏好直接建音轨，格式必须仍是无损的那个。
    func testUnspecifiedFormatStaysLossless() throws {
        let url = dir.appendingPathComponent("default.wav")
        let recorder = try TrackRecorder(
            id: "mic", role: .microphone, deviceID: 0, deviceName: nil,
            fileURL: url, sourceSampleRate: 48000, sourceChannels: 1, sourceIsInterleaved: true)

        XCTAssertEqual(recorder.sampleFormat, .float32)
        let header = try WAVWriter.readHeader(at: url)
        XCTAssertEqual(header.audioFormatID, 3, "float32 的格式码是 3（IEEE 浮点）")
        XCTAssertEqual(header.bitsPerSample, 32)
    }

    /// 立体声轨（系统音频那条）同样遵守格式设置。
    ///
    /// 单独测是因为两条轨走的是**两次**构造调用，各传一次格式。只测单声道那条的话，
    /// 「系统轨漏传格式」这种错会被漏掉——而系统轨恰恰是体积大的那一条
    /// （1318 MiB/小时 vs 660 MiB/小时）。
    func testStereoSystemTrackAlsoHonoursTheFormat() throws {
        let url = dir.appendingPathComponent("system.wav")
        let recorder = try TrackRecorder(
            id: "system", role: .systemAudio, deviceID: 0, deviceName: "系统音频输出",
            fileURL: url, sourceSampleRate: 48000, sourceChannels: 2,
            sourceIsInterleaved: true, format: .pcm16)

        let header = try WAVWriter.readHeader(at: url)
        XCTAssertEqual(header.channels, 2)
        XCTAssertEqual(header.bitsPerSample, 16)
        XCTAssertEqual(header.bytesPerFrame, 4, "2 声道 × 2 字节 = 4 字节/帧")
        XCTAssertEqual(recorder.sampleFormat, .pcm16)
    }

    // MARK: - 触顶告警文案要按当前格式现算

    /// 4 GiB 触顶告警里的「上限时长」必须按当前位深/声道现算。
    ///
    /// 这段文案是用户在最需要判断「还要不要再分段」的时刻唯一能看到的东西。
    /// 原先把「立体声约 3.1 小时、单声道约 6.2 小时」写死——那是 32 位浮点的数；
    /// 开了 16 位实际是 6.2 / 12.4 小时，等于在那一刻告诉用户他只剩一半余量。
    ///
    /// 数值一律用 `WAVWriter.maxDurationHours(...)` 现算传进去，**不手抄**：
    /// 手抄的数会和生产代码一起错，比不测还坏。
    ///
    /// 退化示例：把文案里的格式相关部分换回写死的
    /// 「（48kHz 立体声约 3.1 小时、单声道约 6.2 小时）」，
    /// 立体声 16 位那条会同时命中「含 6.2」与「不含 3.1」两条断言而变红。
    func testSizeLimitWarningReportsPerFormatDuration() {
        func warning(channels: Int, format: WAVSampleFormat) -> String {
            TrackRecorder.sizeLimitWarning(
                id: "mic", sampleRate: 48000, channels: channels, format: format,
                maxDurationHours: WAVWriter.maxDurationHours(
                    sampleRate: 48000, channels: channels, format: format))
        }

        let stereoP16 = warning(channels: 2, format: .pcm16)
        XCTAssertTrue(stereoP16.contains("6.2"), "立体声 16 位上限约 6.2 小时：\(stereoP16)")
        XCTAssertFalse(stereoP16.contains("3.1"), "不能再说 float32 的 3.1 小时：\(stereoP16)")
        XCTAssertTrue(stereoP16.contains("2 声道"), "应带上本轨的声道数：\(stereoP16)")
        XCTAssertTrue(stereoP16.contains("16 位整数 PCM"), "应带上可读的格式名：\(stereoP16)")

        XCTAssertTrue(warning(channels: 1, format: .float32).contains("6.2"),
                      "单声道 float32 上限约 6.2 小时")

        let monoP16 = warning(channels: 1, format: .pcm16)
        XCTAssertTrue(monoP16.contains("12.4"), "单声道 16 位上限约 12.4 小时：\(monoP16)")
        XCTAssertFalse(monoP16.contains("6.2"), "不能再说 float32 的 6.2 小时：\(monoP16)")
    }

    // MARK: - 自检峰值要按写入后实际生效的采样算

    /// `effectiveSample` 必须在 pcm16 下套用量化、在 float32 下原样返回。
    ///
    /// 16 位会把 |v| < 0.5/32767 ≈ 1.53e-5 的采样量化成 0，而
    /// `RecordingSanity.isAllZero` 判的是 `frames > 0 && peakAmplitude == 0`：
    /// 峰值若按量化前的 float 取，一整段被量化成静音的录音会被判成「有内容」。
    ///
    /// 退化示例：把 `effectiveSample` 的 pcm16 分支改成直接返回 `v`，
    /// 第一条断言变红；改成两个分支都量化，第二条断言变红。
    func testEffectiveSampleAppliesQuantisationForPCM16Only() {
        XCTAssertEqual(TrackRecorder.effectiveSample(1e-5, format: .pcm16), 0,
                       "16 位下这个量级会被量化成 0，自检必须看到 0")
        XCTAssertEqual(TrackRecorder.effectiveSample(1e-5, format: .float32), 1e-5,
                       "32 位浮点原样保留，不能也被抹成 0")
        XCTAssertNotEqual(TrackRecorder.effectiveSample(0.5, format: .pcm16), 0,
                          "0.5 这种正常幅度必须还有值")
    }

    // MARK: - 配置里「没表态」的格式落到哪一档

    /// `Configuration.sampleFormat == nil`（含默认构造）必须落到 32 位浮点无损。
    ///
    /// 这是本模块**唯一一条没法变成可执行断言的路径**：`start()` 要真的开设备、跑实时回调，
    /// 而默认套件里没有任何用例调它（GUI 走假引擎、CLI 只测纯函数「参数→配置」、
    /// 真机用例默认跳过）。把默认值从 `start()` 里的 `??` 挪到类型上，就是为了让
    /// 「nil 到底落到哪个格式」这件事能被断言——它是「默认不能悄悄降质量」的最后一道。
    ///
    /// 退化示例：把 `resolvedSampleFormat` 改成恒 `.pcm16`，本用例变红。
    func testUnspecifiedConfigurationResolvesToLossless() {
        XCTAssertEqual(DualTrackRecorder.Configuration().resolvedSampleFormat, .float32,
                       "默认构造（没表态）必须落到无损的 32 位浮点")

        var config = DualTrackRecorder.Configuration()
        config.maxDuration = 600
        XCTAssertEqual(config.resolvedSampleFormat, .float32,
                       "只改了别的字段、格式仍留空时，也必须落到无损")
    }

    /// 显式表态的格式必须原样返回，不能被默认值盖掉。
    ///
    /// 与上一条互为对照：只有两条一起在，才能区分「无条件退回 float32」
    /// 和「nil 才退回 float32」两种实现。少了这条，一个恒返回 `.float32`
    /// 的实现能过掉上面那条。
    ///
    /// 退化示例：把 `resolvedSampleFormat` 改成恒 `.float32`，本用例变红。
    func testExplicitConfigurationKeepsItsFormat() {
        XCTAssertEqual(
            DualTrackRecorder.Configuration(sampleFormat: .pcm16).resolvedSampleFormat, .pcm16,
            "显式要 16 位的配置不能被默认值改回无损")
        XCTAssertEqual(
            DualTrackRecorder.Configuration(sampleFormat: .float32).resolvedSampleFormat, .float32,
            "显式要无损的配置本来就和默认一致，另加一条是为了挡住「恒 pcm16」的实现")
    }

    // MARK: - 采样率与声道：源格式 vs 写入格式
    //
    // 位深只写在 WAV 头里；采样率与声道同样如此，而且它们还多一层陷阱——
    // `TrackManifest.duration = framesWritten / sampleRate`，manifest 若记了源采样率
    // 而文件其实是降采样后的，界面时长会正好差一倍，且没有任何地方会报错。
    // 所以「源」与「写入」必须能分别核。

    /// 构造时给的写入格式必须体现在**文件头**里。
    ///
    /// 退化示例：把 `WAVWriter(... sampleRate: sourceSampleRate, channels: sourceChannels ...)`
    /// 里的参数改回源格式，本用例变红——而症状是「勾了省空间，文件大小纹丝不动」。
    func testWriteFormatLandsInTheFileHeader() throws {
        let url = dir.appendingPathComponent("mono24k.wav")
        let recorder = try TrackRecorder(
            id: "system", role: .systemAudio, deviceID: 0, deviceName: "系统音频输出",
            fileURL: url,
            sourceSampleRate: 48000, sourceChannels: 2, sourceIsInterleaved: true,
            writeSampleRate: 24000, writeChannels: 1, format: .pcm16)

        let header = try WAVWriter.readHeader(at: url)
        XCTAssertEqual(header.sampleRate, 24000, "文件头必须是写入采样率")
        XCTAssertEqual(header.channels, 1, "文件头必须是写入声道数")
        XCTAssertEqual(header.bitsPerSample, 16)
        XCTAssertEqual(header.bytesPerFrame, 2, "单声道 × 16 位 = 2 字节/帧")

        // 属性与文件头必须**同时**对得上：只核一个的话，
        // 「属性记住了、没转手给 writer」这种退化会漏过去。
        XCTAssertEqual(recorder.writeFormat.sampleRate, 24000)
        XCTAssertEqual(recorder.writeFormat.channels, 1)
    }

    /// 不传写入格式时，默认**等于源格式**——也就是本轮之前的行为一字不变。
    ///
    /// 退化示例：把 `writeSampleRate ?? sourceSampleRate` 改成写死 24000，
    /// 本文件里前面那几条（以及 `WAVFileTests` 的往返断言）会集体变红。
    func testWriteFormatDefaultsToSourceFormat() throws {
        let (recorder, url) = try makeRecorder(name: "default-write.wav", format: .float32, channels: 2)

        XCTAssertEqual(recorder.writeFormat.sampleRate, 48000)
        XCTAssertEqual(recorder.writeFormat.channels, 2)
        let header = try WAVWriter.readHeader(at: url)
        XCTAssertEqual(header.sampleRate, 48000)
        XCTAssertEqual(header.channels, 2)
    }

    /// 源格式与写入格式是**两个独立的字段**，各自如实反映自己那一侧。
    func testSourceAndWriteFormatsAreBothReported() throws {
        let url = dir.appendingPathComponent("split.wav")
        let recorder = try TrackRecorder(
            id: "system", role: .systemAudio, deviceID: 0, deviceName: nil,
            fileURL: url,
            sourceSampleRate: 48000, sourceChannels: 2, sourceIsInterleaved: true,
            writeSampleRate: 24000, writeChannels: 1)

        XCTAssertEqual(recorder.sourceSampleRate, 48000, "源采样率必须保留给统计用")
        XCTAssertEqual(recorder.sourceChannels, 2)
        XCTAssertEqual(recorder.writeFormat.sampleRate, 24000, "写入格式决定文件与 manifest")
        XCTAssertEqual(recorder.writeFormat.channels, 1)
    }

    /// `TrackStats` 留在**源格式**：漂移比较的是「采集到的帧数 vs 时钟」。
    ///
    /// 换成写入格式的话，`sampleDerivedDuration = frames / 24000` 会变成真实时长的两倍，
    /// 于是漂移报告里凭空多出一小时的偏差——而那是本文件之外的地方在消费的字段。
    func testStatsStayInSourceFormat() throws {
        let url = dir.appendingPathComponent("stats.wav")
        let recorder = try TrackRecorder(
            id: "mic", role: .microphone, deviceID: 0, deviceName: nil,
            fileURL: url,
            sourceSampleRate: 48000, sourceChannels: 1, sourceIsInterleaved: true,
            writeSampleRate: 24000, writeChannels: 1)

        XCTAssertEqual(recorder.stats.sampleRate, 48000)
        XCTAssertEqual(recorder.stats.channels, 1)
    }

    /// 触顶告警的**上限时长**必须按写入格式算。
    ///
    /// 告警是用户判断「还要不要分段」的唯一依据。文件是 24 kHz 单声道时，
    /// 用源格式（48 kHz 立体声）算出来的余量会比真实值少得多——
    /// 「数字看着对、含义全错」的又一例。
    ///
    /// 这条验的是「两个数确实不同、且写入格式那个才是对的」，
    /// 真实调用点是 `handle()` 里读 `writeFormat`（要设备才能跑，见真机用例）。
    func testSizeLimitDurationUsesWriteFormat() {
        let viaSource = WAVWriter.maxDurationHours(sampleRate: 48000, channels: 2, format: .pcm16)
        let viaWrite = WAVWriter.maxDurationHours(sampleRate: 24000, channels: 1, format: .pcm16)

        XCTAssertGreaterThan(viaWrite, viaSource)
        // 位深相同（都是 pcm16）时，只剩采样率 ÷2 与声道数 ÷2，合起来 4 倍。
        // 再叠加位深减半才是「系统音频轨 1318 → 165 MiB/小时」那个 8 倍。
        XCTAssertEqual(viaWrite / viaSource, 4, accuracy: 0.01,
                       "48k 立体声 → 24k 单声道（同为 16 位）单文件能录的时长长 4 倍")

        let warning = TrackRecorder.sizeLimitWarning(
            id: "system", sampleRate: 24000, channels: 1,
            format: .pcm16, maxDurationHours: viaWrite)
        XCTAssertTrue(warning.contains("24000 Hz"), "要带上写入采样率：\(warning)")
        XCTAssertTrue(warning.contains("1 声道"), "要带上写入声道数：\(warning)")
    }

    /// 不支持的写入格式组合必须**抛错**，不能静默按单声道写出去。
    ///
    /// 本轮管线只实现「不变换」与「合并到单声道 + 重采样」两种。要立体声又要改采样率
    /// 落在两种之外——静默处理的话，用户会拿到「文件头写着 2 声道、实际只有一个声道内容」
    /// 的文件，到回听时才发现少了一半。
    func testUnsupportedWriteFormatThrows() {
        let url = dir.appendingPathComponent("bad.wav")
        XCTAssertThrowsError(
            try TrackRecorder(
                id: "system", role: .systemAudio, deviceID: 0, deviceName: nil,
                fileURL: url,
                sourceSampleRate: 48000, sourceChannels: 2, sourceIsInterleaved: true,
                writeSampleRate: 24000, writeChannels: 2)
        ) { error in
            guard let mr = error as? MRError, case .coreAudio = mr else {
                return XCTFail("应当抛 coreAudio 类的错误，实际 \(error)")
            }
        }

        // 对照组：同一个写入格式、但声道数与源一致（只是同源），不该抛
        XCTAssertNoThrow(
            try TrackRecorder(
                id: "system", role: .systemAudio, deviceID: 0, deviceName: nil,
                fileURL: dir.appendingPathComponent("ok.wav"),
                sourceSampleRate: 24000, sourceChannels: 2, sourceIsInterleaved: true,
                writeSampleRate: 24000, writeChannels: 2))
    }

    // MARK: - 「单声道 24 kHz」配置里的默认落点

    /// `Configuration.mono24k == nil`（含默认构造）必须落到 **false**。
    ///
    /// 与 `resolvedSampleFormat` 同一条纪律：默认不能悄悄降质量。
    /// 这一项比位深更硬——它同时改掉采样率与声道数。
    ///
    /// 退化示例：把 `resolvedMono24k` 改成 `mono24k ?? true`，本用例变红。
    func testUnspecifiedConfigurationDoesNotDownsample() {
        XCTAssertFalse(DualTrackRecorder.Configuration().resolvedMono24k)
        var config = DualTrackRecorder.Configuration()
        config.maxDuration = 600
        XCTAssertFalse(config.resolvedMono24k, "只改了别的字段、开关仍留空时也必须保持全带宽")
    }

    /// 显式表态的开关必须原样返回，不能被默认值盖掉。
    ///
    /// 与上一条互为对照：只有两条一起在，才能区分「无条件退回 false」
    /// 和「nil 才退回 false」。
    func testExplicitMono24kIsHonoured() {
        XCTAssertTrue(DualTrackRecorder.Configuration(mono24k: true).resolvedMono24k)
        XCTAssertFalse(DualTrackRecorder.Configuration(mono24k: false).resolvedMono24k)
    }

    /// 位深与「单声道 24 kHz」**相互独立**，四个组合都能表达。
    ///
    /// 两个维度各有各的收益，捆在一起就没法「只想省一半」。
    func testFormatAndBandwidthSwitchesAreIndependent() {
        XCTAssertEqual(
            DualTrackRecorder.Configuration(sampleFormat: .pcm16, mono24k: true).resolvedSampleFormat,
            .pcm16)
        XCTAssertTrue(
            DualTrackRecorder.Configuration(sampleFormat: .pcm16, mono24k: true).resolvedMono24k)

        XCTAssertEqual(
            DualTrackRecorder.Configuration(sampleFormat: .float32, mono24k: true).resolvedSampleFormat,
            .float32)
        XCTAssertTrue(
            DualTrackRecorder.Configuration(sampleFormat: .float32, mono24k: true).resolvedMono24k)

        XCTAssertEqual(
            DualTrackRecorder.Configuration(sampleFormat: .pcm16, mono24k: false).resolvedSampleFormat,
            .pcm16)
        XCTAssertFalse(
            DualTrackRecorder.Configuration(sampleFormat: .pcm16, mono24k: false).resolvedMono24k)
    }

    /// `DualTrackRecorder.writeFormat(for:mono24k:)` 与 `TrackWriteFormat.resolve` 同源。
    ///
    /// 这条挡的是「协调器自己又写了一套格式公式」——那样两个公式一定会漂，
    /// 而症状是「manifest 记的格式与实际文件不一致」。
    func testCoordinatorUsesTheSameResolveFunction() throws {
        for channels in [1, 2] {
            var asbd = AudioStreamBasicDescription()
            asbd.mSampleRate = 48000
            asbd.mChannelsPerFrame = UInt32(channels)

            let viaCoordinator = DualTrackRecorder.writeFormat(for: asbd, mono24k: true)
            let viaCore = TrackWriteFormat.resolve(
                sourceSampleRate: 48000, sourceChannels: channels, mono24k: true)
            XCTAssertEqual(viaCoordinator, viaCore)

            let off = DualTrackRecorder.writeFormat(for: asbd, mono24k: false)
            XCTAssertEqual(off, TrackWriteFormat(sampleRate: 48000, channels: channels))
        }
    }
}

// MARK: - 降混策略与相位抵消告警

/// 降混策略从配置到管线要**只走一条路**，并且抵消必须被报出来。
///
/// 真正跑录制需要 Core Audio 权限，单测里没有设备——所以这里测两件能测的：
/// 配置的解析（`nil` 落到哪个默认值），以及告警文案本身。
/// 文案抽成静态纯函数正是为此：它是用户发现「这一轨怎么没声音」时唯一的线索。
extension TrackRecorderFormatTests {

    /// `nil` 落到 `firstChannel`——与 `RecorderPreferences.downmixStrategy` 同源。
    ///
    /// 「默认值只有一处」这条纪律的落点。散在各处写 `?? .firstChannel` 等于
    /// 复制了这个决定，将来改必漏一处，而漏掉那处的症状是
    /// 「有的轨按新策略录、有的按旧策略录」——极难从产物看出来。
    func testDownmixDefaultResolvesToFirstChannel() {
        XCTAssertEqual(
            DualTrackRecorder.Configuration().resolvedDownmix, .firstChannel)
        XCTAssertEqual(
            DualTrackRecorder.Configuration(downmix: .average).resolvedDownmix, .average)
        // 没表态（nil）与「明确要求 firstChannel」在结果上不可区分 ——
        // 显式断言这一点，免得将来有人给 resolvedDownmix 加第四种行为。
        XCTAssertEqual(
            DualTrackRecorder.Configuration(downmix: nil).resolvedDownmix,
            DualTrackRecorder.Configuration(downmix: .firstChannel).resolvedDownmix)
    }


    /// 管线确实把抵消记下来了 —— 不是只写了个没人读的字段。
    ///
    /// 退化示例：把 `TrackSamplePipeline.process` 里的
    /// `didCancel = true` 删掉，本用例与下面那条一起红。
    func testPipelineRecordsPhaseCancellation() {
        let frames = 4800
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = 0.3 * Float(sin(2 * Double.pi * 440 * Double(i) / 48000))
            interleaved[i * 2] = v
            interleaved[i * 2 + 1] = -v      // 反相
        }
        var pipeline = TrackSamplePipeline(
            sourceSampleRate: 48000, sourceChannels: 2,
            writeFormat: TrackWriteFormat(sampleRate: 24000, channels: 1),
            downmixStrategy: .average)
        XCTAssertFalse(pipeline.didCancel, "还没处理任何东西，不该已经报抵消")
        _ = pipeline.process(interleaved)
        XCTAssertTrue(pipeline.didCancel, "反相内容经 average 抵消，管线必须记下来")
    }

    /// 正常内容不得触发抵消告警 —— 误报会让人学会无视它。
    func testNormalContentDoesNotRecordPhaseCancellation() {
        let frames = 4800
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = 0.3 * Float(sin(2 * Double.pi * 440 * Double(i) / 48000))
            interleaved[i * 2] = v
            interleaved[i * 2 + 1] = v      // 同相
        }
        var pipeline = TrackSamplePipeline(
            sourceSampleRate: 48000, sourceChannels: 2,
            writeFormat: TrackWriteFormat(sampleRate: 24000, channels: 1),
            downmixStrategy: .average)
        _ = pipeline.process(interleaved)
        XCTAssertFalse(pipeline.didCancel, "同相内容不该报抵消")
    }

    /// **覆盖缺口（如实登记）**：实时告警列表在跑过抵消之后**不含**抵消文案。
    ///
    /// 写不成单测，原因是这条路径无法在无设备环境里触发：
    /// `handle(_:input:inputTime:)` 是私有的、参数是 `UnsafePointer<AudioBufferList>`，
    /// 而喂它就等于真的开设备（`start()` 要 Core Audio 权限）。
    /// 硬要覆盖只能把 `handle` 改成 internal 再手工构造 `AudioBufferList` ——
    /// 那是为了一条断言去改生产代码的可见性，代价大于收益。
    ///
    /// 第一次写这条时我用了「刚构造的 recorder」当夹具，变异 M23（把实时告警加回来）
    /// **打不动它** —— 又一次假绿。判据落在「还没有任何数据」的状态上，
    /// 等于什么都没测。**记在这里，别再写一条自以为测到了的版本。**
    ///
    /// 实际验证靠的是：真机录反相内容 + 显式 `average`（`/tmp/v4`，11:45），
    /// 收尾输出只有一条准确告警。改动后（去重）因本机音频授权在反复并发录制后失效，
    /// **未能重录复验** —— 这条留给下一次能在真机上跑的人补。
    func testDocumentedCoverageGapForRealtimeWarningDeduplication() {
        // 只能确认「构造后未报」，也就是这条用例的真实覆盖范围。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-cancel-gap-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = try! TrackRecorder(
            id: "system", role: .systemAudio,
            deviceID: 0, deviceName: "test",
            fileURL: dir.appendingPathComponent("system.wav"),
            sourceSampleRate: 48000, sourceChannels: 2, sourceIsInterleaved: true,
            writeSampleRate: 24000, writeChannels: 1,
            format: .float32, downmixStrategy: .average)
        XCTAssertFalse(recorder.phaseCancelled)
        XCTAssertFalse(recorder.warnings.contains { $0.contains("抵消") },
                       "构造后不该有抵消告警")
    }

    /// `firstChannel` 下管线**不查**抵消，字段恒为 false。
    ///
    /// 逐样本拷贝不可能抵消，查它只是白花一遍遍历；而更重要的是
    /// 误报会让告警失去意义。
    func testFirstChannelNeverRecordsPhaseCancellation() {
        let frames = 4800
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = 0.3 * Float(sin(2 * Double.pi * 440 * Double(i) / 48000))
            interleaved[i * 2] = v
            interleaved[i * 2 + 1] = -v
        }
        var pipeline = TrackSamplePipeline(
            sourceSampleRate: 48000, sourceChannels: 2,
            writeFormat: TrackWriteFormat(sampleRate: 24000, channels: 1),
            downmixStrategy: .firstChannel)
        _ = pipeline.process(interleaved)
        XCTAssertFalse(pipeline.didCancel)
    }
}
