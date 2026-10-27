import Foundation
import AVFoundation

@main struct EditorOffsetIntegration {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw EditorError.message("usage: editor-offset-integration tone-fixture.wav decoder-binary") }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("editor-offset-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let asset=AVURLAsset(url:URL(fileURLWithPath:CommandLine.arguments[1]))
        let track=try await asset.loadTracks(withMediaType:.audio)[0]
        let hint=try await track.load(.formatDescriptions)[0]
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:nil);reader.add(output)
        let delayed=root.appendingPathComponent("delayed-audio.mov")
        let writer=try AVAssetWriter(outputURL:delayed,fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.audio,outputSettings:nil,sourceFormatHint:hint)
        input.expectsMediaDataInRealTime=false
        writer.add(input)
        guard writer.startWriting(),reader.startReading() else { throw writer.error ?? reader.error ?? EditorError.message("Fixture creation failed") }
        writer.startSession(atSourceTime:.zero)
        while let sample=output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample)>0, CMSampleBufferGetDataBuffer(sample) != nil else { continue }
            var count:CMItemCount=0
            _ = CMSampleBufferGetSampleTimingInfoArray(sample,entryCount:0,arrayToFill:nil,entriesNeededOut:&count)
            guard count > 0 else { throw EditorError.message("Fixture timing count missing") }
            var timing=[CMSampleTimingInfo](repeating:CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:.invalid,decodeTimeStamp:.invalid),count:count)
            guard CMSampleBufferGetSampleTimingInfoArray(sample,entryCount:count,arrayToFill:&timing,entriesNeededOut:&count)==noErr else { throw EditorError.message("Fixture timing read failed") }
            for i in timing.indices {
                timing[i].presentationTimeStamp=CMTimeAdd(timing[i].presentationTimeStamp,CMTime(seconds:2,preferredTimescale:48000))
                if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp=CMTimeAdd(timing[i].decodeTimeStamp,CMTime(seconds:2,preferredTimescale:48000)) }
            }
            var shifted:CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator:kCFAllocatorDefault,sampleBuffer:sample,sampleTimingEntryCount:timing.count,sampleTimingArray:&timing,sampleBufferOut:&shifted)==noErr,let shifted else { throw EditorError.message("Fixture shifting failed") }
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? EditorError.message("Fixture writer stopped") }
                try await Task.sleep(for:.milliseconds(1))
            }
            guard input.append(shifted) else { throw writer.error ?? EditorError.message("Fixture write failed") }
        }
        input.markAsFinished();await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? EditorError.message("Fixture failed") }
        let source=try await EditorMedia.inspect(delayed)
        let srt="1\n00:00:03,000 --> 00:00:04,000\n第一段\n\n2\n00:00:07,000 --> 00:00:08,000\n第二段\n\n3\n00:00:11,000 --> 00:00:12,000\n第三段\n"
        let project=try AudioEditProject.make(source:source,subtitle:srt)
        let exported=try await EditorMedia.export(project:project,mode:.original,format:.wav,destination:root)
        precondition(abs(EditorClock.seconds(exported.durationTicks)-14)<1.0/48000)
        func amplitude(_ file:URL,at seconds:Double)throws->Double {
            let audio=try AVAudioFile(forReading:file)
            audio.framePosition=AVAudioFramePosition(seconds*audio.processingFormat.sampleRate)
            let buffer=AVAudioPCMBuffer(pcmFormat:audio.processingFormat,frameCapacity:4096)!
            try audio.read(into:buffer)
            let data=buffer.floatChannelData![0];var squared:Double=0
            for i in 0..<Int(buffer.frameLength) { squared+=Double(data[i]*data[i]) }
            return sqrt(squared/Double(buffer.frameLength))
        }
        let gap=try amplitude(exported.audio,at:1.2),tone=try amplitude(exported.audio,at:3.2)
        precondition(gap<0.001 && tone>0.1,"Original audio track offset lost during export")
        let decoded=root.appendingPathComponent("decoded.wav")
        let process=Process();process.executableURL=URL(fileURLWithPath:CommandLine.arguments[2]);process.arguments=[delayed.path,decoded.path]
        let log=root.appendingPathComponent("decoder.log");FileManager.default.createFile(atPath:log.path,contents:nil)
        let handle=try FileHandle(forWritingTo:log);process.standardOutput=handle;process.standardError=handle
        try process.run();process.waitUntilExit();try handle.close()
        guard process.terminationStatus==0 else { throw EditorError.message("Decoder fixture failed") }
        let decodedGap=try amplitude(decoded,at:1.2),decodedTone=try amplitude(decoded,at:3.2)
        precondition(decodedGap<0.001 && decodedTone>0.1,"Decoder removed the source track's two-second gap; recognition timestamps would seek early")
        print("PASS two-second leading audio gap preserved in export and recognition decoder")
        print("FIXTURE="+delayed.path)
    }
}
