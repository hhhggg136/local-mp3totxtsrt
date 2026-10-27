import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AudioWorkbenchView: View {
    @ObservedObject var model: AudioWorkbenchModel
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Label("音频工作台", systemImage: "waveform.path").font(.title2.bold())
                Text(model.project.map { URL(fileURLWithPath: $0.source.path).lastPathComponent } ?? "尚未导入素材")
                    .foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(model.dirty ? "有未保存修改" : model.projectURL == nil ? "项目未保存" : "项目已保存")
                    .font(.caption).foregroundColor(model.dirty ? .orange : .secondary)
            }
            HStack(spacing: 10) {
                Button("导入音视频…", action: model.chooseMedia)
                Button("载入 SRT…", action: model.chooseSubtitle).disabled(model.project == nil)
                Button("打开项目…", action: model.openProject)
                Button("保存项目") { model.saveProject() }.disabled(model.project == nil)
                    .keyboardShortcut("s", modifiers: .command)
                Button("另存…") { model.saveProject(asNew: true) }.disabled(model.project == nil)
                Spacer()
                Button("撤销", action: model.undo).disabled(!model.canUndo || model.mode == .original)
                    .keyboardShortcut("z", modifiers: .command)
                Button("重做", action: model.redo).disabled(!model.canRedo || model.mode == .original)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }.disabled(model.busy)
            HStack(spacing: 12) {
                Picker("当前时间线", selection: Binding(get: { model.mode }, set: model.setMode)) {
                    ForEach(EditorTimelineMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(width: 260).disabled(model.busy)
                Text(model.mode == .original ? "原声音、原时间码 · 只读预览" : "保留片段按当前顺序播放和导出")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if model.mode == .edited {
                    Toggle("显示已删除（\(model.deletedCount)）", isOn: $model.showDeleted)
                        .toggleStyle(.checkbox).disabled(model.busy)
                }
            }
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("对白与片段（\(model.rows.count)）").font(.headline)
                        Spacer()
                        Button("上移") { model.moveSelected(-1) }.disabled(model.selection == nil || model.mode == .original)
                        Button("下移") { model.moveSelected(1) }.disabled(model.selection == nil || model.mode == .original)
                        Button("删除片段", action: model.deleteSelected).disabled(model.selection == nil || model.mode == .original)
                    }.disabled(model.busy)
                    if model.project == nil {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("先导入音视频，再载入已有字幕。").font(.headline)
                            Text("也可以从字幕工具的识别结果直接进入工作台。点击对白定位，点耳机试听；删除和重排只修改剪辑结果。")
                                .foregroundColor(.secondary)
                        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        List(selection: $model.selection) {
                            ForEach(model.rows) { row in
                                WorkbenchClipRow(model: model, row: row).tag(row.id)
                            }
                        }
                        .onDeleteCommand { if model.mode == .edited { model.deleteSelected() } }
                        Text("分界默认采用相邻对白间隙的中点，仅为可调整建议；片段包含分界内的停顿和其他声音。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }.padding(.trailing, 10).frame(minWidth: 430)
                WorkbenchInspector(model: model).padding(.leading, 14).frame(minWidth: 300, idealWidth: 330, maxWidth: 380)
            }.frame(minHeight: 270, maxHeight: .infinity)
            Divider()
            WorkbenchWaveform(model: model).frame(height: 100)
            HStack(spacing: 14) {
                Button(model.playing ? "暂停" : "播放", systemImage: model.playing ? "pause.fill" : "play.fill", action: model.togglePlayback)
                    .disabled(!model.ready || model.busy).keyboardShortcut(.space, modifiers: [])
                Text("\(EditorClock.timestamp(model.positionTicks)) / \(EditorClock.timestamp(model.map.duration))")
                    .monospacedDigit().font(.callout)
                if model.mode == .edited, let source = model.map.sourceTime(at: min(model.positionTicks, max(0, model.map.duration - 1))) {
                    Text("原素材位置 \(EditorClock.timestamp(source))").font(.caption).foregroundColor(.secondary).monospacedDigit()
                }
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small)
                    Button("取消任务", action: model.cancelWork)
                }
                if let folder = model.lastExport { Button("打开导出文件夹") { NSWorkspace.shared.open(folder) } }
                Button("导出音频与字幕…") { model.pause(); model.showExport = true }
                    .buttonStyle(.borderedProminent).disabled(model.project == nil || model.busy)
            }
            HStack(alignment: .top) {
                Text(model.status).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                if model.relinkAvailable { Button("重新定位原素材…", action: model.relink) }
            }
            Text("非破坏编辑：原素材不会修改。试听、音频导出与字幕使用同一时间线；单音轨，视频只处理音轨。项目仅保存引用及当前编辑状态，最近 50 次撤销在关闭后清空。")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22).frame(minWidth: 1000, minHeight: 690)
        .sheet(isPresented: $model.showExport, onDismiss: { model.focusWindow?() }) { WorkbenchExportSheet(model: model) }
    }
}

