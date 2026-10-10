import Foundation
import AVFoundation

@main struct Inspect {
    static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        print("duration_seconds=\(CMTimeGetSeconds(duration)) audio_tracks=\(tracks.count)")
        guard let track = tracks.first else { throw NSError(domain: "Probe", code: 1) }
        let range = try await track.load(.timeRange)
        print("audio_start_seconds=\(CMTimeGetSeconds(range.start)) audio_duration_seconds=\(CMTimeGetSeconds(range.duration))")
        guard CommandLine.arguments.count > 2 else { return }
        let destination = URL(fileURLWithPath: CommandLine.arguments[2])
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw NSError(domain: "ProbeOutputExists", code: 2)
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        let file = try AVAudioFile(forWriting: destination, settings: settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        var frames: Int64 = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = AVAudioFrameCount(length / 2)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: count),
                  let target = buffer.int16ChannelData?[0] else {
                throw NSError(domain: "ProbeBuffer", code: 3)
            }
            buffer.frameLength = count
            let result = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                                    destination: target)
            guard result == kCMBlockBufferNoErr else { throw NSError(domain: "ProbeCopy", code: Int(result)) }
            try file.write(from: buffer)
            frames += Int64(count)
        }
        guard reader.status == .completed else { throw reader.error ?? NSError(domain: "ProbeReader", code: 4) }
        print("decoded_frames=\(frames) decoded_seconds=\(Double(frames) / 16000)")
    }
}
