import SwiftUI

enum JellyfinRoute: Hashable {
    case series(JellyfinItem)
    case folder(JellyfinItem)
    case player(JellyfinItem)
}

/// The detail pane for a Jellyfin sidebar row: a library grid or the
/// Continue Watching overview, with series and playback pushed on top.
struct JellyfinBrowseView: View {
    let connection: JellyfinConnection
    let destination: JellyfinDestination

    @State private var path: [JellyfinRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: JellyfinRoute.self) { route in
                    switch route {
                    case let .series(series):
                        JellyfinSeriesView(connection: connection, series: series, onPlay: play)
                    case let .folder(folder):
                        JellyfinLibraryView(connection: connection, parent: folder, onOpen: open)
                    case let .player(item):
                        JellyfinPlayerView(connection: connection, item: item)
                    }
                }
        }
        .id(destination)
    }

    @ViewBuilder
    private var root: some View {
        if !connection.isSignedIn {
            ContentUnavailableView(
                "Not Signed In",
                systemImage: "server.rack",
                description: Text("Sign in to your Jellyfin server in Settings.")
            )
        } else {
            switch destination {
            case .watching:
                JellyfinWatchingView(connection: connection, onOpen: open)
            case let .library(id):
                if let library = connection.library(id: id) {
                    JellyfinLibraryView(connection: connection, parent: library, onOpen: open)
                } else {
                    ContentUnavailableView(
                        "Library Unavailable",
                        systemImage: "rectangle.stack.badge.minus",
                        description: Text("This library is no longer on the server.")
                    )
                }
            }
        }
    }

    private func open(_ item: JellyfinItem) {
        switch item.kind {
        case .series:
            path.append(.series(item))
        case .movie, .episode, .video:
            path.append(.player(item))
        case .season, .folder, .other:
            path.append(.folder(item))
        }
    }

    private func play(_ item: JellyfinItem) {
        path.append(.player(item))
    }
}

// MARK: - Library grid

struct JellyfinLibraryView: View {
    let connection: JellyfinConnection
    let parent: JellyfinItem
    let onOpen: (JellyfinItem) -> Void

    @State private var items: [JellyfinItem] = []
    @State private var totalCount: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 20)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                ForEach(items) { item in
                    JellyfinPosterCard(
                        item: item,
                        imageURL: connection.client?.imageURL(for: item, maxWidth: 400),
                        aspectRatio: 2 / 3
                    ) {
                        onOpen(item)
                    }
                    .onAppear {
                        if item.id == items.last?.id {
                            Task { await loadMore() }
                        }
                    }
                }
            }
            .padding(24)

            JellyfinLoadingFooter(isLoading: isLoading, errorMessage: errorMessage) {
                Task { await loadMore() }
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
              let client = connection.client,
              let userID = connection.account?.userID
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
            connection.handle(error)
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Continue Watching and Next Up

struct JellyfinWatchingView: View {
    let connection: JellyfinConnection
    let onOpen: (JellyfinItem) -> Void

    @State private var resume: [JellyfinItem] = []
    @State private var nextUp: [JellyfinItem] = []
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                shelf("Continue Watching", items: resume)
                shelf("Next Up", items: nextUp)
            }
            .padding(24)

            JellyfinLoadingFooter(isLoading: !hasLoaded, errorMessage: errorMessage) {
                Task { await load() }
            }
        }
        .overlay {
            if hasLoaded, errorMessage == nil, resume.isEmpty, nextUp.isEmpty {
                ContentUnavailableView(
                    "Nothing in Progress",
                    systemImage: "play.circle",
                    description: Text("Start something from a library and it will show up here.")
                )
            }
        }
        .navigationTitle(connection.account?.serverName ?? "Jellyfin")
        // Reload when returning from the player so progress is current.
        .task { await load() }
    }

    @ViewBuilder
    private func shelf(_ title: String, items: [JellyfinItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title2.weight(.semibold))

                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(items) { item in
                        JellyfinPosterCard(
                            item: item,
                            imageURL: connection.client?.landscapeImageURL(for: item, maxWidth: 600),
                            aspectRatio: 16 / 9
                        ) {
                            onOpen(item)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        guard let client = connection.client,
              let userID = connection.account?.userID
        else { return }

        do {
            async let resumeItems = client.resumeItems(userID: userID)
            async let nextUpItems = client.nextUp(userID: userID)
            (resume, nextUp) = try await (resumeItems, nextUpItems)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            connection.handle(error)
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }
}

// MARK: - Shared pieces

struct JellyfinPosterCard: View {
    let item: JellyfinItem
    let imageURL: URL?
    let aspectRatio: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                artwork

                Text(item.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.overview ?? item.displayTitle)
    }

    private var artwork: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: item.kind == .series ? "tv" : "film")
                            .font(.title)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let progress = item.progress, !item.isPlayed {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.isPlayed {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                } else if let unplayed = item.userData?.unplayedItemCount, unplayed > 0, item.kind == .series {
                    Text("\(unplayed)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct JellyfinLoadingFooter: View {
    let isLoading: Bool
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                VStack(spacing: 8) {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again", action: retry)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }
}
