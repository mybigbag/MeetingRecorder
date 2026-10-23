import XCTest
@testable import MRCore

/// 「静默录制」这个偏好的落盘。
///
/// 这一层看起来只是 `UserDefaults` 的转发，测它是因为**默认值本身就是规格**：
/// 默认必须是「看得见在录」。默认一旦反过来，受影响的是「忘记录着音」——
/// 一整场会议没录到，而且过程中没有任何地方提示过。那比「被别人看见」严重得多。
final class RecorderPreferencesTests: XCTestCase {

    /// 每个用例自己的 suite。
    ///
    /// **绝不能用 `.standard`**：那是运行测试的这个进程的偏好域，
    /// 写进去会跨用例、跨运行残留，于是「默认值」这一类断言第二次跑就不再成立——
    /// 而且失败与否取决于用例执行顺序，是最难查的一种。
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "mr-prefs-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    /// 全新安装（键根本不存在）时必须是 `false`。
    /// 注意这走的是 `bool(forKey:)` 对缺失键返回 false 的路径，
    /// 而不是某处 `register(defaults:)` 的副作用——两者行为一样，但只有前者
    /// 在「偏好文件被手动删掉」时也成立。
    func testFreshInstallShowsTheCountdown() throws {
        XCTAssertFalse(RecorderPreferences(defaults: defaults).hidesStatusBarCountdown)
        XCTAssertNil(
            defaults.object(forKey: RecorderPreferences.hidesStatusBarCountdownKey),
            "读一次偏好不该顺手把它写下来")
    }

    /// 真的落到了 `UserDefaults` 里，而不是只在内存里转了一圈。
    /// 判据直接查那个键——「用新实例读回来还是 true」在一个只做内存缓存的
    /// 实现上同样成立，挡不住这类退化。
    func testSettingIsActuallyWrittenToTheStore() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.hidesStatusBarCountdown = true

