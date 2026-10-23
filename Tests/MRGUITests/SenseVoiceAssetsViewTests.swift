import XCTest
import SwiftUI
import CoreGraphics
@testable import MRGUI
import MRTranscribe
import MRCore

/// SenseVoice 资产状态区（顶栏第二行）。
///
/// 这一块的核心判据只有两条，且都不是「渲染没报错」：
/// 1. **默认用户不受打扰**——引擎是苹果原生时，这一行必须**一个像素都不画**。
/// 2. **缺什么、要下多少、去哪下**必须明确，且就绪后下载按钮要消失
///    （一个按下去什么也不会发生的按钮比没有按钮更糟）。
///
/// 资产全部指到临时目录：否则用例结论会随「这台机器装没装过模型」而变，
/// 那种用例没有价值。
@MainActor
final class SenseVoiceAssetsViewTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-gui-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        base = nil
    }

    // MARK: - 夹具

    private var paths: SenseVoicePaths { SenseVoicePaths(baseDirectory: base) }

    /// 用**稀疏文件**凑出精确字节数。
    ///
    /// 门槛判的是精确字节数，所以这里不能随便造个占位文件（242 MiB 也不能真写满盘）；
    /// `truncate` 出来的稀疏文件创建即完成、不占实际块。
    private func installSparseAssets() throws {
        for asset in SenseVoiceAssets.all {
            let url = paths.url(for: asset)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(asset.byteCount))
            try handle.close()
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: paths.installedRuntimeURL.path)
    }

    private func makeModel(
        installAction: (() async throws -> Void)? = nil,
        downloader: SenseVoiceDownloader? = nil
    ) -> SenseVoiceAssetsModel {
        SenseVoiceAssetsModel(
            paths: paths, environment: [:], bundle: .main,
            downloader: downloader, installAction: installAction)
    }

    // MARK: - G02：默认用户不被这行打扰

    /// 引擎 = 苹果原生 → 这一行不该出现在界面上。
    ///
    /// 只断言 `isVisible == false` 是不够的（那只证明了一个布尔值），所以下面
    /// 还把它真的渲染一遍、逐像素确认画布是**全透明**的——「EmptyView 确实什么都没画」
    /// 才是这条用例要守的东西。
    func testRowIsInvisibleForDefaultEngine() throws {
        XCTAssertFalse(SenseVoiceAssetsView.isVisible(for: .apple))
        XCTAssertTrue(SenseVoiceAssetsView.isVisible(for: .senseVoice))

        let image = try render(engine: .apple, model: makeModel())
        XCTAssertTrue(isFullyTransparent(image), "引擎=apple 时这一行画出了内容")
    }

    /// 引擎 = SenseVoice → 渲染出非空位图。
    func testRowRendersForSenseVoiceEngine() throws {
        let image = try render(engine: .senseVoice, model: makeModel())
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
        XCTAssertFalse(isFullyTransparent(image), "引擎=sensevoice 时这一行什么都没画")
    }

    // MARK: - G03 / G04：状态文案与下载入口

    /// 未就绪 → 状态行点名缺什么；说明行给出**体积量级**与落点；有下载入口。
    func testNotReadyStateNamesWhatIsMissingAndHowBig() {
        let model = makeModel()

        XCTAssertFalse(model.isReady)
        let status = model.statusText
        XCTAssertTrue(status.contains("未就绪"), "应明确说未就绪：\(status)")
        for kind in SenseVoiceAsset.Kind.allCases {
            XCTAssertTrue(status.contains(kind.displayName),
                          "应点名缺的是「\(kind.displayName)」：\(status)")
        }

        let detail = model.detailText ?? ""
        XCTAssertTrue(detail.contains("244"), "应给出下载体积量级（约 244 MiB）：\(detail)")
        XCTAssertTrue(detail.contains(base.path), "应给出落点路径：\(detail)")

        // 运行时体积必须与 `model status` 同口径（`SenseVoiceAsset.humanSize`）。
        // 早先这里走的是 `miB()` 四舍五入成整数，于是同一份二进制在 CLI 显示
        // 2.9 MiB、界面上显示 3 MiB——同一个事实两个出处。这条断言就是为了
        // 钉住那次统一：界面与 CLI 必须引用**同一个** humanSize，不得各自取整。
        XCTAssertTrue(detail.contains(SenseVoiceAssets.runtime.humanSize),
                      "运行时体积应与资产清单同口径：\(detail)")
        XCTAssertTrue(detail.contains("2.9 MiB"),
                      "运行时是 2.9 MiB（3,008,104 字节）：\(detail)")
        XCTAssertFalse(detail.contains("3 MiB"),
                       "不得再四舍五入成 3 MiB——那和 model status 对不上：\(detail)")

        XCTAssertTrue(model.canDownload)
        XCTAssertTrue(model.downloadButtonTitle.contains("244"),
                      "按钮上也要有体积量级：\(model.downloadButtonTitle)")
        XCTAssertNil(model.progressFraction)
        XCTAssertNil(model.failureText)
    }

    /// 就绪 → 显示已就绪，**不给**下载按钮，也不再有说明行。
    func testReadyStateHidesDownloadEntry() throws {
        try installSparseAssets()
        let model = makeModel()
        model.refresh()

        XCTAssertTrue(model.isReady)
        XCTAssertTrue(model.statusText.contains("已就绪"), "状态行：\(model.statusText)")
        XCTAssertNil(model.detailText, "已就绪后不该再留着「要下多少」")
        XCTAssertFalse(model.canDownload, "就绪时不得给下载按钮")
    }

    // MARK: - 下载动作

    /// **成功后**：状态被重读（按钮消失）、进度被清干净。
    ///
    /// 这是注入 `installAction` 存在的理由——真下载要 244 MiB 固定 sha256 的资产，
    /// 用假数据过不了摘要校验。这条注入的是「装完之后的效果」，
    /// 于是「装好之后界面变成什么样」这件事第一次真的被跑到了。
    func testSuccessfulInstallRefreshesStateAndClearsProgress() async throws {
        let model = makeModel(installAction: { try self.installSparseAssets() })
        XCTAssertFalse(model.isReady)
        XCTAssertTrue(model.canDownload)

        let ready = await model.startDownload()

        XCTAssertTrue(ready, "startDownload 应返回「已就绪」")
        XCTAssertTrue(model.isReady, "装完之后必须重新读盘，而不是留着旧状态")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.progressFraction)
        XCTAssertNil(model.failureText)
        XCTAssertFalse(model.canDownload, "就绪后按钮该消失")
    }

    /// **失败后**：错误如实显示、按钮回到可点、状态不能卡在「下载中」。
    ///
    /// 这条是最容易写错的：把 `phase` 留在 `.downloading` 会让进度条永远转下去，
    /// 用户既没有成功也没有失败，只能重启应用。
    func testFailedInstallSurfacesMessageAndRecoversButton() async throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "磁盘满了" }
        }
        let model = makeModel(installAction: { throw Boom() })

        let ready = await model.startDownload()

        XCTAssertFalse(ready)
        XCTAssertFalse(model.isDownloading, "失败之后不能还停在「下载中」")
        XCTAssertNil(model.progressFraction)
        XCTAssertTrue(model.canDownload, "失败后应能重试")
        XCTAssertTrue(model.failureText?.contains("磁盘满了") ?? false,
                      "失败原因必须显示出来：\(model.failureText ?? "nil")")
        XCTAssertFalse(model.isReady)
    }

    // MARK: - 真实下载路径（不注入 installAction）

    /// **不注入 `installAction` 的那条路径**也要走通一遍。
    ///
    /// 注入闭包会绕过整段真实流程（构造 `SenseVoiceDownloader`、逐项下载、失败渲染）——
    /// 而那是这个界面实际会跑的代码。这里用一个必然失败的假 `fetch` 驱动**真实**的下载器：
    /// 断言失败之后界面回到可重试、进度被清干净、错误里带出原始原因。
    func testFailureThroughRealDownloaderSurfacesMessageAndClearsProgress() async throws {
        let failing = SenseVoiceDownloader(
            paths: paths,
            fetch: { _, _, _ in
                throw MRError.io(path: "-", reason: "镜像与兜底都不可达")
            })
        let model = makeModel(downloader: failing)
        XCTAssertFalse(model.isReady)
        XCTAssertTrue(model.canDownload)

        let ready = await model.startDownload()

        XCTAssertFalse(ready)
        XCTAssertFalse(model.isDownloading, "失败之后不能还停在「下载中」")
        XCTAssertNil(model.progressFraction, "进度必须清干净，否则进度条会永远转下去")
        XCTAssertTrue(model.canDownload, "失败后应能重试")
        XCTAssertTrue(model.failureText?.contains("镜像与兜底都不可达") ?? false,
                      "失败原因必须显示出来：\(model.failureText ?? "nil")")
        XCTAssertFalse(model.isReady, "失败不得被误报成「已就绪」")
    }

    // MARK: - 渲染工具

    private func render(engine: TranscriptionEngine, model: SenseVoiceAssetsModel) throws -> CGImage {
        let view = SenseVoiceAssetsView(engine: engine, model: model)
            .frame(width: 420, height: 64)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage, "渲染失败（可能整个控件都没画出来）")
    }

    /// 逐像素判断位图是否**完全透明**。
    /// 用来验「`EmptyView` 确实什么都没画」——只断言 `isVisible == false`
    /// 证明不了这一点。
    private func isFullyTransparent(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return true }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 0 }
    }
}
