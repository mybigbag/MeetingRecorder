import Foundation

/// SenseVoice 推理所需的**一份外部资产**。
///
/// 为什么把它做成数据而不是散落的常量：体积与 sha256 是「半成品流入链路」的最后一道闸门。
/// 下载源、字节数、摘要、授权四件事必须写在**同一处**——分散开去的必然结果是
/// 「校验用了旧的 sha、错误提示里写了新的体积」这种没人会发现的不一致。
///
/// 授权与归因（Apache-2.0 / MIT 都要求保留）也在这里，是唯一的出处：
/// 权重来自 `FunAudioLLM/SenseVoiceSmall-GGUF` 与 `FunAudioLLM/fsmn-vad-GGUF`（Hugging Face），
/// 运行时来自 `modelscope/FunASR` 的 llama.cpp 预编译包。
public struct SenseVoiceAsset: Equatable, Sendable {

    /// 资产种类。rawValue 用于日志与错误信息，**不是**文件名。
    public enum Kind: String, Sendable, CaseIterable {
        case model
        case vad
        case runtime

        /// 给人看的名字。用在 `mr model` 的状态表与错误信息里。
        public var displayName: String {
            switch self {
            case .model:   return "SenseVoice 权重"
            case .vad:     return "FSMN-VAD 语音活动检测"
            case .runtime: return "推理运行时"
            }
        }
    }

    /// 获取方式。
    ///
    /// 权重是**可直接下载的文件**；运行时在 GitHub release 里是**一个 tar.gz 归档**，
    /// 我们只取其中那个成员——归档里另外还有 4 个别的模型工具和一个 README，
    /// 全解开再删是没必要的磁盘动作。
    public enum Source: Equatable, Sendable {
        /// 按顺序尝试这些 URL，第一个成功的即用
        case file(urls: [URL])
        /// 下载归档，只抽出 `member`（tar 成员路径）
        case tarGzMember(urls: [URL], member: String)

        /// 按优先级排列的下载地址。第一个是镜像。
        public var urls: [URL] {
            switch self {
            case .file(let urls):              return urls
            case .tarGzMember(let urls, _):    return urls
            }
        }

        /// 是否「先下归档再解包」。落临时文件时要不要加 `.tar.gz` 后缀取决于它。
        public var isArchive: Bool {
            if case .tarGzMember = self { return true }
            return false
        }
    }

    public let kind: Kind
    /// 落地后的文件名。**必须与资产在链路上被用到的名字一致**——
    /// 子进程参数里拼的就是它，改名会让运行时找不到模型。
    public let fileName: String
    /// 期望字节数。对**内容资产**（权重 / VAD）是**精确匹配**、不是「至少 N 字节」：
    /// 截断的文件同样是坏文件。
    ///
    /// 对**运行时**（工具链二进制）它只是「官方那一份多大」，用来回答
    /// 「你手上这份是不是官方的」——**不是**能否使用它的门槛。
    /// 门槛是「存在 + 可执行」，见 `SenseVoiceModelStore.runtimeStatus`。
    /// 两者混为一谈会让自建 / 异版本构建永远装不上（MIT 允许重编译，那就不是拒绝的理由）。
    public let byteCount: Int
    /// 期望 sha256（小写十六进制）。下载后与 `mr model verify` 用它做全量校验。
    public let sha256: String
    public let source: Source
    /// 许可证标识（`Apache-2.0` / `MIT`）。
    public let license: String
    /// 归因文字。Apache-2.0 与 MIT 都要求保留，随源码一起分发。
    public let attribution: String

    public init(
        kind: Kind,
        fileName: String,
        byteCount: Int,
        sha256: String,
        source: Source,
        license: String,
        attribution: String
    ) {
        self.kind = kind
        self.fileName = fileName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.source = source
        self.license = license
        self.attribution = attribution
    }

    /// 人类可读的体积（MiB，一位小数）。错误信息里一律用它，不让人去数九位数。
    public var humanSize: String {
        String(format: "%.1f MiB", Double(byteCount) / 1_048_576)
    }
}

/// 资产清单。**这里是体积、摘要、下载源、授权的唯一出处。**
///
/// 三项决策（模型来源与授权 / 运行时 / 下载体积）的依据见
/// `docs/接入-SenseVoice推理.md` 第一节。
public enum SenseVoiceAssets {

