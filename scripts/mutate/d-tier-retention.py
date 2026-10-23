#!/usr/bin/env python3
"""D 档变异验证：把生产代码按清单逐条改坏，确认对应的测试**真的会红**。

为什么必须做：一条永远绿的测试比没有测试更坏——它给「已覆盖」这个错觉，
而 D 档红一条可能意味着「本该被保住的录音被删了」。

每条变异都：备份 → 改坏 → 跑指定测试 → 记录红/绿 → 还原 → 校验 sha256 一致。
最后那步不是形式主义：这个脚本自己会改生产代码，还原不干净就是在损坏的
代码上跑下一轮验证。

用法：
    ./scripts/mutate/d-tier-retention.py            # 全部
    ./scripts/mutate/d-tier-retention.py M-D3 M-D4  # 指定几条
"""
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
os.chdir(ROOT)

# (编号, 相对路径, [(要匹配的原文, 替换成), ...], 预期变红的测试过滤器, 说明)
MUTATIONS = [
    (
        "M-D1", "Sources/MRSession/MeetingWorkspace.swift",
        [("            preferences.retentionPolicy = retentionPolicy\n",
          "            preferences.retentionPolicy = retentionPolicy\n"
          "            _ = try? retentionCleaner.run(policy: retentionPolicy)\n")],
        "StatusItemRetentionMenuTests/testSelectingAPolicyDeletesNothing",
        "设档位顺手清理一批（纪律 1）",
    ),
    (
        # M-D2 原来只抹掉跳过原因的**文案**。而断言是
        # `skipReason!.contains("manifest")`——抹掉文案里那半句之后
        # 「manifest」两个字仍然在（前半句留着），所以照样绿。
        #
        # 第一版替换体写得太长（构造一整个 SessionPlan），引用了那个作用域里
        # 不存在的 `fileManager`/`w`，**编译直接失败**，一条测试都没跑起来，
        # 而脚本把「0 tests」当成「测试仍全绿」——假命中。M-D10 栽在同一处。
        # 现在只改**开始时间**这一个点：读不出来时拿目录 mtime 顶替，照样进判定流程。
        #
        # 目标用例换过一次：`testBrokenManifestIsNotPrunedEvenWhenTheDirectoryLooksOld`
        # 零命中，因为它的场次只有 **0.5 天**大——mtime 路径判出来的年龄确实很老，
        # 但伪造的 manifest `tracks` 是空的，后面「有轨才删」的判据照样挡住。
        # `testBrokenManifestIsNeverPruned` 的场次是 100 天，且三条断言
        # （prunable 为空 / 不计体积 / 跳过原因非空）全都覆盖到这条路径。
        "M-D2", "Sources/MRSession/SessionRetentionCleaner.swift",
        [("        catch { return skip(\"manifest 读不出来（\\(error.localizedDescription)）。年龄无从判断，跳过。\") }",
          "        //变异：读不出来就拿目录 mtime 当开始时间，照样进判定流程\n"
          "        catch {\n"
          "            let mtime = (try? FileManager.default.attributesOfItem(\n"
          "                atPath: dir.path)[.modificationDate] as? Date) ?? now\n"
          "            var brokenManifest = RecordingManifest(sessionID: id, title: id,\n"
          "                                                   startedAt: mtime, state: .finalized)\n"
          "            brokenManifest.endedAt = mtime\n"
          "            manifest = brokenManifest\n"
          "        }")],
        "SessionRetentionCleanerTests/testBrokenManifestIsNeverPruned",
        "坏 manifest 改按目录 mtime 猜年龄（纪律 2，真正的风险形态）",
    ),
    (
        "M-D3", "Sources/MRCore/RetentionPolicy.swift",
        [("        return age >= Double(d) * 86_400",
          "        return age > Double(d) * 86_400 + 1")],
        "RetentionPolicyTests/testExactlyNDaysOldIsSelected",
        "年龄边界从 >= 改成 >（D2-01）",
    ),
    (
        "M-D4", "Sources/MRSession/SessionRetentionCleaner.swift",
        [("        if !hasTranscript && !includeUntranscribed {",
          "        if false && !includeUntranscribed {")],
        "SessionRetentionCleanerTests/testUntranscribedSessionIsSkippedByDefault",
        "去掉「必须有转写稿」这一条（纪律 3）",
    ),
    (
        "M-D5", "Sources/MRSession/SessionRetentionCleaner.swift",
        [("        if manifest.state == .recording {",
          "        if false {")],
        "SessionRetentionCleanerTests/testRecordingSessionIsNeverPruned",
        "去掉「recording 跳过」这一条（纪律 4）",
    ),
    (
        # M-D6 与 M-D8 是**耦合**的：只要 M-D8 生效（目录里有额外 wav 就整场跳过），
        # 「扫目录而不是读 manifest」就永远走不到执行那一步——单独跑它零命中，
        # 而那个零命中**不代表测试无效**。所以这条要先关掉 M-D8，两个一起改。
        #
        # 目标用例也是换过的：本来指向 `testFilesNotListedInManifestAreLeftAlone`，
        # 零命中。查下来那个夹具的额外文件是 `.txt`/`.png`，而本变异只把
        # `.wav` 纳入删除范围——它压根碰不到那两条断言。
        # 实测（双变异同时打上）真正变红的是
        # `testAnyExtraWavBlocksTheSession`：额外的 `现场录音.wav`
        # 进了 `filesToDelete`，正是这条变异描述的后果。
        #
        # （另一次尝试把 `known` 清空，那条更是错的：那样 mic.wav / system.wav
        #   自己也被当成「额外的 wav」，于是每一场都被跳过，测试照样绿。）
        "M-D6", "Sources/MRSession/SessionRetentionCleaner.swift",
        [("        if let merged = mergedArtifacts(in: dir, manifest: manifest) {",
          "        if let merged = mergedArtifacts(in: dir, manifest: manifest), false {"),
         ("        for t in manifest.tracks {",
          "        for t in ((try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? [])\n"
          "            .filter({ $0.lowercased().hasSuffix(\".wav\") }).map({\n"
          "                TrackManifest(id: $0, role: .microphone, fileName: $0,\n"
          "                             sampleRate: 48000, channels: 1, framesWritten: 1)\n"
          "            }) {")],
        "SessionRetentionCleanerTests/testAnyExtraWavBlocksTheSession",
        "扫目录找 wav 而不是读 manifest（M-D6；须与 M-D8 一起改才可达）",
    ),
    (
        "M-D7", "Sources/MRSession/SessionRetentionCleaner.swift",
        [("            names.append(t.fileName)",
          "            names.append(t.fileName)\n"
          "            _ = try? fileManager.removeItem(at: dir.appendingPathComponent(\n"
          "                SessionStore.manifestFileName))")],
        "SessionRetentionCleanerTests/testManifestAndTranscriptSurviveCleanup",
        "顺手把 manifest 也删掉（M-D7）",
    ),
    (
        "M-D8", "Sources/MRSession/SessionRetentionCleaner.swift",
        [("        if let merged = mergedArtifacts(in: dir, manifest: manifest) {",
          "        if let merged = mergedArtifacts(in: dir, manifest: manifest), false {")],
        "SessionRetentionCleanerTests/testSessionWithMergedArtifactIsSkippedEntirely",
        "有合并导出文件时不整场跳过（附加纪律）",
    ),
    (
        "M-D9", "Sources/MRCore/RecorderPreferences.swift",
        [("        get { RetentionPolicy(resolving: defaults.string(forKey: Self.retentionPolicyKey)) }",
          "        get { RetentionPolicy(resolving: defaults.string(forKey: Self.retentionPolicyKey)) ?? .off }")],
        "RetentionPolicyTests/testUnrecognizedStoredValueIsReportedRatherThanMaskedAsOff",
        "坏键静默回退 .off（M-D9，最危险的一条）",
    ),
    (
        # 直接抹掉而不是进废纸篓（M-D10，用户无法反悔）。
        #
        # 变异点搬过一次家。原来改的是 `trashItem` 那一行，而目标用例
        # `testDeletedFilesLandInTheTrash` 去读**真实的 `~/.Trash`**——
        # 那是 macOS 的系统行为，在无头 / 权限受限环境里会静默失效。
        # 于是这条变异出现了一种最坏的结果：**判据是有效的，测试却是假的绿**。
        # 实测：同一份变异代码，命令行连跑 4 次都红，放进完整跑批却稳定绿；
        # `rm -rf .build`、清 swiftpm 编译缓存、`swift build --build-tests`
        # 全都试过，都不改变这个结果。
        #
        # 修法不是继续找环境因素（那条路已经证明是死胡同），而是**把判据从
        # 系统行为挪到调用边界**：删除动作已经是注入点了（`trash:` 闭包），
        # 现在变异改的是默认闭包里的实现，测试断言的是「调了哪个动作」，
        # 不碰任何系统行为，跨环境稳定。
        "M-D10", "Sources/MRSession/SessionRetentionCleaner.swift",
        [("        var resulting: NSURL?\n"
          "        try fileManager.trashItem(at: url, resultingItemURL: &resulting)\n"
          "        return resulting as URL? ?? url",
          "        //变异：直接抹掉，不走废纸篓\n"
          "        try fileManager.removeItem(at: url)\n"
          "        return url")],
        "SessionRetentionCleanerTests/testDefaultTrashActionReportsALandingPointDistinctFromTheSource",
        "删除动作退化为直接抹掉（用户无法反悔）",
    ),
    (
        "M-D11", "Sources/MRCLI/MeetingRecorderCLI.swift",
        [("        guard let override = config.daysOverride else { return prefs.resolvedRetentionPolicy() }\n\n"
          "        // ⚠️ **这一支绝不落盘。** `--days` 是一次性覆盖：\n"
          "        // 「我试着清一次」不该把长期设置也改掉。\n"
          "        // 有测试钉住「调用这个函数之后偏好一个字节都没变」。\n"
          "        return .days(override)",
          "        guard let override = config.daysOverride else { return prefs.resolvedRetentionPolicy() }\n"
          "        prefs.retentionPolicy = .days(override)\n        return .days(override)")],
        "PruneCommandTests/testDaysOverrideDoesNotPersistToPreferences",
        "--days 顺手落盘（M-D11）",
    ),
    (
        "M-D12", "Sources/MRSession/SessionRetentionCleaner.swift",
        [("            return .skipped(sessionID: id, title: title, startedAt: startedAt,\n"
          "                            reason: \"还没到 \\(policy.displayName)。\",\n"
          "                            hasTranscript: hasTranscript)",
          "            return .skipped(sessionID: id, title: title, startedAt: startedAt,\n"
          "                            reason: \"\",\n"
          "                            hasTranscript: hasTranscript)")],
        "SessionRetentionCleanerTests/testEverySkipCarriesAReadableReason",
        "跳过的场次不写原因（M-D12）",
    ),

    # ---- 「先压后删」顺序提醒（2026-10-09 补）----
    #
    # 这四条守的是同一个东西：**用户以为「清掉了就省下了」**。
    # 顺序反了省的是原始体积，而 prune 不可逆——清完就压不成了。

    (
        # 「已经压过」被当成「还没压过」。
        #
        # 方向一开始写反了（改成 `return true`），结果测试照样绿：
        # 返回 true 意味着「都算压过了」→ stillUncompressed = false →
        # `XCTAssertFalse(sp.isUncompressed)` 正好通过。
        # 教训：**变异必须朝着断言的反方向**。
        # 这里真正的坑是反向的：一直提示「还能再省 6 倍」，
        # 而那 6 倍早就省过了，用户会为一个不存在的收益去跑一遍 transcode。
        "M-D13", "Sources/MRSession/SessionRetentionCleaner.swift",
        [("        return t.sampleFormat == .pcm16 && t.channels == w.channels && t.sampleRate == w.sampleRate",
          "        return false")],
        "SessionRetentionCleanerTests/testCompressedSessionIsNotMarkedUncompressed",
        "已压过的场次仍被标成「还没压过」（反向：提示一个不存在的收益）",
    ),
    (
        # 目标采样率从 24000 改成 48000 —— 少算了一半的收益。
        # 期望值 6.0 是**真机实测**的（14.3 MiB → 2.4 MiB），
        # 所以这条打不中就说明估算与真实转码脱钩了。
        "M-D14", "Sources/MRSession/SessionRetentionCleaner.swift",
        [("                        mono24k: true).sampleRate,",
          "                        mono24k: true).sampleRate * 2,")],
        "SessionRetentionCleanerTests/testCompressionRatioMatchesRealTranscodeMeasurement",
        "压缩比估算少算一半（与真机实测 6.00 倍脱钩）",
    ),
    (
        # 收益估算把**已经不在盘上**的轨也算进去（用 manifest 的帧数估一份字节）。
        # 少一轨时会把收益算低——而「算低」是最坏的方向：
        # 用户以为没多少可省，于是照删。
        "M-D15", "Sources/MRSession/SessionRetentionCleaner.swift",
        [("            guard fileManager.fileExists(atPath: url.path) else { continue }\n"
          "            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0",
          "            let onDisk = fileManager.fileExists(atPath: url.path)\n"
          "            let size = onDisk\n"
          "                ? ((try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)\n"
          "                : Int(Double(t.framesWritten) * Double(t.sampleFormat.bitsPerSample) / 8\n"
          "                    * Double(t.channels))")],
        "SessionRetentionCleanerTests/testRatioUsesOnlyTracksActuallyOnDisk",
        "不在盘上的轨也参与收益加权（把收益算低，方向最坏）",
    ),
    (
        # 汇总把**跳过的场次**也算进「还没压过」。
        #
        # 这条**需要两条改动一起施加**，单独任何一条都打不中——
        # 与 M-D6 同一个耦合形态（那里是「扫目录」被「额外 wav 跳过」挡住）：
        #   1. `skipped(...)` 的默认 `isUncompressed: false` → true
        #   2. `uncompressedPrunable` 从 `prunable` 改成 `sessions`
        # 只改 1：跳过的场次带了标记，但仍被 `prunable` 挡在汇总外 → 测试绿。
        # 只改 2：汇总放行了所有场次，但它们的标记都是 false → 测试也绿。
        # 零命中**不代表测试无效**，只代表「任一单独改动都不足以造成这个缺陷」。
        #
        # 两条一起施加时打中的是 testSkippedSessionsCarryNoCompressionAdvice。
        "M-D16", "Sources/MRSession/SessionRetentionCleaner.swift",
        [("                                   isUncompressed: Bool = false) -> SessionPlan {",
          "                                   isUncompressed: Bool = true) -> SessionPlan {"),
         ("        public var uncompressedPrunable: [SessionPlan] {\n"
          "            prunable.filter(\\.isUncompressed)\n"
          "        }",
          "        public var uncompressedPrunable: [SessionPlan] {\n"
          "            sessions.filter { $0.isUncompressed }\n"
          "        }")],
        "SessionRetentionCleanerTests/testSkippedSessionsCarryNoCompressionAdvice",
        "跳过的场次也带「还没压过」标记且汇总放行（汇总数虚高，白跑 transcode）；须两条一起改",
    ),

    # ---- Q1 档位合并（2026-10-09 补）----

    (
        # 把「关闭」与「永久保留」重新拆成两个 selectable 档位——
        # 也就是**这次要修的那个缺陷本身**。守卫用例
        # `testNoTwoSelectablePoliciesAgreeAtEveryAge` 必须红：
        # 拆出来的两个档位在任何年龄上判定都相同，找不到分出高下的年龄。
        #
        # 实现上用的是**把 `.off` 列两遍**，不是加回 `.forever` 枚举成员：
        # 变异必须能编译通过才算命中，而加成员要同时改 enum、rawValue、
        # displayName、menuHelp 一大片——那些改不动的地方会先编译失败，
        # 脚本只看到 "error:" 就报了命中，那是假命中。
        # 列两遍等价于「菜单里有两个永久保留」，正是缺陷的真实形态。
        "M-D17", "Sources/MRCore/RetentionPolicy.swift",
        [("        .off, .days(7), .days(30), .days(90)\n",
          "        .off, .off, .days(7), .days(30), .days(90)\n")],
        "RetentionPolicyTests/testNoTwoSelectablePoliciesAgreeAtEveryAge",
        "菜单里出现两个判定相同的档位（Q1 的缺陷本身）",
    ),

    # ---- Q2 合并音轨默认目录（2026-10-09 补）----

    (
        # **Q2 的缺陷本身**：默认目录不再是会话目录。
        #
        # 目标用例一开始指向 `exportMergedAudio` 里那两行
        # （`if let directory = ... { panel.directoryURL = directory }`），
        # 结果零命中——查下来是**变异打在了没被测的地方**：
        # `NSSavePanel` 在无头测试里点不出来，用例直接调静态函数
        # `mergeSavePanelDirectory`，根本不经过 `exportMergedAudio`。
        # 换句话说：改坏调用点，测试看不见；这恰恰是这个用例存在的理由。
        #
        # 所以变异改被测函数本身——退回改之前的真实形态（返回 nil，
        # 等价于「没设 directoryURL」，面板落到上次位置或「文稿」根目录）。
        "M-D18", "Sources/MRGUI/MeetingDetailView.swift",
        [("        var isDirectory: ObjCBool = false\n"
          "        guard FileManager.default.fileExists(atPath: sessionDirectory.path,\n"
          "                                             isDirectory: &isDirectory),\n"
          "              isDirectory.boolValue else { return nil }\n"
          "        return sessionDirectory",
          "        //变异：不设默认目录（改之前的实现）\n"
          "        let _ = sessionDirectory\n"
          "        return nil")],
        "MeetingDetailViewInfoTests/testMergeSavePanelDefaultsToTheSessionDirectory",
        "合并面板拿不到默认目录（Q2 的缺陷本身，产物散落到别处）",
    ),
    (
        # 目录判据从 `isDirectory:` 退化成「路径上有东西」。
        # 目标用例专打这一条：同一个路径作为**文件**存在时也返回它。
        "M-D18b", "Sources/MRGUI/MeetingDetailView.swift",
        [("        var isDirectory: ObjCBool = false\n"
          "        guard FileManager.default.fileExists(atPath: sessionDirectory.path,\n"
          "                                             isDirectory: &isDirectory),\n"
          "              isDirectory.boolValue else { return nil }",
          "        guard FileManager.default.fileExists(atPath: sessionDirectory.path) else {\n"
          "            return nil\n        }")],
        "MeetingDetailViewInfoTests/testMergeSavePanelDirectoryRejectsAFileAtTheSamePath",
        "把文件也当成目录返回给面板（isDirectory 判据被抽掉）",
    ),

    # ---- Q3 自动清理（2026-10-09 补）----
    #
    # 这组守的是「用户没授权就删了」和「静默失败」两类形态，
    # 方向与手动路径相反：手动那次用户在场，自动这次用户不在场。

    (
        # 授权判据被削弱成「档位设了就当授权了」。
        #
        # 目标用例一开始选的是 `testFreshInstallNeverDeletesAnything`，**零命中**——
        # 查下来是判据选错了形态：全新安装时 `policy == nil`，
        # 即便跳过 `.autoPruneDisabled` 也照样撞在 `guard let policy` 上返回，
        # 一个字节都不会少。「默认关」本身不需要这条守。
        #
        # 真正的风险形态是**档位已设、开关没开**（下面这条 M-D19b 才打那个），
        # 而这条打的是「开关判据根本不看」：只要偏好里存在一个可删的档位
        # 就直接执行清理。于是用户为了「看看效果」把档位设成 7 天，
        # 几天后老录音自动消失——而他唯一做过的动作是选了个下拉框。
        "M-D19", "Sources/MRSession/RetentionAutoPruner.swift",
        [("        guard autoPruneEnabled else { return .autoPruneDisabled }",
          "        //变异：档位设了就当授权了\n"
          "        if !autoPruneEnabled && (policy?.isEnabled ?? false) == false {\n"
          "            return .autoPruneDisabled\n        }")],
        "RetentionAutoPrunerTests/testSettingThePolicyAloneDoesNotEnableAutomaticDeletion",
        "档位设了就算授权自动删除（选个下拉框就会开始删录音）",
    ),
    (
        # **默认就会删**：从来没设过任何东西的用户，被当成「按 30 天清理」执行。
        #
        # 这一条经过三次改写才打中，值得记下来：
        #
        # 1. 改 `autoPruneEnabled` 的 getter 反读 → 零命中。
        #    `testFreshInstallNeverDeletesAnything` 的夹具只造会议、**不写档位**，
        #    于是 `policy == nil`，开关再怎么反都撞在 `guard let policy` 上返回，
        #    一个字节都不会少。
        # 2. 改 `skipReason` 的授权判据 → 同样零命中，原因一样。
        # 3. 「抽掉开关 + 抽掉空档位的守卫」→ 也不中：档位真的是 nil，
        #    `cleaner.run(policy:)` 拿不到东西。
        #
        # 真正的失效形态是**给一个没设过档位的用户硬塞一个会删的档位**，
        # 那正是「未经任何授权就删录音」。这也解释了为什么守卫用例
        # 必须断言 `lastAutoPruneDate` 为 nil——它证明「跑过」这件事没发生过。
        "M-D19b", "Sources/MRSession/RetentionAutoPruner.swift",
        [("        let reason = Self.skipReason(\n"
          "            autoPruneEnabled: preferences.autoPruneEnabled,\n"
          "            policy: preferences.retentionPolicy,\n"
          "            hasUnrecognizedPolicy: preferences.hasUnrecognizedRetentionPolicy(),\n"
          "            lastRunDay: preferences.lastAutoPruneDate,\n"
          "            today: stamp)\n"
          "        guard let policy = preferences.retentionPolicy, reason == nil else {",
          "        let reason = Self.skipReason(\n"
          "            autoPruneEnabled: preferences.autoPruneEnabled,\n"
          "            policy: preferences.retentionPolicy,\n"
          "            hasUnrecognizedPolicy: preferences.hasUnrecognizedRetentionPolicy(),\n"
          "            lastRunDay: preferences.lastAutoPruneDate,\n"
          "            today: stamp)\n"
          "        //变异：授权闸与空档位守卫一起抽掉，并硬塞一个会删的档位\n"
          "        let policy = preferences.retentionPolicy ?? .days(30)\n"
          "        if false {")],
        "RetentionAutoPrunerTests/testFreshInstallNeverDeletesAnything",
        "没设过档位的用户被硬塞一个会删的档位（默认就会删录音）",
    ),
    (
        # 「今天跑过了」这道闸抽掉——每次触发点都扫一遍全库。
        # 方向：删得更多、更频繁，用户对「为什么这时又少了几个文件」毫无预期。
        "M-D20", "Sources/MRSession/RetentionAutoPruner.swift",
        [("        if lastRunDay == today { return .alreadyRanToday(today) }",
          "        //变异：去掉「每天至多一次」的闸\n        _ = lastRunDay")],
        "RetentionAutoPrunerTests/testSecondRunOnTheSameDayIsBlocked",
        "去掉「每天至多一次」的闸（同一天反复扫库删东西）",
    ),
    (
        # 坏键**继续执行**而不是拒绝。这条与手动路径 M-D9 同源，
        # 但自动路径更糟：没人点确认时，静默按「关」执行会被读成「配置没生效」。
        "M-D21", "Sources/MRSession/RetentionAutoPruner.swift",
        [("        if hasUnrecognizedPolicy { return .unrecognizedPolicy }",
          "        //变异：坏键不拒绝，继续往下判\n        if hasUnrecognizedPolicy && today.isEmpty {\n"
          "            return .unrecognizedPolicy\n        }")],
        "RetentionAutoPrunerTests/testUnrecognizedPolicyRefusesAndExplains",
        "坏档位不再拒绝执行（静默按「关」处理，用户以为设置生效了）",
    ),
    (
        # 「空跑也算跑过」被抽掉——今天本来没有符合档位的会议时不记日期，
        # 于是用户新录一场再转写就会在同一天里**再触发一轮扫库**。
        # 这是 M-D20 之外另一条独立的失效路径，闸在两个不同的地方。
        "M-D22", "Sources/MRSession/RetentionAutoPruner.swift",
        [("            let outcome = try cleaner.run(policy: policy,\n"
          "                                          includeUntranscribed: includeUntranscribed)\n"
          "            preferences.lastAutoPruneDate = stamp",
          "            let outcome = try cleaner.run(policy: policy,\n"
          "                                          includeUntranscribed: includeUntranscribed)\n"
          "            if !outcome.deleted.isEmpty { preferences.lastAutoPruneDate = stamp }")],
        "RetentionAutoPrunerTests/testAnEmptyRunStillCountsAsHavingRunToday",
        "空跑不记「今天跑过了」（同日再扫一轮库）",
    ),

    # ---- Q4 单轨转写（2026-10-09 补）----

    (
        # **覆盖整场稿**：单轨文件名退化回 `transcript`。
        # 这是本轮最危险的一条——用户转了一条轨，回头发现整场稿没了，
        # 而界面上「已转写」的样子完全正常。
        "M-D23", "Sources/MRSession/SessionTranscriber.swift",
        [("        let stem = wholeSession\n"
          "            ? String(SessionStore.transcriptMarkdownName\n"
          "                .replacingOccurrences(of: \".md\", with: \"\"))\n"
          "            : Self.singleTrackFileStem(trackIDs: selectedTracks.map(\\.id))",
          "        let stem = String(SessionStore.transcriptMarkdownName\n"
          "            .replacingOccurrences(of: \".md\", with: \"\"))")],
        "SessionTranscriberSingleTrackTests/testSingleTrackRunNeverOverwritesTheWholeSessionTranscript",
        "单轨稿覆盖整场 transcript.md（用户那条轨的成果抹掉另一条轨的）",
    ),
    (
        # 单轨也把场次标成 `.transcribed`。
        # 后果：界面显示「已转写」，而用户根本没意识到还缺一条轨——
        # 直到某天去查另一轨说了什么，才发现那份稿不存在。
        "M-D24", "Sources/MRSession/SessionTranscriber.swift",
        [("        if wholeSession {\n"
          "            manifest.state = .transcribed\n"
          "            try store.save(manifest, sessionDirectory: directory)\n        }",
          "        manifest.state = .transcribed\n"
          "        try store.save(manifest, sessionDirectory: directory)")],
        "SessionTranscriberSingleTrackTests/testSingleTrackRunDoesNotMarkTheSessionAsTranscribed",
        "单轨转写把整场标成「已转写」（缺了一条轨却看不出来）",
    ),
    (
        # 忽略 `trackFilter`，单轨时照旧两条轨都送进引擎。
        # 后果不只是慢：产物文件名还带着轨名，而内容是整场的——
        # 用户拿 `transcript-mic.md` 当「只看我说了什么」来用，
        # 而里面混着对方的每一句。
        "M-D25", "Sources/MRSession/SessionTranscriber.swift",
        [("            selectedTracks = manifest.tracks.filter { filter.contains($0.id) }",
          "            selectedTracks = manifest.tracks")],
        "SessionTranscriberSingleTrackTests/testOnlyTheSelectedTrackIsSentToTheEngine",
        "忽略轨筛选，两条轨都转写却写成单轨文件名（内容与文件名不符）",
    ),
    (
        # 报告不区分「删到了」与「没删到」。
        # 这条判据抓的是**自动路径特有的**失效形态：用户不在场，
        # 两种情况在界面上长得一样，他会以为第二次没生效而反复去转写。
        "M-D26", "Sources/MRSession/RetentionAutoPruner.swift",
        [("        if outcome.deleted.isEmpty {\n"
          "            return \"按当前档位，今天没有需要清理的旧音频。\"\n        }",
          "        //变异：不区分删到没删到\n        if false {\n"
          "            return \"按当前档位，今天没有需要清理的旧音频。\"\n        }")],
        "RetentionAutoPrunerTests/testReportDistinguishesDeletedFromNothingToDo",
        "自动清理报告不区分「删到了」与「没删到」（用户以为没生效）",
    ),
]


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def apply_mutation(path, edits):
    """返回 True 表示确实改动了内容。任一原文没命中就放弃整条变异。

    放弃而不是部分应用：部分应用改出来的状态不是清单里描述的那个变异，
    拿它去跑测试得到的结果毫无意义，而「看起来跑了」比不跑更坏。
    """
    with open(path, "r", encoding="utf-8") as f:
        original = f.read()
    mutated = original
    for old, new in edits:
        if old not in mutated:
            print("    ⚠️ 原文没命中：\n" + old[:160])
            return False
        mutated = mutated.replace(old, new, 1)
    if mutated == original:
        return False
    with open(path, "w", encoding="utf-8") as f:
        f.write(mutated)
    return True


