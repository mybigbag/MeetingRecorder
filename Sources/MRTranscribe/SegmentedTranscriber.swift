import Foundation
import MRCore

/// 长音频分段转写。
///
/// **默认关闭**，需要时用 `--segment` 显式打开。
///
/// 为什么默认关闭（实测，不是估计）：
///
/// | 音频 | 方式 | 耗时 | 本进程峰值内存 |
/// |---|---|---|---|
/// | 32.5 分钟 | 单段直转 | **11.7 秒** | 23 MB |
/// | 32.5 分钟 | 分段（7 段） | 56.7 秒 | 370 MB |
/// | 2 小时 3 分 | 单段直转 | **56.4 秒** | 24 MB |
///
/// 关键事实是**苹果引擎跑在独立 XPC 进程里**（`localspeechrecognition`，
/// 实测恒定约 180 MB），它对文件是流式处理的——音频从 32 分钟涨到 2 小时，
/// 本进程内存纹丝不动。所以"长音频必须分段才不会撑爆内存"这个前提不成立，
/// 分段反而要额外付出：扫一遍静音 + 全量重写切片 + 逐段重新打开文件。
///
/// 保留它的理由是**局部失败隔离**：单段直转一旦失败整条轨就没了，
/// 分段则只丢一段。以及将来若引擎出现时长上限时的退路。
///
/// 链路：**读时长 → 扫静音 → 算切点 → 逐段切片 → 逐段转写 → 时间戳叠加段偏移 → 合并**
public final class SegmentedTranscriber {

    public struct Configuration {
        /// 超过该时长才启用分段（秒）。默认 `.infinity` 即**不分段**。
        public var segmentThreshold: Double
        /// 单段最长时长（秒）
        public var maxSegment: Double
        /// 单段最短时长（秒）
        public var minSegment: Double
        /// 静音搜索窗口（秒，只往理想切点之前找）
        public var silenceSearchWindow: Double
        /// 静音判定阈值（dBFS）
        public var silenceThresholdDB: Double
        /// 最短静音时长（秒）
        public var minSilenceSeconds: Double
        /// 保留切片文件（排查用）；默认转写完即删
        public var keepSlices: Bool
        /// 切片与转写的临时目录，默认系统临时目录下的子目录
        public var temporaryDirectory: URL?

        public init(
            segmentThreshold: Double = .infinity,
            maxSegment: Double = 300,
            minSegment: Double = 10,
            silenceSearchWindow: Double = 45,
            silenceThresholdDB: Double = -45,
            minSilenceSeconds: Double = 0.35,
            keepSlices: Bool = false,
            temporaryDirectory: URL? = nil
        ) {
            self.segmentThreshold = segmentThreshold
            self.maxSegment = maxSegment
            self.minSegment = minSegment
            self.silenceSearchWindow = silenceSearchWindow
            self.silenceThresholdDB = silenceThresholdDB
            self.minSilenceSeconds = minSilenceSeconds
            self.keepSlices = keepSlices
            self.temporaryDirectory = temporaryDirectory
        }

        var segmenter: Segmenter {
            Segmenter(
                maxSegment: maxSegment,
                minSegment: minSegment,
                silenceSearchWindow: silenceSearchWindow)
        }

        var silenceSettings: SilenceDetector.Settings {
            SilenceDetector.Settings(
                thresholdDB: silenceThresholdDB,
                minSilenceSeconds: minSilenceSeconds)
        }
    }

    /// 单段转写时被调用的实际引擎
    public typealias Engine = (_ fileURL: URL, _ trackID: String, _ speaker: String) async throws -> [TranscriptSegment]

