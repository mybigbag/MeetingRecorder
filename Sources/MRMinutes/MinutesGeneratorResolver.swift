import Foundation
import MRCore

/// 按偏好解析出纪要生成器的结果。
///
/// **`blocked` 是一个独立结局，不是错误**：云端三件套没配齐时，调用方
/// （CLI / GUI）应该明确告诉用户缺什么、敲什么命令，而不是退化到本地模型
/// 写一份署名不同的纪要——用户选了云端，拿到本地产出的东西，是谎报。
public enum MinutesGeneratorResolution: Sendable {
    case ready(any MinutesGenerator)
    case blocked(reason: String)
}

/// 「用哪个纪要模型」的**唯一开关位置**——与 `TranscriptionEngineResolver`
/// 同一套纪律：CLI 与 GUI 两条前端都调这里，不各自判断。
public enum MinutesGeneratorResolver {

    public static func resolve(preferences: RecorderPreferences) -> MinutesGeneratorResolution {
        switch preferences.minutesProvider {
        case .local:
            // 本地模型：macOS 26 上真接 FoundationModels，否则兜底
            // （isAvailable 恒 false → orchestrator 抛 modelUnavailable → 降级）。
            if #available(macOS 26, *) {
                return .ready(FoundationModelsMinutesGenerator())
            }
            return .ready(UnavailableMinutesGenerator())

        case .cloudAPI:
            let missing = preferences.missingMinutesCloudAPIItems()
            guard missing.isEmpty else {
                return .blocked(reason: Self.blockedReason(missing: missing))
            }
            let configuration = CloudAPIConfiguration(
                baseURL: preferences.minutesAPIBaseURL ?? "",
                apiKey: preferences.minutesAPIKey ?? "",
                model: preferences.minutesModel ?? "")
            if let problem = configuration.urlProblem {
                return .blocked(reason: "\(problem)（当前 Base URL：\(configuration.baseURL)）")
            }
            return .ready(CloudAPIMinutesGenerator(configuration: configuration))
        }
    }

    /// 配置不全时的阻止原因。**带上要敲的命令**——只说「缺 Base URL」，
    /// 用户还得自己去翻文档找那条命令长什么样。
    static func blockedReason(missing: [String]) -> String {
        let names = missing.joined(separator: "、")
        let commands = MinutesCloudAPIField.allCases
            .filter { missing.contains($0.displayName) }
            .map { $0.setCommand }
            .joined(separator: "、")
        return "纪要模型设的是云端 API，但还没配齐：缺 \(names)。"
            + "补齐命令：\(commands)（值分别为服务商 Base URL、你的密钥、模型名）。"
            + "配齐之前不会写任何纪要文件。"
    }
}
