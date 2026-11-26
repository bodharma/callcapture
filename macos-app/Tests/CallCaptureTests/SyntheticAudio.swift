import AVFoundation
import Foundation

/// Writes synthetic 16-bit PCM WAV files for tests; never touches real recordings.
enum SyntheticAudio {
    /// A sine on the given channels (others silent). The file is closed when this returns.
    static func writeSine(
        to url: URL, seconds: Double, sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1,
        toneChannels: Set<Int>? = nil, frequency: Double = 440, amplitude: Float = 0.5
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: max(frames, 1)),
            let data = buffer.floatChannelData
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = frames
        let toned = toneChannels ?? Set(0..<Int(channels))
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
                data[channel][frame] = toned.contains(channel) ? amplitude * Float(sin(phase)) : 0
            }
        }
        if frames > 0 { try file.write(from: buffer) }
    }
}
