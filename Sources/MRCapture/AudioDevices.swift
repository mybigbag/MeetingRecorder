import Foundation
import CoreAudio
import MRCore

/// 一个音频设备的可读信息
public struct AudioDeviceInfo: Equatable {
    public var id: AudioDeviceID
    public var uid: String
    public var name: String
    /// 输入通道数（0 表示该设备没有输入能力）
    public var inputChannels: Int

    public var displayName: String { name.isEmpty ? uid : name }
}

/// 音频设备枚举与查询。
///
/// **为什么必须按 UID 锁定设备**：实际机器上除了内置麦克风，还有一个
/// 「iPhone」麦克风（连续互通）。默认输入设备随时可能被系统切走，
/// 录音工具若不显式锁定，会录出一整段静音。这是实测踩到的坑。
public enum AudioDevices {

    // MARK: - 基础读取

    public static func deviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    public static func defaultInputDeviceID() -> AudioDeviceID? {
        deviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        deviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    public static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        // 显式取指针，而不是直接写 `&value`：后者的类型是「指向 Optional 的指针」，
        // 而 CoreAudio 写进来的是一个对象引用（CFString 的 Copy 规则，所有权归我们）。
        // 两者内存布局一致（Optional 引用走空指针优化），所以行为不变；
        // 写成 `withUnsafeMutablePointer` 只是把「这里确实是一块可写内存」讲明白。
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr, let s = value as String? else { return nil }
        return s
    }

    /// 统计某设备在指定方向上的通道数
    static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// 设备的输入流格式
    public static func inputStreamFormat(deviceID: AudioDeviceID) -> AudioStreamBasicDescription? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &asbd)
        return status == noErr ? asbd : nil
    }

    // MARK: - 设备信息

    public static func info(deviceID: AudioDeviceID) -> AudioDeviceInfo? {
        guard deviceID != 0 else { return nil }
        let uid = stringProperty(AudioObjectID(deviceID), kAudioDevicePropertyDeviceUID) ?? ""
        let name = stringProperty(AudioObjectID(deviceID), kAudioObjectPropertyName) ?? uid
        return AudioDeviceInfo(
            id: deviceID,
            uid: uid,
            name: name,
            inputChannels: channelCount(AudioObjectID(deviceID), scope: kAudioDevicePropertyScopeInput))
    }

    /// 所有具备输入能力的设备
    public static func inputDevices() -> [AudioDeviceInfo] {
        allDeviceIDs().compactMap { info(deviceID: $0) }.filter { $0.inputChannels > 0 }
    }

    /// 按 UID 精确查找输入设备
    public static func findInput(uid: String) -> AudioDeviceInfo? {
        inputDevices().first { $0.uid == uid }
    }

    // MARK: - 设备锁定（含降级）

    public struct ResolvedInput {
        public var device: AudioDeviceInfo
        /// 锁定的设备不可用、已降级到别的设备时，这里带原因
        public var warning: String?
        /// 是否用了用户原本指定的设备
        public var usedRequestedDevice: Bool
    }

    /// 解析该用哪个输入设备。
    ///
    /// 优先用调用方指定的 UID；指定的设备不在了（拔掉、iPhone 断开、
    /// 默认设备被切走）就退回系统默认输入，并把降级原因记下来——
    /// 静默换设备比换错设备更危险，用户必须能看到这件事发生过。
    public static func resolveInput(preferredUID: String?) throws -> ResolvedInput {
        if let uid = preferredUID, !uid.isEmpty {
            if let device = findInput(uid: uid) {
                return ResolvedInput(device: device, warning: nil, usedRequestedDevice: true)
            }
            guard let fallbackID = defaultInputDeviceID(),
                  let fallback = info(deviceID: fallbackID) else {
                throw MRError.deviceNotFound(uid: uid)
            }
            return ResolvedInput(
                device: fallback,
                warning: "指定的输入设备（UID=\(uid)）当前不可用，已降级到系统默认输入「\(fallback.displayName)」。"
                    + "如果该设备是连续互通麦克风，请确认 iPhone 仍在附近。",
                usedRequestedDevice: false)
        }
        guard let id = defaultInputDeviceID(), let device = info(deviceID: id) else {
            throw MRError.noInputDevice
        }
        return ResolvedInput(device: device, warning: nil, usedRequestedDevice: true)
    }

    // MARK: - 音频格式工具

    /// ASBD 是否浮点
    public static func isFloat(_ asbd: AudioStreamBasicDescription) -> Bool {
        (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    }

    /// ASBD 是否非交错（非交错时 AudioBufferList 每个 buffer 是一个通道）
    public static func isNonInterleaved(_ asbd: AudioStreamBasicDescription) -> Bool {
        (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    }
}

/// AudioBufferList → 交错 Float32。
///
/// Core Audio 非交错格式下每个 buffer 是一个通道，而 WAV 需要交错排列，
/// 这一步转换是必需的，也容易写错（把通道顺序或帧数搞混就会得到噪声）。
public enum AudioInterleaver {

    /// - Returns: 交错后的采样数组；格式不受支持时返回 nil
    public static func interleave(
        _ list: UnsafeMutableAudioBufferListPointer,
        channels: Int,
        nonInterleaved: Bool
    ) -> [Float]? {
        guard channels > 0, list.count > 0 else { return nil }

        if nonInterleaved {
            guard list.count >= channels else { return nil }
            var frames = Int.max
            for c in 0..<channels {
                let bytes = Int(list[c].mDataByteSize)
                guard bytes > 0 else { return nil }
                frames = min(frames, bytes / MemoryLayout<Float>.size)
            }
            guard frames > 0, frames != Int.max else { return nil }

            var out = [Float](repeating: 0, count: frames * channels)
            for c in 0..<channels {
                guard let raw = list[c].mData else { continue }
                let src = raw.assumingMemoryBound(to: Float.self)
                for i in 0..<frames { out[i * channels + c] = src[i] }
            }
            return out
        } else {
            guard let raw = list[0].mData else { return nil }
            let count = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { return nil }
            return [Float](UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: count))
        }
    }
}
