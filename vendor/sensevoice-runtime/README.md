# vendor/sensevoice-runtime

`llama-funasr-sensevoice` —— SenseVoice 推理运行时的**离线副本**。

| 项 | 值 |
|---|---|
| 文件 | `llama-funasr-sensevoice`（Mach-O 64-bit arm64） |
| 字节数 | 3,008,104 |
| sha256 | `becaa30d66bcaa727c132ef0e8c7248410bbf2cc4f0a2fe8f375cf885b9903c3` |
| 来源 | `https://github.com/modelscope/FunASR/releases/tag/runtime-llamacpp-v0.2.6` |
| 归档 | `funasr-llamacpp-macos-arm64.tar.gz` 中的同名成员 |
| 许可 | **MIT**（FunASR 工具链）。静态链接 llama.cpp（MIT）与 miniaudio（public domain） |
| 动态依赖 | 仅系统框架：Accelerate / Metal / MetalKit / Foundation / CoreFoundation / libSystem / libc++ / libobjc |

## 为什么把二进制放进仓库

不是「顺手存的」，是一个明确的取舍：

1. **GitHub release 在国内经常不通**（实测直连会被掐，curl exit 56）。
   把一个 3 MiB 的东西做成网络依赖，会让这个 opt-in 引擎在最需要它的时候装不上。
2. **这是纯本地的功能**。`mr model install-runtime` 优先用这份副本，
   所以「装 SenseVoice」在网络不通时也能完成——只有 244 MiB 的权重必须联网。
3. 它只有 3 MiB，且仓库本来就带一个打包好的 `.app`。

体积与许可都在 `Sources/MRTranscribe/SenseVoice/SenseVoiceAsset.swift` 里同时声明，
两处不一致时以源码为准（源码是校验执行的地方）。

## 刷新

```bash
./scripts/fetch-sensevoice-runtime.sh            # 走代理，重新下载并校验
./scripts/fetch-sensevoice-runtime.sh --no-proxy # 不挂代理
```

换版本时**必须同时**更新 `SenseVoiceAsset.runtime` 的 `byteCount` / `sha256` / release 版本号，
否则 `mr model install-runtime` 会报摘要不符。

## 注意

这份二进制**不参与** `swift build`。它是运行期资源：
- 开发态（`swift run`）由 `SenseVoicePaths.vendoredRuntimeURL` 从可执行文件向上找 `vendor/` 拿到；
- 打包态由 `scripts/build-app.sh` 复制进 `MeetingRecorder.app/Contents/Resources/sensevoice/`。
