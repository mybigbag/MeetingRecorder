import Foundation
import MRCore

/// 一次子进程调用的原始结果。
public struct SenseVoiceProcessResult: Equatable, Sendable {
    public var standardOutput: String
    public var standardError: String
    public var exitCode: Int32
    /// 因信号而死时为 true（此时 `exitCode` 是信号编号，不是退出码）
    public var terminatedBySignal: Bool

    public init(
        standardOutput: String,
        standardError: String,
        exitCode: Int32,
        terminatedBySignal: Bool = false
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
        self.terminatedBySignal = terminatedBySignal
    }
}

/// 可替换的子进程执行器。测试用假实现注入，真机用 `SenseVoiceProcessRunner`。
public protocol SenseVoiceProcessRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> SenseVoiceProcessResult
}

/// 用 `Process` 跑推理运行时。
///
/// **为什么把子进程的输出导到临时文件，而不是用 `Pipe`：**
///
/// `Pipe` 有两个能把程序直接卡死的坑，而且都发生在「看起来完全正常」的路径上：
///
/// 1. **管道写满即死锁。** 管道内核缓冲约 64 KiB。子进程写 stdout 写到满就阻塞在 `write`
///    上等父进程读；父进程在 `waitUntilExit()` 上等子进程结束 —— 双方互等，永不返回。
///    一场长会议的 SRT 完全可能超过 64 KiB，这不是理论风险。
/// 2. **父进程自己持有写端 → 读端永远等不到 EOF。** `Pipe` 的写端在父进程里也是打开的，
///    除非显式关掉，否则 `readDataToEndOfFile()` 会一直等下去；而「显式关掉」又要先确认
///    Foundation 是否已经关过（重复关闭一个已被复用的 fd 会伤到无关的代码），这个判断很难做对。
///
/// 导到文件把两个问题一起消掉：没有容量上限，没有 EOF 语义依赖，读法就是普通文件读取。
/// 代价是拿不到流式输出——而这里本来也只需要「最终那份 SRT」。
public struct SenseVoiceProcessRunner: SenseVoiceProcessRunning {

    public init() {}

    public func run(executable: URL, arguments: [String]) async throws -> SenseVoiceProcessResult {
        // 「不存在」与「不可执行」要分开说。两者都会让 `Process` 失败，但修复动作不同，
        // 而 `Process` 自己抛出的错误里**一个字都不会提权限**——被 tar 解包丢掉可执行位
        // 是这条路径上最常见的坏法，用户看到的却会是别的东西。
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            let exists = FileManager.default.fileExists(atPath: executable.path)
            throw MRError.transcription(
                reason: exists
                    ? "推理运行时不可用（文件在，但不可执行、缺少可执行权限）：\(executable.path)\n"
                        + "  修复：chmod +x \"\(executable.path)\""
                        + "，或重新安装 `meeting-recorder model install-runtime`"
                    : "推理运行时不可用（文件不存在）：\(executable.path)\n"
                        + "  修复：`meeting-recorder model install-runtime`")
        }

        let call = try SenseVoiceProcessCall(executable: executable, arguments: arguments)
        defer { call.cleanup() }

        return try await withTaskCancellationHandler {
            // 阻塞式等待放进 detached task：`waitUntilExit()` 会占住一个协作线程池线程
            // 直到子进程结束，对一场长会议就是几十秒。
            //
            // 只捕获 `call`（一个 `@unchecked Sendable` 的盒子）而不是裸的 `Process`：
            // `Task.detached` 的闭包是 `@Sendable` 的，捕获非 Sendable 类型会触发
            // 并发检查告警——而本项目要求构建零告警。
            try await Task.detached(priority: .userInitiated) { () throws -> SenseVoiceProcessResult in
                try call.runBlocking()
            }.value
        } onCancel: {
            call.cancel()
        }
    }
}

/// 一次子进程调用的全部状态。
///
/// `@unchecked Sendable` 的依据：`process` 与 `cancelled` 都在 `lock` 下读写；
/// 其余字段（路径、参数）都是不可变值类型。没有别的可变状态。
private final class SenseVoiceProcessCall: @unchecked Sendable {

    private let executablePath: String
    private let arguments: [String]
    private let workDirectory: URL
    private let stdoutURL: URL
    private let stderrURL: URL

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(executable: URL, arguments: [String]) throws {
        self.executablePath = executable.path
        self.arguments = arguments
        self.workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-sv-process-\(UUID().uuidString)", isDirectory: true)
        self.stdoutURL = workDirectory.appendingPathComponent("stdout.txt")
        self.stderrURL = workDirectory.appendingPathComponent("stderr.txt")

        do {
            try FileManager.default.createDirectory(
                at: workDirectory, withIntermediateDirectories: true)
        } catch {
            throw MRError.io(path: workDirectory.path,
                             reason: "无法创建子进程临时目录：\(error.localizedDescription)")
        }
        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// 用信号终止子进程。若取消发生在进程启动**之前**，只记下标志，
    /// 由 `attach` 在启动后补一刀——否则那个进程会成为没人管的孤儿，
    /// 把 CPU 吃满直到自己跑完，用户看到的是「取消之后风扇还在转」。
    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    private func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled, process.isRunning { process.terminate() }
    }

    private var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func runBlocking() throws -> SenseVoiceProcessResult {
        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        do {
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            throw MRError.io(path: workDirectory.path,
                             reason: "无法打开子进程输出文件：\(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            throw MRError.transcription(
                reason: "无法启动推理运行时 \(executablePath)：\(error.localizedDescription)")
        }

        attach(process)
        process.waitUntilExit()

        try? stdoutHandle.close()
        try? stderrHandle.close()

        if wasCancelled { throw CancellationError() }

        let stdout = try SenseVoiceProcessRunner.readOutput(at: stdoutURL, label: "stdout")
        let stderr = try SenseVoiceProcessRunner.readOutput(at: stderrURL, label: "stderr")
        return SenseVoiceProcessResult(
            standardOutput: stdout,
            standardError: stderr,
            exitCode: process.terminationStatus,
            terminatedBySignal: process.terminationReason == .uncaughtSignal)
    }
}

extension SenseVoiceProcessRunner {

    /// 读子进程的输出文件。
    ///
    /// **读不出来不能当成「没有输出」。** 本模块有一条判据：「退出码 0 + 空输出 =
    /// 这段确实没语音」（整段静音时运行时就是这样收场的）。如果这里用
    /// `(try? String(…)) ?? ""` 把读失败也变成空串，那么「文件不见了」「权限不对」
    /// 「内容不是 UTF-8」这几种**真实故障**会全部伪装成「没人说话」——
    /// 用户得到一份空稿，还会以为会议确实很安静。
    ///
    /// 解码用**容错**方式（`String(decoding:as:)` 而不是会抛错的
    /// `String(contentsOf:encoding:)`）：输出被截断在半个多字节字符上时，
    /// 我们要的是「确实拿到了内容」这个事实，而不是因为一个替换字符
    /// 就把一次成功的转写判成失败。
    ///
    /// 放在 `SenseVoiceProcessRunner` 上（而不是留在私有的调用盒子里）是刻意的：
    /// 这条分支只在异常输入下才走到，而它守的正是「不许把读失败说成没输出」，
    /// 值得被单独钉住。
    static func readOutput(at url: URL, label: String) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MRError.transcription(
                reason: "推理运行时的 \(label) 输出文件不见了：\(url.path)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MRError.transcription(
                reason: "推理运行时的 \(label) 输出读不出来（\(url.path)）："
                    + error.localizedDescription)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
