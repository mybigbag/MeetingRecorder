import Foundation
import MRCore

/// 录音引擎的最小接口。
///
/// 存在的**唯一**理由是给 `RecordingController` 一个测试缝。
///
/// 真实录音需要「麦克风」和「系统音频录制」两项 TCC 授权，无头与 CI 环境给不了，
/// 于是「开始 → 准备 → 录制中 → 收尾 → 完成/失败」这条状态机就没有任何办法被测——
/// 而这条链路恰恰是界面录不了音时最先出问题的地方。有了这个协议就能注入一个假引擎，
/// 把整条链路连同落盘副作用一起跑完。
///
/// **刻意不要求 `Sendable`**：`DualTrackRecorder` 本身不是线程安全的。
/// 它持有的两条 `TrackRecorder` 各自带锁，但它自己的字段（`micRecorder`、
/// `sessionDirectory` 等）没有任何保护。跨线程的语义由调用方用一个
/// `@unchecked Sendable` 的持有者明确承担，而不是在这里假装它安全。
public protocol RecordingEngine: AnyObject {
    /// 创建会话目录并开始录制，返回会话 ID。**同步阻塞**（系统音频 tap 可耗秒级）。
    @discardableResult
    func start(title: String) throws -> String
    /// 收尾：flush 两条轨、写回 manifest。**同步阻塞**。
    func stop() throws -> DualTrackRecorder.Result
    /// 放弃录制，不 finalize，留下可恢复的现场。
    func abort()
    /// 暂停采集。暂停期间不写盘，音频里没有这一段。
    @discardableResult
    func pause() -> Bool
    /// 从暂停恢复。
    @discardableResult
    func resume() -> Bool
    /// 是否处于暂停
    var isPaused: Bool { get }
    /// 自开始录制以来经过的秒数（含准备阶段与暂停，墙钟）
    var elapsed: Double { get }
    /// 真正录到的秒数（内容时长，不含暂停）
    var recordedSeconds: Double { get }

    // MARK: - 分轨静音

    /// 静音 / 取消静音**某一轨**。
    ///
    /// 与 `pause()` 的区别是**产出的文件不同**：静音期间该轨照常写帧，
    /// 只是内容为全零，文件长度不变；`pause()` 会丢弃数据、文件变短。
    /// 分轨功能必须用前者——一轨变短就会与另一轨错位。
    @discardableResult
    func setMuted(_ muted: Bool, trackID: String) -> Bool

    /// 切换某一轨的静音。- Returns: 切换后的状态
    @discardableResult
    func toggleMute(trackID: String) -> Bool

    /// 某一轨当前是否被静音。
    ///
    /// 默认实现返回 `false`，而**不是**去问 `mutedTrackIDs`：
    /// 只关心全局暂停的假引擎不该因为实现了新的辅助属性而被迫写对实现。
    /// 真引擎（`DualTrackRecorder`）自己实现。
    func isMuted(trackID: String) -> Bool

    /// 某一轨累计静音秒数。用于界面如实告知。
    func mutedSeconds(trackID: String) -> Double
}

extension RecordingEngine {
    // 默认实现只为让「不关心暂停」「不关心分轨」的假引擎少写几个空方法。
    // 真实实现（`DualTrackRecorder`）全部自己实现——默认值在那边是错的。
    @discardableResult public func pause() -> Bool { false }
    @discardableResult public func resume() -> Bool { false }
    public var isPaused: Bool { false }
    public var recordedSeconds: Double { elapsed }

    @discardableResult public func setMuted(_ muted: Bool, trackID: String) -> Bool { false }
    @discardableResult public func toggleMute(trackID: String) -> Bool { false }
    public func isMuted(trackID: String) -> Bool { false }
    public func mutedSeconds(trackID: String) -> Double { 0 }
}

extension DualTrackRecorder: RecordingEngine {}
