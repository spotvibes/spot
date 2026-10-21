import Foundation
import AVFoundation

enum VoiceMessagePlaybackState: Equatable {
    case idle
    case downloading
    case ready
    case playing
    case paused
    case failed
}

@MainActor
final class VoiceMessagePlayer: NSObject, ObservableObject {
    @Published private(set) var state: VoiceMessagePlaybackState
    @Published private(set) var progress: Double = 0
    @Published private(set) var secondsLeft: TimeInterval

    private let messageId: String
    private let remoteURL: URL
    private var player: AVAudioPlayer?
    private var displayLink: CADisplayLink?

    init(messageId: String, remoteURL: URL, durationMs: Int64?) {
        self.messageId = messageId
        self.remoteURL = remoteURL
        self.secondsLeft = TimeInterval(durationMs ?? 0) / 1000
        self.state = .idle
        super.init()
    }

    func toggle() {
        switch state {
        case .idle, .failed:
            Task { await downloadThenPlay() }
        case .downloading:
            break
        case .ready, .paused:
            resume()
        case .playing:
            pauseCurrent()
        }
    }

    private func downloadThenPlay() async {
        state = .downloading
        do {
            let localURL = remoteURL.isFileURL
                ? remoteURL
                : try await MediaFileCache.shared.localURL(for: remoteURL, cacheKey: messageId)
            let newPlayer = try AVAudioPlayer(contentsOf: localURL)
            newPlayer.delegate = self
            player = newPlayer
            secondsLeft = newPlayer.duration
            state = .ready
            resume()
        } catch {
            print("DEBUG: VoiceMessagePlayer failed to load message \(messageId) at \(remoteURL): \(error)")
            state = .failed
        }
    }

    private func resume() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        state = .playing
        startTicking()
    }

    private func pauseCurrent() {
        player?.pause()
        state = .paused
        stopTicking()
    }

    private func startTicking() {
        stopTicking()
        let link = CADisplayLink(target: self, selector: #selector(tickFromDisplayLink))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tickFromDisplayLink() {
        tick()
    }

    private func tick() {
        guard let player else { return }
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
        secondsLeft = max(0, player.duration - player.currentTime)
    }
}

extension VoiceMessagePlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.state = .ready
            self.progress = 0
            self.secondsLeft = player.duration
            self.player?.currentTime = 0
            self.stopTicking()
        }
    }
}
