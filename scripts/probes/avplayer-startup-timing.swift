import AVFoundation
import Foundation

// 复现「play() 后立刻查 isPlaying」的真实时序。
// 目的：确认 tick() 的 100ms 窗口到底够不够 AVAudioPlayer 真正起播。
//
// 用法：swift scripts/probes/avplayer-startup-timing.swift <某个 mic.wav 或 system.wav>
// 不传路径时退出并给出用法——这里**不写死任何本机路径**：
// 探针要能交给别人跑，路径得由调用方给。
let args = CommandLine.arguments
guard args.count > 1 else {
    print("用法：swift avplayer-startup-timing.swift <音频文件.wav>")
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
guard let player = try? AVAudioPlayer(contentsOf: url) else {
    print("打不开音频"); exit(1)
}
player.prepareToPlay()
print("duration = \(player.duration)")

player.play()
print("play() 返回后立刻查: isPlaying=\(player.isPlaying)")
var waited = 0.0
for step in 1...10 {
    Thread.sleep(forTimeInterval: 0.05)
    waited += 0.05
    let ms = Int(waited * 1000)
    print("  t=\(ms)ms  isPlaying=\(player.isPlaying)  currentTime=\(String(format: "%.3f", player.currentTime))")
    if player.currentTime > 0 { print("  → 播放头开始推进于 ~\(ms)ms"); break }
}
