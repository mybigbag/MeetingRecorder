import XCTest
@testable import MRTranscribe
@testable import MRCore

/// 资产清单、路径解析、SRT 解析、段落清洗。
///
/// 这些都是**纯逻辑**，不需要音频、不需要网络、不需要权限就能钉死。
/// 它们恰好也是整条链路里最容易「悄悄错」的部分：路径解析错了会让引擎报「未安装」，
/// 解析器少读一条会让稿子缺一段，而两者都不会有人在第一时间发现。
final class SenseVoiceAssetTests: XCTestCase {

    // MARK: - B：资产清单与路径

    /// B01 / B02 / B03 / B04：清单本身的自洽性。
    ///
    /// 体积、摘要、来源、授权四件事必须在**同一处**声明，并且互相自洽——
    /// 分散开去的必然结果是「校验用了旧的 sha、错误提示里写了新的体积」。
    func testAssetCatalogueIsSelfConsistent() {
        XCTAssertEqual(SenseVoiceAssets.downloadable.map(\.kind), [.model, .vad])
        XCTAssertEqual(SenseVoiceAssets.all.map(\.kind), [.model, .vad, .runtime])

        for asset in SenseVoiceAssets.all {
            XCTAssertEqual(asset.sha256.count, 64, "\(asset.kind) 的 sha256 不是 64 位十六进制")
            XCTAssertTrue(
                asset.sha256.allSatisfy { $0.isHexDigit },
                "\(asset.kind) 的 sha256 含非十六进制字符")
            XCTAssertGreaterThan(asset.byteCount, 0)
            XCTAssertFalse(asset.license.isEmpty)
            XCTAssertFalse(asset.attribution.isEmpty)
            XCTAssertGreaterThanOrEqual(asset.source.urls.count, 1, "\(asset.kind) 没有下载来源")
        }

        XCTAssertEqual(SenseVoiceAssets.model.byteCount, 254_208_320)
        XCTAssertEqual(SenseVoiceAssets.vad.byteCount, 1_720_512)
        XCTAssertEqual(SenseVoiceAssets.runtime.byteCount, 3_008_104)
        XCTAssertEqual(SenseVoiceAssets.runtime.fileName, "llama-funasr-sensevoice")

        // sha256 的**取值**要钉死，不能只检查「形状」。
        //
        // 早先这里只断言「64 位十六进制字符」，于是把权重摘要换成 64 个 0，
        // 整套测试**仍然全绿**（下载器与校验器的用例用的都是自建小夹具，
        // 不读这三个常量）。而这些常量写错的后果是实的：`model download` 会永远
        // 拒绝真正下载下来的文件、`mr model verify` 会永远报不符——
        // 用户在真机上只会以为「模型坏了」，而 CI 一切正常。
        XCTAssertEqual(SenseVoiceAssets.model.sha256,
                       "4ae45c94422de949b387e2e0fb10d7e14e4c42c69db30c3444ecc7d4b844b7c5")
        XCTAssertEqual(SenseVoiceAssets.vad.sha256,
                       "1270f2559c495f4e7b6e739541151027d360761a3fda43fc147034f5719f5479")
        XCTAssertEqual(SenseVoiceAssets.runtime.sha256,
                       "becaa30d66bcaa727c132ef0e8c7248410bbf2cc4f0a2fe8f375cf885b9903c3")

        // 体积的文字口径只能有一个：`humanSize` 用 1 MiB = 1,048,576。
        // 早先帮助文本与注释写的是十进制的 `3.0 MiB`，于是同一份二进制
        // 在 status 表、帮助文本、GUI 三处显示成三个数。
        XCTAssertEqual(SenseVoiceAssets.runtime.humanSize, "2.9 MiB")
        XCTAssertEqual(SenseVoiceAssets.vad.humanSize, "1.6 MiB")

        // 镜像优先：本机直连 huggingface.co 返回 502，第一顺位必须是镜像。
        for asset in SenseVoiceAssets.downloadable {
            XCTAssertEqual(asset.source.urls.first?.host, "hf-mirror.com",
                           "\(asset.kind) 的第一下载源不是镜像")
            XCTAssertTrue(
                asset.source.urls.contains { $0.host == "huggingface.co" },
                "\(asset.kind) 缺少 huggingface.co 兜底源")
        }
        // 授权：权重是 Apache-2.0，运行时是 MIT。写错了会变成一个许可问题。
        XCTAssertEqual(SenseVoiceAssets.model.license, "Apache-2.0")
        XCTAssertEqual(SenseVoiceAssets.vad.license, "Apache-2.0")
        XCTAssertEqual(SenseVoiceAssets.runtime.license, "MIT")

        // 体积提示按 MiB 渲染，不能直接把九位数甩到用户脸上
        XCTAssertEqual(SenseVoiceAssets.model.humanSize, "242.4 MiB")
    }

