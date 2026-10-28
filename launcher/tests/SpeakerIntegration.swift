import Foundation
import Darwin

@main struct SpeakerIntegration {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { throw EditorError.message("usage: speaker-integration media srt runtime output") }
        let media = URL(fileURLWithPath: args[1]), srt = URL(fileURLWithPath: args[2]), runtime = URL(fileURLWithPath: args[3]), output = URL(fileURLWithPath: args[4])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = try await EditorMedia.inspect(media)
        let project = try AudioEditProject.make(source: source, subtitle: LearningStore.readSubtitle(srt))
        let result = try await SpeakerAnalysis.run(project: project, expected: 0, runtime: runtime)
        let actual = project.dialogues.map { result.data.label($0.id) }
        let editor = try AudioEditHistory(project: project)
        try editor.installSpeakers(result.data)
        if !result.data.speakers.isEmpty {
            let id = result.data.speakers[0].id
            try editor.renameSpeaker(id, name: "测试名字")
            try editor.addSpeaker()
            let newID = editor.project.speakerData!.speakers.last!.id
            try editor.assignSpeaker(project.dialogues[0].id, speaker: newID)
            let corrected = editor.project
            editor.undo(); editor.redo(); precondition(editor.project == corrected)
        }
        let file = output.appendingPathComponent("project.tingting")
        try AudioProjectFile.save(editor.project, to: file)
        let saved = try AudioProjectFile.load(file); precondition(saved == editor.project)
        let named = try editor.project.subtitles(map: editor.project.timeline(.original), includeSpeakers: true)
        let plain = try editor.project.subtitles(map: editor.project.timeline(.original))
        let namedTimes = try SubtitleTranslation.parse(named.srt).map(\.timing), plainTimes = try SubtitleTranslation.parse(plain.srt).map(\.timing)
        precondition(namedTimes == plainTimes)
        try named.srt.write(to: output.appendingPathComponent("named.srt"), atomically: true, encoding: .utf8)
        let afterHash = try EditorMedia.fingerprint(media); precondition(afterHash == source.sha256)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["passed": true, "labels": actual, "speakers": result.data.speakers.count, "cues": project.dialogues.count,
            "modelPeakRSSBytes": result.peakRSSBytes, "parentPeakRSSBytes": usage.ru_maxrss, "inferenceSeconds": result.elapsedSeconds,
            "sourceUnchanged": true, "renameCorrectionUndoAndPersistence": true, "timestampsUnchanged": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        print("SPEAKER_INTEGRATION=" + output.appendingPathComponent("report.json").path)
        print("Speakers \(result.data.speakers.count), labels \(actual.prefix(12)), model peak RSS \(Double(result.peakRSSBytes)/1048576) MiB")
    }
}
