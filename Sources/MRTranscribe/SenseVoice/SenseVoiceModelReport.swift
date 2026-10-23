import Foundation
import MRCore

/// 把资产状态渲染成给人看的文本行。
///
/// 单独成一层而不是直接在 CLI 里拼字符串：这段输出是**用户唯一能看到的资产真相**
/// （装在哪、多大、缺哪一件、下一步敲什么），它必须能被单测断言到具体内容。
/// 藏在 `runModel()` 里的字符串只能靠人眼在终端里看，而人眼一定会漏。
public enum SenseVoiceModelReport {

    /// 状态表。返回的行由调用方逐行打印（不加换行）。
    public static func status(
        state: SenseVoiceInstallState,
        paths: SenseVoicePaths,
        configuredEngine: TranscriptionEngine,
        ignoredRuntimeOverride: String? = nil
    ) -> [String] {
        var lines: [String] = []
        lines.append("SenseVoice 资产（opt-in 引擎，默认不使用）")
        lines.append("")

        let nameWidth = SenseVoiceAssets.all
            .map { displayWidth($0.kind.displayName) }.max() ?? 0
        // marker 也要补位。三种 marker 的宽度不一样（「未下载」和「字节数不符」差 6 列），
        // 不补位的话名字列会跟着 marker 的长度左右跳，而「体积」列本来是要读直的。
        let markWidth = SenseVoiceAssets.all
            .map { displayWidth(marker(for: state.status(of: $0.kind))) }.max() ?? 0
        for asset in SenseVoiceAssets.all {
            let status = state.status(of: asset.kind)
            let mark = marker(for: status)
            lines.append("  \(pad(mark, to: markWidth))  \(pad(asset.kind.displayName, to: nameWidth))"
                + "  \(pad(asset.humanSize, to: 9))"
                + "  \(paths.url(for: asset).path)")
        }
        lines.append("")

        // 「能跑」与「是不是官方那一份」是**两个问题**。运行时的门槛只看前者
        // （工具链二进制允许重编译，见 `SenseVoiceModelStore.runtimeStatus`），
        // 所以后者要在这里单独说一句——否则一份自建 / 异版本构建会静静地通过，
        // 而用户以为自己在用官方 0.2.6。
        if state.status(of: .runtime).isReady,
           let runtime = state.runtimeBinaryURL,
           let actual = SenseVoiceModelStore.fileSize(at: runtime),
           actual != SenseVoiceAssets.runtime.byteCount {
            lines.append("  ⓘ 运行时不是官方那一份（\(actual) 字节；官方 "
                + "\(SenseVoiceAssets.runtime.byteCount)）。能用——"
                + "`meeting-recorder model verify` 会报它的 sha256 与官方不符。")
            lines.append("")
        }

        // 运行时实际会被用到的路径可能不是常规落点（env / 内嵌副本）。
        // 不报出来的话，「我刚装的那个文件到底有没有被用上」就只能靠猜。
        if let runtime = state.runtimeBinaryURL,
           runtime.path != paths.installedRuntimeURL.path {
            lines.append("  运行时实际使用：\(runtime.path)")
        }
        if let ignored = ignoredRuntimeOverride {
            lines.append("  ⚠️  环境变量 \(SenseVoicePaths.runtimeOverrideKey) 指向的 \(ignored)"
                + " 不存在或不可执行，已被忽略。")
        }

        lines.append("  落点根目录：\(paths.baseDirectory.path)")
        lines.append("  当前引擎：\(configuredEngine.rawValue)（\(configuredEngine.displayName)）"
            + (configuredEngine.isOptIn ? "　⚠️ opt-in" : ""))
        lines.append("")

        if state.isReady {
            lines.append("  ✅ 资产齐全，SenseVoice 可以转写。")
            lines.append("     启用：meeting-recorder config set engine sensevoice")
        } else {
            lines.append("  下一步：")
            // 权重与 VAD 由同一条命令一起装，所以要**去重**——逐项列会把同一行
            // 打印两遍，让人以为要执行两次。
            if !state.pendingDownloadable.isEmpty {
                let bytes = state.pendingDownloadByteCount
                lines.append("    meeting-recorder model download"
                    + "             下载模型权重（约 "
                    + "\(String(format: "%.0f", Double(bytes) / 1_048_576)) MiB）")
            }
            if state.runtimeMissing {
                let size = SenseVoiceAssets.runtime.humanSize
                lines.append("    meeting-recorder model install-runtime"
                    + "     安装推理运行时（\(size)，通常用仓库内副本，不需要联网）")
            }
            if configuredEngine == .senseVoice {
                lines.append("")
                lines.append("  ⚠️  当前已配置为 sensevoice，但资产未就绪——"
                    + "此时转写会在写任何文件之前明确报错，不会产出空稿。")
            }
        }
        return lines
    }

