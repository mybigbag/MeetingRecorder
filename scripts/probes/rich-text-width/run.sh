#!/bin/bash
# 量「纪要卡片里的富文本有没有撑满宽度」（详见 main.swift）。
#
# 退出码：0 = 撑满（FILL）、1 = 有屏窄了（NARROW）、2 = 没量到（INCONCLUSIVE）。
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
  -o /tmp/mr-rich-text-width \
  "$here/main.swift" \
  "$products"/MRGUI.o \
  "$products"/MRSession.o \
  "$products"/MRMinutes.o \
  "$products"/MRCore.o \
  "$products"/MRCapture.o \
  "$products"/MRTranscribe.o || exit 1

/tmp/mr-rich-text-width
code=$?
echo
[ "$code" -eq 1 ] && echo "❌ 有屏没撑满，这是缺陷。"
[ "$code" -eq 2 ] && echo "❌ 探针没跑成（不是「正常」，是没结论）。"
exit "$code"
