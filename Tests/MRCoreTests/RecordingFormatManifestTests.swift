import XCTest
@testable import MRCore

/// manifest 里记不记「这条轨是什么采样格式」。
///
/// 为什么值得单独一个文件：manifest 的另外三个音频参数（`sampleRate`、`channels`、
/// `framesWritten`）早就在了，唯独**位深**没有。而位深恰恰是这一版新引入的、
/// 用户可切换的存储设置。
///
/// 少了它会出现一种很难查的错配：manifest 说「48000 Hz / 1 声道」，文件是 16 bit，
/// **盘上没有任何地方写着 16**——想按真实格式转码存量录音，只能把每个 wav 读一遍头。
/// 更糟的是「界面显示的音轨参数」与「文件真实格式」从此可以静默不一致。
final class RecordingFormatManifestTests: XCTestCase {

    // MARK: - 默认值

    /// 不传格式时必须是 `float32`（无损）。
    ///
    /// 与偏好层的「默认关」是同一条规格的两端：默认路径不能悄悄降质量。
    /// 而且这个默认值还有一个额外用途——它是**旧 manifest 的解码兜底值**，
    /// 见下面 `testDecodesLegacyManifestWithoutFormatKey`。
    func testDefaultFormatIsFloat32() {
        let track = TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                                  sampleRate: 48000, channels: 1)
        XCTAssertEqual(track.sampleFormat, .float32)
    }

    // MARK: - 往返

    /// 编码 → 解码之后仍然是原值。两个方向都测，别只测 pcm16 ——
    /// 一个「解码时把什么都解成 pcm16」的实现也能让单向断言通过。
    func testFormatSurvivesEncodeDecode() throws {
        for format in WAVSampleFormat.allCases {
            let original = RecordingManifest(
                sessionID: "s", title: "会议",
                tracks: [TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                                       sampleRate: 48000, channels: 1, sampleFormat: format)])

            let data = try JSONEncoder().encode(original)
            let back = try JSONDecoder().decode(RecordingManifest.self, from: data)

            XCTAssertEqual(back.tracks.first?.sampleFormat, format,
                           "\(format) 往返后应当保持不变")
        }
    }

    // MARK: - 旧数据兼容

    /// **上一版写出的 manifest（没有 `sampleFormat` 键）必须还能读出来。**
    ///
    /// 这是落盘类型的老规矩（同 `pauses`、`pausedSeconds`）：加字段不能让历史数据
    /// 变成「损坏」。一次升级把用户所有历史会议标红，是最不该发生的失败方式。
    ///
    /// 而这里的兜底值恰好**不是猜的**：这一版之前，所有录音都是 float32。
    /// 所以「缺键 → float32」对每一条历史 manifest 都是事实，不是近似。
    func testDecodesLegacyManifestWithoutFormatKey() throws {
        let legacy = """
        {"version":1,"sessionID":"s","title":"会议",
         "startedAt":"2026-09-27T16:24:31.000Z","state":"finalized","notes":[],
         "tracks":[{"id":"system","role":"systemAudio","fileName":"system.wav",
                    "sampleRate":48000,"channels":2,"framesWritten":96000,
                    "firstHostTime":100,"lastHostTime":200,"warnings":[]}]}
        """
        let manifest = try RecordingManifest.decode(Data(legacy.utf8), path: "内存")

        XCTAssertEqual(manifest.tracks.count, 1)
        XCTAssertEqual(manifest.tracks.first?.sampleFormat, .float32,
                       "上一版录的全是 float32，缺键就该解成 float32")
        // 顺手确认其它字段没被这次改动带坏
        XCTAssertEqual(manifest.tracks.first?.channels, 2)
        XCTAssertEqual(manifest.tracks.first?.sampleRate, 48000)
    }

    /// 键存在时以它为准，不能被兜底值盖掉。
    ///
    /// 这条是上面那条的对照：一个「永远返回 float32」的实现能过兼容测试，
    /// 却会让所有 pcm16 录音在 manifest 里被记成 float32。
    func testExistingKeyWinsOverTheFallback() throws {
        let json = """
        {"version":1,"sessionID":"s","title":"会议",
         "startedAt":"2026-09-27T16:24:31.000Z","state":"finalized","notes":[],
         "tracks":[{"id":"mic","role":"microphone","fileName":"mic.wav",
                    "sampleRate":48000,"channels":1,"sampleFormat":"pcm16",
                    "framesWritten":0,"firstHostTime":0,"lastHostTime":0,"warnings":[]}]}
        """
        let manifest = try RecordingManifest.decode(Data(json.utf8), path: "内存")
        XCTAssertEqual(manifest.tracks.first?.sampleFormat, .pcm16)
    }

    // MARK: - 可读性

    /// 这个字段必须真的落进 JSON 文本里。
    ///
    /// manifest 是**人类可读、可被别的工具直接消费**的格式（文件头注释里写着）。
    /// 字段只存在于结构体里、不写出去的话，上面所有往返测试照样全绿，
    /// 但「拿 jq 看一眼这条轨是 16 位还是 32 位」就做不到。
    func testFormatIsPresentInTheWrittenJSON() throws {
        let manifest = RecordingManifest(
            sessionID: "s", title: "会议",
            tracks: [TrackManifest(id: "mic", role: .microphone, fileName: "mic.wav",
                                   sampleRate: 48000, channels: 1, sampleFormat: .pcm16)])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-format-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try manifest.write(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(text.contains("\"sampleFormat\""), "字段名应当出现在 JSON 里")
        XCTAssertTrue(text.contains("pcm16"), "值应当是人类看得懂的字符串")
    }

    // MARK: - 未知/非法位深值不能让整场读不出来

    /// **当前版本不认识的位深值必须被容错，而不是让整场会议报「JSON 无效」。**
    ///
    /// `decodeIfPresent(WAVSampleFormat.self)` 只挡「键缺失」，挡不住「值不认识」：
    /// 枚举原始值映射失败会抛 `dataCorrupted`，于是**一条轨道的一个字段**
    /// 就让整场会议从列表里消失（QA 已隔离编译实测：`"sampleFormat":"pcm24"` →
    /// 整场报「manifest 解析失败 / JSON 无效或结构不对」）。
    /// 将来新增位深、外部工具写入、或新版录完降级回旧版运行都会踩到。
    ///
    /// 第三条断言（其它字段仍正确）是关键：只断言「没抛」挡不住「整条轨道被丢掉」
    /// 那种修法——把轨道整个跳过同样不影响「解码不抛」。
    ///
    /// 退化示例：把容错解码改回
    /// `try c.decodeIfPresent(WAVSampleFormat.self, forKey: .sampleFormat) ?? .float32`，
    /// `decode` 会抛错，本用例在第一步就变红。
    func testUnknownFormatValueDoesNotBreakTheWholeManifest() throws {
        let json = """
        {"version":1,"sessionID":"s","title":"未来格式",
         "startedAt":"2026-09-27T16:24:31.000Z","state":"finalized","notes":[],
         "tracks":[{"id":"mic","role":"microphone","fileName":"mic.wav",
                    "sampleRate":48000,"channels":1,"sampleFormat":"pcm24",
                    "framesWritten":48000,"firstHostTime":1,"lastHostTime":2,"warnings":[]}]}
        """
        // ① 解码不抛
        let manifest = try RecordingManifest.decode(Data(json.utf8), path: "内存")
        // ② 认不出的位深退回 float32（保守值），而不是让整场失败
        XCTAssertEqual(manifest.tracks.count, 1, "整条轨道不能被丢掉")
        XCTAssertEqual(manifest.tracks.first?.sampleFormat, .float32,
                       "认不出的位深应当退回 float32")
        // ③ 其它字段必须仍然正确——这一条才挡得住「把整条轨道丢掉」的假修
        XCTAssertEqual(manifest.title, "未来格式")
        XCTAssertEqual(manifest.tracks.first?.framesWritten, 48000)
        XCTAssertEqual(manifest.tracks.first?.sampleRate, 48000)
        XCTAssertEqual(manifest.tracks.first?.channels, 1)
    }

    /// 类型不对（写成数字而非字符串）也不许让整场失败。
    ///
    /// 与上面那条同一类：外部工具或手改可能写成 `"sampleFormat":16`。
    /// 这里同样要求「读得出来、退回 float32」，而非一个字段让整场报错。
    func testNonStringFormatValueDoesNotBreakTheWholeManifest() throws {
        let json = """
        {"version":1,"sessionID":"s","title":"数字格式",
         "startedAt":"2026-09-27T16:24:31.000Z","state":"finalized","notes":[],
         "tracks":[{"id":"mic","role":"microphone","fileName":"mic.wav",
                    "sampleRate":48000,"channels":1,"sampleFormat":16,
                    "framesWritten":100,"firstHostTime":0,"lastHostTime":0,"warnings":[]}]}
        """
        let manifest = try RecordingManifest.decode(Data(json.utf8), path: "内存")
        XCTAssertEqual(manifest.tracks.count, 1)
        XCTAssertEqual(manifest.tracks.first?.sampleFormat, .float32)
        XCTAssertEqual(manifest.tracks.first?.framesWritten, 100, "其它字段仍要正确")
    }
}
