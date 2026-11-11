import SwiftUI

/// Where to pick up a show, with every episode a click away.
struct EpisodePickUpView: View {
    @Bindable var model: AppModel
    let media: TMDBMediaResult
    let links: TitleLinks

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Episodes").font(.headline)

            if let summary = model.showSchedules.schedule(for: media)?.summary() {
                Label(summary, systemImage: "calendar")
                    .foregroundStyle(.secondary)
            }

            if let progress = model.progress(for: media) {
                pickUp(progress)
            } else if let first = links.episodes.first(where: model.canOpen) {
                Button("Start with \(first.label)") {
                    model.openEpisode(first, of: media)
                }
                .buttonStyle(.borderedProminent)
            }

            Menu("All Episodes") {
                ForEach(links.seasons) { season in
                    Menu(season.title) {
                        ForEach(season.episodes) { episode in
                            Button("\(episode.number). \(episode.title)") {
                                model.openEpisode(episode, of: media)
                            }
                            .disabled(!model.canOpen(episode))
                        }
                    }
                }
            }
            .fixedSize()

            if !links.episodes.contains(where: model.canOpen) {
                Text("None of the services in your sidebar have this show’s episodes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func pickUp(_ progress: EpisodeProgress) -> some View {
        let current = links.episode(season: progress.season, number: progress.episode)
        let next = current.flatMap { links.episode(after: $0) }

        Text(
            ["Last opened \(progress.label)", progress.episodeTitle,
             progress.updatedAt.formatted(.relative(presentation: .named))]
                .compactMap { $0 }
                .joined(separator: " · ")
        )
        .foregroundStyle(.secondary)

        HStack {
            if let next {
                Button("Next: \(next.label) · \(next.title)") {
                    model.openEpisode(next, of: media)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canOpen(next))
            }
            if let current {
                Button("Resume \(current.label)") {
                    model.openEpisode(current, of: media)
                }
                .disabled(!model.canOpen(current))
            }
        }
    }
}
