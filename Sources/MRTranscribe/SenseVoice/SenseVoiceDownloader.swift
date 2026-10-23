import Foundation
import Darwin
import MRCore

/// 资产下载 / 安装的编排。
///
/// 三条纪律写在这里，而不是散在调用点上：
///
/// 1. **先落 `.part`，校验通过才改名。** 直接把字节写进目标文件名，会让「下载中途失败」
///    在磁盘上留下一个**看起来已经装好**的文件——而体积检查恰好又能被下一次下载
///    的断点续传掩盖。改成两步之后，目标路径要么不存在，要么是一份校验过的完整文件。
/// 2. **体积与 sha256 都要过。** 只比体积会放过同长度的坏文件；只比摘要则在文件被截断时
///    给出一个看不出所以然的摘要差异。两者都做，错误信息才能告诉用户到底哪里不对。
/// 3. **多源按顺序试，全失败才报错，且把试过的地址全列出来。** 只说「下载失败」，
///    用户无法判断是镜像挂了、还是自己网络不通、还是地址写错了。
public struct SenseVoiceDownloader {

    /// 抓取一个远端地址到本地文件。测试注入用。
    public typealias Fetch = (
        _ remote: URL,
        _ destination: URL,
        _ onProgress: ((Int64) -> Void)?
    ) async throws -> Void

    /// 从 tar.gz 里抽出一个成员，返回抽取后的文件路径。测试注入用。
    public typealias Extract = (
        _ archive: URL,
        _ member: String,
        _ directory: URL
    ) throws -> URL

    /// 一次下载的进度。`receivedBytes` 是**单个资产**内的累计字节。
    public struct Progress: Equatable, Sendable {
        public var kind: SenseVoiceAsset.Kind
        public var receivedBytes: Int64
        public var expectedBytes: Int
        public var source: URL?
    }

    /// 运行时的安装来源。要报出来——「你的二进制是从哪来的」是排查错版本的第一问。
    public enum RuntimeSource: Equatable, Sendable {
        case explicit(path: String)
        case environment(path: String)
        case bundled(path: String)
        case vendored(path: String)
        case downloaded(URL)

        public var description: String {
            switch self {
            case let .explicit(path):    return "指定路径 \(path)"
            case let .environment(path): return "环境变量指定 \(path)"
            case let .bundled(path):     return ".app 内嵌 \(path)"
            case let .vendored(path):    return "仓库 vendor 副本 \(path)"
            case let .downloaded(url):   return "在线下载 \(url.absoluteString)"
            }
        }
    }

    public struct RuntimeInstallation: Equatable, Sendable {
        public var url: URL
        public var source: RuntimeSource
        /// nil = sha256 校验通过；非 nil = 实际摘要（**不阻断**，只如实报告）
        public var digestMismatch: String?
    }

    public let paths: SenseVoicePaths
    private let fetch: Fetch
    private let extract: Extract

    public init(
        paths: SenseVoicePaths = SenseVoicePaths(),
        fetch: @escaping Fetch = { remote, destination, onProgress in
            // 显式写成一个闭包而不是直接传 `SenseVoiceHTTPFetch.download`：
            // 后者带默认参数，作为函数值引用时会与类型不匹配。
            try await SenseVoiceHTTPFetch.download(
                from: remote, to: destination, onProgress: onProgress)
        },
        extract: @escaping Extract = SenseVoiceTarGz.extractMember
    ) {
        self.paths = paths
        self.fetch = fetch
        self.extract = extract
    }

    // MARK: - 权重 / VAD

