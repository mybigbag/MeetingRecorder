import XCTest
import Darwin
@testable import MRTranscribe
@testable import MRCore

/// 下载器与资产状态：全部用**注入的假 fetch**跑，不打真网络。
///
/// 这一层之所以必须测得这么细：它守的是「半成品不得落盘」。
/// 一个把半个文件改名成目标名的实现，在体积检查恰好被跳过时**看起来完全正常**——
/// 直到推理运行时拿着一个坏模型跑出垃圾文本。真网络只在真机集成里验一次。
final class SenseVoiceDownloaderTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-download-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        base = nil
    }

    // MARK: - 测试替身

    /// 记录调用顺序的假 fetch。
    private final class FakeFetch {
        struct Call { var remote: URL; var destination: URL }
        private let lock = NSLock()
        private var _calls: [Call] = []
        var behaviour: (URL, URL) throws -> Data = { _, _ in Data() }

        var calls: [Call] {
            lock.withLock { _calls }
        }

        func fetch(
            remote: URL,
            destination: URL,
            onProgress: ((Int64) -> Void)?
        ) async throws {
            // `withLock` 而不是裸的 lock/unlock：`fetch` 是 async，
            // 而 `NSLock.lock()` 在异步上下文里会被判成不安全（Swift 6 起是错误）。
            lock.withLock { _calls.append(Call(remote: remote, destination: destination)) }
            let data = try behaviour(remote, destination)
            try data.write(to: destination)
            onProgress?(Int64(data.count))
        }
    }

    /// 造一个**小体积**的资产替身：真权重是 242 MiB，测试里写满磁盘没有意义，
    /// 而这里要验的是「校验与落盘逻辑」，与字节数无关。
    private func makeAsset(
        contents: Data = Data("sensevoice-fixture".utf8),
        fileName: String = "fixture.bin"
    ) throws -> SenseVoiceAsset {
        let staging = base.appendingPathComponent("expected-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let digest = try SenseVoiceModelStore.sha256(ofFileAt: staging)
        return SenseVoiceAsset(
            kind: .model,
            fileName: fileName,
            byteCount: contents.count,
            sha256: digest,
            source: .file(urls: [
                URL(string: "https://hf-mirror.com/fixture.bin")!,
                URL(string: "https://huggingface.co/fixture.bin")!,
            ]),
            license: "MIT",
            attribution: "fixture")
    }

    // MARK: - D01 / D02 / D03：校验与落盘

    /// D01：字节与摘要都对 → 成功，且**不残留 `.part`**。
    func testSuccessfulDownloadLandsFileAndRemovesStaging() async throws {
        let asset = try makeAsset()
        let fake = FakeFetch()
        fake.behaviour = { _, _ in Data("sensevoice-fixture".utf8) }

        let downloader = SenseVoiceDownloader(
            paths: SenseVoicePaths(baseDirectory: base), fetch: fake.fetch)
        let url = try await downloader.install(asset)

        XCTAssertEqual(url.path, base.appendingPathComponent("models/\(asset.fileName)").path)
        XCTAssertEqual(SenseVoiceModelStore.fileSize(at: url), asset.byteCount)
        XCTAssertEqual(fake.calls.count, 1, "成功后不该再试第二个源")

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasSuffix(".part") }
        XCTAssertTrue(leftovers.isEmpty, "不得残留临时文件：\(leftovers)")
    }

    /// D02：字节数不足 → 抛错，**目标文件不存在**。
    /// 留下半个文件冒充「下载完成」是这一层最严重的失败模式。
    func testShortDownloadFailsAndLeavesNoTargetFile() async throws {
        let asset = try makeAsset()
        let fake = FakeFetch()
        fake.behaviour = { _, _ in Data("sense".utf8) }   // 只有一半

        let downloader = SenseVoiceDownloader(
            paths: SenseVoicePaths(baseDirectory: base), fetch: fake.fetch)
        do {
            _ = try await downloader.install(asset)
            XCTFail("字节数不符必须抛错")
        } catch let error as MRError {
            XCTAssertTrue("\(error)".contains("字节数"), "错误信息应指明是字节数问题：\(error)")
            XCTAssertTrue("\(error)".contains("\(asset.byteCount)"), "错误信息应给出期望字节数")
        }

        let target = base.appendingPathComponent("models/\(asset.fileName)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "失败时不得留下目标文件")
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: target.deletingLastPathComponent().path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasSuffix(".part") }, "失败时不得残留 .part")
    }

    /// D03：长度对但内容错 → 抛错并指明 sha256。
    /// 只比字节数会放过这种文件——它同样会让推理产出垃圾。
    func testCorruptedContentFailsDigestCheck() async throws {
        let asset = try makeAsset(contents: Data(repeating: 0x41, count: 64))
        let fake = FakeFetch()
        fake.behaviour = { _, _ in Data(repeating: 0x42, count: 64) }  // 同长度，不同内容

        let downloader = SenseVoiceDownloader(
            paths: SenseVoicePaths(baseDirectory: base), fetch: fake.fetch)
        do {
            _ = try await downloader.install(asset)
            XCTFail("sha256 不符必须抛错")
        } catch let error as MRError {
            XCTAssertTrue("\(error)".contains("sha256"), "错误信息应指明是摘要问题：\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: base.appendingPathComponent("models/\(asset.fileName)").path))
    }

    // MARK: - D04 / D05：多源回退

    /// D04：镜像失败 → 自动试 HF 兜底，且**顺序**是镜像优先。
    func testFallsBackToSecondSourceInOrder() async throws {
        let asset = try makeAsset()
        let fake = FakeFetch()
        fake.behaviour = { remote, _ in
            if remote.host == "hf-mirror.com" { throw MRError.io(path: "-", reason: "镜像挂了") }
            return Data("sensevoice-fixture".utf8)
        }

        let downloader = SenseVoiceDownloader(
            paths: SenseVoicePaths(baseDirectory: base), fetch: fake.fetch)
        let url = try await downloader.install(asset)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertEqual(fake.calls[0].remote.host, "hf-mirror.com")
        XCTAssertEqual(fake.calls[1].remote.host, "huggingface.co")
    }

    /// D05：全部来源失败 → 错误信息里**列全**试过的地址。
    /// 只说一句「下载失败」，用户无法判断是镜像挂了、网络不通，还是地址本身写错了。
    func testAllSourcesFailingListsEveryAttemptedURL() async throws {
        let asset = try makeAsset()
        let fake = FakeFetch()
        fake.behaviour = { _, _ in throw MRError.io(path: "-", reason: "网络不可达") }

        let downloader = SenseVoiceDownloader(
            paths: SenseVoicePaths(baseDirectory: base), fetch: fake.fetch)
        do {
            _ = try await downloader.install(asset)
            XCTFail("全部来源失败必须抛错")
        } catch let error as MRError {
            let text = "\(error)"
            XCTAssertTrue(text.contains("hf-mirror.com"), "应列出镜像地址：\(text)")
            XCTAssertTrue(text.contains("huggingface.co"), "应列出兜底地址：\(text)")
            XCTAssertTrue(text.contains("HTTPS_PROXY"), "应给出代理排查提示")
        }
        XCTAssertEqual(fake.calls.count, 2)
    }

    // MARK: - D06 / D07：幂等

    /// D06：已就绪 → **完全不发网络请求**。让「再跑一次 download」是安全的。
    func testAlreadyInstalledSkipsNetworkEntirely() async throws {
        let asset = try makeAsset()
        let fake = FakeFetch()
        fake.behaviour = { _, _ in Data("sensevoice-fixture".utf8) }
        let downloader = SenseVoiceDownloader(
            paths: SenseVoicePaths(baseDirectory: base), fetch: fake.fetch)

        _ = try await downloader.install(asset)
        XCTAssertEqual(fake.calls.count, 1)

        _ = try await downloader.install(asset)
        XCTAssertEqual(fake.calls.count, 1, "已就绪时不应再下载")
    }

    /// D07：`force` 会重下（用于「怀疑文件坏了」的场景）。
    func testForceRedownloads() async throws {
        let asset = try makeAsset()
        let fake = FakeFetch()
        fake.behaviour = { _, _ in Data("sensevoice-fixture".utf8) }
        let downloader = SenseVoiceDownloader(
            paths: SenseVoicePaths(baseDirectory: base), fetch: fake.fetch)

        _ = try await downloader.install(asset)
        _ = try await downloader.install(asset, force: true)
        XCTAssertEqual(fake.calls.count, 2)
    }

    // MARK: - D08 / D09 / D10

    /// D08：进度单调不减，最终值等于总字节。
    func testProgressIsMonotonicAndEndsAtTotal() async throws {
        let asset = try makeAsset()
        let payload = Data("sensevoice-fixture".utf8)
        let fake = FakeFetch()
        fake.behaviour = { _, _ in payload }

        var seen: [Int64] = []
        let downloader = SenseVoiceDownloader(
            paths: SenseVoicePaths(baseDirectory: base), fetch: fake.fetch)
        _ = try await downloader.install(asset) { progress in
            XCTAssertEqual(progress.kind, .model)
            XCTAssertEqual(progress.expectedBytes, asset.byteCount)
            seen.append(progress.receivedBytes)
        }

        XCTAssertFalse(seen.isEmpty, "应至少报告一次进度")
        XCTAssertEqual(seen, seen.sorted(), "进度必须单调不减")
        XCTAssertEqual(seen.last, Int64(asset.byteCount))
    }

    /// D09：取消 → 抛错并清理 `.part`，不留下一个「看起来在下载」的残骸。
    func testCancellationCleansStaging() async throws {
        let asset = try makeAsset()
        let fake = FakeFetch()
        fake.behaviour = { _, _ in throw CancellationError() }

        let downloader = SenseVoiceDownloader(
            paths: SenseVoicePaths(baseDirectory: base), fetch: fake.fetch)
        do {
            _ = try await downloader.install(asset)
            XCTFail("取消应抛错")
        } catch {
            // 期望是任何错误；关键是下面两条
        }
        let models = base.appendingPathComponent("models")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: models.path)) ?? []
        XCTAssertTrue(leftovers.filter { $0.hasSuffix(".part") }.isEmpty,
                      "取消后不得残留 .part：\(leftovers)")
        XCTAssertFalse(leftovers.contains(asset.fileName))
    }

    /// D10：父目录不存在时自动创建。
    func testCreatesParentDirectories() async throws {
        let asset = try makeAsset(fileName: "nested/deep-fixture.bin")
        let fake = FakeFetch()
        fake.behaviour = { _, _ in Data("sensevoice-fixture".utf8) }

        let downloader = SenseVoiceDownloader(
            paths: SenseVoicePaths(baseDirectory: base), fetch: fake.fetch)
        let url = try await downloader.install(asset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - 归档来源（运行时二进制走这条路）

    /// 归档来源：下载 → 解包指定成员 → 校验 → 落盘 → 补可执行位。
    ///
    /// `tar` 解出来的文件若丢了可执行位，`Process` 会以一个**完全不提权限**的错误失败，
    /// 所以这行 `chmod` 值得单独钉住。
    func testArchiveSourceExtractsMemberAndMarksExecutable() async throws {
        let payload = Data("runtime-fixture".utf8)
        let staging = base.appendingPathComponent("expected-runtime")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try payload.write(to: staging)
        let digest = try SenseVoiceModelStore.sha256(ofFileAt: staging)

        let asset = SenseVoiceAsset(
            kind: .runtime,
            fileName: "fixture-runtime",
            byteCount: payload.count,
            sha256: digest,
            source: .tarGzMember(urls: [URL(string: "https://example.com/rt.tar.gz")!],
                                 member: "fixture-runtime"),
            license: "MIT",
            attribution: "fixture")

        let fake = FakeFetch()
        fake.behaviour = { _, _ in Data("fake-targz".utf8) }
        let extractor: SenseVoiceDownloader.Extract = { archive, member, directory in
            XCTAssertEqual(member, "fixture-runtime")
            XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path),
                          "解包前归档必须已落盘")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent(member)
            try payload.write(to: output)
            return output
        }

        let downloader = SenseVoiceDownloader(
            paths: SenseVoicePaths(baseDirectory: base), fetch: fake.fetch, extract: extractor)
        let url = try await downloader.install(asset)

        XCTAssertEqual(url.lastPathComponent, "fixture-runtime")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path),
                      "解包出来的二进制必须可执行")
    }

    // MARK: - 运行时的本地来源优先级

    /// 本地拷贝来源：`--from` 优先于一切；装好后 sha 一致则**不报警**。
    func testInstallRuntimeFromExplicitPathCopiesAndVerifies() async throws {
        let real = SenseVoiceAssets.runtime
        // 用真实 sha 会让测试依赖 3 MiB 的 fixture；这里用「摘要不符只警告不阻断」这条
        // 语义来验证拷贝与报告逻辑本身。
        let local = base.appendingPathComponent("my-runtime")
        try TestFiles.makeFile(at: local, bytes: 128, executable: true)

        let downloader = SenseVoiceDownloader(paths: SenseVoicePaths(baseDirectory: base))
        let installation = try await downloader.installRuntime(
            from: local, environment: [:], bundle: .main, executableURL: nil)

        XCTAssertEqual(installation.url.path,
                       base.appendingPathComponent("runtime/\(real.fileName)").path)
        XCTAssertEqual(installation.source, .explicit(path: local.path))
        XCTAssertNotNil(installation.digestMismatch, "自建版本应报告摘要不符")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installation.url.path))
    }

    /// `--from` 指向不存在的文件 → 明确报错，且**不静默改用网络**。
    /// 用户明确指定了路径，却去下载了一个别的版本，是最糟的「看起来很成功」。
    func testInstallRuntimeFailsLoudlyWhenExplicitPathMissing() async throws {
        let downloader = SenseVoiceDownloader(paths: SenseVoicePaths(baseDirectory: base))
        do {
            _ = try await downloader.installRuntime(
                from: base.appendingPathComponent("nope"),
                environment: [:], bundle: .main, executableURL: nil)
            XCTFail("指定的运行时不存在时必须抛错")
        } catch let error as MRError {
            XCTAssertTrue("\(error)".contains("nope"), "错误信息应含该路径：\(error)")
        }
    }

    // MARK: - 来源就是目标：**不得先删后拷**

    /// **`install-runtime` 绝不能销毁一份已经在用的运行时。**
    ///
    /// 两条现实入口都是「来源 == 目标」：
    /// ① 环境变量 `MEETING_RECORDER_SENSEVOICE_RUNTIME` 指向常规落点，然后跑一次
    /// `model install-runtime`；② `model install-runtime --from <常规落点>` ——
    /// 「我就地重装一下」最自然的写法。
    ///
    /// 旧实现在这里是无条件的 `removeItem(target)` + `copyItem(candidate → target)`：
    /// 先把目标删掉，再发现源已经不存在（源**就是**刚被删掉的那个），
    /// 于是抛 `NSCocoaErrorDomain 260`，而**运行时就没了**。
    /// 用户本意是重装，拿到的却是一份资产被静默销毁，错误信息还只说「源文件不存在」。
    func testSelfCopyFromEnvironmentDoesNotDestroyTheInstalledRuntime() async throws {
        let paths = SenseVoicePaths(baseDirectory: base)
        try TestFiles.makeFile(
            at: paths.installedRuntimeURL,
            bytes: SenseVoiceAssets.runtime.byteCount, executable: true)
        let before = try XCTUnwrap(SenseVoiceModelStore.fileSize(at: paths.installedRuntimeURL))

        let downloader = SenseVoiceDownloader(paths: paths)
        let installation = try await downloader.installRuntime(
            from: nil,
            environment: [SenseVoicePaths.runtimeOverrideKey: paths.installedRuntimeURL.path],
            bundle: .main, executableURL: nil)

        XCTAssertEqual(installation.source, .environment(path: paths.installedRuntimeURL.path))
        XCTAssertEqual(SenseVoiceModelStore.fileSize(at: paths.installedRuntimeURL), before,
                       "就地重装不得把目标删掉")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: paths.installedRuntimeURL.path))
    }

    /// 同上，走 `--from <常规落点>` 那条入口。
    func testSelfCopyFromExplicitPathDoesNotDestroyTheInstalledRuntime() async throws {
        let paths = SenseVoicePaths(baseDirectory: base)
        try TestFiles.makeFile(
            at: paths.installedRuntimeURL,
            bytes: SenseVoiceAssets.runtime.byteCount, executable: true)

        let downloader = SenseVoiceDownloader(paths: paths)
        _ = try await downloader.installRuntime(
            from: paths.installedRuntimeURL, environment: [:], bundle: .main, executableURL: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.installedRuntimeURL.path),
                      "就地重装不得把目标删掉")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: paths.installedRuntimeURL.path))
    }

    // MARK: - 自建 / 异版本运行时（门槛是「可执行」，不是字节数）

    /// `--from` 装一份自建运行时 → **状态算就绪**。
    ///
    /// 帮助文本承诺了「自建版本可用」。字节数门槛下这个承诺是空的：装进去也永远是
    /// `sizeMismatch`，`prepare()` 一律拒绝，而 `status` 又会把用户引回
    /// `install-runtime`——不带 `--from` 时用官方副本静默覆盖掉自建件。
    func testSelfBuiltRuntimeBecomesUsableAfterInstall() async throws {
        let local = base.appendingPathComponent("my-build")
        try TestFiles.makeFile(at: local, bytes: 128, executable: true)

        let paths = SenseVoicePaths(baseDirectory: base)
        let downloader = SenseVoiceDownloader(paths: paths)
        let installation = try await downloader.installRuntime(
            from: local, environment: [:], bundle: .main, executableURL: nil)

        XCTAssertNotNil(installation.digestMismatch,
                        "自建件的摘要当然与官方不同——那是要如实报出来的事实，不是拒绝的理由")
        let state = SenseVoiceModelStore(paths: paths).state(environment: [:], bundle: .main)
        XCTAssertEqual(state.status(of: .runtime), .ready, "可执行就算就绪")
        XCTAssertEqual(state.runtimeBinaryURL?.path, paths.installedRuntimeURL.path)
    }

    /// `--from` 指向一个没有可执行位的文件 → 装到落点后要**补上**可执行位。
    /// 「装到落点就能跑」是这条命令的承诺；不补的话装完判成 `notExecutable`，
    /// 用户会以为装失败了。
    func testExplicitSourceWithoutExecutableBitIsInstalledExecutable() async throws {
        let local = base.appendingPathComponent("plain-file")
        try TestFiles.makeFile(at: local, bytes: 64, executable: false)

        let downloader = SenseVoiceDownloader(paths: SenseVoicePaths(baseDirectory: base))
        let installation = try await downloader.installRuntime(
            from: local, environment: [:], bundle: .main, executableURL: nil)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installation.url.path))
    }

    /// 运行时来自哪儿要能报出来——「我这个二进制是从哪来的」是排查错版本的第一问。
    func testInstallRuntimeReportsVendoredSource() async throws {
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        let executable = repo.appendingPathComponent(".build/debug/meeting-recorder")
        try TestFiles.makeFile(at: executable, bytes: 8, executable: true)
        let vendored = repo.appendingPathComponent(
            "vendor/sensevoice-runtime/\(SenseVoiceAssets.runtime.fileName)")
        try TestFiles.makeFile(at: vendored, bytes: 128, executable: true)

        let downloader = SenseVoiceDownloader(paths: SenseVoicePaths(baseDirectory: base))
        let installation = try await downloader.installRuntime(
            from: nil, environment: [:], bundle: .main, executableURL: executable)

        XCTAssertEqual(installation.source, .vendored(path: vendored.path))
        XCTAssertEqual(
            installation.url.path,
            base.appendingPathComponent("runtime/\(SenseVoiceAssets.runtime.fileName)").path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installation.url.path))
    }

    // MARK: - 落盘：原子替换与并发互斥

    /// 目标已存在时替换必须**原子**。旧实现是「先删后移」，
    /// 那个窗口里任何失败都会让一份**已经在用**的资产彻底消失——
    /// 用户只是想换一份，结果是既没有旧的也没有新的。
    func testForceRedownloadReplacesExistingTargetAtomically() async throws {
        let asset = try makeAsset()
        let fake = FakeFetch()
        fake.behaviour = { _, _ in Data("sensevoice-fixture".utf8) }
        let downloader = SenseVoiceDownloader(
            paths: SenseVoicePaths(baseDirectory: base), fetch: fake.fetch)

        let first = try await downloader.install(asset)
        XCTAssertEqual(SenseVoiceModelStore.fileSize(at: first), asset.byteCount)

        let second = try await downloader.install(asset, force: true)
        XCTAssertEqual(second.path, first.path)
        XCTAssertEqual(SenseVoiceModelStore.fileSize(at: second), asset.byteCount)
        XCTAssertEqual(fake.calls.count, 2)

        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: second.deletingLastPathComponent().path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasSuffix(".part") }, "替换后不得残留：\(leftovers)")
    }

    /// 两个下载器同时开工 → 后到的一边**直接报错**，不去写同一个 `.part`。
    ///
    /// 静默排队是更坏的选择：界面上那个进度属于另一个进程，用户看到的是
    /// 「按了没反应」，而两边并发写同一个临时文件还会让成品互相覆盖。
    func testConcurrentDownloadIsRejectedRatherThanCorruptingStaging() async throws {
        let asset = try makeAsset()
        let fake = FakeFetch()
        fake.behaviour = { _, _ in Data("sensevoice-fixture".utf8) }
        let downloader = SenseVoiceDownloader(
            paths: SenseVoicePaths(baseDirectory: base), fetch: fake.fetch)

        // 手工占住那把锁，模拟「另一个进程正在下载」
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let lockPath = base.appendingPathComponent(".download.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThanOrEqual(descriptor, 0, "无法创建测试用锁文件")
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0, "无法取得测试用锁")
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        do {
            _ = try await downloader.install(asset)
            XCTFail("锁被占住时必须抛错，而不是并发写同一个临时文件")
        } catch let error as MRError {
            XCTAssertTrue("\(error)".contains("另一个下载"), "应说清是并发冲突：\(error)")
        }
        XCTAssertTrue(fake.calls.isEmpty, "拿不到锁就不该发起任何下载")
    }

    /// `installAll`：按清单顺序先权重、后 VAD；任一项失败就中断。
    ///
    /// 这里只能验顺序与失败传播——真装要 244 MiB。而这个顺序本身是用户可见的：
    /// 「先下哪个」决定了断网时拿到的是完整的一半还是零。
    func testInstallAllStartsWithTheModelAndPropagatesFailure() async throws {
        let fake = FakeFetch()
        fake.behaviour = { _, _ in throw MRError.io(path: "-", reason: "网络不可达") }

        let downloader = SenseVoiceDownloader(
            paths: SenseVoicePaths(baseDirectory: base), fetch: fake.fetch)
        do {
            _ = try await downloader.installAll()
            XCTFail("全部来源失败必须抛错，不该谎报成功")
        } catch let error as MRError {
            XCTAssertTrue("\(error)".contains(SenseVoiceAssets.model.kind.displayName),
                          "应先处理权重（清单顺序）：\(error)")
        }
        XCTAssertEqual(fake.calls.count, SenseVoiceAssets.model.source.urls.count,
                       "权重失败就该中断，不该继续去动 VAD")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: base.appendingPathComponent("models/\(SenseVoiceAssets.vad.fileName)").path),
                       "权重都没拿到就不该报「装了一半」")
    }
}
