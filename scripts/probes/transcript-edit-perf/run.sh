#!/bin/bash
# 量「1375 段的会议，详情页首屏与进编辑态」要多久（详见 main.swift）。
#
# 结论三种：FAST / WARN / SLOW。WARN 不算失败，但阈值不是验收线——
# 要看打印出来的毫秒数说话。
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
  -o /tmp/mr-edit-perf-probe \
  "$here/main.swift" \
  "$products"/MRGUI.o \
  "$products"/MRSession.o \
  "$products"/MRMinutes.o \
  "$products"/MRCore.o \
  "$products"/MRCapture.o \
  "$products"/MRTranscribe.o || exit 1

/tmp/mr-edit-perf-probe
code=$?
echo
[ "$code" -eq 1 ] && echo "❌ 首屏过慢，这条要当缺陷处理。"
[ "$code" -eq 2 ] && echo "❌ 探针没跑成（不是「快」，是没结论）。"
exit "$code"
