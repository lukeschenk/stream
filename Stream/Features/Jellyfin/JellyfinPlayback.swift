import AVFoundation
import Foundation
import Observation

/// Plays one Jellyfin item and reports progress to the server.
@MainActor
@Observable
final class JellyfinPlayback {
    @ObservationIgnored
    let player = AVPlayer()
    /// The item's subtitles, by Jellyfin stream index.
    private(set) var subtitles: [JellyfinSubtitleTrack] = []
    private(set) var selectedSubtitle: Int?
    private(set) var isSwitchingSubtitles = false

    @ObservationIgnored
    private let client: JellyfinClient
    @ObservationIgnored
    private let item: JellyfinItem
    @ObservationIgnored
    private let userID: String
    @ObservationIgnored
    private var source: JellyfinPlaybackSource?

    static let progressInterval: Duration = .seconds(10)

    init(client: JellyfinClient, item: JellyfinItem, userID: String) {
        self.client = client
        self.item = item
        self.userID = userID
    }

    func prepare() async throws {
        let resumeAt = item.resumePositionSeconds
        try await load(startingAt: resumeAt > 5 && !item.isPlayed ? resumeAt : nil)
    }

    /// Reloads the stream with a different subtitle, or none, keeping the
    /// position and whether it was playing.
    func selectSubtitle(_ index: Int?) async {
        guard index != selectedSubtitle, !isSwitchingSubtitles else { return }
        let position = player.currentTime().seconds
        let wasPlaying = player.timeControlStatus != .paused
        let previous = selectedSubtitle

        isSwitchingSubtitles = true
        defer { isSwitchingSubtitles = false }

        selectedSubtitle = index
        do {
            try await load(startingAt: position.isFinite ? position : nil)
        } catch {
            selectedSubtitle = previous
            try? await load(startingAt: position.isFinite ? position : nil)
        }
        if wasPlaying {
            player.play()
        }
        try? await client.reportPlaybackStarted(report())
    }

    private func load(startingAt position: Double?) async throws {
        let source = try await client.playbackSource(
            itemID: item.id,
            userID: userID,
            subtitleStreamIndex: selectedSubtitle
        )
        self.source = source
        if subtitles.isEmpty {
            subtitles = source.subtitles
        }

        let playerItem = AVPlayerItem(url: source.url)
        player.replaceCurrentItem(with: playerItem)

        while playerItem.status == .unknown {
            try await Task.sleep(for: .milliseconds(100))
        }

        if playerItem.status == .failed {
            throw playerItem.error ?? JellyfinError.noPlayableSource
        }

        await playerItem.showSubtitles(selectedSubtitle != nil)

        if let position {
            _ = await player.seek(
                to: CMTime(seconds: position, preferredTimescale: 600),
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