    /// 下载一份资产到常规落点。
    ///
    /// 已就绪且 `force == false` 时**直接返回，不发起任何网络请求**——
    /// 让「再跑一次 download」是安全的、不会重复搬 244 MiB。
    @discardableResult
    public func install(
        _ asset: SenseVoiceAsset,
        force: Bool = false,
        onProgress: ((Progress) -> Void)? = nil
    ) async throws -> URL {

        let target = paths.url(for: asset)

        if !force, SenseVoiceModelStore.status(at: target, expecting: asset.byteCount).isReady {
            return target
        }

        // 一次下载独占一把锁。CLI 与 GUI 都可能被点，而两个下载器写同一个 `.part`
        // 会互相踩：先完成者的成品可能被后者按「先删后移」的路径删掉，
        // 表现是随机失败或「下载完但状态是未下载」，排查成本很高。
        //
        // 用 `flock` 而不是给临时文件加随机名是有意的：随机名能避免互相踩，
        // 但下载中途崩溃会在磁盘上留下一个 242 MiB 的孤儿文件，没人知道该不该删。
        // flock 还有个好处——进程退出即释放，不会留下陈旧的锁文件把后来者挡在门外。
        let lock = try acquireDownloadLock()
        defer { releaseDownloadLock(lock) }

        try makeParentDirectory(of: target)

        var attempts: [String] = []

        for remote in asset.source.urls {
            let staging = stagingURL(for: asset, remote: remote)
            do {
                try await fetch(remote, staging, { received in
                    onProgress?(Progress(kind: asset.kind, receivedBytes: received,
                                         expectedBytes: asset.byteCount, source: remote))
                })

                switch asset.source {
                case .file:
                    try validate(staging, against: asset, source: remote)
                    try moveIntoPlace(staging, at: target, asset: asset)
                case let .tarGzMember(_, member):
                    let workDirectory = staging.deletingLastPathComponent()
                        .appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: workDirectory) }
                    let extracted = try extract(staging, member, workDirectory)
                    try validate(extracted, against: asset, source: remote)
                    try moveIntoPlace(extracted, at: target, asset: asset)
                    // 抽出来的成员必须补上可执行位。归档里的权限位一般是对的，
                    // 但这行保证「不管来源怎么来的，到手都能跑」。
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o755], ofItemAtPath: target.path)
                }

                cleanupStaging(staging, for: asset)
                return target
            } catch {
                cleanupStaging(staging, for: asset)
                attempts.append("\(remote.absoluteString) → \(error)")
            }
        }

        throw MRError.io(
            path: target.path,
            reason: "\(asset.kind.displayName)（\(asset.humanSize)）下载失败，已试过 "
                + "\(asset.source.urls.count) 个地址：\n"
                + attempts.map { "    · \($0)" }.joined(separator: "\n")
                + "\n提示：本机直连 huggingface.co 常返回 502，镜像 hf-mirror.com 是第一顺位；"
                + "\n      若两者都超时，而 curl / 浏览器能访问，多半是代理没生效——"
                + "本程序会读环境变量 HTTPS_PROXY，可以这样重试："
                + "\n        HTTPS_PROXY=http://127.0.0.1:7897 meeting-recorder model download")
    }

    /// 依次安装全部下载型资产（权重 + VAD），返回逐项结果。
    public func installAll(
        force: Bool = false,
        onProgress: ((Progress) -> Void)? = nil
    ) async throws -> [SenseVoiceAsset] {
        var done: [SenseVoiceAsset] = []
        for asset in SenseVoiceAssets.downloadable {
            try await install(asset, force: force, onProgress: onProgress)
            done.append(asset)
        }
        return done
    }

    // MARK: - 运行时二进制

    /// 安装运行时二进制到常规落点。
    ///
    /// 来源优先级（第一条命中即用）：
    /// 1. `explicit`（CLI `--from`）
    /// 2. 环境变量 `MEETING_RECORDER_SENSEVOICE_RUNTIME`
    /// 3. `.app` 内嵌副本
    /// 4. 仓库 `vendor/sensevoice-runtime/`（`swift run` 开发态）
    /// 5. 在线下载 release 归档
    ///
    /// 前四条都是**本地拷贝**，所以绝大多数情况下这一步不需要网络——
    /// 而 GitHub release 在国内经常不通，把 3 MiB 的东西做成网络依赖是不划算的。
    @discardableResult
    public func installRuntime(
        from explicit: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        executableURL: URL? = Bundle.main.executableURL,
        onProgress: ((Progress) -> Void)? = nil
    ) async throws -> RuntimeInstallation {

        let asset = SenseVoiceAssets.runtime
        let target = paths.installedRuntimeURL

        var localCandidates: [(RuntimeSource, URL)] = []
        if let explicit { localCandidates.append((.explicit(path: explicit.path), explicit)) }
        if let raw = environment[SenseVoicePaths.runtimeOverrideKey], !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            localCandidates.append((.environment(path: url.path), url))
        }
        if let bundled = paths.bundledRuntimeURL(bundle: bundle) {
            localCandidates.append((.bundled(path: bundled.path), bundled))
        }
        if let vendored = paths.vendoredRuntimeURL(executableURL: executableURL) {
            localCandidates.append((.vendored(path: vendored.path), vendored))
        }

        // 本地来源：直接拷贝 + 校验。不需要先落 .part —— 源文件本来就在本地，
        // 但拷贝必须**原子**：见 `copyAtomically` 与下面那条「来源就是目标」的特例。
        for (source, candidate) in localCandidates {
            guard SenseVoiceModelStore.fileExists(at: candidate) else {
                if case .explicit = source {
                    throw MRError.io(path: candidate.path,
                                     reason: "指定的运行时二进制不存在：\(candidate.path)")
                }
                continue
            }

            // 「来源就是目标」时**绝不能拷**。
            //
            // 两条现实入口：环境变量 `MEETING_RECORDER_SENSEVOICE_RUNTIME` 指向常规落点，
            // 然后跑一次 `model install-runtime`；或者 `model install-runtime --from <常规落点>`——
            // 后者是「我就地重装一下」最自然的写法。
            //
            // 早先的写法在这里是无条件的 `removeItem(target)` + `copyItem(candidate → target)`：
            // 先把目标删掉，再发现源已经不存在（源**就是**那个被删掉的目标），
            // 于是抛 `NSCocoaErrorDomain 260`，而**运行时就没了**。用户本意是重装，
            // 拿到的却是一份资产被静默销毁，错误信息还只说「源文件不存在」。
            if candidate.standardizedFileURL == target.standardizedFileURL {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: target.path)
                let mismatch = try verifyQuietly(target, against: asset)
                return RuntimeInstallation(url: target, source: source, digestMismatch: mismatch)
            }

            try makeParentDirectory(of: target)
            try copyAtomically(from: candidate, to: target)

            let mismatch = try verifyQuietly(target, against: asset)
            return RuntimeInstallation(url: target, source: source, digestMismatch: mismatch)
        }

        // 最后才是网络。走到这里说明既没有内嵌、也没有 vendor 副本。
        try await install(asset, force: true, onProgress: onProgress)
        return RuntimeInstallation(
            url: target, source: .downloaded(asset.source.urls[0]),
            digestMismatch: nil)
    }

    // MARK: - 校验与落盘

    /// 体积 + sha256 双重校验。任何一项不过都抛错——这是「半成品不得落盘」的执行点。
    private func validate(_ file: URL, against asset: SenseVoiceAsset, source: URL) throws {
        guard let size = SenseVoiceModelStore.fileSize(at: file) else {
            throw MRError.io(path: file.path, reason: "下载后文件不存在")
        }
        guard size == asset.byteCount else {
            throw MRError.io(
                path: file.path,
                reason: "\(asset.kind.displayName) 字节数不符：期望 \(asset.byteCount)，实际 \(size)"
                    + "（来源 \(source.absoluteString)）。下载可能被中断或源已更新。")
        }
        let digest = try SenseVoiceModelStore.sha256(ofFileAt: file)
        guard digest == asset.sha256 else {
            throw MRError.io(
                path: file.path,
                reason: "\(asset.kind.displayName) sha256 不符：期望 \(asset.sha256)，实际 \(digest)"
                    + "（来源 \(source.absoluteString)）。文件已损坏或不是预期的版本。")
        }
    }

    private func verifyQuietly(_ file: URL, against asset: SenseVoiceAsset) throws -> String? {
        let digest = try SenseVoiceModelStore.sha256(ofFileAt: file)
        return digest == asset.sha256 ? nil : digest
    }

    /// 同目录内改名是原子的（同一文件系统），所以不会出现「一半新一半旧」的可见状态。
    ///
    /// 目标已存在时用 `replaceItemAt` 而不是「先删后移」。差别不在性能，在**失败时的后果**：
    /// 先删后移在两次调用之间留了一个「目标不存在」的窗口，这个窗口里任何失败
    /// （磁盘满、权限、源在途中消失）都会让**已经在用**的那份资产彻底消失。
    /// 用户只是想换一份，结果是既没有旧的也没有新的。
    private func moveIntoPlace(_ source: URL, at target: URL, asset: SenseVoiceAsset) throws {
        try makeParentDirectory(of: target)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: source)
            } else {
                try FileManager.default.moveItem(at: source, to: target)
            }
        } catch {
            throw MRError.io(path: target.path,
                             reason: "\(asset.kind.displayName) 落盘失败：\(error.localizedDescription)")
        }
    }

    /// 本地拷贝进常规落点：先拷到同目录的临时名，再原子换上去。
    ///
    /// 分两步的理由与 `moveIntoPlace` 一样——拷贝本身可能拷到一半就失败（磁盘满、
    /// 源被外部删掉），直接拷进目标会让目标被**半个文件**占住，
    /// 而字节数恰好不对的半个文件正是最难判断的一种坏法。
    private func copyAtomically(from source: URL, to target: URL) throws {
        let incoming = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).incoming-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.copyItem(at: source, to: incoming)
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            throw MRError.io(path: target.path,
                             reason: "复制 \(source.path) 失败：\(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: incoming) }
        try moveIntoPlace(incoming, at: target, asset: SenseVoiceAssets.runtime)
        // 补可执行位。`--from` 允许指向任何存在的东西（用户可能刚从别处下载了一份、
        // 或者从 tar 里手抽出来丢了权限位），而「装到落点就能跑」是这个命令的承诺。
        // 不补的话，装完后门槛判成 `notExecutable`，用户会以为装失败了。
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: target.path)
    }

    /// 拿下载锁。拿不到就直接失败——**不排队等**。
    ///
    /// 等待在这里是有害的：用户在 GUI 上点了下载，界面上什么都不会变（因为进度属于
    /// 另一个进程），看起来就是「按了没反应」。直接说「已经有另一个下载在跑」，
    /// 用户至少知道自己刚才那一下去了哪里。
    private func acquireDownloadLock() throws -> Int32 {
        let directory = paths.baseDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MRError.io(path: directory.path,
                             reason: "无法创建资产目录：\(error.localizedDescription)")
        }
        let lockPath = directory.appendingPathComponent(".download.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw MRError.io(path: lockPath,
                             reason: "无法创建下载锁：\(String(cString: strerror(errno)))")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw MRError.io(path: lockPath,
                             reason: "已经有另一个下载在进行（可能来自另一个终端，或界面上的按钮）。"
                                 + "等它结束后重试——并发写同一份资产的临时文件会让两边都拿到坏文件。")
        }
        return descriptor
    }

    private func releaseDownloadLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private func makeParentDirectory(of url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MRError.io(path: directory.path,
                             reason: "无法创建目录：\(error.localizedDescription)")
        }
    }

    /// `.part` 放在**目标同目录**，不是系统临时目录。
    /// 跨文件系统的移动是「拷贝 + 删源」，既慢又可能在磁盘满时留下半个文件。
    private func stagingURL(for asset: SenseVoiceAsset, remote: URL) -> URL {
        _ = remote
        let suffix = asset.source.isArchive ? ".tar.gz" : ""
        return paths.url(for: asset).deletingLastPathComponent()
            .appendingPathComponent(".\(stagingName(for: asset))\(suffix).part")
    }

    /// 临时文件名只取 `fileName` 的**最后一段**。
    ///
    /// 直接把 `fileName` 拼进临时名会出事：若它带子目录（`a/b.bin`），拼出来的是
    /// `.a/b.bin.part`——凭空多出一层没人创建过的目录，`fetch` 在写临时文件时就失败了，
    /// 而错误会指向目标文件，看的人只会觉得「下载器坏了」。临时文件本来也不需要
    /// 复刻目标的目录结构，它只需要和目标**同目录**（保证 rename 是原子的）。
    private func stagingName(for asset: SenseVoiceAsset) -> String {
        (asset.fileName as NSString).lastPathComponent
    }

    private func cleanupStaging(_ staging: URL, for asset: SenseVoiceAsset) {
        try? FileManager.default.removeItem(at: staging)
        // 归档路径与小份路径可能不同名（带 .tar.gz），两个都清一遍，避免残留
        let sibling = paths.url(for: asset).deletingLastPathComponent()
            .appendingPathComponent(".\(stagingName(for: asset)).part")
        if sibling != staging { try? FileManager.default.removeItem(at: sibling) }
    }
}
