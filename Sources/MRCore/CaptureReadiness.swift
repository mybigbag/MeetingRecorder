import Foundation

/// 采集能力的就绪度判定。
///
/// **为什么需要这个类型**：`doctor` 曾经只检查到「tap 创建成功」就报全绿，
/// 而当时 coreaudiod 已经卡死、真实录制 100% 失败。原因是 tap 创建（读属性）
/// 走的是轻量路径，而真实采集要走 `AudioDeviceCreateIOProcIDWithBlock`——
/// 后者才是会卡死的那一步。**诊断工具撒谎比没有诊断工具更糟**，
/// 它会让人把故障环境当成好的，然后在更晚、代价更高的地方才暴露。
///
/// 所以判定刻意保守，且有两条底线：
/// 1. 没有真的跑通 IOProc 并收到 buffer，一律不许说 ready；
/// 2. 要能表达「半坏」——只剩一轨时对会议录音是降级而非可用，不能混进 ready。
///
/// 这一层是纯逻辑，不碰任何系统 API，因此可以完整单元测试——
/// 真正的系统调用由 MRCapture 执行后把结果填进 `Input`。
public enum CaptureReadiness {

    /// IOProc 探针的真实结果。由 MRCapture 层实际执行后填入。
    public enum Probe: Equatable {
        /// IOProc 建成、启动、在时限内收到 buffer，**且采样值非零**——唯一能证明可用的证据
        case warmed
        /// 收到 buffer 了，但采样值**全零**。
        ///
        /// 这是实测踩到的最阴的一种：链路全通、帧数完全正确、没有任何报错，
        /// 但内容空无一物。系统音频授权未生效时就是这个表现；
        /// 录制时系统确实没出声，也会是这个表现——两者从数据上无法区分。
        case silent
        /// 完全没有收到 buffer
        case noData
        /// HAL 调用在时限内未返回。coreaudiod 处于卡死状态的典型信号。
        case timedOut
        /// 没跑探针（tap 没建成，或形态不对，跑也没意义）
        case notAttempted
    }

    public enum Verdict: Equatable {
        /// 两轨都能采到数据，可以正常录会议
        case ready
        /// 一轨被证实可用，另一轨**无法用现有手段验证**，但也没有任何故障证据。
        ///
        /// 典型场景：输入与输出是同一台带回声消除的设备（耳机），提示音探测
        /// 对它从原理上不成立（见 `AudioDeviceIdentity`）。
        ///
        /// 与 `degraded` 的区别是本质性的：`degraded` 是「有一轨确定不好使」，
        /// 这里是「有一轨没法验证」。把后者报成前者，会把人推去做一堆无用的
        /// 权限排查——而实测那种设置下麦克风本来就是好的。
        case partiallyVerified
        /// 只有一轨能采——录得到一边、录不到另一边
        case degraded
        /// 链路通，但没有任何一轨被证实能出数据
        case unproven
        /// 明确故障，必须先修好
        case broken
    }

