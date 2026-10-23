import SwiftUI
import MRCore

/// 单条音轨的波形。
///
/// **纯灰阶**（未播放 `primary@0.18`、已播放 `primary@0.55`、播放头 `primary@0.8`）。
/// 不用点缀色：波形占的面积大，一上色就会顶破设计系统里「点缀面积 <5%」的约束；
/// 而且这里颜色要表达的是「播放到哪了」这种状态，本来就该用灰阶。
///
/// 横轴按容器宽度把 `peaks` 拉伸铺满，所以拖窗口不会触发任何重算
/// （条数固定，见 `MeetingWorkspace.waveformBuckets`）。
struct WaveformView: View {

    let peaks: [Float]
    /// 播放进度 0...1。nil 表示不画播放头。
    let progress: Double?
    var height: CGFloat = 44
    /// 点击或拖动跳转，参数是 0...1 的比例。传 nil 表示只读。
    var onSeek: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                render(into: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(seekGesture(width: geometry.size.width))
        }
        .frame(height: height)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        // `minimumDistance: 0` 让它同时接管单击与拖动。
        // 只在 `onEnded` 里跳转：拖动过程中每帧都 seek 会制造一串爆音。
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard let onSeek,
                      let fraction = Self.fraction(atX: value.location.x, width: width) else { return }
                onSeek(fraction)
            }
    }

    /// 把容器内的横向坐标换算成 0...1 的比例，超出边界就夹回去。
    ///
    /// 抽成静态方法是刻意的：「点哪儿跳哪儿」的全部依据就是这一行换算，
    /// 埋在手势闭包里就没法单独测，而它错一点点就是全程时间错位。
    static func fraction(atX x: CGFloat, width: CGFloat) -> Double? {
        guard width > 0, x.isFinite else { return nil }
        return min(max(0, Double(x / width)), 1)
    }

    private func render(into context: inout GraphicsContext, size: CGSize) {
        let count = peaks.count
        guard count > 0, size.width > 0, size.height > 0 else { return }

        let midY = size.height / 2

        // 中轴。全零音轨画出来就是这条平线，语义正确：这一段没有声音。
        context.fill(
            Path(CGRect(x: 0, y: midY - 0.25, width: size.width, height: 0.5)),
            with: .color(Color.primary.opacity(0.10)))

        let columnWidth = size.width / CGFloat(count)
        // 条留约 38% 间隙。窗口很宽时条会变粗，但不会糊成一片。
        let barWidth = max(0.5, columnWidth * 0.62)
        let playedColumns = progress.map { Int(($0 * Double(count)).rounded()) } ?? 0

        // 两条 Path 批量填充，而不是逐条 fill 三百次。
        var unplayed = Path()
        var played = Path()

        for index in 0..<count {
            let peak = CGFloat(peaks[index])
            guard peak > 0 else { continue }
            // 下限 0.75pt：极轻的声音也必须在图上看得见，
            // 否则「有声音」和「没声音」在视觉上就没区别了。
            let barHeight = max(0.75, peak * size.height)
            let rect = CGRect(
                x: CGFloat(index) * columnWidth + (columnWidth - barWidth) / 2,
                y: midY - barHeight / 2,
                width: barWidth,
                height: barHeight)
            if index < playedColumns {
                played.addRect(rect)
            } else {
                unplayed.addRect(rect)
            }
        }

        context.fill(unplayed, with: .color(Color.primary.opacity(0.18)))
        context.fill(played, with: .color(Color.primary.opacity(0.55)))

        if let progress, progress > 0, progress < 1 {
            let x = CGFloat(progress) * size.width
            context.fill(
                Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)),
                with: .color(Color.primary.opacity(0.75)))
        }
    }
}
