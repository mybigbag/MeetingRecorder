#!/bin/bash
# 依据「源码最后一次修改的时间」更新 App 版本号。
#
# ## 规则（2026-10-21 定）
#
#     2.20261021.1654
#     └┬┘ └──┬───┘ └┬─┘
#      │     │      └── 这次改动**完成的时刻**（HHMM）
#      │     └────────── 这次改动**完成的日期**（YYYYMMDD）
#      └──────────────── 主线（大）版本，**只在用户明确要求时改**
#
# 小版本用时间而不是 `+1` 递增，是因为「我装的是不是最新的」这个问题
# 只能靠时间和代码改动对上号：`2.0.7` 既不说明它有多新，也不说明隔了哪些改动。
#
# ## 为什么取「源码最新 mtime」而不是「现在」
#
# 现在的时间会在**每一次重打包**时推进，于是同一份代码打两次包就有两个版本号，
# 版本号立刻失去意义（用户会以为功能变了，其实一个字节都没变）。
# 取源码最新 mtime 则相反：
#   · 代码没改 → 重打包版本号不变 → 「版本一样」就真的是同一份代码；
#   · 代码改了 → 版本号必然变 → 「版本变了」就一定有改动。
#
# ## 用法
#
#     ./scripts/bump-version.sh              # 需要时更新，并打印当前版本
#     ./scripts/bump-version.sh --dry-run    # 只算不改
#     ./scripts/bump-version.sh --print      # 只打印当前版本（打包产物自检用）
#     MAJOR=3 ./scripts/bump-version.sh       # 改大版本（用户要求时才用）
#
# `build-app.sh` 会自动调用本脚本，所以正常情况下不必手动跑。
set -euo pipefail

cd "$(dirname "$0")/.."

PLIST="app/Info.plist"
DRY_RUN=0
ONLY_PRINT=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --print)   ONLY_PRINT=1 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "❌ 不认识的参数：$arg" >&2; exit 2 ;;
  esac
done

[ -f "$PLIST" ] || { echo "❌ 找不到 $PLIST" >&2; exit 1; }

CURRENT="$(plutil -extract CFBundleShortVersionString raw "$PLIST" 2>/dev/null || true)"
CURRENT="${CURRENT:-0.0}"

# 大版本：**默认沿用现有值**。这就是「大版本只在用户要求时才改」的落地方式——
# 脚本不会自己把 2 推成 3，唯一的入口是显式传 MAJOR。
if [ -n "${MAJOR:-}" ]; then
  MAJOR_VALUE="$MAJOR"
else
  MAJOR_VALUE="${CURRENT%%.*}"
fi
case "$MAJOR_VALUE" in
  ''|*[!0-9]*) echo "❌ 大版本号必须是整数，拿到的是「$MAJOR_VALUE」" >&2; exit 2 ;;
esac

if [ "$ONLY_PRINT" -eq 1 ]; then
  echo "$CURRENT"
  exit 0
fi

# 源码最后一次改动的时刻。Package.swift 也算——加依赖/改 target 同样是「改了代码」。
#
# 用 python 而不是 `find -exec stat`：这台机器上 `stat -f %m` 一旦接多个操作数，
# 会被当成「显示文件系统信息」，把 `%m` 当文件名报 `No such file or directory`。
# 这条坑实测踩过，别再写回去。
EVIDENCE="$(/usr/bin/python3 - <<'PY'
import os
newest = 0
for root, _dirs, files in os.walk("Sources"):
    for name in files:
        if name.endswith(".swift"):
            newest = max(newest, int(os.path.getmtime(os.path.join(root, name))))
if os.path.exists("Package.swift"):
    newest = max(newest, int(os.path.getmtime("Package.swift")))
print(newest)
PY
)"
case "$EVIDENCE" in
  ''|*[!0-9]*) echo "❌ 量不到源码修改时间" >&2; exit 1 ;;
esac
[ "$EVIDENCE" -gt 0 ] || { echo "❌ 量不到源码修改时间" >&2; exit 1; }

DATE_PART="$(date -r "$EVIDENCE" +%Y%m%d)"
TIME_PART="$(date -r "$EVIDENCE" +%H%M)"
NEW="$MAJOR_VALUE.$DATE_PART.$TIME_PART"
NEW_BUILD="$DATE_PART$TIME_PART"

# 比较：去掉点当整数比。版本号形如 2.20261021.1654 → 2202610211654，
# 远小于 2^63，bash 的整数比较够用，不必请 python 出场。
as_number() { echo "${1//./}" | sed 's/^0*//' ; }
cur_num="$(as_number "$CURRENT")"; cur_num="${cur_num:-0}"
new_num="$(as_number "$NEW")";     new_num="${new_num:-0}"

if [ "$new_num" -le "$cur_num" ]; then
  echo "版本号：${CURRENT}（源码没有比它更新的改动，保持不变）"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "版本号将会是：${NEW}（构建 ${NEW_BUILD}）"
  exit 0
fi

plutil -replace CFBundleShortVersionString -string "$NEW" "$PLIST"
plutil -replace CFBundleVersion -string "$NEW_BUILD" "$PLIST"
plutil -lint "$PLIST" >/dev/null

echo "版本号：${NEW}（构建 ${NEW_BUILD}）"
echo "  原版本：${CURRENT}"
echo "  依据：源码最后修改时间 $(date -r "$EVIDENCE" '+%Y-%m-%d %H:%M')"
