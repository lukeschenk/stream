import AVKit
import SwiftUI

struct MobileRootView: View {
    let profiles: MobileProfileController

    @State private var playing: JellyfinItem?
    @Environment(\.scenePhase) private var scenePhase

    private var model: MobileModel {
        profiles.model
    }

    var body: some View {
        TabView {
            Tab("Home", systemImage: "play.house") {
                NavigationStack {
                    MobileHomeView(model: model)
                        .mobileDestinations(model: model)
                }
            }

            if model.jellyfin.isSignedIn {
                Tab("Library", systemImage: "film.stack") {
                    NavigationStack {
                        MobileLibrariesView(model: model)
                            .mobileDestinations(model: model)
                    }
                }
            }

            Tab("Watchlist", systemImage: "bookmark") {
                NavigationStack {
                    MobileWatchlistView(model: model)
                        .mobileDestinations(model: model)
                }
            }

            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    MobileSettingsView(profiles: profiles)
                }
            }

            Tab(role: .search) {
                NavigationStack {
                    MobileSearchView(model: model)
                        .mobileDestinations(model: model)
                }
            }
        }
        // A fresh view tree per profile.
        .id(profiles.current)
        .environment(\.playJellyfinItem) { item in
            playing = item
        }
        .fullScreenCover(item: $playing) { item in
            MobilePlayerView(connection: model.jellyfin, item: item)
        }
        // Pick up services and the Jellyfin server set on other devices.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.settingsSync?.refresh() }
                Task { await model.trakt.syncHistory(into: model.watchlist) }
            }
        }
    }
}

struct MobilePlayerView: View {
    let connection: JellyfinConnection
    let item: JellyfinItem

    @Environment(\.dismiss) private var dismiss
    @State private var playback: JellyfinPlayback?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let playback {
                PlayerViewController(playback: playback)
                    .ignoresSafeArea()
            } else if let errorMessage {
                VStack(spacing: 20) {
                    ContentUnavailableView(
                        "Can’t Play \(item.displayTitle)",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                    Button("Close") { dismiss() }
                }
                .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        #if os(iOS)
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close")
            .padding()
        }
        .overlay(alignment: .topTrailing) {
            if let playback, !playback.subtitles.isEmpty {
                JellyfinSubtitleMenu(playback: playback)
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding()
            }
        }
        #endif
        // Cancelled when the player closes, which stops playback and tells
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

private struct PlayerViewController: UIViewControllerRepresentable {
    let playback: JellyfinPlayback

    private var player: AVPlayer {
        playback.player
    }

    func makeUIViewController(context _: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        #if os(iOS)
            controller.allowsPictureInPicturePlayback = true
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context _: Context) {
        if controller.player !== player {
            controller.player = player
        }
        #if os(tvOS)
            controller.transportBarCustomMenuItems = subtitleMenu.map { [$0] } ?? []
        #endif
    }

    #if os(tvOS)
        /// Jellyfin's subtitles, chosen from the player's transport bar.
        private var subtitleMenu: UIMenu? {
            guard !playback.subtitles.isEmpty else { return nil }
            let playback = playback
            let choices = [(index: Int?.none, title: "Off")]
                + playback.subtitles.map { (index: Int?.some($0.index), title: $0.title) }
            let actions = choices.map { choice in
                UIAction(title: choice.title, state: playback.selectedSubtitle == choice.index ? .on : .off) { _ in
                    Task { await playback.selectSubtitle(choice.index) }
                }
            }
            return UIMenu(
                title: "Subtitles",
                image: UIImage(systemName: "captions.bubble"),
                options: .singleSelection,
                children: actions
            )
        }
    #endif
}
