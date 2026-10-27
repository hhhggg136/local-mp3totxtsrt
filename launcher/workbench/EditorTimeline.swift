import Foundation

// One integer timebase for editing, playback composition and export (48 ticks / millisecond).
enum EditorClock {
    static let scale: Int64 = 48_000
    static func fromMilliseconds(_ value: Int64) -> Int64 { value * 48 }
    static func seconds(_ ticks: Int64) -> Double { Double(ticks) / Double(scale) }
    static func timestamp(_ ticks: Int64) -> String {
        let ms = max(0, (ticks + 24) / 48)
        return String(format: "%02lld:%02lld:%02lld,%03lld", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
    static func parseTimestamp(_ text: String) throws -> Int64 {
        let pieces = text.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == ":" || $0 == "," })
        guard pieces.count == 4, let h = Int64(pieces[0]), let m = Int64(pieces[1]), let s = Int64(pieces[2]), let ms = Int64(pieces[3]),
              h >= 0, h < 8760, (0..<60).contains(m), (0..<60).contains(s), (0..<1000).contains(ms) else { throw EditorError.message("字幕时间码不正确。") }
        return (((h * 60 + m) * 60 + s) * 1000 + ms) * 48
    }
    static func parseSeconds(_ text: String) throws -> Int64 {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.range(of: #"^\d{1,8}(\.\d{1,3})?$"#, options: .regularExpression) != nil else { throw EditorError.message("时间请输入非负秒数，最多三位小数。") }
        let parts = value.split(separator: ".")
        guard let whole = Int64(parts[0]), whole < 31_536_000 else { throw EditorError.message("时间超出范围。") }
        let fraction = parts.count == 2 ? String(parts[1]).padding(toLength: 3, withPad: "0", startingAt: 0) : "000"
        return whole * scale + Int64(fraction)! * 48
    }
}

enum EditorError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct TickRange: Codable, Equatable, Sendable {
    var start: Int64
    var end: Int64
    var duration: Int64 { end - start }
    func intersection(_ other: TickRange) -> TickRange? {
        let range = TickRange(start: max(start, other.start), end: min(end, other.end))
        return range.end > range.start ? range : nil
    }
}
enum EditorTimelineMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, edited
    var id: String { rawValue }
    var title: String { self == .original ? "原始素材" : "剪辑结果" }
}
struct EditorSource: Codable, Equatable, Sendable {
    var path: String
    var durationTicks: Int64
    var fileSize: Int64
    var sha256: String
}
struct EditorDialogue: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var range: TickRange
    var originalText: String
    var text: String
}
enum ClipBoundaryOrigin: String, Codable, Sendable { case automaticMidpoint, manual }
struct EditorClip: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var initial: TickRange
    var range: TickRange
    var dialogueIDs: [UUID]
    var deleted = false
    var boundaryOrigin = ClipBoundaryOrigin.automaticMidpoint
    var textReviewConfirmed = false
    var isTrimmed: Bool { range != initial }
}
struct TimelineEntry: Equatable {
    var clipID: UUID
    var source: TickRange
    var timeline: TickRange
}
struct EditorTimelineMap: Equatable {
    var entries: [TimelineEntry]
    var duration: Int64 { entries.last?.timeline.end ?? 0 }
    func entry(at ticks: Int64) -> TimelineEntry? {
        guard ticks >= 0, ticks < duration else { return nil }
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].timeline.end <= ticks { low = mid + 1 } else { high = mid }
        }
        guard low < entries.count, ticks >= entries[low].timeline.start else { return nil }
        return entries[low]
    }
    func sourceTime(at ticks: Int64) -> Int64? {
        guard let entry = entry(at: ticks) else { return nil }
        return entry.source.start + ticks - entry.timeline.start
    }
    func timelineTime(source ticks: Int64, clipID: UUID) -> Int64? {
        guard let entry = entries.first(where: { $0.clipID == clipID }), ticks >= entry.source.start, ticks < entry.source.end else { return nil }
        return entry.timeline.start + ticks - entry.source.start
    }
}
struct ProjectedDialogue: Equatable, Identifiable {
    var id: String { clipID.uuidString + dialogueID.uuidString }
    var dialogueID: UUID
    var clipID: UUID
    var source: TickRange
    var timeline: TickRange
    var text: String
    var needsTextReview: Bool
}

