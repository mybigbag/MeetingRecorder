import CoreGraphics
import Foundation

// 列出指定应用的在屏窗口。给界面冒烟用：证明「窗口真的被创建并显示」，
// 而不是只证明「进程还活着」。
let targetOwner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MeetingRecorder"

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("无法枚举窗口\n".utf8))
    exit(1)
}

var matched = 0
for window in windowList {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""

    // 传 `--all` 时列出全部在屏窗口的属主，用来确认应用到底以什么名字出现。
    // 实测 bundle 的 CFBundleDisplayName 是中文时，属主名也是中文，
    // 按可执行文件名去匹配会一个也找不到。
    if targetOwner == "--all" {
        let layer = window[kCGWindowLayer as String] as? Int ?? -1
        let title = window[kCGWindowName as String] as? String ?? ""
        var size = ""
        if let bounds = window[kCGWindowBounds as String] as? [String: Any],
           let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double {
            size = "\(Int(w))x\(Int(h))"
        }
        if layer == 0 { print("layer0\t\(owner)\t\(size)\t\(title)") }
        matched += 1
        continue
    }

    guard owner.contains(targetOwner) else { continue }
    matched += 1

    let number = window[kCGWindowNumber as String] as? Int ?? -1
    let title = window[kCGWindowName as String] as? String ?? "(读不到标题)"
    let layer = window[kCGWindowLayer as String] as? Int ?? -1

    var geometry = "未知"
    if let bounds = window[kCGWindowBounds as String] as? [String: Any],
       let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
       let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double {
        geometry = "\(Int(x)),\(Int(y)),\(Int(width)),\(Int(height))"
    }

    // 制表符分隔，方便 shell 侧 cut
    print("\(number)\t\(geometry)\t\(layer)\t\(title)")
}

if matched == 0 {
    FileHandle.standardError.write(Data("没有找到属主含「\(targetOwner)」的在屏窗口\n".utf8))
    exit(2)
}
