import AVKit
import SwiftUI

struct JellyfinPlayerView: View {
    let connection: JellyfinConnection
    let item: JellyfinItem

    @State private var playback: JellyfinPlayback?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let playback {
                JellyfinVideoPlayer(player: playback.player)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Can’t Play \(item.displayTitle)",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .foregroundStyle(.white)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .navigationTitle(item.displayTitle)
        .navigationSubtitle(item.subtitle ?? "")
        // Cancelled when the view goes away, which stops playback and tells
        // Jellyfin where to resume next time.
        .task { await run() }
    }

    private func run() async {
        guard let client = connection.client,
              let userID = connection.account?.userID
        else {
            errorMessage = JellyfinError.notSignedIn.localizedDescription
            return
        }

        let playback = JellyfinPlayback(client: client, item: item, userID: userID)

        do {
            try await playback.prepare()
        } catch is CancellationError {
            return
        } catch {
            connection.handle(error)
            errorMessage = error.localizedDescription
            return
        }

        self.playback = playback
        await playback.run()
    }
}

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
            await player.seek(
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

struct JellyfinVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context _: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context _: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
