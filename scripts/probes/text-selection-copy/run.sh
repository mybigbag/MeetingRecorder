#!/bin/bash
# 跑「纪要划词选中 + ⌘C 复制」探针（详见 main.swift 顶部说明）。
#
# 两遍：selectable（生产同款修饰符，期望复制成功）
#       plain（阴性对照，期望复制不到）
# 结论读**输出行**，不读退出码：真 NSApplication.run() 里 exit(n) 拿回来永远是 0。
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
  -o /tmp/mr-text-selection-probe \
  "$here/main.swift" \
  "$products"/MRGUI.o \
  "$products"/MRSession.o \
  "$products"/MRMinutes.o \
  "$products"/MRCore.o \
  "$products"/MRCapture.o \
  "$products"/MRTranscribe.o || exit 1

# 三种结果、三个退出码（读结论行，不读进程退出码）：
#   0  链路通（可选文本复制走了，不可选文本复制不到）
#   1  探针失效（不可选文本也被复制走 → 这个探针不可信）
#   2  测不出结论（两路结果一样 → 本机建不起选区，只能人工试）
selectable="$(/tmp/mr-text-selection-probe selectable 2>&1)"; echo "$selectable"
plain="$(/tmp/mr-text-selection-probe plain 2>&1)";       echo "$plain"

if echo "$plain" | grep -q "CONCLUSION: PROBE-BROKEN"; then
  echo "❌ 探针失效：不可选文本也被复制走了，这次结果不能作为证据。"
  exit 1
fi
if echo "$selectable" | grep -q "CONCLUSION: LINK-OK"; then
  echo "✅ 链路通：划词选中 + ⌘C 能把内容复制走（阴性对照同时成立）。"
  exit 0
fi
echo "⚠️  无结论：两路都没复制到，分不出「⌘C 不工作」与「根本没建立选区」。"
echo "   本机（2026-10-22）实测就是这一种：合成鼠标事件建不起 SwiftUI 选区。"
echo "   要真结论只能人工试：打开 App → 划一句 → ⌘C → 粘到别处（SM-24-1）。"
exit 2
