#!/bin/bash
# 在项目目录跑 swift test，绕开「工作目录被上游重置」这个反复出现的问题。
#
# 另外固定加 --disable-sandbox：本机SwiftPM 的 sandbox_apply 会被拒
# （`sandbox-exec: Operation not permitted`），manifest 直接加载失败。
#
# 用法：./Scripts/t.sh                 # 全量
#      ./Scripts/t.sh --filter Foo    # 透传给 swift test

set -uo pipefail
# 项目根 = 本脚本所在目录的上一级。写死绝对路径会让脚本换台机器就失效。
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 1
exec swift test --disable-sandbox "$@"