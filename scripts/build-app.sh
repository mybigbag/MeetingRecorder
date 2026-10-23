#!/bin/bash
# 把可执行文件打包成 .app bundle。
#
# 为什么必须打包：macOS 26 上系统音频捕获（Core Audio Process Tap）的 TCC 权限
# 只授予带有效 Info.plist 的 .app bundle。裸 CLI 可执行文件**拿不到权限**，
# 而且失败是静默的——所有 API 返回 0、采样点数完全正确，但缓冲区全是零。
#
# 打包要点：
#   1. bundle ID 与路径保持稳定 —— 改了会让 TCC 把它当新 app，此前授权全部失效。
#      「文件与文件夹」权限同理，所以这个 .app 的位置也不要挪。
#   2. 原地替换二进制（不删整个 .app）—— 实测这样重建后授权不丢
#   3. 这里的二进制**同时是 CLI 与 GUI**：带参数走命令行，双击弹窗口
#
# ⚠️ 关于「状态栏图标不显示」——2026-10-20 定案，**不要按旧说法处理**
#
# 旧注释里写的「不要用 `.accessory` 激活策略」「ad-hoc 每次重建哈希都变
# 会触发被系统拒绝放置」**都已被实测证伪**：
#   - `LSUIElement` / 激活策略 `.accessory` 与登记**无关**（`LSUIElement=true`
#     也照样能登记；`lsregister -f` 清掉 flags 也不改变结果）。
#   - ad-hoc 签名**也不是**触发条件（同一份 ad-hoc 签名的 app 能正常登记）。
#
# 真正的根因是**启动方式**（2026-10-20 用受控对照实验定案）：
# macOS 26 上，第三方 `NSStatusBar` 项**只有由 LaunchServices 启动时**
# （访达双击 / `open -a`）才会被系统登记。而**直接执行
# `.app/Contents/MacOS/<二进制>` 启动 GUI** 不但不会登记，还会把这个
# bundle id **永久毒化**——之后再用 `open -a` 启动同一个 id 也永远登不上。
# 记录按 bundle id 存，`defaults delete` / `lsregister -u` + `-f` / 换路径 /
# 重启 ControlCenter 全试过，都清不掉。唯一有效的解法是换一个没用过的 id。
#
# 证据（判据是**按屏分组的菜单栏项数**，不能用名字 grep——内置屏那层的
# `kCGWindowName` 会退化成 `Item-0`，那样是假阴性）：
#
#   | 操作                                | 内置屏 | 外接屏 |
#   |-------------------------------------|--------|--------|
#   | 基线                                 | 10     | 10     |
#   | 全新 id + `open -a`                 | **11** | **11** |
#   | 退出                                  | 10     | 10     |
#   | 直接执行 .app 内二进制（GUI 模式）    | 10     | 10     |
#   | 退出后改用 `open -a`（同一个 id）      | 10     | 10     | ← 永久毒化
#
# 对策已落地在代码里：`Sources/MeetingRecorderMain/main.swift` 在碰 AppKit
# **之前**用 `__CFBundleIdentifier` 判启动方式，不是 LaunchServices 启动就
# `open -a` 交接出去（实现见 `Sources/MRGUI/LaunchServicesHandoff.swift`）。
# 所以**直接执行这条命令是安全的**，但手工绕过它仍然会毒化 bundle id。
#
# 复现步骤与排除清单：scripts/probes/status-item-identity/README.md
#
# 签名：
#   **不再默认 ad-hoc。** 没传 DEVELOPER_ID 时，脚本会自动挑本机钥匙串里可用的
#   真实身份（Apple Development / Developer ID Application）来签。原因见下：
#
#   ad-hoc 签名每次重建哈希都变，而 macOS 会按 bundle id 缓存对状态栏项的
#   「拒绝放置」记录（见上方第 13-22 行警告与 README「状态栏图标曾因 bundle id
#   被系统拒绝放置」）。哈希一变，同一个 id 可能被系统重新拒绝放置，表现就是
#   「双击打开窗口正常、菜单栏没图标」，且这条记录清不掉、只能换 id。
#   2026-09-29 这轮就是 `com.pxing.meetingrecorder` 在 ad-hoc 多轮重签后复发，
#   最终把 id 换成 `com.pxing.mr` 并用稳定证书签名才恢复。所以默认走真实身份，
#   身份不变就不再触发。
#
#   要分发给别人时传 DEVELOPER_ID，会切到开发者签名（并可选公证）：
#
#     DEVELOPER_ID="Developer ID Application: 你的名字 (TEAMID)" \
#       NOTARY_PROFILE=AC_NOTARY ./scripts/build-app.sh
#
#   NOTARY_PROFILE 是 `xcrun notarytool store-credentials` 存好的钥匙串条目名。
#   不传就只签名不公证——**别人打开会被 Gatekeeper 拦**（无法验证开发者）。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
CONFIG="${1:-release}"
APP="$ROOT/MeetingRecorder.app"

