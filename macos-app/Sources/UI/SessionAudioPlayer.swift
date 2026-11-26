import AVFoundation
import Observation

/// Plays a session's mixed recording. Views that show the clock read `currentTime`;
/// transcript rows read only `currentLine`, which changes once per line, so the
/// 4 Hz tick does not redraw the whole transcript.
@MainActor
@Observable
final class SessionAudioPlayer {
    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var currentLine: Int?
    private(set) var isPlaying = false
    private(set) var error: String?
    var rate: Float = 1 { didSet { player?.rate = rate } }

    var isLoaded: Bool { player != nil }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var lines: [TranscriptLine] = []
    @ObservationIgnored private var timer: Timer?

    private static let instances = NSHashTable<SessionAudioPlayer>.weakObjects()

    init() { Self.instances.add(self) }

    /// Called synchronously before capture starts, ahead of any view update.
    static func pauseAll() { instances.allObjects.forEach { $0.pause() } }

    func load(path: String, lines: [TranscriptLine]) {
        self.lines = lines
        player?.stop()
        player = nil
        stopTicking()
        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player.enableRate = true  // must be set before prepareToPlay
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            error = nil
        } catch {
            self.error = "Audio unavailable: \(error.localizedDescription)"
        }
    }

    func seek(to time: Double, play: Bool) {
        guard let player else { return }
        player.currentTime = min(max(0, time), duration)
        sync()
        if play { self.play() }
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        player.rate = rate
        isPlaying = player.play()
        guard isPlaying else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.sync()
            }
        }
        RunLoop.main.add(timer, forMode: .common)  // keeps ticking while the transcript scrolls
        self.timer = timer
    }

    func pause() {
        player?.pause()
        stopTicking()
        sync()
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    private func sync() {
        guard let player else { return }
        currentTime = player.currentTime
        let line = TranscriptDocument.lineIndex(at: currentTime, in: lines)
        if line != currentLine { currentLine = line }
        if isPlaying && !player.isPlaying { stopTicking() }
    }
}