struct AudioEditProject: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var source: EditorSource
    var dialogues: [EditorDialogue]
    var clips: [EditorClip]
    var order: [UUID]

    static func make(source: EditorSource, subtitle: String?) throws -> AudioEditProject {
        let cues = try subtitle.map(SubtitleTranslation.parse) ?? []
        let dialogues = try cues.map { cue -> EditorDialogue in
            let bounds = cue.timing.components(separatedBy: " --> ")
            return EditorDialogue(range: TickRange(start: try EditorClock.parseTimestamp(bounds[0]), end: try EditorClock.parseTimestamp(bounds[1])), originalText: cue.text, text: cue.text)
        }.enumerated().sorted { a, b in
            a.element.range.start == b.element.range.start ? a.offset < b.offset : a.element.range.start < b.element.range.start
        }.map(\.element)
        var groups: [[EditorDialogue]] = []
        var groupEnds: [Int64] = []
        for dialogue in dialogues {
            guard dialogue.range.start >= 0, dialogue.range.end <= source.durationTicks else { throw EditorError.message("字幕时间码超出所选素材，请确认字幕和音视频属于同一份素材。") }
            if let end = groupEnds.last, dialogue.range.start < end {
                groups[groups.count - 1].append(dialogue)
                groupEnds[groupEnds.count - 1] = max(end, dialogue.range.end)
            } else { groups.append([dialogue]); groupEnds.append(dialogue.range.end) }
        }
        var clips: [EditorClip] = []
        if groups.isEmpty {
            let range = TickRange(start: 0, end: source.durationTicks)
            clips = [EditorClip(initial: range, range: range, dialogueIDs: [])]
        } else {
            for index in groups.indices {
                let start = index == 0 ? 0 : (groupEnds[index - 1] + groups[index][0].range.start) / 2
                let end = index == groups.count - 1 ? source.durationTicks : (groupEnds[index] + groups[index + 1][0].range.start) / 2
                let range = TickRange(start: start, end: end)
                clips.append(EditorClip(initial: range, range: range, dialogueIDs: groups[index].map(\.id)))
            }
        }
        let project = AudioEditProject(source: source, dialogues: dialogues, clips: clips, order: clips.map(\.id))
        try project.validate()
        return project
    }
    func validate() throws {
        guard schemaVersion == 1, source.path.hasPrefix("/"), source.fileSize >= 0,
              source.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil, source.durationTicks > 0, source.durationTicks < 31_536_000 * EditorClock.scale,
              dialogues.count <= 10000, !clips.isEmpty, clips.count <= 10000,
              Set(order).count == clips.count, Set(order) == Set(clips.map(\.id)), Set(dialogues.map(\.id)).count == dialogues.count else { throw EditorError.message("项目结构不正确或版本不兼容。") }
        var end: Int64 = 0
        var assigned: [UUID] = []
        let dialogueIndex = Dictionary(uniqueKeysWithValues: dialogues.map { ($0.id, $0) })
        for clip in clips.sorted(by: { $0.initial.start < $1.initial.start }) {
            guard clip.initial.start == end, clip.initial.end > clip.initial.start,
                  clip.range.start >= clip.initial.start, clip.range.end <= clip.initial.end, clip.range.end > clip.range.start else { throw EditorError.message("片段区间不正确，不能打开项目。") }
            end = clip.initial.end
            for id in clip.dialogueIDs {
                guard let dialogue = dialogueIndex[id], dialogue.range.start >= clip.initial.start, dialogue.range.end <= clip.initial.end,
                      dialogue.range.end > dialogue.range.start, !dialogue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      dialogue.text.count <= 4000, dialogue.originalText.count <= 4000 else { throw EditorError.message("对白与片段的对应关系不正确。") }
                assigned.append(id)
            }
        }
        guard end == source.durationTicks, assigned.count == dialogues.count, Set(assigned).count == dialogues.count else { throw EditorError.message("项目的原始时间线不完整。") }
    }
    func timeline(_ mode: EditorTimelineMode) -> EditorTimelineMap {
        let index = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        let ids = mode == .original ? clips.sorted { $0.initial.start < $1.initial.start }.map(\.id) : order
        var cursor: Int64 = 0
        var entries: [TimelineEntry] = []
        entries.reserveCapacity(ids.count)
        for id in ids {
            guard let clip = index[id], mode == .original || !clip.deleted else { continue }
            let source = mode == .original ? clip.initial : clip.range
            let destination = TickRange(start: cursor, end: cursor + source.duration)
            entries.append(TimelineEntry(clipID: id, source: source, timeline: destination))
            cursor = destination.end
        }
        return EditorTimelineMap(entries: entries)
    }
    func projected(_ map: EditorTimelineMap) -> [ProjectedDialogue] {
        let clipIndex = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        let dialogueIndex = Dictionary(uniqueKeysWithValues: dialogues.map { ($0.id, $0) })
        var result: [ProjectedDialogue] = []
        for entry in map.entries {
            guard let clip = clipIndex[entry.clipID] else { continue }
            for id in clip.dialogueIDs {
                guard let dialogue = dialogueIndex[id], let remaining = dialogue.range.intersection(entry.source) else { continue }
                let start = entry.timeline.start + remaining.start - entry.source.start
                result.append(ProjectedDialogue(dialogueID: id, clipID: clip.id, source: remaining,
                    timeline: TickRange(start: start, end: start + remaining.duration), text: dialogue.text,
                    needsTextReview: remaining != dialogue.range && !clip.textReviewConfirmed))
            }
        }
        return result.sorted { $0.timeline.start < $1.timeline.start }
    }
    func previewRange(clipID: UUID, map: EditorTimelineMap) -> TickRange? {
        guard let entry = map.entries.first(where: { $0.clipID == clipID }) else { return nil }
        let cues = projected(EditorTimelineMap(entries: [entry]))
        guard let first = cues.first, let last = cues.max(by: { $0.timeline.end < $1.timeline.end }) else { return entry.timeline }
        return TickRange(start: first.timeline.start, end: last.timeline.end)
    }
    func subtitles(map: EditorTimelineMap) throws -> (srt: String, txt: String) {
        let cues = projected(map)
        var srt = "", txt = ""
        for (index, cue) in cues.enumerated() {
            let start = EditorClock.timestamp(cue.timeline.start), end = EditorClock.timestamp(cue.timeline.end)
            guard start != end else { throw EditorError.message("有字幕不足 1 毫秒，不能导出有效 SRT，请调整边界。") }
            let lines = cue.text.split(whereSeparator: { $0.isNewline })
            let text = lines.joined(separator: "\n")
            srt += "\(index + 1)\n\(start) --> \(end)\n\(text)\n\n"
            txt += "[\(start) → \(end)] \(lines.joined(separator: " / "))\n"
        }
        return (srt, txt)
    }
}