# 额外传给 swift build 的参数。默认留空，保持 swiftpm 自带的沙箱保护。
#
# 本机实测 swiftpm 嵌套调用自己的 sandbox-exec 会被系统拒绝
# （`sandbox-exec: sandbox_apply: Operation not permitted`），编译会失败在解析 manifest
# 那一步。以前需要手动 `SWIFT_FLAGS=--disable-sandbox ./scripts/build-app.sh`，
# 但这台机器上**每次**都失败，让人记环境变量没有意义——所以下面做成了自动降级：
# 先用带沙箱的默认方式编译，失败且未显式指定时才改用 --disable-sandbox 重试一次。
# 显式指定 SWIFT_FLAGS 时不做任何自动动作，出错就原样退出。
SWIFT_FLAGS="${SWIFT_FLAGS:-}"

echo "=== 0/5 版本号 ==="
# 版本号由源码最后一次修改时间推出（规则见 scripts/bump-version.sh 顶部）。
# 放在编译**之前**：这样包里的 Info.plist 与源码状态是同一份事实，
# 而不是「编译了新代码、印了旧版本」。
# 想打一个「不动版本号」的包（纯排查用）时：NO_VERSION_BUMP=1 ./scripts/build-app.sh
if [ "${NO_VERSION_BUMP:-0}" = "1" ]; then
  echo "  ⚠️ NO_VERSION_BUMP=1，跳过版本号更新；当前 $(./scripts/bump-version.sh --print)"
else
  ./scripts/bump-version.sh 2>&1 | sed 's/^/  /'
fi

echo "=== 1/5 编译（${CONFIG}）==="
# 本机（macOS 26 + 新版 SwiftPM）会拒绝 swiftpm 自己起的嵌套沙箱，第一次必然报
# "Invalid manifest" 那一整段——那是**环境**问题不是代码问题，紧接着降级重试就好。
# 所以把第一次的 stderr 收进文件：降级成功就整个不提，降级也失败才拿出来当证据。
FIRST_ERR="$(mktemp -t mr-build-err)"
# shellcheck disable=SC2086  # 这里就是要按空格拆成多个参数
if ! swift build -c "${CONFIG}" ${SWIFT_FLAGS} 2>"$FIRST_ERR"; then
  if [ -z "$SWIFT_FLAGS" ]; then
    echo "  · 首次编译未通过，改用 --disable-sandbox 重试（本机拒绝嵌套沙箱）"
    SWIFT_FLAGS="--disable-sandbox"
    # shellcheck disable=SC2086
    if swift build -c "${CONFIG}" ${SWIFT_FLAGS}; then
      echo "  ✅ 重试成功"
    else
      echo "❌ 编译失败——这次是真的编译错误。首次尝试的记录："
      cat "$FIRST_ERR"
      rm -f "$FIRST_ERR" || true
      exit 1
    fi
  else
    echo "❌ 编译失败（已指定 SWIFT_FLAGS=${SWIFT_FLAGS}，不再自动重试）："
    cat "$FIRST_ERR"
    rm -f "$FIRST_ERR" || true
    exit 1
  fi
