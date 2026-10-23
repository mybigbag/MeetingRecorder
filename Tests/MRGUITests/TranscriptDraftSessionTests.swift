import XCTest
import MRCore
@testable import MRGUI

/// 编辑转写稿的草稿簿：**打字不写盘，停顿才写一次，失败要退回**。
///
/// ## 这组用例钉住的是「卡顿的原因」
///
/// 反馈「编辑转写稿卡顿」时，本机最长的一场会有 **1375 段**。
/// 原来的实现每按一个键就 `saveTranscript`（编码 290 KB 的 prettyPrinted JSON +
/// 重写整份 markdown + 两次原子写），并把 `transcript` 重新 `@Published` 一次，
/// 于是整页 1375 行都重算。
///
/// 所以这里的判据不是「改完能存上」（那本来就能），而是
/// **`commitCount`（写盘次数）必须远小于按键次数**——
/// 把「每键写盘」改回去，这条会立刻红。
@MainActor
final class TranscriptDraftSessionTests: XCTestCase {

    private func makeDocument(segmentCount: Int = 3) -> TranscriptDocument {
        TranscriptDocument(
            sessionID: "S1", title: "评审", language: "zh", engine: "apple",
            segments: (0..<segmentCount).map { i in
                TranscriptSegment(start: Double(i), end: Double(i) + 1,
                                  text: "第 \(i) 段", track: "mic", speaker: "我")
            })
    }

    private func makeSession(segmentCount: Int = 3,
                             debounce: TimeInterval = 60,
                             disk: [String]? = nil) -> TranscriptDraftSession {
        let session = TranscriptDraftSession(document: makeDocument(segmentCount: segmentCount),
                                             debounce: debounce)
        var stored = disk
        session.commit = { index, text in
            if stored != nil { stored?[index] = text }
            return true
        }
        session.diskText = { index in
            guard let stored, stored.indices.contains(index) else { return nil }
            return stored[index]
        }
        return session
    }

    // MARK: - 防抖

    /// **核心**：打十个字只提交一次，且提交的是最后那一份文本。
    func testTypingManyCharactersCommitsOnce() {
        let session = makeSession()
        let sentence = Array("把灰度改成回度吧")
        for (offset, character) in sentence.enumerated() {
            session.drafts[0].text = String(sentence.prefix(offset + 1))
            session.noteChange(at: 0)
        }
        XCTAssertEqual(session.commitCount, 0, "还在打字就写盘＝每个键一次全量写，正是卡顿的来源")
        XCTAssertTrue(session.hasPending)

        session.flush()

        XCTAssertEqual(session.commitCount, 1, "一次停顿只该写一次盘")
        XCTAssertEqual(session.drafts[0].text, String(sentence))
    }

    /// 防抖计时器自己到点（不靠 flush）。
    func testDebounceTimerFiresOnItsOwn() async throws {
        let session = makeSession(debounce: 0.05)
        session.drafts[1].text = "改过的第二段"
        session.noteChange(at: 1)

        // 停在 await 上时主线程让出来，那个 `Task` 才能跑到点。
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(session.commitCount, 1)
        XCTAssertFalse(session.hasPending)
    }

    /// 连续改**不同**的段：每段各提交一次，不能因为共用一个计时器就漏掉前一段。
    func testEditsToDifferentSegmentsAreAllCommitted() {
        let session = makeSession()
        session.drafts[0].text = "A"
        session.noteChange(at: 0)
        session.drafts[1].text = "B"
        session.noteChange(at: 1)

        session.flush()

        XCTAssertEqual(session.commitCount, 2)
        XCTAssertEqual(session.drafts[0].text, "A")
        XCTAssertEqual(session.drafts[1].text, "B")
    }

    /// 原样打字（内容没变）不该产生提交。
    func testNoEditNoCommit() {
        let session = makeSession()
        session.flush()
        XCTAssertEqual(session.commitCount, 0)
    }

    // MARK: - 清空 / 恢复

    /// 清空之前必须先撤掉待提交：否则 0.35 秒后那次提交会把刚清掉的文字写回去。
    func testCancelPendingPreventsResurrectingClearedText() {
        let session = makeSession()
        session.drafts[0].text = "用户刚打的字"
        session.noteChange(at: 0)

        session.cancelPending(at: 0)
        session.syncDraft(at: 0, to: "")

        session.flush()

        XCTAssertEqual(session.commitCount, 0, "清空后又被写回，等于清空没生效")
        XCTAssertEqual(session.drafts[0].text, "")
    }

    /// 清空/恢复之后草稿必须跟着变——行视图只认草稿，不同步就显示旧文字。
    func testSyncDraftFollowsTheDocument() {
        let session = makeSession()
        session.drafts[2].text = "改了一半"
        session.noteChange(at: 2)

        session.syncDraft(at: 2, to: "引擎原文")

        XCTAssertEqual(session.drafts[2].text, "引擎原文")
        XCTAssertFalse(session.hasPending)
    }

    // MARK: - 写盘失败

    /// 写盘失败：草稿退回磁盘那份，并把提交标记为失败。
    ///
    /// 界面留着「其实没存下来」的字，刷新一次就凭空复原——
    /// 那会让用户以为自己改的没生效，然后再改一遍。
    func testFailedCommitRollsTheDraftBackToDisk() {
        let session = makeSession(disk: ["第一段", "第二段", "第三段"])
        session.commit = { _, _ in false }

        session.drafts[0].text = "改完但存不下去"
        session.noteChange(at: 0)
        session.flush()

        XCTAssertEqual(session.drafts[0].text, "第一段")
    }

    /// 失败**不能**连带把后面那些段的改动也丢掉：一次只回滚写失败的那一段。
    func testFailedCommitKeepsOtherSegmentsIntact() {
        let session = makeSession(disk: ["第一段", "第二段", "第三段"])
        var failed = false
        session.commit = { index, _ in
            if index == 0 && !failed {
                failed = true
                return false
            }
            return true
        }
        session.drafts[0].text = "改0"
        session.noteChange(at: 0)
        session.drafts[1].text = "改1"
        session.noteChange(at: 1)

        session.flush()

        XCTAssertEqual(session.drafts[0].text, "第一段", "失败那段退回磁盘内容")
        XCTAssertEqual(session.drafts[1].text, "改1", "别把没失败的段也退回去")
        XCTAssertTrue(session.hasPending, "没写成的段必须重新排队，否则它的改动无声消失")
    }
}
