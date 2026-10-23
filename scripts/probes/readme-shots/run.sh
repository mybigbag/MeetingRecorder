#!/bin/bash
# 跑 README 拍图探针（详见 main.swift 顶部说明）。
#
# 产出两张 PNG 到 docs/screenshots/：主窗口（有内容）+ 设置窗口。
# 内容全部是合成数据，跑在临时目录与独立偏好域里，
# **不碰真实会议库**，也不需要屏幕录制权限。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
products="$root/.build/out/Products/Debug"

if [ ! -f "$products/MRGUI.o" ]; then
  echo "先构建一次：swift build --disable-sandbox" >&2
  exit 1
fi

swiftc -O -enable-testing \
  -I "$products" \
  -o /tmp/mr-readme-shots \
  "$here/main.swift" \
  "$products"/MRGUI.o \
  "$products"/MRSession.o \
  "$products"/MRMinutes.o \
  "$products"/MRCore.o \
  "$products"/MRCapture.o \
  "$products"/MRTranscribe.o

/tmp/mr-readme-shots

echo
echo "看一眼：open \"$root/docs/screenshots/main-window.png\""
