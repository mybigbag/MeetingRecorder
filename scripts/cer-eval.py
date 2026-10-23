#!/usr/bin/env python3
"""转写稿的**字级错误率（CER）**度量与两稿分歧定位。

## 为什么需要它

「换一个引擎能不能提高转写准确率」这句话，在本项目里此前**无法验收**——
`scripts/punct-stats.py` 测的是标点密度，不是准确率。两者是不同的东西：
标点密度回答「稿子能不能读」，CER 回答「字对不对」。

没有基线就换引擎，结果只能是「感觉好像好一点」，而那不足以支撑一次不可逆的改动。

## 两种模式

### 1. 真 CER（有参考稿时）

    python3 scripts/cer-eval.py --ref 人工校对稿.txt 苹果稿.txt SenseVoice稿.txt

对每个候选稿算 CER = 编辑距离 / 参考稿字数，并给出 替换/删除/插入 的拆解。

**参考稿从哪来**：只能人工校对。这是本项目唯一无法自动化的验收环节。
但可以用 `--matrix` 模式把人工量压到最小（见下）。

### 2. 两两分歧 + 校对清单（没有参考稿时）

    python3 scripts/cer-eval.py --matrix 苹果稿.txt SenseVoice稿.txt whisper稿.txt

给出两两的「分歧率」与**逐处分歧清单**。注意：**分歧率不是错误率**——
两个引擎都错成一样时分歧率为 0，一个错一个对时分歧率很高。它的用途是
**当人工校对的待办清单**：只需要核对分歧点，一致的部分（通常占大多数）可以直接跳过。

## 口径（写死在这里，改动前先想清楚会破坏哪些既有结论）

- **归一化**：去掉全部标点与空白；全角转半角；ASCII 字母统一小写
- **不做的归一化**：中文数字 ↔ 阿拉伯数字**不互转**。ITN（「7折」vs「七折」）
  是真实差异，会被单独列出来而不是悄悄抹平
- **单位**：字 = 汉字 + 字母 + 数字（与 `punct-stats.py` 同口径）
- **CER** = 编辑距离 ÷ 参考稿字数。所以 CER 可以 > 100%（候选稿比参考稿长很多时）
- 输入可以是 `.txt`（每行一段，拼接后比较）或 `transcript.json`（取全部 segment 文本）

## 已知边界

- 编辑距离是 O(n·m) 的，长稿（数万字）会比较慢；本脚本用滚动数组，内存是 O(m)
- 只做字级对齐，不做词级/语义级判断：「的/地/得」这类错都会计入
"""
import argparse
import json
import os
import re
import sys
import unicodedata
from difflib import SequenceMatcher

CJK = re.compile(r"[\u4e00-\u9fff]")
ALNUM = re.compile(r"[A-Za-z0-9]")
PUNCT_OR_SPACE = re.compile(r"[\s。，、！？；：（）《》「」『』…—～·,.!?;:()\"'`\[\]{}<>/\\|~@#$%^&*+=_-]")


def normalize(text):
    """归一化：去标点空白、全角转半角、ASCII 小写。口径见文件头。"""
    text = unicodedata.normalize("NFKC", text)
    text = PUNCT_OR_SPACE.sub("", text)
    return "".join(c.lower() if c.isascii() else c for c in text)


def load_text(path):
    """读一稿。返回 (归一化文本, 原始文本)。"""
    if path.endswith(".json"):
        doc = json.load(open(path, encoding="utf-8"))
        raw = "".join(s.get("text", "") for s in doc.get("segments", []))
    else:
        raw = "".join(open(path, encoding="utf-8").read().splitlines())
    return normalize(raw), raw


