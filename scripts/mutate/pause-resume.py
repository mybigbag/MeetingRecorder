#!/usr/bin/env python3
"""播放暂停/续播功能的变异验证。

**为什么必须做这一步**：这批用例守的是一个「编译能过、界面能画、只有真听才发现」
的 bug。改回去只要动一行——把 `pause()` 写成 `stop()`，或者把 `position = 0` 加回去。
没有变异验证，就只能靠「我记得我测过了」这种不可靠的记忆。

**沿用上一轮定下的三条铁律**（都踩过坑）：
1. 变异必须**编译通过**——编译不过的变异不算命中，它只证明编译器能抓到。
2. 过滤条件必须真的跑到了目标测试——**跑 0 个测试 = 判据无效**，直接判失败。
3. 备份还原顺序：还原 → 校验还原成功 → 必要时再恢复一次。

用法：python3 Scripts/mutate/pause-resume.py
"""

import atexit
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

# 项目根 = 本文件上溯两级（scripts/mutate/ → scripts/ → 仓库根）。
PROJ = Path(__file__).resolve().parents[2]
TRACK = PROJ / "Sources/MRGUI/TrackPlayer.swift"
VIEW = PROJ / "Sources/MRGUI/MeetingDetailView.swift"
T_SH = PROJ / "scripts/t.sh"

# 每次只跑这几条，快。变异要的是「跑到了并且红了」，不是全量。
TARGET_TESTS = "TrackPlayerPauseTests|TransportControlLabelTests"


@dataclass
class Mutation:
    ident: str          # 编号，如 M-P01
    desc: str           # 人话描述这条变异模拟什么回归
    path: Path
    old: str            # 原文片段（必须唯一命中）
    new: str
    must_fail: bool = True


def M(ident, desc, path, old, new, must_fail=True):
    return Mutation(ident, desc, path, old, new, must_fail)


