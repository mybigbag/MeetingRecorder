import Foundation
import CoreAudio
import os
import MRCore

/// 单条音轨的采集器：把一个音频设备的输入流写成一个 WAV 文件。
///
/// 时间轴唯一基准是**每个 buffer 自带的 `mHostTime`**。
/// 采样点数只用来校验连续性，绝不用来推算时间——实测样本数会偏离真实时长
/// （8 秒差 10.7ms、26 秒差 21.3ms），且偏差随内容变化，不是恒定的时钟漂移。
///
/// 锁的选择：采集回调跑在实时线程上，用 `OSAllocatedUnfairLock` 而不是 `NSLock`，
/// 且**整个回调只加一次锁**（嵌套加锁会死锁，写盘与统计在同一次持有内完成）。
public final class TrackRecorder {

    private struct MutableState: Sendable {
        var stats: TrackStats
        /// 写盘前的变换（降混 + 重采样）。
        ///
        /// 放在被同一把锁保护的 mutable state 里，而不是当成类的只读属性：
        /// 它**是有状态的可变对象**（重采样器要跨块保留滤波器历史与相位），
        /// 而采集回调、`stop()` 的排空都会动它——和 `stats` 受同一套并发约束。
        var pipeline: TrackSamplePipeline
        var warnings: [String] = []
        var running = false
        var bufferCount = 0
        var missingTimestampBuffers = 0
        /// 4 GiB 上限告警只报一次，避免每秒刷 48 条
        var sizeLimitWarned = false
        /// 出现过的最大绝对采样值。
        ///
        /// 它存在的唯一理由是回答「这一轨录到东西了吗」：
        /// 授权未生效时录制会正常完成、帧数正确，但每个采样都是零。
        /// 只看帧数会以为成功，必须看内容。
        var peakAmplitude: Double = 0
        /// 是否处于暂停
        var paused = false
        /// 是否处于静音（分轨掐掉这一段）
        ///
        /// **与 `paused` 严格区分，两者产出的文件完全不同**：
        /// - `paused`（全局暂停）：数据**丢弃**，音频里没有这一段，文件变短。
        /// - `muting`（分轨静音）：数据仍**走完管线并写盘**，只是写全零，
        ///   音频里这一段是静音，文件长度不变。
        ///
        /// 两者混用的后果不是"风格不一致"，而是**时间轴直接错位**：
        /// 一轨掐掉 10 分钟、另一轨正常录，两轨文件长度就差 10 分钟，
        /// 双轨并排回放与按轨对齐的转写都会失准。
        var muting = false
        /// 静音累计秒数。
        ///
        /// **它不参与 `pausedSeconds` 的时长计算**——静音期间帧照写、
        /// 统计照累计，这一轨的内容时长本来就该包含这段时间。
        /// 单列一个字段是为了如实告知「这轨有多少时间是人为掐掉的」。
        var mutedSeconds: Double = 0
        /// 静音期间写下的 buffer 数（诊断用：静音没生效时这个值会是 0）
        var mutedBuffers = 0
        /// 暂停期间丢弃了多少个 buffer（诊断用：暂停没生效时这个值会是 0）
        var skippedBuffers = 0
        /// 刚恢复：下一个到达的 buffer 要先把暂停空档记进 `stats.pausedSeconds`
        ///
        /// 之所以要这个标记：暂停时我们不做任何记账，恢复后第一个 buffer 的
        /// `hostTime` 离上一个已写入 buffer 的结束时刻隔了一整段暂停。
        /// 不显式记下来，那段空档就会被算进 `clockDuration`。
        var pendingPauseGap = false
        /// 静音期间复用的全零缓冲区。采集回调在实时线程上，不能每次现分配。
        var silenceScratch = [Float]()