        XCTAssertEqual(
            defaults.object(forKey: RecorderPreferences.hidesStatusBarCountdownKey) as? Bool,
            true,
            "开关的值必须真的写进偏好域，键名 = \(RecorderPreferences.hidesStatusBarCountdownKey)")
    }

    /// 换一个实例（= 下次启动应用）仍然读到 true。
    func testSettingSurvivesANewInstance() throws {
        let first = RecorderPreferences(defaults: defaults)
        first.hidesStatusBarCountdown = true

        let second = RecorderPreferences(defaults: defaults)
        XCTAssertTrue(second.hidesStatusBarCountdown)
    }

    /// 关得掉。只写不关的实现（比如 `set` 写成了 `set(true)`）在这里会被抓住。
    func testSettingCanBeTurnedBackOff() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.hidesStatusBarCountdown = true
        XCTAssertTrue(prefs.hidesStatusBarCountdown)

        prefs.hidesStatusBarCountdown = false
        XCTAssertFalse(prefs.hidesStatusBarCountdown)
        XCTAssertFalse(RecorderPreferences(defaults: defaults).hidesStatusBarCountdown)
    }

    /// 两个实例指向同一个 suite 时必须看到彼此的写入——`MeetingWorkspace`
    /// 与测试夹具各持一个实例是常态，看到不同快照就说明缓存层级错了。
    func testTwoInstancesOnTheSameSuiteAgree() throws {
        let writer = RecorderPreferences(defaults: defaults)
        let reader = RecorderPreferences(defaults: defaults)

        writer.hidesStatusBarCountdown = true
        XCTAssertTrue(reader.hidesStatusBarCountdown)

        writer.hidesStatusBarCountdown = false
        XCTAssertFalse(reader.hidesStatusBarCountdown)
    }

    // MARK: - 16 位录音（体积减半）

    /// 默认必须是**关**，也就是照旧 32 位浮点无损录制。
    ///
    /// 理由比「静默录制默认关」更硬：打开它会**降低录音精度**（实测对转写无影响，
    /// 但那是这一版才测出来的结论，将来换了引擎就不一定）。升级一次应用就顺手把
    /// 用户的录音质量换掉，属于「没人发现、发现了也追溯不回来」的那类改动——
    /// 被换掉的那批音频已经录完了。要省空间，得用户自己点头。
    func testSixteenBitDefaultsOff() throws {
        XCTAssertFalse(RecorderPreferences(defaults: defaults).pcm16Recording)
        XCTAssertNil(
            defaults.object(forKey: RecorderPreferences.pcm16RecordingKey),
            "读一次偏好不该顺手把它写下来")
    }

    /// 真的落到了 `UserDefaults` 里。判据直接查键——「换个实例读回来是 true」
    /// 在一个只做内存缓存的实现上同样成立。
    func testSixteenBitIsActuallyWrittenToTheStore() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.pcm16Recording = true

        XCTAssertEqual(
            defaults.object(forKey: RecorderPreferences.pcm16RecordingKey) as? Bool,
            true,
            "开关的值必须真的写进偏好域，键名 = \(RecorderPreferences.pcm16RecordingKey)")
    }

    /// 换一个实例（= 下次启动应用）仍然读到 true。
    func testSixteenBitSurvivesANewInstance() throws {
        RecorderPreferences(defaults: defaults).pcm16Recording = true
        XCTAssertTrue(RecorderPreferences(defaults: defaults).pcm16Recording)
    }

    /// 关得掉。这条不只是「能写 false」——它挡的是「开关一旦打开就再也关不掉」，
    /// 而那种 bug 只有用户想把质量换回来时才会发现。
    func testSixteenBitCanBeTurnedBackOff() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.pcm16Recording = true
        XCTAssertTrue(prefs.pcm16Recording)

        prefs.pcm16Recording = false
        XCTAssertFalse(prefs.pcm16Recording)
        XCTAssertFalse(RecorderPreferences(defaults: defaults).pcm16Recording)
    }

    /// 两个开关**互不干扰**。
    ///
    /// 它们共用一个 `UserDefaults`，键名写错一个字母就会互相覆盖，
    /// 而症状是「勾了静默录制，录音格式也跟着变了」——没人会往这边想。
    ///
    /// 判据必须**双向**：原来的写法是 `XCTAssertNotEqual(两个字符串字面量)`，
    /// 对两个常量几乎永真——把 `pcm16Recording` 的读写接错到 hides 那个键上，
    /// 它照样全绿。这里两个开关各自「开 → 关」各走一遍，每步都验两个值，
    /// 任一方向的串键都会在「另一个开关的值被顺手改掉」处露出来。
    ///
    /// 退化示例：把 `pcm16Recording` 的读写键改成
    /// `hidesStatusBarCountdownKey`，开静默录制那一步之后
    /// `XCTAssertFalse(prefs.pcm16Recording)` 立刻变红。
    func testTheTwoSwitchesDoNotInterfere() throws {
        let prefs = RecorderPreferences(defaults: defaults)

        // 开静默录制：只该动它自己
        prefs.hidesStatusBarCountdown = true
        XCTAssertTrue(prefs.hidesStatusBarCountdown)
        XCTAssertFalse(prefs.pcm16Recording, "开静默录制不该顺手把 16 位也打开")

        // 再开 16 位：静默录制的状态必须原封不动，且真的落到它自己的键上
        prefs.pcm16Recording = true
        XCTAssertTrue(prefs.pcm16Recording)
        XCTAssertTrue(prefs.hidesStatusBarCountdown, "开 16 位不该把静默录制挤掉")
        XCTAssertEqual(
            defaults.object(forKey: RecorderPreferences.pcm16RecordingKey) as? Bool, true)

        // 关掉 16 位：静默录制仍然不动
        prefs.pcm16Recording = false
        XCTAssertFalse(prefs.pcm16Recording)
        XCTAssertTrue(prefs.hidesStatusBarCountdown, "关 16 位不该把静默录制一起关掉")

        // 再关静默录制：两个都回到 false
        prefs.hidesStatusBarCountdown = false
        XCTAssertFalse(prefs.hidesStatusBarCountdown)
        XCTAssertFalse(prefs.pcm16Recording)

        XCTAssertNotEqual(
            RecorderPreferences.hidesStatusBarCountdownKey,
            RecorderPreferences.pcm16RecordingKey,
            "两个开关的键名必须不同")
    }

    /// 派生属性：把偏好翻译成实际要用的格式枚举，开关一关必须回到无损。
    ///
    /// 单独钉它是因为**格式只有一个出处**（`MeetingWorkspace.startRecording` 读的就是
    /// 这个属性）。把 `testTheTwoSwitchesDoNotInterfere` 那类「开关存没存下来」的测试
    /// 全绿，也拦不住这里被写成恒返回一个值——那时所有用户录出来的格式都会是同一个。
    func testSampleFormatFollowsTheSwitch() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        XCTAssertEqual(prefs.sampleFormat, .float32, "默认必须是无损的 32 位浮点")

        prefs.pcm16Recording = true
        XCTAssertEqual(prefs.sampleFormat, .pcm16)

        prefs.pcm16Recording = false
        XCTAssertEqual(prefs.sampleFormat, .float32, "关掉开关必须回到无损")
    }

    // MARK: - 转写引擎（全局配置项）

    /// 默认必须是**苹果原生**，而且读一次不该把键写下来。
    ///
    /// 默认值本身就是规格：换引擎（尤其换成要下载 242 MB、内存涨到 300~400 MB 的 SV）
    /// 必须用户显式点头。若某次升级把默认悄悄换成 SV，被换掉的那批会议已经录完了，
    /// 且用户完全不知情——这正是这个断言要挡的事。
    func testTranscriptionEngineDefaultsToAppleWithoutWriting() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        XCTAssertEqual(prefs.transcriptionEngine, .apple, "默认必须是苹果原生")
        XCTAssertNil(
            defaults.object(forKey: RecorderPreferences.transcriptionEngineKey),
            "读一次偏好不该顺手把它写下来")
    }

    /// 真的落到偏好域，且换实例仍读得到——「只在内存里转一圈」的实现要在这里露馅。
    func testTranscriptionEngineIsPersistedAndSurvivesANewInstance() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.transcriptionEngine = .senseVoice

        XCTAssertEqual(
            defaults.string(forKey: RecorderPreferences.transcriptionEngineKey),
            TranscriptionEngine.senseVoice.rawValue,
            "引擎名必须真的写进偏好域")
        XCTAssertEqual(
            RecorderPreferences(defaults: defaults).transcriptionEngine, .senseVoice,
            "换实例（= 下次启动）仍要读到 SV")
    }

    /// 改得回来。只写不关的实现（set 写死一个值）在这里被抓。
    func testTranscriptionEngineCanBeSetBackToApple() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.transcriptionEngine = .senseVoice
        XCTAssertEqual(prefs.transcriptionEngine, .senseVoice)

        prefs.transcriptionEngine = .apple
        XCTAssertEqual(prefs.transcriptionEngine, .apple)
        XCTAssertEqual(RecorderPreferences(defaults: defaults).transcriptionEngine, .apple)
    }

    /// 存了一个不认识的引擎名（含历史遗留的 `whisper`）必须**回退到 apple**，
    /// 既不崩、也不静默选中一个更重的引擎。
    func testUnknownEngineNameFallsBackToApple() throws {
        defaults.set("whisper", forKey: RecorderPreferences.transcriptionEngineKey)
        XCTAssertEqual(RecorderPreferences(defaults: defaults).transcriptionEngine, .apple)

        defaults.set("SENSEVOICE", forKey: RecorderPreferences.transcriptionEngineKey)  // 大小写不匹配
        XCTAssertEqual(RecorderPreferences(defaults: defaults).transcriptionEngine, .apple)
    }

    /// 「读不写键」的补充：即便键已存在其它值，读也不该改动它。
    func testReadingEngineDoesNotRewriteTheStoredValue() throws {
        defaults.set("bogus", forKey: RecorderPreferences.transcriptionEngineKey)
        _ = RecorderPreferences(defaults: defaults).transcriptionEngine
        XCTAssertEqual(
            defaults.string(forKey: RecorderPreferences.transcriptionEngineKey), "bogus",
            "读一次不该把已存在的值改写成默认值")
    }

    // MARK: - 单声道 24 kHz（体积再降至 1/3）

    /// 默认必须是**关**，也就是照旧保留源采样率与声道数。
    ///
    /// 这条比「16 位默认关」还硬：位深降级影响的是精度，而这一项同时改掉
    /// **采样率与声道数**——用户拿到的是一副形态不同的录音，且已经录完的补不回来。
    ///
    /// 退化示例：把 `mono24kRecording` 的 getter 改成 `true`（或改成
    /// `defaults.object(forKey:) == nil ? true : ...`），本用例变红。
    func testMono24kDefaultsOffWithoutWriting() throws {
        XCTAssertFalse(RecorderPreferences(defaults: defaults).mono24kRecording)
        XCTAssertNil(
            defaults.object(forKey: RecorderPreferences.mono24kRecordingKey),
            "读一次偏好不该顺手把它写下来")
    }

    /// 真的落到了 `UserDefaults` 里。判据直接查键——「换个实例读回来是 true」
    /// 在一个只做内存缓存的实现上同样成立。
    func testMono24kIsActuallyWrittenToTheStore() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.mono24kRecording = true

        XCTAssertEqual(
            defaults.object(forKey: RecorderPreferences.mono24kRecordingKey) as? Bool,
            true,
            "开关的值必须真的写进偏好域，键名 = \(RecorderPreferences.mono24kRecordingKey)")
    }

    /// 换一个实例（= 下次启动应用）仍然读到 true；也关得掉。
    ///
    /// 「关得掉」这条挡的是「开关一旦打开就再也关不掉」——
    /// 而那种 bug 只有用户想把质量换回来时才会发现。
    func testMono24kSurvivesANewInstanceAndCanBeTurnedOff() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.mono24kRecording = true
        XCTAssertTrue(RecorderPreferences(defaults: defaults).mono24kRecording)

        prefs.mono24kRecording = false
        XCTAssertFalse(prefs.mono24kRecording)
        XCTAssertFalse(RecorderPreferences(defaults: defaults).mono24kRecording)
    }

    /// 三个开关**两两不串键**（静默录制 / 16 位 / 单声道 24 kHz）。
    ///
    /// 判据必须**双向**且逐步验其它两个：`XCTAssertNotEqual(两个常量)` 这种写法
    /// 对常量几乎永真，把读写接错到别的键上照样全绿。
    ///
    /// 退化示例：把 `mono24kRecording` 的读写键改成 `pcm16RecordingKey`，
    /// 「开 16 位」那一步之后 `XCTAssertFalse(prefs.mono24kRecording)` 立刻变红。
    func testAllThreeSwitchesDoNotInterfere() throws {
        let prefs = RecorderPreferences(defaults: defaults)

        prefs.hidesStatusBarCountdown = true
        XCTAssertFalse(prefs.pcm16Recording)
        XCTAssertFalse(prefs.mono24kRecording)

        prefs.pcm16Recording = true
        XCTAssertTrue(prefs.hidesStatusBarCountdown)
        XCTAssertFalse(prefs.mono24kRecording, "开 16 位不该顺手把带宽也降了")

        prefs.mono24kRecording = true
        XCTAssertTrue(prefs.hidesStatusBarCountdown, "开带宽开关不该把静默录制挤掉")
        XCTAssertTrue(prefs.pcm16Recording, "开带宽开关不该把位深挤掉")

        prefs.mono24kRecording = false
        XCTAssertTrue(prefs.pcm16Recording)
        XCTAssertTrue(prefs.hidesStatusBarCountdown)

        prefs.pcm16Recording = false
        XCTAssertFalse(prefs.pcm16Recording)
        XCTAssertFalse(prefs.mono24kRecording)
        XCTAssertTrue(prefs.hidesStatusBarCountdown)

        XCTAssertEqual(
            Set([
                RecorderPreferences.hidesStatusBarCountdownKey,
                RecorderPreferences.pcm16RecordingKey,
                RecorderPreferences.mono24kRecordingKey,
            ]).count, 3, "三个键名必须互不相同")
    }

    // MARK: - 菜单栏图标显示开关

    /// 全新安装（键不存在）时必须是**显示**。
    ///
    /// 这一项与上面几个开关的默认值**方向相反**，所以读法也不同：
    /// `bool(forKey:)` 对缺失键返回 `false`，这里要先问 `object(forKey:)`
    /// 把「没设过」和「设过关掉」区分开。少了这一问，升级后所有用户的
    /// 菜单栏图标会**一夜之间全部消失**——而用户什么都没做过。
    ///
    /// 顺带钉住「读不写键」：读一次之后键必须仍然不存在。
    func testStatusBarIconDefaultsToShownWithoutWriting() throws {
        XCTAssertTrue(RecorderPreferences(defaults: defaults).showsStatusBarIcon)
        XCTAssertNil(
            defaults.object(forKey: RecorderPreferences.showsStatusBarIconKey),
            "读一次偏好不该顺手把它写下来")
    }

    /// 关掉图标必须真的落进偏好域。判据直接查键——
    /// 「换个实例读回来是 false」在一个只做内存缓存的实现上同样成立。
    func testHidingTheStatusBarIconIsActuallyWrittenToTheStore() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.showsStatusBarIcon = false

        XCTAssertEqual(
            defaults.object(forKey: RecorderPreferences.showsStatusBarIconKey) as? Bool,
            false,
            "关掉图标必须真的写进偏好域，键名 = \(RecorderPreferences.showsStatusBarIconKey)")
    }

    /// 关掉之后换实例（= 下次启动）仍然是关的；也开得回来。
    ///
    /// 「开得回来」挡的是「一旦关掉就再也回不来」——那种 bug 的表现是
    /// 用户照着设置窗口的说明去恢复，图标却死活不出现。
    func testStatusBarIconSettingSurvivesANewInstanceAndCanBeTurnedBackOn() throws {
        let prefs = RecorderPreferences(defaults: defaults)
        prefs.showsStatusBarIcon = false
        XCTAssertFalse(RecorderPreferences(defaults: defaults).showsStatusBarIcon)

        prefs.showsStatusBarIcon = true
        XCTAssertTrue(prefs.showsStatusBarIcon)
        XCTAssertTrue(RecorderPreferences(defaults: defaults).showsStatusBarIcon)
    }

    /// 与其它开关**不串键**：关掉图标不该动到录音格式、静默录制。
    ///
    /// 判据逐步验其它三个值。只写 `XCTAssertNotEqual(两个键名常量)` 的话，
    /// 把读写接错到 `hidesStatusBarCountdownKey` 上照样全绿。
    func testStatusBarIconDoesNotInterfereWithOtherSwitches() throws {
        let prefs = RecorderPreferences(defaults: defaults)

        prefs.showsStatusBarIcon = false
        XCTAssertFalse(prefs.showsStatusBarIcon)
        XCTAssertFalse(prefs.hidesStatusBarCountdown, "关图标不该顺手打开静默录制")
        XCTAssertFalse(prefs.pcm16Recording, "关图标不该顺手改录音格式")
        XCTAssertFalse(prefs.mono24kRecording, "关图标不该顺手改录音格式")

        prefs.hidesStatusBarCountdown = true
        XCTAssertTrue(prefs.hidesStatusBarCountdown)
        XCTAssertFalse(prefs.showsStatusBarIcon, "开静默录制不该把图标开关挤掉")

        XCTAssertEqual(
            Set([
                RecorderPreferences.showsStatusBarIconKey,
                RecorderPreferences.hidesStatusBarCountdownKey,
                RecorderPreferences.pcm16RecordingKey,
                RecorderPreferences.mono24kRecordingKey,
            ]).count, 4, "四个键名必须互不相同")
    }
}
