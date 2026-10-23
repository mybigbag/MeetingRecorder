import XCTest
@testable import MRTranscribe
@testable import MRCore

/// `mr model` 的文本渲染。
///
/// 单独测这一层，理由写在 `SenseVoiceModelReport` 的文档里：这段输出是**用户唯一能看到的
/// 资产真相**（装在哪、多大、缺哪件、下一步敲什么）。藏在 `runModel()` 里只能靠人眼在终端扫，
/// 而人眼一定漏——尤其是「什么都没装时它有没有谎报通过」这种事。
final class SenseVoiceModelReportTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-report-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        base = nil
    }

    private var paths: SenseVoicePaths { SenseVoicePaths(baseDirectory: base) }

    private func makeState() -> SenseVoiceInstallState {
        SenseVoiceModelStore(paths: paths).state(environment: [:], bundle: .main)
    }

    /// 稀疏文件凑出精确字节数（权重 242 MiB 不能真写满盘）。
    private func install(_ kinds: [SenseVoiceAsset.Kind]) throws {
        for asset in SenseVoiceAssets.all where kinds.contains(asset.kind) {
            let url = paths.url(for: asset)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(asset.byteCount))
            try handle.close()
        }
        if kinds.contains(.runtime) {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: paths.installedRuntimeURL.path)
        }
    }

    // MARK: - status

    /// 每一行都要有**状态、体积、落点**三样东西。
    /// 缺体积用户没法判断要花多少流量；缺落点没法自己去清。
    func testStatusListsEveryAssetWithSizeAndLocation() {
        let lines = SenseVoiceModelReport.status(
            state: makeState(), paths: paths, configuredEngine: .senseVoice)

        for asset in SenseVoiceAssets.all {
            let matching = lines.filter { $0.contains(asset.kind.displayName) }
            XCTAssertFalse(matching.isEmpty, "缺少「\(asset.kind.displayName)」一行：\(lines)")
            XCTAssertTrue(lines.contains { $0.contains(asset.kind.displayName)
                                            && $0.contains(asset.humanSize)
                                            && $0.contains(paths.url(for: asset).path) },
                          "「\(asset.kind.displayName)」那行缺体积或落点：\(lines)")
        }
        XCTAssertTrue(lines.contains { $0.contains(paths.baseDirectory.path) }, "应给出落点根目录")
    }

    /// 未就绪 → 给出**可照抄**的下一步；权重与 VAD 共用一条命令，不能打印两遍。
    func testStatusGivesNextStepOncePerCommand() {
        let lines = SenseVoiceModelReport.status(
            state: makeState(), paths: paths, configuredEngine: .senseVoice)

        let downloads = lines.filter { $0.contains("model download") }
        XCTAssertEqual(downloads.count, 1, "download 提示应去重，只出现一次：\(downloads)")
        XCTAssertTrue(downloads[0].contains("244"), "应带上下载体积：\(downloads[0])")
        XCTAssertTrue(lines.contains { $0.contains("install-runtime") }, "应给出运行时安装命令")
        XCTAssertTrue(lines.contains { $0.contains("未就绪") }, "应明确指出资产未就绪")
    }

    /// **只缺运行时**时不该让人去下载模型——那是 244 MiB 的白等。
    func testStatusDoesNotAskForDownloadWhenOnlyRuntimeMissing() throws {
        try install([.model, .vad])
        let lines = SenseVoiceModelReport.status(
            state: makeState(), paths: paths, configuredEngine: .senseVoice)

        XCTAssertFalse(lines.contains { $0.contains("model download") },
                       "模型已就绪，不该再提示下载：\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("install-runtime") })
    }

    /// 就绪 → 明确说可以转写，并给出启用命令。
    func testStatusSaysReadyWhenEverythingInstalled() throws {
        try install(SenseVoiceAsset.Kind.allCases)
        let lines = SenseVoiceModelReport.status(
            state: makeState(), paths: paths, configuredEngine: .senseVoice)

        XCTAssertTrue(lines.contains { $0.contains("资产齐全") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("config set engine sensevoice") })
        XCTAssertFalse(lines.contains { $0.contains("model download") })
    }

    /// 坏掉的环境变量覆盖要被点出来。（静默忽略是最难排查的一类问题。）
    func testStatusReportsIgnoredRuntimeOverride() {
        let lines = SenseVoiceModelReport.status(
            state: makeState(), paths: paths, configuredEngine: .apple,
            ignoredRuntimeOverride: "/tmp/not-a-runtime")

        XCTAssertTrue(lines.contains { $0.contains("/tmp/not-a-runtime") && $0.contains("已被忽略") },
                      "应报出被忽略的 env 覆盖：\(lines)")
    }

    /// 运行时实际来自别处（env / 内嵌）时要说出来——
    /// 「我刚装的那个文件到底有没有被用上」不该靠猜。
    func testStatusReportsRuntimeActuallyInUse() throws {
        let elsewhere = base.appendingPathComponent("elsewhere/llama-funasr-sensevoice")
        try FileManager.default.createDirectory(
            at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: elsewhere.path, contents: nil)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: elsewhere.path)

        let store = SenseVoiceModelStore(paths: paths)
        let state = store.state(
            environment: [SenseVoicePaths.runtimeOverrideKey: elsewhere.path], bundle: .main)
        let lines = SenseVoiceModelReport.status(
            state: state, paths: paths, configuredEngine: .senseVoice)

        XCTAssertTrue(lines.contains { $0.contains("运行时实际使用") && $0.contains(elsewhere.path) },
                      "应报出实际使用的运行时路径：\(lines)")
    }

    /// 已配置成 sensevoice 但资产没装好 → 必须警告「会明确报错、不会产空稿」。
    func testStatusWarnsWhenConfiguredButNotReady() {
        let lines = SenseVoiceModelReport.status(
            state: makeState(), paths: paths, configuredEngine: .senseVoice)
        XCTAssertTrue(lines.contains { $0.contains("不会产出空稿") }, "\(lines)")

        // 引擎是苹果原生时不该出现这条警告——那批用户没配 SenseVoice。
        let appleLines = SenseVoiceModelReport.status(
            state: makeState(), paths: paths, configuredEngine: .apple)
        XCTAssertFalse(appleLines.contains { $0.contains("不会产出空稿") })
    }

    // MARK: - verification

    /// **这一条是本组用例的重点。**
    ///
    /// 什么都没装时 `verifyAll()` 返回空数组（对不存在的文件不报「不符」），
    /// 旧写法会打出一句「✅ 全部通过。」——在一台全新机器上宣告资产完好。
    /// 那是典型的静默成功：用户以为是好的，直到转写时才炸。
    func testVerificationNeverClaimsSuccessWhenNothingWasVerified() {
        let lines = SenseVoiceModelReport.verification(failures: [], state: makeState())

        XCTAssertFalse(lines.contains { $0.contains("全部通过") },
                       "没有资产可校验时不得说「全部通过」：\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("没有可校验") }, "应说清是「没东西可校验」：\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("model download") }, "应给出补装命令")

        for asset in SenseVoiceAssets.all {
            XCTAssertTrue(lines.contains { $0.contains(asset.kind.displayName)
                                            && $0.contains("未校验") },
                          "「\(asset.kind.displayName)」应标为未校验：\(lines)")
        }
    }

    /// 真的校验过且都没问题 → 才说通过，并报出**校验了几项**。
    func testVerificationReportsHowManyWereActuallyChecked() throws {
        try install(SenseVoiceAsset.Kind.allCases)
        let lines = SenseVoiceModelReport.verification(failures: [], state: makeState())

        XCTAssertTrue(lines.contains { $0.contains("全部通过") && $0.contains("3") },
                      "应报出校验项数：\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("sha256 通过") })
        XCTAssertFalse(lines.contains { $0.contains("未校验") })
    }

    /// 有一项不符 → 逐项列出期望 / 实际 / 修复命令。
    /// 只说「校验失败」，用户不知道是重下还是换个文件。
    ///
    /// 修复指引**按资产分派**：早先三项一律让用户 `model remove --yes && model download`，
    /// 而 `remove` 删的是**整个**资产目录——一个只坏了的运行时会连 244 MiB 权重一起删掉重下。
    func testVerificationPrintsExpectedActualAndFix() {
        let model = SenseVoiceAssets.model
        let lines = SenseVoiceModelReport.verification(
            failures: [(asset: model, actual: "deadbeef")], state: makeState())

        XCTAssertTrue(lines.contains { $0.contains(model.sha256) }, "应给出期望摘要")
        XCTAssertTrue(lines.contains { $0.contains("deadbeef") }, "应给出实际摘要")
        XCTAssertTrue(lines.contains { $0.contains("model download") }, "应给出重下命令")
        XCTAssertFalse(lines.contains { $0.contains("remove --yes") },
                       "权重项不该被指引去删掉整个资产目录：\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("有 1 项未通过") })
        XCTAssertFalse(lines.contains { $0.contains("全部通过") })
    }

    /// 运行时的修复指引必须是**重装它**，而不是「重下权重」或「删光重来」。
    /// 那 244 MiB 的权重和这件事毫无关系。
    func testVerificationRuntimeFailurePointsAtInstallingRuntimeOnly() {
        let runtime = SenseVoiceAssets.runtime
        let lines = SenseVoiceModelReport.verification(
            failures: [(asset: runtime, actual: "deadbeef")], state: makeState())

        XCTAssertTrue(lines.contains { $0.contains("install-runtime") },
                      "运行时项应指向重装运行时：\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("model download") },
                       "不该让用户去重下权重：\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("remove --yes") },
                       "不该让用户删掉整个资产目录：\(lines)")
    }

    /// 只有部分就绪时，就绪的说通过、没就绪的说未校验——不能混成一句。
    func testVerificationSeparatesCheckedFromSkipped() throws {
        try install([.model])
        let lines = SenseVoiceModelReport.verification(failures: [], state: makeState())

        XCTAssertEqual(SenseVoiceModelReport.verifiedCount(state: makeState()), 1)
        XCTAssertTrue(lines.contains { $0.contains("权重") && $0.contains("通过") })
        XCTAssertTrue(lines.contains { $0.contains("推理运行时") && $0.contains("未校验") })
    }

    // MARK: - 排版

    /// 中文一个字占两个终端列。按 `String.count` 对齐会让所有含中文的行错位，
    /// 而错位之后「体积」那一列就再也扫不直——那一列正是用户在看的。
    func testPaddingCountsWideCharactersAsTwoColumns() {
        XCTAssertEqual(SenseVoiceModelReport.displayWidth("abc"), 3)
        XCTAssertEqual(SenseVoiceModelReport.displayWidth("权重"), 4)
        XCTAssertEqual(SenseVoiceModelReport.displayWidth("权重ab"), 6)

        XCTAssertEqual(SenseVoiceModelReport.pad("权重", to: 6), "权重  ")
        XCTAssertEqual(SenseVoiceModelReport.pad("abcdefg", to: 3), "abcdefg", "超宽不得截断")
    }

    /// **marker 与 emoji 的宽度要算对。**
    ///
    /// 下面这些数字是硬编码的终端事实，不是实现的自画像。先钉单个标量，再钉整串——
    /// 这样将来万一有人改了文案，也能一眼看出错的是哪一层。
    ///
    /// 关键的一条是变体选择符 `U+FE0F` **不占位**：`⬇️` 是 `U+2B07` + `U+FE0F`，
    /// 把两个都算宽会得到 4 列，而终端里它只占 2 列。这一个字符的误差
    /// 就足以让整张表的名字列错开。
    func testMarkerWidthsMatchRealTerminalColumns() {
        XCTAssertEqual(SenseVoiceModelReport.width(of: Unicode.Scalar(0x2705)!), 2, "✅")
        XCTAssertEqual(SenseVoiceModelReport.width(of: Unicode.Scalar(0x26A0)!), 2, "⚠")
        XCTAssertEqual(SenseVoiceModelReport.width(of: Unicode.Scalar(0x2B07)!), 2, "⬇")
        XCTAssertEqual(SenseVoiceModelReport.width(of: Unicode.Scalar(0x1F6AB)!), 2, "🚫")
        XCTAssertEqual(SenseVoiceModelReport.width(of: Unicode.Scalar(0xFE0F)!), 0,
                       "变体选择符不占列")
        XCTAssertEqual(SenseVoiceModelReport.width(of: Unicode.Scalar(0x41)!), 1, "A")
        XCTAssertEqual(SenseVoiceModelReport.width(of: Unicode.Scalar(0x4E2D)!), 2, "中")

        XCTAssertEqual(SenseVoiceModelReport.displayWidth("✅ 已就绪"), 9)
        XCTAssertEqual(SenseVoiceModelReport.displayWidth("🚫 不可执行"), 11)
        XCTAssertEqual(SenseVoiceModelReport.displayWidth("⬇️  未下载"), 10)
        XCTAssertEqual(SenseVoiceModelReport.displayWidth("⚠️  字节数不符"), 14)
    }

    /// 三项状态**各不相同**时，名字列与体积列仍要各自对齐——那两列正是用户在扫的。
    /// （marker 不补位的话，名字列会跟着 marker 的长度左右跳。）
    func testStatusTableColumnsAlignAcrossDifferentStatuses() throws {
        try install([.vad])                                   // 就绪
        try TestFiles.makeFile(at: paths.url(for: SenseVoiceAssets.model), bytes: 1024)
        try TestFiles.makeFile(                               // 存在但不可执行
            at: paths.installedRuntimeURL,
            bytes: SenseVoiceAssets.runtime.byteCount, executable: false)

        let lines = SenseVoiceModelReport.status(
            state: makeState(), paths: paths, configuredEngine: .senseVoice)

        /// 在状态表里找出含 `needle` 的那一行，返回 `needle` 之前占了几个终端列。
        func column(of needle: String) -> Int? {
            for line in lines where line.contains(needle) {
                guard let range = line.range(of: needle) else { continue }
                return SenseVoiceModelReport.displayWidth(
                    String(line[line.startIndex..<range.lowerBound]))
            }
            return nil
        }

        let nameColumns = SenseVoiceAssets.all.compactMap { column(of: $0.kind.displayName) }
        let sizeColumns = SenseVoiceAssets.all.compactMap { column(of: $0.humanSize) }

        XCTAssertEqual(nameColumns.count, SenseVoiceAssets.all.count, "每一项都应有状态行：\(lines)")
        XCTAssertEqual(sizeColumns.count, SenseVoiceAssets.all.count, "每一项都应有体积：\(lines)")
        XCTAssertEqual(Set(nameColumns).count, 1, "名字列必须对齐，实际起始列：\(nameColumns)")
        XCTAssertEqual(Set(sizeColumns).count, 1, "体积列必须对齐，实际起始列：\(sizeColumns)")
    }

    /// 运行时存在但不可执行 → 状态表要说「不可执行」。
    /// 说成「未下载」会把用户送去重下一份 2.9 MiB，而真正要做的是 `chmod +x`。
    func testStatusDistinguishesNotExecutableRuntime() throws {
        try install([.model, .vad])
        try TestFiles.makeFile(
            at: paths.installedRuntimeURL,
            bytes: SenseVoiceAssets.runtime.byteCount, executable: false)

        let lines = SenseVoiceModelReport.status(
            state: makeState(), paths: paths, configuredEngine: .senseVoice)

        XCTAssertTrue(lines.contains { $0.contains("不可执行") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("install-runtime") }, "应给出修复命令：\(lines)")
    }

    /// 运行时是自建 / 异版本（字节数与官方不同但可执行）→ **能用**，但要如实说出来。
    /// 不说的话，用户会以为自己在跑官方 0.2.6。
    func testStatusFlagsNonOfficialRuntime() throws {
        try install([.model, .vad])
        try TestFiles.makeFile(at: paths.installedRuntimeURL, bytes: 128, executable: true)

        let lines = SenseVoiceModelReport.status(
            state: makeState(), paths: paths, configuredEngine: .senseVoice)

        XCTAssertTrue(lines.contains { $0.contains("不是官方那一份") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("\(SenseVoiceAssets.runtime.byteCount)") },
                      "应给出官方字节数：\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("资产齐全") },
                      "可执行就该算能用，不能报成未就绪：\(lines)")
    }
}
