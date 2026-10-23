import Foundation

/// 统一错误类型。每条都带足够定位问题的上下文——排查音频链路时「哪个环节、什么状态码」
/// 比错误描述本身重要得多。
///
/// ## 同时实现 `CustomStringConvertible` 与 `LocalizedError`
///
/// 这不是冗余。`LocalizedError.errorDescription` 是 `NSError` 桥接时的取值来源，
/// 而 **`error.localizedDescription` 对只实现 `CustomStringConvertible` 的类型
/// 会退化成 `MRCore.MRError 错误 0`** —— 错误文案整条丢失，只剩类型名和序号。
///
/// 这不是理论问题：`transcode --all` 的逐场失败处理原本就走的 `localizedDescription`，
/// 于是批量迁移里每一场的真实失败原因全部被吞成同一句废话，
/// 而批量场景恰恰是最需要逐场原因的场景。
/// 在类型上补齐 `LocalizedError`，所有调用点一次性都好，不必逐处记得换写法。
public enum MRError: Error, CustomStringConvertible, LocalizedError, Equatable {

    case io(path: String, reason: String)
    case invalidWAV(path: String, reason: String)
    case deviceNotFound(uid: String)
    case noInputDevice
    /// 双轨都没起来。必须把**累积的具体原因**带出来——
    /// 只说「没有可用的输入设备」会让权限问题、HAL 超时、设备被切走三者无法区分。
    case captureFailed(reasons: [String])
    case permissionDenied(what: String, hint: String)
    case coreAudio(operation: String, status: Int32)
    case transcription(reason: String)
    /// 命令行参数本身非法（互斥参数同时给出、取值超范围等）。
    /// 与 `io` / `coreAudio` 分开是为了让「用户写错了参数」和「环境出问题」
    /// 在退出码与文案上都能区分开。
    case invalidArgument(String)

    public var description: String {
        switch self {
        case let .io(path, reason):
            return "文件读写失败 [\(path)]: \(reason)"
        case let .invalidWAV(path, reason):
            return "WAV 文件非法 [\(path)]: \(reason)"
        case let .deviceNotFound(uid):
            return "找不到指定设备 UID=\(uid)"
        case .noInputDevice:
            return "系统没有可用的音频输入设备"
        case let .captureFailed(reasons):
            guard !reasons.isEmpty else { return "未能启动任何音轨" }
            return "未能启动任何音轨，原因如下：\n"
                + reasons.map { "    · \($0)" }.joined(separator: "\n")
        case let .permissionDenied(what, hint):
            return "缺少权限：\(what)。\(hint)"
        case let .coreAudio(op, status):
            return "Core Audio 调用失败 \(op) → OSStatus \(status)"
        case let .transcription(reason):
            return "转写失败：\(reason)"
        case let .invalidArgument(reason):
            return "参数错误：\(reason)"
        }
    }

    /// 与 `description` **刻意同源**，不各写一份。
    ///
    /// 两份文案分头维护的话，迟早会有一处加了上下文另一处没加——
    /// 而踩到的那一处通常正是排查问题时唯一能看到的那一处。
    public var errorDescription: String? { description }
}

/// 把 OSStatus 渲染成四字符码，排查 Core Audio 问题时比十进制直观得多
public func fourCC(_ status: Int32) -> String {
    let v = UInt32(bitPattern: status)
    let bytes = [
        UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
        UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF),
    ]
    let text = String(bytes: bytes, encoding: .ascii) ?? "????"
    let printable = text.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
    return printable ? "\(status) ('\(text)')" : "\(status)"
}
