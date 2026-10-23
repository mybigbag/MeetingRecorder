#!/bin/bash
# 跑会议详情右栏的渲染探针（详见 main.swift 顶部说明）。
#
# 产出四张 PNG 到 /tmp/mr-ui-preview/。它**不需要**屏幕录制权限，
# 也不启动录音器、不碰真实偏好（跑在临时目录 + 独立 UserDefaults suite 里）。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
products="$root/.build/out/Products/Debug"

if [ ! -f "$products/MRGUI.o" ]; then
  echo "先构建一次：swift build --package-path $root" >&2
  exit 1
fi

swiftc -O -enable-testing \
  -I "$products" \
  -o /tmp/mr-detail-render-probe \
  "$here/main.swift" \
  "$products"/MRGUI.o \
  "$products"/MRSession.o \
  "$products"/MRMinutes.o \
  "$products"/MRCore.o \
  "$products"/MRCapture.o \
  "$products"/MRTranscribe.o

/tmp/mr-detail-render-probe

echo
echo "看一眼：open /tmp/mr-ui-preview/detail-*.png"