MUTATIONS = [
    # ---- 根因 1：用stop() 冒充暂停 ----------------------------------------
    # 这条**漏过两次网**，值得把过程写下来：
    #  1. 第一版判据是「读 currentTime > 3.5」——无头环境音频栈起不来，
    #     currentTime 恒为 0，抓不到任何东西。
    #  2. 第二版改成「pause() 里额外写 position = 0」，以为能抓——
    #     结果手动跑确实绿了（因为随后那行读 currentTime 又把它覆盖回去，
    #     而无头环境读到 0，等于没写）。后来干脆把实现里那行读回currentTime
    #     删了（本来就不该有，见pause() 的注释），判据才落在真实语义上。
    # 现在抓的是 `canResume()`：用 stop() 冒充 pause() 会清空 paused，
    # 这条判据不依赖音频栈、也不依赖播放头。
    M("M-P01", "pause() 里用 stop() 代替 pause()（原始 bug 的直接形态）",
      TRACK, "            players[track]?.pause()\n        }\n        playing = []\n        paused = pausedNow",
          "            players[track]?.stop()\n        }\n        playing = []\n        paused = []"),

    # ---- 根因 2：toggleTrack 里把播放头抹零 -----------------------------
    M("M-P02", "把 toggleTrack 里删掉的 position = 0 加回来（原始 bug 的另一条根因）",
      TRACK, "            seekPlayer(track, to: position)\n            player.play()\n            playing.insert(track)\n            paused.remove(track)",
          "            if !isPlaying { position = 0 }\n            seekPlayer(track, to: position)\n            player.play()\n            playing.insert(track)\n            paused.remove(track)"),

    # ---- 暂停态建模 ------------------------------------------------------
    M("M-P03", "pause() 不记录 paused 集合（暂停后无法继续）",
      TRACK, "        playing = []\n        paused = pausedNow\n        stopTimer()",
          "        playing = []\n        stopTimer()"),

    # 这条原本锚在「读 currentTime 回写 position」那几行上，后来那几行被删掉了
    # （本来就不该有——见 TrackPlayer.pause() 的注释），锚点失效、变异跑不起来。
    # 改成真正的回归形态：暂停时把播放头抹零。
    M("M-P04", "pause() 把播放头强制归零",
      TRACK, "        for track in pausedNow {\n            players[track]?.pause()\n        }\n        playing = []",
          "        for track in pausedNow {\n            players[track]?.pause()\n        }\n        position = 0\n        playing = []"),

    M("M-P05", "isPaused 恒为 false（界面永远不显示「继续」）",
      TRACK, "    var isPaused: Bool { !paused.isEmpty }",
          "    var isPaused: Bool { false }"),

    M("M-P06", "isPlaying 把暂停也算成在播（按钮该显示暂停却显示继续）",
      TRACK, "    var isPlaying: Bool { !playing.isEmpty }",
          "    var isPlaying: Bool { !playing.isEmpty || !paused.isEmpty }"),

    # ---- 继续 ------------------------------------------------------------
    # 这条以前**永远抓不到**：它改的是 `AVAudioPlayer.currentTime`，
    # 而无头环境那个值恒为 0，改成 0 和不改读出来一模一样。
    # 现在实现把播放头设置收敛到 `seekPlayer()` 这一个出口，
    # 并且那里会记 `requestedStartTimes`——判据终于有着落了。
    M("M-P07", "resume() 从 0 开始而不是从暂停处",
      TRACK, "            seekPlayer(track, to: position)\n            players[track]?.play()",
          "            seekPlayer(track, to: 0)\n            players[track]?.play()"),

    M("M-P08", "resume() 覆盖 playing 而非并集（把还在播的轨抹掉，导致两轨错位）",
      TRACK, "        playing.formUnion(toResume)",
          "        playing = toResume"),

    M("M-P09", "resume() 恢复全部轨而不只是 paused 里的",
      TRACK, "        let toResume = paused.filter { players[$0] != nil }",
          "        let toResume = Set(Track.allCases).filter { players[$0] != nil }"),

    # ---- 停止 ------------------------------------------------------------
    M("M-P10", "stop() 不归零（停止失去了「回到开头」的意义）",
      TRACK, "        playing = []\n        paused = []\n        stopTimer()\n        position = 0\n    }",
          "        playing = []\n        paused = []\n        stopTimer()\n    }"),

    M("M-P11", "canStop 恒为 true（播放头在开头也摆一个没用的停止按钮）",
      TRACK, "    var canStop: Bool { isPlaying || isPaused || position > 0 }",
          "    var canStop: Bool { true }"),

    # ---- seek ------------------------------------------------------------
    # 同 M-P01：原本靠读 currentTime 判命中，在无头环境下恒为 0，抓不到。
    # 现在靠 `requestedStartTimes`——判据变成「我们要求它去哪」，
    # 而非「播放器实际在哪」。这条变异会让暂停中的轨压根不进循环。
    M("M-P12", "seek 只动正在播的轨（暂停中的轨不跟随，续播会跳回旧位置）",
      TRACK, "        for track in players.keys {\n            seekPlayer(track, to: target)\n        }",
          "        for track in players.keys where players[track]?.isPlaying == true {\n            seekPlayer(track, to: target)\n        }"),

    # ---- 播完回落 -------------------------------------------------------
    M("M-P13", "isAtEnd 恒为 false（播完再按播放会立刻又结束，按钮像失灵）",
      TRACK, "        duration > 0 && position >= duration - endEpsilon",
          "        duration > 0 && false"),

    M("M-P14", "play() 在 stop() 之后才取续播位置（永远是 0，拖进度条后按播放从头来）",
      TRACK, "        let carried = position\n        stop()\n        paused = []",
          "        stop()\n        paused = []\n        let carried = position"),

    # ---- 载入 / 清空 -----------------------------------------------------
    #
    # 这两条一开始写成「删掉 load()/clear() 里的 `paused = []`」，
    # 结果全绿——查下去才发现那两行是**冗余防御**：两个函数都以 `stop()` 开头，
    # 而 `stop()` 里已经清了 `paused`。删掉它们本来就不会出事，
    # 所以这不是回归、是用例覆盖不到的东西，判据没错，是变异选错了。
    #
    # 换成真正会出事的那一处：**`stop()` 不再清 paused**。
    # 这才是真回归——切会议后新会议会被判成「可以继续上一场的暂停」。

    M("M-P15", "stop() 不清暂停态（切会议后带着上一场的暂停位置过来）",
      TRACK, "    func stop() {\n        for player in players.values { player.stop() }\n        playing = []\n        paused = []",
          "    func stop() {\n        for player in players.values { player.stop() }\n        playing = []"),

    # 这条第一版只拆掉 `stop()`，手动跑发现**测试仍然全绿**——查下去才发现
    # `load()` 里有**两道防线**：`stop()` 自己会清 `paused`，紧接着第 91 行
    # 还有一句 `paused = []`。拆一道，另一道照样拦住，所以测不出东西。
    # 这跟 M-P15 是同一类错误：**变异选错了，不是用例没覆盖到。**
    # 要模拟真回归，两道都得拆。
    M("M-P16", "load() 既不调 stop() 也不清 paused（切会议时旧状态全留着）",
      TRACK, "    func load(sessionID: String, directory: URL) {\n        stop()\n        players.removeAll()\n        loadErrors.removeAll()\n        duration = 0\n        position = 0\n        paused = []",
          "    func load(sessionID: String, directory: URL) {\n        players.removeAll()\n        loadErrors.removeAll()\n        duration = 0\n        position = 0"),

    # ---- 界面三态 -------------------------------------------------------
    M("M-P17", "底部按钮把「已暂停」也显示成「两轨同时播放」",
      VIEW, '        if player.isPaused { return "继续" }\n        return "两轨同时播放"',
          '        return "两轨同时播放"'),

    M("M-P18", "底部按钮永远显示「暂停」",
      VIEW, '        if player.isPlaying { return "暂停" }',
          '        return "暂停"'),

    M("M-P19", "续播提示不带真实位置（用户不知道会从哪继续）",
      VIEW, '        if player.isPaused { return "从 \\(clock(player.position)) 接着听" }',
          '        if player.isPaused { return "接着听" }'),
]


