import Foundation
import SwiftUI
import MRCore
import MRTranscribe

/// GUI 里的 SenseVoice 资产状态与下载入口。
///
/// **为什么这个视图只在引擎选成 SenseVoice 时出现**：默认引擎是苹果原生，
/// 那批用户跟 SenseVoice 一点关系都没有，不该在他们的顶栏上常驻一行
/// 「还有个模型没下」——那不是信息，是噪音。选中了才出现，是「你要用才告诉你缺什么」。
///
/// **为什么状态必须现取、不能缓存**：资产是可以在别处被改掉的——用户可能在终端里
/// `mr model remove --yes`，也可能装完模型又切回苹果引擎。界面若拿一份构造时的快照，
/// 就会显示一个早已不成立的状态，然后转写时以完全不同的理由失败。
/// 所以每次出现、每次切换引擎都重新读一次磁盘。
@MainActor
final class SenseVoiceAssetsModel: ObservableObject {

    /// 下载进度 / 失败。刻意不叫 `state`——那是资产状态，两者要分得开。
    enum Phase: Equatable {
        case idle
        /// 正在下载某一项。`fraction` 是该**单项**的进度（0…1）。
        case downloading(assetName: String, fraction: Double)
        case failed(String)
    }

    @Published private(set) var state: SenseVoiceInstallState
    @Published private(set) var phase: Phase = .idle

    private let paths: SenseVoicePaths
    private let store: SenseVoiceModelStore
    private let downloader: SenseVoiceDownloader
    private let environment: [String: String]
    private let bundle: Bundle

    /// 「把资产装上」这一步。默认走真实的下载 + 装运行时。
    ///
    /// 抽成可注入闭包的理由与 `SessionTranscriber.Configuration.makeDriver` 完全一样：
    /// 这条**成功**路径要动 242 MiB 固定 sha256 的资产——真跑要联网，用假数据又过不了
    /// 摘要校验，不抽的话「装好之后界面变成什么样」会变成一段永远没被执行过的代码。
    /// 而那恰恰是最该被钉住的一处：按钮要消失、进度要清干净、状态要重读。
    private let installAction: (() async throws -> Void)?

    /// 上一次上报给界面的进度百分比。用来把更新压到「每变化 1% 一次」——
    /// 下载一个 242 MiB 的文件会回调几千次，每次都发一个 `objectWillChange`
    /// 会把主线程刷满，界面反而卡。
    private var lastReportedPercent = -1

