import Foundation

/// `main.swift` 在顶层代码里不能 `await`，所以 CLI 的异步入口需要一个同步包装。
///
/// 这里用信号量把异步调用压成同步。看起来像「阻塞主线程」，但实际不必担心死锁：
/// CLI 内部所有等待都发生在别的线程上（录音靠 `DispatchSource`，
/// 转写靠 `Task`），主线程只需等一个最终结果。
extension MeetingRecorderCLI {

    /// 同步执行 CLI，返回进程退出码。
    public static func runSynchronously(_ arguments: [String]) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        // 用锁保护：写入发生在并发任务的线程上，读取在主线程
        let box = ExitCodeBox()

        Task.detached(priority: .userInitiated) {
            let code = await MeetingRecorderCLI.run(arguments)
            box.store(code)
            semaphore.signal()
        }

        semaphore.wait()
        return box.load()
    }
}

/// 极小的加锁容器。只为跨线程传一个退出码，不值得引入别的东西。
private final class ExitCodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32 = 0

    func store(_ newValue: Int32) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }

    func load() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
