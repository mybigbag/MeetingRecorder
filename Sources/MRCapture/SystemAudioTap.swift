import Foundation
import CoreAudio
import os
import MRCore

/// 系统音频捕获用的 Core Audio Process Tap。
///
/// 有四条必须遵守的硬约束，全部来自实测踩坑：
///
/// 1. **必须打包成 .app bundle**。裸 CLI 可执行文件在 macOS 26 上拿不到
///    `kTCCServiceAudioCapture` 权限，而且失败是**静默的**——所有 API 返回 0、
///    采样点数完全正确，但缓冲区全是零。代码没错，是形态不对。
/// 2. **PID 不能直接当 AudioObjectID 用**，必须先经 TranslatePIDToProcessObject 翻译，
///    否则返回 `!obj`(560947818)。
/// 3. 权限有两套，「屏幕与系统音频录制」与「仅系统音频录制」是不同开关，授错那个仍然无声。
/// 4. **绝对不要在同一个聚合设备上 `stop` 之后再 `start`。** 第二次 buffer 照常到达、
///    帧数完全正确、无任何报错，但采样值**全是零**。本项目因此长期误判为「授权没生效」，
///    查了很多轮才定位到。详见类末尾的说明。
///
/// 排查这类问题时用 `doctor`：它会把「收到 buffer 但采样全零」单独标出来，
/// 这比「tap 创建成功」有意义得多。
///
/// **一个排查陷阱**：从终端 / IDE 的 shell 里直接 exec bundle 内的二进制时，
/// TCC 认定的责任进程是宿主 app（例如 Electron），**不是这个 bundle**
/// （证据看崩溃报告的 `responsibleProc`）。所以「换一个已授权的 app 就能抓到」
/// 这类观察没有说服力，别据此下「本 app 没授权」的结论。真正干净的对照是
/// **同一个二进制分别装进两个 bundle**，这样只有身份一个变量。
public final class SystemAudioTap {

    public let tapID: AudioObjectID
    public let aggregateDeviceID: AudioObjectID
    public let name: String

    private var destroyed = false

    private init(tapID: AudioObjectID, aggregateDeviceID: AudioObjectID, name: String) {
        self.tapID = tapID
        self.aggregateDeviceID = aggregateDeviceID
        self.name = name
    }

    /// PID → Core Audio process object。
    /// 直接用 PID 会得到 kAudioHardwareBadObjectError。
    public static func processObject(for pid: pid_t) -> AudioObjectID? {
        var p = pid
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var objectID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, UInt32(MemoryLayout<pid_t>.size), &p, &size, &objectID)
        return status == noErr && objectID != 0 ? objectID : nil
    }

    /// 创建全局系统音频 tap（可选排除自己的进程，避免把提示音录进去）
    public static func create(
        name: String = "meeting-recorder-tap",
        excludingCurrentProcess: Bool = true
    ) throws -> SystemAudioTap {

        var excluded: [AudioObjectID] = []
        if excludingCurrentProcess, let selfObject = processObject(for: getpid()) {
            excluded = [selfObject]
        }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = name
        desc.isPrivate = true
        // `isExclusive = true` 的语义是「录制除列表外的所有进程」，而
        // stereoGlobalTapButExcludeProcesses 这个构造器本身就隐含了该语义，
        // 所以这一行是冗余的。读 SDK 头文件（CATapDescription.h）可确认，
        // 实测也验证过：加不加它，RMS 都在 0.0625 附近，没有任何差别。
        //
        // 保留它只为「与已验证通过的配置逐字一致」，避免引入无谓变量。
        // 注意：它**不是**「不影响其他进程播放」的意思——那件事由下面
        // muteBehavior = .unmuted 负责。
        desc.isExclusive = true
        desc.muteBehavior = .unmuted     // 不静音原输出，会议照常听得见

        var tapID = AudioObjectID(0)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
        guard tapStatus == noErr, tapID != 0 else {
            throw MRError.permissionDenied(
                what: "创建系统音频 tap",
                hint: "OSStatus \(fourCC(tapStatus))。确认程序从带 NSAudioCaptureUsageDescription 的 .app 运行。")
        }

        // tap 只有在挂进聚合设备后才能被 IOProc 读取
        var aggregateID = AudioObjectID(0)
        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: name,
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceSubDeviceListKey as String: [],
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapUIDKey as String: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey as String: true,
            ]],
            kAudioAggregateDeviceMainSubDeviceKey as String: "",
        ]
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDesc as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr, aggregateID != 0 else {
            AudioHardwareDestroyProcessTap(tapID)
            throw MRError.coreAudio(operation: "创建聚合设备", status: aggregateStatus)
        }

        return SystemAudioTap(tapID: tapID, aggregateDeviceID: aggregateID, name: name)
    }

    public func destroy() {
        guard !destroyed else { return }
        destroyed = true
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        AudioHardwareDestroyProcessTap(tapID)
    }

    // MARK: - 为什么这里没有「预热」
    //
    // 本项目曾经有一个 `warmUp()`：在正式录制前先把聚合设备空跑一次
    // （create IOProc → start → 等到数据 → stop），用意是消化「首次启动约 1.6 秒」
    // 的冷初始化开销，避免两条轨错开。
    //
    // **这个方法是错的，已被删除。** 两条原因，都由实验确定：
    //
    // 1. **它必然让正式录制采到全零。** 对一个「纯 tap 聚合设备」（sub-device list
    //    为空、只挂了 tap）执行 start → stop → 再 start，第二次 start 之后 buffer
    //    照常按时到达、帧数完全正确、没有任何报错，但**每个采样值都是零**。
    //    实测（同一聚合设备，同一份代码）：
    //
    //        预热 RMS = 0.122627  ✅
    //        正式 RMS = 0.000000  ❌   ← stop 之后再 start
    //
    //    换一个新聚合设备则不预热也正常（0.123413）；预热后**销毁并重建**聚合设备、
    //    在重建的设备上正式录制也正常（0.123236）。所以破坏来自 stop/start 本身。
    //
    // 2. **它想解决的那个问题根本不存在。** 重新实测聚合设备的首次
    //    `AudioDeviceStart`：**0.009 秒**（换一个新设备再测 0.012 秒，到首个 buffer
    //    再 +0.012 秒）。此前注释里写的「首次要 1.6 秒」是早期环境下的观察，
    //    在当前系统上不成立。既然没有冷启动开销，预热的收益就是零。
    //
    // 净效果：**零收益 + 确定性的破坏**。所以三阶段启动现在是两阶段，
    // 正式启动前不再碰聚合设备。
    //
    // 如果将来真需要「同设备重启」这种操作，唯一安全的做法是
    // **销毁旧聚合设备并连同 tap 一起重建**，绝不在同一个设备上 stop 后再 start。
    // 回归验证脚本见 `audiocap-probe/src/warmup-test.swift` 与 `warmup-test2.swift`。

    deinit { destroy() }
}
