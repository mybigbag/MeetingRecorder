import XCTest
@testable import MRSession
import MRCore

/// `SessionTranscriber.Configuration` 的引擎字段。
///
/// 单独的用例，因为「配置默认值」本身就是规格：编排层默认走苹果原生，
/// 引擎只由调用方（CLI 从全局偏好）显式注入。默认一旦被写成 SV，
/// 所有没显式传引擎的调用点都会静默换引擎，而稿子上只多一个名字。
final class SessionTranscriberConfigTests: XCTestCase {

    func testConfigurationDefaultsToAppleEngine() {
        let config = SessionTranscriber.Configuration()
        XCTAssertEqual(config.engine, .apple, "编排层的默认引擎必须是苹果原生")
        XCTAssertEqual(config.language, "zh-CN")
    }

    func testConfigurationCarriesExplicitEngine() {
        let config = SessionTranscriber.Configuration(language: "zh-CN", engine: .senseVoice)
        XCTAssertEqual(config.engine, .senseVoice)
    }
}
