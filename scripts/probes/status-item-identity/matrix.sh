#!/bin/bash
# 状态栏图标「在不在屏幕上」的开关差实验。
#
# 判据不是截图肉眼看，也不是 NSStatusItem.visible（它会骗人，见 README），
# 而是：整条菜单栏截图 → 逐列找亮字形 → 数出图标簇。
# 应用启动前后各截一次，右边多出来的那一簇就是它的状态栏图标。
#
# 用法：
#   ./matrix.sh <app 路径> [初始 bundle id]
#   ./matrix.sh /path/to/MeetingRecorder.app com.pxing.meeting-recorder
#
# 脚本会在**副本**上改 bundle id，不动原应用；每次跑完把副本删掉并注销注册。
set -u

APP="${1:?用法: ./matrix.sh <app 路径> [初始 bundle id]}"
BASE_ID="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
LOGICAL_WIDTH=1710          # 屏幕逻辑宽度，用于把像素簇换算回 x 坐标
BRIGHT=190                  # 菜单栏图标是近白字形；蓝底会被这个阈值挡掉

command -v swiftc >/dev/null || { echo "需要 swiftc（Xcode 命令行工具）"; exit 1; }

echo "=== 编译检测工具 ==="
swiftc -O -o "$WORK/glyphcols" "$HERE/glyphcols.swift" || exit 1
swiftc -O -o "$WORK/colordiff" "$HERE/colordiff.swift" || exit 1

kill_ours() {
  # 只杀本脚本复制出来的那一份，别碰用户自己开着的应用
  for p in $(pgrep -f "$WORK/" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  sleep 2
}

shot() { sleep 6; screencapture -x -R0,0,${LOGICAL_WIDTH},40 "$1"; }

# 只数**屏幕右半边**的图标簇。
#
# 左边那些簇是当前最前台应用的菜单标题（「文件」「编辑」…），前台应用一换，
# 数量就在 11~16 之间乱跳——把它们算进来，开关差会被这点噪声完全盖掉。
# 第一版就是这么错的：数出「运行前 16 → 运行后 13」。
#
# 宽度 12~40 筛掉日期文字（它是一整块 44+ 宽的簇）和零碎笔画。
STATUS_AREA_MIN_X=850
clusters() {
  "$WORK/glyphcols" "$1" "$LOGICAL_WIDTH" "$BRIGHT" \
    | awk -v minx="$STATUS_AREA_MIN_X" '
        /^  x / {
          lo = $2 + 0; w = $5 + 0
          if (lo >= minx && w >= 12 && w <= 40) n++
        }
        END { print n + 0 }'
}

# 列出右半边的图标簇，用来对照「多出来的那一个」在哪个 x
status_clusters() {
  "$WORK/glyphcols" "$1" "$LOGICAL_WIDTH" "$BRIGHT" \
    | awk -v minx="$STATUS_AREA_MIN_X" '
        /^  x / { lo = $2 + 0; w = $5 + 0; if (lo >= minx && w >= 12 && w <= 40) print }'
}

report() {
  local label="$1" before="$2" after="$3"
  local nb na
  nb=$(clusters "$before")
  na=$(clusters "$after")
  echo "CASE: $label"
  echo "   右半边图标簇：运行前 $nb → 运行后 $na"
  if [ "$na" -gt "$nb" ]; then
    echo "   结论：菜单栏上多出了一个图标"
    status_clusters "$after" | head -4 | sed 's/^/     /'
  else
    echo "   结论：菜单栏上什么都没多出来"
  fi
  echo
}

run_case() {
  local bundle_id="$1"
  local copy="$WORK/app-$bundle_id.app"
  # 直接拷 .app 目录（cp -R 会保留扩展属性，签名仍然有效）
  cp -R "$APP" "$copy"
  local pl="$copy/Contents/Info.plist"
  [ -n "$bundle_id" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$pl" >/dev/null
  codesign --force --deep --sign - "$copy" >/dev/null 2>&1
  "$LSREGISTER" -f "$copy" >/dev/null 2>&1

  kill_ours
  shot "$WORK/before.png"
  open "$copy"
  shot "$WORK/after.png"
  report "${bundle_id:-（原 bundle id）}" "$WORK/before.png" "$WORK/after.png"
  kill_ours
}

if [ -n "$BASE_ID" ]; then
  run_case "$BASE_ID"
  run_case "${BASE_ID}.probe-b"
fi

echo "=== 清理 ==="
kill_ours
for d in "$WORK"/app-*.app; do [ -d "$d" ] && "$LSREGISTER" -u "$d" >/dev/null 2>&1; done
rm -rf "$WORK"
echo "完成"
