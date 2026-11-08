import SwiftUI

struct MobileHomeView: View {
    let model: MobileModel

    @State private var resume: [JellyfinItem] = []
    @State private var nextUp: [JellyfinItem] = []
    @State private var errorMessage: String?

    private var jellyfin: JellyfinConnection {
        model.jellyfin
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if !jellyfin.isSignedIn || !model.hasServices {
                    MobileGetStarted(model: model)
                        .padding(.horizontal)
                }

                if !resume.isEmpty {
                    jellyfinShelf("Continue Watching", items: resume)
                }
                if !nextUp.isEmpty {
                    jellyfinShelf("Next Up", items: nextUp)
                }
                if let errorMessage {
                    MobileErrorView(message: errorMessage) {
                        Task { await load() }
                    }
                }

                watchlistShelf
            }
            .padding(.vertical)
        }
        .navigationTitle(model.profile == .main ? "Home" : "\(model.profile.displayName) Home")
        .task(id: jellyfin.account) { await load() }
        #if os(iOS)
            .refreshable { await load() }
        #endif
    }

    private func jellyfinShelf(_ title: String, items: [JellyfinItem]) -> some View {
        MobileShelf(title: title) {
            ForEach(items) { item in
                JellyfinItemLink(item: item) {
                    JellyfinCard(
                        item: item,
                        imageURL: jellyfin.client?.landscapeImageURL(for: item, maxWidth: 800),
                        aspectRatio: 16 / 9,
                        width: MobileLayout.landscapeWidth
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var watchlistShelf: some View {
        let items = model.watchlist.items.compactMap(\.tmdbMetadata)
        if !items.isEmpty {
            MobileShelf(title: "Watchlist") {
                ForEach(items) { media in
                    NavigationLink(value: MobileRoute.media(media)) {
                        MobileMediaCard(
                            media: media,
                            posterURL: model.search.imageConfiguration?.posterURL(path: media.posterPath)
                        )
                    }
                    .cardButtonStyle()
                }
            }
        }
    }

    private func load() async {
        guard let client = jellyfin.client,
              let userID = jellyfin.account?.userID
        else {
            resume = []
            nextUp = []
            return
        }

        do {
            async let resumeItems = client.resumeItems(userID: userID)
            async let nextUpItems = client.nextUp(userID: userID)
            let (loadedResume, loadedNextUp) = try await (resumeItems, nextUpItems)
            resume = loadedResume
            nextUp = loadedNextUp
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            jellyfin.handle(error)
            errorMessage = error.localizedDescription
        }
    }
}

struct MobileMediaCard: View {
    let media: TMDBMediaResult
    let posterURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MobileArtwork(url: posterURL, aspectRatio: 2 / 3)
            Text(media.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let year = media.year {
                Text(year)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: MobileLayout.posterWidth)
    }
}

/// Shown until Jellyfin and at least one service are set up.
private struct MobileGetStarted: View {
    let model: MobileModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up Stream")
                .font(.title2.weight(.semibold))

            if !model.hasServices {
                NavigationLink {
                    MobileServicesView(model: model)
                } label: {
                    Label("Choose your streaming services", systemImage: "square.grid.2x2")
                }
            }
            if !model.jellyfin.isSignedIn {
                NavigationLink {
                    JellyfinSettingsView(connection: model.jellyfin, profile: model.profile)
                        .navigationTitle("Jellyfin")
                } label: {
                    Label("Connect your Jellyfin server", systemImage: "server.rack")
                }
            }

            Text("Your watchlist syncs from your Mac through iCloud.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
}