fi
# `|| true` 不是装饰：`set -e` 下，一句**清理**失败会让整个脚本在**编译已经成功之后**
# 以非 0 退出，而调用方看到的是「打包失败」——实际上 .app 一个字节都没换。
# 实测过一次：`/var/folders` 下的临时文件在某些沙箱/权限设置下删不掉（Operation not
# permitted），于是编译通过、打包中断，最坏的结果是「以为装的是新版本、其实跑的是旧的」。
rm -f "$FIRST_ERR" || true
# shellcheck disable=SC2086
BIN="$(swift build -c "${CONFIG}" ${SWIFT_FLAGS} --show-bin-path)/meeting-recorder"
[ -f "$BIN" ] || { echo "❌ 找不到可执行文件：$BIN"; exit 1; }

echo "=== 2/5 组装 bundle ==="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# 原地替换二进制，保持 bundle 身份不变
rm -f "$APP/Contents/MacOS/MeetingRecorder"
cp "$BIN" "$APP/Contents/MacOS/MeetingRecorder"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/MeetingRecorder"

# 内嵌 SenseVoice 推理运行时（2.9 MiB，即 3,008,104 字节）。
#
# 为什么值得占这 2.9 MiB：`SenseVoicePaths.resolveRuntimeBinary` 的第三条就是
# `Contents/Resources/sensevoice/`，有了它，**装好包的人不必联网**就能启用
# SenseVoice——剩下的只有 244 MiB 权重必须下载。而运行时原来那条下载路径走的是
# GitHub release，国内经常不通；为了 3 MiB 卡住整个功能是不划算的。
# 权重**不内嵌**：那会把 .app 撑成 250 MB，且塞进版本库不合适。
echo "=== 2.5/5 内嵌 SenseVoice 运行时 ==="
VENDOR_RUNTIME="$ROOT/vendor/sensevoice-runtime/llama-funasr-sensevoice"
if [ -f "$VENDOR_RUNTIME" ]; then
  mkdir -p "$APP/Contents/Resources/sensevoice"
  cp "$VENDOR_RUNTIME" "$APP/Contents/Resources/sensevoice/llama-funasr-sensevoice"
  chmod +x "$APP/Contents/Resources/sensevoice/llama-funasr-sensevoice"
  echo "  ✅ llama-funasr-sensevoice（$(du -h "$VENDOR_RUNTIME" | cut -f1)）"
else
  echo "  ⚠️  仓库里没有 vendor/sensevoice-runtime/llama-funasr-sensevoice"
  echo "      打包出来的 .app 需要联网执行一次 install-runtime。生成命令："
  echo "      ./scripts/fetch-sensevoice-runtime.sh"
fi

echo "=== 3/5 图标 ==="
if [ -f "$ROOT/app/AppIcon.icns" ]; then
  cp "$ROOT/app/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  echo "  ✅ AppIcon.icns"
else
  echo "  ⚠️  缺少 app/AppIcon.icns，图标会是空白。生成命令："
  echo "      /usr/bin/python3 scripts/make-icon.py"
fi

echo "=== 4/5 校验 Info.plist ==="
plutil -lint "$APP/Contents/Info.plist"
for key in NSMicrophoneUsageDescription NSAudioCaptureUsageDescription CFBundleIdentifier; do
  plutil -p "$APP/Contents/Info.plist" | grep -q "$key" \
    && echo "  ✅ $key" \
    || { echo "  ❌ 缺少 $key"; exit 1; }
