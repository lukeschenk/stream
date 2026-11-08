import SwiftUI

struct CommandPaletteView: View {
    @Bindable var model: AppModel
    let onAction: (CommandPaletteAction) -> Void
    let onDismiss: () -> Void

    @FocusState private var searchFieldIsFocused: Bool

    @State private var selectedResult: ResultID?
    @State private var scrollTarget: ResultID?
    @AppStorage("searchOnlyMyServices") private var onlyMyServices = false

    private enum ResultID: Hashable {
        case command(CommandPaletteAction)
        case media(TMDBMediaResult.ID)
    }

    private var search: TMDBSearchModel {
        model.tmdbSearch
    }

    private var commands: [CommandPaletteCommand] {
        CommandCatalog.commands(
            matching: search.query,
            sites: model.siteStore.sites,
            continueWatchingItems: model.continueWatchingStore.sortedItems
        )
    }

    private var visibleResultIDs: [ResultID] {
        commands.map { .command($0.action) }
            + (canSelectMediaResults
                ? displayedResults.map { .media($0.id) }
                : [])
    }

    private var availability: ServiceAvailabilityModel {
        model.serviceAvailability
    }

    private var hasLinkedServices: Bool {
        MyServices.hasLinkedServices(model.siteStore.sites)
    }

    private var filtersToMyServices: Bool {
        onlyMyServices && hasLinkedServices
    }

    /// Saved sites that stream the title, or `nil` while that's unknown.
    private func myServices(for media: TMDBMediaResult) -> [SavedSite]? {
        availability
            .streamingProviders(for: media, region: search.selectedRegion)
            .map { MyServices.sites(streaming: $0, from: model.siteStore.sites) }
    }

    private var displayedResults: [TMDBMediaResult] {
        guard filtersToMyServices else { return search.results }
        return search.results.filter { myServices(for: $0)?.isEmpty == false }
    }

    private var prefetchID: PrefetchID {
        PrefetchID(
            resultIDs: search.results.map(\.id),
            region: search.selectedRegion,
            isFiltering: filtersToMyServices
        )
    }