    init(
        paths: SenseVoicePaths = SenseVoicePaths(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        downloader: SenseVoiceDownloader? = nil,
        installAction: (() async throws -> Void)? = nil
    ) {
        self.paths = paths
        self.environment = environment
        self.bundle = bundle
        self.store = SenseVoiceModelStore(paths: paths)
        self.downloader = downloader ?? SenseVoiceDownloader(paths: paths)
        self.installAction = installAction
        self.state = store.state(environment: environment, bundle: bundle)
    }

    // MARK: - 状态

    var isReady: Bool { state.isReady }

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    /// 主状态行。
    var statusText: String {
        let name = TranscriptionEngine.senseVoice.displayName
        if state.isReady { return "\(name) 模型已就绪" }
        let missing = state.pending.map(\.kind.displayName).joined(separator: "、")
        return "\(name) 未就绪：缺 \(missing)"
    }

    /// 第二行：还要下多少、运行时怎么来、装在哪。就绪时为 nil。
    ///
    /// 体积量级写在这里而不是按钮上，是因为它是**用户决定要不要下**的依据；
    /// 按钮上只该有一个动词。
    var detailText: String? {
        guard !state.isReady else { return nil }
        var parts: [String] = []
        if state.pendingDownloadByteCount > 0 {
            parts.append("需联网下载约 \(Self.miB(state.pendingDownloadByteCount)) MiB")
        }
        if state.runtimeMissing {
            // 体积直接用资产清单里的 `humanSize`（2.9 MiB，1 MiB = 1,048,576 口径）。
            // 这里早先用 `miB()` 四舍五入成整数，于是同一份二进制在
            // `model status` 显示 2.9 MiB、界面上显示 3 MiB——同一个事实两个出处，
            // 正是 `SenseVoiceAsset` 那句注释明确要避免的。
            parts.append("推理运行时 \(SenseVoiceAssets.runtime.humanSize)"
                + "（通常可从本机副本装上，不必联网）")
        }
        parts.append("落点：\(paths.baseDirectory.path)")
        return parts.joined(separator: "｜")
    }

    /// 失败信息。**不用弹窗**：一次失败不该打断用户手上的事，而这条信息
    /// 会一直留在原地，直到下一次操作。
    var failureText: String? {
        if case let .failed(message) = phase { return message }
        return nil
    }

    /// 下载进度（0…1），非下载中为 nil。
    var progressFraction: Double? {
        if case let .downloading(_, fraction) = phase { return fraction }
        return nil
    }

    /// 单个资产下载中的进度文案，例如「正在下载 权重 42%」。
    var progressText: String? {
        if case let .downloading(assetName, fraction) = phase {
            return "正在下载 \(assetName) \(Int(fraction * 100))%"
        }
        return nil
    }

    /// 就绪时**不给**下载按钮：一个按下去什么也不会发生的按钮比没有按钮更糟。
    var canDownload: Bool { !state.isReady && !isDownloading }

    var downloadButtonTitle: String {
        "下载模型（约 \(Self.miB(SenseVoiceAssets.downloadableByteCount)) MiB）"
    }

    /// 跑全量 sha256 的成本（读 242 MiB，本机约 0.5~1 s），所以状态查询只比字节数。
    func refresh() {
        state = store.state(environment: environment, bundle: bundle)
    }

    // MARK: - 下载

    /// 下载权重 + VAD，然后装运行时。返回是否最终就绪。
    ///
    /// 顺序与 CLI 的 `model download` **刻意一致**：权重体积大、要联网；
    /// 运行时通常能从本机副本装上，放在后面可以让「网络很差」的用户至少先把
    /// 那 3 MiB 拿到手（权重失败也不会把运行时一起拖垮）。
    @discardableResult
    func startDownload() async -> Bool {
        guard !isDownloading else { return state.isReady }
        lastReportedPercent = -1
        phase = .downloading(assetName: SenseVoiceAssets.model.kind.displayName, fraction: 0)

        do {
            if let installAction {
                try await installAction()
            } else {
                _ = try await downloader.installAll { [weak self] progress in
                    // 回调发生在网络层自己的队列上，**必须**跳回主线程再改 `@Published`。
                    Task { @MainActor in self?.record(progress) }
                }
                // 顺序与 CLI 的 `model download` 一致：权重先、运行时后。
                _ = try await downloader.installRuntime(
                    from: nil, environment: environment, bundle: bundle)
            }
            phase = .idle
        } catch {
            phase = .failed(Self.describe(error))
        }

        refresh()
        return state.isReady
    }

    /// 把错误渲染成给用户看的文字。
    ///
    /// 不能直接 `"\(error)"`：本项目自己的 `MRError` 是 `CustomStringConvertible`，
    /// 那句话很好；但系统错误（`CocoaError`、`URLError`）是 `LocalizedError`，
    /// `"\(error)"` 对它们只会给出 `Boom()` 这种类型名，用户拿不到任何信息。
    /// 反过来只用 `localizedDescription` 也不行——对 `MRError` 它会退化成
    /// 「The operation couldn't be completed…」。两个都试，各取所长。
    private static func describe(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return "\(error)"
    }

    private func record(_ progress: SenseVoiceDownloader.Progress) {
        guard case .downloading = phase else { return }   // 已经被取消/失败，迟到的进度不该复活它
        let fraction = progress.expectedBytes > 0
            ? min(1, max(0, Double(progress.receivedBytes) / Double(progress.expectedBytes)))
            : 0
        let percent = Int(fraction * 100)
        guard percent != lastReportedPercent else { return }
        lastReportedPercent = percent
        phase = .downloading(assetName: progress.kind.displayName, fraction: fraction)
    }

    private static func miB(_ bytes: Int) -> Int {
        Int((Double(bytes) / 1_048_576).rounded())
    }
}

/// 顶栏第二行的 SenseVoice 资产区。
///
/// 抽成独立视图（而不是塞进 `RecordingBarView` 的 HStack）有两个理由：
/// 它渲染的是一个**可变高度的状态块**（状态 + 说明 + 进度条），挤在一行里会把
/// 那一排全局偏好控件推来推去；以及它能脱离整条顶栏单独做渲染冒烟
/// （顶栏里的标题输入框会被 `ImageRenderer` 报 `FocusState` 警告，不该混进来）。
struct SenseVoiceAssetsView: View {

    var engine: TranscriptionEngine

    @StateObject private var model: SenseVoiceAssetsModel

    init(engine: TranscriptionEngine, model: SenseVoiceAssetsModel? = nil) {
        self.engine = engine
        _model = StateObject(wrappedValue: model ?? SenseVoiceAssetsModel())
    }

    /// 该不该显示。抽成静态函数，是为了让「默认用户不被这行打扰」这件事
    /// 能被断言到，而不是只能靠截图目测。
    static func isVisible(for engine: TranscriptionEngine) -> Bool {
        engine == .senseVoice
    }

    var body: some View {
        if Self.isVisible(for: engine) {
            row
        } else {
            EmptyView()
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: model.isReady ? "checkmark.seal.fill" : "arrow.down.circle")
                .foregroundStyle(model.isReady ? Color.green : Color.orange)
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(model.isReady ? .secondary : .primary)

                if let progressText = model.progressText {
                    Text(progressText).font(.caption2).foregroundStyle(.secondary)
                } else if let detail = model.detailText {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let failure = model.failureText {
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 8)

            if let fraction = model.progressFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
            }

            if model.canDownload {
                Button(model.downloadButtonTitle) {
                    Task { await model.startDownload() }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        // 每次出现就重读一次磁盘：资产可能在终端里被删过，也可能刚被装好。
        .task(id: engine) { model.refresh() }
    }
}
