import AppKit
import Combine
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

struct WorkbenchRow: Identifiable {
    var id: UUID
    var text: String
    var sourceRange: TickRange
    var clipRange: TickRange
    var preview: TickRange?
    var timelineRange: TickRange?
    var dialogueIDs: [UUID]
    var dialogues: [EditorDialogue]
    var dialogueRanges: [UUID: TickRange]
    var deleted: Bool
    var needsReview: Bool
    var trimmed: Bool
    var boundaryDescription: String
}

@MainActor final class AudioWorkbenchModel: ObservableObject {
    @Published private(set) var project: AudioEditProject?
    @Published private(set) var rows: [WorkbenchRow] = []
    @Published private(set) var map = EditorTimelineMap(entries: [])
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var positionTicks: Int64 = 0
    @Published private(set) var playing = false
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var waveformLoading = false
    @Published private(set) var status = "导入音视频和 SRT，即可按对白试听、删除和重排。"
    @Published private(set) var mode: EditorTimelineMode = .edited
    @Published private(set) var dirty = false
    @Published private(set) var projectURL: URL?
    @Published private(set) var lastExport: URL?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var relinkAvailable = false
    @Published var selection: UUID?
    @Published var showDeleted = false { didSet { updateVisibleRows() } }
    @Published var showSpeakers = false
    @Published private(set) var speakerMetrics: String?
    @Published var showExport = false

