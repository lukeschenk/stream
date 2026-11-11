import Foundation
import Observation

@MainActor
@Observable
final class WatchlistStore {
    private(set) var items: [WatchlistItem] = []
    private(set) var persistenceError: String?

    @ObservationIgnored
    private let fileStore: JSONFileStore<[WatchlistItem]>

    /// Called after local edits with the IDs saved and deleted, so iCloud sync
    /// can upload them. Changes applied from iCloud don't trigger it.
    @ObservationIgnored
    var changeHandler: ((_ saved: [WatchlistItem.ID], _ deleted: [WatchlistItem.ID]) -> Void)?

    @ObservationIgnored
    private var snapshot: [WatchlistItem.ID: WatchlistItem] = [:]

    init(
        fileStore: JSONFileStore<[WatchlistItem]> = JSONFileStore(
            fileName: "letterboxd-watchlist.json",
            folderName: "Wianu"
        )
    ) {
        self.fileStore = fileStore
        load()
    }

    func item(id: WatchlistItem.ID) -> WatchlistItem? {
        items.first { $0.id == id }
    }

    func item(matching url: URL) -> WatchlistItem? {
        let key = URLNormalizer.comparisonKey(for: url)

        return items.first {
            $0.url.map(URLNormalizer.comparisonKey(for:)) == key
        }
    }

    func contains(url: URL) -> Bool {
        item(matching: url) != nil
    }

    func replaceImportedItems(with newItems: [WatchlistItem]) {
        let existingIDs = items.reduce(into: [String: WatchlistItem.ID]()) {
            ids, item in
            guard item.source == .letterboxd, let url = item.url else { return }

            ids[URLNormalizer.comparisonKey(for: url)] = item.id
        }

        let importedItems = newItems.enumerated().map { index, item in
            let existing = item.url.flatMap { self.item(matching: $0) }

            return WatchlistItem(
                id: item.url.flatMap {
                    existingIDs[URLNormalizer.comparisonKey(for: $0)]
                } ?? item.id,
                title: item.title,
                year: item.year,
                url: item.url,
                addedAt: item.addedAt,
                sourceOrder: index,
                source: .letterboxd,
                tmdbID: item.tmdbID ?? existing?.tmdbID,
                tmdbMetadata: item.tmdbMetadata ?? existing?.tmdbMetadata,
                tmdbMediaType: item.tmdbMediaType ?? existing?.tmdbMediaType
            )
        }

        let customItems = items
            .filter { $0.source == .custom }
            .enumerated()
            .map { offset, item in
                item.withSourceOrder(importedItems.count + offset)
            }

        items = importedItems + customItems
        persist()
    }

    func mergeImportedItems(_ newItems: [WatchlistItem]) {
        var keys = Set(items.compactMap { $0.url.map(URLNormalizer.comparisonKey(for:)) })

        for item in newItems {
            guard let url = item.url,
                  keys.insert(URLNormalizer.comparisonKey(for: url)).inserted else { continue }

            items.append(item.withSourceOrder(items.count))
        }

        persist()
    }

    @discardableResult
    func add(title: String, year: Int?, url: URL?) -> WatchlistItem {
        let item = WatchlistItem(
            title: title,
            year: year,
            url: url,
            addedAt: Date(),
            sourceOrder: items.count,
            source: .custom
        )
        items.append(item)
        persist()
        return item
    }

    /// The watchlist entry for a TMDB title, if there is one.
    func item(for media: TMDBMediaResult) -> WatchlistItem? {
        items.first {
            $0.tmdbID == media.id && ($0.tmdbMediaType ?? .movie) == media.mediaType
        }
    }

    /// Shows with an episode in progress, most recent first.
    var showsInProgress: [WatchlistItem] {
        items
            .filter { $0.progress != nil }
            .sorted { ($0.progress?.updatedAt ?? .distantPast) > ($1.progress?.updatedAt ?? .distantPast) }
    }

    /// Remembers the episode just opened, adding the show to the watchlist
    /// if it isn't there yet.
    func recordEpisode(season: Int, episode: Int, title: String?, of media: TMDBMediaResult, at date: Date = Date()) {
        let progress = EpisodeProgress(season: season, episode: episode, episodeTitle: title, updatedAt: date)

        if let existing = item(for: media), let index = items.firstIndex(where: { $0.id == existing.id }) {
            items[index].progress = progress
            persist()
            return
        }

        var item = WatchlistItem(
            title: media.title,
            year: media.year.flatMap(Int.init),
            url: nil,
            addedAt: date,
            sourceOrder: items.count,
            source: .custom,
            tmdbID: media.id,
            tmdbMetadata: media,
            tmdbMediaType: media.mediaType
        )
        item.progress = progress
        items.append(item)
        persist()
    }

    func clearProgress(id: WatchlistItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].progress != nil else { return }
        items[index].progress = nil
        persist()
    }

    func associate(id: WatchlistItem.ID, with media: TMDBMediaResult?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].tmdbID = media?.id
        items[index].tmdbMediaType = media?.mediaType
        items[index].tmdbMetadata = media
        persist()
    }

    func update(
        id: WatchlistItem.ID,
        title: String,
        year: Int?,
        url: URL?
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }

        items[index] = items[index].updating(title: title, year: year, url: url)
        persist()
    }

    func remove(id: WatchlistItem.ID) {
        items.removeAll { $0.id == id }
        items = items.enumerated().map {
            $0.element.withSourceOrder($0.offset)
        }

        persist()
    }

    /// Applies changes that came from iCloud without echoing them back.
    func applyRemoteChanges(upserts: [WatchlistItem], deletions: [WatchlistItem.ID]) {
        guard !upserts.isEmpty || !deletions.isEmpty else { return }

        let removed = Set(deletions)
        var byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in removed {
            byID[id] = nil
        }
        for item in upserts where !removed.contains(item.id) {
            byID[item.id] = item
        }

        items = Self.ordered(Array(byID.values))
        write()
        takeSnapshot()
    }

    private func load() {
        do {
            items = try Self.ordered(fileStore.load(defaultValue: []))
            persistenceError = nil
        } catch {
            items = []
            persistenceError = error.localizedDescription
        }
        takeSnapshot()
    }

    private func persist() {
        write()

        let current = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let saved = items.filter { snapshot[$0.id] != $0 }.map(\.id)
        let deleted = snapshot.keys.filter { current[$0] == nil }
        snapshot = current

        if !saved.isEmpty || !deleted.isEmpty {
            changeHandler?(saved, Array(deleted))
        }
    }

    private func write() {
        do {
            try fileStore.save(items)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func takeSnapshot() {
        snapshot = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Watchlist order, with the date added breaking ties between items
    /// numbered on different devices.
    private static func ordered(_ items: [WatchlistItem]) -> [WatchlistItem] {
        items.sorted {
            if $0.sourceOrder != $1.sourceOrder {
                return $0.sourceOrder < $1.sourceOrder
            }
            return ($0.addedAt ?? .distantPast) < ($1.addedAt ?? .distantPast)
        }
    }
}
