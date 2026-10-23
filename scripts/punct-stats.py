#!/usr/bin/env python3
"""标点密度统计 —— 用来比较「同一段音频 / 同一批音频」在不同引擎下的标点产出。

为什么要单独一个脚本：标点密度的口径很容易被无意改掉（算不算字母？算不算 `%`？
整段比还是截同样时长比？），口径一变两次跑的结论就不可比。这里把口径写死在文件里。

口径（改动前请先想清楚会破坏哪些既有结论）：
  - 字符数 = 汉字 + 字母 + 数字
  - 标点 = 中英文断句标点（不含 `%` `$` 这类非断句符号）
  - 密度 = 标点数 ÷ 字符数 × 100，单位「标点/百字」
  - 段 = `transcript.json` 里的一条 segment；`.txt` 则按行

用法：
    python3 scripts/punct-stats.py ~/Documents/MeetingRecorder/*/transcript.json
    python3 scripts/punct-stats.py <whisper 输出目录>/out-*.txt
"""
import json
import os
import re
import sys

PUNCT = set("。，、！？；：（）《》「」『』…—～·,.!?;:()\"'")
HALF = set(",.!?;:()")
FULL = set("。，、！？；：（）")
CJK = re.compile(r"[\u4e00-\u9fff]")
ALNUM = re.compile(r"[A-Za-z0-9]")


def measure(texts):
    """texts 是「一段段文本」。返回汇总指标。"""
    chars = punct = 0
    zero_seg = long_zero_seg = 0
    segs = []
    for t in texts:
        t = t.strip()
        if not t:
            continue
        c = len(CJK.findall(t)) + len(ALNUM.findall(t))
        p = sum(1 for x in t if x in PUNCT)
        chars += c
        punct += p
        if p == 0:
            zero_seg += 1
        if c >= 40 and p == 0:
            long_zero_seg += 1
        segs.append((c, p, t))
    return {
        "segments": len(segs), "chars": chars, "punct": punct,
        "density": (punct / chars * 100) if chars else 0.0,
        "zero": zero_seg, "long_zero": long_zero_seg,
        "half": sum(1 for _, _, t in segs for x in t if x in HALF),
        "full": sum(1 for _, _, t in segs for x in t if x in FULL),
        "longest": sorted(segs, key=lambda r: -r[0])[:3],
    }


def report(name, texts):
    m = measure(texts)
    n = m["segments"]
    print(f"\n{'=' * 76}\n【{name}】\n{'=' * 76}")
    print(f"  段数                    : {n}")
    print(f"  字符数（汉字+字母+数字）: {m['chars']}")
    print(f"  标点数                  : {m['punct']}"
          f"（半角 {m['half']} / 全角 {m['full']}）")
    print(f"  标点密度                : {m['density']:.1f} 标点/百字")
    print(f"  零标点段                : {m['zero']}/{n}"
          f"（{100 * m['zero'] / n if n else 0:.0f}%）")
    print(f"  超长零标点段（≥40 字）  : {m['long_zero']}")
    for c, p, t in m["longest"]:
        print(f"    {c:4d} 字 {p:2d} 标点 │ {t[:54]}…")
    return m


def load(path):
    """返回 [(组名, [文本])]。json 按 track 分组，txt 整体一组。"""
    if path.endswith(".json"):
        try:
            doc = json.load(open(path, encoding="utf-8"))
        except Exception as e:
            print(f"读取失败 {path}: {e}")
            return None, None
        by_track = {}
        for s in doc.get("segments", []):
            by_track.setdefault(s.get("track", "?"), []).append(s.get("text", ""))
        header = (f"引擎 {doc.get('engine')}　语言 {doc.get('language')}"
                  f"　会话 {doc.get('sessionID')}")
        return header, sorted(by_track.items())
    if os.path.exists(path):
        return "", [(".", open(path, encoding="utf-8").read().splitlines())]
    print(f"找不到文件：{path}")
    return None, None


def main(paths):
    grand = None
    for path in paths:
        header, groups = load(path)
        if groups is None:
            continue
        print(f"\n{'#' * 76}\n# {path}")
        if header:
            print(f"# {header}")
        print(f"{'#' * 76}")
        for name, texts in groups:
            m = report(name, texts)
            if grand is None:
                grand = dict(m)
                grand["longest"] = []
            else:
                for k in ("segments", "chars", "punct", "zero", "long_zero",
                          "half", "full"):
                    grand[k] += m[k]
    if grand and grand["chars"]:
        print(f"\n{'=' * 76}")
        print(f"全部样本合计：{grand['chars']} 字，{grand['punct']} 标点，"
              f"密度 {grand['punct'] / grand['chars'] * 100:.1f}/百字")
        print(f"{'=' * 76}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    main(sys.argv[1:])
