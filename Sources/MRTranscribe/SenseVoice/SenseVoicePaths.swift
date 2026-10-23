import Foundation

/// SenseVoice 资产的落点，以及**运行时二进制的解析顺序**。
///
/// 为什么需要一个类型而不是几个 `static let` 路径：所有落点测试都要能指向临时目录。
/// 写死 `Application Support` 的代码没法在无副作用的前提下被验证（会污染真实机器），
/// 于是「路径对不对」这件事永远只能靠肉眼看。
///
/// 构造它是**零副作用**的：这里不建目录、不写文件。一个在 `init` 里创建目录的类型，
/// 会让「只是查一下状态」也变成一次磁盘写入。落盘由下载器显式负责。
public struct SenseVoicePaths: Sendable {

    /// 覆盖运行时二进制的环境变量名。
    ///
    /// 存在的理由只有一个：让端到端验证能指向一份**已验证过的**二进制，
    /// 而不必先把它装到 Application Support。属于调试与测试通道，不是常规用法。
    public static let runtimeOverrideKey = "MEETING_RECORDER_SENSEVOICE_RUNTIME"

    /// `.app` 内嵌副本相对于 bundle 资源目录的位置。
    public static let bundledSubdirectory = "sensevoice"

    public let baseDirectory: URL

    public init(baseDirectory: URL = SenseVoicePaths.defaultBaseDirectory) {
        self.baseDirectory = baseDirectory
    }

    /// 默认落点：`~/Library/Application Support/meeting-recorder/sensevoice`。
    ///
    /// 与录音库（`~/Documents/MeetingRecorder`）**刻意分开**：模型是可以随时重下的
    /// 缓存型资产，不该混在用户要归档、要备份的会议录音里——那会让「备份会议」凭空
    /// 多出 244 MiB 的模型文件。
    public static var defaultBaseDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("meeting-recorder/sensevoice", isDirectory: true)
    }

    public var modelsDirectory: URL {
        baseDirectory.appendingPathComponent("models", isDirectory: true)
    }

    public var runtimeDirectory: URL {
        baseDirectory.appendingPathComponent("runtime", isDirectory: true)
    }

    /// 三份资产各自的落盘位置。
    ///
    /// 注意运行时这里给的是**常规落点**，不一定是实际会被用到的那个——
    /// 实际用哪个由 `resolveRuntimeBinary` 决定（env / 常规落点 / `.app` 内嵌）。
    public func url(for asset: SenseVoiceAsset) -> URL {
        switch asset.kind {
        case .model, .vad: return modelsDirectory.appendingPathComponent(asset.fileName)
        case .runtime:     return runtimeDirectory.appendingPathComponent(asset.fileName)
        }
    }

    /// 常规落点上的运行时（不看 env，也不看 bundle）。`mr model install-runtime` 的写入目标。
    public var installedRuntimeURL: URL {
        url(for: SenseVoiceAssets.runtime)
    }

    /// `.app` 内嵌副本的位置（`.app/Contents/Resources/sensevoice/<名字>`）。
    ///
    /// 打包时嵌入一份的好处是：**装机后不必再联网就能拿到运行时**。
    /// 权重（244 MiB）不嵌入——那会把 .app 撑成 250 MB 的包，且塞进版本库不合适。
    public func bundledRuntimeURL(bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        return resources
            .appendingPathComponent(Self.bundledSubdirectory, isDirectory: true)
            .appendingPathComponent(SenseVoiceAssets.runtime.fileName)
    }

    /// 解析实际使用的运行时二进制。**第一条命中即用**：
    ///
    /// 1. 环境变量 `MEETING_RECORDER_SENSEVOICE_RUNTIME`
    /// 2. 常规落点 `~/Library/Application Support/meeting-recorder/sensevoice/runtime/`
    /// 3. `.app` 内嵌 `Contents/Resources/sensevoice/`
    ///
    /// 每条都要求**存在且可执行**。只判「存在」是不够的：`tar` 解包出来的文件若丢了
    /// 可执行位，`Process` 会以一个含义模糊的错误失败，而错误信息里不会提到权限。
    ///
    /// 坏掉的 env 会被**忽略**而不是让整条链路不可用——用错一个调试开关就把引擎彻底打死，
    /// 是最没必要的自伤。
    public func resolveRuntimeBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL? {
        if let raw = environment[Self.runtimeOverrideKey], !raw.isEmpty {
            let candidate = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            if Self.isUsableExecutable(candidate) { return candidate }
        }
        if Self.isUsableExecutable(installedRuntimeURL) { return installedRuntimeURL }
        if let bundled = bundledRuntimeURL(bundle: bundle), Self.isUsableExecutable(bundled) {
            return bundled
        }
        return nil
    }

    /// 环境变量被设置过、但指向的东西不可用——`mr model` 需要把这件事说出来。
    ///
    /// 静默忽略一个配错的环境变量是最难排查的一类问题：用户改了 env，
    /// 却发现程序行为毫无变化，也没有任何提示。
    public func ignoredRuntimeOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = environment[Self.runtimeOverrideKey], !raw.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        return Self.isUsableExecutable(candidate) ? nil : raw
    }

    static func isUsableExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// 从可执行文件所在目录**向上**找仓库内的 vendor 副本。
    ///
    /// 存在的理由：`swift run` 开发态既没有 `.app` 内嵌副本，也没装到 Application Support，
    /// 而仓库里 `vendor/sensevoice-runtime/` 本来就有一份（见 `scripts/fetch-sensevoice-runtime.sh`）。
    /// 从 `.build/debug/meeting-recorder` 上溯两层就是包根，所以这是可靠且零配置的。
    public func vendoredRuntimeURL(
        executableURL: URL? = Bundle.main.executableURL,
        maxAscend: Int = 6
    ) -> URL? {
        guard var directory = executableURL?.deletingLastPathComponent() else { return nil }
        let relative = "vendor/sensevoice-runtime/\(SenseVoiceAssets.runtime.fileName)"
        for _ in 0..<maxAscend {
            let candidate = directory.appendingPathComponent(relative)
            if Self.isUsableExecutable(candidate) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }   // 到根了
            directory = parent
        }
        return nil
    }
}
