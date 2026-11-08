import SwiftUI

enum MobileRoute: Hashable {
    case jellyfinFolder(JellyfinItem)
    case jellyfinSeries(JellyfinItem)
    case media(TMDBMediaResult)
}

extension EnvironmentValues {
    /// Starts full-screen Jellyfin playback. Set by the root view.
    @Entry var playJellyfinItem: (JellyfinItem) -> Void = { _ in }
}

extension View {
    /// Pushes the shared screens from any tab.
    func mobileDestinations(model: MobileModel) -> some View {
        navigationDestination(for: MobileRoute.self) { route in
            switch route {
            case let .jellyfinFolder(folder):
                MobileLibraryGridView(model: model, parent: folder)
            case let .jellyfinSeries(series):
                MobileSeriesView(model: model, series: series)
            case let .media(media):
                MobileMediaView(model: model, media: media)
            }
        }
    }

    /// The focus-friendly card style on Apple TV, plain elsewhere.
    @ViewBuilder
    func cardButtonStyle() -> some View {
        #if os(tvOS)
            buttonStyle(.card)
        #else
            buttonStyle(.plain)
        #endif
    }
}

enum MobileLayout {
    #if os(tvOS)
        static let posterWidth: CGFloat = 220
        static let landscapeWidth: CGFloat = 420
        static let spacing: CGFloat = 40
    #else
        static let posterWidth: CGFloat = 120
        static let landscapeWidth: CGFloat = 250
        static let spacing: CGFloat = 16
    #endif
}

/// Opens a Jellyfin item: series and folders push, everything else plays.
struct JellyfinItemLink<Label: View>: View {
    let item: JellyfinItem
    @ViewBuilder let label: () -> Label

    @Environment(\.playJellyfinItem) private var play

    var body: some View {
        switch item.kind {
        case .series:
            NavigationLink(value: MobileRoute.jellyfinSeries(item), label: label)
                .cardButtonStyle()
        case .season, .folder, .other:
            NavigationLink(value: MobileRoute.jellyfinFolder(item), label: label)
                .cardButtonStyle()
        case .movie, .episode, .video:
            Button {
                play(item)
            } label: {
                label()
            }
            .cardButtonStyle()
        }
    }
}

struct MobileArtwork: View {
    let url: URL?
    let aspectRatio: CGFloat
    var placeholder = "film"
    var progress: Double?
    var isPlayed = false

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: placeholder)
                            .font(.title)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let progress, !isPlayed {
                    ProgressView(value: progress)
                        .tint(.accentColor)
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isPlayed {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct JellyfinCard: View {
    let item: JellyfinItem
    let imageURL: URL?
    let aspectRatio: CGFloat
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MobileArtwork(
                url: imageURL,
                aspectRatio: aspectRatio,
                placeholder: item.kind == .series ? "tv" : "film",
                progress: item.progress,
                isPlayed: item.isPlayed
            )

            Text(item.displayTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width)
    }
}

/// A titled, horizontally scrolling row.
struct MobileShelf<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.semibold))
                .padding(.horizontal)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: MobileLayout.spacing) {
                    content()
                }
                .padding(.horizontal)
                #if os(tvOS)
                    .padding(.vertical, 30)
                #endif
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
                .scrollClipDisabled()
            #endif
        }
    }
}

struct MobileErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