# 测试类名 → SwiftPM test target 名。
#
# 为什么必须显式给 target：`swift test --filter` 只认 `Target.类名/方法名`，
# 而**不匹配的过滤条件会静默跑 0 个测试**（不是报错）。0 个测试的输出里没有
# `error:`，于是一条根本没跑过的变异会被判成「测试仍全绿」——一份永远绿的
# 验证报告比没有验证更坏。补全 target 之后，`run_filtered` 里的
# 「Executed == 0 就算判据无效」那道守卫也才真正起作用。
CLASS_TO_TARGET = {
    "RetentionPolicyTests": "MRCoreTests",
    "RecorderPreferencesTests": "MRCoreTests",
    "SessionRetentionCleanerTests": "MRSessionTests",
    "RetentionAutoPrunerTests": "MRSessionTests",
    "SessionTranscriberSingleTrackTests": "MRSessionTests",
    "SessionTranscriberTests": "MRSessionTests",
    "MeetingWorkspaceTests": "MRSessionTests",
    "MeetingDetailViewInfoTests": "MRGUITests",
    "StatusItemRetentionMenuTests": "MRGUITests",
    "StatusItemControllerTests": "MRGUITests",
    "PruneCommandTests": "MRCLITests",
    "MeetingRecorderArgumentTests": "MRCLITests",
    "TranscodeArgumentTests": "MRCLITests",
    "TrackRecorderTests": "MRCaptureTests",
    "TranscriptionEngineResolverTests": "MRTranscribeTests",
    "MinutesOrchestratorTests": "MRMinutesTests",
}


