import Foundation
import CryptoKit
import MRCore

/// 单份资产的就地状态。
///
/// 刻意区分 `missing` 与 `sizeMismatch`：前者要下载，后者要**重下**
/// （文件在，但是坏的）。把两者都说成「未就绪」会让用户先去试「是不是网络问题」，
/// 而真正该做的是删掉重来。
///
/// `notExecutable` 只对运行时有意义：文件在、字节数也许对，但丢了可执行位。
/// 它的修复动作是 `chmod +x`，既不是「下载」也不是「重下」——混进上面两种里
/// 都会把用户送去一条白跑的路上。
public enum SenseVoiceAssetStatus: Equatable, Sendable {
    case ready
    case missing
    /// 文件在，但字节数不对（截断 / 半个文件 / 被别的同名文件占位）
    case sizeMismatch(expected: Int, actual: Int)
    /// 文件在，但没有可执行权限。只有运行时会出现（见 `status(of:…)` 的运行时分支）。
    case notExecutable

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// 一句话状态，供 `mr model` 与 GUI 直接打印。
    public var summary: String {
        switch self {
        case .ready:
            return "已就绪"
        case .missing:
            return "未下载"
        case let .sizeMismatch(expected, actual):
            // 用「字节数」而不是「体积」：下载器的同类错误（`validate`）一直这么说，
            // 同一件事在两处叫两个名字，会让「搜报错信息找原因」这件事失效。
            return "字节数不符（期望 \(expected) 字节，实际 \(actual) 字节）"
        case .notExecutable:
            return "存在但不可执行（缺可执行权限）"
        }
    }
}

/// 一次「装好了没有」的完整回答。
public struct SenseVoiceInstallState: Equatable, Sendable {
    /// 逐项状态。键是资产种类，`allCases` 都应在表里。
    public var statuses: [SenseVoiceAsset.Kind: SenseVoiceAssetStatus]
    /// 运行时**实际**会被用到的路径（可能来自 env / 内嵌 / 常规落点）。
    /// 解析不到时为 nil —— 此时 `prepare()` 必须拒绝转写。
    public var runtimeBinaryURL: URL?

    public init(
        statuses: [SenseVoiceAsset.Kind: SenseVoiceAssetStatus],
        runtimeBinaryURL: URL?
    ) {
        self.statuses = statuses
        self.runtimeBinaryURL = runtimeBinaryURL
    }

    /// 全部就绪才叫就绪。**不存在「部分可用」**：缺 VAD 时时间戳没有意义，
    /// 那种稿子比没有稿子更糟——它看起来是好的。
    public var isReady: Bool {
        SenseVoiceAssets.all.allSatisfy { status(of: $0.kind).isReady } && runtimeBinaryURL != nil
    }

    public func status(of kind: SenseVoiceAsset.Kind) -> SenseVoiceAssetStatus {
        statuses[kind] ?? .missing
    }

    /// 尚未就绪的资产，按清单顺序。
    public var pending: [SenseVoiceAsset] {
        SenseVoiceAssets.all.filter { !status(of: $0.kind).isReady }
    }

    /// 未就绪的**可下载**资产（权重 / VAD）。用于「还要下载多少」的计算。
    public var pendingDownloadable: [SenseVoiceAsset] {
        SenseVoiceAssets.downloadable.filter { !status(of: $0.kind).isReady }
    }

    /// 运行时是否缺失（与权重分开报，因为修复动作完全不同）。
    public var runtimeMissing: Bool { !status(of: .runtime).isReady }

    /// 可下载部分的剩余体积，已减去已就绪的。
    public var pendingDownloadByteCount: Int {
        pendingDownloadable.reduce(0) { $0 + $1.byteCount }
    }
}

/// 资产状态的查询与校验。
///
/// **校验分两档，这是刻意的**：
/// - `state()` 只比**存在性 + 字节数**，代价是几次 `stat`，可以在每次 `prepare()` 里跑；
/// - `verify()` 才算**全量 sha256**，代价是读完整个 242 MiB（本机约 0.5~1 s），
///   只在「下载刚完成」和用户显式执行 `mr model verify` 时跑。
///
/// 若把 sha256 放进 `prepare()`，每次转写都要先白读 242 MiB；若完全不校验，
/// 一个字节数被凑巧对上的坏文件就会一路喂进推理。两档分开放才对得上这两个成本。
public struct SenseVoiceModelStore {

    public let paths: SenseVoicePaths

    public init(paths: SenseVoicePaths = SenseVoicePaths()) {
        self.paths = paths
    }

    // MARK: - 快速状态（存在性 + 字节数）