# 全局备份：脚本被 Ctrl-C / 超时杀掉时，源码可能停在变异态。
# 光靠 try/finally 不够——进程被杀时 finally 根本不会执行。
# 实测踩过：一次超时后 `if !isPlaying { position = 0 }` 留在源码里，
# 后续测试全部跑在错误版本上而不自知。
_SAFETY_BACKUP: dict[Path, bytes] = {}


def snapshot_sources():
    for p in (TRACK, VIEW):
        _SAFETY_BACKUP[p] = p.read_bytes()
    print(f"已备份 {len(_SAFETY_BACKUP)} 个源文件用于异常恢复")


def restore_all():
    for p, data in _SAFETY_BACKUP.items():
        try:
            if p.read_bytes() != data:
                p.write_bytes(data)
                touch(p)
                print(f"[恢复] {p.name} 已从备份还原")
        except Exception as e:
            print(f"[恢复失败] {p.name}: {e}")


def self_heal():
    """启动时先确认源码是干净的。若上一次是被中途杀掉的，这里能救回来。"""
    orig = TRACK.read_text(encoding="utf-8")
    # 注意：**只匹配代码行**，别匹配注释——`// 旧实现有一句 if !isPlaying ...`
    # 这种注释里就含变异片段，用子串判断会被它骗到（踩过一次）。
    code_lines = [l.strip() for l in orig.split("\n") if not l.strip().startswith("//")]
    suspicious = [l for l in code_lines if "if !isPlaying { position = 0 }" in l]
    if suspicious:
        print("[自愈] 检测到上一次残留的变异代码，先清除：")
        for l in suspicious:
            print("   ", l)
        cleaned = "\n".join(l for l in orig.split("\n")
                            if l.strip() != "if !isPlaying { position = 0 }")
        TRACK.write_text(cleaned, encoding="utf-8")
        touch(TRACK)
        print("[自愈] 已清除")


def run(cmd, timeout=900):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    # **swift test 把结果写在 stdout，但构建错误走 stderr**——
    # 只看 stdout 会漏掉真正的失败原因，判据就成了「猜」。
    return r.returncode, r.stdout + "\n===STDERR===\n" + r.stderr


def touch(path: Path):
    """把 mtime 推到当前时刻。

    **这条是整个脚本能不能用的关键**，踩过一次很隐蔽的坑：
    `shutil.copy2` 做备份会**保留原文件的 mtime**。还原时再 copy2 回去，
    文件内容对了但 mtime 退回备份那一刻（可能很老），
    SwiftPM 按时间戳判断「这个源文件没变过」，直接复用旧二进制——
    于是后续每条变异都跑在**陈旧产物**上，表现为「改了代码但测试还是绿的」。
    症状极具误导性：看起来像用例没覆盖到，其实是根本没重新编译。
    """
    now = time.time()
    os.utime(path, (now, now))


