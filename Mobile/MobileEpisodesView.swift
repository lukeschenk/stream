import SwiftUI

/// "Pick up" for a show: the episode last opened from Stream, the one after
/// it, and a way into the full episode list.
struct MobilePickUpSection: View {
    let model: MobileModel
    let media: TMDBMediaResult
    let links: TitleLinks?
    let open: (TitleEpisode) -> Void

    var body: some View {
        if let links, !links.seasons.isEmpty {
            Section {
                if let progress = model.progress(for: media) {
                    pickUp(progress, links: links)
                } else if let first = links.episodes.first {
                    Button {
                        open(first)
                    } label: {
                        Label("Start with \(first.label)", systemImage: "play.fill")
                    }
                }

                NavigationLink {
                    MobileEpisodesView(model: model, media: media, links: links, open: open)
                } label: {
                    Label("All Episodes", systemImage: "list.number")
                }
            } header: {
                Text("Pick Up")
            } footer: {
                Text("Stream remembers the episode you last opened here.")
            }
        }
    }

    @ViewBuilder
    private func pickUp(_ progress: EpisodeProgress, links: TitleLinks) -> some View {
        let current = links.episode(season: progress.season, number: progress.episode)

        VStack(alignment: .leading, spacing: 2) {
            Text("Last opened \(progress.label)")
                .font(.headline)
            Text(
                [progress.episodeTitle, progress.updatedAt.formatted(.relative(presentation: .named))]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        if let current, let next = links.episode(after: current) {
            Button {
                open(next)
            } label: {
                Label("Next: \(next.label) · \(next.title)", systemImage: "forward.fill")
            }
        }

        if let current {
            Button {
                open(current)
            } label: {
                Label("Resume \(current.label)", systemImage: "play.fill")
            }
        }
    }
}

struct MobileEpisodesView: View {
    let model: MobileModel
    let media: TMDBMediaResult
    let links: TitleLinks
    let open: (TitleEpisode) -> Void

    @State private var seasonNumber: Int?

    private var selectedSeason: TitleSeason? {
        links.seasons.first { $0.number == seasonNumber } ?? links.seasons.first
    }

    var body: some View {
        List {
            if links.seasons.count > 1 {
                Picker("Season", selection: $seasonNumber) {
                    ForEach(links.seasons) { season in
                        Text(season.title).tag(Optional(season.number))
                    }
                }
            }

            ForEach(selectedSeason?.episodes ?? []) { episode in
                Button {
                    open(episode)
                } label: {
                    row(for: episode)
                }
                .disabled(episode.service(preferring: model.myServices) == nil)
            }
        }
        .navigationTitle(media.title)
        .onAppear {
            if seasonNumber == nil {
                seasonNumber = model.progress(for: media)?.season ?? links.seasons.first?.number
            }
        }
    }

    private func row(for episode: TitleEpisode) -> some View {
        let progress = model.progress(for: media)
        let isLastOpened = progress?.season == episode.season && progress?.episode == episode.number
        let service = episode.service(preferring: model.myServices)

        return HStack(alignment: .top, spacing: 12) {
            Text("\(episode.number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.headline)
                if let overview = episode.overview {
                    Text(overview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let service {
                    Text(service.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("Not streaming")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if isLastOpened {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Last opened")
            }
        }
        .padding(.vertical, 4)
    }
}
