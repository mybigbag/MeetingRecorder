// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MRCore", targets: ["MRCore"]),

        // 唯一可执行产物。它是 **CLI 与 GUI 共用的同一个二进制**：
        // 带参数调用走命令行，不带参数（双击 .app）弹主窗口。
        //
        // 刻意不拆成两个可执行文件：TCC 的麦克风/系统音频授权是按
        // 「bundle 身份 + 路径」记账的，两个 .app 要么撞 bundle ID、
        // 要么让用户重新授权一遍，而且 `mr` 软链会指向另一半。
        .executable(name: "meeting-recorder", targets: ["MeetingRecorderMain"]),
    ],
    targets: [
        // 纯逻辑：零系统依赖，可在无权限环境下完整单元测试
        .target(name: "MRCore"),

        // 会议纪要层（加在转写之后的独立一层 LLM）。纯协议 + 分块 + 编排 + 降级，
        // 与具体模型实现解耦——FoundationModels 的真实调用在单独的编译单元里，
        // 本 target 不引入任何系统模型框架，保证无头完整可测。
        .target(name: "MRMinutes", dependencies: ["MRCore"]),

        // Core Audio 集成：麦克风 + 系统音频 Process Tap
        .target(name: "MRCapture", dependencies: ["MRCore"]),

        // 苹果原生本地转写
        .target(name: "MRTranscribe", dependencies: ["MRCore"]),

        // 跨入口共享的编排层：CLI 与 GUI 都调这里，避免两份实现各自漂移。
        // （转写编排曾经只存在于 CLI 内部，GUI 复用它的唯一办法就是抽出来。）
        .target(name: "MRSession", dependencies: ["MRCore", "MRCapture", "MRTranscribe", "MRMinutes"]),

        // 命令行前端：参数解析、终端输出排版
        .target(name: "MRCLI", dependencies: ["MRSession"]),

        // 图形前端：SwiftUI 视图 + AppKit 宿主
        .target(name: "MRGUI", dependencies: ["MRSession"]),

        // 入口分派（main.swift）：唯一持有 @main 的地方
        .executableTarget(
            name: "MeetingRecorderMain",
            dependencies: ["MRCLI", "MRGUI"]
        ),

        .testTarget(name: "MRCoreTests", dependencies: ["MRCore"]),
        // 转写引擎的选择与 SenseVoice 实现。`TranscriptionEngineResolver` 是「换引擎」唯一的
        // 开关位置，而 SenseVoice **必须证明它不会产出伪造文稿**（资产缺失时 `transcribe`
        // 明确抛错），以及证明解析/清洗/下载/子进程这几层在无资产、无网络、无权限的
        // 环境里都能被钉死——这四件事恰好都落在这个 target 里。
        .testTarget(name: "MRTranscribeTests", dependencies: ["MRTranscribe", "MRCore"]),
        .testTarget(name: "MRSessionTests", dependencies: ["MRSession"]),
        // 采集层可直接测的部分：`TrackRecorder` 的构造（写头、格式、帧数换算）
        // 完全不需要 Core Audio 权限——只有 `start()` 才要。而位深这种
        // 「用户能感知、出问题却没有任何界面异常」的参数，正是必须在这里钉住的。
        .testTarget(name: "MRCaptureTests", dependencies: ["MRCapture", "MRCore"]),
        // 图形层里值得单测的东西有两类：
        //   1. `TrackPlayer`——界面点不出来的地方（两轨同播、seek、切会议不残留）
        //   2. `StatusItemController` 的外观判断与它到真实 `NSStatusBarButton` 的接线
        //      （「隐藏录制迹象」这个开关失效时，屏幕上不会有任何异常，只有该消失的
        //      计时还留着——纯目测发现不了）
        // 后者要驱动状态机走到 `.recording`，所以显式依赖 MRSession（工作区）
        // 与 MRCapture（假引擎要满足 `RecordingEngine`）。
        // 另加 MRTranscribe：SenseVoice 资产状态/下载入口那组用例要直接构造
        // `SenseVoicePaths` 与假下载器，把资产目录隔离到临时目录——
        // SwiftPM 的 import 不传递，少一行就编不过。
        .testTarget(
            name: "MRGUITests",
            dependencies: ["MRGUI", "MRSession", "MRCore", "MRCapture", "MRTranscribe"]),

        // 纪要层纯逻辑：分块、map-reduce 编排、降级、云端 API 生成器（假 transport）、
        // 生成器解析（按偏好选本地/云端），全部用假实现与注入的偏好域测。
        // 显式依赖 MRCore：解析器读 `RecorderPreferences`，SwiftPM 的 import 不传递。
        .testTarget(name: "MRMinutesTests", dependencies: ["MRMinutes", "MRCore"]),

        // 命令行参数解析。`Args` 与「参数 → 配置」这条映射此前零覆盖——
        // `--f32` 写了却没被解析、运行时静默忽略，正是这个缺口放过去的。
        // 另加 MRTranscribe：`model` 子命令要能指向临时资产目录，
        // 那条**删除**分支的护栏（没有 `--yes` 绝不执行）才测得了。
        .testTarget(
            name: "MRCLITests",
            dependencies: ["MRCLI", "MRCapture", "MRCore", "MRTranscribe"]),
    ]
)
