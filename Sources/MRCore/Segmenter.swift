import Foundation

/// 长会议分段。
///
/// 为什么要分段：16GB 内存上，一次性把一小时音频喂给转写引擎是危险的——
/// 有的是内存峰值，有的是引擎内部的时长上限。按段流式处理更稳。
///
/// 切分策略：优先在**静音处**切（不会把词切开），静音点不可用时才硬切。
public struct Segmenter {

    public struct Segment: Equatable {
        public var start: Double
        public var end: Double
        public var duration: Double { end - start }

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    /// 单段最长时长（秒）
    public var maxSegment: Double
    /// 单段最短时长（秒），短于此的尾段并入前一段
    public var minSegment: Double
    /// 静音搜索窗口：**只往理想切点之前**找多远
    public var silenceSearchWindow: Double

    public init(
        maxSegment: Double = 300,
        minSegment: Double = 10,
        silenceSearchWindow: Double = 45
    ) {
        self.maxSegment = maxSegment
        self.minSegment = minSegment
        self.silenceSearchWindow = silenceSearchWindow
    }

    /// - Parameters:
    ///   - duration: 音频总时长（秒）
    ///   - silences: 静音区间（秒，相对该音轨起点），按 start 升序
    public func segment(duration: Double, silences: [ClosedRange<Double>] = []) -> [Segment] {
        guard duration > 0 else { return [] }
        guard duration > maxSegment else {
            return [Segment(start: 0, end: duration)]
        }

        let sorted = silences.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Segment] = []
        var cursor = 0.0

        while duration - cursor > maxSegment {
            let ideal = cursor + maxSegment
            let lo = ideal - silenceSearchWindow

            // 刻意**只往理想切点之前**找静音。
            // 若允许切点越过 ideal，静音会把段推长到 ideal + window，
            // 直接突破 maxSegment 这个上限——而超长段落正是分段要避免的事。
            // 代价是切出的段普遍略短于上限，这个交换是划算的。
            let candidate = sorted
                .map { ($0.lowerBound + $0.upperBound) / 2 }
                .filter { $0 > lo && $0 <= ideal && $0 - cursor >= minSegment }
                .min { abs($0 - ideal) < abs($1 - ideal) }

            let cut = candidate ?? ideal
            result.append(Segment(start: cursor, end: cut))
            cursor = cut
        }

        // 收尾
        if duration - cursor > 0 {
            if duration - cursor < minSegment, !result.isEmpty {
                result[result.count - 1].end = duration   // 尾段太短，并入前一段
            } else {
                result.append(Segment(start: cursor, end: duration))
            }
        }
        return result
    }
}