def edit_ops(a, b):
    """把 a（参考）变成 b（候选）所需的 替换/删除/插入 数量。滚动数组算距离。"""
    n, m = len(a), len(b)
    if n == 0:
        return m, 0, 0, m
    prev = list(range(m + 1))
    # back[i][j]: 0=match 1=sub 2=del 3=ins，用于回溯统计
    back = [[0] * (m + 1) for _ in range(n + 1)]
    for j in range(m + 1):
        back[0][j] = 3
    for i in range(1, n + 1):
        back[i][0] = 2
    for i in range(1, n + 1):
        cur = [i] + [0] * m
        for j in range(1, m + 1):
            if a[i - 1] == b[j - 1]:
                cur[j] = prev[j - 1]
                back[i][j] = 0
            else:
                sub, dele, ins = prev[j - 1] + 1, prev[j] + 1, cur[j - 1] + 1
                best = min(sub, dele, ins)
                cur[j] = best
                back[i][j] = 1 if best == sub else (2 if best == dele else 3)
        prev = cur
    dist = prev[m]
    # 回溯统计
    s = d = i2 = 0
    i, j = n, m
    while i > 0 or j > 0:
        op = back[i][j]
        if op == 0:
            i, j = i - 1, j - 1
        elif op == 1:
            s += 1; i, j = i - 1, j - 1
        elif op == 2:
            d += 1; i -= 1
        else:
            i2 += 1; j -= 1
    return dist, s, d, i2


def char_count(text):
    return len(CJK.findall(text)) + len(ALNUM.findall(text))


def report_cer(ref_text, ref_raw, cand_path, cand_text):
    dist, s, d, ins = edit_ops(ref_text, cand_text)
    denom = len(ref_text) or 1
    print(f"\n  候选：{cand_path}")
    print(f"    字数        : {char_count(cand_text)}（参考 {char_count(ref_text)}）")
    print(f"    编辑距离    : {dist}")
    print(f"    替换/删除/插入 : {s} / {d} / {ins}")
    print(f"    **CER       : {dist / denom * 100:.2f}%**")
    return dist / denom


def disagreements(a_text, b_text, a_raw, b_raw, limit):
    """用字符序列对齐找分歧段，返回 [(参考侧片段, 候选侧片段)]。"""
    sm = SequenceMatcher(None, a_text, b_text, autojunk=False)
    out = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        out.append((a_text[i1:i2], b_text[j1:j2]))
    return out[:limit]


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--ref", help="参考稿（人工校对稿），给了就算真 CER")
    ap.add_argument("--matrix", action="store_true", help="两两分歧率 + 校对清单")
    ap.add_argument("--limit", type=int, default=25, help="每对最多列多少处分歧")
    ap.add_argument("files", nargs="*")
    args = ap.parse_args()

    if not args.files:
        print(__doc__)
        return 2

    loaded = []
    for p in args.files:
        if not os.path.exists(p):
            print(f"找不到：{p}")
            return 2
        loaded.append((p, *load_text(p)))

    if args.ref:
        ref_text, ref_raw = load_text(args.ref)
        print(f"参考稿：{args.ref}　归一化后 {len(ref_text)} 字")
        for path, text, raw in loaded:
            report_cer(ref_text, ref_raw, path, text)
        return 0

    if args.matrix:
        print("两两分歧率（**不是错误率**——两边同错则分歧为 0）")
        print(f"{'稿件 A':<28}{'稿件 B':<28}{'分歧率':>9}{'分歧处数':>10}")
        print("-" * 76)
        for i in range(len(loaded)):
            for j in range(i + 1, len(loaded)):
                pa, ta, ra = loaded[i]
                pb, tb, rb = loaded[j]
                diffs = disagreements(ta, tb, ra, rb, 10 ** 9)
                denom = max(len(ta), len(tb)) or 1
                # 分歧字符数 / 较长稿字数
                n = sum(max(len(x), len(y)) for x, y in diffs)
                print(f"{os.path.basename(pa):<28}{os.path.basename(pb):<28}"
                      f"{n / denom * 100:>8.1f}%{len(diffs):>10}")

        if len(loaded) == 2:
            pa, ta, ra = loaded[0]
            pb, tb, rb = loaded[1]
            print(f"\n校对清单（只需核对这 {args.limit} 处；其余一致）")
            print(f"  「{os.path.basename(pa)}」→「{os.path.basename(pb)}」")
            for k, (x, y) in enumerate(disagreements(ta, tb, ra, rb, args.limit), 1):
                print(f"    {k:3d}. {x or '∅':<24} → {y or '∅'}")
        return 0

    print("请给 --ref 或 --matrix。")
    return 2


if __name__ == "__main__":
    sys.exit(main())
