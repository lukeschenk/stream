import SwiftUI

/// A movie or show: where it's streaming, whether it's in your Jellyfin
/// library, and its place on your watchlist.
struct MobileMediaView: View {
    let model: MobileModel
    let media: TMDBMediaResult

    @Environment(\.openURL) private var openURL
    @Environment(\.playJellyfinItem) private var play
    @State private var availability: TMDBWatchAvailability?
    @State private var hasLoadedAvailability = false
    @State private var libraryItem: JellyfinItem?
    @State private var errorMessage: String?
    @State private var unopenedService: StreamingService?

    private var region: String {
        model.search.selectedRegion
    }

    private var links: TitleLinks? {
        model.titleLinks.links(for: media, region: region)
    }

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)

            actions

            if media.mediaType == .tv {
                MobilePickUpSection(model: model, media: media, links: links, open: openEpisode)
            }

            if !hasLoadedAvailability {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let errorMessage {
                MobileErrorView(message: errorMessage) {
                    Task { await loadAvailability() }
                }
            } else {
                providerSections
            }
        }
        .navigationTitle(media.title)
        .task { await loadAvailability() }
        .task { await model.titleLinks.load(for: media, region: region) }
        .task(id: model.jellyfin.account) { await findInLibrary() }
        .alert(
            "Open \(unopenedService?.name ?? "the App")",
            isPresented: Binding(
                get: { unopenedService != nil },
                set: { if !$0 { unopenedService = nil } }
            )
        ) {
            Button("OK") { unopenedService = nil }
        } message: {
            Text("Stream can’t open \(unopenedService?.name ?? "this service") directly here. "
                + "Open its app and search for \(media.title).")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            MobileArtwork(
                url: model.search.imageConfiguration?.posterURL(path: media.posterPath),
                aspectRatio: 2 / 3
            )
            .frame(width: MobileLayout.posterWidth)

            VStack(alignment: .leading, spacing: 6) {
                Text(media.title)
                    .font(.title2.weight(.semibold))
                Text([media.mediaType == .movie ? "Movie" : "TV Show", media.year].compactMap { $0 }
                    .joined(separator: " · "))
                    .foregroundStyle(.secondary)
                if !media.overview.isEmpty {
                    Text(media.overview)
                        .font(.callout)
                        .lineLimit(8)
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Section {
            if let libraryItem {
                if libraryItem.kind == .series {
                    NavigationLink(value: MobileRoute.jellyfinSeries(libraryItem)) {
                        Label("Watch from Your Library", systemImage: "play.fill")
                    }
                } else {
                    Button {
                        play(libraryItem)
                    } label: {
                        Label(
                            libraryItem.progress == nil ? "Play from Your Library" : "Resume from Your Library",
                            systemImage: "play.fill"
                        )
                    }
                }
            }

            if let appleTV = links?.appleTV {
                Button {
                    openURL(appleTV)
                } label: {
                    Label("Open in the TV App", systemImage: "appletv")
                }
            }

            let isSaved = model.watchlistItem(for: media) != nil
            Button {
                model.toggleWatchlist(media)
            } label: {
                Label(
                    isSaved ? "Remove from Watchlist" : "Add to Watchlist",
                    systemImage: isSaved ? "bookmark.fill" : "bookmark"
                )
            }
        }
    }

    @ViewBuilder
    private var providerSections: some View {
        let included = MyServices.streamingProviders(in: availability)
        let paid = (availability?[.rent] ?? []) + (availability?[.buy] ?? [])

        if included.isEmpty, paid.isEmpty {
            Text("Not streaming anywhere in \(regionName) right now.")
                .foregroundStyle(.secondary)
        }

        if !included.isEmpty {
            Section("Streaming") {
                ForEach(included) { provider in
                    providerRow(provider)
                }
            }
        }

        if !paid.isEmpty {
            Section("Rent or Buy") {
                ForEach(uniqueByID(paid)) { provider in
                    providerRow(provider)
                }
            }
        }
    }

    private func providerRow(_ provider: TMDBProvider) -> some View {
        let service = StreamingServiceCatalog.service(forProviderName: provider.name)
        let isMine = !MyServices.sites(streaming: [provider], from: model.services.sites).isEmpty

        return Button {
            if let service {
                open(service)
            }
        } label: {
            HStack(spacing: 14) {
                AsyncImage(url: model.search.imageConfiguration?.logoURL(path: provider.logoPath)) { phase in
                    phase.image?.resizable().scaledToFit()
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                    if let detail = detail(isMine: isMine, service: service) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(isMine ? Color.accentColor : .secondary)
                    }
                }

                Spacer()

                if service != nil {
                    Image(systemName: "arrow.up.forward.app")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(service == nil)
    }

    // MARK: Actions

    private var regionName: String {
        model.search.regions.first { $0.isoCode == region }?.displayName ?? region
    }

    private func detail(isMine: Bool, service: StreamingService?) -> String? {
        let opensTitle = service.flatMap { links?.url(for: $0) } != nil
        switch (isMine, opensTitle) {
        case (true, true): return "Your service · Opens to this title"
        case (true, false): return "Your service"
        case (false, true): return "Opens to this title"
        case (false, false): return nil
        }
    }

    private func open(_ service: StreamingService) {
        #if os(tvOS)
            let platform = ServiceLauncher.Platform.appleTV
        #else
            let platform = ServiceLauncher.Platform.touch
        #endif

        let candidates = ServiceLauncher.candidates(
            for: service,
            title: media.title,
            links: links,
            platform: platform
        )
        open(candidates, fallingBackTo: service)
    }

    private func openEpisode(_ episode: TitleEpisode) {
        guard let service = episode.service(preferring: model.myServices) else { return }

        model.recordEpisode(episode, of: media)
        let urls = ServiceLauncher.candidates(
            for: episode,
            service: service,
            title: media.title,
            links: links,
            platform: .current
        )
        open(urls, fallingBackTo: service)
    }

    /// Tries each link in turn; an app that doesn't claim a link refuses it.
    private func open(_ urls: [URL], fallingBackTo service: StreamingService) {
        guard let url = urls.first else {
            unopenedService = service
            return
        }

        openURL(url) { accepted in
            if !accepted {
                open(Array(urls.dropFirst()), fallingBackTo: service)
            }
        }
    }

    private func loadAvailability() async {
        do {
            availability = try await model.tmdbClient.watchProviders(for: media, region: region)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        hasLoadedAvailability = true
    }

    private func findInLibrary() async {
        guard let client = model.jellyfin.client,
              let userID = model.jellyfin.account?.userID
        else {
            libraryItem = nil
            return
        }

        let candidates = (try? await client.search(term: media.title, userID: userID)) ?? []
        libraryItem = JellyfinLibraryMatch.item(for: media, in: candidates)
    }

    private func uniqueByID(_ providers: [TMDBProvider]) -> [TMDBProvider] {
        var seen = Set<Int>()
        return providers.filter { seen.insert($0.id).inserted }
    }
}
