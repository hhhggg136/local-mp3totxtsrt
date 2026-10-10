import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LearningPanel: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var baseline: URL?
    @State private var corrected: URL?
    @State private var entries: [LearningEntry] = []
    @State private var selection: Int64?
    @State private var editedWord = ""
    @State private var message = "先选择本工具生成的学习基准，再导入你校对好的 SRT。"
    @State private var importing = false
    @State private var scene: String?
    private var selected: LearningEntry? { entries.first { $0.id == selection } }
    @discardableResult private func perform(_ operation: (LearningStore) throws -> Void) -> Bool {
        do {
            let store = try LearningStore(url: LearningStore.defaultURL)
            try operation(store)
            entries = try store.entries(project: model.project)
            return true
        } catch { message = error.localizedDescription; return false }
    }
    private func choose(correctedFile: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt")!]
        panel.title = correctedFile ? "选择校对好的 SRT" : "选择识别时保存的学习基准 SRT"
        if panel.runModal() == .OK, let file = panel.url {
            if correctedFile {
                corrected = file
                do { scene = LearningStore.suggestScene(try LearningStore.readSubtitle(file)) }
                catch { message = error.localizedDescription }
            } else { baseline = file }
        }
    }
    private func learn() {
        guard let baseline, let corrected else { return }
        importing = true
        let project = model.project
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> ImportSummary in
                try autoreleasepool {
                    let store = try LearningStore(url: LearningStore.defaultURL)
                    return try store.importPair(original: LearningStore.readSubtitle(baseline), corrected: LearningStore.readSubtitle(corrected), project: project)
                }
            }
            DispatchQueue.main.async {
                importing = false
                switch result {
                case .success(let summary):
                    message = summary.duplicate ? "这份校对版本已学习过，没有重复计数。" : "已记录 \(summary.learned) 处候选纠错，\(summary.unmatched) 条时间区间无法唯一对应，已跳过。请核对候选词后确认使用。"
                    perform { _ in }
                case .failure(let error): message = error.localizedDescription
                }
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地校对学习库").font(.title2.bold())
            HStack { Text("项目：\(model.project)"); Spacer(); Button("完成") { dismiss() }.disabled(importing) }
            HStack { Button("选择学习基准…") { choose(correctedFile: false) }; Text(baseline?.lastPathComponent ?? "未选择").lineLimit(1) }.disabled(importing)
            HStack { Button("导入校对字幕…") { choose(correctedFile: true) }; Text(corrected?.lastPathComponent ?? "未选择").lineLimit(1) }.disabled(importing)
            if let scene { Text("建议场景：\(scene)（根据关键词推测；词库仍只归当前项目）").font(.caption).foregroundColor(.secondary) }
            HStack { Button("学习本次修改", action: learn).disabled(baseline == nil || corrected == nil || importing); if importing { ProgressView().controlSize(.small) } }
            Text(message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(entries) { entry in
                    HStack {
                        Text(entry.enabled ? "已确认" : "待核对").foregroundColor(entry.enabled ? .green : .secondary)
                        Text("\(entry.wrong) → \(entry.right)")
                        Spacer()
                        Text("\(entry.count) 次").foregroundColor(.secondary)
                    }.tag(entry.id)
                }
            }.frame(minHeight: 180).disabled(importing)
            if let entry = selected {
                HStack {
                    TextField("正确词语", text: $editedWord).textFieldStyle(.roundedBorder)
                    Button("保存修改") { if perform({ try $0.edit(id: entry.id, right: editedWord) }) { message = "词语已修改，请重新确认使用。" } }
                    Button(entry.enabled ? "停用" : "确认使用") { perform { try $0.approve(id: entry.id, enabled: !entry.enabled) } }
                    Button("删除") { if perform({ try $0.delete(id: entry.id) }) { selection = nil } }
                }.disabled(importing)
            }
            Text("仅匹配相同且唯一的时间区间；合并、拆分、移动时间码的句子先跳过。\n只保存短词纠错和次数，不保存音频或完整字幕；最多显示 200 条候选，每项目最多 5000 条。\n确认的词仅作为识别提示，不自动替换字幕；可在主窗口关闭词库。").font(.caption).foregroundColor(.secondary)
        }.padding(24).frame(width: 720, height: 570)
        .onAppear {
            if let result = model.result { baseline = result.appendingPathComponent("学习基准.srt") }
            perform { _ in }
        }
        .onChange(of: selection) { _, id in editedWord = entries.first { $0.id == id }?.right ?? "" }
    }
}
