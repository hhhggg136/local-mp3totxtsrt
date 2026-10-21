import AppKit
import SwiftUI

let root: URL = {
    if let configured = ProcessInfo.processInfo.environment["LOCAL_SUBTITLE_ROOT"] { return URL(fileURLWithPath: configured) }
    return Bundle.main.bundleURL.deletingLastPathComponent()
}()

struct Recognition {
    static func process(_ executable: URL, _ arguments: [String], log: URL) throws {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.standardOutput = handle
        task.standardError = handle
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "Subtitle", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "处理失败，请查看输出文件夹内的日志。"])
        }
    }
    static func run(source: URL, destination: URL, project: String = "默认项目", useLearning: Bool = true) throws -> URL {
        let fm = FileManager.default
        let store = try LearningStore(url: LearningStore.defaultURL)
        let prompt = useLearning ? try store.prompt(project: project) : ""
        let folder = destination.appendingPathComponent("字幕_" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "_" + UUID().uuidString.prefix(6))
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = fm.temporaryDirectory.appendingPathComponent("local-subtitles-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let wav = temporary.appendingPathComponent("audio.wav")
        try process(root.appendingPathComponent(".local/bin/inspect"), [source.path, wav.path], log: folder.appendingPathComponent("音频处理.log"))
        let prefix = folder.appendingPathComponent("识别原始结果")
        let arguments = [root.appendingPathComponent(".local/models/ggml-small.bin").path,
                         root.appendingPathComponent(".local/models/ggml-silero-v6.2.0.bin").path,
                         wav.path, prefix.appendingPathExtension("json").path, prompt]
        try process(root.appendingPathComponent(".local/bin/source-timed-whisper"), arguments, log: folder.appendingPathComponent("识别.log"))
        let bytes = try Data(contentsOf: prefix.appendingPathExtension("json"))
        let decoded = String(decoding: bytes, as: UTF8.self)
        let object = try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any]
        guard let rows = object?["transcription"] as? [[String: Any]] else { throw NSError(domain: "Subtitle", code: 1, userInfo: [NSLocalizedDescriptionKey: "识别结果格式无法读取，原始结果已保留。"]) }
        var srt = "", txt = "", count = 0, invalid = 0
        func timestamp(_ milliseconds: Int) -> String {
            String(format: "%02d:%02d:%02d,%03d", milliseconds / 3600000, milliseconds / 60000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
        }
        for row in rows {
            let text = (row["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let offsets = row["offsets"] as? [String: Any], let start = offsets["from"] as? Int, let end = offsets["to"] as? Int, start >= 0, end > start, !text.isEmpty else { invalid += 1; continue }
            count += 1
            srt += "\(count)\n\(timestamp(start)) --> \(timestamp(end))\n\(text)\n\n"
            txt += "[\(timestamp(start)) → \(timestamp(end))] \(text)\n"
        }
        guard count > 0 else { throw NSError(domain: "Subtitle", code: 2, userInfo: [NSLocalizedDescriptionKey: "没有识别出带有效时间码的对白，原始结果已保留。"]) }
        try srt.write(to: folder.appendingPathComponent("字幕.srt"), atomically: true, encoding: .utf8)
        try txt.write(to: folder.appendingPathComponent("对白.txt"), atomically: true, encoding: .utf8)
        try srt.write(to: folder.appendingPathComponent("学习基准.srt"), atomically: true, encoding: .utf8)
        let metadata: [String: Any] = ["project": project, "learningEnabled": useLearning, "prompt": prompt, "version": "0.2.2", "alignment": "source-vad-islands-v1"]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("本次词库.json"), options: .atomic)
        let note = "本地中文识别结果，文字与时间码需人工核对。\n时间码采用原音频人声区间，停顿不拼接。短语边界依赖人声检测，轻声与背景音乐仍需核对。\n字幕条数：\(count)\n无效或空白片段：\(invalid)（未写入字幕，详见原始结果）\n编码替换字符数：\(decoded.filter { $0 == "\u{fffd}" }.count)（出现 � 的对白需要人工检查）\n原素材未修改。\n"
        try note.write(to: folder.appendingPathComponent("核对说明.txt"), atomically: true, encoding: .utf8)
        return folder
    }
}

final class Model: ObservableObject {
    @Published var project = "默认项目"
    @Published var useLearning = true
    @Published var showLearning = false
    @Published var source: URL?
    @Published var destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    @Published var busy = false
    @Published var status = "选择音视频后，生成带时间码的中文对白与 SRT 字幕。"
    @Published var result: URL?
    func chooseFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.title = "选择要识别的音频或视频"
        if panel.runModal() == .OK { source = panel.url; result = nil }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.title = "选择字幕保存位置"
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
    func start() {
        guard let source, !busy else { return }
        let destination = destination
        let project = project, useLearning = useLearning
        busy = true; result = nil; status = "正在本地识别，请保持窗口打开……"
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try Recognition.run(source: source, destination: destination, project: project, useLearning: useLearning) }
            DispatchQueue.main.async {
                self.busy = false
                switch outcome {
                case .success(let folder): self.result = folder; self.status = "字幕已生成。请核对错字、断句和时间码。"
                case .failure(let error): self.status = error.localizedDescription
                }
            }
        }
    }
}
struct WorkspaceView: View {
    @ObservedObject var model: Model

