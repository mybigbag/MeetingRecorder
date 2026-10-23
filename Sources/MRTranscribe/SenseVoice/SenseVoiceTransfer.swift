import Foundation
import CFNetwork
import MRCore

/// 用 `URLSession` 把一个远端地址抓成本地文件，并报告进度。
///
/// 为什么不用 `URLSession.bytes(for:)` + `for try await byte in stream`：那是**逐字节**迭代，
/// 244 MiB 就是 2.5 亿次循环。下载类任务的正确工具是 `downloadTask` + 代理回调，
/// 它在网络线程里成块写盘，进度也是现成的。
///
/// 为什么不用 `URLSession.download(from:)`：拿不到进度。244 MiB 的静默等待
/// 与「卡住」在用户侧无法区分。
public enum SenseVoiceHTTPFetch {

    public static func download(
        from remote: URL,
        to destination: URL,
        onProgress: ((Int64) -> Void)?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        var request = URLRequest(url: remote)
        // 单次请求的**不活动**超时（有数据在流就不会触发）。防的是「连上以后彻底没动静」，
        // 不是「文件大所以慢」——后者由下面的资源超时管，给到 2 小时。
        request.timeoutInterval = 60
        request.setValue("meeting-recorder/sensevoice", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 2 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 2

        // CFNetwork 只读**系统级**代理设置，**不读** `HTTPS_PROXY` 这类环境变量。
        // 而「终端里 export 一个本地代理」是极常见的用法，于是会出现一个很难懂的现象：
        // curl 能下、浏览器能下，只有这个程序超时。把环境变量显式翻译成代理字典，
        // 两个世界就一致了。没设环境变量时保持 nil —— 那才会让系统代理设置正常生效。
        if let proxy = proxyDictionary(environment: environment) {
            configuration.connectionProxyDictionary = proxy
        }

        let delegate = DownloadDelegate(
            remote: remote, destination: destination, onProgress: onProgress)
        let session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await delegate.run(session: session, request: request)
    }

    /// 把 `HTTPS_PROXY`（及常见别名）翻成 `connectionProxyDictionary`。
    ///
    /// **按 scheme 分派**，这一步不能省。`ALL_PROXY` 在 Clash / V2Ray / Surge 这类
    /// 常见配置里写的往往是 `socks5://127.0.0.1:1080`——把它当成 HTTP 代理塞进
    /// `kCFNetworkProxiesHTTP(S)*`，结果是：拿 SOCKS 端口当 HTTP 代理用，必然超时；
    /// 而且因为字典非 nil，**系统代理设置还会被一起顶掉**。这恰好就是本文件开头
    /// 那段注释想消除的「很难懂的现象」，却被这段代码自己造出来。
    ///
    /// 认不出的 scheme 一律返回 nil（保持字典为 nil，让系统代理正常生效）——
    /// 猜一个槽位塞进去，比不管它更糟。
    ///
    /// 只认大小写两种最常见的形式，**不做** `NO_PROXY` 匹配——半吊子的 `NO_PROXY`
    /// 实现比没有更容易让人误判「我明明排除了却还是走代理」。
    static func proxyDictionary(environment: [String: String]) -> [AnyHashable: Any]? {
        let raw = environment["HTTPS_PROXY"] ?? environment["https_proxy"]
            ?? environment["ALL_PROXY"] ?? environment["all_proxy"]
        guard let raw, !raw.isEmpty else { return nil }
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else { return nil }

        switch (url.scheme ?? "").lowercased() {
        case "socks", "socks5", "socks5h", "socks4", "socks4a":
            return [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: host,
                kCFNetworkProxiesSOCKSPort as String: url.port ?? 1080,
            ]
        case "http", "https":
            let port = url.port ?? 8080
            return [
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port,
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
            ]
        default:
            return nil
        }
    }

    /// `downloadTask` 的代理。持有一次下载的全部状态。
    ///
    /// `@unchecked Sendable` 的依据：`continuation` 只在 `run()` 里、`resume()` 之前赋值，
    /// 而代理回调只可能在 `resume()` 之后发生（`URLSessionTask` 在 resume 前不会开始），
    /// 因此不存在并发读写。`moveError` 同理：写它的是 `didFinishDownloadingTo`，
    /// 读它的是随后的 `didCompleteWithError`，两者在同一个串行代理队列上按序发生。
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

        private let remote: URL
        private let destination: URL
        private let onProgress: ((Int64) -> Void)?
        private var continuation: CheckedContinuation<Void, Error>?
        private var moveError: Error?

        init(remote: URL, destination: URL, onProgress: ((Int64) -> Void)?) {
            self.remote = remote
            self.destination = destination
            self.onProgress = onProgress
        }

        func run(session: URLSession, request: URLRequest) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = session.downloadTask(with: request)
                task.resume()
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            onProgress?(totalBytesWritten)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // `location` 是系统临时文件，**必须在本回调返回之前搬走**——返回后它就被删了。
            // 这是 downloadTask 最容易踩的一个坑：出错时表现为「偶尔下载到 0 字节文件」。
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                moveError = error
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            let continuation = self.continuation
            self.continuation = nil

            if let error {
                continuation?.resume(throwing: MRError.io(
                    path: destination.path,
                    reason: "下载 \(remote.absoluteString) 失败：\(error.localizedDescription)"))
                return
            }
            if let moveError {
                continuation?.resume(throwing: MRError.io(
                    path: destination.path,
                    reason: "临时文件落盘失败：\(moveError.localizedDescription)"))
                return
            }
            if let http = task.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                continuation?.resume(throwing: MRError.io(
                    path: destination.path,
                    reason: "\(remote.absoluteString) 返回 HTTP \(http.statusCode)"))
                return
            }
            continuation?.resume()
        }
    }
}

