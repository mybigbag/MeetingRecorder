import Foundation

/// 崩溃恢复。
///
/// 判定「崩溃」的唯一依据：manifest 里 `state == .recording`，但进程早已不在。
/// 因为 manifest 在录制开始时就落盘、正常停止时改成 `.finalized`，
/// 所以启动时看到 `recording` 就等于看到一份未收尾的录音。
public struct Recovery {

    public struct RecoveredTrack: Equatable {
        public var id: String
        public var fileName: String
        public var framesBefore: Int
        public var framesAfter: Int
        public var headerRepaired: Bool
        public var problem: String?
    }

    public struct RecoveredSession: Equatable {
        public var sessionID: String
        public var directory: URL
        public var previousState: SessionState
        public var duration: Double
        public var tracks: [RecoveredTrack]
    }

    public struct Report: Equatable {
        public var scanned: Int
        public var recovered: [RecoveredSession]
        public var failed: [(sessionID: String, reason: String)]

        public init(scanned: Int = 0, recovered: [RecoveredSession] = [],
                    failed: [(sessionID: String, reason: String)] = []) {
            self.scanned = scanned
            self.recovered = recovered
            self.failed = failed
        }

        public static func == (lhs: Report, rhs: Report) -> Bool {
            lhs.scanned == rhs.scanned
                && lhs.recovered == rhs.recovered
                && lhs.failed.map(\.sessionID) == rhs.failed.map(\.sessionID)
        }
    }

    public let store: SessionStore

    public init(store: SessionStore) { self.store = store }

    /// 扫描所有会话，修复未正常收尾的录音。幂等：重复运行不会重复处理。
    public func scanAndRepair() throws -> Report {
        var report = Report()
        let ids = try store.listSessionIDs()
        report.scanned = ids.count

        for id in ids {
            let dir = store.directory(forSessionID: id)
            let manifest: RecordingManifest
            do { manifest = try store.loadManifest(sessionDirectory: dir) }
            catch {
                report.failed.append((id, "manifest 不可读: \(error)"))
                continue
            }

            guard manifest.state == .recording else { continue }   // 已收尾，跳过

            var updated = manifest
            var recoveredTracks: [RecoveredTrack] = []

            for track in manifest.tracks {
                let url = store.trackURL(sessionDirectory: dir, fileName: track.fileName)
                var rt = RecoveredTrack(
                    id: track.id, fileName: track.fileName,
                    framesBefore: track.framesWritten, framesAfter: track.framesWritten,
                    headerRepaired: false, problem: nil)

                guard FileManager.default.fileExists(atPath: url.path) else {
                    rt.problem = "音频文件缺失"
                    recoveredTracks.append(rt)
                    continue
                }
                do {
                    let info = try WAVWriter.repairHeader(at: url)
                    rt.framesAfter = info.frameCount
                    rt.headerRepaired = info.frameCount != track.framesWritten
                    if let idx = updated.tracks.firstIndex(where: { $0.id == track.id }) {
                        updated.tracks[idx].framesWritten = info.frameCount
                        updated.tracks[idx].warnings.append(
                            "崩溃后恢复：帧数 \(track.framesWritten) → \(info.frameCount)")
                    }
                } catch {
                    rt.problem = "WAV 修复失败: \(error)"
                }
                recoveredTracks.append(rt)
            }

            updated.state = .recovered
            if updated.endedAt == nil {
                // 此刻 framesWritten 刚按**文件实际长度**修正过，是最可靠的时长来源：
                // checkpoint 写回的 hostTime 最多落后一个间隔（5 秒），不如文件长度精确。
                updated.endedAt = Self.inferEndDateFromFrames(
                    startedAt: manifest.startedAt, tracks: updated.tracks)
            }
            updated.addNote("由启动时崩溃恢复流程修复（原状态 recording）")

            do { try store.save(updated, sessionDirectory: dir) }
            catch {
                report.failed.append((id, "写回 manifest 失败: \(error)"))
                continue
            }

            let longest = updated.tracks.map(\.duration).max() ?? 0
            report.recovered.append(RecoveredSession(
                sessionID: id, directory: dir, previousState: .recording,
                duration: longest, tracks: recoveredTracks))
        }
        return report
    }

    /// 恢复场景专用：`framesWritten` 已按文件实际长度修正，
    /// 比 checkpoint 写回的 hostTime 更精确（后者最多落后一个 checkpoint 间隔）。
    static func inferEndDateFromFrames(startedAt: Date, tracks: [TrackManifest]) -> Date {
        let durations = tracks.map(\.duration)
        if let longest = durations.max(), longest > 0 {
            return startedAt.addingTimeInterval(longest)
        }
        return inferEndDate(startedAt: startedAt, tracks: tracks)
    }

    /// 反推真实的结束时间。
    ///
    /// 优先用音轨的 hostTime 跨度（最准）；崩溃时 manifest 可能还没写回过 hostTime，
    /// 这时退化为用「帧数 ÷ 采样率」推算——虽然不如 hostTime 精确，
    /// 但远好过把 endedAt 写成「恢复发生的时刻」（那样隔天恢复会得到荒谬的时长）。
    static func inferEndDate(startedAt: Date, tracks: [TrackManifest]) -> Date {
        let hostSpans = tracks.compactMap { t -> Double? in
            guard t.firstHostTime > 0, t.lastHostTime > t.firstHostTime else { return nil }
            return HostClock.secondsBetween(t.firstHostTime, t.lastHostTime)
        }
        if let longest = hostSpans.max(), longest > 0 {
            return startedAt.addingTimeInterval(longest)
        }

        let frameDerived = tracks.map(\.duration)
        if let longest = frameDerived.max(), longest > 0 {
            return startedAt.addingTimeInterval(longest)
        }
        return startedAt
    }
}
