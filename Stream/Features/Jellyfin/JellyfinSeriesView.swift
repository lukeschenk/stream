import SwiftUI

struct JellyfinSeriesView: View {
    let connection: JellyfinConnection
    let series: JellyfinItem
    let onPlay: (JellyfinItem) -> Void

    @State private var seasons: [JellyfinItem] = []
    @State private var selectedSeasonID: String?
    @State private var episodes: [JellyfinItem] = []
    @State private var isLoadingEpisodes = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)

            if seasons.count > 1 {
                Picker("Season", selection: $selectedSeasonID) {
                    ForEach(seasons) { season in
                        Text(season.displayTitle).tag(Optional(season.id))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .listRowSeparator(.hidden)
            }

            ForEach(episodes) { episode in
                Button {
                    onPlay(episode)
                } label: {
                    JellyfinEpisodeRow(
                        episode: episode,
                        imageURL: connection.client?.imageURL(for: episode, maxWidth: 400)
                    )
                }
                .buttonStyle(.plain)
            }

            if isLoadingEpisodes || errorMessage != nil {
                JellyfinLoadingFooter(isLoading: isLoadingEpisodes, errorMessage: errorMessage) {
                    Task { await loadSeasons() }
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .navigationTitle(series.displayTitle)
        .task { await loadSeasons() }
        .task(id: selectedSeasonID) { await loadEpisodes() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            Color.secondary.opacity(0.12)
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(width: 120)
                .overlay {
                    AsyncImage(url: connection.client?.imageURL(for: series, maxWidth: 300)) { phase in
                        phase.image?.resizable().scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                Text(series.displayTitle)
                    .font(.largeTitle.weight(.semibold))
                if let year = series.productionYear {
                    Text(String(year))
                        .foregroundStyle(.secondary)
                }
                if let overview = series.overview {
                    Text(overview)
                        .lineLimit(6)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func loadSeasons() async {
        guard let client = connection.client,
              let userID = connection.account?.userID
        else { return }

        do {
            seasons = try await client.seasons(seriesID: series.id, userID: userID)
            errorMessage = nil
            if selectedSeasonID == nil {
                // Open on the first season that still has something to watch.
                selectedSeasonID = (
                    seasons.first { ($0.userData?.unplayedItemCount ?? 0) > 0 } ?? seasons.first
                )?.id
            }
        } catch is CancellationError {
            return
        } catch {
            connection.handle(error)
            errorMessage = error.localizedDescription
        }
    }

    private func loadEpisodes() async {
        guard let seasonID = selectedSeasonID,
              let client = connection.client,
              let userID = connection.account?.userID
        else { return }

        isLoadingEpisodes = true
        defer { isLoadingEpisodes = false }

        do {
            episodes = try await client.episodes(seriesID: series.id, seasonID: seasonID, userID: userID)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            connection.handle(error)
            errorMessage = error.localizedDescription
        }
    }
}

private struct JellyfinEpisodeRow: View {
    let episode: JellyfinItem
    let imageURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Color.secondary.opacity(0.12)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: 180)
                .overlay {
                    AsyncImage(url: imageURL) { phase in
                        phase.image?.resizable().scaledToFill()
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress = episode.progress, !episode.isPlayed {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let label = episode.episodeLabel {
                        Text(label)
                            .foregroundStyle(.secondary)
                    }
                    Text(episode.displayTitle)
                        .fontWeight(.medium)
                    if episode.isPlayed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Watched")
                    }
                }
                if let overview = episode.overview {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
