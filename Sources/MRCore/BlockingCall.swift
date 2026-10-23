import Foundation

/// 给「可能永久阻塞、且无法取消」的系统调用加一道硬超时。
///
/// 为什么需要它：Core Audio 的 HAL 调用（`AudioDeviceCreateIOProcIDWithBlock`
/// 等）没有超时参数，也不能被取消。实测在 coreaudiod 处于异常状态时，
/// 这个调用**永不返回**——`sample` 抓到的调用栈就停在
/// `HAL_HardwarePlugIn_DeviceCreateIOProcIDWithBlock` 里。如果它落在主流程上，
/// 整个录制程序会静默卡死：日志停在启动步骤、WAV 文件只有 44 字节的空头。
///
/// 处理办法是把这类调用挪到后台线程，主流程用信号量等待固定时长。
///
/// **诚实的代价**：超时后被遗弃的那个线程无法回收，它可能在任意时刻才真正返回。
/// 所以它只适用于「本来就是可选的优化动作」，或「失败了可以直接放弃该资源」的场合；
/// 不要用它包裹必须确知结果的写操作。
public enum BlockingCall {

    public enum Outcome: Equatable {
        /// 在时限内返回，并带出工作结果
        case finished(Bool)
        /// 超时，工作线程已被遗弃
        case timedOut
    }

    /// 在后台线程执行 `work`，最多等 `timeout` 秒。
    /// - Parameter work: 返回是否成功。**必须能接受它可能永不返回。**
    public static func run(timeout: TimeInterval, _ work: @escaping () -> Bool) -> Outcome {
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            result.value = work()
            done.signal()
        }
        if done.wait(timeout: .now() + max(0, timeout)) == .timedOut {
            return .timedOut
        }
        return .finished(result.value)
    }

    /// 跨线程传递结果。仅在信号量已确认完成时才读取，因此不存在竞态。
    private final class ResultBox: @unchecked Sendable {
        var value = false
    }
}