        /// 取一块**恰好 `count` 个采样、且全为零**的缓冲区（复用，不每次分配）。
        ///
        /// 只在静音路径调用。长度必须与源等长，见采集回调里那段说明——
        /// 重采样器的输出长度由输入长度决定，改长度就会让这一轨与另一轨错位。
        ///
        /// 复用时**必须重新清零**，不能因为「刚才是全零」就直接返回：
        /// `TrackSamplePipeline.process` 在恒等路径下原样返回输入数组，
        /// 而写入器拿到的正是这块缓冲的同一份存储。不清零的话，
        /// 第一次静音之后这块内存可能已经被别处写入过声音，
        /// 而"静音里混进人声"恰好是这个功能要杜绝的那件事，且没有任何报错。
        mutating func silenceBuffer(sourceCount count: Int) -> [Float] {
            if silenceScratch.count != count {
                silenceScratch = [Float](repeating: 0, count: count)
            } else {
                silenceScratch.withUnsafeMutableBufferPointer { raw in
                    for index in raw.indices { raw[index] = 0 }
                }
            }
            return silenceScratch
        }
    }

    public let id: String
    public let role: TrackRole
    public let fileURL: URL
    /// **源**（设备）采样率。用来解释采集回调里的交错缓冲区，也是本轨统计/漂移的基准。
    public let sourceSampleRate: Double
    /// **源**（设备）声道数
    public let sourceChannels: Int
    /// **写进文件**的格式（采样率 + 声道数）。
    ///
    /// 与源格式分开，是因为两者错配的后果**很隐蔽**：`TrackManifest.duration` 是
    /// `framesWritten / sampleRate`，manifest 若记了源采样率而文件其实是降采样后的，
    /// 界面上的时长会正好差一倍，而没有任何地方会报错。
    /// 源格式给统计（漂移比较的是「采集到的帧数 vs 时钟」），写入格式给文件和 manifest。
    public let writeFormat: TrackWriteFormat
    /// 写盘用的采样格式（位深）。与 `writeFormat` 并列，
    /// 三者一起构成「这个文件占多大」的全部参数。
    ///
    /// 暴露出来是因为它**只写在 WAV 头里**：构造参数传错了，
    /// 要等录完、去读文件头才能发现。有了这个属性，构造完就能核。
    public let sampleFormat: WAVSampleFormat
    public let deviceID: AudioDeviceID
    public let deviceName: String?
    /// 降混策略。暴露出来是为了让「这一轨是怎么混出来的」在录完就能核，
    /// 而不是只能反推文件参数——源是双声道时，两种策略产出的文件**参数完全一样**。
    public let downmixStrategy: MonoDownmixStrategy

    private let writer: WAVWriter
    private let nonInterleaved: Bool
    private let lock: OSAllocatedUnfairLock<MutableState>
    private var procID: AudioDeviceIOProcID?

    /// 跨线程带回 HAL 调用结果。只在信号量确认完成后读取，不存在竞态。
    private final class ResultBox: @unchecked Sendable {
        var procID: AudioDeviceIOProcID?
        var status: OSStatus = -1
    }

    // MARK: - 只读状态

    public var stats: TrackStats { lock.withLock { $0.stats } }
    public var warnings: [String] { lock.withLock { $0.warnings } }

    /// 本轨是否发生过**降混相位抵消**（源多声道有声音，合并后变成静音）。
    ///
    /// 暴露给协调器是为了让收尾自检能给出**准确**的原因，而不是并列两种猜测：
    /// 「全零」在数据上分不清「没出声」与「被抵消」，但录制侧知道。
    public var phaseCancelled: Bool { lock.withLock { $0.pipeline.didCancel } }
    public var isRunning: Bool { lock.withLock { $0.running } }
    public var bufferCount: Int { lock.withLock { $0.bufferCount } }

    /// 无时间戳的 buffer 数。非零说明设备没提供 mHostTime，时间轴可信度下降。
    public var missingTimestampBuffers: Int { lock.withLock { $0.missingTimestampBuffers } }

    /// 该轨出现过的最大绝对采样值。
    ///
    /// **0 且帧数 > 0** 表示「录到了，但内容是空的」——授权未生效的典型表现。
    /// 只有帧数无法区分这种情况，必须看这个值。
    public var peakAmplitude: Double { lock.withLock { $0.peakAmplitude } }

    public var framesWritten: Int { writer.framesWritten }

    /// 该轨是否已触达单个 WAV 文件的 4 GiB 上限（此后音频不再写入）
    public var didReachSizeLimit: Bool { writer.didReachSizeLimit }

    /// 当前是否处于暂停
    public var isPaused: Bool { lock.withLock { $0.paused } }