    public struct Input: Equatable {
        public var isAppBundle: Bool
        /// 系统音频 tap + 聚合设备是否创建成功
        public var tapCreated: Bool
        /// 系统音频轨的 IOProc 探针结果
        public var systemProbe: Probe
        /// 麦克风轨的 IOProc 探针结果
        public var micProbe: Probe
        /// 探测系统音频轨时，程序是否**自己播过一段测试音**。
        ///
        /// 这一位决定「采样全零」怎么解读，是整份判定里最关键的一个开关：
        /// - `false`：系统当时可能本来就没有音频输出，全零**说明不了任何问题**，只能算未证实；
        /// - `true` ：喂进去的测试音没被拾到，那就与「有没有声音」无关了——是确定的故障。
        ///
        /// 没有这一位时 doctor 会给出二义结论：实测系统安静时报「采集降级、只有麦克风可用」，
        /// 而同一份二进制在放声音时录得好好的。**把不确定当成确定，方向还是反的。**
        ///
        /// 只用于系统音频轨。麦克风轨的判据是「人有没有说话」，放提示音不能替代。
        public var probeTonePlayed: Bool
        /// 枚举音频设备（`AudioObjectGetPropertyData`）是否在时限内正常返回。
        ///
        /// 这一位只在 HAL 超时时用来分辨故障的**深度**：
        /// - `true` ：枚举照常返回设备，卡住的只是 `AudioDeviceCreateIOProcIDWithBlock`；
        /// - `false`：连枚举都回不来，是整个 HAL 层无响应。
        ///
        /// 实测见过两轨 IOProc 都超时、而设备枚举完全正常的「中间态」，
        /// 几分钟后就自行缓解了，并不需要重启音频服务。若不区分这两种深度，
        /// 就会把使用者推向一次本可避免的 `killall`（它会中断全机音频）。
        public var deviceEnumerationWorked: Bool
        /// 默认输入设备与默认输出设备是否**是同一台物理设备**。
        ///
        /// 这一位决定麦克风轨的探针结果能不能算数。共用一台设备（耳机等）时，
        /// 系统会对麦克风启用回声消除，把本机自己播放的提示音抹掉——实测把系统轨
        /// 0.296～0.638 的提示音压到麦克风轨只剩 0.0005～0.024，其中一次恰好全零。
        /// 于是 `micProbe` 会随机落在 `.warmed` 与 `.silent` 之间，
        /// **而两者都不代表麦克风能不能录到人声**（同一副 AirPods 录真人说话，
        /// 麦克风轨峰值 0.263，是提示音泄漏的 10 倍以上）。
        ///
        /// 判据只做「同一台物理设备」这一层，不去猜回声消除的实现细节：
        /// 共设备是机制，能被验证；「它到底压了多少 dB」是易变的。
        public var inputSharesOutputDevice: Bool

        public init(
            isAppBundle: Bool,
            tapCreated: Bool,
            systemProbe: Probe,
            micProbe: Probe,
            probeTonePlayed: Bool = false,
            deviceEnumerationWorked: Bool = true,
            inputSharesOutputDevice: Bool = false
        ) {
            self.isAppBundle = isAppBundle
            self.tapCreated = tapCreated
            self.systemProbe = systemProbe
            self.micProbe = micProbe
            self.probeTonePlayed = probeTonePlayed
            self.deviceEnumerationWorked = deviceEnumerationWorked
            self.inputSharesOutputDevice = inputSharesOutputDevice
        }
    }

    public struct Report: Equatable {
        public let verdict: Verdict
        /// 一句话结论
        public let headline: String
        /// 可操作的细节；不许为空
        public let details: [String]

        public var isUsable: Bool {
            verdict == .ready || verdict == .partiallyVerified || verdict == .degraded
        }
    }

