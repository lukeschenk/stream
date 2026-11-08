import SwiftUI

struct MobileLibrariesView: View {
    let model: MobileModel

    var body: some View {
        List {
            ForEach(model.jellyfin.libraries) { library in
                NavigationLink(value: MobileRoute.jellyfinFolder(library)) {
                    Label(library.displayTitle, systemImage: library.librarySystemImage)
                }
            }

            if let error = model.jellyfin.librariesError {
                MobileErrorView(message: error) {
                    Task { await model.jellyfin.refreshLibraries() }
                }
            }
        }
        .overlay {
            if model.jellyfin.isLoadingLibraries, model.jellyfin.libraries.isEmpty {
                ProgressView()
            }
        }
        .navigationTitle(model.jellyfin.account?.serverName ?? "Library")
        .task(id: model.jellyfin.account) {
            await model.jellyfin.refreshLibraries()
        }
    }
}

struct MobileLibraryGridView: View {
    let model: MobileModel
    let parent: JellyfinItem

    @State private var items: [JellyfinItem] = []
    @State private var totalCount: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: MobileLayout.posterWidth), spacing: MobileLayout.spacing)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: MobileLayout.spacing) {
                ForEach(items) { item in
                    JellyfinItemLink(item: item) {
                        JellyfinCard(
                            item: item,
                            imageURL: model.jellyfin.client?.imageURL(for: item, maxWidth: 500),
                            aspectRatio: 2 / 3,
                            width: MobileLayout.posterWidth
                        )
                    }
                    .onAppear {
                        if item.id == items.last?.id {
                            Task { await loadMore() }
                        }
                    }
                }
            }
            .padding()

            if isLoading {
                ProgressView().padding()
            } else if let errorMessage {
                MobileErrorView(message: errorMessage) {
                    Task { await loadMore() }
                }
            }
        }
        .overlay {
            if !isLoading, errorMessage == nil, totalCount == 0 {
                ContentUnavailableView("Nothing Here Yet", systemImage: "film.stack")
            }
        }
        .navigationTitle(parent.displayTitle)
        .task {
            if items.isEmpty {
                await loadMore()
            }
        }
    }

    private func loadMore() async {
        guard !isLoading,
              let client = model.jellyfin.client,
              let userID = model.jellyfin.account?.userID
        else { return }

        if let totalCount, items.count >= totalCount {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await client.items(
                userID: userID,
                parentID: parent.id,
                collectionType: parent.collectionType,
                startIndex: items.count
            )
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            totalCount = page.items.isEmpty ? items.count : page.totalCount
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            model.jellyfin.handle(error)
            errorMessage = error.localizedDescription
        }
    }
}

struct MobileSeriesView: View {
    let model: MobileModel
    let series: JellyfinItem

    @Environment(\.playJellyfinItem) private var play
    @State private var seasons: [JellyfinItem] = []
    @State private var selectedSeasonID: String?
    @State private var episodes: [JellyfinItem] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let overview = series.overview {
                Text(overview)
                    .foregroundStyle(.secondary)
            }

            if seasons.count > 1 {
                Picker("Season", selection: $selectedSeasonID) {
                    ForEach(seasons) { season in
                        Text(season.displayTitle).tag(Optional(season.id))
                    }
                }
            }

            Section {
                ForEach(episodes) { episode in
                    Button {
                        play(episode)
                    } label: {
                        episodeRow(episode)
                    }
                }
            }

            if let errorMessage {
                MobileErrorView(message: errorMessage) {
                    Task { await loadSeasons() }
                }
            }
        }
        .navigationTitle(series.displayTitle)
        .task { await loadSeasons() }
        .task(id: selectedSeasonID) { await loadEpisodes() }
    }

    private func episodeRow(_ episode: JellyfinItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            MobileArtwork(
                url: model.jellyfin.client?.imageURL(for: episode, maxWidth: 500),
                aspectRatio: 16 / 9,
                progress: episode.progress,
                isPlayed: episode.isPlayed
            )
            .frame(width: MobileLayout.landscapeWidth * 0.6)

            VStack(alignment: .leading, spacing: 4) {
                Text([episode.episodeLabel, episode.displayTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                if let overview = episode.overview {
                    Text(overview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func loadSeasons() async {
        guard let client = model.jellyfin.client,
              let userID = model.jellyfin.account?.userID
        else { return }

        do {
            seasons = try await client.seasons(seriesID: series.id, userID: userID)
            errorMessage = nil
            if selectedSeasonID == nil {
                selectedSeasonID = (
                    seasons.first { ($0.userData?.unplayedItemCount ?? 0) > 0 } ?? seasons.first
                )?.id
            }
        } catch is CancellationError {
            return
        } catch {
            model.jellyfin.handle(error)
            errorMessage = error.localizedDescription
        }
    }

    private func loadEpisodes() async {
        guard let seasonID = selectedSeasonID,
              let client = model.jellyfin.client,
              let userID = model.jellyfin.account?.userID
        else { return }

        do {
            episodes = try await client.episodes(seriesID: series.id, seasonID: seasonID, userID: userID)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            model.jellyfin.handle(error)
            errorMessage = error.localizedDescription
        }
    }
}
