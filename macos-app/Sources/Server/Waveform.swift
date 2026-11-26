import AVFoundation
import Accelerate
import Foundation
import os

enum WaveformError: Error, Equatable {
    case invalidBucketCount
    case unreadableAudio
}

/// Read-only waveform peaks for the meeting tape, cached beside the audio.
///
/// Each bucket holds the largest absolute sample over all channels in its slice
/// of the file, scaled so the loudest bucket is 1 (silence stays 0). The audio
/// is read with `AVAudioFile` in fixed-size chunks, never loaded whole. This is
/// blocking work: callers on the server run it through `Blocking.run`.
enum WaveformPeaks {
    static let defaultBuckets = 1200
    static let chunkFrames: AVAudioFrameCount = 65_536

    private static let logger = Logger(subsystem: "com.callcapture.app", category: "Waveform")

    /// `<audio basename>_peaks.json`; removed with the session.
    static func cachePath(audioPath: String) -> String {
        (audioPath as NSString).deletingPathExtension + "_peaks.json"
    }

    /// What the cached peaks were computed from; any change recomputes.
    private struct CacheFile: Codable {
        let size: Int64
        let modified: Double
        let buckets: Int
        let peaks: [Float]
    }

    static func load(audioPath: String, buckets: Int) throws -> [Float] {
        guard buckets > 0 else { throw WaveformError.invalidBucketCount }
        let attributes = try FileManager.default.attributesOfItem(atPath: audioPath)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let cachePath = cachePath(audioPath: audioPath)

        if let cached = readCache(cachePath),
            cached.size == size, cached.modified == modified, cached.buckets == buckets,
            cached.peaks.count == buckets
        {
            return cached.peaks
        }
        let peaks = try compute(audioPath: audioPath, buckets: buckets)
        writeCache(CacheFile(size: size, modified: modified, buckets: buckets, peaks: peaks), to: cachePath)
        return peaks
    }

    /// A missing or corrupt cache reads as no cache.
    private static func readCache(_ path: String) -> CacheFile? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(CacheFile.self, from: data)
    }

    /// Best effort: a cache that cannot be written only costs a recompute next time.
    private static func writeCache(_ cache: CacheFile, to path: String) {
        do {
            try JSONEncoder().encode(cache).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            logger.error("Could not write waveform cache: \(error.localizedDescription)")
        }
    }

    static func compute(audioPath: String, buckets: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        let total = file.length
        var peaks = [Float](repeating: 0, count: buckets)
        guard total > 0 else { return peaks }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames)
        else { throw WaveformError.unreadableAudio }

        var position: AVAudioFramePosition = 0
        while position < total {
            let wanted = AVAudioFrameCount(min(Int64(chunkFrames), total - position))
            try file.read(into: buffer, frameCount: wanted)
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            guard let channels = buffer.floatChannelData else { throw WaveformError.unreadableAudio }
            accumulate(
                channels: channels, channelCount: Int(buffer.format.channelCount), count: count,
                start: position, total: total, into: &peaks)
            position += AVAudioFramePosition(count)
        }
        return normalized(peaks)
    }

    /// Folds one chunk into the buckets. Frame `f` belongs to bucket
    /// `f * buckets / total`; each bucket's slice of the chunk is scanned with vDSP.
    private static func accumulate(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, count: Int,
        start: AVAudioFramePosition, total: AVAudioFramePosition, into peaks: inout [Float]
    ) {
        let buckets = Int64(peaks.count)
        var offset = 0
        while offset < count {
            let frame = start + Int64(offset)
            let bucket = Int(frame * buckets / total)
            // First frame of the next bucket: ceil((bucket + 1) * total / buckets) > frame.
            let nextStart = (Int64(bucket + 1) * total + buckets - 1) / buckets
            let end = min(count, Int(nextStart - start))
            for channel in 0..<channelCount {
                var magnitude: Float = 0
                vDSP_maxmgv(channels[channel] + offset, 1, &magnitude, vDSP_Length(end - offset))
                if magnitude.isFinite { peaks[bucket] = max(peaks[bucket], magnitude) }
            }
            offset = end
        }
    }

    /// Loudest bucket becomes 1; three decimals are plenty for drawing.
    private static func normalized(_ peaks: [Float]) -> [Float] {
        guard let loudest = peaks.max(), loudest > 0 else { return peaks }
        return peaks.map { min(1, ($0 / loudest * 1000).rounded() / 1000) }
    }
}