    public func state(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> SenseVoiceInstallState {
        var statuses: [SenseVoiceAsset.Kind: SenseVoiceAssetStatus] = [:]
        for asset in SenseVoiceAssets.all {
            statuses[asset.kind] = status(of: asset, environment: environment, bundle: bundle)
        }
        return SenseVoiceInstallState(
            statuses: statuses,
            runtimeBinaryURL: paths.resolveRuntimeBinary(environment: environment, bundle: bundle))
    }

    public func status(
        of asset: SenseVoiceAsset,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> SenseVoiceAssetStatus {
        // 运行时可能被 env / 内嵌副本满足，所以它的位置走解析而不是固定路径。
        // 这不是特例处理的洁癖——若这里只看 `base/runtime/`，一个通过 env 指定、
        // 实际能正常跑起来的运行时会被报成「未安装」。
        //
        // 而且运行时的就绪判据**不是字节数**，见下面 `runtimeStatus` 的说明。
        if asset.kind == .runtime {
            let location = paths.resolveRuntimeBinary(environment: environment, bundle: bundle)
            let installed = paths.installedRuntimeURL
            let installedSize = Self.fileSize(at: installed)
            return Self.runtimeStatus(
                resolved: location,
                installedExists: installedSize != nil,
                installedIsExecutable: SenseVoicePaths.isUsableExecutable(installed))
        }
        return Self.status(at: paths.url(for: asset), expecting: asset.byteCount)
    }

    /// 运行时的就绪判据：**存在 + 可执行**，不看字节数。
    ///
    /// 权重与 VAD 是**内容资产**——它们是模型本身，字节数就是权威判据，差一个字节都
    /// 不该放行。运行时不一样，它是**工具链二进制**：MIT 许可明确允许重新编译，
    /// `model install-runtime --from <路径>` 这个入口存在的意义就是让用户装一份自己的
    /// 构建。若这里仍然要求字节数精确等于官方那一份的 3,008,104：
    ///
    /// - `--from` 装进去的自建件会**永远**是 `sizeMismatch`，`prepare()` 一律拒绝——
    ///   帮助文本承诺的能力根本不存在；
    /// - 用户还会掉进一个闭环：`status` 说「字节数不符」→ 下一行让你 `install-runtime`
    ///   → 不带 `--from` 时用官方副本**静默覆盖**你刚装的自建件，而且不会告诉你为什么。
    ///
    /// 把门槛降为「能不能跑」，那件事就散开了：「这份是不是官方那一份」是**另一个问题**，
    /// 由 `verify()` 的 sha256 回答，而且它的答案只影响「要不要重装」，不影响「能不能用」。
    public static func runtimeStatus(
        resolved: URL?,
        installedExists: Bool,
        installedIsExecutable: Bool
    ) -> SenseVoiceAssetStatus {
        if resolved != nil { return .ready }
        // 解析不到，但常规落点上确实躺着一个不可执行的文件——修复动作是 chmod，
        // 说得准确一点，别让用户去重下一份 3 MiB。
        if installedExists, !installedIsExecutable { return .notExecutable }
        return .missing
    }

    /// 只看体积。`actual == nil` 表示文件不存在。
    public static func status(at url: URL, expecting byteCount: Int) -> SenseVoiceAssetStatus {
        guard let size = fileSize(at: url) else { return .missing }
        return size == byteCount ? .ready : .sizeMismatch(expected: byteCount, actual: size)
    }

    // MARK: - 全量校验（sha256）

    /// 全量 sha256 校验。返回 `nil` 表示通过；返回字符串表示不符（内容是实际摘要）。
    ///
    /// 用「返回摘要」而不是抛错，是因为调用方（`mr model verify`）需要**汇总多项**
    /// 而不中断——第一项失败就 throw 会让用户修一项跑一次，来回好几轮。
    public func verify(
        _ asset: SenseVoiceAsset,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) throws -> String? {
        let location: URL?
        if asset.kind == .runtime {
            location = paths.resolveRuntimeBinary(environment: environment, bundle: bundle)
        } else {
            location = paths.url(for: asset)
        }
        guard let url = location else { return nil }  // 不存在：由 state() 报，这里不重复
        guard Self.fileExists(at: url) else { return nil }

        let actual = try Self.sha256(ofFileAt: url)
        return actual == asset.sha256 ? nil : actual
    }

    /// 逐项全量校验，返回**未通过**的项。空数组 = 全部通过。
    public func verifyAll(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) throws -> [(asset: SenseVoiceAsset, actual: String)] {
        var failures: [(asset: SenseVoiceAsset, actual: String)] = []
        for asset in SenseVoiceAssets.all {
            if let wrong = try verify(asset, environment: environment, bundle: bundle) {
                failures.append((asset, wrong))
            }
        }
        return failures
    }

    // MARK: - 工具

    public static func fileSize(at url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    public static func fileExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    /// 流式 sha256。整文件读进内存也能算，但 242 MiB 全量驻留是没必要的——
    /// 分块读只占 1 MiB 缓冲，代价与收益不成比例地划算。
    public static func sha256(ofFileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw MRError.io(path: url.path, reason: "无法打开文件计算校验和")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