    /// 当前是否处于静音（分轨掐掉，但文件长度不变）
    public var isMuting: Bool { lock.withLock { $0.muting } }

    /// 静音累计秒数。**不要用它去减时长**——见 `MutableState.mutedSeconds`。
    public var mutedSeconds: Double { lock.withLock { $0.mutedSeconds } }

    /// 静音期间写下的 buffer 数。用于验证「静音真的生效了」——
    /// 只看状态位的话，一个从没被调进回调的实现也能报「已静音」。
    public var mutedBuffers: Int { lock.withLock { $0.mutedBuffers } }

    /// 暂停造成的时钟空档累计（秒）。见 `TrackStats.pausedSeconds`。
    public var pausedSeconds: Double { lock.withLock { $0.stats.pausedSeconds } }

    /// 暂停期间被丢弃的 buffer 数。用于验证「暂停真的生效了」——
    /// 只看状态位的话，一个从没被调进回调的实现也能报「已暂停」。
    public var skippedBuffers: Int { lock.withLock { $0.skippedBuffers } }

    // MARK: - 初始化

    public init(
        id: String,
        role: TrackRole,
        deviceID: AudioDeviceID,
        deviceName: String?,
        fileURL: URL,
        sourceSampleRate: Double,
        sourceChannels: Int,
        sourceIsInterleaved: Bool,
        writeSampleRate: Double? = nil,
        writeChannels: Int? = nil,
        format: WAVSampleFormat = .float32,
        downmixStrategy: MonoDownmixStrategy = .firstChannel
    ) throws {
        guard sourceSampleRate > 0, sourceChannels > 0 else {
            throw MRError.coreAudio(operation: "初始化音轨 \(id)：采样率或通道数非法", status: -1)
        }
        let resolvedWrite = TrackWriteFormat(
            sampleRate: writeSampleRate ?? sourceSampleRate,
            channels: writeChannels ?? sourceChannels)

        // 写前管线只实现两种情形：**与源完全一致（不变换）**，或**合并到单声道 + 重采样**。
        // 不在此列的组合直接抛错，而不是让它静默按单声道写出去——
        // 静默的后果是「要了立体声却只得到一个声道」，且文件头还写着 2 声道，
        // 到回听时才发现少了一半内容。`TrackWriteFormat.resolve` 不会产出这种组合，
        // 这道 guard 挡的是将来有人绕过它直接构造出来的情况。
        let identity = TrackWriteFormat(sampleRate: sourceSampleRate, channels: sourceChannels)
        guard resolvedWrite == identity || resolvedWrite.channels == 1 else {
            throw MRError.coreAudio(
                operation: "初始化音轨 \(id)：不支持的写入格式 \(resolvedWrite.displayName)"
                    + "（源为 \(Int(sourceSampleRate)) Hz · \(sourceChannels) 声道）。"
                    + "只支持「与源一致」或「合并为单声道」两种。",
                status: -1)
        }
        // 升采样同样挡住。`TrackWriteFormat.resolve` 取 `min(源率, 24000)`，本来就绝不升采样；
        // 而重采样器的升采样分支在「整块 vs 分块」下输出长度会差 1~3 个样本
        // （尾部前瞻条件 `position + 1 < count` 吃掉了最后几个输出），
        // 与「分块不得改变输出长度」这条不变量冲突，也与 `resolve` 的纪律相悖。
        // 生产路径本来就到不了这里，这道 guard 挡的是将来有人绕过 `resolve` 直接构造。
        guard resolvedWrite.sampleRate <= sourceSampleRate else {
            throw MRError.coreAudio(
                operation: "初始化音轨 \(id)：不支持升采样（源 \(Int(sourceSampleRate)) Hz"
                    + " → 写入 \(Int(resolvedWrite.sampleRate)) Hz）。"
                    + "插值不会凭空造出信息，只会让文件变大。",
                status: -1)
        }

        self.id = id
        self.role = role
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.fileURL = fileURL
        self.sourceSampleRate = sourceSampleRate
        self.sourceChannels = sourceChannels
        self.writeFormat = resolvedWrite
        self.sampleFormat = format
        self.nonInterleaved = !sourceIsInterleaved
        self.downmixStrategy = downmixStrategy
        self.writer = try WAVWriter(
            url: fileURL, sampleRate: resolvedWrite.sampleRate,
            channels: resolvedWrite.channels, format: format)
        self.lock = OSAllocatedUnfairLock(initialState: MutableState(
            stats: TrackStats(sampleRate: sourceSampleRate, channels: sourceChannels),
            pipeline: TrackSamplePipeline(
                sourceSampleRate: sourceSampleRate,
                sourceChannels: sourceChannels,
                writeFormat: resolvedWrite,
                downmixStrategy: downmixStrategy)))
    }

