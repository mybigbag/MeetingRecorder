#!/usr/bin/env python3
"""比对「同一音频的不同存储格式」的转写结果，量化降格式对识别质量的影响。

为什么要单独一个脚本：这里的比对有三处容易做错，写死在文件里免得每次重新踩。

  1. **必须去标点再比**。标点密度在中文 ASR 上本来就极不稳定（同一份音频
     逐字一致但标点可能变），把标点算进相似度会把「标点抖动」误判成「识别错误」。
  2. **必须有重复对照**。引擎可能有抖动，不给「同一文件跑两遍」这一组，
     就无法区分差异来自降格式还是来自引擎自身。
  3. **相似度不是准确率**。SequenceMatcher 的 ratio 会把一个字的错认稀释到
     整段长度上；所以同时给出「编辑距离」和「首个差异片段」，后者才是判断
     「是听错了字」还是「整句丢了」的依据。

用法：
    python3 scripts/storage-eval-compare.py <输出目录>
    # 目录里应有 out-<源>-f32-a.txt / out-<源>-f32-b.txt / out-<源>-<变体>.txt
"""
import difflib
import os
import re
import sys

# 标点与空白都不参与比对（见文件头第 1 条）
STRIP = set("。，、！？；：（）《》「」『』…—～·,.!?;:()\"'%-_ \t\n\r")


def load(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def plain(s):
    return "".join(c for c in s if c not in STRIP)


def similarity(a, b):
    """0~1 的相似度。两边都空时视为相同（空对空没有信息，不该判成失败）。"""
    if not a and not b:
        return 1.0
    return difflib.SequenceMatcher(None, a, b, autojunk=False).ratio()


def first_diff(a, b, width=14):
    """第一处不一致的上下文，用来肉眼判断「错字」还是「漏句」。"""
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        before = a[max(0, i1 - width):i1]
        got = b[j1:j2]
        want = a[i1:i2]
        after = a[i2:i2 + width]
        return f"…{before}[基准「{want}」→「{got}」]{after}…"
    return ""


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mr-storage-eval"
    files = sorted(f for f in os.listdir(root) if f.startswith("out-") and f.endswith(".txt"))

    # 按「源」归组：S202956-f32-a → 源 S202956，变体 f32-a
    # 源名本身不含连字符，所以按**第一个**连字符切，而不是最后一个——
    # 变体名里还有连字符（f32-a、pcm16-2ch），按最后一个切会把源名切错。
    groups = {}
    for f in files:
        stem = f[4:-4]                       # 去掉 out- 与 .txt
        parts = stem.split("-", 1)
        if len(parts) != 2:
            continue
        src, variant = parts
        groups.setdefault(src, {})[variant] = os.path.join(root, f)

    print("=" * 100)
    print("引擎抖动基线（同一文件、同一格式、跑两遍）")
    print("=" * 100)
    print(f"{'源':<10}{'基准字数':>8}{'重跑字数':>8}{'相似度':>9}   判定")
    print("-" * 100)
    for src in sorted(groups):
        v = groups[src]
        if "f32-a" not in v or "f32-b" not in v:
            continue
        a, b = plain(load(v["f32-a"])), plain(load(v["f32-b"]))
        ratio = similarity(a, b)
        verdict = "完全一致" if ratio == 1.0 else f"有抖动（{first_diff(a, b)}）"
        print(f"{src:<10}{len(a):>8}{len(b):>8}{ratio * 100:>8.1f}%   {verdict}")

    print()
    print("=" * 100)
    print("各格式相比原格式（float32 / 48k / 原始声道）")
    print("=" * 100)
    header = f"{'源':<10}{'变体':<14}{'字数':>6}{'相似度':>9}{'编辑距离':>9}   首处差异"
    print(header)
    print("-" * 100)

    summary = {}
    for src in sorted(groups):
        v = groups[src]
        if "f32-a" not in v:
            continue
        base = plain(load(v["f32-a"]))
        for variant in sorted(v):
            if variant.startswith("f32"):
                continue
            cand = plain(load(v[variant]))
            ratio = similarity(base, cand)
            dist = int(round((1 - ratio) * max(len(base), len(cand))))
            diff = first_diff(base, cand) or "—"
            print(f"{src:<10}{variant:<14}{len(cand):>6}{ratio * 100:>8.1f}%{dist:>9}   {diff}")
            summary.setdefault(variant, []).append((src, ratio, dist))

    print()
    print("=" * 100)
    print("按格式汇总（跨全部源）")
    print("=" * 100)
    print(f"{'变体':<14}{'样本数':>7}{'最差相似度':>11}{'平均相似度':>11}{'总编辑距离':>11}")
    print("-" * 100)
    for variant in sorted(summary, key=lambda k: sum(x[1] for x in summary[k]) / len(summary[k]), reverse=True):
        rows = summary[variant]
        ratios = [r for _, r, _ in rows]
        print(f"{variant:<14}{len(rows):>7}{min(ratios) * 100:>10.1f}%"
              f"{sum(ratios) / len(ratios) * 100:>10.1f}%{sum(d for _, _, d in rows):>11}")

    print()
    print("=" * 100)
    print("口径：相似度与编辑距离都基于**去掉标点与空白**的纯文本，")
    print("      标点在中文 ASR 上本身就不稳定，计入会把标点抖动误判成识别错误。")
    print("=" * 100)


if __name__ == "__main__":
    main()