    /// 全量校验（sha256）的结果行。
    public static func verification(
        failures: [(asset: SenseVoiceAsset, actual: String)],
        state: SenseVoiceInstallState
    ) -> [String] {
        var lines: [String] = []
        lines.append("sha256 全量校验（读取全部字节，比状态检查慢）")
        lines.append("")
        for asset in SenseVoiceAssets.all {
            let failure = failures.first { $0.asset.kind == asset.kind }
            if let failure {
                lines.append("  ❌ \(asset.kind.displayName)：sha256 不符")
                lines.append("       期望 \(asset.sha256)")
                lines.append("       实际 \(failure.actual)")
                lines.append("       修复：\(repairHint(for: asset))")
            } else if state.status(of: asset.kind).isReady {
                lines.append("  ✅ \(asset.kind.displayName)：sha256 通过")
            } else {
                lines.append("  ⏭  \(asset.kind.displayName)：\(state.status(of: asset.kind).summary)，未校验")
            }
        }
        lines.append("")
        // 汇总行不能只看 `failures.isEmpty`。
        //
        // 什么都没装时 `verifyAll()` 也返回空数组（它对不存在的文件不报「不符」），
        // 于是旧写法会在一台**全新机器**上打出「✅ 全部通过。」——一句听起来像
        // 「资产完好」、实际什么也没校验的话。这正是本项目最忌讳的静默成功：
        // 用户会以为模型没问题，直到转写时才炸。区分「校验过且通过」与
        // 「压根没东西可校验」，两句话都得说清。
        if !failures.isEmpty {
            lines.append("  ❌ 有 \(failures.count) 项未通过。")
        } else if verifiedCount(state: state) > 0 {
            lines.append("  ✅ 全部通过（校验了 \(verifiedCount(state: state)) 项）。")
        } else {
            lines.append("  ⏭  没有可校验的资产：三项目前都不是「已就绪」。")
            lines.append("     先执行 `meeting-recorder model download` 把资产装上。")
        }
        return lines
    }

    /// 真正**会被校验**的项数：只有「已就绪」的资产才会走到 sha256 那一步。
    ///
    /// 未下载与字节数不符的项 `verify()` 直接返回 nil（不报错、也不算通过），
    /// 所以它们不能计入「校验通过」的分子——否则那两句话就混成了一句。
    public static func verifiedCount(state: SenseVoiceInstallState) -> Int {
        SenseVoiceAssets.all.filter { state.status(of: $0.kind).isReady }.count
    }

    /// 修复指引**按资产分派**。
    ///
    /// 早先三项一律写「`model remove --yes` 然后 `model download`」。而 `remove` 删的是
    /// **整个**资产目录——于是一个只是运行时摘要不符的机器，会让用户把那 242 MiB 的权重
    /// 一起删掉重下，而运行时的正确修法（重装它）在指引里根本没出现。
    /// 写错的指引比不写更贵：用户会照着做。
    static func repairHint(for asset: SenseVoiceAsset) -> String {
        switch asset.kind {
        case .runtime:
            return "重装运行时：`meeting-recorder model install-runtime`（权重与 VAD 不受影响）"
        case .model, .vad:
            // `model download` 会跳过已就绪的项，只重下坏了的那一份，
            // 所以**不需要**先 `remove`——那条命令会顺手删掉另外两项。
            return "重下这一项：`meeting-recorder model download`（已就绪的项会被跳过）"
        }
    }

    // MARK: - 排版

    private static func marker(for status: SenseVoiceAssetStatus) -> String {
        switch status {
        case .ready:         return "✅ 已就绪"
        case .missing:       return "⬇️  未下载"
        case .sizeMismatch:  return "⚠️  字节数不符"
        case .notExecutable: return "🚫 不可执行"
        }
    }

    /// 按**显示宽度**补空格。
    ///
    /// 中文一个字占两个终端列，用 `String.count` 对齐会让含中文的行全部错位。
    /// 这类对齐问题不大，但一旦错位，「体积」列就再也读不直——而那一列正是用户在扫的。
    static func pad(_ text: String, to width: Int) -> String {
        let current = displayWidth(text)
        guard current < width else { return text }
        return text + String(repeating: " ", count: width - current)
    }

    static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            total + width(of: scalar)
        }
    }

    /// 单个标量在终端里占几列。
    ///
    /// 变体选择符（U+FE0E / U+FE0F）**不占位**：`⬇️` 是 `U+2B07` + `U+FE0F`，
    /// 把它当成两个宽字符会得到 4 列，而终端里它只占 2 列——这一个字符的误差
    /// 就足以让整张表的名字列错开。
    static func width(of scalar: Unicode.Scalar) -> Int {
        if scalar.value == 0xFE0E || scalar.value == 0xFE0F { return 0 }
        return isWide(scalar) ? 2 : 1
    }

    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,
             0x26A0,              // ⚠ 警告（状态表用）
             0x2705,              // ✅ 通过（状态表用）
             0x2B07,              // ⬇ 下载（状态表用）
             0x2E80...0x303E,
             0x3041...0x33FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xA000...0xA4CF,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x1F300...0x1F64F,   // emoji
             0x1F6AB,             // 🚫 禁止（状态表用）
             0x1F900...0x1F9FF:
            return true
        default:
            return false
        }
    }
}
