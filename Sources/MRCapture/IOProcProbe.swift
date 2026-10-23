import Foundation
import CoreAudio
import os
import MRCore

/// 用一次真实但极短的采集，回答「这个设备到底能不能出数据」。
///
/// 这件事没法靠读属性回答。`AudioObjectGetPropertyData` 查采样率、通道数、
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` 全部正常返回，而实际上一个 buffer
/// 都收不到——权限未授予时就是这个表现，且完全没有报错。
/// 唯一的证据是**真的把 IOProc 跑起来，等第一个 buffer 到达**。
///
/// **而且「收到 buffer」还不够。** 实测踩到过更阴的一种：buffer 按时到达、
/// 帧数完全正确、回调稳定触发，但每个采样值都是零。如果只判断「有没有收到 buffer」，
/// 这种静默失败会被判成通过。所以这里同时检查**采样内容是否非零**，
/// 两者都满足才算 `.warmed`。
///
/// 它与正式采集走**同一条** HAL 路径（`AudioDeviceCreateIOProcIDWithBlock`
/// → `AudioDeviceStart` → 回调），所以它过了，正式录制就大概率能过；
/// 它卡了，正式录制也一定卡。这正是 `doctor` 之前缺的那一环：
/// 只验到 tap 创建就报全绿，而 tap 创建是轻量路径，覆盖不到这里。
///
/// **必须带硬超时**：`AudioDeviceCreateIOProcIDWithBlock` 没有超时参数、
/// 也不能取消，coreaudiod 异常时它永不返回。探针本身绝不能把诊断程序挂死。
public enum IOProcProbe {

    /// 跨线程带回探针状态。只在信号量确认完成或读锁内访问。
    private struct State: Sendable {
        var gotBuffer = false
        var sawNonZero = false
    }

    /// 探测单个设备能否出数据。
    ///
    /// - Parameters:
    ///   - timeout: 等待第一个 buffer 的时长。有声音时通常几毫秒就到。
    ///   - hardDeadline: HAL 调用的硬超时。超过即判 `.timedOut`。
    /// - Returns: `.warmed` 收到 buffer 且采样非零；`.silent` 收到 buffer 但全零；
    ///            `.noData` 没收到 buffer；`.timedOut` HAL 未返回。
    public static func run(
        deviceID: AudioDeviceID,
        timeout: TimeInterval = 3.0,
        hardDeadline: TimeInterval = 5.0
    ) -> CaptureReadiness.Probe {
        var outcome: CaptureReadiness.Probe = .noData
        let result = BlockingCall.run(timeout: hardDeadline) {
            outcome = perform(deviceID: deviceID, timeout: timeout)
            return true
        }
        if case .timedOut = result { return .timedOut }
        return outcome
    }

    /// 真正的探测。
    ///
    /// **注意这里没有 `defer` 收尾**：一旦硬超时，本函数还在被遗弃的线程上跑，
    /// 它可能在任意时刻才真正返回，届时才轮到清理由它自己负责——这是刻意保留的
    /// 行为，因为从外面强行销毁一个正在创建中的 IOProc 更危险。
    private static func perform(
        deviceID: AudioDeviceID,
        timeout: TimeInterval
    ) -> CaptureReadiness.Probe {
        let state = OSAllocatedUnfairLock(initialState: State())

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID, deviceID, nil
        ) { _, inInputData, _, _, _ in
            // 逐字节判非零，不依赖具体采样格式（float32 / int16 都能用）
            var found = false
            let list = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            for buf in list {
                guard let data = buf.mData else { continue }
                let count = Int(buf.mDataByteSize)
                guard count > 0 else { continue }
                let bytes = data.assumingMemoryBound(to: UInt8.self)
                for i in 0..<count where bytes[i] != 0 {
                    found = true
                    break
                }
                if found { break }
            }
            // 先落成 `let` 再进闭包：`withLock` 的闭包是 `@Sendable`，
            // 捕获可变变量在 Swift 6 是错误。
            let anyNonZero = found
            state.withLock { s in
                s.gotBuffer = true
                if anyNonZero { s.sawNonZero = true }
            }
        }
        guard createStatus == noErr, let procID else { return .noData }
        defer { AudioDeviceDestroyIOProcID(deviceID, procID) }

        guard AudioDeviceStart(deviceID, procID) == noErr else { return .noData }

        let deadline = Date().addingTimeInterval(timeout)
        // 必须等到「非零」才提前收工，**不能**收到第一个 buffer 就退出：
        // 设备刚启动时的第一个 buffer 可能本来就是静音（数字零），
        // 见零就下结论会得到随机结果——实测同一台机器同一份代码，
        // 有时报「有数据」有时报「全零」，就是这个原因造成的。
        while Date() < deadline, !state.withLock({ $0.sawNonZero }) {
            Thread.sleep(forTimeInterval: 0.005)
        }
        AudioDeviceStop(deviceID, procID)

        let final = state.withLock { $0 }
        guard final.gotBuffer else { return .noData }
        return final.sawNonZero ? .warmed : .silent
    }
}
