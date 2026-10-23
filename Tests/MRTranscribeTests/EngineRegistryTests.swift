import XCTest
@testable import MRTranscribe
@testable import MRCore

/// 转写引擎的解析与 SenseVoice 的**守卫语义**。
///
/// 这一层有两块价值，都能在**没有音频、没有权限、没有网络**的环境里钉死：
/// 1. `TranscriptionEngineResolver` 是「换引擎」唯一的开关位置——映射错了，
///    整条链路会用错引擎，而稿子上只会多一个名字，不会有任何异常。
/// 2. SenseVoice **不得产出伪造文稿**——资产没就绪时 `transcribe` 必须抛错。
///    如果哪天有人为了「让它跑起来」把缺资产的路径改成返回空数组/假文本，
///    这里会立刻变红。
///
/// 注：SenseVoice 从「骨架」变成真实现之后，这两条守卫**语义完全不变**，
/// 变的只是错误原因（从「尚未接入」变成「资产未就绪 + 怎么装」）。
/// 详细的资产 / 下载 / 解析 / 子进程用例见同目录下的 `SenseVoice*Tests.swift`。
final class EngineRegistryTests: XCTestCase {

    // MARK: - 解析器映射

    /// 默认引擎解析成苹果驱动器，标签是 `apple-speech`。
    func testResolverReturnsAppleDriver() {
        let driver = TranscriptionEngineResolver.driver(for: .apple, language: "zh-CN")
        XCTAssertTrue(driver is AppleSpeechEngineDriver)
        XCTAssertEqual(driver.engineID, "apple-speech")
    }

    /// opt-in 引擎解析成 SenseVoice 驱动器，标签是 `sensevoice`。
    func testResolverReturnsSenseVoiceDriver() {
        let driver = TranscriptionEngineResolver.driver(for: .senseVoice, language: "zh-CN")
        XCTAssertTrue(driver is SenseVoiceTranscriptionEngine)
        XCTAssertEqual(driver.engineID, "sensevoice")
    }

    /// 驱动器的 `engineID` 必须与枚举的 `driverEngineID` 一致——
    /// 这是「稿子上写的引擎名」的唯一出处，两处不一致会让文档与代码对不上。
    func testDriverEngineIDMatchesEnum() {
        for engine in TranscriptionEngine.allCases {
            let driver = TranscriptionEngineResolver.driver(for: engine, language: "zh-CN")
            XCTAssertEqual(
                driver.engineID, engine.driverEngineID,
                "驱动器标签与枚举不一致：\(engine)")
        }
    }

    // MARK: - SenseVoice：绝不产出伪造文稿

    /// `transcribe` 在资产缺失时**必须抛错**，绝不能返回伪造或空的段落。
    ///
    /// 这是它能被安全合入的前提：没装好资产之前，任何一次误用都要在转写阶段
    /// 明确失败，而不是安静地产出一份空稿——空稿会被下游读成「这场确实没人说话」。
    func testSenseVoiceTranscribeThrowsRatherThanFaking() async {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-registry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let engine = SenseVoiceTranscriptionEngine(
            language: "zh-CN",
            paths: SenseVoicePaths(baseDirectory: base),
            runner: FakeProcessRunner(),
            environment: [:],
            bundle: .main)
        do {
            _ = try await engine.transcribe(
                fileURL: URL(fileURLWithPath: "/tmp/does-not-exist.wav"),
                trackID: "mic", speaker: "我")
            XCTFail("资产缺失时 transcribe 必须抛错，绝不能返回伪造文稿")
        } catch let error as MRError {
            guard case .transcription = error else {
                return XCTFail("应抛 .transcription，实际：\(error)")
            }
        } catch {
            XCTFail("应抛 MRError，实际：\(error)")
        }
    }

    /// `prepare` 同样抛错，而且**必须可照抄执行**。
    ///
    /// 「未就绪」本身不是有用的信息；有用的是「敲哪一条命令能变就绪」。
    func testSenseVoicePrepareThrowsWithActionableCommand() async {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-registry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let engine = SenseVoiceTranscriptionEngine(
            paths: SenseVoicePaths(baseDirectory: base),
            runner: FakeProcessRunner(), environment: [:], bundle: .main)
        do {
            try await engine.prepare()
            XCTFail("资产缺失时 prepare 必须抛错")
        } catch let error as MRError {
            guard case .transcription = error else {
                return XCTFail("应抛 .transcription，实际：\(error)")
            }
            XCTAssertTrue("\(error)".contains("model download"), "错误信息里应含修复命令")
        } catch {
            XCTFail("应抛 MRError，实际：\(error)")
        }
    }

    // MARK: - SenseVoice 的其余行为

    /// 语言支持反映模型的**真实**能力（五语种），不再是「只认中文」的占位。
    func testSenseVoiceLanguageSupportIsNotAPlaceholder() async {
        let engine = SenseVoiceTranscriptionEngine(
            paths: SenseVoicePaths(baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("sv-lang-\(UUID().uuidString)")),
            runner: FakeProcessRunner(), environment: [:], bundle: .main)

        let zh = await engine.isLanguageSupported("zh-CN")
        let yue = await engine.isLanguageSupported("yue-CN")
        let en = await engine.isLanguageSupported("en-US")
        let ja = await engine.isLanguageSupported("ja-JP")
        let ko = await engine.isLanguageSupported("ko-KR")
        let fr = await engine.isLanguageSupported("fr-FR")
        XCTAssertTrue(zh)
        XCTAssertTrue(yue)
        XCTAssertTrue(en, "SenseVoiceSmall 支持英文——占位实现会在这里拦下合法请求")
        XCTAssertTrue(ja)
        XCTAssertTrue(ko)
        XCTAssertFalse(fr)

        let supported = await engine.supportedLanguages()
        XCTAssertTrue(supported.contains("zh-CN"))
        XCTAssertEqual(supported.count, 5)
    }

    /// 模型目录应当与录音库分离（放在 Application Support 下的固定子路径），
    /// 便于单独清理与版本管理。
    func testSenseVoiceModelDirectoryIsScoped() {
        let dir = SenseVoiceTranscriptionEngine.modelDirectory
        XCTAssertTrue(dir.path.contains("meeting-recorder/sensevoice"),
                      "模型目录路径异常：\(dir.path)")
        XCTAssertTrue(dir.hasDirectoryPath, "模型目录应标记为目录")
    }

    /// 构造引擎**不会**自己创建模型目录——「不偷偷在磁盘上建东西」。
    func testSenseVoiceDoesNotCreateModelDirectoryEagerly() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-eager-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        _ = SenseVoiceTranscriptionEngine(
            paths: SenseVoicePaths(baseDirectory: base),
            runner: FakeProcessRunner(), environment: [:], bundle: .main)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path),
                       "构造引擎不得创建目录")
    }
}
