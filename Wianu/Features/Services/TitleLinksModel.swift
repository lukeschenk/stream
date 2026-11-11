import Foundation
import Observation

/// Finds title and episode links, remembering them on the device: Streaming
/// Availability first (when a key is configured), with Wikidata filling gaps.
@MainActor
@Observable
final class TitleLinksModel {
    private(set) var links: [String: TitleLinks] = [:]

    @ObservationIgnored
    private let wikidata: WikidataClient
    @ObservationIgnored
    private let streamingAvailability: StreamingAvailabilityClient?
    @ObservationIgnored
    private let cache: TitleLinksCache?
    @ObservationIgnored
    private var inFlight: [String: Task<TitleLinks?, Never>] = [:]
    /// Set once the monthly quota runs out, so lookups stop until relaunch.
    @ObservationIgnored
    private var streamingAvailabilityPaused = false

    init(
        wikidata: WikidataClient = WikidataClient(),
        streamingAvailability: StreamingAvailabilityClient? = .configured,
        cache: TitleLinksCache?
    ) {
        self.wikidata = wikidata
        self.streamingAvailability = streamingAvailability
        self.cache = cache
    }

    /// Uses the configured key and the on-device cache.
    convenience init() {
        self.init(cache: TitleLinksCache())
    }

    static func key(for media: TMDBMediaResult, region: String) -> String {
        "\(region.uppercased())/\(media.mediaType.rawValue)/\(media.id)"
    }

    /// Known links for the title, or `nil` while they haven't been looked up.
    func links(for media: TMDBMediaResult, region: String) -> TitleLinks? {
        let key = Self.key(for: media, region: region)
        if let known = links[key] {
            return known
        }
        return cache?.links(for: key)
    }

    func load(for media: TMDBMediaResult, region: String) async {
        let key = Self.key(for: media, region: region)
        guard links[key] == nil else { return }

        if let cached = cache?.links(for: key) {
            links[key] = cached
            return
        }

        // Share one lookup between views asking for the same title.
        let task = inFlight[key] ?? Task { await self.fetch(media, region: region) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        guard let result else { return }
        links[key] = result
    }

    private func fetch(_ media: TMDBMediaResult, region: String) async -> TitleLinks? {
        let key = Self.key(for: media, region: region)
        async let wikidataLinks = try? wikidata.titleLinks(for: media, region: region)

        var primary: TitleLinks?
        if let streamingAvailability, !streamingAvailabilityPaused {
            do {
                primary = try await streamingAvailability.titleLinks(for: media, region: region)
            } catch StreamingAvailabilityError.quotaExceeded {
                streamingAvailabilityPaused = true
            } catch StreamingAvailabilityError.unauthorized {
                streamingAvailabilityPaused = true
            } catch StreamingAvailabilityError.notFound {
                primary = .empty
            } catch {
                // Network trouble: fall back to Wikidata for now.
            }
        }

        let fallback = await wikidataLinks
        if Task.isCancelled {
            return nil
        }

        let merged = (primary ?? .empty).merging(fallback ?? .empty)
        // Streaming catalogs change, so answers are kept for a week, or a day
        // when only Wikidata answered.
        cache?.store(merged, for: key, lifetime: primary == nil ? .oneDay : .oneWeek)
        return merged
    }
}

/// Title links saved in the Caches folder, which the system may clear.
@MainActor
final class TitleLinksCache {
    enum Lifetime: TimeInterval {
        case oneDay = 86400
        case oneWeek = 604_800
    }

    struct Entry: Codable {
        let links: TitleLinks
        let expiresAt: Date
    }

    private let fileStore: JSONFileStore<[String: Entry]>
    private var entries: [String: Entry]
    private let now: () -> Date
    static let maximumEntries = 300

    init(fileStore: JSONFileStore<[String: Entry]>? = nil, now: @escaping () -> Date = Date.init) {
        let store = fileStore ?? JSONFileStore(
            fileName: "title-links.json",
            folderName: "Stream",
            baseDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
        self.fileStore = store
        self.now = now
        entries = (try? store.load(defaultValue: [:])) ?? [:]
    }

    func links(for key: String) -> TitleLinks? {
        guard let entry = entries[key], entry.expiresAt > now() else { return nil }
        return entry.links
    }

    func store(_ links: TitleLinks, for key: String, lifetime: Lifetime) {
        entries[key] = Entry(links: links, expiresAt: now().addingTimeInterval(lifetime.rawValue))

        // Drop expired entries, then the soonest to expire, to stay small.
        let current = now()
        entries = entries.filter { $0.value.expiresAt > current }
        if entries.count > Self.maximumEntries {
            let overflow = entries.count - Self.maximumEntries
            for key in entries.sorted(by: { $0.value.expiresAt < $1.value.expiresAt }).prefix(overflow).map(\.key) {
                entries[key] = nil
            }
        }

        try? fileStore.save(entries)
    }
}
