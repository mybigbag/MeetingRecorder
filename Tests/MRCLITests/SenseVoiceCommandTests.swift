import XCTest
@testable import MRCLI
import MRCore
import MRTranscribe

/// `meeting-recorder model` 这一组命令。
///
/// 这里能测到的都是**不碰真资产**的部分：用法文本、子命令分派、以及 `remove` 的护栏。
///
/// 资产目录一律注入临时目录——`remove --yes` 真的会删掉一个 244 MiB 的目录，
/// 拿 `~/Library/Application Support` 去测「删掉了吗」是荒唐的，也危险。
/// 真下载 / 真校验走真机（`docs/测试用例-SenseVoice接入.md` 的 SV-I 组）。
final class SenseVoiceCommandTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-cli-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        base = nil
    }

    private var paths: SenseVoicePaths { SenseVoicePaths(baseDirectory: base) }

    /// 在临时目录里放一份「看起来装好了」的资产（稀疏文件，不占磁盘）。
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

    // MARK: - C11：帮助

    /// 帮助里要有 `model` 段，且四个子命令一个不少。
    /// 少了任何一个，用户就只能靠猜——而 `--yes` 漏写会以为自己删成功了。
    func testUsageDocumentsModelCommandAndEverySubcommand() {
        let usage = MeetingRecorderCLI.usageText()
        XCTAssertTrue(usage.contains("meeting-recorder model"), "帮助里缺 model 段")
        for subcommand in ["download", "install-runtime", "verify", "remove"] {
            XCTAssertTrue(usage.contains("model \(subcommand)"),
                          "帮助里缺 model \(subcommand)")
        }
        XCTAssertTrue(usage.contains("--from"), "install-runtime 的 --from 要写进去")
        XCTAssertTrue(usage.contains("--yes"), "remove 的 --yes 要写进去——它是护栏的一部分")
    }

    /// **回归**：帮助里不得再出现「尚未接入」。
    ///
    /// 这是骨架期的文案，推理接上之后它就从「如实告知限制」变成了一句谎话，
    /// 会让人以为这个引擎根本用不了。
    func testUsageDoesNotClaimSenseVoiceIsUnavailable() {
        let usage = MeetingRecorderCLI.usageText()
        XCTAssertFalse(usage.contains("尚未接入"), "SenseVoice 已经能用了，帮助不该这么说")
        XCTAssertFalse(usage.contains("尚未实现"))
    }

    /// 帮助里必须说明**本仓库的真实入口是 `./mr`**。
    ///
    /// 所有错误提示与用法文本里都写作 `meeting-recorder`，而 `PATH` 里通常没有这个名字，
    /// 照抄会 `command not found`。「错误信息可照抄执行」是硬约束，那就得把这条差异
    /// 明说出来，而不是让它变成一次静默的失败。
    func testUsageTellsYouWhatTheRealEntryPointIs() {
        let usage = MeetingRecorderCLI.usageText()
        XCTAssertTrue(usage.contains("./mr"), "应说明本仓库的入口是 ./mr：\(usage)")
    }

    /// C13：切到 sensevoice 之后必须给出**具体命令**，并说清要下多少。
    ///
    /// 早先写的是「执行 `meeting-recorder model` 查看状态并按其提示安装」——
    /// 那要求用户再跑一条命令、再读一段输出，才拿到真正该敲的那一行。
    func testActivationHintNamesTheConcreteCommand() {
        let state = SenseVoiceModelStore(paths: paths).state(environment: [:], bundle: .main)
        let text = MeetingRecorderCLI.senseVoiceActivationHint(state: state)
            .joined(separator: "\n")

        XCTAssertTrue(text.contains("meeting-recorder model download"),
                      "应给出具体命令：\(text)")
        XCTAssertTrue(text.contains("model install-runtime"),
                      "缺运行时该给出更快的那条：\(text)")
        XCTAssertTrue(text.contains("244"), "应给出下载体积量级：\(text)")
        XCTAssertTrue(text.contains(SenseVoiceAssets.runtime.humanSize),
                      "运行时的体积口径要与资产清单一致：\(text)")
    }

    // MARK: - C10：未知子命令

    /// 拼错的子命令要被拒绝并**列出合法取值**，不能静默当成 `status`。
    /// 静默兜底最坑的一种：用户以为自己在删除，实际只看到一张状态表。
    func testUnknownSubcommandIsRejectedWithValidOnesListed() async {
        do {
            try await MeetingRecorderCLI.runModel(["bogus"], paths: paths)
            XCTFail("未知子命令必须抛错")
        } catch let error as MRError {
            guard case .invalidArgument = error else {
                return XCTFail("应抛 .invalidArgument，实际：\(error)")
            }
            let text = "\(error)"
            XCTAssertTrue(text.contains("bogus"), "应指出是哪个子命令：\(text)")
            for subcommand in ["download", "install-runtime", "verify", "remove"] {
                XCTAssertTrue(text.contains(subcommand), "应列出合法子命令 \(subcommand)：\(text)")
            }
        } catch {
            XCTFail("应抛 MRError，实际：\(error)")
        }
    }

    // MARK: - 子命令后面的 `--help`

    /// **回归**：`record --help` 曾经直接开录。
    ///
    /// 顶层分派只认「第一个词」，子命令后面的 `-h` / `--help` 被当成多余的开关忽略，
    /// 于是 `record --help` = 开始录音。这不是假想——2026-09-29 实测就这样往
    /// 真实会议库里写进了 2 分钟、约 68 MB 的无用录音。
    ///
    /// **把修复退回去它会怎么红**：加了 `--seconds 0` 是为了让它*红*而不是*挂*——
    /// 没有修复时 `runRecord` 会照常建会话目录，于是下面那条「刻意什么都不该产出」
    /// 的断言立刻失败；同时因为 0 秒即刻收尾，用例不会卡在等 Ctrl-C 上。
    /// 按这个项目的规矩，「退回修复会红」验过才算回归用例。
    func testRecordWithHelpPrintsUsageInsteadOfRecording() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-help-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let code = await MeetingRecorderCLI.run(
            ["record", "--help", "--seconds", "0", "--root", root.path])

        XCTAssertEqual(code, 0, "打印用法是正常结束，不是失败")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                       "只打印用法：不得建任何会话目录、不得落任何音频")
    }

    /// 同一个坑的另外两种进法：`-h`、以及跟在别的参数后面的 `--help`。
    func testTranscribeWithHelpAlsoStopsBeforeTouchingAnything() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-help2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcribeCode = await MeetingRecorderCLI.run(["transcribe", "-h", "--root", root.path])
        let recordCode = await MeetingRecorderCLI.run(["record", "--pcm16", "--help"])
        XCTAssertEqual(transcribeCode, 0)
        XCTAssertEqual(recordCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                       "`transcribe -h` 不该去扫会议库、更不该建目录")
    }

    // MARK: - C08 / C09：删除的护栏

    /// **没有 `--yes` 一律只打印不执行。**
    ///
    /// 这条守的是一份 244 MiB 的资产：删了要重新下载，而误删的触发方式极其普通——
    /// 少打一个词、或者把 `remove` 当 `status` 用。所以护栏必须能被断言到，
    /// 而不是「我读过代码，它没删」。
    func testRemoveWithoutYesKeepsEverything() async throws {
        try installSparseAssets()
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))

        try await MeetingRecorderCLI.runModel(["remove"], paths: paths)

        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path),
                      "没有 --yes 时不得删除任何东西")
        for asset in SenseVoiceAssets.all {
            XCTAssertEqual(SenseVoiceModelStore.fileSize(at: paths.url(for: asset)),
                           asset.byteCount, "\(asset.kind.displayName) 被动过")
        }
    }

    /// 加了 `--yes` 才真的删。
    func testRemoveWithYesDeletesTheAssetDirectory() async throws {
        try installSparseAssets()

        try await MeetingRecorderCLI.runModel(["remove", "--yes"], paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path), "应已删除")
    }

    /// 本来就不存在 → 不当错误（`remove --yes` 可以安全重复执行）。
    func testRemoveWithYesOnMissingDirectoryIsNotAnError() async throws {
        try await MeetingRecorderCLI.runModel(["remove", "--yes"], paths: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
    }

    // MARK: - C07：全量校验

    /// 什么都没装时，`verify` **必须以非 0 退出**。
    ///
    /// `verifyAll()` 对不存在的文件返回空数组（它不报「不符」），所以只看 failures
    /// 的话这个命令会在全新机器上安静地成功退出——脚本据此认为「资产完好」，
    /// 继续跑一场注定失败的转写。说不清「验过没有」的绿灯比红灯更危险。
    func testVerifyRefusesToSucceedWhenNothingWasChecked() async {
        do {
            try await MeetingRecorderCLI.runModel(["verify"], paths: paths)
            XCTFail("没有资产可校验时必须抛错，而不是静默成功")
        } catch let error as MRError {
            XCTAssertTrue("\(error)".contains("没有校验到东西"), "错误信息：\(error)")
        } catch {
            XCTFail("应抛 MRError，实际：\(error)")
        }
    }

    // MARK: - C01：状态是只读的

    /// `model` / `model status` 只查状态，**不得顺手建目录**。
    /// 一次「我只是想看看」不该在磁盘上留下任何痕迹。
    func testStatusDoesNotCreateAnything() async throws {
        try await MeetingRecorderCLI.runModel([], paths: paths)
        try await MeetingRecorderCLI.runModel(["status"], paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path),
                       "查询状态不得建目录")
    }
}