    // MARK: - 生命周期

    /// 启动采集。
    ///
    /// **带硬超时**：`AudioDeviceCreateIOProcIDWithBlock` / `AudioDeviceStart` 都可能
    /// 永不返回（实测 coreaudiod 异常时如此）。卡住的话整个录制进程就静默挂死，
    /// 文件只剩一个 44 字节的空头——这比"这一轨启动失败"糟糕得多。
    /// 所以超时即抛错，由上层决定降级（例如只用另一条轨继续）。
    public func start(timeout: TimeInterval = 8.0) throws {
        let ioBlock: AudioDeviceIOBlock = { [weak self] inNow, inInputData, inInputTime, _, _ in
            self?.handle(inNow: inNow, input: inInputData, inputTime: inInputTime)
        }

        let created = ResultBox()
        let outcome = BlockingCall.run(timeout: timeout) { [self] in
            var newProcID: AudioDeviceIOProcID?
            let status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, deviceID, nil, ioBlock)
            guard status == noErr, let p = newProcID else {
                created.status = status
                return false
            }
            let startStatus = AudioDeviceStart(deviceID, p)
            guard startStatus == noErr else {
                AudioDeviceDestroyIOProcID(deviceID, p)
                created.status = startStatus
                return false
            }
            created.procID = p
            created.status = noErr
            return true
        }

