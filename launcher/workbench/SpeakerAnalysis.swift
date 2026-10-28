import Foundation
@preconcurrency import AVFoundation

struct SpeakerAnalysisResult: Sendable {
    var data: SpeakerProjectData
    var peakRSSBytes: Int64
    var elapsedSeconds: Double
}
enum SpeakerAnalysis {
    static var runtimeRoot: URL {
        if let value = ProcessInfo.processInfo.environment["LOCAL_SUBTITLE_ROOT"] { return URL(fileURLWithPath: value) }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Runtime"), FileManager.default.fileExists(atPath: bundled.appendingPathComponent("runtime.json").path) { return bundled }
        return Bundle.main.bundleURL.deletingLastPathComponent()
    }
    static func run(project: AudioEditProject, expected: Int, runtime: URL = runtimeRoot) async throws -> SpeakerAnalysisResult {
        try project.validate()
        guard !project.dialogues.isEmpty else { throw EditorError.message("请先载入对应素材的 SRT，再区分说话人。") }
        let executable = runtime.appendingPathComponent(".local/bin/speaker-embeddings")
        let directory = runtime.appendingPathComponent(".local/speaker-runtime")
        let model = directory.appendingPathComponent("campplus-zh-en.onnx")
        guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.isReadableFile(atPath: model.path),
              let manifest = try? JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any],
              let expectedHash = manifest["modelSHA256"] as? String,
              try EditorMedia.fingerprint(model) == expectedHash else {
            throw EditorError.message("本地说话人模块缺失或校验失败，请安装包含该模块的新版程序。")
        }
        _ = try await EditorMedia.verify(project.source)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("tingting-speakers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let wav = temporary.appendingPathComponent("audio.wav")
        try await decode(source: project.source, to: wav)
        let ranges = temporary.appendingPathComponent("ranges.tsv")
        let text = project.dialogues.map { "\($0.id.uuidString)\t\($0.range.start)\t\($0.range.end)" }.joined(separator: "\n")
        try text.write(to: ranges, atomically: true, encoding: .utf8)
        let output = temporary.appendingPathComponent("vectors.bin"), stats = temporary.appendingPathComponent("stats.json")
        let log = temporary.appendingPathComponent("analysis.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        let process = Process(); process.executableURL = executable
        process.arguments = [model.path, wav.path, ranges.path, output.path, stats.path]
        process.standardOutput = handle; process.standardError = handle
        try Task.checkCancellation(); try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        while process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        guard process.terminationStatus == 0 else { throw EditorError.message("本地说话人分析未完成，当前编辑已保留；请检查素材音轨后重试。") }
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: output); defer { try? input.close() }
        guard try input.read(upToCount: 8) == Data("TTSPK001".utf8) else { throw EditorError.message("说话人结果格式不正确。") }
        var vectors: [SpeakerVector] = []
        while let bytes = try input.read(upToCount: 804), !bytes.isEmpty {
            try Task.checkCancellation()
            guard bytes.count == 804, vectors.count < project.dialogues.count * 3,
                  let text = String(data: bytes.prefix(36), encoding: .utf8), let id = UUID(uuidString: text) else { throw EditorError.message("说话人结果不完整。") }
            let values: [Float] = bytes.withUnsafeBytes { buffer in
                (0..<192).map { Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: 36 + $0 * 4, as: UInt32.self))) }
            }
            vectors.append(SpeakerVector(dialogue: id, values: values))
        }
        let data = try SpeakerClustering.group(dialogues: project.dialogues, vectors: vectors, expected: expected)
        let metrics = try JSONSerialization.jsonObject(with: Data(contentsOf: stats)) as? [String: Any]
        return SpeakerAnalysisResult(data: data, peakRSSBytes: (metrics?["peakRSSBytes"] as? NSNumber)?.int64Value ?? 0,
                                     elapsedSeconds: (metrics?["elapsedSeconds"] as? NSNumber)?.doubleValue ?? 0)
    }
    // Stream onto disk using source timestamps; only one small PCM chunk is resident.
    private static func decode(source: EditorSource, to destination: URL) async throws {
        guard source.durationTicks <= 24 * 3600 * EditorClock.scale else { throw EditorError.message("说话人分析目前限 24 小时以内，请先分段。") }
        let asset = AVURLAsset(url: URL(fileURLWithPath: source.path))
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw EditorError.message("素材没有音轨。") }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings); output.alwaysCopiesSampleData = false; reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditorError.message("音轨读取失败。") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let file = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let total = (source.durationTicks + 2) / 3
        var written: Int64 = 0
        func silence(until end: Int64) throws {
            while written < min(end, total) {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(4096, min(end, total) - written))
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
                buffer.frameLength = count; memset(buffer.int16ChannelData![0], 0, Int(count) * 2)
                try file.write(from: buffer); written += Int64(count)
            }
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
                let size = CMBlockBufferGetDataLength(block), count = CMSampleBufferGetNumSamples(sample)
                guard count > 0, size == count * 2, size <= 4_194_304 else { throw EditorError.message("音轨解码格式异常。") }
                let start = EditorMedia.ticks(CMSampleBufferGetPresentationTimeStamp(sample)) / 3
                try silence(until: max(0, start))
                let skip = max(0, written - start), remaining = min(Int64(count) - skip, total - written)
                guard remaining > 0 else { return }
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(remaining))!
                buffer.frameLength = AVAudioFrameCount(remaining)
                guard CMBlockBufferCopyDataBytes(block, atOffset: Int(skip) * 2, dataLength: Int(remaining) * 2, destination: buffer.int16ChannelData![0]) == kCMBlockBufferNoErr else { throw EditorError.message("音轨读取失败。") }
                try file.write(from: buffer); written += remaining
            }
        }
        guard reader.status == .completed else { throw reader.error ?? EditorError.message("音轨读取未完成。") }
        try silence(until: total)
    }
}
