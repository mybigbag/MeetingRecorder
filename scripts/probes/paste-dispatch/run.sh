#!/bin/bash
# 跑粘贴派发探针（详见 main.swift 顶部说明）。
#
# 它跑真 NSApplication.run()、真键盘事件派发（NSApp.sendEvent），
# 并带一个**阴性对照**：故意不给「编辑」菜单时 ⌘V 应当进不去，
# 给了才进得去。
# 不需要辅助功能权限，也不点任何按钮、不改真实偏好。
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
  -o /tmp/mr-paste-dispatch-probe \
  "$here/main.swift" \
  "$products"/MRGUI.o \
  "$products"/MRSession.o \
  "$products"/MRMinutes.o \
  "$products"/MRCore.o \
  "$products"/MRCapture.o \
  "$products"/MRTranscribe.o

# 探针的退出码规则：**「现象符合该模式吗」**。
# 阴性模式（without-edit）下「粘不进去」才是对的，所以它退出 1。
# 因此这里不能用「退出 0 = 通过」来判——那会把正确的阴性说成对照失效。
echo "=== 阴性对照（主菜单没有编辑菜单，期望进不去）==="
# **判据是探针的结论行，不是退出码。**
# 实测：在真 `NSApplication.run()` 里 `exit(n)` 拿回来的永远是 0，
# 所以退出码在这里没有信息量（见 main.swift 里的说明）。
set +e
/tmp/mr-paste-dispatch-probe without-edit 2>&1 | tee /tmp/mr-paste-negative.log
set -e
if grep -q "内容进去了" /tmp/mr-paste-negative.log; then
  echo "❌ 对照失效：没有编辑菜单居然也粘进去了——这个探针测不出失败。"
  exit 1
fi
if ! grep -q "内容没进去" /tmp/mr-paste-negative.log; then
  if grep -q "测不出结论" /tmp/mr-paste-negative.log; then
    # **环境不成立 ≠ 对照失效。** 前者说的是「这台机器上这一刻测不了」，
    # 后者说的是「这个探针根本测不出失败」。混为一谈会让人以为还有别的 bug。
    echo
    echo "⚠️  本次未得出结论（这不是 bug，是这台机器这一刻测不了）。"
    echo "   原因：⌘V 的派发链路需要探针自己的窗口成为 key window，"
    echo "   而「成为前台应用」这一步在自动化会话里不稳定——"
    echo "   本进程没有辅助功能权限，无法确认前台状态，也无法强行置前。"
    echo
    echo "   要在本机复现：在**你自己的终端**里跑（前台由你控制）："
    echo "     cd \$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    echo "     bash scripts/probes/paste-dispatch/run.sh"
    echo
    echo "   已验证结论（2026-10-19，本机跑通过一次带对照的完整流程）："
    echo "     无编辑菜单 → ⌘V 进不去；装上生产那份 → 剪贴板内容真的进了输入框。"
    exit 2
  fi
  echo "❌ 探针既没给结论也没报错——脚本与探针的约定不一致。"
  exit 1
fi
echo "   → 对照成立（正如预期：⌘V 无处派发，内容没进去）。"

echo
echo "=== 阳性（生产代码的编辑菜单，期望进得去）==="
/tmp/mr-paste-dispatch-probe with-edit 2>&1 | tee /tmp/mr-paste-positive.log
if ! grep -q "内容进去了" /tmp/mr-paste-positive.log; then
  echo "❌ 菜单装上了，⌘V 仍然进不去——派发链路上还有别的问题。"
  exit 1
fi

echo
echo "✅ ⌘V 派发链路通：菜单匹配 → 响应链 → 写入输入框。"
echo "   主窗口的重命名框与设置窗口的密钥框共用同一个 NSApp.mainMenu，同样受益。"