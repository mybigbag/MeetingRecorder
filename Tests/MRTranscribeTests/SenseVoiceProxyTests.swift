import XCTest
import CFNetwork
@testable import MRTranscribe

/// 代理环境变量 → `connectionProxyDictionary` 的翻译。
///
/// 单独一组用例的理由：这段代码写错时，表现是**下载超时**，而用户看到的会是
/// 「这个下载器坏了」——同一台机器上 `curl` 与浏览器都好好的。这是最难排查的一类问题，
/// 所以它必须被钉住，尤其是 scheme 的分派。
final class SenseVoiceProxyTests: XCTestCase {

    private func dictionary(_ environment: [String: String]) -> [AnyHashable: Any]? {
        SenseVoiceHTTPFetch.proxyDictionary(environment: environment)
    }

    /// 没设任何代理环境变量 → nil。
    ///
    /// **必须是 nil**：只有 nil 才会让 CFNetwork 去读系统级代理设置。
    /// 返回一个空字典或半截字典会把系统代理顶掉，而这一点用户完全看不出来。
    func testNoEnvironmentProxyYieldsNilSoSystemSettingsApply() {
        XCTAssertNil(dictionary([:]))
        XCTAssertNil(dictionary(["PATH": "/usr/bin"]))
        XCTAssertNil(dictionary(["HTTPS_PROXY": ""]))
    }

    /// `http://` / `https://` → HTTP/HTTPS 键。
    func testHTTPProxyIsTranslatedToHTTPKeys() throws {
        let dict = try XCTUnwrap(dictionary(["HTTPS_PROXY": "http://127.0.0.1:7897"]))
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPEnable as String] as? Int, 1)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPProxy as String] as? String, "127.0.0.1")
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPPort as String] as? Int, 7897)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPSProxy as String] as? String, "127.0.0.1")
        XCTAssertNil(dict[kCFNetworkProxiesSOCKSProxy as String], "HTTP 代理不该顺手写 SOCKS 键")
    }

    /// **`ALL_PROXY=socks5://…` 必须走 SOCKS 键。**
    ///
    /// `ALL_PROXY` 只设成 SOCKS 地址是 Clash / V2Ray / Surge 用户的常见配置。
    /// 早先的实现把 `ALL_PROXY` 与 `HTTPS_PROXY` 一视同仁地塞进
    /// `kCFNetworkProxiesHTTP(S)*`，**完全不看 scheme**。结果是：拿 SOCKS 端口当 HTTP
    /// 代理用，必然超时；而且因为字典非 nil，系统代理设置还会被一起顶掉。
    /// 别人能下的文件，这个程序一个都下不了。
    func testSocksProxyUsesSOCKSKeysAndNeverHTTPKeys() throws {
        let dict = try XCTUnwrap(dictionary(["ALL_PROXY": "socks5://127.0.0.1:1080"]))
        XCTAssertEqual(dict[kCFNetworkProxiesSOCKSEnable as String] as? Int, 1)
        XCTAssertEqual(dict[kCFNetworkProxiesSOCKSProxy as String] as? String, "127.0.0.1")
        XCTAssertEqual(dict[kCFNetworkProxiesSOCKSPort as String] as? Int, 1080)
        XCTAssertNil(dict[kCFNetworkProxiesHTTPProxy as String], "SOCKS 地址绝不能塞进 HTTP 槽位")
        XCTAssertNil(dict[kCFNetworkProxiesHTTPSProxy as String])
    }

    /// SOCKS 的各个别名都认；没写端口时用 SOCKS 的常规 1080（不是 HTTP 的 8080）。
    func testSocksAliasesAndDefaultPort() throws {
        for scheme in ["socks", "socks5", "socks5h", "socks4", "socks4a"] {
            let dict = try XCTUnwrap(dictionary(["ALL_PROXY": "\(scheme)://10.0.0.1:1081"]),
                                     "scheme \(scheme) 应被识别")
            XCTAssertEqual(dict[kCFNetworkProxiesSOCKSPort as String] as? Int, 1081, scheme)
        }

        let noPort = try XCTUnwrap(dictionary(["all_proxy": "socks5://10.0.0.1"]))
        XCTAssertEqual(noPort[kCFNetworkProxiesSOCKSPort as String] as? Int, 1080)
    }

    /// 认不出的 scheme → nil，**不猜**一个槽位塞进去。
    /// 猜错的代价不只是「这条不生效」，而是「把系统代理顶掉、还假装配置成功了」。
    func testUnknownSchemeIsIgnoredInsteadOfGuessed() {
        XCTAssertNil(dictionary(["ALL_PROXY": "ftp://127.0.0.1:21"]))
        XCTAssertNil(dictionary(["ALL_PROXY": "not-a-url"]))
        XCTAssertNil(dictionary(["ALL_PROXY": "http://"]), "没有 host 的地址不可用")
    }

    /// `HTTPS_PROXY` 优先于 `ALL_PROXY`（小写别名同样认）。
    func testHTTPSProxyWinsOverAllProxy() throws {
        let dict = try XCTUnwrap(dictionary([
            "HTTPS_PROXY": "http://127.0.0.1:7897",
            "ALL_PROXY": "socks5://127.0.0.1:1080",
        ]))
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPPort as String] as? Int, 7897)
        XCTAssertNil(dict[kCFNetworkProxiesSOCKSPort as String])
    }
}
