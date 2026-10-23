import XCTest
@testable import MRSession
@testable import MRCore
import Foundation

/// D 档：保留策略的执行层（`SessionRetentionCleaner`）。
///
/// ## 这一组是全项目里唯一「测试失败 = 用户录音还在」的一组
///
/// 与前四档的测试不同，测转码时红一条只是格式不对，**测这里红一条可能意味着
/// 「本该被保住的录音被删了」**。所以下面每条断言都偏向保守侧：
/// 宁可多断言一条「这个不该被删」，也不能漏掉一条「这个被删了」。
///
/// 夹具的年龄用**固定基准日**而不是 `Date()`，这样「刚好 7 天」这类边界
/// 在任何时候跑都成立——用 `Date()` 的话，测试会在跨午夜那几秒里偶发失败。
final class SessionRetentionCleanerTests: XCTestCase {

    /// 统一的「现在」。所有夹具都按它算年龄。
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var root: URL!
    private var store: SessionStore!
    private var cleaner: SessionRetentionCleaner!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SessionStore(root: root)
        cleaner = SessionRetentionCleaner(store: store, now: { Self.now })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 夹具

    /// 造一场会议。
    ///
    /// 轨文件写的是**任意字节**而不是真 WAV：这一层只按 manifest 登记的名字删文件，
    /// 音频内容对判定没有影响，而真写 48 kHz 立体声会把测试拖慢一个量级。
    ///
    /// - Parameters:
    ///   - ageDays: 距「现在」多少天。负数代表未来（时钟回拨）。
    ///   - extraFiles: 额外塞进目录里的文件（用来测「不是 manifest 登记的」那些）。
    @discardableResult
    private func makeSession(title: String,
                             ageDays: Double,
                             state: SessionState = .finalized,
                             withTranscript: Bool = true,
                             withJSONOnly: Bool = false,
                             extraFiles: [String: String] = [:],
                             trackBytes: Int = 4096,
                             compressed: Bool = false) throws -> String {
        let started = Self.now.addingTimeInterval(-ageDays * 86_400)
        let (id, dir) = try store.createSession(title: title, date: started,
                                               writeInitialManifest: false)
        var manifest = RecordingManifest(sessionID: id, title: title,
                                         startedAt: started, state: state)
        manifest.endedAt = started.addingTimeInterval(1800)
        // 轨文件不必是真的 WAV：这一层只按 manifest 登记的名字删文件，
        // 写音频内容对判定没有影响，而真写 48 kHz 立体声会把测试拖慢一个量级。
        //
        // 字节数按**声道数**给（system 是 2 声道，所以字节是 mic 的两倍），
        // 不是两轨一律 `trackBytes`。这一条起初写错了：给成等字节，
        // 于是压缩比算成 5.33 而不是真实的 6.0，而测试还「绿」着——
        // 夹具失真比断言缺失更难发现。
        for (name, role, ch) in [("mic.wav", TrackRole.microphone, 1),
                                  ("system.wav", TrackRole.systemAudio, 2)] {
            let url = dir.appendingPathComponent(name)
            let bytes = compressed ? trackBytes * ch / 2 : trackBytes * ch
            try Data(repeating: 0, count: max(1, bytes)).write(to: url)
            // `compressed: true` 造的是「已经跑过 transcode --preset b-tier」的形态，
            // 格式与位深/采样率/声道**三项都要对**——只改其中一项在现实里做不到，
            // 而 `isCompressedToBTier` 判的就是三项。
            let sampleRate = compressed ? 24000.0 : 48000.0
            let channels = compressed ? 1 : ch
            let sampleFormat: WAVSampleFormat = compressed ? .pcm16 : .float32
            manifest.tracks.append(TrackManifest(
                id: String(name.prefix(while: { $0 != "." })), role: role, fileName: name,
                sampleRate: sampleRate, channels: channels,
                sampleFormat: sampleFormat,
                framesWritten: Int(sampleRate) * 1800))
        }
        try store.save(manifest, sessionDirectory: dir)
        if withTranscript {
            try "# 转写稿\n内容".write(
                to: dir.appendingPathComponent(SessionStore.transcriptMarkdownName),
                atomically: true, encoding: .utf8)
        }
        if withJSONOnly {
            try "{}".write(to: dir.appendingPathComponent(SessionStore.transcriptJSONName),
                           atomically: true, encoding: .utf8)
        }
        for (name, content) in extraFiles {
            try content.write(to: dir.appendingPathComponent(name),
                              atomically: true, encoding: .utf8)
        }
        return id
    }

