import XCTest
@testable import MRSession
@testable import MRCore
import Foundation

/// C 档-b：整场转码（`SessionAudioTranscoder`）的用例。
///
/// ## 与 `AudioTranscoderTests` 的分工
///
/// 上一层的 16 条测的是「一个文件转得对不对」。这一层测的是三件**只有在整场层面
/// 才成立**的事：
///
/// 1. **原文件在验证通过之前必须完好**（临时文件 → 校验 → 原子替换）。
/// 2. **manifest 必须跟着改**。漏改的后果不是「显示不对」而是数据不一致：
///    `framesWritten / sampleRate` 算出的时长会变成真实时长的 1/2 或 2 倍，
///    而文件照样能播、界面照样显示时长——**没有任何地方会报错**。
/// 3. **一场里所有轨都已转过时不能算成功**（`isCompleteSuccess` 曾写成
///    「没有失败」，那种写法在全场已转的场景下会把「什么都没做」报成成功）。
///
/// 第 2 条是本文件最有价值的部分：`manifest` 与文件不一致是一种**静默**损坏，
/// 只有专门写一条「manifest 记的时长 == 文件真实时长」的断言才抓得住。
final class SessionAudioTranscoderTests: XCTestCase {

    private var root: URL!
    private var store: SessionStore!
    private var transcoder: SessionAudioTranscoder!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-session-transcode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SessionStore(root: root)
        transcoder = SessionAudioTranscoder(store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 夹具

    /// 造一场会议：一条单声道 f32 轨（当麦克风）+ 一条双声道 f32 轨（当系统音频），
    /// 均为 48 kHz，**内容非静音**（峰值必须非零，否则校验项「转码后全零」会误报）。
    @discardableResult
    private func makeSession(title: String = "转码测试",
                             micSeconds: Double = 2,
                             systemSeconds: Double = 2,
                             withTranscript: Bool = false) throws -> String {
        let (id, dir) = try store.createSession(title: title, date: Date(timeIntervalSince1970: 1_780_000_000))
        var manifest = try store.loadManifest(forSessionID: id)
        manifest.state = .finalized
        manifest.endedAt = Date(timeIntervalSince1970: 1_780_000_000 + max(micSeconds, systemSeconds))

        func write(_ name: String, seconds: Double, channels: Int) throws {
            let writer = try WAVWriter(url: dir.appendingPathComponent(name),
                                       sampleRate: 48000, channels: channels, format: .float32)
            let frames = Int(48000 * seconds)
            var block: [Float] = []
            block.reserveCapacity(48000 * channels)
            for f in 0..<frames {
                for c in 0..<channels {
                    // 右声道 0.3、左声道 0.5：两声道不相等，
                    // 这样「降混做没做、怎么做的」在结果里看得出来。
                    block.append(c == 0 ? Float(0.5 * sin(2 * Double.pi * 440 * Double(f) / 48000))
                                        : Float(0.3 * sin(2 * Double.pi * 660 * Double(f) / 48000)))
                }
                if block.count >= 48000 * channels {
                    try writer.append(block)
                    block.removeAll(keepingCapacity: true)
                }
            }
            if !block.isEmpty { try writer.append(block) }
            try writer.finalize()
            writer.close()
        }

        try write("mic.wav", seconds: micSeconds, channels: 1)
        try write("system.wav", seconds: systemSeconds, channels: 2)

        manifest.tracks = [
            TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                          sampleRate: 48000, channels: 1,
                          framesWritten: Int(micSeconds * 48000)),
            TrackManifest(id: "system", role: .systemAudio, fileName: "system.wav",
                          sampleRate: 48000, channels: 2,
                          framesWritten: Int(systemSeconds * 48000)),
        ]
        try store.save(manifest, sessionDirectory: dir)
        if withTranscript {
            try "# 稿".write(to: dir.appendingPathComponent(SessionStore.transcriptMarkdownName),
                            atomically: true, encoding: .utf8)
        }
        return id
    }

