import CoreGraphics
import Foundation
import ImageIO

// 比较两张「同一块屏幕区域」的截图，按 **x 轴聚簇** 报告不同的地方。
//
// 为什么不只报一个 bbox：菜单栏里有网络速率文字这种自己会变的元素，
// 一个 bbox 会被它撑满全宽，看不出「某处多了一个图标」这种局部变化。
// 按列聚簇能把互不相干的变化分开，一眼看得出哪一段真的多了东西。
func load(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return img
}

func pixels(_ img: CGImage) -> [UInt8] {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return buf
}

let args = CommandLine.arguments
guard args.count >= 3, let a = load(args[1]), let b = load(args[2]) else {
    FileHandle.standardError.write(Data("用法: colordiff <a.png> <b.png> [逻辑宽] [阈值]\n".utf8))
    exit(1)
}
guard a.width == b.width, a.height == b.height else {
    print("尺寸不同：\(a.width)x\(a.height) vs \(b.width)x\(b.height)")
    exit(1)
}
let logicalWidth = args.count > 3 ? (Double(args[3]) ?? 1710) : 1710
let threshold = args.count > 4 ? (Int(args[4]) ?? 24) : 24
let scale = Double(a.width) / logicalWidth

let pa = pixels(a), pb = pixels(b)
var changedPerColumn = [Int](repeating: 0, count: a.width)
for y in 0..<a.height {
    for x in 0..<a.width {
        let i = (y * a.width + x) * 4
        let d = abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1]))
              + abs(Int(pa[i + 2]) - Int(pb[i + 2]))
        if d > threshold { changedPerColumn[x] += 1 }
    }
}

// 把有变化的列聚成簇，容忍 <=2 像素的空隙
var clusters: [(Int, Int, Int)] = []   // (起始列, 结束列, 变化像素总数)
var start = -1, count = 0, gap = 0
for x in 0..<a.width {
    if changedPerColumn[x] > 0 {
        if start < 0 { start = x; count = 0 }
        else if gap > 2 { clusters.append((start, x - gap - 1, count)); start = x; count = 0 }
        count += changedPerColumn[x]
        gap = 0
    } else if start >= 0 {
        gap += 1
    }
}
if start >= 0 { clusters.append((start, a.width - 1, count)) }

let total = changedPerColumn.reduce(0, +)
if total == 0 {
    print("两图完全相同（阈值 \(threshold)）")
    exit(0)
}
print(String(format: "图片 %dx%d　逻辑缩放 %.2f　不同像素总数 %d", a.width, a.height, scale, total))
print("变化簇：")
for c in clusters {
    let lo = Double(c.0) / scale, hi = Double(c.1) / scale
    print(String(format: "  逻辑 x %.0f…%.0f（宽 %.0f）变化 %d 像素",
                 lo, hi, hi - lo + 1, c.2))
}
