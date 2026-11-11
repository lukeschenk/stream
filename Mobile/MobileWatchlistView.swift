import SwiftUI

struct MobileWatchlistView: View {
    let model: MobileModel

    var body: some View {
        List {
            ForEach(model.watchlist.items) { item in
                row(for: item)
                    .contextMenu {
                        Button("Remove from Watchlist", systemImage: "bookmark.slash", role: .destructive) {
                            model.watchlist.remove(id: item.id)
                        }
                    }
            }
            #if os(iOS)
            .onDelete { offsets in
                let ids = offsets.map { model.watchlist.items[$0].id }
                for id in ids {
                    model.watchlist.remove(id: id)
                }
            }
            #endif
        }
        .overlay {
            if model.watchlist.items.isEmpty {
                ContentUnavailableView(
                    "Your Watchlist Is Empty",
                    systemImage: "bookmark",
                    description: Text("Add titles from Search, or on your Mac. iCloud keeps them in sync.")
                )
            }
        }
        .navigationTitle("Watchlist")
    }

    @ViewBuilder
    private func row(for item: WatchlistItem) -> some View {
        let label = WatchlistRowLabel(
            title: item.title,
            year: item.year.map(String.init) ?? item.tmdbMetadata?.year,
            posterURL: model.search.imageConfiguration?.posterURL(path: item.tmdbMetadata?.posterPath)
        )

        if let media = item.tmdbMetadata {
            NavigationLink(value: MobileRoute.media(media)) {
                label
            }
        } else {
            label
        }
    }
}

private struct WatchlistRowLabel: View {
    let title: String
    let year: String?
    let posterURL: URL?

    var body: some View {
        HStack(spacing: 14) {
            MobileArtwork(url: posterURL, aspectRatio: 2 / 3)
                .frame(width: MobileLayout.posterWidth * 0.45)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let year {
                    Text(year)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct MobileSearchView: View {
    let model: MobileModel
    @AppStorage("searchOnlyMyServices") private var onlyMyServices = false

    private var search: TMDBSearchModel {
        model.search
    }

    private var filtersToMyServices: Bool {
        onlyMyServices && model.hasServices
    }

    private var displayedResults: [TMDBMediaResult] {
        guard filtersToMyServices else { return search.results }
        return search.results.filter { model.myServices(streaming: $0)?.isEmpty == false }
    }

    var body: some View {
        List {
            if model.hasServices, !search.results.isEmpty {
                Toggle("Only On My Services", isOn: $onlyMyServices)
            }

            ForEach(displayedResults) { media in
                NavigationLink(value: MobileRoute.media(media)) {
                    resultRow(media)
                }
                .onAppear {
                    if !filtersToMyServices {
                        search.loadMoreIfNeeded(after: media)
                    }
                }
            }

            if search.isSearching || search.isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let error = search.errorMessage {
                MobileErrorView(message: error) { search.retry() }
            } else if filtersToMyServices {
                filterFooter
            }
        }
        .navigationTitle("Search")
        .searchable(text: queryBinding, prompt: "Movies and TV shows")
        .task(id: PrefetchKey(ids: search.results.map(\.id), filtering: filtersToMyServices)) {
            if filtersToMyServices {
                model.availability.prefetch(search.results, region: search.selectedRegion)
            } else {
                model.availability.cancelPending()
            }
        }
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { search.query },
            set: {
                search.query = $0
                search.queryChanged()
            }
        )
    }

    @ViewBuilder
    private var filterFooter: some View {
        if model.availability.pendingCount > 0 {
            Label("Checking your services…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        } else if search.canLoadMore, let last = search.results.last {
            Button("Search More Titles") {
                search.loadMoreIfNeeded(after: last)
            }
        }
    }

    private func resultRow(_ media: TMDBMediaResult) -> some View {
        HStack(spacing: 14) {
            MobileArtwork(
                url: search.imageConfiguration?.posterURL(path: media.posterPath),
                aspectRatio: 2 / 3
            )
            .frame(width: MobileLayout.posterWidth * 0.45)

            VStack(alignment: .leading, spacing: 4) {
                Text(media.title)
                    .font(.headline)
                Text([media.mediaType == .movie ? "Movie" : "TV Show", media.year].compactMap { $0 }
                    .joined(separator: " · "))
                    .foregroundStyle(.secondary)
                if let services = model.myServices(streaming: media), !services.isEmpty {
                    Label(services.map(\.name).joined(separator: " · "), systemImage: "play.tv")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

private struct PrefetchKey: Hashable {
    let ids: [TMDBMediaResult.ID]
    let filtering: Bool
}
