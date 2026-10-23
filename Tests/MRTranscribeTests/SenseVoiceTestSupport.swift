import Foundation
import XCTest
@testable import MRTranscribe
@testable import MRCore

/// 测试公用的小工具。
enum TestFiles {
    /// 造一个指定字节数的文件。
    ///
    /// 用 `truncate` 造**稀疏文件**：SenseVoice 权重的真实体积是 242 MiB，
    /// 而「就绪门槛」判的是精确字节数。真写满磁盘的话这类用例根本跑不起来，
    /// 而稀疏文件创建与删除都是瞬时的、不占实际块。
    static func makeFile(at url: URL, bytes: Int, executable: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw MRError.io(path: url.path, reason: "无法创建测试文件")
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}

/// 假子进程执行器。
///
/// `@unchecked Sendable` 的依据：所有可变状态都在 `lock` 下读写。
final class FakeProcessRunner: SenseVoiceProcessRunning, @unchecked Sendable {

    struct Invocation: Equatable {
        var executable: URL
        var arguments: [String]
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []

    /// 下一次 `run` 的返回值（先看 `error`）。
    var result = SenseVoiceProcessResult(
        standardOutput: "", standardError: "", exitCode: 0)
    var error: Error?

    var invocations: [Invocation] {
        lock.withLock { _invocations }
    }

    var lastArguments: [String]? { invocations.last?.arguments }

    func run(executable: URL, arguments: [String]) async throws -> SenseVoiceProcessResult {
        // 用 `withLock` 而不是裸的 lock/unlock：`run` 是 async，
        // 而 `NSLock.lock()` 在异步上下文里会被编译器判成不安全（Swift 6 起是错误）。
        lock.withLock {
            _invocations.append(Invocation(executable: executable, arguments: arguments))
        }
        if let error { throw error }
        return result
    }
}

/// 一套「资产就绪」的临时 Fixture。
struct SenseVoiceFixture {
    var base: URL
    var paths: SenseVoicePaths
    var runner: FakeProcessRunner

    /// 造一个临时基目录。默认**不**创建任何资产。
    static func make(
        directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-fixture-\(UUID().uuidString)", isDirectory: true)
    ) -> SenseVoiceFixture {
        SenseVoiceFixture(
            base: directory,
            paths: SenseVoicePaths(baseDirectory: directory),
            runner: FakeProcessRunner())
    }

    /// 补齐权重 + VAD（精确字节数，稀疏文件）。
    func installModels() throws {
        try TestFiles.makeFile(
            at: paths.url(for: SenseVoiceAssets.model), bytes: SenseVoiceAssets.model.byteCount)
        try TestFiles.makeFile(
            at: paths.url(for: SenseVoiceAssets.vad), bytes: SenseVoiceAssets.vad.byteCount)
    }

    /// 补齐运行时（稀疏文件 + 可执行位），字节数与官方清单一致。
    ///
    /// 这里**刻意**跟清单对齐：绝大多数用例关心的是「资产齐全 → 门槛通过」，
    /// 而「字节数不同但可执行」是**另一个**场景（自建 / 异版本构建），
    /// 它有自己的用例（`installSelfBuiltRuntime`），不该混进来。
    ///
    /// 早先这里写死 4096 字节，且当时运行时门槛判的是「精确字节数」，
    /// 于是所有「资产齐全」的用例都卡在 `字节数不符（期望 3008104，实际 4096）`——
    /// 那种红色看起来像产品坏了，其实是 fixture 没按自己的约定造文件。
    /// 现在门槛是「存在 + 可执行」，但这两条约定仍然分开写，避免再次互相掩盖。
    func installRuntime() throws {
        try TestFiles.makeFile(
            at: paths.installedRuntimeURL,
            bytes: SenseVoiceAssets.runtime.byteCount,
            executable: true)
    }

    /// 造一份**自建 / 异版本**运行时：字节数与官方清单不同，但确实可执行。
    ///
    /// 它的意义是把「字节数」与「能不能用」这两件事分开：门槛只看后者，
    /// 前者只影响 `model verify` 的报告。
    func installSelfBuiltRuntime(bytes: Int = 128) throws {
        try TestFiles.makeFile(
            at: paths.installedRuntimeURL, bytes: bytes, executable: true)
    }

    func installEverything() throws {
        try installModels()
        try installRuntime()
    }

    /// 用注入的 paths / runner / 空环境造一个引擎。
    ///
    /// 环境显式传空字典：否则开发机上恰好设了 `MEETING_RECORDER_SENSEVOICE_RUNTIME`
    /// 就会让用例的结果随环境变化——那种「在我机器上是绿的」的用例没有价值。
    func makeEngine(language: String = "zh-CN") -> SenseVoiceTranscriptionEngine {
        SenseVoiceTranscriptionEngine(
            language: language, paths: paths, runner: runner, environment: [:], bundle: .main)
    }

    func makeInference() -> SenseVoiceInference {
        SenseVoiceInference(paths: paths, runner: runner, environment: [:], bundle: .main)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }
}
