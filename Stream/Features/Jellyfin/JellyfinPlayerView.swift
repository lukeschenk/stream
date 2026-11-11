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
        .toolbar {
            if let playback, !playback.subtitles.isEmpty {
                ToolbarItem {
                    JellyfinSubtitleMenu(playback: playback)
                }
            }
        }
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
