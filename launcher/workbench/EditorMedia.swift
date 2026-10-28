import Foundation
@preconcurrency import AVFoundation
import CryptoKit

struct AudioEditExportResult: Sendable {
    var folder: URL
    var audio: URL
    var subtitle: URL?
    var durationTicks: Int64
    var needsReview: Int
}
enum EditorAudioFormat: String, CaseIterable, Identifiable, Sendable {
    case m4a, wav
    var id: String { rawValue }
    var title: String { self == .m4a ? "M4A（较小）" : "WAV（无压缩）" }
}
enum EditorMedia {
    static func background<T: Sendable>(priority: TaskPriority, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let worker = Task.detached(priority: priority, operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
    static func time(_ ticks: Int64) -> CMTime { CMTime(value: ticks, timescale: CMTimeScale(EditorClock.scale)) }
    static func range(_ ticks: TickRange) -> CMTimeRange { CMTimeRange(start: time(ticks.start), duration: time(ticks.duration)) }
    static func ticks(_ time: CMTime) -> Int64 {
        guard time.isNumeric else { return 0 }
        return time.convertScale(CMTimeScale(EditorClock.scale), method: .roundHalfAwayFromZero).value
    }
    static func fingerprint(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let more = try autoreleasepool { () throws -> Bool in
                guard let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
                hash.update(data: chunk)
                return true
            }
            if !more { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func inspect(_ url: URL) async throws -> EditorSource {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { throw EditorError.message("原素材不存在或不可读取，请重新定位素材。") }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty, ticks(duration) > 0 else { throw EditorError.message("所选素材没有可读取的音轨。") }
        let digest = try fingerprint(url)
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard values.fileSize == after.fileSize, values.contentModificationDate == after.contentModificationDate else { throw EditorError.message("素材在读取时发生变化，请稍后重试。") }
        return EditorSource(path: url.path, durationTicks: ticks(duration), fileSize: Int64(values.fileSize ?? 0), sha256: digest)
    }
    static func verify(_ source: EditorSource, at replacement: URL? = nil) async throws -> EditorSource {
        let actual = try await inspect(replacement ?? URL(fileURLWithPath: source.path))
        guard actual.fileSize == source.fileSize, actual.sha256 == source.sha256 else { throw EditorError.message("所选文件与项目原素材不一致。请重新定位同一份素材，避免剪错文件。") }
        return actual
    }
    static func composition(source: EditorSource, map: EditorTimelineMap) async throws -> AVMutableComposition {
        try Task.checkCancellation()
        guard map.duration > 0 else { throw EditorError.message("剪辑结果没有保留的音频片段。可撤销删除或恢复片段。") }
        let asset = AVURLAsset(url: URL(fileURLWithPath: source.path))
        guard let input = try await asset.loadTracks(withMediaType: .audio).first else { throw EditorError.message("原素材没有可读取的音轨。") }
        let available = try await input.load(.timeRange)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw EditorError.message("无法准备音频时间线。") }
        // Start with silence across the complete output, then replace only the
        // portions covered by the source audio track. Video-only head/tail gaps survive.
        track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: time(map.duration)))
        for entry in map.entries {
            try Task.checkCancellation()
            let intersection = CMTimeRangeGetIntersection(range(entry.source), otherRange: available)
            guard intersection.isValid, intersection.duration > .zero else { continue }
            let destination = CMTimeAdd(time(entry.timeline.start), CMTimeSubtract(intersection.start, time(entry.source.start)))
            track.removeTimeRange(CMTimeRange(start: destination, duration: intersection.duration))
            try track.insertTimeRange(intersection, of: input, at: destination)
        }
        return composition
    }
    static func waveform(source: EditorSource, bins: Int = 2048) async throws -> [Float] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: source.path))
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw EditorError.message("没有可绘制波形的音轨。") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditorError.message("波形解码启动失败。") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var peaks = [Float](repeating: 0, count: bins)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
                let count = CMSampleBufferGetNumSamples(sample)
                let length = CMBlockBufferGetDataLength(block)
                guard count > 0, length >= count * 4, length <= 4_194_304 else { throw EditorError.message("音频解码块过大或格式异常，已停止绘制波形。") }
                var bytes: UnsafeMutablePointer<Int8>?
                var contiguous = 0, total = 0
                let result = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous, totalLengthOut: &total, dataPointerOut: &bytes)
                let start = ticks(CMSampleBufferGetPresentationTimeStamp(sample))
                func consume(_ pointer: UnsafePointer<Float>) {
                    for i in 0..<count {
                        let tick = start + Int64(i) * 3
                        guard tick >= 0, tick < source.durationTicks else { continue }
                        let bin = min(bins - 1, Int(tick * Int64(bins) / source.durationTicks))
                        let value = abs(pointer[i])
                        if value.isFinite { peaks[bin] = max(peaks[bin], min(1, value)) }
                    }
                }
                if result == kCMBlockBufferNoErr, contiguous >= length, let bytes {
                    consume(UnsafeRawPointer(bytes).assumingMemoryBound(to: Float.self))
                } else {
                    var buffer = [Float](repeating: 0, count: count)
                    let copied = buffer.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!) }
                    guard copied == kCMBlockBufferNoErr else { throw EditorError.message("波形音频块读取失败。") }
                    buffer.withUnsafeBufferPointer { consume($0.baseAddress!) }
                }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? EditorError.message("波形读取未完成。") }
        return peaks
    }
    static func projectedWaveform(_ peaks: [Float], sourceDuration: Int64, map: EditorTimelineMap, bins: Int = 2048) -> [Float] {
        guard !peaks.isEmpty, sourceDuration > 0, map.duration > 0 else { return [] }
        return (0..<bins).map { i in
            let at = Int64(i) * map.duration / Int64(bins)
            guard let source = map.sourceTime(at: at) else { return Float(0) }
            let index = min(peaks.count - 1, Int(source * Int64(peaks.count) / sourceDuration))
            return peaks[max(0, index)]
        }
    }
    static func export(project: AudioEditProject, mode: EditorTimelineMode, format: EditorAudioFormat, destination: URL, includeSpeakers: Bool = false) async throws -> AudioEditExportResult {
        try project.validate()
        let map = project.timeline(mode)
        guard map.duration > 0 else { throw EditorError.message("没有保留的音频，无法导出。") }
        let subtitles = try project.subtitles(map: map, includeSpeakers: includeSpeakers)
        _ = try await verify(project.source)
        let composition = try await composition(source: project.source, map: map)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = String(URL(fileURLWithPath: project.source.path).deletingPathExtension().lastPathComponent.prefix(40))
        let base = name + "_" + mode.title + "_" + formatter.string(from: Date()) + "_" + UUID().uuidString.prefix(6)
        let folder = destination.appendingPathComponent(base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let audio = folder.appendingPathComponent(base).appendingPathExtension(format.rawValue)
        do {
            try Task.checkCancellation()
            if format == .m4a {
                guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw EditorError.message("系统无法创建 M4A 导出任务。") }
                // The SDK's async export implementation propagates task cancellation to cancelExport().
                try await exporter.export(to: audio, as: .m4a)
            } else { try await exportWave(composition, to: audio, source: project.source, expectedFrames: map.duration) }
            try Task.checkCancellation()
            var subtitle: URL?
            if !subtitles.srt.isEmpty {
                let file = folder.appendingPathComponent(base).appendingPathExtension("srt")
                try subtitles.srt.write(to: file, atomically: true, encoding: .utf8)
                try subtitles.txt.write(to: folder.appendingPathComponent(base).appendingPathExtension("txt"), atomically: true, encoding: .utf8)
                subtitle = file
            }
            let actual = ticks(try await AVURLAsset(url: audio).load(.duration))
            let review = project.projected(map).filter(\.needsTextReview).count
            let note = "说话人标签：\(includeSpeakers ? "包含（自动结果需核对）" : "不包含")\n时间线：\(mode.title)\n保留片段：\(map.entries.count)\n字幕：\(project.projected(map).count)\n文字需检查：\(review)\n映射时长：\(EditorClock.timestamp(map.duration))\n音频文件时长：\(EditorClock.timestamp(actual))\n边界微调及原字幕的识别误差需要人工核对。\n原素材未修改；裁剪半句不自动猜测剩余文字。\nM4A 可能存在编码帧粒度差异。\n"
            try note.write(to: folder.appendingPathComponent("导出核对说明.txt"), atomically: true, encoding: .utf8)
            let entries = map.entries.map { ["clipID": $0.clipID.uuidString, "sourceStart": String($0.source.start), "sourceEnd": String($0.source.end), "timelineStart": String($0.timeline.start), "timelineEnd": String($0.timeline.end)] }
            let manifest: [String: Any] = ["timeScale": EditorClock.scale, "timeline": mode.rawValue, "sourceSHA256": project.source.sha256, "durationTicks": map.duration, "audioDurationTicks": actual, "entries": entries]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("时间线映射.json"), options: .atomic)
            return AudioEditExportResult(folder: folder, audio: audio, subtitle: subtitle, durationTicks: actual, needsReview: review)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    private static func exportWave(_ composition: AVComposition, to url: URL, source: EditorSource, expectedFrames: Int64) async throws {
        let original = AVURLAsset(url: URL(fileURLWithPath: source.path))
        var channels = 2
        if let track = try await original.loadTracks(withMediaType: .audio).first,
           let description = try await track.load(.formatDescriptions).first,
           let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            channels = max(1, min(2, Int(stream.pointee.mChannelsPerFrame)))
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let reader = try AVAssetReader(asset: composition)
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditorError.message("WAV 导出启动失败。") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        var written: Int64 = 0
        func silence(until target: Int64) throws {
            while written < min(target, expectedFrames) {
                try Task.checkCancellation()
                let frames = AVAudioFrameCount(min(4096, min(target, expectedFrames) - written))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames), let pointer = buffer.int16ChannelData?[0] else { throw EditorError.message("WAV 静音缓冲区创建失败。") }
                buffer.frameLength = frames
                memset(pointer, 0, Int(frames) * channels * 2)
                try file.write(from: buffer); written += Int64(frames)
            }
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let data = CMSampleBufferGetDataBuffer(sample) else { return }
                let length = CMBlockBufferGetDataLength(data)
                guard length <= 4_194_304 else { throw EditorError.message("导出音频块超出内存限制。") }
                let sampleStart = ticks(CMSampleBufferGetPresentationTimeStamp(sample))
                try silence(until: max(0, sampleStart))
                let skip = max(0, written - sampleStart)
                let count = min(Int64(length / (2 * channels)) - skip, expectedFrames - written)
                guard count > 0 else { return }
                let frames = AVAudioFrameCount(count)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames), let pointer = buffer.int16ChannelData?[0] else { throw EditorError.message("WAV 音频缓冲区创建失败。") }
                buffer.frameLength = frames
                guard CMBlockBufferCopyDataBytes(data, atOffset: Int(skip) * channels * 2, dataLength: Int(count) * channels * 2, destination: pointer) == kCMBlockBufferNoErr else { throw EditorError.message("WAV 音频块读取失败。") }
                try file.write(from: buffer); written += count
            }
        }
        guard reader.status == .completed else { throw reader.error ?? EditorError.message("WAV 导出未完成。") }
        try silence(until: expectedFrames)
    }
}