private struct WorkbenchClipRow: View {
    @ObservedObject var model: AudioWorkbenchModel
    let row: WorkbenchRow
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button {
                    model.locate(row.id)
                } label: {
                    Text(row.preview.map { EditorClock.timestamp($0.start) + " → " + EditorClock.timestamp($0.end) } ?? "已从剪辑结果删除")
                        .font(.caption.monospacedDigit()).foregroundColor(.blue)
                }.buttonStyle(.plain).disabled(row.preview == nil || !model.ready || model.busy)
                Spacer()
                if row.needsReview { Label("文字需核对", systemImage: "exclamationmark.circle").font(.caption).foregroundColor(.orange) }
                if row.deleted, model.mode == .edited {
                    Button("恢复") { model.setDeleted(row.id, deleted: false) }.disabled(model.busy)
                } else {
                    Button("试听", systemImage: "ear") { model.preview(row.id) }.disabled(!model.ready || model.busy)
                }
            }
            if row.dialogues.isEmpty {
                Button(row.text) { model.locate(row.id) }.buttonStyle(.plain)
            } else {
                ForEach(row.dialogues) { dialogue in
                    HStack(alignment: .top) {
                        Button { model.locateDialogue(clip: row.id, dialogue: dialogue.id) } label: {
                            Text(dialogue.text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                .strikethrough(row.dialogueRanges[dialogue.id] == nil && model.mode == .edited)
                        }.buttonStyle(.plain).disabled(row.dialogueRanges[dialogue.id] == nil || !model.ready || model.busy)
                        if row.dialogues.count > 1 {
                            Button { model.locateDialogue(clip: row.id, dialogue: dialogue.id, audition: true) } label: { Image(systemName: "ear") }
                                .help("试听这一句").disabled(row.dialogueRanges[dialogue.id] == nil || !model.ready || model.busy)
                        }
                    }
                }
            }
            HStack {
                Text("原素材 \(EditorClock.timestamp(row.sourceRange.start)) · \(row.boundaryDescription)")
                if row.dialogues.count > 1 { Text("重叠对白合并块") }
                if row.trimmed { Text("已裁剪") }
            }.font(.caption2).foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .opacity(row.deleted && model.mode == .edited ? 0.5 : 1)
        .onDrag {
            guard model.mode == .edited, !model.busy else { return NSItemProvider() }
            return NSItemProvider(object: ("tingting-clip:" + row.id.uuidString) as NSString)
        }
        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
            guard model.mode == .edited, !model.busy, let provider = providers.first else { return false }
            let destination = row.id
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                guard let text, text.hasPrefix("tingting-clip:"), let id = UUID(uuidString: String(text.dropFirst(14))) else { return }
                Task { @MainActor in model.move(id, before: destination) }
            }
            return true
        }
    }
}