// Store at most 50 small inverse commands, never audio or complete project snapshots.
final class AudioEditHistory {
    private(set) var project: AudioEditProject
    private enum Action {
        case deletion(UUID, Bool, Bool)
        case move(UUID, Int, Int)
        case trim(UUID, TickRange, ClipBoundaryOrigin, Bool, TickRange)
        case text(UUID, String, String)
        case review(UUID, Bool, Bool)
    }
    private var undoActions: [Action] = []
    private var redoActions: [Action] = []
    var canUndo: Bool { !undoActions.isEmpty }
    var canRedo: Bool { !redoActions.isEmpty }
    var historyCount: Int { undoActions.count }
    init(project: AudioEditProject) throws { try project.validate(); self.project = project }
    private func commit(_ action: Action) {
        apply(action, forward: true); undoActions.append(action)
        if undoActions.count > 50 { undoActions.removeFirst() }
        redoActions.removeAll(keepingCapacity: true)
    }
    private func apply(_ action: Action, forward: Bool) {
        switch action {
        case .deletion(let id, let old, let new):
            if let i = project.clips.firstIndex(where: { $0.id == id }) { project.clips[i].deleted = forward ? new : old }
        case .move(let id, let old, let new):
            if let i = project.order.firstIndex(of: id) { project.order.remove(at: i); project.order.insert(id, at: forward ? new : old) }
        case .trim(let id, let old, let origin, let reviewed, let new):
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                project.clips[i].range = forward ? new : old
                project.clips[i].boundaryOrigin = forward ? .manual : origin
                project.clips[i].textReviewConfirmed = forward ? false : reviewed
            }
        case .text(let id, let old, let new):
            if let i = project.dialogues.firstIndex(where: { $0.id == id }) { project.dialogues[i].text = forward ? new : old }
        case .review(let id, let old, let new):
            if let i = project.clips.firstIndex(where: { $0.id == id }) { project.clips[i].textReviewConfirmed = forward ? new : old }
        }
    }
    func setDeleted(_ id: UUID, _ value: Bool) {
        guard let clip = project.clips.first(where: { $0.id == id }), clip.deleted != value else { return }
        commit(.deletion(id, clip.deleted, value))
    }
    func move(_ id: UUID, to index: Int) {
        guard let from = project.order.firstIndex(of: id), project.order.indices.contains(index), from != index else { return }
        commit(.move(id, from, index))
    }
    func trim(_ id: UUID, to range: TickRange) throws {
        guard let clip = project.clips.first(where: { $0.id == id }), range.start >= clip.initial.start, range.end <= clip.initial.end, range.duration > 0 else { throw EditorError.message("边界必须位于该片段的初始范围内，终点应晚于起点。") }
        guard range != clip.range else { return }
        commit(.trim(id, clip.range, clip.boundaryOrigin, clip.textReviewConfirmed, range))
    }
    func editText(_ id: UUID, text: String) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 4000 else { throw EditorError.message("对白文字不能为空，最多 4000 个字。") }
        guard let old = project.dialogues.first(where: { $0.id == id })?.text, old != value else { return }
        commit(.text(id, old, value))
    }
    func confirmReview(_ id: UUID, confirmed: Bool) {
        guard let clip = project.clips.first(where: { $0.id == id }), clip.textReviewConfirmed != confirmed else { return }
        commit(.review(id, clip.textReviewConfirmed, confirmed))
    }
    func undo() { guard let action = undoActions.popLast() else { return }; apply(action, forward: false); redoActions.append(action) }
    func redo() { guard let action = redoActions.popLast() else { return }; apply(action, forward: true); undoActions.append(action) }
}

