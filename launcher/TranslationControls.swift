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
            status = "正在检查本机翻译语言包……"
            model.status = status
            let source = Locale.Language(identifier: sourceLanguage)
            let target = Locale.Language(identifier: targetLanguage)
            Task { @MainActor in
                let availability = await LanguageAvailability().status(from: source, to: target)
                guard availability != .unsupported else {
                    status = "系统暂不支持这组翻译语言，原字幕已保留。"
                    model.status = status; model.busy = false; translationRunning = false
                    pendingCues = []; pendingSource = nil
                    return
                }
                status = availability == .installed ? "正在本地翻译……" : "首次使用需要系统下载语言包，请在系统提示中确认；取消后可重试。"
                model.status = status
                configuration = TranslationSession.Configuration(source: source, target: target)
            }
        } catch { status = error.localizedDescription; model.status = status }
    }
    @MainActor private func translate(_ session: TranslationSession) async {
        guard translationRunning, let original = pendingSource else { return }
        defer {
            pendingCues = []; pendingSource = nil; configuration = nil
            translationRunning = false; model.busy = false
        }
        do {
            // The system presents its own consent/download UI if assets are missing.
            try await session.prepareTranslation()
            var translated: [String] = []
            translated.reserveCapacity(pendingCues.count)
            for (index, cue) in pendingCues.enumerated() {
                try Task.checkCancellation()
                let response = try await session.translate(cue.text)
                guard !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SubtitleTranslation.error("第 \(index+1) 条翻译为空，未导出，请重试。")
                }
                translated.append(response.targetText)
                status = "正在翻译 \(index+1) / \(pendingCues.count) 条……"
                model.status = status
            }
            output = try SubtitleTranslation.export(cues: pendingCues, translated: translated, beside: original, target: pendingTarget, bilingual: pendingBilingual)
            status = pendingBilingual ? "已额外生成译文 TXT/SRT 和双语字幕，原字幕未修改。" : "已额外生成译文 TXT/SRT，原字幕未修改。"
        } catch {
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
            }
            if let output { Button("打开译文文件夹") { NSWorkspace.shared.open(output) } }
            Text(status).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            Text("译文单独保存；双语为原文在上、译文在下，时间码不变。\n使用系统本地翻译，首次可能需要下载语言包；长字幕逐条处理，译文请人工核对。")
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear { useRecognitionLanguage() }
        .onChange(of: model.language) { _, _ in useRecognitionLanguage() }
        .translationTask(configuration) { session in await translate(session) }
    }
}