private struct WorkbenchInspector: View {
    @ObservedObject var model: AudioWorkbenchModel
    @State private var start = ""
    @State private var end = ""
    @State private var texts: [UUID: String] = [:]
    private func resetFields() {
        guard let row = model.selectedRow else { start = ""; end = ""; texts = [:]; return }
        start = AudioWorkbenchModel.secondsText(row.clipRange.start)
        end = AudioWorkbenchModel.secondsText(row.clipRange.end)
        texts = Dictionary(uniqueKeysWithValues: row.dialogues.map { ($0.id, $0.text) })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("片段边界与文字").font(.headline)
                if let row = model.selectedRow {
                    Text("音频片段范围（原素材秒数）").font(.caption).foregroundColor(.secondary)
                    HStack {
                        VStack(alignment: .leading) { Text("起点").font(.caption); TextField("秒", text: $start).textFieldStyle(.roundedBorder) }
                        VStack(alignment: .leading) { Text("终点").font(.caption); TextField("秒", text: $end).textFieldStyle(.roundedBorder) }
                    }
                    HStack {
                        Button("应用边界") { model.trimSelected(start: start, end: end); resetFields() }
                        Button("恢复初始边界") { model.resetTrim(); resetFields() }
                    }
                    Text("只能在这个片段的初始范围内裁剪；前后静音属于当前音频片段，也会参与重排。")
                        .font(.caption).foregroundColor(.secondary)
                    if row.needsReview {
                        Text("裁剪切入了对白，当前文字可能不再完整对应剩余声音。请试听并校对。")
                            .font(.callout).foregroundColor(.orange)
                        Button("文字已人工核对", action: model.confirmReview)
                    }
                    Divider()
                    ForEach(row.dialogues) { dialogue in
                        VStack(alignment: .leading, spacing: 7) {
                            TextField("对白文字", text: Binding(get: { texts[dialogue.id] ?? dialogue.text }, set: { texts[dialogue.id] = $0 }), axis: .vertical)
                                .textFieldStyle(.roundedBorder).lineLimit(2...6)
                            Button("保存这句文字") { model.saveText(dialogue.id, text: texts[dialogue.id] ?? dialogue.text); resetFields() }
                        }
                    }
                    if row.dialogues.isEmpty { Text("这个音频块尚未关联对白；仍可试听和裁剪。") }
                    if model.mode == .original { Text("原始模式只读。切换到剪辑结果后可修改边界和文字。") }
                } else { Text("选择左侧的一个对白或音频块。") }
                Spacer(minLength: 20)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(model.mode == .original || model.busy || model.selectedRow?.deleted == true)
        .onAppear(perform: resetFields)
        .onChange(of: model.selection) { _, _ in resetFields() }
        .onChange(of: model.project) { _, _ in resetFields() }
    }
}

private struct WorkbenchWaveform: View {
    @ObservedObject var model: AudioWorkbenchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(model.mode.title) · 简略波形（点击定位）").font(.caption).foregroundColor(.secondary)
                if model.waveformLoading { ProgressView().controlSize(.mini); Text("正在分段读取波形…").font(.caption).foregroundColor(.secondary) }
                Spacer()
            }
            GeometryReader { geometry in
                Canvas { context, size in
                    let mid = size.height / 2
                    if let range = model.selectedRow?.timelineRange, model.map.duration > 0 {
                        let x = CGFloat(range.start) / CGFloat(model.map.duration) * size.width
                        let width = CGFloat(range.duration) / CGFloat(model.map.duration) * size.width
                        context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(.blue.opacity(0.08)))
                    }
                    var path = Path()
                    if model.waveform.isEmpty { path.move(to: CGPoint(x: 0, y: mid)); path.addLine(to: CGPoint(x: size.width, y: mid)) }
                    for (index, peak) in model.waveform.enumerated() {
                        let x = CGFloat(index) / CGFloat(max(1, model.waveform.count - 1)) * size.width
                        let height = max(0.5, CGFloat(peak) * mid)
                        path.move(to: CGPoint(x: x, y: mid - height)); path.addLine(to: CGPoint(x: x, y: mid + height))
                    }
                    context.stroke(path, with: .color(model.mode == .original ? .gray : .blue), lineWidth: 1)
                    if model.map.duration > 0 {
                        let x = CGFloat(model.positionTicks) / CGFloat(model.map.duration) * size.width
                        var cursor = Path(); cursor.move(to: CGPoint(x: x, y: 0)); cursor.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(cursor, with: .color(.red), lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    guard !model.busy, model.ready, geometry.size.width > 0 else { return }
                    let position = min(1, max(0, value.location.x / geometry.size.width))
                    model.seek(to: Int64(position * CGFloat(model.map.duration)))
                })
            }
        }
    }
}

