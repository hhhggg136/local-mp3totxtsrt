import Foundation

@main struct SpeakerTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) { precondition(condition, name); checks += 1; print("PASS " + name) }
        let source = EditorSource(path: "/tmp/fixture.wav", durationTicks: 576000, fileSize: 0, sha256: String(repeating: "0", count: 64))
        let text = "1\n00:00:01,000 --> 00:00:02,000\n第一句\n\n2\n00:00:05,000 --> 00:00:06,000\n第二句\n\n3\n00:00:09,000 --> 00:00:10,000\n第三句\n"
        let project = try AudioEditProject.make(source: source, subtitle: text)
        let old = try JSONEncoder().encode(project)
        check(try JSONDecoder().decode(AudioEditProject.self, from: old) == project, "旧项目无需分人信息也能读取")
        let ids = project.dialogues.map(\.id)
        func vector(_ id: UUID, _ component: Int) -> SpeakerVector {
            var values = [Float](repeating: 0, count: 192); values[component] = 1
            return SpeakerVector(dialogue: id, values: values)
        }
        let vectors = [vector(ids[0], 0), vector(ids[1], 1), vector(ids[2], 0)]
        let data = try SpeakerClustering.group(dialogues: project.dialogues, vectors: vectors)
        check(data.speakers.map(\.id) == ["A", "B"] && data.label(ids[2]) == "A", "自动按声音分组，并按原始首次出现命名")
        let fixed = try SpeakerClustering.group(dialogues: project.dialogues, vectors: vectors, expected: 2)
        check(fixed.label(ids[0]) == fixed.label(ids[2]) && fixed.label(ids[0]) != fixed.label(ids[1]), "指定人数仍按声音归属而非轮流贴标签")
        let mixed = try SpeakerClustering.group(dialogues: project.dialogues, vectors: [vector(ids[0],0), vector(ids[0],1)])
        check(mixed.assignments[ids[0]]?.speakerID == nil && mixed.assignments[ids[0]]!.note.contains("多人"), "同一句窗口声音不一致时不强行归人")
        let empty = try SpeakerClustering.group(dialogues: project.dialogues, vectors: [])
        check(empty.speakers.isEmpty && empty.assignments.values.allSatisfy { $0.speakerID == nil }, "静音和过短对白不虚构说话人")
        do { _ = try SpeakerClustering.group(dialogues: project.dialogues, vectors: [SpeakerVector(dialogue: ids[0], values: [1])]); check(false,"拒绝错误向量") } catch { check(true,"拒绝错误向量") }
        let editor = try AudioEditHistory(project: project)
        editor.move(project.order[2], to: 0)
        try editor.installSpeakers(data)
        check(editor.project.order[0] == project.order[2] && !editor.canUndo && editor.project.schemaVersion == 2, "分析建立新基线但保留剪辑状态")
        try editor.renameSpeaker("A", name: "小王")
        check(editor.project.speakerData!.label(ids[0]) == "小王" && editor.project.speakerData!.label(ids[2]) == "小王" && editor.project.dialogues == project.dialogues, "批量改名不改对白正文")
        let beforeCorrection = editor.project
        try editor.assignSpeaker(ids[2], speaker: "B")
        check(editor.project.speakerData!.label(ids[2]) == "B" && editor.project.speakerData!.label(ids[0]) == "小王" && editor.project.speakerData!.assignments[ids[2]]!.manual, "单句纠正只影响该句")
        editor.undo(); check(editor.project == beforeCorrection, "单句归属可完整撤销")
        editor.redo(); check(editor.project.speakerData!.label(ids[2]) == "B", "单句归属可重做")
        try editor.addSpeaker(); check(editor.project.speakerData!.speakers.last?.id == "C", "漏分的人可新增 C")
        try editor.assignSpeaker(ids[0], speaker: "C"); try editor.renameSpeaker("C", name: "小陈")
        editor.setDeleted(project.order[1], true)
        let map = editor.project.timeline(.edited)
        let plain = try editor.project.subtitles(map: map)
        let named = try editor.project.subtitles(map: map, includeSpeakers: true)
        check(named.srt.contains("B：第三句") && named.srt.contains("小陈：第一句") && !named.srt.contains("第二句"), "重排删除后导出仍对应正确说话人")
        check(try SubtitleTranslation.parse(plain.srt).map(\.timing) == SubtitleTranslation.parse(named.srt).map(\.timing), "名字不改变字幕时间码")
        check(!plain.srt.contains("小陈") && named.txt.contains("小陈：第一句"), "可选择不带名字，并支持带名字 TXT")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tingting")
        defer { try? FileManager.default.removeItem(at: file) }
        try AudioProjectFile.save(editor.project, to: file)
        check(try AudioProjectFile.load(file) == editor.project, "保存重开保留名字、单句纠正和剪辑")
        for invalid in ["", "\n", "A：伪造对白", "姓名\n第二行", String(repeating:"字",count:41)] {
            do { try editor.renameSpeaker("A", name: invalid); check(false,"拒绝无效名字") } catch { check(true,"拒绝无效名字") }
        }
        do { try editor.assignSpeaker(ids[0], speaker: "Z"); check(false,"拒绝不存在的说话人") } catch { check(true,"拒绝不存在的说话人") }
        let manual = try AudioEditHistory(project: project)
        try manual.addSpeaker(); manual.undo()
        check(manual.project == project, "首次手动新增说话人也能完整撤销为旧格式")
        try manual.assignSpeaker(ids[0], speaker: nil); manual.undo()
        check(manual.project == project, "首次设为待确认可完整撤销")
        print("\(checks) speaker checks passed")
    }
}