    public struct Outcome {
        /// 段内时间戳已叠加段偏移，即相对**该轨文件起点**的秒数
        public var segments: [TranscriptSegment]
        /// 切出的段数（未分段时为 1）
        public var segmentCount: Int
        /// 是否发生了分段
        public var didSegment: Bool
        /// 音频总时长
        public var duration: Double
        /// 检测到的静音区间数（未分段时为 0，因为没扫）
        public var silenceCount: Int
        /// 失败被跳过的段数
        public var failedSegments: Int
        /// 逐段诊断信息
        public var notes: [String]
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 分段转写一个音频文件。
    /// - Parameter engine: 真正执行转写的引擎（例如苹果原生引擎的单文件接口）
    public func transcribe(
        fileURL: URL,
        trackID: String,
        speaker: String,
        engine: Engine,
        progress: ((_ index: Int, _ total: Int, _ start: Double, _ end: Double) -> Void)? = nil
    ) async throws -> Outcome {

        let info = try AudioSlicer.inspect(fileURL)

        // 未启用分段（或音频未达阈值）：不扫静音、不切片，直接转。
        guard info.duration > configuration.segmentThreshold else {
            let segments = try await engine(fileURL, trackID, speaker)
            let note = configuration.segmentThreshold.isFinite
                ? String(format: "音频 %.1f 秒，未达分段阈值 %.0f 秒，单段转写",
                         info.duration, configuration.segmentThreshold)
                : String(format: "音频 %.1f 秒，分段已关闭，单段转写", info.duration)
            return Outcome(
                segments: segments, segmentCount: 1, didSegment: false,
                duration: info.duration, silenceCount: 0, failedSegments: 0,
                notes: [note])
        }

        // 长音频：扫静音 → 算切点
        let plan = SegmentPlan(
            segmenter: configuration.segmenter,
            silenceSettings: configuration.silenceSettings)
        let planned = try plan.plan(forFileAt: fileURL)

        guard planned.segments.count > 1 else {
            let segments = try await engine(fileURL, trackID, speaker)
            return Outcome(
                segments: segments, segmentCount: 1, didSegment: false,
                duration: info.duration, silenceCount: planned.silences.count,
                failedSegments: 0,
                notes: ["检测到 \(planned.silences.count) 处静音，但未产生多个切点，单段转写"])
        }

        let workDir = try makeWorkDirectory()
        defer { if !configuration.keepSlices { try? FileManager.default.removeItem(at: workDir) } }

        var all: [TranscriptSegment] = []
        var notes: [String] = []
        var failed = 0

        for (index, seg) in planned.segments.enumerated() {
            progress?(index + 1, planned.segments.count, seg.start, seg.end)

            let sliceURL = workDir.appendingPathComponent(
                String(format: "seg-%03d-%.3f-%.3f.wav", index, seg.start, seg.end))

            do {
                try AudioSlicer.slice(
                    source: fileURL, to: sliceURL, start: seg.start, end: seg.end)
            } catch {
                failed += 1
                notes.append(String(format: "第 %d 段（%.1f–%.1f 秒）切片失败，已跳过：%@",
                                    index + 1, seg.start, seg.end, "\(error)"))
                continue
            }

            do {
                let part = try await engine(sliceURL, trackID, speaker)
                // 引擎给的是**相对该段起点**的秒数，叠加段偏移即回到本轨时间轴
                let shifted = part.map { s -> TranscriptSegment in
                    var copy = s
                    copy.start = seg.start + max(0, s.start)
                    copy.end = seg.start + max(max(0, s.start), s.end)
                    return copy
                }
                all.append(contentsOf: shifted)
                if part.isEmpty {
                    notes.append(String(format: "第 %d 段（%.1f–%.1f 秒）无识别内容",
                                        index + 1, seg.start, seg.end))
                }
            } catch {
                failed += 1
                notes.append(String(format: "第 %d 段（%.1f–%.1f 秒）转写失败，已跳过：%@",
                                    index + 1, seg.start, seg.end, "\(error)"))
            }

            if !configuration.keepSlices { try? FileManager.default.removeItem(at: sliceURL) }
        }

        all.sort { $0.start < $1.start }

        notes.insert(String(
            format: "音频 %.1f 秒，切为 %d 段（检测到 %d 处静音）",
            info.duration, planned.segments.count, planned.silences.count), at: 0)

        return Outcome(
            segments: all,
            segmentCount: planned.segments.count,
            didSegment: true,
            duration: info.duration,
            silenceCount: planned.silences.count,
            failedSegments: failed,
            notes: notes)
    }

    private func makeWorkDirectory() throws -> URL {
        let base = configuration.temporaryDirectory
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("meeting-recorder-segments-\(UUID().uuidString)",
                                              isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw MRError.io(path: dir.path, reason: "无法创建切片临时目录：\(error)") }
        return dir
    }
}