private struct WorkbenchExportSheet: View {
    @ObservedObject var model: AudioWorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: EditorTimelineMode
    @State private var format: EditorAudioFormat = .m4a
    init(model: AudioWorkbenchModel) { self.model = model; _selectedMode = State(initialValue: model.mode) }
    private var map: EditorTimelineMap { model.project?.timeline(selectedMode) ?? EditorTimelineMap(entries: []) }
    private var cues: [ProjectedDialogue] { model.project?.projected(map) ?? [] }
    private func chooseAndExport() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.title = "选择导出文件夹（将新建独立文件夹）"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.beginExport(mode: selectedMode, format: format, destination: destination)
        dismiss()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导出音频与字幕").font(.title2.bold())
            Picker("时间线", selection: $selectedMode) { ForEach(EditorTimelineMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            Text("本次导出：\(selectedMode.title)").font(.headline)
            Text("时长 \(EditorClock.timestamp(map.duration)) · 音频块 \(map.entries.count) · 字幕 \(cues.count) 条")
            Picker("音频格式", selection: $format) { ForEach(EditorAudioFormat.allCases) { Text($0.title).tag($0) } }
            if cues.isEmpty { Text("没有可导出的对白，只生成音频和核对说明。") }
            if cues.contains(where: \.needsTextReview) {
                Text("有 \(cues.filter(\.needsTextReview).count) 条对白被裁剪，文字需核对。导出保留当前文字，不自动猜测半句内容。")
                    .foregroundColor(.orange)
            }
            Text("音频、SRT 和带时间 TXT 共用同一时间线。每次新建文件夹，原素材与既有输出不变。WAV 保留最多两个声道，M4A 可能有编码帧粒度差异。")
                .font(.caption).foregroundColor(.secondary)
            HStack { Button("取消") { dismiss() }; Spacer(); Button("选择文件夹并导出", action: chooseAndExport).buttonStyle(.borderedProminent).disabled(map.duration == 0) }
        }.padding(26).frame(width: 500)
    }
}

@MainActor final class AudioWorkbenchWindow: NSObject, NSWindowDelegate {
    let model = AudioWorkbenchModel()
    let window: NSWindow
    private let didClose: () -> Void
    init(media: URL?, subtitle: URL?, didClose: @escaping () -> Void) {
        self.didClose = didClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 810), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "听听兽 · 音频工作台"; window.delegate = self; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 1000, height: 690)
        window.contentView = NSHostingView(rootView: AudioWorkbenchView(model: model))
        let host = window
        model.focusWindow = { [weak host] in host?.makeKeyAndOrderFront(nil) }
        window.center()
        show()
        if let media { model.load(media: media, subtitle: subtitle) }
    }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func requestClose() -> Bool {
        if model.busy {
            let alert = NSAlert(); alert.messageText = "任务正在进行"; alert.informativeText = "是否取消当前导入或导出并关闭工作台？"
            alert.addButton(withTitle: "继续等待"); alert.addButton(withTitle: "取消任务并关闭")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
            model.cancelWork()
        }
        return model.confirmDiscardOrSave()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose() }
    func windowWillClose(_ notification: Notification) { model.close(); didClose() }
}