def qualify_filter(expr: str) -> str:
    """把 `类名/方法名` 补成 `Target.类名/方法名`。已有 target 前缀的原样返回。"""
    if "." in expr.split("/")[0]:
        return expr
    cls = expr.split("/")[0]
    target = CLASS_TO_TARGET.get(cls)
    if target is None:
        return expr
    return "%s.%s" % (target, expr)


def rebuild_after_crash():
    """在**施加变异之后、跑测试之前**强制重建一次。

    ## 为什么放在这个位置

    原本放在每条变异的开头（即「上一条还原之后」），实测**不管用**：M-D10
    在完整跑批里稳定零命中，而单独跑、同进程连跑 6 次、连跑 4 次命令行、
    `rm -rf .build`、清 swiftpm 编译缓存——全都命中。差别只剩「上一条跑过什么」。

    机制：SwiftPM 判定「要不要重编」看的是它自己的构建数据库，而每条变异
    都是**改同一个文件再还原**（内容哈希来回切换）。前面那些条目会把数据库
    推到「M-D10 那一版已经编译过了」的状态，于是 `swift test` 不重编，
    跑的是**上一次**留下的二进制。

    所以正确的位置是「变异已落到磁盘、测试还没跑」——此刻强制重建，
    编出来的就是**当前这版**。改到还原之后再重建是白做的：那时候源码
    已经是基线，重建出来的仍是基线二进制。
    """
    subprocess.run(
        ["swift", "build", "--disable-sandbox", "--build-tests"],
        capture_output=True, text=True, cwd=ROOT,
    )


