import XCTest
@testable import MRCore

/// 给不可取消的系统调用加硬超时。
///
/// 背景：实测 coreaudiod 异常时 `AudioDeviceCreateIOProcIDWithBlock` 永不返回，
/// 导致录制程序静默卡死（日志停在启动步骤、WAV 只剩 44 字节空头）。
/// 预热只是优化项，绝不能因为它挂掉整个会话——所以必须有这道闸。
final class BlockingCallTests: XCTestCase {

    func testReturnsResultWhenWorkFinishesInTime() {
        let outcome = BlockingCall.run(timeout: 2.0) { true }
        XCTAssertEqual(outcome, .finished(true))

        let failing = BlockingCall.run(timeout: 2.0) { false }
        XCTAssertEqual(failing, .finished(false))
    }

    func testTimesOutInsteadOfHangingForever() {
        let start = Date()
        // 模拟一个永不返回的 HAL 调用
        let outcome = BlockingCall.run(timeout: 0.3) {
            Thread.sleep(forTimeInterval: 30)
            return true
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(outcome, .timedOut, "超过时限必须返回 timedOut，而不是一直等下去")
        XCTAssertLessThan(elapsed, 3.0, "必须在时限附近就返回（实测 \(elapsed) 秒）")
    }

    func testZeroTimeoutStillReturnsRatherThanBlocking() {
        let start = Date()
        let outcome = BlockingCall.run(timeout: 0) {
            Thread.sleep(forTimeInterval: 2)
            return true
        }
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testWorkActuallyRunsOnAnotherThread() {
        // 若在主线程同步执行，超时机制就没有意义了
        let workThread = ThreadBox()
        _ = BlockingCall.run(timeout: 5.0) {
            workThread.isMain = Thread.isMainThread
            return true
        }
        XCTAssertFalse(workThread.isMain, "工作必须在后台线程执行，否则主流程根本没有机会超时")
    }

    private final class ThreadBox: @unchecked Sendable {
        var isMain = true
    }
}