    /// SenseVoiceSmall 的 q8 量化权重（242.4 MiB）。
    ///
    /// 只接 q8 一档：f16 / f32 换档需要重新测中文用字差异并重定 sha256，
    /// 未做就不接（见接入文档第五节）。
    public static let model = SenseVoiceAsset(
        kind: .model,
        fileName: "sensevoice-small-q8.gguf",
        byteCount: 254_208_320,
        sha256: "4ae45c94422de949b387e2e0fb10d7e14e4c42c69db30c3444ecc7d4b844b7c5",
        source: .file(urls: [
            url("https://hf-mirror.com/FunAudioLLM/SenseVoiceSmall-GGUF/resolve/main/sensevoice-small-q8.gguf"),
            url("https://huggingface.co/FunAudioLLM/SenseVoiceSmall-GGUF/resolve/main/sensevoice-small-q8.gguf"),
        ]),
        license: "Apache-2.0",
        attribution: "SenseVoiceSmall 权重 © FunAudioLLM / 阿里通义实验室，Apache-2.0 许可。"
            + "上游：https://www.modelscope.cn/models/iic/SenseVoiceSmall　"
            + "GGUF 量化版：https://huggingface.co/FunAudioLLM/SenseVoiceSmall-GGUF")

    /// FSMN-VAD（1.6 MiB）。VAD 不是可选装饰——长音频靠它切成语音段，
    /// 没有它 SenseVoice 会把整段当一句（`--srt` 输出仍只有一条，时间戳没有意义）。
    public static let vad = SenseVoiceAsset(
        kind: .vad,
        fileName: "fsmn-vad.gguf",
        byteCount: 1_720_512,
        sha256: "1270f2559c495f4e7b6e739541151027d360761a3fda43fc147034f5719f5479",
        source: .file(urls: [
            url("https://hf-mirror.com/FunAudioLLM/fsmn-vad-GGUF/resolve/main/fsmn-vad.gguf"),
            url("https://huggingface.co/FunAudioLLM/fsmn-vad-GGUF/resolve/main/fsmn-vad.gguf"),
        ]),
        license: "Apache-2.0",
        attribution: "FSMN-VAD 权重 © FunAudioLLM，Apache-2.0 许可。"
            + "上游：https://www.modelscope.cn/models/iic/speech_fsmn_vad_zh-cn-16k-common-pytorch　"
            + "GGUF 版：https://huggingface.co/FunAudioLLM/fsmn-vad-GGUF")

    /// llama.cpp / GGUF 推理运行时（3,008,104 字节 = 2.9 MiB，Mach-O arm64）。
    ///
    /// FunASR 官方预编译包，**只链系统框架**（Accelerate / Metal / Foundation / libSystem），
    /// 不需要任何第三方 dylib，也不需要本机编译。
    ///
    /// 这里写作 `2.9 MiB` 是**1 MiB = 1,048,576 字节**的口径，与 `humanSize` 一致。
    /// 早先注释与帮助文本写的是 `3.0 MiB`（十进制 MB 的说法），于是同一份资产
    /// 在 `model status`、帮助文本、GUI 三处显示成三个数——体积是用户拿来判断
    /// 「值不值得下」的数，不能有多个出处。
    public static let runtime = SenseVoiceAsset(
        kind: .runtime,
        fileName: "llama-funasr-sensevoice",
        byteCount: 3_008_104,
        sha256: "becaa30d66bcaa727c132ef0e8c7248410bbf2cc4f0a2fe8f375cf885b9903c3",
        source: .tarGzMember(
            urls: [
                url("https://github.com/modelscope/FunASR/releases/download/runtime-llamacpp-v0.2.6/funasr-llamacpp-macos-arm64.tar.gz"),
            ],
            member: "llama-funasr-sensevoice"),
        license: "MIT",
        attribution: "FunASR llama.cpp/GGUF 运行时 © ModelScope / FunASR 贡献者，MIT 许可。"
            + "静态链接 llama.cpp（MIT）与 miniaudio（public domain）。"
            + "来源：https://github.com/modelscope/FunASR/releases/tag/runtime-llamacpp-v0.2.6")

    /// 全部资产，顺序固定（状态表、下载顺序都按它走）。
    public static let all: [SenseVoiceAsset] = [model, vad, runtime]

    /// 需要联网下载的资产（`mr model download` 的网络部分）。
    /// 运行时**不算**——它优先从 `.app` 内嵌或仓库 vendor 副本安装，通常不需要网络。
    public static var downloadable: [SenseVoiceAsset] { [model, vad] }

    /// 联网下载的总体积，用于「即将下载约 X MiB」这类提示。
    public static var downloadableByteCount: Int {
        downloadable.reduce(0) { $0 + $1.byteCount }
    }

    public static func asset(for kind: SenseVoiceAsset.Kind) -> SenseVoiceAsset {
        switch kind {
        case .model:   return model
        case .vad:     return vad
        case .runtime: return runtime
        }
    }

    private static func url(_ string: String) -> URL {
        // 这些是源码里的常量字面量。写成 `URL(string:)!` 会在拼错时崩在启动路径上，
        // 而这里宁可让它变成一个明显不可用的 URL —— 下载会失败并报出该 URL，
        // 比整个进程崩掉好排查。
        URL(string: string) ?? URL(fileURLWithPath: "/dev/null/\(string)")
    }
}