def run_filtered(filter_expr):
    """跑一条测试，返回 (是否变红, 输出)。

    ## `--filter` 语法：`Target.类名/方法名`（**点**号分隔 target，斜杠分隔方法）

    写成 `Target/类名/方法名`（斜杠分隔 target）会**静默跑 0 个测试**，
    而 0 tests 的输出里没有 `error:`，于是一条根本没跑过的变异会被判成
    「测试仍全绿」——零命中的假象就是这么来的。已实测：
    `MRGUITests/MeetingDetailViewInfoTests/testX` → 0 tests（假）；
    `MRGUITests.MeetingDetailViewInfoTests/testX` → 1 test（对）。

    所以下面额外把「跑了 0 个测试」显式判成失败：判据本身坏了时必须喊出来，
    而不是伪装成一条「测试有效」的结论。

    ## **顺序很关键：先判红，再判有没有跑**

    M-D8 就是反例：它的变异让用例在 `XCTUnwrap` 上崩溃
    （`exited with unexpected signal code 5`），进程**中途死掉**，
    于是 `Executed N test` 那行根本没打印出来——先查「跑没跑」就会得到
    「0 tests → 判据无效」的结论，把一条真正命中的变异报成零命中。
    崩溃本身就是红，所以顺序必须是：红 → 直接返回；不红 → 才去追问跑没跑。
    """
    expr = qualify_filter(filter_expr)
    proc = subprocess.run(
        ["swift", "test", "--disable-sandbox", "--filter", expr],
        capture_output=True, text=True,
    )
    out = proc.stdout + proc.stderr

    # 红的三种形态：断言失败、编译/运行错误、进程崩溃。
    # 崩溃那一条别漏——它在输出里长这样：
    #   error: Process '...xctest ...' exited with unexpected signal code 5
    red = ("error:" in out and ("XCTAssert" in out or "failed" in out)) \
        or ("exited with unexpected signal code" in out)
    if red:
        return True, out

    # `Executed N test(s)` 每个 target 各出一行，所以同一数字会重复出现若干次。
    # 这里按「有没有任何一行大于 0」判断——踩过的坑是取 max：各 target 的数字不同，
    # max 恰好为 0（多数 target 一条都没匹配上），把「跑到了 1 条」误判成「没跑」。
    ran_anything = False
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("Executed ") and " test" in s:
            parts = s.split()
            try:
                if int(parts[1]) > 0:
                    ran_anything = True
            except (IndexError, ValueError):
                pass

    if not ran_anything:
        print("    ⚠️ 过滤条件没匹配到任何测试（判据无效）：%s" % filter_expr)
        print("    实际过滤：%s" % expr)
        print("    swift test 只认 `Target.类名/方法名`，不匹配时是静默跑 0 个；")
        print("    也可能是变异把编译改坏了 → 请把类名补进 CLASS_TO_TARGET。")
        return False, out

    return False, out


