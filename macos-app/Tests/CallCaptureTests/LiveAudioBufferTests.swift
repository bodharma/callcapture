import Foundation
import Testing
@testable import CallCapture

@Suite("Bounded live PCM")
struct LiveAudioBufferTests {
    @Test("overflow rejects new samples and the next accepted offset exposes the gap")
    func pressureAndOffsets() throws {
        let buffer = LivePCMBuffer(maxSamples: 8, maxChunkSamples: 8)
        #expect(buffer.offer(samples: [1, 2, 3, 4], source: .mic, start: 0))
        #expect(!buffer.offer(samples: [5, 6, 7, 8, 9], source: .system, start: 0))
        #expect(buffer.queuedSamples == 4)
        let first = try #require(buffer.take())
        #expect(first.source == .mic)
        #expect(first.samples == [1, 2, 3, 4])
        #expect(buffer.offer(samples: [9, 10], source: .system, start: 1))
        let next = try #require(buffer.take())
        #expect(next.start == 1)
        #expect(next.source == .system)
        #expect(buffer.queuedSamples == 0)
    }

    @Test("large callbacks are rejected rather than copied into an unbounded allocation")
    func oversizedCallback() {
        let buffer = LivePCMBuffer(maxSamples: 16, maxChunkSamples: 4)
        #expect(!buffer.offer(samples: [1, 2, 3, 4, 5], source: .mic, start: 0))
        #expect(buffer.take() == nil)
    }

    @Test("windowing retains one second lookback, separates sources and flushes tails")
    func windowsAndTail() {
        var windows = LivePCMWindowBuilder(sampleRate: 2, windowSeconds: 3, lookbackSeconds: 1)
        #expect(windows.append(LivePCMChunk(source: .mic, start: 0, samples: [0, 1, 2, 3])).chunks.isEmpty)
        let result = windows.append(LivePCMChunk(source: .mic, start: 2, samples: [4, 5, 6, 7]))
        #expect(result.chunks.count == 1)
        #expect(result.chunks.first?.samples == [0, 1, 2, 3, 4, 5])
        #expect(result.chunks.first?.start == 0)
        _ = windows.append(LivePCMChunk(source: .system, start: 0, samples: [8, 9]))
        let tails = windows.flush()
        #expect(tails.first(where: { $0.source == .mic })?.samples == [4, 5, 6, 7])
        #expect(tails.first(where: { $0.source == .mic })?.start == 2)
        #expect(tails.first(where: { $0.source == .system })?.samples == [8, 9])
    }

    @Test("a discontinuity flushes earlier evidence and reports the missing range")
    func gap() {
        var windows = LivePCMWindowBuilder(sampleRate: 2, windowSeconds: 3, lookbackSeconds: 1)
        _ = windows.append(LivePCMChunk(source: .system, start: 0, samples: [1, 2]))
        let result = windows.append(LivePCMChunk(source: .system, start: 3, samples: [7, 8]))
        #expect(result.gap != nil)
        #expect(result.chunks.first?.samples == [1, 2])
        #expect(windows.flush().first?.start == 3)
    }
    @Test("one provisional preview per window shares identity with its committed final")
    func provisionalWindows() {
        var windows = LivePCMWindowBuilder(sampleRate: 2, windowSeconds: 6, lookbackSeconds: 1)
        let preview = windows.append(LivePCMChunk(source: .mic, start: 0, samples: [0, 1, 2, 3, 4, 5])).chunks
        #expect(preview.count == 1)
        #expect(preview.first?.final == false)
        #expect(windows.append(LivePCMChunk(source: .mic, start: 3, samples: [6, 7])).chunks.isEmpty)
        let final = windows.append(LivePCMChunk(source: .mic, start: 4, samples: [8, 9, 10, 11])).chunks
        #expect(final.count == 1)
        #expect(final.first?.final == true)
        #expect(final.first?.requestID == preview.first?.requestID)
        #expect(windows.flush().isEmpty)
    }

}
