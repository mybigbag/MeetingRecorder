#!/bin/bash
# 跑「会议纪要跨行划选 + ⌘C」探针（详见 main.swift 头顶的说明）。
#
# 三个模式都要跑，缺一不可：
#   swiftui          旧实现，期望「只能选中 1 行」——把用户报的现象复现出来
#   textview-single  新实现，单行内拖，期望恰好 1 行——证明选区跟拖拽范围走
#   textview-cross   新实现，跨段落拖，期望 ≥2 行且含两个不同小节的词
#   scroll           滚轮落在卡片上，期望外层照常滚动（否则「鼠标停在纪要上滚不动」）
#
# 三种结论分开报：LINK-OK / INCONCLUSIVE / PROBE-BROKEN。
# **INCONCLUSIVE 不许被当成通过**，脚本会以非零退出码停下。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
products="$root/.build/out/Products/Debug"

if [ ! -f "$products/MRGUI.o" ]; then
  echo "先构建一次：swift build --package-path $root" >&2
  exit 1
fi

swiftc -O -enable-testing \
  -I "$products" \
  -o /tmp/mr-minutes-selection-probe \
  "$here/main.swift" \
  "$products"/MRGUI.o \
  "$products"/MRSession.o \
  "$products"/MRMinutes.o \
  "$products"/MRCore.o \
  "$products"/MRCapture.o \
  "$products"/MRTranscribe.o || exit 1

fail=0
for mode in swiftui textview-single textview-cross scroll; do
  echo "── $mode ──────────────────────────────────────────"
  out="$(/tmp/mr-minutes-selection-probe "$mode" 2>&1)"
  echo "$out"
  # ⚠️ 必须用 -E：macOS 自带的是 BSD grep，基本正则里的 `\|` 不是「或」，
  # 而是字面竖线——第一版就是这么写，三路明明都有结论却被判成「没结论」。
  if ! echo "$out" | grep -qE "CONCLUSION: (LINK-OK|BUG-REPRODUCED|SCROLL-OK)"; then
    echo "❌ $mode 没拿到可用结论（见上）"
    fail=1
  fi
  echo
done

if [ "$fail" -ne 0 ]; then
  echo "至少一路没有结论——不许把「测不出」当成「通过」。"
  exit 1
fi
echo "四路都有结论：旧实现只能选 1 行（bug 复现）、新实现单行 1 行 / 跨段 ≥2 行、滚轮不被卡片吃掉。"
