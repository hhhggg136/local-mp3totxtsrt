import Foundation
import AVFoundation

@main struct EditorAudioIntegration {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingting-editor-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let audio = root.appendingPathComponent("three-tones.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        var writer: AVAudioFile? = try AVAudioFile(forWriting: audio, settings: format.settings)
        var cursor = 0
        while cursor < 12 * 48000 {
            let count = min(4096, 12 * 48000 - cursor)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            let pointer = buffer.floatChannelData![0]
            let right = buffer.floatChannelData![1]
            for i in 0..<count {
                let second = Double(cursor + i) / 48000
                let frequency: Double = (1..<2).contains(second) ? 440 : (5..<6).contains(second) ? 660 : (9..<10).contains(second) ? 880 : 0
                pointer[i] = frequency == 0 ? 0 : Float(0.35 * sin(2 * .pi * frequency * second))
                right[i] = frequency == 0 ? 0 : Float(0.35 * sin(2 * .pi * (frequency + 220) * second))
            }
            try writer!.write(from: buffer); cursor += count
        }
        writer = nil
        let originalHash = try EditorMedia.fingerprint(audio)
        let source = try await EditorMedia.inspect(audio)
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n第一段\n\n2\n00:00:05,000 --> 00:00:06,000\n第二段\n\n3\n00:00:09,000 --> 00:00:10,000\n第三段\n"
        let project = try AudioEditProject.make(source: source, subtitle: srt)
        let engine = try AudioEditHistory(project: project)
        engine.move(project.clips[2].id, to: 0)
        engine.setDeleted(project.clips[1].id, true)
        let peaks = try await EditorMedia.waveform(source: source)
        precondition(peaks.count == 2048 && peaks.max()! > 0.3)
        var results: [[String: Any]] = []
        func measure(_ file: URL, start: Double, duration: Double, channel: Int = 0) throws -> (Double, Double) {
            let input = try AVAudioFile(forReading: file)
            let sampleRate = input.processingFormat.sampleRate
            input.framePosition = AVAudioFramePosition(start * sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(duration * sampleRate))!
            try input.read(into: buffer)
            let values = buffer.floatChannelData![channel]
            let count = Int(buffer.frameLength)
            var crossing = 0, squared: Double = 0
            for i in 0..<count {
                squared += Double(values[i] * values[i])
                if i > 0, values[i-1] <= 0, values[i] > 0 { crossing += 1 }
            }
            return (Double(crossing) * sampleRate / Double(count), sqrt(squared / Double(count)))
        }
        for format in EditorAudioFormat.allCases {
            let result = try await EditorMedia.export(project: engine.project, mode: .edited, format: format, destination: root)
            precondition(abs(EditorClock.seconds(result.durationTicks) - 8) <= (format == .wav ? 1.0/48000 : 0.05))
            let first = try measure(result.audio, start: 1.6, duration: 0.6)
            let second = try measure(result.audio, start: 5.6, duration: 0.6)
            let silence = try measure(result.audio, start: 3.1, duration: 0.5)
            precondition(abs(first.0-880) < 5 && abs(second.0-440) < 5 && first.1 > 0.1 && second.1 > 0.1)
            let rightFirst = try measure(result.audio, start: 1.6, duration: 0.6, channel: 1)
            let rightSecond = try measure(result.audio, start: 5.6, duration: 0.6, channel: 1)
            precondition(abs(rightFirst.0 - 1100) < 5 && abs(rightSecond.0 - 660) < 5)
            precondition(silence.1 < 0.001)
            let actualSRT = try String(contentsOf: result.subtitle!, encoding: .utf8)
            precondition(actualSRT == "1\n00:00:01,500 --> 00:00:02,500\n第三段\n\n2\n00:00:05,500 --> 00:00:06,500\n第一段\n\n")
            results.append(["format": format.rawValue, "duration": EditorClock.seconds(result.durationTicks), "firstToneHz": first.0, "secondToneHz": second.0, "silenceRMS": silence.1, "subtitleOrderMatchesAudio": true, "stereoChannelsPreserved": true])
            print("PASS \(format.rawValue): decoded tones 880 → 440 Hz, 8 seconds, preserved silence and SRT")
        }
        let original = try await EditorMedia.export(project: engine.project, mode: .original, format: .wav, destination: root)
        precondition(abs(EditorClock.seconds(original.durationTicks)-12) < 1.0/48000)
        let originalTone = try measure(original.audio,start:5.1,duration:0.5)
        precondition(originalTone.0 > 655)
        let projectURL=root.appendingPathComponent("project.tingting")
        try AudioProjectFile.save(engine.project,to:projectURL)
        let model=AudioWorkbenchModel();model.player.volume=0
        model.loadProject(projectURL)
        for _ in 0..<200 {
            if model.ready && !model.busy { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        precondition(model.ready && !model.busy,model.status)
        let firstID=engine.project.order[0]
        model.locate(firstID)
        try await Task.sleep(for:.milliseconds(200))
        precondition(abs(EditorClock.seconds(model.positionTicks)-1.5)<0.06)
        model.preview(firstID)
        try await Task.sleep(for:.milliseconds(1500))
        precondition(!model.playing && abs(EditorClock.seconds(model.positionTicks)-2.5)<0.1,"Single-line preview failed to stop at end")
        model.close()
        let replacement = root.appendingPathComponent("relocated.wav")
        try FileManager.default.copyItem(at: audio, to: replacement)
        let verifiedReplacement = try await EditorMedia.verify(source, at: replacement)
        precondition(verifiedReplacement.path == replacement.path)
        let wrong = root.appendingPathComponent("different.wav")
        try FileManager.default.copyItem(at: audio, to: wrong)
        let handle = try FileHandle(forWritingTo: wrong)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0, 0])); try handle.close()
        var refused = false
        do { _ = try await EditorMedia.verify(source, at: wrong) } catch { refused = true }
        precondition(refused, "Different source must be rejected")
        let cancellationRoot = root.appendingPathComponent("cancelled")
        try FileManager.default.createDirectory(at: cancellationRoot, withIntermediateDirectories: false)
        let exportTask = Task {
            try await EditorMedia.background(priority: .utility) {
                try await EditorMedia.export(project: project, mode: .edited, format: .wav, destination: cancellationRoot)
            }
        }
        exportTask.cancel()
        var cancelled = false
        do { _ = try await exportTask.value } catch { cancelled = true }
        let remainingCancelledFiles = try FileManager.default.contentsOfDirectory(atPath: cancellationRoot.path)
        precondition(cancelled && remainingCancelledFiles.isEmpty)
        let failedModel = AudioWorkbenchModel(); failedModel.player.volume = 0
        failedModel.loadProject(root.appendingPathComponent("missing.tingting"))
        for _ in 0..<100 {
            if !failedModel.busy { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(!failedModel.busy && failedModel.project == nil && failedModel.status.contains("失败"))
        failedModel.load(media: audio, subtitle: nil)
        for _ in 0..<200 {
            if failedModel.ready && !failedModel.busy { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(failedModel.ready && failedModel.project?.clips.count == 1)
        failedModel.close()
        print("PASS matching-source relink, mismatched-source rejection, cancellation cleanup and failed-import retry")
        let afterHash = try EditorMedia.fingerprint(audio)
        precondition(afterHash == originalHash)
        let output: [String: Any] = ["passed":true,"fixture":"three synthetic tones, 12 seconds, first/last swapped, middle deleted","exports":results,"originalExportSeconds":12,"clickSeekSeconds":1.5,"singleLineStoppedAtSeconds":2.5,"sourceUnchanged":true,"relinkAndFailureRecovery":true,"cancellationCleanup":true]
        try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("report.json"))
        print("PASS click positioning, single-line stop, original timeline, save/reopen and source hash")
        print("REPORT="+root.appendingPathComponent("report.json").path)
    }
}
