#!/bin/bash
# 重新抓取 SenseVoice 推理运行时到 vendor/sensevoice-runtime/ 并校验。
#
# 为什么需要这个脚本（而不是每次现下）：GitHub release 直连在国内会被掐，
# 而这份二进制只有 3 MiB。抓一次留下来，之后 `mr model install-runtime` 就
# 完全不需要网络。见 vendor/sensevoice-runtime/README.md。
#
# 用法：
#   ./scripts/fetch-sensevoice-runtime.sh              # 默认走 127.0.0.1:7897 代理
#   ./scripts/fetch-sensevoice-runtime.sh --no-proxy   # 直连
#   PROXY=http://127.0.0.1:1087 ./scripts/fetch-sensevoice-runtime.sh

set -euo pipefail

RELEASE="runtime-llamacpp-v0.2.6"
ASSET="funasr-llamacpp-macos-arm64.tar.gz"
MEMBER="llama-funasr-sensevoice"
EXPECTED_SHA="becaa30d66bcaa727c132ef0e8c7248410bbf2cc4f0a2fe8f375cf885b9903c3"
EXPECTED_BYTES=3008104

PROXY="${PROXY:-http://127.0.0.1:7897}"
USE_PROXY=1
for arg in "$@"; do
  case "$arg" in
    --no-proxy) USE_PROXY=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$ROOT/vendor/sensevoice-runtime"
URL="https://github.com/modelscope/FunASR/releases/download/$RELEASE/$ASSET"

mkdir -p "$DEST_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CURL=(curl -fL --retry 3 --retry-delay 2 --connect-timeout 20)
if [ "$USE_PROXY" = 1 ]; then
  CURL+=(-x "$PROXY")
  echo "使用代理：$PROXY"
else
  echo "直连（不使用代理）"
fi

echo "下载 $URL"
if ! "${CURL[@]}" -o "$WORK/$ASSET" "$URL"; then
  echo "下载失败。GitHub release 直连常见被掐 —— 试试挂代理，或从浏览器手动下载后放到 $DEST_DIR/$MEMBER。" >&2
  exit 1
fi

echo "解包成员 $MEMBER"
tar -xzf "$WORK/$ASSET" -C "$WORK" "$MEMBER"

echo "校验"
ACTUAL_BYTES=$(stat -f '%z' "$WORK/$MEMBER")
if [ "$ACTUAL_BYTES" != "$EXPECTED_BYTES" ]; then
  echo "字节数不符：期望 $EXPECTED_BYTES，实际 $ACTUAL_BYTES" >&2
  echo "如果上游发布了新版本，请同步更新本脚本与 SenseVoiceAsset.runtime。" >&2
  exit 1
fi
ACTUAL_SHA=$(shasum -a 256 "$WORK/$MEMBER" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "sha256 不符：期望 $EXPECTED_SHA，实际 $ACTUAL_SHA" >&2
  exit 1
fi

install -m 755 "$WORK/$MEMBER" "$DEST_DIR/$MEMBER"
echo "✅ 已更新 $DEST_DIR/$MEMBER"
echo "   sha256 $ACTUAL_SHA"
