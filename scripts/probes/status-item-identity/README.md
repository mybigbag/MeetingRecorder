# 状态栏图标「明明建了，屏幕上却没有」

> **2026-10-20 全面复核：本文件先前的大部分结论已被推翻。**
> 下文按「仍然成立 / 已被推翻」分开写，**别把已被推翻的部分当依据**。

跑 GUI 冒烟时发现的：双击打开应用，主窗口正常，**菜单栏上却没有图标**。
关掉窗口之后就没有任何入口了——正好把「关窗不退出、状态栏留个小工具」这个需求掏空。

**现在的结论（2026-10-20 定案）：不是代码没建图标，也不�� bundle id 本身有问题，
而是「启动方式」决定了系统登不登记这个项——而直接执行 .app 内的二进制还会
把这个 bundle id 永久毒化。**

---

## 一、当前结论：根因是启动方式（已被受控对照实验锁定）

### 判据先说清楚：**不能用窗口名字**

`kCGWindowName` 在**内置屏**那条菜单栏上会退化成 `Item-0`
（第三方项全部如此，系统项如 WiFi / Clock 名字正常）。
此时「按 bundle id grep」必然是**假阴性**——会把「已登记」误判成「没登记」。

> 这不是小事：本文档上一版就是靠 grep 名字下的结论，结果把「已登记」看成了
> 「没登记」，连带把整件事归因到了错误的方向。

可靠判据是**按屏分组的菜单栏项数**（名字无关）：

```bash
# 统计每块屏的菜单栏项数与宽度签名
# 内置屏 origin.y=0（菜单栏高 39pt），外接屏 origin.y=-1152（菜单栏高 30pt）
```

### 实验矩阵（macOS 26.6.2，双屏）

| 操作 | 内置屏 | 外接屏 |
|---|---|---|
| 基线 | 10 | 10 |
| 全新 bundle id + `open -a` | **11** | **11** |
| 退出 | 10 | 10 |
| **直接执行 `.app/Contents/MacOS/<二进制>`（GUI 模式）** | 10 | 10 |
| 退出后改用 `open -a`（同一个 id） | 10 | 10 | ← **永久毒化** |
| CLI 模式直接执行（`doctor` / `config show`） | 11 | 11 | ← CLI **不**毒化 |

两条关键推论：

1. **状态栏项在每一块屏的菜单栏上各有一份，始终同步。**
   启动时两块屏同时 +1、退出时同时 -1，宽度签名完全一致。
   「状态栏图标只在一块屏上」这个症状**不存在**。
2. **直接执行 GUI 一次，就把这个 bundle id 永久毒化。**
   之后 `open -a` 也登不上。记录按 bundle id 存，换路径、`lsregister -u` + `-f`、
   `defaults delete`、重启 ControlCenter 全都清不掉。
   唯一有效的解法是换一个没用过的 bundle id。

### 进程内可分辨的三种状态

用一份 20 行的最小 AppKit 探针（同一真实证书签名）量到的：

| 状态 | `__CFBundleIdentifier` | 按钮窗口 frame | 高度 | 登记数 |
|---|---|---|---|---|
| A 正常（`open -a`） | == 自己 bundle id | `(1116, 1073, 32, 39)` | **39** | 11 ✅ |
| B 直接执行 | == **父进程** bundle id | `(1678, 1090, 32, 22)` | 22 | 10 ❌ |
| C 被毒化后 `open -a` | == 自己 bundle id | `(0, -22, 32, 22)` | 22 | 10 ❌ |

三种状态下 `NSStatusItem.isVisible` **全都读回 `true`**。

**判据找到了：按钮窗口的高度。** 系统真登记了才会把它拉到菜单栏那么高
（内置屏 39pt、外接屏 30pt）；没登记时它保持 AppKit 默认的 22pt。
这个判据不依赖名字、不依赖外部进程，现在用在
`StatusItemController.isPlaced(buttonFrame:menuBarHeight:)`。

### `__CFBundleIdentifier` 是怎么判「是否被 LaunchServices 启动」的

- 由 LaunchServices 启动时，它等于**进程自己的** bundle id；
- 直接执行时，它等于**父进程**的 bundle id（实测父进程是 WorkBuddy 时为
  `com.tencent.workbuddy.mac`）。

这是唯一不碰 AppKit 就能判定的信号——`NSRunningApplication` 那条路太晚：
`applicationDidFinishLaunching` 时它已经返回 `true` 了，拦不住毒化。

---

## 二、已被推翻的旧结论（**不要再照着做**）

