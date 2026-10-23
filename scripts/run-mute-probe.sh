#!/bin/zsh
# 编译并运行「分轨静音」真机探针。
#
# ## 为什么必须放进 .app 才能跑
#
# 系统音频 Process Tap 要求发起进程**有 bundle 身份**：TCC 的
# 「屏幕与系统音频录制」授权是按 bundle id 记录的，`xctest` 没有 bundle，
# 探针会静默停在权限弹窗（实测真机用例卡了 7 分钟无输出）。
# 所以这里把探针编成 `.app` 里的可执行文件，复用 `com.pxing.mr` 已有的授权。
#
# 用法：
#   ./scripts/run-mute-probe.sh
#
# 前置条件：
#   - MeetingRecorder.app 已用你的开发证书签名
#   - 已授予「麦克风」与「屏幕与系统音频录制」权限
#   - 运行时不要有别的会议在录（会争抢音频设备）

set -e
cd "$(dirname "$0")/.."

PROBE_SRC="scripts/probes/per-track-mute/main.swift"
APP="MeetingRecorder.app"
BUNDLE_ID="com.pxing.mr"
SIGN_IDENTITY="${MR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development.*\)".*/\1/p' | head -1)}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "找不到可用的 Apple Development 签名身份。" >&2
  echo "可用 MR_SIGN_IDENTITY='Apple Development: xxx (yyy)' 覆盖。" >&2
  exit 1
fi

echo "==> 编译库（debug，带 @testable）"
swift build --disable-sandbox 2>&1 | tail -3

echo "==> 编译探针"
OUT_DIR="$(mktemp -d)"
swiftc -O -I .build/debug -o "$OUT_DIR/mute-probe" "$PROBE_SRC" \
  .build/debug/MRCore.o .build/debug/MRCapture.o .build/debug/MRSession.o \
  .build/debug/MRTranscribe.o .build/debug/MRMinutes.o

echo "==> 装进 $APP（复用 bundle 身份 $BUNDLE_ID 才能过 TCC）"
# 备份原可执行文件，探针跑完再换回去
BACKUP="$OUT_DIR/MeetingRecorder.real"
cp "$APP/Contents/MacOS/MeetingRecorder" "$BACKUP"
cp "$OUT_DIR/mute-probe" "$APP/Contents/MacOS/MeetingRecorder"

# 签名：改了可执行文件必须重签，否则 bundle 身份失效
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" 2>&1 | sed 's/^/    /'

echo "==> 运行探针"
ROOT="$(mktemp -d)"
set +e
MEETING_RECORDER_ROOT="$ROOT" "$APP/Contents/MacOS/MeetingRecorder"
STATUS=$?
set -e

echo "==> 还原真实可执行文件"
cp "$BACKUP" "$APP/Contents/MacOS/MeetingRecorder"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" 2>&1 | sed 's/^/    /'

if [[ $STATUS -eq 0 ]]; then
  echo "探针通过。录音留在：$ROOT"
else
  echo "探针失败（退出码 $STATUS）。录音留在：$ROOT" >&2
fi
exit $STATUS