    var focusWindow: (() -> Void)?
    let player = AVPlayer()
    private var history: AudioEditHistory?
    private var allRows: [WorkbenchRow] = []
    private var sourcePeaks: [Float] = []
    private var pendingRelink: (AudioEditProject, URL)?
    private var work: Task<Void, Never>?
    private var compositionTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var periodic: Any?
    private var boundary: Any?
    private var itemObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var contentID = UUID()
    private var compositionID = UUID()
    private var playbackID = UUID()
    private var workID = UUID()
    private(set) var closed = false
    var selectedRow: WorkbenchRow? { rows.first { $0.id == selection } }
    var deletedCount: Int { project?.clips.filter(\.deleted).count ?? 0 }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        periodic = player.addPeriodicTimeObserver(forInterval: EditorMedia.time(4800), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                let ticks = min(max(0, EditorMedia.ticks(time)), self.map.duration)
                if self.positionTicks != ticks { self.positionTicks = ticks }
            }
        }
        playbackObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let active = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in self?.playing = active }
        }
    }
    private func updateVisibleRows() {
        rows = mode == .original || showDeleted ? allRows : allRows.filter { !$0.deleted }
        if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = rows.first?.id }
        if selection == nil { selection = rows.first?.id }
    }
    private func refresh() {
        guard let history else { return }
        let sourcePosition = map.sourceTime(at: positionTicks)
        let sourceClip = map.entry(at: positionTicks)?.clipID
        let project = history.project
        self.project = project
        canUndo = history.canUndo; canRedo = history.canRedo
        map = project.timeline(mode)
        let clipIndex = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.id, $0) })
        let dialogueIndex = Dictionary(uniqueKeysWithValues: project.dialogues.map { ($0.id, $0) })
        let entryIndex = Dictionary(uniqueKeysWithValues: map.entries.map { ($0.clipID, $0) })
        let projected = Dictionary(grouping: project.projected(map), by: \.clipID)
        let ids = mode == .original ? project.clips.sorted { $0.initial.start < $1.initial.start }.map(\.id) : project.order
        allRows = ids.compactMap { id in
            guard let clip = clipIndex[id] else { return nil }
            let cues = projected[id] ?? []
            let texts = clip.dialogueIDs.compactMap { dialogueIndex[$0]?.text }
            let first = cues.map(\.timeline.start).min(), last = cues.map(\.timeline.end).max()
            let spokenSource = TickRange(start: cues.map(\.source.start).min() ?? clip.range.start, end: cues.map(\.source.end).max() ?? clip.range.end)
            let preview = first != nil && last != nil ? TickRange(start: first!, end: last!) : entryIndex[id]?.timeline
            return WorkbenchRow(id: id, text: texts.isEmpty ? "非对白音频片段" : texts.joined(separator: " / "), sourceRange: spokenSource,
                clipRange: clip.range, preview: preview, timelineRange: entryIndex[id]?.timeline, dialogueIDs: clip.dialogueIDs, dialogues: clip.dialogueIDs.compactMap { dialogueIndex[$0] },
                dialogueRanges: Dictionary(uniqueKeysWithValues: cues.map { ($0.dialogueID, $0.timeline) }),
                deleted: clip.deleted, needsReview: cues.contains(where: \.needsTextReview), trimmed: clip.isTrimmed,
                boundaryDescription: clip.boundaryOrigin == .manual ? "手动裁剪" : "自动中点建议")
        }
        updateVisibleRows()
        waveform = EditorMedia.projectedWaveform(sourcePeaks, sourceDuration: project.source.durationTicks, map: map)
        let target = sourcePosition.flatMap { position in sourceClip.flatMap { map.timelineTime(source: position, clipID: $0) } } ?? 0
        rebuildPlayer(seekTo: target)
    }
    private func rebuildPlayer(seekTo ticks: Int64) {
        pause()
        compositionTask?.cancel()
        let id = UUID(); compositionID = id
        ready = false; positionTicks = min(max(0, ticks), map.duration)
        itemObservation = nil
        player.replaceCurrentItem(with: nil)
        guard let source = project?.source, map.duration > 0 else { return }
        let map = map
        compositionTask = Task { [weak self] in
            do {
                let composition = try await EditorMedia.composition(source: source, map: map)
                try Task.checkCancellation()
                guard let self, self.compositionID == id, !self.closed else { return }
                let item = AVPlayerItem(asset: composition)
                item.preferredForwardBufferDuration = 2
                self.itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    let failed = item.status == .failed
                    let message = item.error?.localizedDescription
                    if failed { Task { @MainActor [weak self] in
                        guard let self, self.compositionID == id else { return }
                        self.ready = false; self.status = "播放失败：" + (message ?? "无法解码音轨")
                    } }
                }
                self.player.replaceCurrentItem(with: item)
                self.ready = true
                self.seek(to: ticks)
            } catch {
                guard let self, self.compositionID == id, !Task.isCancelled, !self.closed else { return }
                self.status = "时间线准备失败：\(error.localizedDescription)"
            }
        }
    }
    func pause() {
        playbackID = UUID()
        player.pause(); playing = false
        if let boundary { player.removeTimeObserver(boundary); self.boundary = nil }
        player.currentItem?.forwardPlaybackEndTime = .invalid
    }
    func seek(to ticks: Int64) {
        pause()
        let ticks = min(max(0, ticks), max(0, map.duration - 1))
        positionTicks = ticks
        player.seek(to: EditorMedia.time(ticks), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func locate(_ id: UUID) {
        selection = id
        guard let row = rows.first(where: { $0.id == id }), let range = row.preview else { status = "这个片段已从剪辑结果删除，可切换原始素材查看。"; return }
        seek(to: range.start)
    }
    func locateDialogue(clip: UUID, dialogue: UUID, audition: Bool = false) {
        selection = clip
        guard let range = rows.first(where: { $0.id == clip })?.dialogueRanges[dialogue], !busy, ready else { return }
        if audition { playRange(range) } else { seek(to: range.start) }
    }
    func preview(_ id: UUID) {
        selection = id
        guard ready, !busy, let range = rows.first(where: { $0.id == id })?.preview else { return }
        playRange(range)
    }
    func togglePlayback() {
        if playing { pause(); return }
        guard ready, !busy, map.duration > 0 else { return }
        let start = positionTicks >= map.duration - 48 ? 0 : positionTicks
        playRange(TickRange(start: start, end: map.duration))
    }
    private func playRange(_ range: TickRange) {
        pause()
        let token = UUID(); playbackID = token
        positionTicks = range.start
        player.currentItem?.forwardPlaybackEndTime = EditorMedia.time(range.end)
        boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: EditorMedia.time(range.end))], queue: .main) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.playbackID == token else { return }
                self.player.pause(); self.playing = false; self.positionTicks = range.end
            }
        }
        player.seek(to: EditorMedia.time(range.start), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
            Task { @MainActor [weak self] in
                guard let self, done, self.playbackID == token, !self.closed else { return }
                self.player.play(); self.playing = true
            }
        }
    }
    func setMode(_ newMode: EditorTimelineMode) {
        guard !busy, newMode != mode else { return }
        mode = newMode; refresh()
        status = newMode == .original ? "正在查看原始时间线；删除、裁剪和重排仅在剪辑结果中进行。" : "剪辑结果按保留片段排列，导出将使用同一份时间映射。"
    }
    private func edited(_ change: (AudioEditHistory) throws -> Void) {
        guard !busy, mode == .edited, let history else { return }
        do {
            try change(history); dirty = true; lastExport = nil; refresh()
        } catch { status = error.localizedDescription }
    }
    func deleteSelected() { guard let selection else { return }; setDeleted(selection, deleted: true) }
    func setDeleted(_ id: UUID, deleted: Bool) {
        edited { $0.setDeleted(id, deleted) }
        status = deleted ? "片段已从剪辑结果删除，原素材未修改；可以撤销。" : "片段已恢复。"
    }
    func moveSelected(_ delta: Int) {
        guard let selection, let order = project?.order, let index = order.firstIndex(of: selection) else { return }
        let target = index + delta
        guard order.indices.contains(target) else { return }
        edited { $0.move(selection, to: target) }
    }
    func move(_ id: UUID, before target: UUID) {
        guard let order = project?.order, let from = order.firstIndex(of: id), let to = order.firstIndex(of: target), id != target else { return }
        edited { $0.move(id, to: from < to ? to - 1 : to) }
    }
    func trimSelected(start: String, end: String) {
        guard let selection, let clip = project?.clips.first(where: { $0.id == selection }) else { return }
        edited { editor in
            let beginning = start == Self.secondsText(clip.range.start) ? clip.range.start : try EditorClock.parseSeconds(start)
            let ending = end == Self.secondsText(clip.range.end) ? clip.range.end : try EditorClock.parseSeconds(end)
            try editor.trim(selection, to: TickRange(start: beginning, end: ending))
        }
    }
    func resetTrim() {
        guard let selection, let clip = project?.clips.first(where: { $0.id == selection }) else { return }
        edited { try $0.trim(selection, to: clip.initial) }
    }
    func saveText(_ id: UUID, text: String) { edited { try $0.editText(id, text: text) } }
    func confirmReview() { guard let selection else { return }; edited { $0.confirmReview(selection, confirmed: true) } }
    func addSpeaker() { edited { try $0.addSpeaker() } }
    func renameSpeaker(_ id: String, name: String) { edited { try $0.renameSpeaker(id, name: name) } }
    func assignSpeaker(_ dialogue: UUID, speaker: String?) { edited { try $0.assignSpeaker(dialogue, speaker: speaker) } }
    func analyzeSpeakers(expected: Int) {
        guard !busy, let project, !project.dialogues.isEmpty, mode == .edited else { return }
        let alert = NSAlert(); alert.messageText = "开始本地说话人分析？"
        alert.informativeText = "按原素材对白分析，不识别真实身份。短句、游戏配音、多人重叠可能分错，需要人工核对。完成后替换现有分人结果并清空撤销历史；文字和音频剪辑保留。建议先保存项目，以便保留上一版。"
        alert.addButton(withTitle: "开始分析"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        showSpeakers = false; pause(); busy = true; workID = UUID(); let id = workID
        status = "正在本地分析说话人；模型仅在独立进程内按需加载，可取消……"
        work = Task { [weak self] in
            do {
                let result = try await EditorMedia.background(priority: .userInitiated) { try await SpeakerAnalysis.run(project: project, expected: expected) }
                guard let self, self.workID == id, !self.closed, let history = self.history else { return }
                try history.installSpeakers(result.data)
                self.busy = false; self.dirty = true; self.lastExport = nil; self.refresh()
                self.speakerMetrics = String(format: "本次模型进程峰值 RSS %.1f MiB，推理 %.1f 秒；不含窗口和音轨预处理。", Double(result.peakRSSBytes) / 1048576, result.elapsedSeconds)
                let pending = result.data.assignments.values.filter { $0.speakerID == nil }.count
                self.status = "分人完成：\(result.data.speakers.count) 个候选说话人，\(pending) 句待确认。自动结果均需试听核对；模型进程已退出。"
            } catch {
                guard let self, self.workID == id, !self.closed else { return }
                self.busy = false; self.status = error is CancellationError ? "分人已取消，当前编辑保留。" : "分人失败，当前编辑保留：\(error.localizedDescription)"
            }
        }
    }
    func undo() { guard !busy, let history, history.canUndo else { return }; history.undo(); dirty = true; refresh(); status = "已撤销。" }
    func redo() { guard !busy, let history, history.canRedo else { return }; history.redo(); dirty = true; refresh(); status = "已重做。" }
    static func secondsText(_ ticks: Int64) -> String { String(format: "%.3f", EditorClock.seconds(ticks)) }

    func load(media: URL, subtitle: URL?) {
        guard !busy else { return }
        beginLoading()
        let id = workID
        work = Task { [weak self] in
            do {
                let loaded = try await EditorMedia.background(priority: .userInitiated) { () -> AudioEditProject in
                    let source = try await EditorMedia.inspect(media)
                    let text = try subtitle.map { try LearningStore.readSubtitle($0) }
                    return try AudioEditProject.make(source: source, subtitle: text)
                }
                guard let self, self.workID == id, !self.closed else { return }
                self.install(loaded, document: nil)
                self.status = "素材已载入。点击对白时间码定位，点耳机试听；片段默认保留相邻停顿和首尾声音。"
            } catch {
                guard let self, self.workID == id, !self.closed else { return }
                self.busy = false; self.status = "导入失败：\(error.localizedDescription)"
            }
        }
    }
    private func beginLoading() {
        pause(); work?.cancel(); workID = UUID(); busy = true
        status = "正在读取素材和校验原文件……"
        pendingRelink = nil; relinkAvailable = false
    }
    private func install(_ loaded: AudioEditProject, document: URL?) {
        contentID = UUID(); waveformTask?.cancel(); sourcePeaks = []; waveform = []
        history = try? AudioEditHistory(project: loaded)
        projectURL = document; dirty = false; busy = false; lastExport = nil
        selection = nil; mode = .edited; speakerMetrics = nil; refresh()
        waveformLoading = true
        let source = loaded.source, id = contentID
        waveformTask = Task { [weak self] in
            do {
                let peaks = try await EditorMedia.background(priority: .utility) { try await EditorMedia.waveform(source: source) }
                guard let self, self.contentID == id, !self.closed else { return }
                self.sourcePeaks = peaks
                self.waveform = EditorMedia.projectedWaveform(peaks, sourceDuration: source.durationTicks, map: self.map)
                self.waveformLoading = false
            } catch {
                guard let self, self.contentID == id, !self.closed else { return }
                self.waveformLoading = false
                if !Task.isCancelled { self.status = "波形未完成（仍可按对白编辑）：\(error.localizedDescription)" }
            }
        }
    }
    func chooseMedia() {
        guard !busy, confirmDiscardOrSave() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio, .movie]; panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.title = "导入音频或视频（只编辑音轨）"
        if panel.runModal() == .OK, let media = panel.url { load(media: media, subtitle: nil) }
    }
    func chooseSubtitle() {
        guard !busy, let source = project?.source, confirmDiscardOrSave() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "srt")!]; panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.title = "载入与原素材时间码对应的 SRT"
        if panel.runModal() == .OK, let subtitle = panel.url { load(media: URL(fileURLWithPath: source.path), subtitle: subtitle) }
    }
    func openProject() {
        guard !busy, confirmDiscardOrSave() else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.title = "打开听听兽剪辑项目（.tingting 或 .bak）"
        if panel.runModal() == .OK, let url = panel.url { loadProject(url) }
    }
    func loadProject(_ url: URL) {
        guard !busy else { return }
        beginLoading(); let id = workID
        work = Task { [weak self] in
            var decoded: AudioEditProject?
            do {
                var project = try AudioProjectFile.load(url); decoded = project
                let source = project.source
                project.source = try await EditorMedia.background(priority: .userInitiated) { try await EditorMedia.verify(source) }
                guard let self, self.workID == id, !self.closed else { return }
                self.install(project, document: url)
                self.status = "项目已恢复；关闭前的撤销历史不会恢复。"
            } catch {
                guard let self, self.workID == id, !self.closed else { return }
                self.busy = false; self.status = "项目打开失败：\(error.localizedDescription)"
                if let decoded { self.pendingRelink = (decoded, url); self.relinkAvailable = true }
            }
        }
    }
    func relink() {
        guard !busy, let pending = pendingRelink else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio, .movie]; panel.title = "重新定位项目的同一份原素材"
        guard panel.runModal() == .OK, let replacement = panel.url else { return }
        beginLoading(); let id = workID
        work = Task { [weak self] in
            do {
                var project = pending.0
                let source = project.source
                project.source = try await EditorMedia.background(priority: .userInitiated) { try await EditorMedia.verify(source, at: replacement) }
                guard let self, self.workID == id, !self.closed else { return }
                self.install(project, document: pending.1); self.dirty = true; self.status = "原素材已重新定位，请保存项目更新路径。"
            } catch {
                guard let self, self.workID == id, !self.closed else { return }
                self.busy = false; self.pendingRelink = pending; self.relinkAvailable = true; self.status = error.localizedDescription
            }
        }
    }
    @discardableResult func saveProject(asNew: Bool = false) -> Bool {
        guard !busy, let project else { return false }
        var target = asNew ? nil : projectURL
        if target == nil {
            let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "tingting") ?? .data]; panel.canCreateDirectories = true
            panel.nameFieldStringValue = URL(fileURLWithPath: project.source.path).deletingPathExtension().lastPathComponent + ".tingting"
            panel.title = "保存剪辑项目（不包含音频副本）"
            guard panel.runModal() == .OK else { return false }; target = panel.url
        }
        guard let target, target.standardizedFileURL != URL(fileURLWithPath: project.source.path).standardizedFileURL else { status = "不能把项目写入原素材文件。"; return false }
        do { try AudioProjectFile.save(project, to: target); projectURL = target; dirty = false; status = "项目已保存；音频仍引用原文件，撤销历史不写入项目。"; return true }
        catch { status = "保存失败，原有项目已保留：\(error.localizedDescription)"; return false }
    }
    func confirmDiscardOrSave() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "是否保存当前剪辑项目？"; alert.informativeText = "不保存会丢失这次编辑；原素材不会改变。"
        alert.addButton(withTitle: "保存项目"); alert.addButton(withTitle: "不保存"); alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveProject()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    func beginExport(mode: EditorTimelineMode, format: EditorAudioFormat, destination: URL, includeSpeakers: Bool = false) {
        guard !busy, let project else { return }
        pause(); busy = true; lastExport = nil; workID = UUID(); let id = workID
        status = "正在导出\(mode.title)的音频和字幕……"
        work = Task { [weak self] in
            do {
                let result = try await EditorMedia.background(priority: .userInitiated) { try await EditorMedia.export(project: project, mode: mode, format: format, destination: destination, includeSpeakers: includeSpeakers) }
                guard let self, self.workID == id, !self.closed else { return }
                self.busy = false; self.lastExport = result.folder
                self.status = "导出完成：\(mode.title)，需核对文字 \(result.needsReview) 条。原素材未修改。"
            } catch {
                guard let self, self.workID == id, !self.closed else { return }
                self.busy = false; self.status = error is CancellationError ? "导出已取消，原素材未修改。" : "导出失败，编辑仍保留：\(error.localizedDescription)"
            }
        }
    }
    func cancelWork() {
        work?.cancel(); work = nil; workID = UUID(); busy = false
        status = "任务已取消，当前编辑和原素材保留。"
    }
    func close() {
        closed = true; contentID = UUID(); compositionID = UUID(); workID = UUID()
        work?.cancel(); compositionTask?.cancel(); waveformTask?.cancel()
        work = nil; compositionTask = nil; waveformTask = nil
        busy = false; ready = false; waveformLoading = false; focusWindow = nil
        pause(); player.replaceCurrentItem(with: nil)
        if let periodic { player.removeTimeObserver(periodic); self.periodic = nil }
        itemObservation = nil; playbackObservation = nil
        sourcePeaks = []; waveform = []; rows = []; allRows = []; project = nil; history = nil
    }
}