def apply(m: Mutation):
    """写入变异，返回备份路径。原文必须唯一命中，否则拒绝执行。"""
    src = m.path.read_text(encoding="utf-8")
    n = src.count(m.old)
    if n != 1:
        raise SystemExit(
            f"[{m.ident}] 原文片段命中 {n} 次，必须恰好 1 次。"
            f"片段：\n{m.old[:120]}"
        )
    backup = tempfile.mktemp(suffix=".swift")
    shutil.copy2(m.path, backup)
    m.path.write_text(src.replace(m.old, m.new), encoding="utf-8")
    touch(m.path)

    # 写完立刻读回来确认。**这一步不是多余的**：怀疑过「变异没真正落盘」
    # 这种最蠢的情况发生过。与其事后猜，不如当场验。
    #
    # 校验必须**按变异类型分两种情况**，踩过一次：
    # 原先只有一条规则「`m.new` 在 且 `m.old` 不在」。可插入型变异
    # （新片段 = 旧片段 + 额外一行，例如 M-P02 把 `position = 0` 插回去）
    # 里，`m.old` 是 `m.new` 的子串，于是替换后 `m.old` 当然还在——
    # 校验必然失败，而变异其实**已经正确落盘**了。
    # 症状是「跳过：变异片段未能唯一命中」，很容易误判成锚点失效，
    # 白花一轮去改锚点。判据本身错了，就跟被测代码一样危险。
    back = m.path.read_text(encoding="utf-8")
    if m.new not in back:
        raise SystemExit(f"[{m.ident}] 写入后读回校验失败：新片段不在文件里——变异没落盘")
    if m.old not in m.new:
        # 替换型：旧片段应该消失（原本恰好 1 次，替换后 0 次）
        if m.old in back:
            raise SystemExit(f"[{m.ident}] 写入后读回校验失败：旧片段仍在——变异没落盘")
    # 插入型（old 是 new 的子串）：旧片段出现次数应当不变，仍是 1 次。
    # 若变成 0，说明连锚点那部分一起被弄丢了。
    elif back.count(m.old) != 1:
        raise SystemExit(
            f"[{m.ident}] 写入后读回校验失败：锚点片段出现 "
            f"{back.count(m.old)} 次（应为 1 次）")
    return backup


def restore(m: Mutation, backup: str):
    """还原，并校验真的还原了。

    校验用**字节级比对**，不是「变异片段读不到了」——
    变异后的片段有可能在文件别处本来就存在（比如 `players[track]?.pause()`
    在 `toggleTrack` 里也有），据此报警是假警报。
    还原后必须 touch，否则下一次 apply 会被 SwiftPM 当成没改过。
    """
    shutil.copy2(backup, m.path)
    if not m.path.read_bytes():
        raise SystemExit(f"[{m.ident}] 还原后文件为空")
    if m.path.read_bytes() != Path(backup).read_bytes():
        shutil.copy2(backup, m.path)      # 再来一次，兜住偶发的部分写
        if m.path.read_bytes() != Path(backup).read_bytes():
            raise SystemExit(f"[{m.ident}] 还原两次后仍不一致，需人工检查")
    touch(m.path)


