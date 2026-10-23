#!/bin/bash
# 打包后自检：确认状态栏图标**真的**被系统登记了。
#
# 为什么需要这一步：2026-10-20 之前，打包成功 ≠ 状态栏图标会出现。
# 根因是「不经 LaunchServices 直接执行 .app 内二进制会永久毒化 bundle id」
# （详见 build-app.sh 顶部的完整实验记录）。中毒之后，**打包、启动、窗口
# 全都正常**，只有菜单栏上少一个图标——没有任何一步会报错。
#
# 所以「跑起来没崩」不能作为验收标准。这里量的是**系统登记**本身：
# 启动前后，按屏分组的菜单栏项数必须各 +1。
#
# 判据为什么不用窗口名字：`kCGWindowName` 在**内置屏**那条带上会退化成
# `Item-0`（第三方项全部如此，系统项如 WiFi/Clock 名字正常），此时
# 「按 bundle id 找」必然是**假阴性**——会把「已登记」误判成「没登记」。
# 项数是名字-independent 的可靠信号。
#
# 用法：./scripts/verify-status-item.sh [路径/to/MeetingRecorder.app]
# 退出码：0 = 通过；1 = 未通过（图标不会出现）；2 = 本机此刻测不了

set -uo pipefail

APP="${1:-$(cd "$(dirname "$0")/.." && pwd)/MeetingRecorder.app}"
PROBE="$(mktemp -t mr-menubar-probe).swift"
BIN="$(mktemp -t mr-menubar-probe)"
trap 'rm -f "$PROBE" "$BIN" 2>/dev/null || true' EXIT

if [ ! -d "$APP" ]; then
  echo "❌ 找不到 .app：$APP"
  exit 2
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null || echo "")
if [ -z "$BUNDLE_ID" ]; then
  echo "❌ 读不到 CFBundleIdentifier"
  exit 2
fi

# ── 探针：按屏分组统计 layer=25 的菜单栏项 ──────────────────────────
cat > "$PROBE" <<'SWIFT'
import CoreGraphics
import Foundation

let list = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

var ids = [CGDirectDisplayID]()
var count: UInt32 = 0
CGGetActiveDisplayList(0, nil, &count)
if count > 0 {
    ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
}

var out: [String] = []
for id in ids {
    let b = CGDisplayBounds(id)
    var n = 0
    for w in list {
        guard let wb = w[kCGWindowBounds as String] as? [String: Any],
              let r = CGRect(dictionaryRepresentation: wb as CFDictionary) else { continue }
        guard (w[kCGWindowLayer as String] as? Int) == 25 else { continue }
        guard abs(Int(r.minY) - Int(b.origin.y)) <= 2 else { continue }
        guard r.minX >= b.minX - 2, r.maxX <= b.maxX + 2 else { continue }
        n += 1
    }
    out.append("\(n)")
}
print(out.joined(separator: ","))
SWIFT

if ! /usr/bin/swiftc -O "$PROBE" -o "$BIN" 2>/dev/null; then
  echo "❌ 探针编译失败"
  exit 2
fi

count_bars() { "$BIN" 2>/dev/null || echo ""; }

echo "=== 状态栏登记自检 ==="
echo "bundle id: $BUNDLE_ID"
echo

# 先把已经在跑的同 id 实例退掉，否则量到的基线里就有它
pkill -f "$APP/Contents/MacOS/" 2>/dev/null || true
sleep 2

BEFORE=$(count_bars)
if [ -z "$BEFORE" ]; then
  echo "❌ 探针取不到菜单栏项数（本机此刻测不了）"
  exit 2
fi
echo "启动前（每块屏的项数）: $BEFORE"

# ── 关键：必须由 LaunchServices 启动 ──────────────────────────────
# 直接执行 .app 内二进制会毒化 bundle id（不可逆），
# 所以这里用 `open -a`，绝不直接跑二进制。
open -a "$APP"
sleep 4

AFTER=$(count_bars)
echo "启动后（每块屏的项数）: $AFTER"

if [ -z "$AFTER" ]; then
  echo "❌ 探针取不到菜单栏项数（本机此刻测不了）"
  exit 2
fi

# 逐屏比较：每一块屏都必须 +1
# 用数组而不是 sed 逐行取——`sed -n "Np"` 在行数不足时会返回空，
# 后面那句 `[ -z "$a" ] && a=0` 会把「取不到」误当成「0 项」。
BEFORE_ARR=($(echo "$BEFORE" | tr ',' ' '))
AFTER_ARR=($(echo "$AFTER" | tr ',' ' '))
# 逐屏比较：**有菜单栏的那几块屏**都必须 +1。
#
# ⚠️ 不能要求「每块屏都 +1」：一块屏的菜单栏项数基线是 0，说明它**现在没有菜单栏**
# （镜像显示、显示器睡眠、或「显示器各自有独立空间」关掉时，副屏本来就没有菜单栏）。
# 2026-10-22 就是这样：外接屏 0 → 0 被判成「图标没登记」，而内置屏 10 → 11 明明成功了。
# 判据要能区分「没登记」和「这块屏没有菜单栏可登记」——前者基线一定不是 0
# （有菜单栏就至少有系统项），后者基线恒为 0。
OK=1
MEASURED=0
for i in "${!BEFORE_ARR[@]}"; do
  b=${BEFORE_ARR[$i]}
  a=${AFTER_ARR[$i]:-0}
  DELTA=$((a - b))
  SCREEN=$((i + 1))
  if [ "$b" -eq 0 ]; then
    echo "  ⏭  第 ${SCREEN} 块屏：${b} → ${a} ——这一块屏没有菜单栏，不参与判定"
    continue
  fi
  MEASURED=$((MEASURED + 1))
  if [ "$DELTA" -ge 1 ]; then
    echo "  ✅ 第 ${SCREEN} 块屏：${b} → ${a}（+${DELTA}）"
  else
    echo "  ❌ 第 ${SCREEN} 块屏：${b} → ${a}（+${DELTA}）——系统没有登记这个状态栏项"
    OK=0
  fi
done
echo
if [ "$MEASURED" -eq 0 ]; then
  echo "❌ 一块带菜单栏的屏都没量到（本机此刻测不了）——这里不给结论。"
  exit 2
fi
if [ "$OK" -eq 1 ]; then
  echo "✅ 通过：状态栏项已被系统登记，${MEASURED} 块有菜单栏的屏上都有一份。"
  exit 0
fi
echo "❌ 未通过：菜单栏上不会出现本应用的图标。"
echo
echo "最可能的原因：这个 bundle id 曾经被**直接执行** .app 内的二进制启动过——"
echo "那会把它永久列入系统的拒绝名单，清不掉，只能换一个没用过的 bundle id。"
echo "本项目的代码已经处理了这条路径（直接执行会自动交给 LaunchServices），"
echo "但手工绕过它仍会中毒。"
exit 1