| 旧结论 | 状态 | 实测反驳 |
|---|---|---|
| 根因是 `ui-element` 标记 | ❌ 推翻 | `lsregister -f` 能清掉 flags，但登记仍失败；`LSUIElement=true` 也照样能登记 |
| 根因是 ad-hoc 签名 / cdhash 变化 | ❌ 推翻 | 同一份 ad-hoc 签名的 app 能正常登记；真实证书签名的也会失败 |
| 根因是 bundle id 本身 | ❌ 推翻 | 同一个 id 只要经 LaunchServices 启动就正常；换 id 只是绕过了毒化记录 |
| 根因是「菜单栏放不下」 | ❌ 推翻 | 那块屏的菜单栏还有空位，系统是**根本没登记** |
| 「状态栏项跟随 key window 所在屏」 | ❌ 推翻 | 每块屏各有一份，始终同步（见上） |
| 「图标被排到另一块屏 → 搬窗口过去」 | ❌ 推翻 | 跨屏状态不存在；那个动作会**擅自搬走用户自己的窗口** |
| 几何判据（`maxY` 落在上沿 60pt 内）可靠 | ❌ 推翻 | 系统没登记时按钮窗口 frame 可能是 `(1826, 2242, 32, 22)`，几何算出来是 `true`，而屏幕上没有图标 |

**几何判据的假阳性**是这轮最隐蔽的一个：它「看起来」很合理（有实测值支撑），
但与真实登记状态**完全脱钩**。

---

## 三、代码这边做了什么

### 1. LaunchServices 交接（根治）

`Sources/MRGUI/LaunchServicesHandoff.swift` +
`Sources/MeetingRecorderMain/main.swift`。

在**碰 AppKit 之前**用 `__CFBundleIdentifier` 判启动方式：
不是 LaunchServices 启动就 `open -a` 交接出去，然后立刻退出。

- 交接成功 → 退出，让 LaunchServices 拉起的那个进程去建状态栏项。
- 交接失败 → **明确报错并退出**，绝不能继续跑 GUI
  （继续跑就等于亲手毒化这个 bundle id，且不可逆）。

CLI 模式**不交接**：实测 CLI 直接执行不毒化，交接只会平白多起一个进程。
裸二进制（不在 `.app` 里）**不交接**：它没有 bundle id，无从毒化。

### 2. 判据换成「高度」

`StatusItemController.isPlaced(buttonFrame:menuBarHeight:)`。
菜单栏高度取所有屏的最大值（内置屏 39pt、外接屏 30pt，两块屏高度不同）。

### 3. 拆掉有害副作用

- 删掉 `alignWindowWithIconScreen` / `moveWindow`——它们会**擅自把用户的主窗口
  搬到另一块屏**，建立在「图标在别的屏上」这个已被证伪的前提上。
- `StatusIconScreenNotice` 改为只回答「系统有没有登记这个项」，
  并把原因说准（不是「菜单栏放不下」，是「系统没登记」）。
- `watchStatusItemPlacement()` 的告警文案同步修正。

### 4. 打包后自检

`scripts/verify-status-item.sh`：启动前后各量一次**按屏分组的项数**，
每块屏必须 +1 才算通过。

> 「跑起来没崩」**不能**作为验收标准——中毒之后打包、启动、窗口全都正常，
> 只有菜单栏上少一个图标，没有任何一步会报错。

退出码：0 = 通过；1 = 未通过；2 = 本机此刻测不了。

---

## 四、怎么重跑

```bash
# 打包 + 自检（最省事的一条）
./scripts/build-app.sh release
./scripts/verify-status-item.sh

# 只跑自检
./scripts/verify-status-item.sh /path/to/MeetingRecorder.app
```

### 手工复现「毒化」

```bash
# 1) 复制一份 .app，换一个没用过的 bundle id，重签
# 2) open -a 启动 → 用上面的项数探针量，应当两块屏都 +1
# 3) 退出，然后直接执行 .app 内的二进制 → 项数应当**不 +1**
# 4) 退出，再用 open -a 启动同一个 id → 项数**仍然不 +1**（毒化）
```

第 4 步是关键：它证明「不是没登记」，而是「**永久登不上**」。

---

## 五、代价与遗留

- **换过 bundle id**：从 `com.pxing.mr` → `com.pxing.recorder` → **`com.pxing.mrecorder`**。
  前两个都被毒化过（后者是 2026-10-20 的排查实验自己造成的）。
  TCC 的麦克风 / 系统音频录制 /「文稿」访问都按 bundle id 记账，
  换 id 后首次录音要把这三项重新允许一遍。
- **`menubars` 进程崩溃**：2026-10-20 14:58:36 有一次 `menubars`（macOS 26 的
  一方菜单栏管理进程）SIGTRAP 崩溃。**它不是本问题的根因**——但它会让
  **内置屏那层的 `kCGWindowName` 全部退化成 `Item-0`**，
  于是「按名字 grep」的判据彻底失效。这就是为什么本文件改用项数判据。
