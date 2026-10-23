#!/bin/bash
# 跑设置界面的渲染探针（详见 main.swift 顶部说明）。
#
# 产出 PNG 到 /tmp/mr-ui-preview/：设置窗口按三页分页逐屏 + 组件图 + 顶栏「录音设置」面板两屏。
# 它**不需要**屏幕录制权限，也不启动录音器、不碰真实偏好
# （跑在临时目录 + 独立 UserDefaults suite 里）。
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
  -o /tmp/mr-settings-render-probe \
  "$here/main.swift" \
  "$products"/MRGUI.o \
  "$products"/MRSession.o \
  "$products"/MRMinutes.o \
  "$products"/MRCore.o \
  "$products"/MRCapture.o \
  "$products"/MRTranscribe.o

/tmp/mr-settings-render-probe

echo
echo "看一眼：open /tmp/mr-ui-preview/settings-recording.png"
echo "        open /tmp/mr-ui-preview/settings-minutes-cloud-ok.png"
echo "        open /tmp/mr-ui-preview/settings-general.png"
echo "        open /tmp/mr-ui-preview/settings-row-expanded.png"
echo "        open /tmp/mr-ui-preview/settings-popover-icon-off.png"