    /// 目录树的完整快照：相对路径 + 字节数。**用来断言「一个字节都没动」。**
    private func snapshot(_ dir: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        guard let walker = FileManager.default.enumerator(atPath: dir.path) else { return out }
        while let rel = walker.nextObject() as? String {
            let full = dir.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir)
            if isDir.boolValue { continue }
            out[rel] = (try? FileManager.default.attributesOfItem(atPath: full.path)[.size]
                as? Int) ?? -1
        }
        return out
    }

    private func wavPaths(_ id: String) -> [String] {
        let dir = store.directory(forSessionID: id)
        return ["mic.wav", "system.wav"].map { dir.appendingPathComponent($0).path }
    }

    // MARK: - D3-01 plan 是零写入

    func testPlanWritesNothing() throws {
        let id = try makeSession(title: "老会议", ageDays: 100)
        let before = snapshot(root)

        let plan = try cleaner.plan(policy: .days(30))

        XCTAssertEqual(snapshot(root), before, "plan 不该动任何一个文件")
        XCTAssertEqual(plan.sessionCount, 1)
        XCTAssertEqual(plan.prunable.first?.sessionID, id)
    }

    /// 体积按**实际磁盘字节数**算，不是 manifest 的估算。
    ///
    /// manifest 记的是写入时的帧数，盘上现状可能已经和它不一致（手工改过、
    /// 被外部工具转过）。报一个对不上的数字会让用户对「能省多少」失去信任。
    func testReclaimableBytesMatchActualFileSize() throws {
        try makeSession(title: "老会议", ageDays: 100, trackBytes: 8192)
        let plan = try cleaner.plan(policy: .days(30))
        XCTAssertEqual(plan.prunable.first?.filesToDelete.count, 2)
        // mic 单声道 → 8192；system 立体声 → 16384。写成算式而不是 8192*2，
        // 是为了让「字节按声道给」这条夹具语义显形——写死数字时改错夹具不会被发现。
        XCTAssertEqual(plan.reclaimableBytes, 8192 * 1 + 8192 * 2)
    }

    func testPlanListsFileNamesNotJustCounts() throws {
        try makeSession(title: "老会议", ageDays: 100)
        let plan = try cleaner.plan(policy: .days(30))
        XCTAssertEqual(plan.prunable.first?.filesToDelete, ["mic.wav", "system.wav"])
        XCTAssertEqual(plan.prunable.first?.paths.count, 2)
    }

    // MARK: - D3-04 只删 manifest 登记的

    /// **用户自己放进目录里的文件不能被删。** 扫目录式的实现会把
    /// `我的笔记.txt` 之类的无关文件一起清掉，而那与「保留策略」毫无关系。
    ///
    /// 附带文件刻意用非 `.wav`：目录里多一个 wav 会触发另一条纪律（整场跳过，
    /// 见 `testAnyExtraWavBlocksTheSession`），那是更强的判断，单独测。
    func testFilesNotListedInManifestAreLeftAlone() throws {
        try makeSession(title: "老会议", ageDays: 100,
                        extraFiles: ["我的笔记.txt": "重要", "封面.png": "x"])
        let outcome = try cleaner.run(policy: .days(30))
        let deletedID = try XCTUnwrap(outcome.deleted.first?.sessionID)
        XCTAssertEqual(outcome.deleted.first?.deletedFiles.sorted(),
                       ["mic.wav", "system.wav"])
        let dir = store.directory(forSessionID: deletedID)
        for name in ["我的笔记.txt", "封面.png"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(name).path),
                "\(name) 不在 manifest 里，不该被删")
        }
    }

    /// 目录里多出**任何一个** wav 就整场跳过，不只是 `-merged.wav`。
    ///
    /// 判据刻意从宽：那一个多出来的 wav 是什么，只有用户知道。所以从宽的一边
    /// 兜住，代价只是少清一场——而少清用户根本感知不到。
    func testAnyExtraWavBlocksTheSession() throws {
        let id = try makeSession(title: "多一个wav", ageDays: 100,
                                extraFiles: ["现场录音.wav": "别的设备录的"])
        let plan = try cleaner.plan(policy: .days(30))
        let sp = try XCTUnwrap(plan.sessions.first { $0.sessionID == id })
        XCTAssertEqual(sp.filesToDelete, [])
        XCTAssertNotNil(sp.skipReason)
        for path in wavPaths(id) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
    }

    /// 目录里有合并导出产物时整场跳过：合并稿很可能正被当作主要听音入口，
    /// 删掉两条原轨会造成「mic 轨打不开」这种没法解释的现象。
    func testSessionWithMergedArtifactIsSkippedEntirely() throws {
        let id = try makeSession(title: "有合并", ageDays: 100,
                                extraFiles: ["有合并-merged.wav": "merged"])
        let plan = try cleaner.plan(policy: .days(30))
        let sp = try XCTUnwrap(plan.sessions.first { $0.sessionID == id })
        XCTAssertEqual(sp.filesToDelete, [], "有合并产物时不该列任何待删文件")
        XCTAssertNotNil(sp.skipReason)
        XCTAssertTrue(sp.skipReason!.contains("合并"),
                      "跳过原因里要说出「有合并导出文件」这件事：\(sp.skipReason!)")
    }

    // MARK: - D3-05 manifest 与转写稿留着

    func testManifestAndTranscriptSurviveCleanup() throws {
        let id = try makeSession(title: "老会议", ageDays: 100, withJSONOnly: true)
        let dir = store.directory(forSessionID: id)

        _ = try cleaner.run(policy: .days(30))

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(SessionStore.manifestFileName).path))
        for name in [SessionStore.transcriptMarkdownName, SessionStore.transcriptJSONName] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(name).path), "\(name) 不该被删")
        }
    }

    /// **删除走废纸篓，不是直接抹掉。**
    ///
    /// 这是录音这种不可再生数据唯一的反悔机会，所以断言不止于「原路径没了」——
    /// 还要断言**废纸篓里真的有**。`fileExists == false` 这两种做法都满足。
    /// 探针实测（`trashItem` 对普通文件）落点为 `~/.Trash/<原文件名>`。
    func testDeletedFilesLandInTheTrash() throws {
        let id = try makeSession(title: "老会议", ageDays: 100)
        let originals = wavPaths(id)
        let names = originals.map { URL(fileURLWithPath: $0).lastPathComponent }

        _ = try cleaner.run(policy: .days(30))

        let trash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
        for name in names {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: originals.first { $0.hasSuffix(name) }!),
                "\(name) 应当离开原目录")
            let trashed = trash.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path),
                          "\(name) 应当出现在废纸篓里——直接抹掉的话用户无法反悔")
            try? FileManager.default.removeItem(at: trashed)
        }
    }

    /// **删除走的是 `trashItem`（废纸篓），不是直接 `removeItem`。**
    ///
    /// 这是录音这种不可再生数据唯一的反悔机会。而判据必须落在**动作**上：
    /// 「原路径不见了」两种实现都满足，端到端读 `~/.Trash` 又不可靠
    /// （macOS 真实行为，无头/权限受限环境里静默失效——实测过同一条
    /// 「直接抹掉」的变异在命令行连跑 4 次都红、放进完整跑批却稳定绿）。
    ///
    /// 所以把删除动作注入进来：探针只需要回答「调用的是哪一个」，
    /// 不碰任何系统行为，跨环境稳定。
    func testDeletionUsesTheInjectedTrashActionAndReportsItsResult() throws {
        let id = try makeSession(title: "老会议", ageDays: 100)
        let expected = Set(wavPaths(id).map { URL(fileURLWithPath: $0).lastPathComponent })

        final class Probe {
            var received: [String] = []
        }
        let probe = Probe()

        // 探针**真的把文件移走**（移到临时「废纸篓」），这样后面的
        // 「原路径已空 / 已释放体积」两条断言仍然是端到端的，没有被架空。
        let fakeTrash = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-fake-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeTrash) }

        let injected = SessionRetentionCleaner(
            store: store, now: { Self.now },
            trash: { url in
                probe.received.append(url.lastPathComponent)
                let dest = fakeTrash.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            })

        let outcome = try injected.run(policy: .days(30))

        XCTAssertEqual(Set(probe.received), expected,
                       "两个音频都必须交给删除动作，而不是被跳过或直接抹掉")
        // 端到端的那一半：文件真的离开原目录了，且体积按落点算。
        for name in expected {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: fakeTrash.appendingPathComponent(name).path),
                "\(name) 应当出现在删除动作给出的落点上")
        }
        XCTAssertFalse(outcome.deleted.isEmpty, "删除结果不应为空")
        XCTAssertTrue(outcome.failed.isEmpty, "不该有失败")
        XCTAssertEqual(outcome.deletedFileCount, expected.count,
                       "删掉的文件数应当正好是两个音频")
        XCTAssertGreaterThan(outcome.freedBytes, 0, "释放体积应当按落点算")
    }

    /// **默认动作必须是 `trashItem`（移动到废纸篓），不是 `removeItem`（抹掉）。**
    ///
    /// 上面那条证明了「注入的动作会被调用」，这条钉住**默认值本身**——
    /// 注入点是为了可测，但生产路径绝不能因为「测试方便」而改成直接抹掉。
    ///
    /// 这条判据绕开了两次都踩到的坑：
    ///
    /// 1. 端到端读 `~/.Trash` —— macOS 真实行为，无头环境里静默失效；
    /// 2. 去临时卷里找 `.Trash` —— **也不行**：实测本机上`trashItem`
    ///    对临时目录里的文件不产生任何可查的落点，于是「默认实现」也会判红。
    ///
    /// 剩下的唯一可靠办法是**观察默认动作的行为差异**，而这个差异
    /// 在源码层面是确定的：`trashItem` 成功时会给出一个**不同于原路径**的
    /// 落点（`resultingItemURL`），`removeItem` 没有这个返回值。
    /// 所以直接断言默认闭包的落点语义：
    ///
    /// - 默认闭包对受控文件执行后，返回的 URL **必须存在且不等于原路径**
    ///   （抹掉的实现会返回原路径，而原路径已经没了）。
    ///
    /// 用例会造一个真实文件让默认动作处理，不依赖系统废纸篓的落点位置。
    func testDefaultTrashActionReportsALandingPointDistinctFromTheSource() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-trash-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("probe.wav")
        try Data(repeating: 0, count: 64).write(to: source)

        let landing = try SessionRetentionCleaner.defaultTrash(source)

        XCTAssertNotEqual(landing.standardizedFileURL,
                          source.standardizedFileURL,
                          "默认动作返回的落点就是原路径——它没把文件移走，"
                          + "而是抹掉了（用户无法反悔）")
        // 抹掉的实现会让原路径消失但落点也不存在；移动的实现两者都成立。
        // 这一条断言把「移动」钉死，而不只是「原路径没了」。
        XCTAssertTrue(FileManager.default.fileExists(atPath: landing.path),
                      "落点 \\(landing.path) 应当真实存在——文件是被移走的，不是被抹掉的")
    }

    /// 清理之后这一场**仍在列表里**，且显示为「0 轨」而不是条目消失。
    ///
    /// 条目消失会是「数据没了」的读法，而事实是「内容还在，只是不能回放了」——
    /// 这两者的差别就是 D 档全部设计的出发点。
    func testCleanedSessionStaysListedWithZeroTracks() throws {
        let id = try makeSession(title: "老会议", ageDays: 100)
        let library = SessionLibrary(root: root)

        XCTAssertEqual(library.summary(forSessionID: id).existingTrackCount, 2)

        _ = try cleaner.run(policy: .days(30))

        let after = library.summary(forSessionID: id)
        XCTAssertEqual(after.existingTrackCount, 0)
        XCTAssertTrue(library.list().contains { $0.id == id },
                      "清理后的场次仍应出现在列表里")
        XCTAssertEqual(after.title, "老会议", "标题也该留着")
        XCTAssertTrue(after.hasTranscript)
    }

    // MARK: - 四条纪律

    /// 纪律 2：坏 manifest 永远不参与清理。
    ///
    /// `SessionLibrary` 对读不出来的 manifest 会给一个用**目录 mtime** 当日期的
    /// 占位条目。用它来判年龄的话，往老猜会删掉刚录的会议，往新猜只是少删一场——
    /// 这个不对称决定了必须跳过。
    ///
    /// 断言分三层，缺一层就有一类实现能混过去：
    /// 1. 计划里没有它（`prunable` 为空）；
    /// 2. 它在 `sessions` 里且**带着可读的跳过原因**（不能是个静默的空条目）；
    /// 3. **真的跑一遍之后文件还在盘上**（这是唯一能抓住「嘴上跳过、手上照删」的）。
    func testBrokenManifestIsNeverPruned() throws {
        let id = try makeSession(title: "坏manifest", ageDays: 100)
        // 把它读坏：截断成非法 JSON
        try Data("{ 这不是 json".utf8).write(
            to: store.directory(forSessionID: id)
                .appendingPathComponent(SessionStore.manifestFileName))

        let plan = try cleaner.plan(policy: .days(30))

        XCTAssertTrue(plan.prunable.isEmpty, "manifest 读不出来的场次不该被列入清理")
        XCTAssertFalse(plan.reclaimableBytes > 0,
                       "可回收体积不该把读不出 manifest 的场次算进去")
        let sp = try XCTUnwrap(plan.sessions.first { $0.sessionID == id })
        XCTAssertNotNil(sp.skipReason)
        XCTAssertTrue(sp.skipReason!.contains("manifest"),
                      "跳过原因要说清是 manifest 的问题：\(sp.skipReason!)")

        // 第 3 层：实跑一遍，文件必须还在。
        _ = try cleaner.run(policy: .days(30))
        for path in wavPaths(id) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "manifest 读不出来的场次，音频必须留在盘上")
        }
    }

    /// **坏 manifest 的场次即使「看起来够老」也不删。**
    ///
    /// 上一条用的场次是 100 天前的；这一条把目录 mtime 调到很久以前，
    /// 于是「按 mtime 猜年龄」的实现会算出「够 90 天」而把它清掉——
    /// 那正是纪律 2 要挡的事：删掉一场用户刚录、只是 manifest 写坏了的会议。
    /// 只改目录 mtime、不改 manifest，所以 manifest 依然是坏的。
    func testBrokenManifestIsNotPrunedEvenWhenTheDirectoryLooksOld() throws {
        let id = try makeSession(title: "坏manifest但目录很老", ageDays: 0.5)
        try Data("{ 坏".utf8).write(
            to: store.directory(forSessionID: id)
                .appendingPathComponent(SessionStore.manifestFileName))
        // 把目录 mtime 推到 400 天前：任何「按 mtime 判年龄」的实现都会中招。
        let old = Date().addingTimeInterval(-400 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old],
                                              ofItemAtPath: store.directory(forSessionID: id).path)

        let outcome = try cleaner.run(policy: .days(30))

        XCTAssertTrue(outcome.deleted.isEmpty)
        XCTAssertTrue(outcome.freedBytes == 0)
        for path in wavPaths(id) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "目录 mtime 很老不是删除理由——它恰恰是坏 manifest 的症状")
        }
    }

    /// 纪律 2：录制中的永不删。
    func testRecordingSessionIsNeverPruned() throws {
        let id = try makeSession(title: "正在录", ageDays: 100, state: .recording)
        _ = try cleaner.run(policy: .days(30))
        for path in wavPaths(id) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "state == .recording 的场次可能真的还在录，不能删")
        }
    }

    /// 纪律 3：没转写稿的默认不删——删了这场就只剩标题和时长了。
    func testUntranscribedSessionIsSkippedByDefault() throws {
        let id = try makeSession(title: "没转写", ageDays: 100, withTranscript: false)
        _ = try cleaner.run(policy: .days(30))
        for path in wavPaths(id) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "没转写过的会议删掉音频就没有内容了")
        }
    }

    /// 显式开口子之后才清，而且**只清没稿的那一场**。
    func testIncludeUntranscribedOptIn() throws {
        let withText = try makeSession(title: "有稿", ageDays: 100, withTranscript: true)
        let without = try makeSession(title: "无稿", ageDays: 100, withTranscript: false)

        let plan = try cleaner.plan(policy: .days(30), includeUntranscribed: true)
        XCTAssertEqual(plan.sessionCount, 2)

        let outcome = try cleaner.run(policy: .days(30), includeUntranscribed: true)
        XCTAssertEqual(Set(outcome.deleted.map(\.sessionID)), [withText, without])
    }

    /// 只有 `transcript.json`（没有 md）也算「转写过」。
    ///
    /// 与 `SessionAudioTranscoder.hasTranscript` 同口径：只认 md 会把这类场次
    /// 判成「没转写过」，于是它**永远不会被清理**——一个静默的漏网。
    func testJSONOnlyTranscriptCountsAsTranscribed() throws {
        let id = try makeSession(title: "只有json", ageDays: 100,
                                 withTranscript: false, withJSONOnly: true)
        let plan = try cleaner.plan(policy: .days(30))
        XCTAssertEqual(plan.prunable.first?.sessionID, id)
    }

    /// 档位判定本身也在这里过一遍（`>=` 边界）。
    func testAgeBoundaryIsInclusive() throws {
        let exactlySeven = try makeSession(title: "刚好七天", ageDays: 7)
        // 差 1 秒（比7 天年轻 1 秒）：7 天的档位**不**该选中它。
        let oneSecondYounger = try makeSession(title: "差一秒",
                                                ageDays: 7 - 1.0 / 86_400)

        let plan = try cleaner.plan(policy: .days(7))
        let ids = plan.prunable.map(\.sessionID)

        XCTAssertTrue(ids.contains(exactlySeven), "正好 7 天应当入选（边界是 >=）")
        XCTAssertFalse(ids.contains(oneSecondYounger))
    }

    // MARK: - 幂等与批量

    func testRunningTwiceIsIdempotent() throws {
        try makeSession(title: "老会议", ageDays: 100)
        let first = try cleaner.run(policy: .days(30))
        XCTAssertEqual(first.deletedFileCount, 2)

        let second = try cleaner.run(policy: .days(30))

        XCTAssertTrue(second.deleted.isEmpty, "第二次不该再删任何东西")
        XCTAssertTrue(second.failed.isEmpty, "清过了不该报错")
    }

    /// 一场失败不中断整批。
    ///
    /// 失败怎么造：把这一场目录的权限设成 `r-x`（不可写），
    /// 于是 `trashItem` 移不动里面的文件（实测 errno 513 = ENOTEMPTY 路径上的拒绝）。
    ///
    /// **这里踩过一次坑**：最初把 `mic.wav` 换成一个同名**目录**来制造失败，
    /// 结果它被成功移进废纸篓（探针实测 `trashItem` 对非空目录同样成功），
    /// 于是「一批里混进一个失败」这个场景根本没被造出来，
    /// 而测试当时是绿的——因为它只在断言「另一场被删」这件事。
    /// 换掉造法之后本条才真的在测它声称在测的东西。
    func testOneSessionFailureDoesNotStopTheBatch() throws {
        let bad = try makeSession(title: "会失败", ageDays: 100)
        let good = try makeSession(title: "正常", ageDays: 100)
        let badDir = store.directory(forSessionID: bad)

        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: badDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: badDir.path) }

        let outcome = try cleaner.run(policy: .days(30))

        XCTAssertEqual(Set(outcome.deleted.map(\.sessionID)), [good],
                       "另一场应当照常删完")
        XCTAssertEqual(Set(outcome.failed.map(\.sessionID)), [bad],
                       "不可写的这场应当报失败")
        XCTAssertFalse(outcome.isCompleteSuccess, "有一场失败就不能算全部成功")
    }

    /// 磁盘上轨文件已经不在（用户手工删过）→ 跳过，不报错。
    func testMissingTrackFileIsNotAnError() throws {
        let id = try makeSession(title: "手工删过", ageDays: 100)
        try FileManager.default.removeItem(
            at: store.directory(forSessionID: id).appendingPathComponent("mic.wav"))

        let plan = try cleaner.plan(policy: .days(30))
        XCTAssertEqual(plan.prunable.first?.filesToDelete, ["system.wav"])

        let outcome = try cleaner.run(policy: .days(30))
        XCTAssertTrue(outcome.failed.isEmpty, "文件不在盘上是正常状态，不是失败")
    }

    /// 每一场跳过都要有**可读原因**，不能是空条目。
    func testEverySkipCarriesAReadableReason() throws {
        try makeSession(title: "没到档", ageDays: 3)
        try makeSession(title: "没转写", ageDays: 100, withTranscript: false)
        try makeSession(title: "在录", ageDays: 100, state: .recording)
        try makeSession(title: "有合并", ageDays: 100, extraFiles: ["x-merged.wav": "m"])

        let plan = try cleaner.plan(policy: .days(30))

        XCTAssertFalse(plan.skipped.isEmpty)
        for s in plan.skipped {
            let reason = s.skipReason ?? ""
            XCTAssertFalse(reason.isEmpty, "\(s.title) 的跳过原因为空")
            XCTAssertGreaterThan(reason.count, 6,
                                 "跳过理由太短，多半只是个占位符：\(reason)")
        }
    }

    /// 列表顺序与 `SessionLibrary.list()` 一致（最新的在前）。
    /// 两边顺序不同会让用户在对照时怀疑其中一个坏了。
    func testPlanOrderMatchesLibraryOrder() throws {
        try makeSession(title: "老", ageDays: 200)
        try makeSession(title: "新", ageDays: 2)
        let plan = try cleaner.plan(policy: .days(7))
        XCTAssertEqual(plan.sessions.map(\.sessionID),
                       SessionLibrary(root: root).list().map(\.id))
    }

    // MARK: - dry-run 与档位

    /// dry-run 一个字节都不写，但**账要算对**——
    /// 「预演说能省 8 MiB，真跑省了 0」是比报错更坏的体验。
    func testDryRunWritesNothingButReportsAccurately() throws {
        try makeSession(title: "老会议", ageDays: 100, trackBytes: 4096)
        let before = snapshot(root)

        let outcome = try cleaner.run(policy: .days(30), dryRun: true)

        XCTAssertEqual(snapshot(root), before)
        XCTAssertTrue(outcome.dryRun)
        XCTAssertEqual(outcome.deletedFileCount, 2)
        XCTAssertEqual(outcome.freedBytes, 4096 * 1 + 4096 * 2)
        XCTAssertTrue(outcome.notes.contains { $0.contains("不会") },
                      "dry-run 必须明说一个文件都不会被删")
    }

    /// 「关闭」在清理器这一层也必须真的什么都不删——
    /// 哪怕场次老到一万年、已转写、磁盘上有 4 GB 音频。
    ///
    /// 这条同时替掉了原来那条 `.keepForever` 的用例：合并档位后
    /// 「永久保留」就是关闭，所以只有一种「不删」需要被守住。
    func testOffPolicyNeverPrunesEvenForAncientTranscribedSessions() throws {
        try makeSession(title: "一万年前", ageDays: 3650, trackBytes: 4096)
        let outcome = try cleaner.run(policy: .off)
        XCTAssertTrue(outcome.deleted.isEmpty)
        XCTAssertTrue(outcome.notes.contains { $0.contains("不会删任何东西") },
                      "档位是关闭时要明说「不会删任何东西」")
    }

    /// 根目录还不存在时给一句人话，而不是抛错或静默空集。
    func testMissingRootIsExplainedNotThrown() throws {
        let emptyRoot = root.appendingPathComponent("不存在", isDirectory: true)
        let c = SessionRetentionCleaner(store: SessionStore(root: emptyRoot),
                                         now: { Self.now })
        let plan = try c.plan(policy: .days(30))
        XCTAssertTrue(plan.isEmpty)
        XCTAssertNotNil(plan.rootNote)
        XCTAssertTrue(plan.rootNote!.contains("不存在"))
    }

    /// `isCompleteSuccess` 不能把「什么都没删」报成成功。
    func testNothingDeletedIsNotReportedAsSuccess() throws {
        try makeSession(title: "没到档", ageDays: 1)
        let outcome = try cleaner.run(policy: .days(30))
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertFalse(outcome.isCompleteSuccess,
                       "一场都没删时不该报「全部成功」")
    }

    // MARK: - 「还没压过」的判定与收益估算

    /// 刚录的场次是原始格式，必须被标出来。
    ///
    /// 这条是整个顺序提醒的地基：标不出来，CLI 与 GUI 就都不会提醒，
    /// 而用户以为「清掉了就省下了」——实际省的是原始体积。
    func testFreshlyRecordedSessionIsMarkedUncompressed() throws {
        _ = try makeSession(title: "原始格式", ageDays: 100)
        let plan = try cleaner.plan(policy: .days(30))
        let sp = try XCTUnwrap(plan.prunable.first)
        XCTAssertTrue(sp.isUncompressed)
        XCTAssertEqual(plan.uncompressedPrunable.count, 1)
        XCTAssertGreaterThan(plan.additionalBytesIfCompressedFirst, 0)
    }

    /// 压过之后**必须不再提示**。
    ///
    /// 反向同样重要：一直提示「还能再省 6 倍」是在骗人——那 6 倍已经省过了，
    /// 再提示一次会让用户以为还有 6 倍没拿。
    func testCompressedSessionIsNotMarkedUncompressed() throws {
        _ = try makeSession(title: "压过了", ageDays: 100, compressed: true)
        let plan = try cleaner.plan(policy: .days(30))
        let sp = try XCTUnwrap(plan.prunable.first)
        XCTAssertFalse(sp.isUncompressed)
        XCTAssertTrue(plan.uncompressedPrunable.isEmpty)
        XCTAssertEqual(plan.additionalBytesIfCompressedFirst, 0)
        XCTAssertNil(sp.potentialCompressionRatio)
    }

    /// **收益估算必须等于真实转码的结果。**
    ///
    /// 期望值 6.0 不是拍出来的：本机真机录了一 26秒双轨（mic 48 kHz 单声道
    /// float32 + system 48 kHz 立体声 float32），跑 `transcode --preset b-tier`
    /// 实测 14.3 MiB → 2.4 MiB，正好 6.00 倍。判定用字节比例算而不用「6.0」
    /// 这个常数，才能保证转码器改了之后这里会跟着变。
    func testCompressionRatioMatchesRealTranscodeMeasurement() throws {
        _ = try makeSession(title: "估算", ageDays: 100)
        let plan = try cleaner.plan(policy: .days(30))
        let sp = try XCTUnwrap(plan.prunable.first)
        let ratio = try XCTUnwrap(sp.potentialCompressionRatio)

        // mic: 32bit×48000×1 → 16bit×24000×1 = 1/4
        // system: 32bit×48000×2 → 16bit×24000×1 = 1/12
        // 两轨字节数相等（夹具里 trackBytes 相同），加权后：
        // (4096 + 4096) / (4096/4 + 4096/12) = 8192 / 1365.33 = 6.0
        XCTAssertEqual(ratio, 6.0, accuracy: 0.01,
                       "估算收益与真机实测的 6.00 倍对不上")
    }

    /// 两条轨的**源格式不同时**不能套一个统一倍数。
    ///
    /// 用统一值会报出一个假的收益：这里 mic 已经压过（无收益）、
    /// system 还是原始（有收益），平均出来的数两边都不对。
    func testMixedCompressionStatesAreAveragedNotAssumed() throws {
        let started = Self.now.addingTimeInterval(-100 * 86_400)
        let (id, dir) = try store.createSession(title: "一半压过",
                                               date: started,
                                               writeInitialManifest: false)
        var m = RecordingManifest(sessionID: id, title: "一半压过",
                                  startedAt: started, state: .finalized)
        m.endedAt = started.addingTimeInterval(1800)
        for (name, role, ch, compressed) in [
            ("mic.wav", TrackRole.microphone, 1, true),
            ("system.wav", TrackRole.systemAudio, 2, false),
        ] {
            let url = dir.appendingPathComponent(name)
            // 字节按声道给：压过的 mic 是 4096，原始的 system 是 8192。
            let bytes = compressed ? 4096 : 4096 * ch
            try Data(repeating: 0, count: bytes).write(to: url)
            m.tracks.append(TrackManifest(
                id: String(name.prefix(while: { $0 != "." })), role: role, fileName: name,
                sampleRate: compressed ? 24000 : 48000,
                channels: compressed ? 1 : ch,
                sampleFormat: compressed ? .pcm16 : .float32,
                framesWritten: 48000 * 1800))
        }
        try store.save(m, sessionDirectory: dir)
        try "# 稿".write(to: dir.appendingPathComponent(SessionStore.transcriptMarkdownName),
                         atomically: true, encoding: .utf8)

        let plan = try cleaner.plan(policy: .days(30))
        let sp = try XCTUnwrap(plan.prunable.first)
        // 只要还有一条轨是原始的，这场就仍算「没压过」——
        // 判「全部压过」比判「至少压过一条」更保守，宁可多提醒一次。
        XCTAssertTrue(sp.isUncompressed)
        // mic 已压过 → 收益 1.0（4096 → 4096）；system 原始立体声 → 收益 8.0
        // （8192 → 1024）。合计 12288 / 5120 = 2.4。
        //
        // 这个数比「两轨都原始」的 6.0 小，正是**加权**该有的结果：
        // 整体收益取决于字节分布，不是一条轨一个固定倍数。
        let ratio = try XCTUnwrap(sp.potentialCompressionRatio)
        XCTAssertEqual(ratio, 2.4, accuracy: 0.01)
    }

    /// 只有一条轨还在盘上时，收益只能按那一条算。
    ///
    /// 拿 manifest 里另一条**已经不在盘上**的轨去参与加权，会把收益算低——
    /// 而「算低」在这里的方向是让用户以为没多少可省，于是照删。
    func testRatioUsesOnlyTracksActuallyOnDisk() throws {
        let id = try makeSession(title: "少一轨", ageDays: 100)
        try FileManager.default.removeItem(
            at: store.directory(forSessionID: id).appendingPathComponent("system.wav"))

        let plan = try cleaner.plan(policy: .days(30))
        let sp = try XCTUnwrap(plan.prunable.first)
        XCTAssertEqual(sp.filesToDelete, ["mic.wav"])
        // mic 原始 32bit×48000×1 → 1/4
        XCTAssertEqual(try XCTUnwrap(sp.potentialCompressionRatio), 4.0, accuracy: 0.01)
    }

    /// 跳过的场次不该带「还没压过」的结论。
    ///
    /// 它不会被删，顺序对它没有意义；带上只会让汇总数虚高。
    func testSkippedSessionsCarryNoCompressionAdvice() throws {
        _ = try makeSession(title: "没转写", ageDays: 100, withTranscript: false)
        _ = try makeSession(title: "太新", ageDays: 2)
        let plan = try cleaner.plan(policy: .days(30))
        XCTAssertTrue(plan.prunable.isEmpty)
        XCTAssertTrue(plan.uncompressedPrunable.isEmpty)
        XCTAssertEqual(plan.additionalBytesIfCompressedFirst, 0)
    }

    /// 空目录不该因为「还没压过」而被算出一个收益。
    ///
    /// `potentialCompressionRatio` 是 `Double`，`0/0` 在那条路上真的会得到 NaN。
    /// 而 NaN 一旦进了文案就是「多腾约 nan 字节」——
    /// 用户没法判断那是 0 还是全部，所以这条守的是「宁可不给数，也不给 NaN」。
    func testEmptyLibraryYieldsNoNaNAdvice() throws {
        let plan = try cleaner.plan(policy: .days(30))
        XCTAssertTrue(plan.sessions.isEmpty)
        XCTAssertEqual(plan.additionalBytesIfCompressedFirst, 0)
        for sp in plan.sessions {
            if let r = sp.potentialCompressionRatio {
                XCTAssertTrue(r.isFinite, "收益倍数不能是 NaN 或 inf，得到的是 \(r)")
            }
        }
    }

    /// 一条轨都没有（都在盘上被手工删光）时同样不该给出收益。
    ///
    /// 注意这条场次**不在 `prunable` 里**——`filesToDelete` 为空，它走的是
    /// 「音频文件已经不在盘上（之前清过了）」那条分支。所以断言要打在
    /// `sessions` 上而不是 `prunable`，否则测的是一个不存在的场次。
    ///
    /// `potentialCompressionRatio` 是 `Double`，`0/0` 在那条路上真的会得到 NaN。
    func testSessionWithNoAudioLeftYieldsNoRatio() throws {
        let id = try makeSession(title: "音频全没了", ageDays: 100)
        let dir = store.directory(forSessionID: id)
        for n in ["mic.wav", "system.wav"] {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }

        let plan = try cleaner.plan(policy: .days(30))
        let sp = try XCTUnwrap(plan.sessions.first { $0.sessionID == id })
        XCTAssertEqual(sp.filesToDelete, [])
        XCTAssertNil(sp.potentialCompressionRatio)
        XCTAssertEqual(plan.additionalBytesIfCompressedFirst, 0)
    }
}