enum AudioProjectFile {
    static func load(_ url: URL) throws -> AudioEditProject {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16_000_000 else { throw EditorError.message("项目文件超过 16 MB，无法打开。") }
        let project = try JSONDecoder().decode(AudioEditProject.self, from: Data(contentsOf: url))
        try project.validate()
        return project
    }
    static func save(_ project: AudioEditProject, to url: URL) throws {
        try project.validate()
        let source = URL(fileURLWithPath: project.source.path).resolvingSymlinksInPath().standardizedFileURL
        guard url.resolvingSymlinksInPath().standardizedFileURL != source,
              url.appendingPathExtension("bak").resolvingSymlinksInPath().standardizedFileURL != source else { throw EditorError.message("不能把项目或备份写入原素材。") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        guard data.count <= 16_000_000 else { throw EditorError.message("项目超过 16 MB，请分成较小项目。") }
        _ = try JSONDecoder().decode(AudioEditProject.self, from: data)
        if FileManager.default.fileExists(atPath: url.path) {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16_000_000 else { throw EditorError.message("现有目标文件超过项目大小限制，请另存为新文件；现有文件未修改。") }
            // One previous complete document, not an unbounded history of audio copies.
            try Data(contentsOf: url).write(to: url.appendingPathExtension("bak"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
}
