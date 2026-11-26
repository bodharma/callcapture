import Foundation

struct LivePCMChunk: Sendable {
    let source: LiveAudioSource
    let start: Double
    let samples: [Float]
    var final = true
    var requestID: String { "\(source.rawValue)-\(Int64((start * 16_000).rounded()))" }
}

/// One producer (the capture IO proc). Admission never waits for its consumer.
final class LivePCMBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [LivePCMChunk] = []
    private var sampleCount = 0
    let maxSamples: Int
    let maxChunkSamples: Int

    init(maxSamples: Int = 16_000 * 24, maxChunkSamples: Int = 16_000) {
        self.maxSamples = maxSamples
        self.maxChunkSamples = maxChunkSamples
    }

    var queuedSamples: Int { lock.withLock { sampleCount } }
    func offer(samples: [Float], source: LiveAudioSource, start: Double) -> Bool {
        samples.withUnsafeBufferPointer { offer(samples: $0, source: source, start: start) }
    }
    func offer(samples: UnsafeBufferPointer<Float>, source: LiveAudioSource, start: Double) -> Bool {
        guard !samples.isEmpty, samples.count <= maxChunkSamples, start.isFinite, start >= 0, start <= LiveMeetingModel.maxOffsetSeconds,
              lock.try() else { return false }
        defer { lock.unlock() }
        guard sampleCount + samples.count <= maxSamples else { return false }
        chunks.append(LivePCMChunk(source: source, start: start, samples: Array(samples)))
        sampleCount += samples.count
        return true
    }
    func take() -> LivePCMChunk? {
        lock.withLock {
            guard !chunks.isEmpty else { return nil }
            let chunk = chunks.removeFirst()
            sampleCount -= chunk.samples.count
            return chunk
        }
    }
}

struct LivePCMWindowBuilder {
    struct Result { var chunks: [LivePCMChunk] = []; var gap: String? }
    private struct Stream { var start: Double; var samples: [Float]; var newSamples: Int; var previewSent = false }
    private var streams: [LiveAudioSource: Stream] = [:]
    private(set) var acceptedEnds: [LiveAudioSource: Double] = [:]
    let sampleRate: Int
    let windowSamples: Int
    let lookbackSamples: Int

    init(sampleRate: Int = 16_000, windowSeconds: Int = 6, lookbackSeconds: Int = 1) {
        precondition(sampleRate > 0 && windowSeconds > lookbackSeconds && lookbackSeconds >= 0)
        self.sampleRate = sampleRate
        windowSamples = sampleRate * windowSeconds
        lookbackSamples = sampleRate * lookbackSeconds
    }

    mutating func append(_ chunk: LivePCMChunk) -> Result {
        var result = Result()
        let expected = acceptedEnds[chunk.source] ?? 0
        if abs(chunk.start - expected) > 1.5 / Double(sampleRate) {
            result.gap = "\(chunk.source.rawValue) live audio gap at \(String(format: "%.2f", expected))–\(String(format: "%.2f", chunk.start))s; recording retained."
            if let prior = streams.removeValue(forKey: chunk.source), prior.newSamples > 0 {
                result.chunks.append(LivePCMChunk(source: chunk.source, start: prior.start, samples: prior.samples))
            }
        }
        var stream = streams[chunk.source] ?? Stream(start: chunk.start, samples: [], newSamples: 0)
        stream.samples.append(contentsOf: chunk.samples)
        stream.newSamples += chunk.samples.count
        acceptedEnds[chunk.source] = chunk.start + Double(chunk.samples.count) / Double(sampleRate)
        while stream.samples.count >= windowSamples {
            result.chunks.append(LivePCMChunk(source: chunk.source, start: stream.start, samples: Array(stream.samples.prefix(windowSamples))))
            let consumed = windowSamples - lookbackSamples
            stream.samples.removeFirst(consumed)
            stream.start += Double(consumed) / Double(sampleRate)
            stream.newSamples = stream.samples.count - lookbackSamples
            stream.previewSent = false
        }
        let previewSamples = sampleRate * 3
        if previewSamples < windowSamples, stream.samples.count >= previewSamples, !stream.previewSent {
            result.chunks.append(LivePCMChunk(source: chunk.source, start: stream.start,
                                              samples: Array(stream.samples.prefix(previewSamples)), final: false))
            stream.previewSent = true
        }
        streams[chunk.source] = stream
        return result
    }

    mutating func flush() -> [LivePCMChunk] {
        defer { streams.removeAll() }
        return [LiveAudioSource.mic, .system].compactMap { source in
            guard let stream = streams[source], stream.newSamples > 0 else { return nil }
            return LivePCMChunk(source: source, start: stream.start, samples: stream.samples)
        }
    }
}
