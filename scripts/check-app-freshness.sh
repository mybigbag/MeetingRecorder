#!/bin/bash
# 检查 .app 里的二进制有没有落后于源码。
#
# **为什么需要这个脚本**：GUI 应用有一条容易被忘掉的交付链路——
#   源码 → swift build → **打包成 .app** → 用户启动
# `swift test` 跑的是 `.build/` 里的 debug 产物，跟
# `MeetingRecorder.app/Contents/MacOS/` 里的 release 二进制**完全是两个文件**。
# 于是「改了代码、测试全绿」之后忘了打包，用户启动的还是旧包，
# 表现为「功能没做」——2026-10-10踩过一次（暂停按钮看不到）。
#
# 本脚本按**内容**判定而不是只看时间戳：新代码里出现过的字符串，
# 二进制里就该找得到。
#
# 用法：
#   Scripts/check-app-freshness.sh              # 检查后提示
#   Scripts/check-app-freshness.sh --strict     # 落后时退出码 1（适合挂 CI）

set -uo pipefail
cd "$(dirname "$0")/.."

APP_BIN="MeetingRecorder.app/Contents/MacOS/MeetingRecorder"
STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

if [[ ! -f "$APP_BIN" ]]; then
  echo "❌ 找不到 $APP_BIN —— 尚未打包。先跑 Scripts/build-app.sh"
  exit 1
fi

echo "=== .app 二进制 ==="
stat -f "  修改时间 %Sm  大小 %z bytes" -t "%m-%d %H:%M:%S" "$APP_BIN"
echo "=== 源码最新修改时间 ==="
# 注意：这里不能用 `find -exec stat -f "格式" {} \;` ——
# 实测 macOS 的 find 会把格式串里的 %m / %N 也当成路径传给 stat，
# 于是每个文件都报一次 "No such file or directory"，最后静默取到空值。
# 改成 find 只吐路径、循环里单独 stat。
NEWEST_TS=0
NEWEST_FILE=""
while IFS= read -r f; do
  ts=$(stat -f "%m" "$f" 2>/dev/null) || continue
  if (( ts > NEWEST_TS )); then
    NEWEST_TS=$ts
    NEWEST_FILE=$f
  fi
done < <(find Sources -name "*.swift" -type f)
echo "  $(date -r "$NEWEST_TS" '+%m-%d %H:%M:%S')  $NEWEST_FILE"

STALE=0
BIN_TS=$(stat -f "%m" "$APP_BIN")
if (( NEWEST_TS > BIN_TS )); then
  echo ""
  echo "⚠️  源码比 .app 新 —— **.app 里没有这些改动**"
  echo "    测试跑在 .build/ 的 debug 产物上，验不到用户实际启动的那个包。"
  echo "    修法：./Scripts/build-app.sh"
  STALE=1
fi

# 时间戳会被 touch / 还原等操作搞乱，所以再做一次内容校验。
# 注意：这里必须用 Python 读字节，**不能用 strings** ——
# 实测 strings 对 Swift 的 UTF-8 字符串段读不出来，会给出
# 「一个都没有」的假阴性，害人去查根本不存在的问题。
echo ""
echo "=== 内容校验（.app 二进制里找新代码的标记字符串）==="
MARKERS=(
  "两轨同时播放|播放按钮第三态文案"
  "停止并回到开头|独立停止按钮"
)
CHECK_MARKS=("两轨同时播放" "停止并回到开头")
FOUND_ALL=1
for m in "${CHECK_MARKS[@]}"; do
  n=$(python3 -c "
import sys
data = open('$APP_BIN','rb').read()
print(data.count('$m'.encode('utf-8')))
")
  if (( n > 0 )); then
    echo "  ✅ '$m' → $n 处"
  else
    echo "  ❌ '$m' → 0 处  ← 二进制里没有这段代码，.app 是旧包"
    FOUND_ALL=0
    STALE=1
  fi
done

echo ""
if (( STALE )); then
  echo "结论：❌ .app 落后于源码，用户启动的是旧版本。"
  echo "      跑 ./Scripts/build-app.sh 后重试。"
  (( STRICT )) && exit 1
  exit 1
else
  echo "结论：✅ .app 与源码一致。"
  exit 0
fi