    /// B05 / B06 / B11：落点结构。
    func testPathsAreScopedUnderAppSupport() {
        let base = URL(fileURLWithPath: "/tmp/sv-fixture", isDirectory: true)
        let paths = SenseVoicePaths(baseDirectory: base)

        XCTAssertEqual(paths.modelsDirectory.path, "/tmp/sv-fixture/models")
        XCTAssertEqual(paths.runtimeDirectory.path, "/tmp/sv-fixture/runtime")
        XCTAssertEqual(paths.installedRuntimeURL.path,
                       "/tmp/sv-fixture/runtime/llama-funasr-sensevoice")
        XCTAssertEqual(paths.url(for: SenseVoiceAssets.model).path,
                       "/tmp/sv-fixture/models/sensevoice-small-q8.gguf")
        XCTAssertEqual(paths.url(for: SenseVoiceAssets.vad).path,
                       "/tmp/sv-fixture/models/fsmn-vad.gguf")
        XCTAssertFalse(paths.url(for: SenseVoiceAssets.model).hasDirectoryPath)

        // 默认落点必须与录音库分开，否则「备份会议」会平白多出 244 MiB
        XCTAssertTrue(SenseVoicePaths.defaultBaseDirectory.path.contains("meeting-recorder/sensevoice"))
        XCTAssertFalse(SenseVoicePaths.defaultBaseDirectory.path.contains("Documents/MeetingRecorder"))
    }