def main():
    # `--only M-P08,M-P14` 只跑指定几条。用途是**在干净基线上单独复核**：
    # 一次全量跑里，若某条 apply 之后源码没能正确还原，后面的变异就全跑在
    # 脏基线上，「命中」可能只是上一条变异的残留造成的假象。
    # 排查这类问题必须能单条重跑，否则改哪个都是猜。
    only = None
    if "--only" in sys.argv:
        i = sys.argv.index("--only")
        only = {s.strip() for s in sys.argv[i + 1].split(",")}

    selected = [m for m in MUTATIONS if only is None or m.ident in only]
    if not selected:
        print(f"没有匹配 --only {only} 的变异。可用编号："
              f"{', '.join(m.ident for m in MUTATIONS)}")
        return 1

    print(f"变异验证：{len(selected)} 条"
          + (f"（仅 {', '.join(sorted(only))}）" if only else ""))
    print(f"目标测试：{TARGET_TESTS}\n")
    self_heal()
    snapshot_sources()
    atexit.register(restore_all)

    # 先确认基线是绿的，否则「红」说明不了任何问题
    rc, base_out = run(f"{T_SH} --filter '{TARGET_TESTS}'")
    if rc != 0 or "with 0 failures" not in base_out:
        print("基线不绿，先修好再来做变异：")
        print(base_out[-2500:])
        return 1
    # 取**最大**的那个计数，不要用 `re.search` 抓第一个匹配——
    # swift test 会按target 逐个打「Executed 0 tests, with 0 failures」
    # （没被 filter 命中的套件也算），抓第一个永远得到 0，
    # 于是基线打印成「0 条全绿」，看着像什么都没跑。
    nums = [int(x) for x in re.findall(r"Executed (\d+) tests?, with 0 failures", base_out)]
    base_n = max(nums) if nums else "?"
    print(f"基线：{base_n} 条全绿\n")

    hits, misses = [], []

    for mut in selected:
        print(f"[{mut.ident}] {mut.desc}", flush=True)
        backup = None
        try:
            backup = apply(mut)
        except SystemExit as e:
            print(f"    跳过：{e}")
            misses.append((mut.ident, "变异片段未能唯一命中"))
            # apply() 可能**已经改写了源文件**才在读回校验处失败。
            # 此时必须还原，否则源码停在半变异态、后续变异全跑在错版本上。
            # 这里靠全局快照兜底（_SAFETY_BACKUP 在本轮开始时拍的）。
            if mut.path in _SAFETY_BACKUP and mut.path.read_bytes() != _SAFETY_BACKUP[mut.path]:
                mut.path.write_bytes(_SAFETY_BACKUP[mut.path])
                touch(mut.path)
                print(f"    已还原 {mut.path.name} 到本轮基线")
            continue

        try:
            rc, build = run(f"{T_SH} --filter '{TARGET_TESTS}'")
            # 1) 必须编译通过。编译不过的变异不算命中。
            #
            #    **判据本身踩过一次坑**：XCTest 断言失败输出的是
            #      `Foo.swift:97: error: -[MRGUITests.X] : XCTAssertTrue failed`
            #    编译错误输出的是
            #      `Foo.swift:80:16: error: value of type 'X' has no member 'y'`
            #    两者都有 "error:" 且都带行号，靠 `error:` 过滤会把**断言失败
            #    误判成编译失败**，19 条变异全被判成「编译器抓到了」，0 命中。
            #
            #    可靠的区别：**编译错误带列号（`:行:列:`），断言失败不带列号**。
            compile_err = re.findall(
                r"^\S+\.swift:\d+:\d+: error:", build, re.MULTILINE)
            if compile_err:
                print("    未命中：编译失败（不算命中，编译器抓到了）")
                print(f"      {compile_err[0][:120]}")
                misses.append((mut.ident, "编译失败"))
                continue

            # 2) 必须真的跑到了目标测试。跑 0 个 = 判据无效。
            ran = re.findall(r"Executed (\d+) tests?,", build)
            ran_n = max((int(x) for x in ran), default=0)
            if ran_n == 0:
                print("    判据无效：一个测试都没跑到")
                misses.append((mut.ident, "0 tests"))
                continue

            # 3) 期望它红。判据不能用 "failures" 字样——
            #    `with 0 failures` 里也含 "failures"，得看有没有非零数。
            #
            #    **而且不能只匹配复数 `failures`**——XCTest 的输出是按数量变形的：
            #      1 条失败 → `Executed 28 tests, with 1 failure`
            #      2 条失败 → `... with 2 failures`
            #    写成 `failures` 的话，**只有 1 条失败的变异会整行漏掉**，
            #    于是明明红了却判成「未命中」。
            #    这个 bug 极隐蔽：它只在「恰好红 1 条」时发作，
            #    表现为「同一批变异时好时坏」，很容易被误判成用例覆盖不稳。
            #    ——本轮实测 19 条里 7 条就这样被误判成漏网。
            exec_lines = re.findall(
                r"Executed (\d+) tests?, with (\d+) failures?", build)
            any_fail = any(int(f) > 0 for _, f in exec_lines)
            if any_fail:
                first = next((l for l in build.splitlines()
                              if re.match(r"^\S+\.swift:\d+: error:", l)), "")
                print(f"    命中（{ran_n} 条执行）")
                if first:
                    print(f"      {first.strip()[:150]}")
                hits.append(mut.ident)
            else:
                print(f"    未命中：{ran_n} 条执行但仍全绿 ← 用例没覆盖到")
                misses.append((mut.ident, "全绿"))
        finally:
            if backup:
                restore(mut, backup)

    print("\n" + "=" * 60)
    print(f"命中 {len(hits)} / {len(MUTATIONS)}")
    if hits:
        print("  " + ", ".join(hits))
    if misses:
        print("未命中：")
        for ident, why in misses:
            print(f"  {ident}  {why}")
    print("=" * 60)
    return 0 if not misses else 2


if __name__ == "__main__":
    sys.exit(main())