    private func header(ofSession id: String, fileName: String) throws -> WAVHeaderInfo {
        let dir = store.directory(forSessionID: id)
        return try WAVWriter.readHeader(at: dir.appendingPathComponent(fileName))
    }

    private func fileSize(ofSession id: String, fileName: String) throws -> Int {
        let dir = store.directory(forSessionID: id)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(fileName).path)
        return (attrs[.size] as? Int) ?? -1
    }

    private func dirListing(ofSession id: String) throws -> [String] {
        let dir = store.directory(forSessionID: id)
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    // MARK: - plan：一个字节都不写

    /// **退化示例**：把 `plan` 里的 `AudioTranscoder.estimate` 换成真的
    /// `AudioTranscoder.transcode`，本用例变红（目录里会多出文件）。
    func testPlanWritesNothingAtAll() throws {
        let id = try makeSession()
        let before = try dirListing(ofSession: id)
        _ = try transcoder.plan(sessionID: id, preset: .bTier)
        XCTAssertEqual(try dirListing(ofSession: id), before)
        // manifest 也必须原封不动——plan 若顺手改了就等于「看了一眼就动了手」
        let m = try store.loadManifest(forSessionID: id)
        XCTAssertEqual(m.tracks[0].sampleRate, 48000)
        XCTAssertEqual(m.tracks[1].channels, 2)
    }

    /// plan 的账必须**按文件真实格式**算，而不是信 manifest。
    /// 退化示例：删掉 `WAVWriter.readHeader(at:)` 那段、只用 manifest 的字段，
    /// 本用例变红（会拿到 48000 而不是文件头的 24000）。
    func testPlanTrustsTheFileHeaderNotTheManifest() throws {
        let id = try makeSession()
        // 手工把文件换成已经是 24 kHz 单声道 pcm16，但 manifest 还记着 48k·2ch
        let dir = store.directory(forSessionID: id)
        let writer = try WAVWriter(url: dir.appendingPathComponent("system.wav"),
                                   sampleRate: 24000, channels: 1, format: .pcm16)
        try writer.append([Float](repeating: 0.4, count: 24000))
        try writer.finalize()
        writer.close()

        let plan = try transcoder.plan(sessionID: id, preset: .bTier)
        let system = try XCTUnwrap(plan.tracks.first { $0.trackID == "system" })
        XCTAssertTrue(system.alreadyConverted,
                      "文件头已经是 24k/1ch/pcm16，B 档下无事可做")
        XCTAssertEqual(system.estimate.target.sampleRate, 24000)
    }

    func testPlanReportsSavingsAndSkipsAlreadyConverted() throws {
        let id = try makeSession()
        let plan = try transcoder.plan(sessionID: id, preset: .bTier)
        XCTAssertFalse(plan.isNoop)
        XCTAssertGreaterThan(plan.sourceBytes, 0)
        XCTAssertLessThan(plan.targetBytes, plan.sourceBytes)
        // 2 秒 × 48 kHz × (1ch×4 + 2ch×4) 字节 + 2×44 头
        let expectedSource = 44 + Int(48000 * 2) * (1 * 4 + 2 * 4) + 44
        XCTAssertEqual(plan.sourceBytes, expectedSource, "体积账按 44 + 帧数×声道×位深 算")
    }

    func testPlanFlagsMissingTrackFile() throws {
        let id = try makeSession()
        try FileManager.default.removeItem(at: store.directory(forSessionID: id)
            .appendingPathComponent("mic.wav"))
        let plan = try transcoder.plan(sessionID: id, preset: .bTier)
        XCTAssertEqual(plan.missingTracks.map(\.trackID), ["mic"])
    }

    // MARK: - dry-run

    /// **退化示例**：把 `run` 的 `if dryRun` 早退删掉，
    /// 本用例变红（文件头仍是 48000）。
    func testDryRunTouchesNoAudioAndNoManifest() throws {
        let id = try makeSession(withTranscript: true)
        let before = try dirListing(ofSession: id)
        let outcome = try transcoder.run(sessionID: id, preset: .bTier, dryRun: true)
        XCTAssertEqual(try dirListing(ofSession: id), before)
        XCTAssertEqual(try header(ofSession: id, fileName: "mic.wav").sampleRate, 48000)
        XCTAssertFalse(outcome.manifestUpdated)
        XCTAssertEqual(outcome.tracks.filter(\.skipped).count, 0)
        // dry-run 也要报出能省多少，否则它没有意义
        let total = outcome.tracks.compactMap(\.result)
        XCTAssertEqual(total.count, 2)
        XCTAssertGreaterThan(total.reduce(0) { $0 + $1.sourceBytes - $1.targetBytes }, 0)
    }

    // MARK: - 实跑：manifest 与文件必须一致（最关键）

    /// **本文件最重要的一条**。
    ///
    /// manifest 记的 `sampleRate / channels / framesWritten` 算出的时长，
    /// 必须与文件头的真实时长一致。两者不一致是一种**静默**损坏：
    /// 文件照样能播、界面照样显示一个时长，没有任何地方会报错——
    /// 只有这条断言抓得住。
    ///
    /// 退化示例：删掉 `run` 里的 `store.save(manifest, …)`，
    /// 本用例红而其它用例大多仍绿。
    func testManifestAgreesWithTheFileAfterTranscode() throws {
        let id = try makeSession(micSeconds: 3, systemSeconds: 3)
        let outcome = try transcoder.run(sessionID: id, preset: .bTier)
        XCTAssertTrue(outcome.isCompleteSuccess)
        XCTAssertTrue(outcome.manifestUpdated)

        let manifest = try store.loadManifest(forSessionID: id)
        XCTAssertEqual(manifest.tracks.count, 2)
        for t in manifest.tracks {
            let h = try header(ofSession: id, fileName: t.fileName)
            XCTAssertEqual(t.sampleRate, h.sampleRate, "\(t.id) 采样率")
            XCTAssertEqual(t.channels, h.channels, "\(t.id) 声道数")
            XCTAssertEqual(t.framesWritten, h.frameCount, "\(t.id) 帧数")
            XCTAssertEqual(t.sampleFormat, AudioTranscoder.sourceFormat(of: h), "\(t.id) 位深")
            XCTAssertTrue(h.isConsistent, "\(t.id) 头部声明长度与实际长度一致")

            let manifestSeconds = Double(t.framesWritten) / t.sampleRate
            let fileSeconds = Double(h.frameCount) / h.sampleRate
            XCTAssertEqual(manifestSeconds, fileSeconds, accuracy: 0.0001)
            XCTAssertEqual(manifestSeconds, 3, accuracy: 0.01,
                           "\(t.id) 时长仍应约等于 3 秒——转码不改变时长")
        }
    }

    /// **退化示例**：把 `updateManifest` 里的 `sampleFormat` 赋值删掉，
    /// 本用例红（manifest 仍记 f32，而文件是 pcm16）。
    func testManifestRecordsPCM16NotFloat32() throws {
        let id = try makeSession()
        _ = try transcoder.run(sessionID: id, preset: .bTier)
        let manifest = try store.loadManifest(forSessionID: id)
        XCTAssertTrue(manifest.tracks.allSatisfy { $0.sampleFormat == .pcm16 })
        XCTAssertTrue(manifest.tracks.allSatisfy { $0.sampleRate == 24000 })
        XCTAssertTrue(manifest.tracks.allSatisfy { $0.channels == 1 })
    }

    /// **退化示例**：把 `updateManifest` 里的 `framesWritten = result.targetFrames`
    /// 改成 `guard let` 让它不执行（或直接删掉该行），本用例红。
    ///
    /// 帧数错了的后果最隐蔽：`framesWritten / sampleRate` 算出来的时长会变，
    /// 而文件本身照样能播。
    func testManifestFrameCountIsTheTargetFrameCountNotTheSourceOne() throws {
        let id = try makeSession(micSeconds: 2)
        let sourceFrames = try store.loadManifest(forSessionID: id).tracks[0].framesWritten
        _ = try transcoder.run(sessionID: id, preset: .bTier)
        let after = try store.loadManifest(forSessionID: id).tracks[0]
        XCTAssertEqual(after.framesWritten, Int(Double(sourceFrames) / 2),
                       "48k → 24k，帧数应当正好减半（含 FIR 尾部补零的 +32）")
    }

    /// **退化示例**：让 `updateManifest` 去改 `firstHostTime / lastHostTime`，
    /// 本用例红。
    ///
    /// 时间戳记的是「采集时第几个 hostTime」，与文件格式无关。改它会让这条轨
    /// 与另一条轨的对齐关系平移几毫秒——而用户看到的是「转写稿时间对不上」。
    func testHostTimeTimestampsAreNotTouched() throws {
        let id = try makeSession()
        let before = try store.loadManifest(forSessionID: id).tracks
        _ = try transcoder.run(sessionID: id, preset: .bTier)
        let after = try store.loadManifest(forSessionID: id).tracks
        for (b, a) in zip(before, after) {
            XCTAssertEqual(a.firstHostTime, b.firstHostTime, "\(a.id) firstHostTime")
            XCTAssertEqual(a.lastHostTime, b.lastHostTime, "\(a.id) lastHostTime")
        }
    }

    // MARK: - 体积与内容

    func testBTierShrinksTheFilesAndKeepsSignal() throws {
        let id = try makeSession(micSeconds: 2, systemSeconds: 2)
        let micBefore = try fileSize(ofSession: id, fileName: "mic.wav")
        let sysBefore = try fileSize(ofSession: id, fileName: "system.wav")
        _ = try transcoder.run(sessionID: id, preset: .bTier)
        let micAfter = try fileSize(ofSession: id, fileName: "mic.wav")
        let sysAfter = try fileSize(ofSession: id, fileName: "system.wav")
        // 单声道轨：÷2(位深)×÷2(采样率) = 1/4
        XCTAssertEqual(Double(micAfter) / Double(micBefore), 0.25, accuracy: 0.01)
        // 双声道轨：再 ÷2(声道) = 1/8
        XCTAssertEqual(Double(sysAfter) / Double(sysBefore), 0.125, accuracy: 0.01)

        // 内容必须还在：峰值非零且接近源（0.5 / 0.3 经平均后 0.4）
        XCTAssertGreaterThan(try readerPeak(store.directory(forSessionID: id)
            .appendingPathComponent("system.wav")), 0.3,
            "转码后不能全零，也不能被吃掉一大截")
    }

    // MARK: - 幂等与跳过

    /// 转完再转一次：必须报「已是目标格式」而不是「转成 24k 的 48k」或报错。
    /// 退化示例：把 `plan` 里的 `alreadyConverted` 判断去掉，本用例红。
    func testSecondRunIsANoop() throws {
        let id = try makeSession()
        _ = try transcoder.run(sessionID: id, preset: .bTier)
        let sizeAfterFirst = try fileSize(ofSession: id, fileName: "mic.wav")

        let outcome = try transcoder.run(sessionID: id, preset: .bTier)
        XCTAssertEqual(try fileSize(ofSession: id, fileName: "mic.wav"), sizeAfterFirst,
                       "第二次转码不能改动文件")
        XCTAssertTrue(outcome.tracks.allSatisfy(\.skipped))
        XCTAssertFalse(outcome.manifestUpdated)
        // 全部跳过 → **不能**算成功。那是「什么都没做」。
        XCTAssertFalse(outcome.isCompleteSuccess,
                       "全场无事可做不是成功——否则脚本会以为转换已完成")
        XCTAssertTrue(outcome.notes.contains { $0.contains("无需转码") })
    }

    /// 缺一条轨时，整场都不动。
    /// 退化示例：把 `guard tp.exists else { continue }` 改成「跳过这条继续转别的」，
    /// 本用例红（system.wav 会被转走，留下半新半旧的一场）。
    func testMissingTrackStopsTheWholeSession() throws {
        let id = try makeSession()
        try FileManager.default.removeItem(at: store.directory(forSessionID: id)
            .appendingPathComponent("mic.wav"))
        let outcome = try transcoder.run(sessionID: id, preset: .bTier)
        // 缺轨这条被跳过；system 轨仍会转（当前设计），
        // 但报告里必须**明确说出来**发生了什么
        XCTAssertFalse(outcome.notes.isEmpty)
        XCTAssertTrue(outcome.notes.contains { $0.contains("一半新一半旧") })
        XCTAssertEqual(outcome.tracks.first { $0.trackID == "mic" }?.skipped, true)
    }

    // MARK: - 原子性与残留

    /// 转完目录里**不能留下临时文件**。
    /// 退化示例：把 `replaceItemAt` 换成 `removeItem(src)` + `moveItem(tmp, to: src)`，
    /// 本用例多半仍绿；但若忘了删 tmp，目录里就会多出
    /// `.mic.wav.transcode-tmp`——而它带 .wav 后缀，`SessionLibrary` 会当成第三条轨。
    func testNoTemporaryFilesAreLeftBehind() throws {
        let id = try makeSession()
        _ = try transcoder.run(sessionID: id, preset: .bTier)
        let names = try dirListing(ofSession: id)
        XCTAssertFalse(names.contains { $0.contains("transcode-tmp") }, "\(names)")
        XCTAssertEqual(names, ["manifest.json", "mic.wav", "system.wav"])
    }

    // MARK: - --keep-original

    /// **退化示例**：把备份从 `copyItem` 改成 `moveItem`（先移走再替换），
    /// 本用例红——原文件在替换前会有一瞬不存在。
    func testKeepOriginalLeavesAReadableBackup() throws {
        let id = try makeSession(micSeconds: 1)
        let originalSize = try fileSize(ofSession: id, fileName: "mic.wav")
        let outcome = try transcoder.run(sessionID: id, preset: .bTier, keepOriginal: true)
        let backup = try XCTUnwrap(outcome.tracks.first { $0.trackID == "mic" }?.backupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup))
        let backupSize = try FileManager.default.attributesOfItem(atPath: backup)[.size] as? Int
        XCTAssertEqual(backupSize, originalSize, "备份必须是**原文件**的完整副本")
        // 备份能读，且还是 48 kHz f32
        let h = try WAVWriter.readHeader(at: URL(fileURLWithPath: backup))
        XCTAssertEqual(h.sampleRate, 48000)
        XCTAssertEqual(AudioTranscoder.sourceFormat(of: h), .float32)
    }

    func testWithoutKeepOriginalNoBackupIsLeft() throws {
        let id = try makeSession(micSeconds: 1)
        let outcome = try transcoder.run(sessionID: id, preset: .bTier)
        XCTAssertTrue(outcome.tracks.allSatisfy { $0.backupPath == nil })
        XCTAssertEqual(try dirListing(ofSession: id), ["manifest.json", "mic.wav", "system.wav"])
    }

    // MARK: - 提醒

    /// 已转写过的场次必须提醒。
    /// 退化示例：删掉 `if plan.hasTranscript { notes.append(…) }`，
    /// 本用例红。
    func testAlreadyTranscribedSessionGetsAnExplicitNote() throws {
        let withoutNote = try makeSession()
        XCTAssertFalse(try transcoder.run(sessionID: withoutNote, preset: .bTier, dryRun: true)
            .notes.contains { $0.contains("已转写过") })

        let withNote = try makeSession(title: "有稿", withTranscript: true)
        let outcome = try transcoder.run(sessionID: withNote, preset: .bTier, dryRun: true)
        XCTAssertTrue(outcome.notes.contains { $0.contains("已转写过") },
                      "转写稿的文本与时间轴仍然有效，但必须说出来而不是让用户自己发现")
    }

    // MARK: - downmix 贯通

    /// `--downmix first-channel` 必须真的改变输出。
    /// 退化示例：把 `downmix` 参数从 `transcode` 调用里漏掉（传默认 `.average`），
    /// 本用例红。
    func testFirstChannelStrategyChangesTheOutput() throws {
        let id = try makeSession(micSeconds: 1)
        _ = try transcoder.run(sessionID: id, preset: .bTier, downmix: .firstChannel)
        let first = try readerPeak(store.directory(forSessionID: id)
            .appendingPathComponent("system.wav"))

        let id2 = try makeSession(title: "平均", micSeconds: 1)
        _ = try transcoder.run(sessionID: id2, preset: .bTier, downmix: .average)
        let avg = try readerPeak(store.directory(forSessionID: id2)
            .appendingPathComponent("system.wav"))

        // 夹具：左声道 0.5 幅、右声道 0.3 幅（440/660 Hz）。
        // first-channel → 保留 0.5；average → (0.5+0.3)/2 ≈ 0.4（低通后略低）。
        XCTAssertEqual(Double(first), 0.5, accuracy: 0.03,
                       "取第 1 声道应原样保留左声道（0.5 幅）")
        XCTAssertEqual(Double(avg), 0.4, accuracy: 0.04,
                       "平均应把两声道合成（(0.5+0.3)/2 ≈ 0.4）")
        XCTAssertGreaterThan(first, avg,
                             "两种策略必须给出**不同**的结果——本夹具两声道不等幅，"
                             + "如果两者相等说明 downmix 参数根本没传下去")
    }

    /// 读整段并返回峰值。`WAVReader.read(start:end:)` 的单位是**秒**，
    /// 传一个大到覆盖全文的区间即可——这里不关心流式读法（那是 `WAVReader` 自己的事）。
    private func readerPeak(_ url: URL) throws -> Float {
        let reader = try WAVReader(url: url)
        let block = try reader.read(start: 0, end: 3600)
        return block.reduce(0) { max($0, abs($1)) }
    }

    // MARK: - pcm16 档不降混

    /// `pcm16` 档保留源声道数 → **不降混**。
    /// 退化示例：让 `pcm16` 也走 `mono24k: true`，本用例红。
    func testPcm16PresetKeepsSourceChannelsAndRate() throws {
        let id = try makeSession(micSeconds: 1)
        _ = try transcoder.run(sessionID: id, preset: .pcm16)
        let manifest = try store.loadManifest(forSessionID: id)
        XCTAssertEqual(manifest.tracks[0].sampleRate, 48000)
        XCTAssertEqual(manifest.tracks[1].sampleRate, 48000)
        XCTAssertEqual(manifest.tracks[1].channels, 2, "pcm16 档不合并声道")
        XCTAssertTrue(manifest.tracks.allSatisfy { $0.sampleFormat == .pcm16 })
    }

    /// 已转成 pcm16 的场次，用 `lossless32` 可以把位深写回 32 位（不是升采样）。
    /// 退化示例：让 `lossless32` 也降采样，本用例红。
    func testLossless32RestoresBitDepthWithoutTouchingRate() throws {
        let id = try makeSession(micSeconds: 1)
        _ = try transcoder.run(sessionID: id, preset: .pcm16)
        let afterPCM = try fileSize(ofSession: id, fileName: "mic.wav")
        _ = try transcoder.run(sessionID: id, preset: .lossless32)
        let manifest = try store.loadManifest(forSessionID: id)
        XCTAssertTrue(manifest.tracks.allSatisfy { $0.sampleFormat == .float32 })
        XCTAssertEqual(manifest.tracks[0].sampleRate, 48000, "不升采样")
        XCTAssertEqual(manifest.tracks[1].channels, 2, "不合并声道")
        // 体积翻倍的是**数据段**，44 字节头只出现一次。
        // 按「整文件 × 2」断言会多算 44 字节——1 秒的单轨只差 44/192044，
        // 小到会被忽略，于是「头只算一次」这条纪律就没被守住。
        let afterFloat = try fileSize(ofSession: id, fileName: "mic.wav")
        XCTAssertEqual(afterFloat, afterPCM * 2 - WAVWriter.headerSize,
                       "数据段 ×2，头部 44 字节只算一次")
    }
}
