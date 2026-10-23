import XCTest
@testable import MRCore

/// 「默认输入与默认输出是不是同一台物理设备」的判定。
///
/// 这个判定的作用是让 `doctor` 在耳机上不要给出一个会随机翻转的麦克风结论。
/// 两个方向判错的代价**不对称**：
/// - 误判成「同一台」→ 该做的提示音探测被跳过，麦克风轨退回「未验证」（保守，可接受）
/// - 误判成「不同设备」→ 又回到「同一环境两种结论随机出现」的老问题
///
/// 所以取值主要按本机真实 UID 的形状来锁，而不是凭想象编。
final class AudioDeviceIdentityTests: XCTestCase {

    /// 本机实测取到的真实 UID
    private let airPodsIn = "AC-90-85-B5-57-20:input"
    private let airPodsOut = "AC-90-85-B5-57-20:output"
    private let builtInMic = "BuiltInMicrophoneDevice"
    private let builtInSpk = "BuiltInSpeakerDevice"

    func testAirPodsInputAndOutputAreTheSameDevice() {
        XCTAssertTrue(AudioDeviceIdentity.sharesPhysicalDevice(airPodsIn, airPodsOut),
                      "AirPods 输入输出共用一台物理设备——正是回声消除抹掉提示音的情形")
        XCTAssertTrue(AudioDeviceIdentity.sharesPhysicalDevice(airPodsOut, airPodsIn),
                      "判定必须与顺序无关")
    }

    func testBuiltInMicAndSpeakerAreDifferentDevices() {
        XCTAssertFalse(AudioDeviceIdentity.sharesPhysicalDevice(builtInMic, builtInSpk),
                       "内置麦克风与扬声器是两台设备，提示音探测在它们之间是有效的")
    }

    func testSuffixStrippingOnlyAppliesToDirectionSuffix() {
        XCTAssertEqual(AudioDeviceIdentity.physicalBase(airPodsIn), "ac-90-85-b5-57-20")
        XCTAssertEqual(AudioDeviceIdentity.physicalBase(airPodsOut), "ac-90-85-b5-57-20")
        XCTAssertEqual(AudioDeviceIdentity.physicalBase(builtInMic), "builtinmicrophonedevice")
    }

    func testUidWithColonsIsNotTruncatedAtTheLastColon() {
        // USB 设备的 UID 本来就含冒号。若笼统截到最后一个冒号，会把不同设备误判成
        // 同一台，进而错误地放弃麦克风轨的探测。
        let a = "AppleUSBAudioEngine:Shure:MV7:123456"
        let b = "AppleUSBAudioEngine:Shure:MV7:654321"
        XCTAssertEqual(AudioDeviceIdentity.physicalBase(a), a.lowercased())
        XCTAssertFalse(AudioDeviceIdentity.sharesPhysicalDevice(a, b))
    }

    func testAggregateDeviceIsNotConfusedWithItsMember() {
        // 聚合设备（医生自检时会建一个）名字里带 PID，不该和普通设备撞上。
        XCTAssertFalse(AudioDeviceIdentity.sharesPhysicalDevice(
            "meeting-recorder-doctor-probe:input", builtInMic))
    }

    func testEmptyUidNeverMatches() {
        // 拿不到设备身份时不许凭猜下结论：退回保守口径，照常做提示音探测。
        XCTAssertFalse(AudioDeviceIdentity.sharesPhysicalDevice("", ""))
        XCTAssertFalse(AudioDeviceIdentity.sharesPhysicalDevice("", airPodsIn))
        XCTAssertFalse(AudioDeviceIdentity.sharesPhysicalDevice(":input", ":output"),
                       "只剩方向后缀时基名为空，不能算匹配")
    }

    func testSameUidMatches() {
        XCTAssertTrue(AudioDeviceIdentity.sharesPhysicalDevice(airPodsIn, airPodsIn))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(AudioDeviceIdentity.sharesPhysicalDevice("AC-90-85-B5-57-20:Input", airPodsOut))
    }
}
