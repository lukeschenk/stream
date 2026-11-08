import AVFoundation
import Foundation

/// Plays one Jellyfin item and reports progress to the server.
@MainActor
final class JellyfinPlayback {
    let player = AVPlayer()

    private let client: JellyfinClient
    private let item: JellyfinItem
    private let userID: String
    private var source: JellyfinPlaybackSource?

    static let progressInterval: Duration = .seconds(10)

    init(client: JellyfinClient, item: JellyfinItem, userID: String) {
        self.client = client
        self.item = item
        self.userID = userID
    }

    func prepare() async throws {
        let source = try await client.playbackSource(itemID: item.id, userID: userID)
        self.source = source

        let playerItem = AVPlayerItem(url: source.url)
        player.replaceCurrentItem(with: playerItem)

        while playerItem.status == .unknown {
            try await Task.sleep(for: .milliseconds(100))
        }

        if playerItem.status == .failed {
            throw playerItem.error ?? JellyfinError.noPlayableSource
        }

        let resumeAt = item.resumePositionSeconds
        if resumeAt > 5, !item.isPlayed {
            _ = await player.seek(
                to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    /// Plays until the calling task is cancelled.
    func run() async {
        guard source != nil else { return }

        player.play()
        try? await client.reportPlaybackStarted(report())

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.progressInterval)
            } catch {
                break
            }
            try? await client.reportPlaybackProgress(report())
        }

        let finalReport = report()
        player.pause()
        player.replaceCurrentItem(with: nil)

        // The view's task is already cancelled, so report from a new task.
        let client = client
        Task {
            try? await client.reportPlaybackStopped(finalReport)
        }
    }

    private func report() -> JellyfinPlaybackReport {
        JellyfinPlaybackReport(
            itemID: item.id,
            mediaSourceID: source?.mediaSourceID ?? item.id,
            playSessionID: source?.playSessionID,
            positionTicks: JellyfinPlaybackReport.ticks(fromSeconds: player.currentTime().seconds),
            isPaused: player.timeControlStatus == .paused,
            canSeek: true,
            playMethod: source?.playMethod
        )
    }
}