        switch outcome {
        case .timedOut:
            throw MRError.coreAudio(
                operation: "启动音轨 \(id) 超时：Core Audio 未在 \(Int(timeout)) 秒内响应",
                status: -1)
        case .finished(false):
            throw MRError.permissionDenied(
                what: "启动音轨 \(id)",
                hint: "OSStatus \(fourCC(created.status))。"
                + "若为权限问题，确认程序从 .app 运行且已授权。")
        case .finished(true):
            self.procID = created.procID
            lock.withLock { $0.running = true }
        }
    }

    /// 停止采集并收尾文件（回填 WAV 头）。
    @discardableResult
    public func stop() throws -> TrackStats {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
        }
        // 排空重采样器的尾部，再回填头部。
        //
        // 顺序不能反：必须等 `AudioDeviceStop` 真的生效之后才能 flush，
        // 否则并发的采集回调会和这次 flush 抢同一把锁、同一个 writer，
        // 排空出来的尾巴可能被后到的数据挤到中间。
        //
        // **置停、排空、写尾段必须在同一个锁里做完。** 拆成「锁内 flush + 锁外 append」
        // 会留一个窗口：在途回调在我们释放锁之后、`finalize()` 之前挤进来写一笔，
        // 于是头部声明的长度小于文件实际长度（尾段是在头部回填之后追加的）。
        //
        // 不排空的话文件尾部会短掉约半个窗宽的源样本（48 kHz 下约 0.67 ms）。
        // 绝对值很小，但「文件时长比采集时长少一丁点」会让人在核对时间轴时多花一轮
        // 去排除它，而不排空换来的收益是零。
        let tailError: Error? = lock.withLock { state -> Error? in
            state.running = false
            let tail = state.pipeline.flush()
            guard !tail.isEmpty else { return nil }
            do {
                try writer.append(tail)
                return nil
            } catch {
                return error
            }
        }
        if let tailError {
            // 不吞：尾巴没写进去，文件时长会短一截，而这件事只发生在排空路径上。
            lock.withLock {
                $0.warnings.append(
                    "音轨 \(id) 尾段排空写入失败：\(tailError.localizedDescription)")
            }
        }

        do {
            try writer.finalize()
        } catch {
            // **不吞。** 头部回填失败意味着文件头声明 `dataSize = 0`：音频字节明明都在盘上，
            // 却会被 WAVReader / 播放器 / 波形 / 转写一律读成空轨，而 CLI 与 GUI 报的是
            // 「录制完成」。更糟的是恢复流程只扫 `state == .recording` 的会话，
            // 而这个会话收尾时已被标成 finalized ——**永远没有人会来修它**。
            // 所以先就地兜一次：`repairHeader` 按文件实际长度重写头部，
            // 那正是 `Recovery` 会做的事，只是提前到现场做掉。
            lock.withLock {
                $0.warnings.append(
                    "音轨 \(id) 回填文件头失败：\(error.localizedDescription)"
                    + "（已尝试按文件实际长度就地修复）")
            }
            do {
                _ = try WAVWriter.repairHeader(at: writer.url)
            } catch let repairError {
                lock.withLock {
                    $0.warnings.append(
                        "音轨 \(id) 就地修复文件头也失败了：\(repairError.localizedDescription)"
                        + "；该轨音频可能读不出来")
                }
            }
        }
        writer.close()
        return stats
    }

    /// 放弃收尾（保留「头为空、数据为全」的崩溃现场，供恢复流程处理）
    public func abort() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
        }
        lock.withLock { $0.running = false }
        // **刻意不排空管线**：这条路径要留下的是「崩溃当时盘上到底有什么」，
        // 多写一段尾部会让恢复出来的帧数与真实崩溃现场不一致。
        writer.abort()
    }

    // MARK: - 暂停 / 继续

    /// 暂停采集。
    ///
    /// **语义是「这一段不要」**：暂停期间既不写盘也不累计统计，音频文件里没有这一段，
    /// 播放与转写稿的时间轴都是「内容时间」。恢复时把空档记进 `pausedSeconds`，
    /// 从时钟时长里扣掉，所以不会污染时长和漂移。
    ///
    /// **刻意不写静音。** 写静音能让「帧数 == 时钟跨度 × 采样率」这条不变量继续成立，
    /// 代价是一次午休的暂停就能凭空产生上 GB 的静音数据（48kHz 立体声约 1.4 GB/小时），
    /// 还会把 4 GiB 上限提前撞掉。为一条不变量付这个代价不值。
    ///
    /// ⚠️ **全局暂停已不再走这条路**（见 `DualTrackRecorder.pause()`）：
    /// 它改用 `mute()`，否则同一场会议里"暂停过的那段"会让两轨文件长度分叉，
    /// 而双轨回放与按轨对齐的转写都建立在两轨等长之上。
    /// 保留这个方法是因为它仍被单测覆盖，且"丢弃数据"是需要保留的另一种语义。
    ///
    /// - Returns: 是否真的发生了状态变化（未在采集、或本来就在暂停都返回 false）
    @discardableResult
    public func pause() -> Bool {
        lock.withLock { state in
            guard state.running, !state.paused else { return false }
            state.paused = true
            return true
        }
    }

    /// 从暂停恢复。
    /// - Returns: 是否真的发生了状态变化
    @discardableResult
    public func resume() -> Bool {
        lock.withLock { state in
            guard state.running, state.paused else { return false }
            state.paused = false
            state.pendingPauseGap = true
            return true
        }
    }

    // MARK: - 静音 / 取消静音（分轨）

    /// 让这一轨进入静音。
    ///
    /// **语义是「这一段留白」**：采集照跑、管线照走、帧照写盘，只是写进去的全是零。
    /// 所以文件里这一段是静音，**长度不变**——这正是分轨能用、而不能直接
    /// 拿 `pause()` 顶替的原因：`pause()` 会丢弃数据，让这一轨比另一轨短一大截，
    /// 双轨并排回放与按轨对齐的转写都会因此错位。
    ///
    /// 与 `pause()` 可以并存（本项目不使用这种组合，但状态是独立的）：
    /// 两者都置位时先丢数据再谈静音，行为是确定的。
    ///
    /// - Returns: 是否真的发生了状态变化
    @discardableResult
    public func mute() -> Bool {
        lock.withLock { state in
            guard state.running, !state.muting else { return false }
            state.muting = true
            return true
        }
    }

    /// 取消静音。
    /// - Returns: 是否真的发生了状态变化
    @discardableResult
    public func unmute() -> Bool {
        lock.withLock { state in
            guard state.running, state.muting else { return false }
            state.muting = false
            return true
        }
    }

    /// **仅供测试**：把自己标成「正在采集」。
    ///
    /// `mute()` / `unmute()` 都要求 `state.running`，而 `running` 只在
    /// 真正 `start()`（碰 Core Audio、开设备）之后才为 true。无头环境给不了设备，
    /// 于是分轨静音的**语义**就没法在单测里验——只能验它不卡死。
    ///
    /// 不做成 `public`：生产代码没有正当理由伪造"正在采集"。
    func _testForceRunning() {
        lock.withLock { $0.running = true }
    }

    /// 切换静音。
    /// - Returns: 切换后的静音状态
    @discardableResult
    public func toggleMute() -> Bool {
        if isMuting { unmute() } else { mute() }
        return isMuting
    }

    // MARK: - 采集回调

    private func handle(
        inNow: UnsafePointer<AudioTimeStamp>,
        input: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))

        // 输入数据时间戳优先；缺省时退回设备当前时间。
        //
        // 必须是 `let`：这个值要进下面 `lock.withLock` 的闭包，而那个闭包是
        // `@Sendable` 的——捕获可变变量在 Swift 6 是错误。它本来就没被改过，
        // 只是原来写成 `var` 再赋值，白白让编译器无法证明这一点。
        let inputHostTime = inputTime.pointee.mHostTime
        let hostTime = inputHostTime == 0 ? inNow.pointee.mHostTime : inputHostTime

        // 一次加锁内完成「暂停判断 + 补记暂停空档 + 写盘 + 统计」，绝不在持锁时再调 withLock。
        lock.withLock { state in
            // `stop()` 会把 `running` 置 false，这里必须真的将它当回事。
            //
            // 不加这道 guard 的话那个赋值形同虚设：回调仍会照写，于是 `stop()` 里
            // 「排空 + 写尾段 + 回填头部」就可能与在途回调交错——文件会变成
            // **头部声明的长度小于文件实际长度**（尾段是在头部回填之后才被追加的）。
            // 播放器只看 dataSize，多出来的尾巴会被静默忽略，而 `framesWritten`
            // 与头部对不上，核对时间轴时又是一个要花时间排除的假象。
            guard state.running else { return }

            // 暂停期间：完全不碰 writer 和 stats，连交错化都跳过。
            // 只有一个例外必须先做——恢复后的第一个 buffer 要把暂停空档补记下来，
            // 否则那段没录的时间会被算进 `clockDuration`。
            if state.pendingPauseGap {
                state.pendingPauseGap = false
                if state.stats.lastHostTime > 0, hostTime > 0 {
                    let gap = HostClock.signedSeconds(from: state.stats.lastHostTime, to: hostTime)
                    if gap > 0 { state.stats.pausedSeconds += gap }
                }
            }

            guard !state.paused else {
                state.skippedBuffers += 1
                return
            }

            guard let source = AudioInterleaver.interleave(
                list, channels: sourceChannels, nonInterleaved: nonInterleaved),
                source.count >= sourceChannels else {
                if state.warnings.count < 5 {
                    state.warnings.append(
                        "收到无法解析的音频缓冲区（buffer 数 \(list.count)，期望通道数 \(sourceChannels)），该段已跳过")
                }
                return
            }

            // **源帧数**。统计与漂移一律以源为准：它们比较的是「采集到的帧数 vs 时钟」，
            // 而降采样后的帧数是另一个量，拿它去比时钟只会得到一个恒定的假漂移。
            let frames = source.count / sourceChannels

            // 静音：把源采样原地换成**等长的全零**，其余流程一个字都不改。
            //
            // 为什么必须等长、且必须真的过一遍管线：帧数要由 `source.count` 决定，
            // 而重采样器是靠输入长度决定输出长度的。若在这里直接跳过管线，
            // 开启单声道 24 kHz 时写出的帧数会与另一轨（正常录制的）差一倍，
            // 两轨时长就此错位——那正是分轨静音要避免的问题自己制造了出来。
            //
            // 复用缓冲区而不是每次 `repeating: 0`：这里是实时线程，
            // 每秒几十次的整块分配会放大抖动。
            var samples: [Float]
            if state.muting {
                let silence = state.silenceBuffer(sourceCount: source.count)
                samples = state.pipeline.process(silence)
                state.mutedBuffers += 1
                if sourceSampleRate > 0 {
                    state.mutedSeconds += Double(frames) / sourceSampleRate
                }
            } else {
                samples = state.pipeline.process(source)
            }

            do {
                try writer.append(samples)
            } catch {
                if state.warnings.count < 5 {
                    state.warnings.append("写入音频失败：\(error)")
                }
            }

            // 记录峰值。授权未生效时这里会一直是 0，而帧数完全正常——
            // 收尾时靠它把这种「静默成功」揪出来。
            //
            // 必须按**写入后实际生效**的采样算，两个理由：
            // ① 16 位会把 |v| < 0.5/32767 ≈ 1.53e-5 的采样量化成 0，而
            //    `RecordingSanity.isAllZero` 判的是 `frames > 0 && peakAmplitude == 0`；
            // ② 降混与重采样会改变采样值本身，峰值必须反映**盘上那份**内容。
            // 取的是管线产物（已是写入格式），量化则由 `effectiveSample` 补上。
            var peak = state.peakAmplitude
            for sample in samples {
                let value = Self.effectiveSample(sample, format: sampleFormat)
                let magnitude = Double(value < 0 ? -value : value)
                if magnitude > peak { peak = magnitude }
            }
            state.peakAmplitude = peak

            // 触顶必须显式告知：否则使用者只会看到"录音在继续但内容停了"。
            // 这里的时长上限按**写入格式**现算——文件是 24 kHz 单声道，
            // 用源格式（48 kHz 立体声）算出来的数字会比真实余量少一大截。
            if writer.didReachSizeLimit, !state.sizeLimitWarned {
                state.sizeLimitWarned = true
                state.warnings.append(Self.sizeLimitWarning(
                    id: id, sampleRate: writeFormat.sampleRate, channels: writeFormat.channels,
                    format: sampleFormat, maxDurationHours: writer.maxDurationHours))
            }

            // 相位抵消**不在这里报**：`TrackRecorder.warnings` 会与协调器收尾时的
            // `RecordingSanity` 告警并列展示，而后者已经能给出准确原因
            // （它知道这一轨被抵消过）。两处都报就是同一件事说两遍，
            // 而且实时这条内容更笼统，读起来像另一个独立问题。
            // 状态由 `phaseCancelled` 传给收尾流程，只报一次、报准的那次。

            if hostTime != 0 {
                state.stats.accumulate(frameCount: frames, startHostTime: hostTime)
            } else {
                state.missingTimestampBuffers += 1
                state.stats.accumulate(
                    frameCount: frames, startHostTime: state.stats.lastHostTime)
            }
            state.bufferCount += 1
        }
    }

    // MARK: - 可测的纯函数

    /// 单个 WAV 文件触顶时的告警文案。
    ///
    /// 抽成静态纯函数是为了**能测**：真正发出它必须走实时采集回调，单测里没有设备。
    /// 而这段文案恰好是用户在最需要判断「还要不要再分段」的时刻唯一能看到的东西——
    /// 原先把「立体声约 3.1 小时、单声道约 6.2 小时」写死，那是 32 位浮点的数；
    /// 开了 16 位实际是 6.2 / 12.4 小时，等于在那一刻告诉用户他只剩一半余量。
    /// `maxDurationHours` 由调用方按本轨的采样率/声道/位深现算后传入。
    static func sizeLimitWarning(
        id: String, sampleRate: Double, channels: Int,
        format: WAVSampleFormat, maxDurationHours: Double
    ) -> String {
        "音轨 \(id) 已达单个 WAV 文件 4 GiB 上限"
        + "（本轨 \(Int(sampleRate)) Hz、\(channels) 声道、\(format.displayName)，"
        + "约 \(String(format: "%.1f", maxDurationHours)) 小时），此后音频不再写入。"
        + "长时段录制请分段进行。"
    }

    /// 一个采样**写进文件后**实际生效的值。
    /// 自检的峰值必须按这个算，不能按量化前的 float——见 `RecordingSanity.isAllZero`。
    static func effectiveSample(_ v: Float, format: WAVSampleFormat) -> Float {
        format == .pcm16 ? WAVWriter.effectiveAfterQuantisation(v) : v
    }
}