    private func sectionTitle(_ number: String, _ title: String) -> some View {
        HStack(spacing: 10) {
            Text(number).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            Text(title).font(.headline)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("本地字幕工具", systemImage: "waveform").font(.title.bold())
                    Text("音视频转中文对白 · TXT / SRT").foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("01", "素材")
                    HStack(alignment: .center, spacing: 16) {
                        Button("选择音视频…", action: model.chooseFile)
                        Text(model.source?.lastPathComponent ?? "尚未选择素材")
                            .lineLimit(2).truncationMode(.middle)
                            .foregroundColor(model.source == nil ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.disabled(model.busy)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("02", "项目与词库")
                    HStack(spacing: 16) {
                        TextField("项目名称", text: $model.project)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .accessibilityLabel("项目名称")
                        Toggle("使用已确认词库", isOn: $model.useLearning)
                        Spacer(minLength: 0)
                        Button("管理词库…") { model.showLearning = true }
                    }
                    Text("仅使用同名项目中已确认的词语；可随时关闭提示。")
                        .font(.caption).foregroundColor(.secondary)
                }.disabled(model.busy)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("03", "保存位置")
                    HStack(alignment: .center, spacing: 16) {
                        Text(model.destination.path)
                            .font(.callout).foregroundColor(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("更改…", action: model.chooseFolder)
                    }
                }.disabled(model.busy)

                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Button("开始识别", action: model.start)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.source == nil || model.busy)
                        if model.busy {
                            ProgressView().controlSize(.small)
                            Text("正在本地识别…").foregroundColor(.secondary)
                        }
                        if let result = model.result {
                            Button("打开字幕文件夹") { NSWorkspace.shared.open(result) }
                        }
                    }
                    Text(model.source == nil && !model.busy ? "先选择一个音频或视频文件，随后即可开始识别。" : model.status)
                        .font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                        .padding(14)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(8)
                }

                Text("使用本机 small 模型和人声检测，素材不会上传。\n完成后请核对文字、断句和时间码。音频剪辑和对白重排尚未开放。")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 680, minHeight: 610)
        .tint(.blue)
        .sheet(isPresented: $model.showLearning) { LearningPanel(model: model) }
    }
}
final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let model = Model()
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 690), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "本地字幕工具"; window.delegate = self
        window.contentMinSize = NSSize(width: 680, height: 610)
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy {
            let alert = NSAlert(); alert.messageText = "识别正在进行"; alert.informativeText = "请等待识别完成后再关闭窗口。"; alert.runModal(); return false
        }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { model.busy ? .terminateCancel : .terminateNow }
}
@main struct Launcher {
    static func main() {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--self-test" {
            do { print(try Recognition.run(source: URL(fileURLWithPath: CommandLine.arguments[2]), destination: URL(fileURLWithPath: CommandLine.arguments[3])).path) }
            catch { fputs("\(error)\n", stderr); exit(1) }
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = Delegate(); application.delegate = delegate
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let submenu = NSMenu(); submenu.addItem(withTitle: "退出本地字幕工具", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = submenu
        application.mainMenu = menu
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
