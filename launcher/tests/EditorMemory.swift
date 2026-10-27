import Foundation
import AVFoundation
import Darwin

@main struct EditorMemory {
    @MainActor static func main() async throws {
        let args=CommandLine.arguments
        if args.count == 3 && args[1] == "--make-long-fixture" {
            let folder=URL(fileURLWithPath:args[2]);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let audio=folder.appendingPathComponent("synthetic-61min.wav")
            guard !FileManager.default.fileExists(atPath:audio.path) else { print("Fixture already exists"); return }
            let settings:[String:Any]=[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000.0,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsNonInterleaved:false]
            var file:AVAudioFile?=try AVAudioFile(forWriting:audio,settings:settings,commonFormat:.pcmFormatInt16,interleaved:true)
            let format=file!.processingFormat
            var position=0
            let frames=3660*16000
            while position<frames {
                let n=min(4096,frames-position)
                let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(n))!;buffer.frameLength=AVAudioFrameCount(n)
                let pointer=buffer.int16ChannelData![0]
                for index in 0..<n {
                    let time=Double(position+index)/16000
                    pointer[index]=time.truncatingRemainder(dividingBy:6)>=1 && time.truncatingRemainder(dividingBy:6)<2 ? Int16(sin(time*2 * .pi*440)*5000) : 0
                }
                try file!.write(from:buffer);position+=n
            }
            file=nil
            var srt=""
            for i in 0..<610 {
                let start=Int64(i*6+1)*EditorClock.scale,end=start+EditorClock.scale
                srt += "\(i+1)\n\(EditorClock.timestamp(start)) --> \(EditorClock.timestamp(end))\n合成资源测试 \(i+1)\n\n"
            }
            try srt.write(to:folder.appendingPathComponent("synthetic-61min.srt"),atomically:true,encoding:.utf8)
            print("Made 61-minute synthetic fixture, 610 dialogue entries; resource testing only")
            return
        }
        guard args.count==4 else { throw EditorError.message("usage: editor-memory media subtitle-or-dash output-directory") }
        let output=URL(fileURLWithPath:args[3]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        func memory()->[String:UInt64] {
            var basic=mach_task_basic_info();var count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
            _=withUnsafeMutablePointer(to:&basic) { $0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) } }
            var vm=task_vm_info_data_t();var vmCount=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<natural_t>.size)
            _=withUnsafeMutablePointer(to:&vm) { $0.withMemoryRebound(to:integer_t.self,capacity:Int(vmCount)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&vmCount) } }
            return ["resident":UInt64(basic.resident_size),"physicalFootprint":UInt64(vm.phys_footprint)]
        }
        var checkpoints:[[String:Any]]=[],peakResident:UInt64=0,peakPhysical:UInt64=0
        func capture(_ stage:String) {
            let m=memory();peakResident=max(peakResident,m["resident"]!);peakPhysical=max(peakPhysical,m["physicalFootprint"]!)
            checkpoints.append(["stage":stage,"residentBytes":m["resident"]!,"physicalFootprintBytes":m["physicalFootprint"]!])
        }
        func sample() { let m=memory();peakResident=max(peakResident,m["resident"]!);peakPhysical=max(peakPhysical,m["physicalFootprint"]!) }
        let model=AudioWorkbenchModel();model.player.volume=0
        capture("idle_model")
        model.load(media:URL(fileURLWithPath:args[1]),subtitle:args[2]=="-" ? nil : URL(fileURLWithPath:args[2]))
        for _ in 0..<4000 {
            sample()
            if !model.busy && !model.waveformLoading && model.ready { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        guard model.ready,!model.busy,!model.waveformLoading,let initial=model.project else { throw EditorError.message("Memory test load failed: "+model.status) }
        capture("loaded_with_waveform")
        let duration=initial.source.durationTicks,clips=initial.clips.count
        for pass in 0..<5 {
            for _ in 0..<10 {
                model.selection=initial.order[0];model.moveSelected(1);model.moveSelected(-1)
            }
            for _ in 0..<200 {
                sample();if model.ready { break };try await Task.sleep(for:.milliseconds(10))
            }
            capture("after_\((pass+1)*20)_reorders")
        }
        if let row=model.rows.first {
            model.preview(row.id);try await Task.sleep(for:.milliseconds(350));sample();model.pause()
            if let second=model.rows.last { model.preview(second.id);try await Task.sleep(for:.milliseconds(350));sample();model.pause() }
        }
        capture("after_preview")
        model.beginExport(mode:.edited,format:.wav,destination:output)
        for _ in 0..<6000 {
            sample();if !model.busy { break };try await Task.sleep(for:.milliseconds(50))
        }
        guard !model.busy,let exported=model.lastExport else { throw EditorError.message("Memory export failed: "+model.status) }
        capture("after_wave_export")
        let wave=try FileManager.default.contentsOfDirectory(at:exported,includingPropertiesForKeys:nil).first { $0.pathExtension=="wav" }!
        let actual=EditorMedia.ticks(try await AVURLAsset(url:wave).load(.duration))
        guard abs(actual-duration)<=1 else { throw EditorError.message("Export duration mismatch") }
        model.close();try await Task.sleep(for:.seconds(1));capture("closed_model")
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        let report:[String:Any]=["passed":true,"durationSeconds":EditorClock.seconds(duration),"clips":clips,"reorderCommands":100,"peakSampledResidentBytes":peakResident,"peakSampledPhysicalFootprintBytes":peakPhysical,"processMaxRSSBytes":usage.ru_maxrss,"waveformPeakCount":2048,"checkpoints":checkpoints,"includesASRModel":false,"exportDurationTicks":actual,"timelineDurationTicks":duration]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try data.write(to:output.appendingPathComponent("memory.json"));print(String(data:data,encoding:.utf8)!)
    }
}
