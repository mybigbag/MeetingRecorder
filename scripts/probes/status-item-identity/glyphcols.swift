import CoreGraphics
import Foundation
import ImageIO

// 把菜单栏截图里的「亮像素」按列找出簇 —— 每个簇就是屏幕上一个图标的横向占位。
//
// 为什么要这个：菜单栏图标是细线字形，整条菜单栏缩到能一眼看全的尺寸时，
// 那几根细线会糊掉，肉眼「看不见」不等于屏幕上没有。逐列扫亮度不会漏。
func load(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return img
}

guard CommandLine.arguments.count >= 2, let img = load(CommandLine.arguments[1]) else {
    print("用法: glyphcols <menu-bar.png> [逻辑宽] [亮度阈值]")
    exit(1)
}
let logicalWidth = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 1710) : 1710
let threshold = CommandLine.arguments.count > 3 ? (Int(CommandLine.arguments[3]) ?? 190) : 190
let scale = Double(img.width) / logicalWidth

let w = img.width, h = img.height
var buf = [UInt8](repeating: 0, count: w * h * 4)
buf.withUnsafeMutableBytes { raw in
    let ctx = CGContext(
        data: raw.baseAddress, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
}

// 逐列统计「亮像素」个数（白字形在蓝色菜单栏上是暗底亮字）
var brightPerColumn = [Int](repeating: 0, count: w)
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
        // 菜单栏图标是近白；用「最小通道」判断，蓝底（低 R）会被排除
        if min(r, g, b) > threshold { brightPerColumn[x] += 1 }
    }
}

var clusters: [(Int, Int)] = []
var start = -1, gap = 0
for x in 0..<w {
    if brightPerColumn[x] > 0 {
        if start < 0 { start = x } else if gap > 6 { clusters.append((start, x - gap - 1)); start = x }
        gap = 0
    } else if start >= 0 {
        gap += 1
    }
}
if start >= 0 { clusters.append((start, w - 1)) }

print("图片 \(w)x\(h)　逻辑缩放 \(scale)　亮度阈值 \(threshold)")
print("亮字形簇（逻辑 x 范围 / 宽度）：")
for c in clusters {
    let lo = Double(c.0) / scale, hi = Double(c.1) / scale
    let width = hi - lo + 1
    let mark = width >= 12 && width <= 40 ? "  ← 像一个状态栏图标" : ""
    print(String(format: "  x %6.0f … %6.0f　宽 %4.0f%@", lo, hi, width, mark))
}