    private var canSelectMediaResults: Bool {
        !trimmedQuery.isEmpty
            && !search.isSearching
            && search.errorMessage == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if let selected = search.selectedMedia {
                TMDBAvailabilityView(model: model, media: selected) {
                    search.clearSelection()
                    searchFieldIsFocused = true
                }
            } else {
                resultsView
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .onAppear {
            searchFieldIsFocused = true
            selectedResult = visibleResultIDs.first
        }
        .task(id: prefetchID) {
            if prefetchID.isFiltering {
                availability.prefetch(search.results, region: search.selectedRegion)
            } else {
                availability.cancelPending()
            }
        }
        .onChange(of: search.focusRequest) {
            searchFieldIsFocused = true
        }
        .onChange(of: visibleResultIDs) { _, ids in
            guard let selectedResult, ids.contains(selectedResult) else {
                selectedResult = ids.first
                return
            }
        }
        .onKeyPress(.downArrow) {
            guard search.selectedMedia == nil else { return .ignored }
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard search.selectedMedia == nil else { return .ignored }
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.return) {
            guard search.selectedMedia == nil, selectedResult != nil else { return .ignored }
            activateSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            if search.selectedMedia != nil {
                search.clearSelection()
                searchFieldIsFocused = true
            } else {
                onDismiss()
            }
            return .handled
        }
    }

    private var searchBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(
                "Search Wianu",
                text: Bindable(search).query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 25, weight: .regular))
            .focused($searchFieldIsFocused)
            .onChange(of: search.query) { search.queryChanged() }
            if !search.query.isEmpty {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear Search")
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 19)
    }

    private var resultsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !commands.isEmpty {
                    sectionHeader("Actions")

                    ForEach(commands) { command in
                        commandRow(command)
                    }
                }
                searchResultsSection
            }
            .scrollTargetLayout()
            .padding(8)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $scrollTarget, anchor: .center)
        .onChange(of: selectedResult) { _, selection in
            scrollTarget = selection
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if !trimmedQuery.isEmpty {
            HStack {
                sectionHeader("Movies & TV")
                Spacer()
                if hasLinkedServices {
                    Toggle(isOn: $onlyMyServices) {
                        Label("On My Services", systemImage: "line.3.horizontal.decrease")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Only show titles included with the services in your sidebar")
                    .padding(.trailing, 10)
                }
            }
            mediaResults
        } else if commands.isEmpty {
            compactMessage(
                "No actions available",
                systemImage: "command",
                description: "Add a site to get started."
            )
        }
    }

    @ViewBuilder
    private var mediaResults: some View {
        if search.isSearching {
            HStack {
                Spacer()
                ProgressView("Searching TMDB…").padding(24)
                Spacer()
            }
        } else if let error = search.errorMessage {
            TMDBErrorView(search: search, error: error)
                .frame(minHeight: 180)
        } else if search.results.isEmpty {
            compactMessage(
                "No TMDB results",
                systemImage: "magnifyingglass",
                description: "Try another title or check the spelling."
            )
        } else {
            mediaResultRows
        }
    }

    @ViewBuilder
    private var mediaResultRows: some View {
        ForEach(displayedResults) { item in
            resultButton(id: .media(item.id), action: { search.select(item) }, content: {
                paletteMediaRow(
                    item: item,
                    posterURL: search.imageConfiguration?.posterURL(path: item.posterPath),
                    services: myServices(for: item)
                )
            })
            .onAppear {
                if !filtersToMyServices {
                    search.loadMoreIfNeeded(after: item)
                }
            }
        }
        if search.isLoadingMore {
            ProgressView().padding()
        } else if filtersToMyServices {
            myServicesFooter
        }
    }

    @ViewBuilder
    private var myServicesFooter: some View {
        if availability.pendingCount > 0 {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking your services…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else {
            VStack(spacing: 8) {
                if displayedResults.isEmpty {
                    Text("None of these are included with your services.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if search.canLoadMore, let last = search.results.last {
                    Button("Search More Titles") {
                        search.loadMoreIfNeeded(after: last)
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    private var trimmedQuery: String {
        search.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    private func commandRow(_ command: CommandPaletteCommand) -> some View {
        resultButton(id: .command(command.action), action: { onAction(command.action) }, content: {
            HStack(spacing: 12) {
                Image(systemName: command.systemImage)
                    .font(.system(size: 24))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if let subtitle = command.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .opacity(0.7)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        })
    }

    private func compactMessage(
        _ title: String,
        systemImage: String,
        description: String
    ) -> some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func moveSelection(by offset: Int) {
        let ids = visibleResultIDs
        guard !ids.isEmpty else {
            selectedResult = nil
            return
        }
        guard let selectedResult,
              let index = ids.firstIndex(of: selectedResult)
        else {
            selectedResult = ids.first
            return
        }
        self.selectedResult = ids[(index + offset + ids.count) % ids.count]
    }

    private func activateSelection() {
        switch selectedResult {
        case let .command(action):
            onAction(action)
        case let .media(id):
            guard let media = search.results.first(where: { $0.id == id })
            else {
                return
            }
            search.select(media)
        case nil:
            break
        }
    }
}

private extension CommandPaletteView {
    private func resultButton(
        id: ResultID,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> some View
    ) -> some View {
        let isSelected = selectedResult == id
        return Button(action: action) {
            content()
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
                .background(
                    isSelected ? Color.accentColor.opacity(0.35) : .clear,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : .clear)
                }
        }
        .buttonStyle(.plain)
        .id(id)
        .onHover { hovering in
            if hovering {
                selectedResult = id
            }
        }
    }

    private func paletteMediaRow(
        item: TMDBMediaResult,
        posterURL: URL?,
        services: [SavedSite]?
    ) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: posterURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "film")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
            .frame(width: 30, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text([item.mediaType == .movie ? "Movie" : "TV Show", item.year]
                    .compactMap(\.self).joined(separator: " · "))
                    .font(.system(size: 12))
                    .opacity(0.7)
                if let services, !services.isEmpty {
                    Label(
                        services.map(\.name).joined(separator: " · "),
                        systemImage: "play.tv"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .opacity(0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct PrefetchID: Hashable {
    let resultIDs: [TMDBMediaResult.ID]
    let region: String
    let isFiltering: Bool
}