/// 从 tar.gz 里抽出单个成员。
///
/// 走系统 `/usr/bin/tar`（macOS 上就是 libarchive / bsdtar）而不是自己解压：
/// 归档里除了我们需要的那个二进制，还有 4 个别的模型工具和一个 README，
/// `tar` 支持只抽指定成员，省掉「全解开再删」的往返。用系统工具也意味着
/// 不需要为 3 MiB 的二进制再引一个解压依赖。
public enum SenseVoiceTarGz {

    public static func extractMember(
        from archive: URL,
        member: String,
        into directory: URL
    ) throws -> URL {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw MRError.io(path: directory.path,
                             reason: "无法创建解包目录：\(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path, member]
        let errorPipe = Pipe()
        // stdout 直接丢进 null device，**不用** `Pipe`。
        //
        // 这与 `SenseVoiceProcessRunner` 里那段论证是同一条：管道内核缓冲约 64 KiB，
        // 写满就互等。当前 `-xzf`（没有 `-v`）不往 stdout 写东西，所以这只是**潜在**
        // 风险；但同一份代码里一处专门论证「管道不能用来接子进程输出」、另一处却留着
        // 一个没人读的 Pipe，未来给 tar 加个 `-v` 就会变成真死锁——那时没人会想到是这里。
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw MRError.io(path: archive.path,
                             reason: "无法启动 tar：\(error.localizedDescription)")
        }

        // 先读完 stderr 再 waitUntilExit：反过来会有管道填满导致子进程卡死的风险。
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MRError.io(
                path: archive.path,
                reason: "解包 \(member) 失败（tar 退出码 \(process.terminationStatus)）"
                    + (message.isEmpty ? "" : "：\(message)"))
        }

        // 归档里的成员写作 `./llama-funasr-sensevoice`，抽出来落在目录根下。
        let extracted = directory.appendingPathComponent(
            (member as NSString).lastPathComponent)
        guard FileManager.default.fileExists(atPath: extracted.path) else {
            throw MRError.io(path: directory.path,
                             reason: "解包后没有找到成员 \(member)")
        }
        return extracted
    }
}