    /// B12：构造路径对象**不得**在磁盘上留下任何东西。
    func testConstructingPathsCreatesNothing() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-nocreate-\(UUID().uuidString)", isDirectory: true)
        _ = SenseVoicePaths(baseDirectory: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path),
                       "构造 SenseVoicePaths 不应创建目录")
    }

    /// B07 / B08 / B09 / B10：运行时解析顺序与坏 env 的容错。
    func testRuntimeResolutionOrder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-resolve-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = SenseVoicePaths(baseDirectory: base)

        // B07：什么都没有 → nil
        XCTAssertNil(paths.resolveRuntimeBinary(environment: [:], bundle: .main))

        // B08：常规落点存在 → 被解析到，且是绝对路径
        try TestFiles.makeFile(at: paths.installedRuntimeURL, bytes: 64, executable: true)
        let installed = paths.resolveRuntimeBinary(environment: [:], bundle: .main)
        XCTAssertEqual(installed?.path, paths.installedRuntimeURL.path)
        XCTAssertTrue(installed?.path.hasPrefix("/") ?? false)

        // B09：env 指向另一个存在的文件 → env 优先
        let override = base.appendingPathComponent("custom-runtime")
        try TestFiles.makeFile(at: override, bytes: 32, executable: true)
        let resolved = paths.resolveRuntimeBinary(
            environment: [SenseVoicePaths.runtimeOverrideKey: override.path], bundle: .main)
        XCTAssertEqual(resolved?.path, override.path, "env 应优先于常规落点")

        // B10：env 指向不存在的东西 → **忽略它**，回落到常规落点。
        // 坏掉一个调试开关不该让整个引擎不可用。
        let fallback = paths.resolveRuntimeBinary(
            environment: [SenseVoicePaths.runtimeOverrideKey: "/tmp/definitely-not-here-\(UUID())"],
            bundle: .main)
        XCTAssertEqual(fallback?.path, paths.installedRuntimeURL.path)
        XCTAssertNotNil(paths.ignoredRuntimeOverride(
            environment: [SenseVoicePaths.runtimeOverrideKey: "/tmp/definitely-not-here-\(UUID())"]))

        // 文件存在但没有可执行位 → 不算可用。只判「存在」会让 Process 以一种
        // 完全不提权限的错误失败。
        let notExecutable = base.appendingPathComponent("no-x-bit")
        try TestFiles.makeFile(at: notExecutable, bytes: 16, executable: false)
        XCTAssertFalse(SenseVoicePaths.isUsableExecutable(notExecutable))
    }

    /// B13：从可执行文件向上找仓库 vendor 副本（`swift run` 开发态靠它）。
    func testVendoredRuntimeSearchAscendsFromExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-vendor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root
            .appendingPathComponent(".build/debug/meeting-recorder")
        try TestFiles.makeFile(at: executable, bytes: 8, executable: true)
        let vendored = root
            .appendingPathComponent("vendor/sensevoice-runtime/\(SenseVoiceAssets.runtime.fileName)")
        try TestFiles.makeFile(at: vendored, bytes: 8, executable: true)

        let paths = SenseVoicePaths(baseDirectory: root.appendingPathComponent("base"))
        XCTAssertEqual(paths.vendoredRuntimeURL(executableURL: executable)?.path, vendored.path)

        // 找不到就是 nil，不能瞎猜一个
        let isolated = root.appendingPathComponent("elsewhere/meeting-recorder")
        try TestFiles.makeFile(at: isolated, bytes: 8, executable: true)
        XCTAssertNil(paths.vendoredRuntimeURL(executableURL: isolated, maxAscend: 1))
    }

    // MARK: - P：SRT 解析

    /// P01 / P10：标准输入，含毫秒换算与「纯标点段照样返回」。
    func testParseStandardSRT() {
        let srt = """
        1
        00:01:07,260 --> 00:01:37,260
        嗯，OK昨天把用户部门多语言的改版检查了一遍。

        2
        00:01:37,260 --> 00:01:56,190
        主要就这两件事。

        """
        let result = SenseVoiceSRTParser.parse(srt)
        XCTAssertEqual(result.captions.count, 2)
        XCTAssertEqual(result.skippedBlocks, 0)
        XCTAssertEqual(result.invertedTimestamps, 0)
        XCTAssertEqual(result.captions[0].index, 1)
        XCTAssertEqual(result.captions[0].start, 67.26, accuracy: 0.0001)
        XCTAssertEqual(result.captions[0].end, 97.26, accuracy: 0.0001)
        XCTAssertEqual(result.captions[0].text, "嗯，OK昨天把用户部门多语言的改版检查了一遍。")
    }

    /// P02 / P03：空输入与纯空白**不是畸形输入**。
    ///
    /// 这条很重要：整段静音时运行时的输出就是 0 字节。若把空输入算作解析失败，
    /// 一场安静的会议会被报成「转写出错」。
    func testEmptyInputIsNotMalformed() {
        for raw in ["", "\n", "   \n\n  \t \n"] {
            let result = SenseVoiceSRTParser.parse(raw)
            XCTAssertTrue(result.isEmpty, "输入 \(raw.debugDescription) 应为空结果")
            XCTAssertEqual(result.skippedBlocks, 0, "空输入不应被算作畸形块")
        }
    }

    /// P04：缺时间码的块被跳过并计数。
    func testBlockWithoutTimecodeIsCountedAndSkipped() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,000
        正常一条

        2
        没有时间码的坏块

        3
        00:00:03,000 --> 00:00:04,000
        另一条正常的

        """
        let result = SenseVoiceSRTParser.parse(srt)
        XCTAssertEqual(result.captions.map(\.text), ["正常一条", "另一条正常的"])
        XCTAssertEqual(result.skippedBlocks, 1)
    }

    /// P05：段号行缺失也要能解析（宽容）。
    func testBlockWithoutIndexStillParses() {
        let srt = "00:00:05,000 --> 00:00:06,000\n只有时间码和文本\n"
        let result = SenseVoiceSRTParser.parse(srt)
        XCTAssertEqual(result.captions.count, 1)
        XCTAssertEqual(result.captions[0].text, "只有时间码和文本")
        XCTAssertEqual(result.skippedBlocks, 0)
    }

    /// P06：`end < start` → **保留内容**、夹正时间戳并计数。
    ///
    /// 时间戳可疑时扔掉内容是最坏的选择：时间戳可以后修，丢掉的话没人知道丢过。
    func testInvertedTimestampsAreClampedNotDropped() throws {
        let srt = "1\n00:00:10,000 --> 00:00:04,000\n内容比时间戳值钱\n"
        let result = SenseVoiceSRTParser.parse(srt)
        XCTAssertEqual(result.captions.count, 1, "倒挂的时间码不得导致内容被丢弃")
        // 先 `XCTUnwrap` 再取属性：直接写 `captions[0]` 的话，一旦上面那条断言失败，
        // 这一行会以「数组越界」崩溃收场（signal 5），报告里只剩一个陷阱，
        // 看不到真正失败的断言。
        let caption = try XCTUnwrap(result.captions.first)
        XCTAssertEqual(caption.start, 10.0, accuracy: 0.0001)
        XCTAssertEqual(caption.end, 10.0, accuracy: 0.0001)
        XCTAssertEqual(result.invertedTimestamps, 1)
    }

    /// P07：乱序输入 → 输出按 start 升序。
    /// 下游按时间归并双轨，顺序错了会让整条时间线错位。
    func testCaptionsAreSortedByStart() {
        let srt = """
        1
        00:00:30,000 --> 00:00:31,000
        后

        2
        00:00:10,000 --> 00:00:11,000
        前

        """
        let result = SenseVoiceSRTParser.parse(srt)
        XCTAssertEqual(result.captions.map(\.text), ["前", "后"])
        XCTAssertEqual(result.captions[0].start, 10.0, accuracy: 0.0001)
    }

    /// P08：多行拼接规则 —— 中文↔中文不插空格，ASCII↔ASCII 插一个空格，混边界不插。
    func testMultiLineJoiningRule() {
        XCTAssertEqual(
            SenseVoiceSRTParser.joinCaptionLines(["这是一句", "被折行的话"]),
            "这是一句被折行的话")
        XCTAssertEqual(
            SenseVoiceSRTParser.joinCaptionLines(["the cat", "sat down"]),
            "the cat sat down")
        XCTAssertEqual(
            SenseVoiceSRTParser.joinCaptionLines(["说了个", "OK"]),
            "说了个OK")
        XCTAssertEqual(
            SenseVoiceSRTParser.joinCaptionLines(["OK", "就这样"]),
            "OK就这样")
        // 空行不参与拼接，也不额外插空格
        XCTAssertEqual(
            SenseVoiceSRTParser.joinCaptionLines(["第一行", "", "  ", "第二行"]),
            "第一行第二行")
    }

    /// P09：富文本标签被剥掉。
    /// 默认不带 `--keep-tags`，但只要有人改了参数，这些标签就会**直接出现在稿子里**。
    func testRichTextTagsAreStripped() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n<|zh|><|NEUTRAL|><|Speech|><|woitn|>今天天气不错\n"
        let result = SenseVoiceSRTParser.parse(srt)
        XCTAssertEqual(result.captions.first?.text, "今天天气不错")

        XCTAssertEqual(SenseVoiceSRTParser.stripTags("a<|x|>b"), "ab")
        XCTAssertEqual(SenseVoiceSRTParser.stripTags("没有标签"), "没有标签")
        XCTAssertEqual(SenseVoiceSRTParser.stripTags("截断的标签<|zh"), "截断的标签")
    }

    /// P11 / P12 / P13：`\r\n`、末尾无空行、毫秒位数不足。
    func testParserSurvivesAwkwardWhitespaceAndShortMillis() {
        let crlf = "1\r\n00:00:01,000 --> 00:00:02,000\r\n第一条\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\n第二条"
        let result = SenseVoiceSRTParser.parse(crlf)
        XCTAssertEqual(result.captions.map(\.text), ["第一条", "第二条"],
                       "CRLF 与「末尾没有空行」都不该吃掉最后一条")

        // `,5` 是 0.5 秒（不是 5 毫秒）——靠直读小数自然得到正确结果
        XCTAssertEqual(SenseVoiceSRTParser.parseTimestamp("00:00:01,5") ?? -1, 1.5, accuracy: 0.0001)
        XCTAssertEqual(SenseVoiceSRTParser.parseTimestamp("00:00:01.25") ?? -1, 1.25, accuracy: 0.0001)
        XCTAssertNil(SenseVoiceSRTParser.parseTimestamp("01,5"))
        XCTAssertNil(SenseVoiceSRTParser.parseTimestamp("aa:bb:cc"))
    }

    // MARK: - F：段落清洗

    /// F01 / F02：纯标点 / 纯空白被丢弃并计数。
    func testPurePunctuationCaptionsAreDropped() {
        let captions = [
            SenseVoiceCaption(index: 1, start: 0, end: 1, text: "。"),
            SenseVoiceCaption(index: 2, start: 1, end: 2, text: "……"),
            SenseVoiceCaption(index: 3, start: 2, end: 3, text: "，"),
            SenseVoiceCaption(index: 4, start: 3, end: 4, text: "　"),
            SenseVoiceCaption(index: 5, start: 4, end: 5, text: "   "),
        ]
        let cleanup = SenseVoiceCaptionFilter.clean(captions)
        XCTAssertTrue(cleanup.captions.isEmpty)
        XCTAssertEqual(cleanup.droppedEmpty, 5)
    }

    /// F03 / F05：真实短句**不许误杀**，且首尾空白被 trim。
    func testRealShortCaptionsAreKeptAndTrimmed() {
        let captions = [
            SenseVoiceCaption(index: 1, start: 0, end: 1, text: "  好  "),
            SenseVoiceCaption(index: 2, start: 1, end: 2, text: "嗯"),
        ]
        let cleanup = SenseVoiceCaptionFilter.clean(captions)
        XCTAssertEqual(cleanup.captions.map(\.text), ["好", "嗯"])
        XCTAssertEqual(cleanup.droppedEmpty, 0)
        XCTAssertEqual(cleanup.suspiciouslyShort, 2, "短句应被计数以便暴露，但不得删除")
    }

    /// F04：正常长句不计入可疑短段。
    func testNormalCaptionsAreNotFlagged() {
        let cleanup = SenseVoiceCaptionFilter.clean([
            SenseVoiceCaption(index: 1, start: 0, end: 3, text: "嗯，OK嗯嗯OK"),
        ])
        XCTAssertEqual(cleanup.captions.count, 1)
        XCTAssertEqual(cleanup.suspiciouslyShort, 0)
    }

    /// F06：`I.` / `Yeah。` 这类**非语音幻觉**保留但计数。
    ///
    /// 这是刻意不删的：它们与真实的 `好`、`对` 在形状上完全一样，
    /// 一个「太短就删」的规则会同时干掉真话。删掉用户说过的话比多几条噪声严重得多，
    /// 所以这里只把它做成**可见**的问题。
    func testNonSpeechHallucinationsAreKeptButCounted() {
        let cleanup = SenseVoiceCaptionFilter.clean([
            SenseVoiceCaption(index: 1, start: 0, end: 2, text: "I."),
            SenseVoiceCaption(index: 2, start: 2, end: 3, text: "Yeah。"),
            SenseVoiceCaption(index: 3, start: 3, end: 5, text: "Good morning everyone"),
        ])
        XCTAssertEqual(cleanup.captions.count, 3, "不得删除——它与真实短句无法区分")
        XCTAssertEqual(cleanup.suspiciouslyShort, 2, "`I.` 与 `Yeah。` 应被计数")
        XCTAssertEqual(cleanup.droppedEmpty, 0)
    }

    /// F07：混合一批时保序、计数正确。
    func testMixedBatchKeepsOrder() {
        let captions = [
            SenseVoiceCaption(index: 1, start: 0, end: 1, text: "第一句"),
            SenseVoiceCaption(index: 2, start: 1, end: 2, text: "。"),
            SenseVoiceCaption(index: 3, start: 2, end: 3, text: "第二句"),
            SenseVoiceCaption(index: 4, start: 3, end: 4, text: "……"),
            SenseVoiceCaption(index: 5, start: 4, end: 5, text: "第三句"),
        ]
        let cleanup = SenseVoiceCaptionFilter.clean(captions)
        XCTAssertEqual(cleanup.captions.map(\.text), ["第一句", "第二句", "第三句"])
        XCTAssertEqual(cleanup.droppedEmpty, 2)
    }

    /// 实义单元计数的边界：符号与 emoji 不该被误判成「无实义」而丢掉。
    func testContentUnitsKeepSymbolsAndEmoji() {
        XCTAssertEqual(SenseVoiceCaptionFilter.contentUnitCount(of: "。，！？"), 0)
        XCTAssertEqual(SenseVoiceCaptionFilter.contentUnitCount(of: "好"), 1)
        XCTAssertEqual(SenseVoiceCaptionFilter.contentUnitCount(of: "♪"), 1, "音符不是标点，不该被丢")
        XCTAssertEqual(SenseVoiceCaptionFilter.contentUnitCount(of: "3 千 5"), 3, "空格断开即三个单元")
    }

    /// 单元口径按文字系统分：**连续 ASCII 字母算一个单元**，中文一字一单元。
    ///
    /// 这条不只是为了 `Yeah。`——SenseVoiceSmall 是五语种模型，英文稿与中文稿走同一条
    /// 清洗链路。若按字符数判，判据在中文上成立（`好` = 1）而在英文上失效
    /// （`Yeah` = 4 字符），一个词的英文幻觉永远不会进「可疑短段」计数。
    func testContentUnitsTreatASCIIWordAsOneUnit() {
        XCTAssertEqual(SenseVoiceCaptionFilter.contentUnitCount(of: "Yeah"), 1)
        XCTAssertEqual(SenseVoiceCaptionFilter.contentUnitCount(of: "Okay."), 1)
        XCTAssertEqual(SenseVoiceCaptionFilter.contentUnitCount(of: "Good morning everyone"), 3)
        // 混合：中文逐字、英文逐词
        XCTAssertEqual(SenseVoiceCaptionFilter.contentUnitCount(of: "说了个OK"), 4)
        XCTAssertEqual(SenseVoiceCaptionFilter.contentUnitCount(of: "嗯OK嗯嗯OK"), 5)
    }
}
