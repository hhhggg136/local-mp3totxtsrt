import AppKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

@available(macOS 15.0, *)
struct TranslationControls: View {
    @ObservedObject var model: Model
    @State private var sourceLanguage = "en"
    @State private var targetLanguage = "zh-Hans"
    @State private var bilingual = true
    @State private var selectedSubtitle: URL?
    @State private var configuration: TranslationSession.Configuration?
    @State private var pendingCues: [TranslationCue] = []
    @State private var pendingSource: URL?
    @State private var pendingTarget = "zh-Hans"
    @State private var pendingBilingual = true
    @State private var translationRunning = false
    @State private var jobID: UUID?
    @State private var operation: Task<Void, Never>?
    @State private var downloadMonitor: Task<Void, Never>?
    @State private var activeSession: TranslationSession?
    @State private var output: URL?
    @State private var status = "识别完成后可直接翻译，也可以选择已有的 SRT。原字幕会保留。"
    private var subtitle: URL? { selectedSubtitle ?? model.result?.appendingPathComponent("字幕.srt") }

    private func chooseSubtitle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt")!]
        panel.title = "选择原语言字幕 SRT"
        if panel.runModal() == .OK, let file = panel.url { selectedSubtitle = file; output = nil }
    }
    private func useRecognitionLanguage() {
        if model.language != "auto" {
            sourceLanguage = model.language == "zh" ? "zh-Hans" : model.language
            if sourceLanguage == targetLanguage { targetLanguage = sourceLanguage == "zh-Hans" ? "en" : "zh-Hans" }
        }
    }
    @MainActor private func start() {
        guard !model.busy, let subtitle else { return }
        guard sourceLanguage != targetLanguage else { status = "原文和译文语言相同，请选择另一种译文语言。"; return }
        do {
            pendingCues = try SubtitleTranslation.load(subtitle)
            pendingSource = subtitle
            pendingTarget = targetLanguage
            pendingBilingual = bilingual
            output = nil
            model.busy = true
            translationRunning = true
            let id = UUID()
            jobID = id
            status = "正在检查本机翻译语言包……"
            model.status = status
            let source = Locale.Language(identifier: sourceLanguage)
            let target = Locale.Language(identifier: targetLanguage)
            Task { @MainActor in
                let availability = await LanguageAvailability().status(from: source, to: target)
                guard jobID == id else { return }
                guard availability != .unsupported else {
                    status = "系统暂不支持这组翻译语言，原字幕已保留。"
                    model.status = status; finish(id)
                    return
                }
                status = availability == .installed ? "正在本地翻译……" : "首次使用需要系统下载语言包，请在系统提示中确认；取消后可重试。"
                model.status = status
                if #available(macOS 26.0, *), availability == .installed {
                    startInstalled(source: source, target: target, id: id)
                } else {
                    configuration = TranslationSession.Configuration(source: source, target: target)
                    // A download can finish after the system sheet was dismissed.
                    // Watch actual asset readiness instead of waiting indefinitely on that sheet's session.
                    if #available(macOS 26.0, *) {
                        downloadMonitor = Task { @MainActor in
                            for _ in 0..<450 {
                                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                                guard jobID == id else { return }
                                if await LanguageAvailability().status(from: source, to: target) == .installed {
                                    guard jobID == id else { return }
                                    startInstalled(source: source, target: target, id: id)
                                    return
                                }
                            }
                            guard jobID == id else { return }
                            status = "语言包准备超时，原字幕已保留。下载完成后可重试。"
                            model.status = status; finish(id)
                        }
                    }
                }
            }
        } catch { status = error.localizedDescription; model.status = status }
    }
    @MainActor private func finish(_ id: UUID) {
        guard jobID == id else { return }
        jobID = nil
        downloadMonitor?.cancel(); downloadMonitor = nil
        pendingCues = []; pendingSource = nil; configuration = nil
        activeSession = nil; operation = nil
        translationRunning = false; model.busy = false
    }
    @available(macOS 26.0, *)
    @MainActor private func startInstalled(source: Locale.Language, target: Locale.Language, id: UUID) {
        guard jobID == id, activeSession == nil else { return }
        downloadMonitor?.cancel(); downloadMonitor = nil
        let session = TranslationSession(installedSource: source, target: target)
        activeSession = session
        configuration = nil
        status = "正在本地翻译……"; model.status = status
        operation = Task { @MainActor in await translate(session, id: id, prepare: false) }
    }
    @MainActor private func prepare(_ session: TranslationSession) async {
        guard let id = jobID else { return }
        if #available(macOS 26.0, *) {
            do {
                try await session.prepareTranslation()
                guard jobID == id else { return }
                startInstalled(source: Locale.Language(identifier: sourceLanguage), target: Locale.Language(identifier: pendingTarget), id: id)
            } catch {
                // Cancelling the old sheet must not cancel the installed session that replaced it.
                guard jobID == id, activeSession == nil else { return }
                status = "翻译准备未完成，原字幕未修改。\(error.localizedDescription) 可重试。"
                model.status = status; finish(id)
            }
        } else {
            await translate(session, id: id, prepare: true)
        }
    }
    @MainActor private func cancel() {
        guard let id = jobID else { return }
        operation?.cancel()
        if #available(macOS 26.0, *) { activeSession?.cancel() }
        status = "翻译已取消，原字幕未修改；系统语言包可能继续在后台下载。"
        model.status = status
        finish(id)
    }
    @MainActor private func translate(_ session: TranslationSession, id: UUID, prepare: Bool) async {
        guard jobID == id, let original = pendingSource else { return }
        let cues = pendingCues, target = pendingTarget, dual = pendingBilingual
        defer { finish(id) }
        do {
            if prepare { try await session.prepareTranslation() }
            var translated: [String] = []
            translated.reserveCapacity(cues.count)
            for (index, cue) in cues.enumerated() {
                try Task.checkCancellation()
                let response = try await session.translate(cue.text)
                guard jobID == id else { return }
                guard !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SubtitleTranslation.error("第 \(index+1) 条翻译为空，未导出，请重试。")
                }
                translated.append(response.targetText)
                status = "正在翻译 \(index+1) / \(cues.count) 条……"
                model.status = status
            }
            try Task.checkCancellation()
            guard jobID == id else { return }
            output = try SubtitleTranslation.export(cues: cues, translated: translated, beside: original, target: target, bilingual: dual)
            status = dual ? "已额外生成译文 TXT/SRT 和双语字幕，原字幕未修改。" : "已额外生成译文 TXT/SRT，原字幕未修改。"
        } catch {
            guard jobID == id else { return }
            status = "翻译未完成，原字幕未修改。\(error.localizedDescription) 可重新点击翻译；如缺少语言包，请按系统提示下载。"
        }
        model.status = status
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("04  翻译与双语字幕").font(.headline)
            HStack {
                Picker("原文", selection: $sourceLanguage) {
                    Text("中文").tag("zh-Hans"); Text("English").tag("en"); Text("Español").tag("es")
                }
                Picker("译文", selection: $targetLanguage) {
                    Text("中文").tag("zh-Hans"); Text("English").tag("en"); Text("Español").tag("es")
                }
                Toggle("双语字幕", isOn: $bilingual)
            }.disabled(model.busy)
            HStack {
                Button("选择已有 SRT…", action: chooseSubtitle).disabled(model.busy)
                Text(subtitle?.lastPathComponent ?? "尚无字幕").font(.caption).lineLimit(1).help(subtitle?.path ?? "")
                if selectedSubtitle != nil, model.result != nil {
                    Button("使用本次识别") { selectedSubtitle = nil; useRecognitionLanguage() }.disabled(model.busy)
                }
                Spacer()
                Button("一键翻译", action: start).disabled(subtitle == nil || model.busy)
                if translationRunning { Button("取消翻译", action: cancel) }
            }
            if let output { Button("打开译文文件夹") { NSWorkspace.shared.open(output) } }
            Text(status).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            Text("译文单独保存；双语为原文在上、译文在下，时间码不变。\n使用系统本地翻译，首次可能需要下载语言包；长字幕逐条处理，译文请人工核对。")
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear { useRecognitionLanguage() }
        .onChange(of: model.language) { _, _ in useRecognitionLanguage() }
        .translationTask(configuration) { session in await prepare(session) }
    }
}