done
# 版本号：包里印的必须和 `app/Info.plist` 一致。
# 不一致只有一种可能——打包用的是旧的 plist，那「版本号」就在撒谎，
# 而用户正是拿它判断「我装的是不是最新的」。
PLIST_VERSION="$(./scripts/bump-version.sh --print)"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
if [ "$PLIST_VERSION" != "$APP_VERSION" ]; then
  echo "  ❌ 版本号不一致：源码清单 ${PLIST_VERSION}，包内 ${APP_VERSION:-（缺失）}"
  exit 1
fi
echo "  ✅ 版本号 ${APP_VERSION}"
# 有窗口的应用不能是 UIElement——那样双击之后什么都不会出现
if plutil -p "$APP/Contents/Info.plist" | grep -q "LSUIElement"; then
  echo "  ❌ Info.plist 里有 LSUIElement，双击不会有窗口"
  exit 1
fi

echo "=== 5/5 签名 ==="
SIGN_IDENTITY="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# 没显式给 DEVELOPER_ID 时，自动挑一个本机可用的真实签名身份。
# 为什么不能默认 ad-hoc：ad-hoc 签名每次重建哈希都变，而 macOS 会按 bundle id
# 缓存对状态栏项的「拒绝放置」记录（见顶部警告与 README「状态栏图标曾因 bundle id
# 被系统拒绝放置」）。哈希一变，同一 id 可能被系统重新拒绝放置，表现就是
# 「双击打开窗口正常、菜单栏没图标」，且这条记录清不掉、只能换 id。
# 用稳定身份签名 → 身份不变 → 不再触发。分发给别人仍走 DEVELOPER_ID + NOTARY_PROFILE。
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"(Apple Development|Developer ID Application)[^"]*"' | head -1 | tr -d '"')
  if [ -n "$SIGN_IDENTITY" ]; then
    echo "  未指定 DEVELOPER_ID，自动选用本机身份：$SIGN_IDENTITY"
  fi
fi

if [ -n "$SIGN_IDENTITY" ]; then
  echo "  使用身份：$SIGN_IDENTITY"
  # 内层可执行先签，再签 bundle。
  codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/MeetingRecorder"
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --verbose=2 "$APP" 2>&1 | tail -2

  if [ -n "$NOTARY_PROFILE" ]; then
    echo "  提交公证（keychain profile: $NOTARY_PROFILE）…"
    ZIP="$(mktemp -d)/MeetingRecorder.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    echo "  ✅ 已公证并装订（staple），别人可以直接打开"
  else
    echo "  （未公证，本机可正常用；分发请同时传 NOTARY_PROFILE=<钥匙串条目名>。）"
  fi
else
  echo "  ⚠️  本机没有任何可用签名身份，退回 ad-hoc。注意：ad-hoc 每次重建哈希都变，"
  echo "      可能触发『状态栏图标被系统按 bundle id 拒绝放置』（菜单栏没图标、清不掉、只能换 id）。"
  echo "      建议：在钥匙串里放一个『Apple Development』或『Developer ID Application』证书后再打包。"
  codesign --force --deep --sign - "$APP" 2>&1 | tail -2
  codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true
  echo "  （ad-hoc 签名，仅本机可用。分发请参考脚本开头的用法。）"
fi

echo
echo "✅ 打包完成：$APP"
echo "   版本号：$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "   （终端 ./mr version / 设置窗口右上角 / 菜单「关于会议录音器」都能查到）"
echo
echo "双击即可打开主窗口；命令行用法不变（同一个二进制）："
echo "  \"$APP/Contents/MacOS/MeetingRecorder\" doctor"
echo "  \"$APP/Contents/MacOS/MeetingRecorder\" record --title 测试 --seconds 10"
echo
echo "首次使用会请求三类权限：麦克风、系统音频录制、以及访问「文稿」文件夹。"
echo "三者都允许才能完整工作；拒绝「文稿」会导致列表看不到已有录音（不会丢数据）。"
