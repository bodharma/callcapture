import Foundation
import Testing

@testable import CallCapture

/// A temp dir per test; synthetic audio only.
private struct AudioDir {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cc-peaks-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

    var audioPath: String { url.appendingPathComponent("rec.wav").path }
    var cachePath: String { WaveformPeaks.cachePath(audioPath: audioPath) }

    func cache() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: cachePath))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

@Suite("Waveform peaks")
struct WaveformTests {
    @Test("peaksBuckets: a synthetic sine gives 1200 values in 0…1 and writes the cache")
    func peaksBuckets() throws {
        let dir = try AudioDir()
        defer { dir.cleanup() }
        try SyntheticAudio.writeSine(to: URL(fileURLWithPath: dir.audioPath), seconds: 2, amplitude: 0.5)

        let peaks = try WaveformPeaks.load(audioPath: dir.audioPath, buckets: 1200)

        #expect(peaks.count == 1200)
        #expect(peaks.allSatisfy { (0...1).contains($0) })
        // Normalized to the loudest bucket; a steady tone fills every bucket.
        #expect(peaks.max() == 1)
        #expect(peaks.allSatisfy { $0 > 0.5 })
        #expect(dir.cachePath == (dir.audioPath as NSString).deletingPathExtension + "_peaks.json")
        let cache = try dir.cache()
        #expect(cache["buckets"] as? Int == 1200)
        #expect((cache["peaks"] as? [Double])?.count == 1200)
    }

    @Test("a matching cache is served without decoding the audio again")
    func usesCache() throws {
        let dir = try AudioDir()
        defer { dir.cleanup() }
        try SyntheticAudio.writeSine(to: URL(fileURLWithPath: dir.audioPath), seconds: 1)
        _ = try WaveformPeaks.load(audioPath: dir.audioPath, buckets: 8)

        var cache = try dir.cache()
        cache["peaks"] = [0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25]
        try JSONSerialization.data(withJSONObject: cache).write(to: URL(fileURLWithPath: dir.cachePath))

        #expect(try WaveformPeaks.load(audioPath: dir.audioPath, buckets: 8) == Array(repeating: 0.25, count: 8))
        // A different bucket count is a different key.
        #expect(try WaveformPeaks.load(audioPath: dir.audioPath, buckets: 4).count == 4)
    }

    @Test("a changed audio file recomputes and rewrites the cache key")
    func changedFileRecomputes() throws {
        let dir = try AudioDir()
        defer { dir.cleanup() }
        let url = URL(fileURLWithPath: dir.audioPath)
        try SyntheticAudio.writeSine(to: url, seconds: 2)
        _ = try WaveformPeaks.load(audioPath: dir.audioPath, buckets: 16)
        let firstSize = try dir.cache()["size"] as? Int

        // Now silent and shorter: the old all-loud cache must not be served.
        try FileManager.default.removeItem(at: url)
        try SyntheticAudio.writeSine(to: url, seconds: 1, toneChannels: [])
        let silent = try WaveformPeaks.load(audioPath: dir.audioPath, buckets: 16)

        #expect(silent == Array(repeating: 0, count: 16))
        let size = try FileManager.default.attributesOfItem(atPath: dir.audioPath)[.size] as? Int
        #expect(try dir.cache()["size"] as? Int == size)
        #expect(size != firstSize)
    }

    @Test("a corrupt cache is ignored and rewritten")
    func corruptCacheIgnored() throws {
        let dir = try AudioDir()
        defer { dir.cleanup() }
        try SyntheticAudio.writeSine(to: URL(fileURLWithPath: dir.audioPath), seconds: 1)
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: dir.cachePath))

        let peaks = try WaveformPeaks.load(audioPath: dir.audioPath, buckets: 32)

        #expect(peaks.count == 32)
        #expect(peaks.max() == 1)
        #expect((try dir.cache()["peaks"] as? [Double])?.count == 32)
    }

    @Test("the loudest channel wins in each bucket")
    func maxAcrossChannels() throws {
        let dir = try AudioDir()
        defer { dir.cleanup() }
        // Left silent, right carries the tone: reading only one channel would give zeros.
        try SyntheticAudio.writeSine(
            to: URL(fileURLWithPath: dir.audioPath), seconds: 1, channels: 2, toneChannels: [1])

        let peaks = try WaveformPeaks.load(audioPath: dir.audioPath, buckets: 10)

        #expect(peaks.count == 10)
        #expect(peaks.allSatisfy { $0 > 0.5 })
    }

    @Test("files shorter than the bucket count still give every bucket")
    func shortFile() throws {
        let dir = try AudioDir()
        defer { dir.cleanup() }
        try SyntheticAudio.writeSine(to: URL(fileURLWithPath: dir.audioPath), seconds: 0.01)  // 160 frames

        let peaks = try WaveformPeaks.load(audioPath: dir.audioPath, buckets: 1200)

        #expect(peaks.count == 1200)
        #expect(peaks.allSatisfy { (0...1).contains($0) })
        #expect(peaks.contains { $0 > 0 })
    }

    @Test("a missing or unreadable audio file throws")
    func unreadableAudio() throws {
        let dir = try AudioDir()
        defer { dir.cleanup() }
        #expect(throws: (any Error).self) { try WaveformPeaks.load(audioPath: dir.audioPath, buckets: 10) }
        try Data("not audio".utf8).write(to: URL(fileURLWithPath: dir.audioPath))
        #expect(throws: (any Error).self) { try WaveformPeaks.load(audioPath: dir.audioPath, buckets: 10) }
        #expect(throws: (any Error).self) { try WaveformPeaks.load(audioPath: dir.audioPath, buckets: 0) }
    }
}
