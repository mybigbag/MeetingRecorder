import XCTest
@testable import MRCore

/// 长会议分段。
///
/// 目标不是"切得均匀"，而是**不把词切开**：优先落在静音处，且每段不超过引擎能承受的长度。
final class SegmenterTests: XCTestCase {

    private let s = Segmenter()

    func testZeroDurationProducesNoSegments() {
        XCTAssertTrue(s.segment(duration: 0).isEmpty)
        XCTAssertTrue(s.segment(duration: -5).isEmpty)
    }

    func testShortAudioIsOneSegment() {
        let segs = s.segment(duration: 120)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].start, 0)
        XCTAssertEqual(segs[0].end, 120)
    }

    func testExactlyMaxDurationIsOneSegment() {
        let segs = s.segment(duration: 300)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].duration, 300)
    }

    func testLongAudioIsSplitWithoutGapsOrOverlap() {
        let segs = s.segment(duration: 1000)
        XCTAssertEqual(segs.count, 4)
        XCTAssertEqual(segs.map(\.start), [0, 300, 600, 900])
        XCTAssertEqual(segs.map(\.end), [300, 600, 900, 1000])

        // 严丝合缝：每段结束就是下一段开始，总长等于原始时长
        for i in 1..<segs.count {
            XCTAssertEqual(segs[i].start, segs[i - 1].end, accuracy: 1e-9)
        }
        XCTAssertEqual(segs.map(\.duration).reduce(0, +), 1000, accuracy: 1e-9)
    }

    func testEverySegmentRespectsMaxDuration() {
        let segs = s.segment(duration: 3725.4)
        for seg in segs {
            XCTAssertLessThanOrEqual(seg.duration, 300 + 1e-9, "单段不得超过上限")
        }
    }

    // MARK: - 静音落点

    func testCutsAtSilenceInsideWindow() {
        // 理想切点 300，只往之前搜索：静音中点 290 落在 [255, 300] → 切在 290
        let segs = s.segment(duration: 550, silences: [280...300])
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].end, 290, accuracy: 1e-9)
        XCTAssertEqual(segs[0].start, 0)
        XCTAssertEqual(segs[1].start, 290, accuracy: 1e-9)
        XCTAssertEqual(segs[1].end, 550, accuracy: 1e-9)
    }

    func testPicksNearestSilenceWhenSeveralInWindow() {
        let segs = s.segment(duration: 900, silences: [265...275, 280...290, 293...303])
        // 静音中点 270 / 285 / 298，理想切点 300 → 取最接近的 298
        XCTAssertEqual(segs[0].end, 298, accuracy: 1e-9)
    }

    func testNeverCutsPastIdealPoint() {
        // 关键约束：静音只能把切点**提前**，不能推后。
        // 若允许越过 ideal，段长会突破 maxSegment —— 那正是分段要避免的。
        let segs = s.segment(duration: 600, silences: [330...350])
        XCTAssertEqual(segs[0].end, 300, accuracy: 1e-9, "静音在理想点之后，应被忽略")
        XCTAssertLessThanOrEqual(segs[0].duration, s.maxSegment)
    }

    func testIgnoresSilenceOutsideWindow() {
        // 静音中点 400，距理想切点 300 有 100 秒，超出窗口（45 秒）→ 不采纳，硬切在 300
        let segs = s.segment(duration: 600, silences: [390...410])
        XCTAssertEqual(segs[0].end, 300, accuracy: 1e-9)
    }

    func testIgnoresSilenceTooCloseToSegmentStart() {
        // 静音中点 5 秒，切在这里会产出 5 秒的碎段 → 不采纳
        let segs = s.segment(duration: 600, silences: [0...10])
        XCTAssertEqual(segs[0].end, 300, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(segs[0].duration, s.minSegment)
    }

    func testSilencesGivenOutOfOrderStillWork() {
        let ordered = s.segment(duration: 900, silences: [270...280, 605...615])
        let shuffled = s.segment(duration: 900, silences: [605...615, 270...280])
        XCTAssertEqual(ordered, shuffled, "静音输入顺序不该影响结果")
    }

    // MARK: - 尾段合并

    func testShortTailIsMergedIntoPreviousSegment() {
        // 总长 301 → 切在 300 后剩 1 秒，短于 minSegment(10) → 并入前一段
        let segs = s.segment(duration: 301)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].duration, 301, accuracy: 1e-9)
    }

    func testTailJustAboveMinIsKeptSeparate() {
        let segs = s.segment(duration: 311)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[1].duration, 11, accuracy: 1e-9)
    }

    // MARK: - 自定义参数

    func testCustomMaxSegment() {
        let small = Segmenter(maxSegment: 10, minSegment: 1, silenceSearchWindow: 2)
        let segs = small.segment(duration: 35)
        XCTAssertEqual(segs.count, 4)
        for seg in segs { XCTAssertLessThanOrEqual(seg.duration, 10 + 1e-9) }
        XCTAssertEqual(segs.map(\.duration).reduce(0, +), 35, accuracy: 1e-9)
    }

    func testSegmentNeverOverlapsWithSilenceDrivenCuts() {
        let segs = s.segment(duration: 2000, silences: [285...295, 890...900, 1495...1505])
        for i in 1..<segs.count {
            XCTAssertLessThanOrEqual(segs[i - 1].end, segs[i].start + 1e-9)
        }
        XCTAssertEqual(segs.first!.start, 0)
        XCTAssertEqual(segs.last!.end, 2000, accuracy: 1e-9)
    }

    func testRealisticOneHourMeeting() {
        // 一小时会议，静音点分布不均 —— 模拟真实场景
        let silences: [ClosedRange<Double>] = stride(from: 100.0, to: 3500.0, by: 137.0)
            .map { $0...(($0 + 4)) }
        let segs = s.segment(duration: 3600, silences: silences)

        XCTAssertGreaterThan(segs.count, 1)
        for seg in segs {
            XCTAssertLessThanOrEqual(seg.duration, 300 + 1e-9)
            XCTAssertGreaterThan(seg.duration, 0)
        }
        XCTAssertEqual(segs.map(\.duration).reduce(0, +), 3600, accuracy: 1e-6)
        XCTAssertEqual(segs.first!.start, 0)
        XCTAssertEqual(segs.last!.end, 3600, accuracy: 1e-9)
    }
}