def main():
    only = set(sys.argv[1:])
    targets = [m for m in MUTATIONS if not only or m[0] in only]

    if only and len(targets) != len(only):
        missing = only - {m[0] for m in targets}
        print("不存在的变异编号：" + " ".join(sorted(missing)))
        return 2

    hits, misses = [], []
    for mid, rel, edits, filt, desc in targets:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            print("❌ %s 找不到文件：%s" % (mid, rel))
            misses.append(mid)
            continue

        before = sha256(path)
        backup = tempfile.mktemp()
        shutil.copy2(path, backup)

        try:
            if not apply_mutation(path, edits):
                print("❌ %s 改写失败（判据无效）—— %s" % (mid, desc))
                misses.append(mid)
                continue
            # 变异已落盘、测试还没跑 —— 此刻强制重编，编出来的才是当前这版。
            rebuild_after_crash()
            red, out = run_filtered(filt)
            if red:
                print("✅ %s 命中 —— %s" % (mid, desc))
                hits.append(mid)
            else:
                print("❌ %s 零命中（相关测试仍全绿）—— %s" % (mid, desc))
                print("    过滤条件：%s" % filt)
                misses.append(mid)
        finally:
            # **总是**先无条件还原（备份还在时它就是可信副本），再校验。
            #
            # 原来写的是「先删备份、再校验、失败时再从已删的备份复制」——
            # 那个顺序会让损坏悄悄溜过去。而更早的一版是完全不校验。
            # 现在：还原 → 校验 → 不一致就再报一次（此时备份还在，可再次覆盖）。
            shutil.copy2(backup, path)
            if sha256(path) != before:
                shutil.copy2(backup, path)  # 再覆盖一次，排除复制途中被打断
                if sha256(path) != before:
                    print("   ⚠️⚠️ 还原失败：%s 未能还原，请立刻检查！" % rel)
                    misses.append(mid)
            os.unlink(backup)

    print("")
    print("变异结果：命中 %d / 未命中 %d / 共 %d"
          % (len(hits), len(misses), len(targets)))
    if misses:
        print("未命中：" + " ".join(misses))
    return 0 if not misses else 1


if __name__ == "__main__":
    sys.exit(main())