    /// 判定就绪度。纯函数：同样输入必得同样结论。
    ///
    /// 优先级刻意如此排列——**越根本的原因越先说**。
    /// 形态不对会让权限必然拿不到，此时去查权限是白费功夫。
    public static func assess(_ input: Input) -> Report {
        // HAL 超时的恢复提示要在任何分支里都带出来，所以先算好。
        let halTimedOut = input.systemProbe == .timedOut || input.micProbe == .timedOut
        //
        // ⚠️ 这句话被推翻过一次，改回来要慎重。原版写的是
        // 「该状态不会自行恢复——实测等待 45 秒无效」，而「不会自行恢复」是**错的**：
        // 两次实测卡死都自行缓解了，coreaudiod 进程号始终不变。
        // 把 killall 摆在第一位，会让人去做一次本可避免、且会中断全机音频的操作。
        // 所以顺序必须是「先等，再杀」。
        let halHint = "「超时未返回」是 coreaudiod 卡在 IOProc 创建上的信号；"
            + "实测这种卡死多数会在几分钟内自行缓解（进程号不变）。"
            + "先等 2–5 分钟重跑本命令，仍不通再执行 sudo killall coreaudiod（或重启系统）。"

        // 1. 形态：最根本。裸 CLI 在 macOS 26 上拿不到系统音频权限，
        //    而且失败是静默的——所有 API 返回 0、缓冲区全零。
        //    这种情况下即使链路「全通」也是假象。
        guard input.isAppBundle else {
            return Report(
                verdict: .broken,
                headline: "采集不可用：程序没有从 .app bundle 运行",
                details: [
                    "系统音频采集在 macOS 26 上必须从 .app bundle 运行，裸可执行文件拿不到权限。",
                    "这个失败是静默的：所有 API 返回 0、采样点数完全正确，但缓冲区全零。",
                    "即使上面显示 tap 创建成功，在裸 CLI 下也不能相信。",
                    "先跑 ./scripts/build-app.sh 打包，再从 .app 内运行本命令。",
                ])
        }

        // 2. 两轨 HAL 都超时 => coreaudiod 卡在 IOProc 创建上。这是实测踩到的真实故障。
        //
        // 这里再分一层。设备枚举（AudioObjectGetPropertyData）与 IOProc 创建
        // （AudioDeviceCreateIOProcIDWithBlock）走的是 HAL 里两条不同的路径，
        // 实测见过「枚举照常返回设备、只有 IOProc 超时」的中间态——那个状态
        // 几分钟后自行缓解了，并不需要重启音频服务。把两者混为一谈，
        // 会把人推向一次本可避免的 killall。
        if input.systemProbe == .timedOut, input.micProbe == .timedOut {
            if input.deviceEnumerationWorked {
                return Report(
                    verdict: .broken,
                    headline: "采集不可用：IOProc 创建卡住（设备枚举仍正常）",
                    details: [
                        "设备枚举正常返回了输入设备，但 AudioDeviceCreateIOProcIDWithBlock 超时未返回——"
                        + "卡住的只是 IOProc 创建这一步，不是整个 audio 服务。",
                        "这不是本程序的问题。实测这种中间态会在几分钟内自行缓解，coreaudiod 进程号不变。",
                        "建议顺序：先等 2–5 分钟重跑本命令；仍不通再执行 sudo killall coreaudiod（或重启系统）。",
                        "排查时不要 kill -9 卡在 HAL 调用里的进程，那会让 coreaudiod 更糟。",
                    ])
            }
            return Report(
                verdict: .broken,
                headline: "采集不可用：设备枚举与 IOProc 创建都没返回",
                details: [
                    "HAL 层整体无响应：连枚举音频设备这一步都没能正常返回。",
                    "coreaudiod 处于卡死状态，AudioDeviceCreateIOProcIDWithBlock 永不返回。",
                    "恢复命令：sudo killall coreaudiod（或重启系统）。",
                    "也可以先等 2–5 分钟重跑一次——实测卡死有过自行缓解的情况，coreaudiod 进程号不变。",
                    "排查时不要 kill -9 卡在 HAL 调用里的进程，那会让 coreaudiod 更糟。",
                ])
        }

        let systemWorks = input.systemProbe == .warmed
        let micWorks = input.micProbe == .warmed
        // 系统音频轨采到全零，且探测期间**已经自播过测试音** —— 这就排除了
        // 「当前系统没在出声」这个解释，剩下的只能是授权或链路故障。
        // 没有这一位时，同样的全零既可能是故障也可能完全正常，判定只能停在「未证实」。
        let systemSilentProven = input.systemProbe == .silent && input.probeTonePlayed

        // 3. 系统音频轨可用，而麦克风轨的探针结果**不可采信**——因为默认输入与
        //    默认输出是同一台物理设备，提示音会被回声消除抹掉。
        //
        // 不做这一步的话，同一个环境、同一份代码会在
        // 「✅ 两轨都收到了真实数据」与「⚠️ 采集降级，仅系统音频轨被证实可用」
        // 之间随机摆动（两种输出都实测到过），而麦克风本身一直是好的。
        // 一个会自己变来变去的诊断，比一个说「无法判断」的诊断更糟。
        //
        // 放宽的**只有**「收到了 buffer」这两种结果。`noData` / `timedOut` 是链路级
        // 问题，与回声消除无关，必须照旧报出来——否则就是拿新规则去掩盖旧故障。
        if systemWorks, input.inputSharesOutputDevice,
           input.micProbe == .warmed || input.micProbe == .silent {
            return Report(
                verdict: .partiallyVerified,
                headline: "系统音频轨可用；麦克风轨无法用提示音验证（输入与输出是同一台设备）",
                details: [
                    "已确认录得到「对方」：系统音频轨收到了非零数据。",
                    "麦克风轨的链路正常（建得起 IOProc、收得到 buffer），但它的内容无法用提示音验证："
                        + "当前默认输入与默认输出是同一台设备，系统会对它启用回声消除，"
                        + "把本机自己播放的提示音抹掉。实测同一段提示音在这条轨上只剩系统轨的 0.5%~8%，"
                        + "其中一次是整段全零。",
                    "所以麦克风轨的结论是「未验证」，不是「有问题」——"
                        + "不要照这条去改权限或换设备。",
                    "要确认麦克风真能录到人声，只有一条可靠的路：录一次说话。"
                        + "跑 record --seconds 10 --title 试麦，对着麦克风说一句话，看那一段有没有信号。",
                    "也可以用 --device 把输入锁到本机内置麦克风（mr devices 查 UID），"
                        + "那就回到普通设备、提示音探测立刻恢复有效。",
                ])
        }

        // 4. 两轨都真的出数据 —— 唯一可以说 ready 的情形。
        if systemWorks, micWorks {
            return Report(
                verdict: .ready,
                headline: "采集链路可用：两轨都收到了真实数据",
                details: [
                    "麦克风轨与系统音频轨都跑通了 IOProc 并收到 buffer。",
                    "可以把工作交给 record 了。",
                ])
        }

        // 5. 只有一轨 —— 降级。必须点名缺的是哪一轨。
        //
        // 走到这里说明麦克风轨**不是**「共设备 + 收到 buffer」那种无法验证的情形
        // （那种已在第 3 步按 `partiallyVerified` 处理），所以这里的沉默是可信的：
        // 要么输入与输出是两台不同设备（提示音本该传到麦克风），要么压根没收到 buffer。
        if systemWorks, !micWorks {
            // 麦克风轨的「全零」和系统音频轨**不是一回事**：系统轨可以靠自播提示音确诊，
            // 麦克风轨不行。麦克风的判据是「人有没有说话」。所以这里只说到「未证实」，
            // 不许断言「录不到你」——那会把人推去做无用排查。
            return Report(
                verdict: .degraded,
                headline: "采集降级：仅系统音频轨被证实可用，麦克风轨未证实",
                details: [
                    "已确认录得到「对方」（系统音频轨收到了非零数据）。",
                    input.micProbe == .silent
                        ? "麦克风轨的链路是通的、帧数正常，但采样值**全零**——这一段没拾到任何声音。"
                        : "麦克风轨没有得到可用数据。",
                    input.micProbe == .silent
                        ? "这有两个成因，从录音数据上无法区分：这一段确实没人说话，"
                            + "或麦克风授权 / 输入设备有问题。"
                        : "",
                    input.micProbe == .silent
                        ? "注意：播提示音**不能**用来确诊麦克风轨——默认输入若是带回声消除的耳机"
                            + "（如 AirPods），系统播放的声音会被它滤掉，链路正常时也照样全零。"
                        : "",
                    "最直接的验证：对着当前默认输入设备说一句话，跑 record --seconds 10，"
                        + "看那一段有没有信号。",
                    "若说话也录不到，再到「系统设置 → 隐私与安全性 → 麦克风」确认本 app 已勾选，"
                        + "并确认默认输入没有被切到连续互通设备。",
                    halTimedOut ? halHint : "",
                ].filter { !$0.isEmpty })
        }

        if micWorks, !systemWorks {
            // 已自播提示音却仍全零 —— 与「当前没声音」无关，是确定故障。
            // 这种情况下含糊其辞代价很大：使用者会一直在「是不是没放声音」上打转。
            if systemSilentProven {
                return Report(
                    verdict: .broken,
                    headline: "系统音频轨确定不可用：已自播提示音，采到的仍是全零",
                    details: [
                        "探针运行期间本程序主动播放了系统提示音，而系统音频轨每个采样值都是零。",
                        "所以这不是「当前没人放声音」——喂进去的声音没有被拾到。",
                        "麦克风轨正常，说明程序本身能跑；问题只在这条 tap 链路（多半是授权未生效）。",
                        "先到「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」确认本 app 已勾选。"
                            + "它和麦克风是两套独立授权。",
                        "若开关已经是打开的，把本 app 从列表里移除再重新添加一次，"
                            + "然后完全退出本程序再重跑本命令。",
                        "若刚改过 bundle ID 或安装路径，TCC 会把它当新 app，此前的授权全部失效。",
                        halTimedOut ? halHint : "",
                    ].filter { !$0.isEmpty })
            }
            return Report(
                verdict: .degraded,
                headline: "采集降级：只有麦克风轨可用，系统音频轨没数据",
                details: [
                    "当前只能录到「我」，录不到「对方」——对会议录音来说这个降级很关键。",
                    explainSystemTrack(input),
                    input.tapCreated
                        ? "先确认「屏幕与系统音频录制」权限已授予本 app（它与麦克风是两套独立授权）。"
                        : "系统音频 tap 创建失败，先确认「屏幕与系统音频录制」权限（它与麦克风是两套独立授权）。",
                    "若刚改过 bundle ID 或安装路径，TCC 会把它当新 app，此前的授权全部失效——需要重新授权。",
                    "另一种可能是当前系统确实没有音频输出；放一段声音再测。",
                    halTimedOut ? halHint : "",
                ].filter { !$0.isEmpty })
        }

        // 6. tap 建不起来、麦克风也没证实 —— 什么录不了，是明确故障。
        if !input.tapCreated {
            return Report(
                verdict: .broken,
                headline: "采集不可用：系统音频 tap 创建失败，麦克风也没有数据",
                details: [
                    "两条轨都拿不到音频，无法录制。",
                    "先确认已授予「屏幕与系统音频录制」权限（它与麦克风是两套独立授权）。",
                    "再确认「系统设置 → 隐私与安全性 → 麦克风」里本 app 已勾选。",
                    "若刚改过 bundle ID 或安装路径，TCC 会把它当新 app，此前的授权全部失效——需要重新授权。",
                    halTimedOut ? halHint : "",
                ].filter { !$0.isEmpty })
        }

        // 7. 其余：链路搭好了，但没有任何一轨被证实能出数据。
        var details: [String] = []
        if systemSilentProven {
            details.append(
                "系统音频轨在**已自播提示音**的前提下仍是全零——这排除了「当前没声音」，"
                + "是确定的问题，不是环境因素。")
            details.append(
                "先到「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」确认本 app 已勾选；"
                + "若已勾选，移除后重新添加一次，再完全退出本程序重试。")
        } else if input.systemProbe == .silent || input.micProbe == .silent {
            details.append(
                "探针收到了 buffer，但采样值**全零**——链路全通、帧数正确、无任何报错。"
                + "这正是授权未生效的典型表现（静默失败）。")
            details.append(
                "系统音频与麦克风是两套独立授权，分别到「系统设置 → 隐私与安全性 → "
                + "屏幕与系统音频录制」和「麦克风」确认本 app 已勾选，然后完全退出本程序再重试。")
        } else {
            details.append("最常见原因是权限未授予，到「系统设置 → 隐私与安全性」确认相关项已勾选。")
        }
        if !systemSilentProven {
            details.append("另一种可能是录制时确实没有声音（无人说话、系统也未播放音频）；放一段声音再测。")
        }
        details.append("这条链路未证实前不要相信任何「录制成功」的结论。")
        if halTimedOut { details.append(halHint) }

        return Report(
            verdict: systemSilentProven ? .broken : .unproven,
            headline: systemSilentProven
                ? "采集不可用：系统音频轨已确诊故障，麦克风轨也未证实"
                : "采集未证实：没有任何一轨确认收到非零数据",
            details: details)
    }

    /// 用一句话说清系统音频轨为什么没数据。区分「没收到 buffer」和「收到但全零」，
    /// 因为这两者的排查方向完全不同。
    private static func explainSystemTrack(_ input: Input) -> String {
        switch input.systemProbe {
        case .silent:
            return "系统音频轨收到了 buffer，但采样值**全零**——链路是通的，内容空无一物。"
        case .noData:
            return "系统音频轨完全没有收到 buffer，链路没有真正跑起来。"
        case .timedOut:
            return "系统音频轨的 HAL 调用超时未返回。"
        case .warmed:
            return "系统音频轨数据正常（本分支不应出现）。"
        case .notAttempted:
            return "系统音频轨没有执行探针，无法判断。"
        }
    }
}
