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
    /// When each answer in `links` was fetched.
    @ObservationIgnored
    private var fetchedAt: [String: Date] = [:]
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
        self.init(cache: TitleLinksCache(fileName: "title-links.json"))
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
        return cache?.value(for: key)
    }

    /// Looks the title up unless a current answer is saved. `staleBefore`
    /// asks for a fresh lookup if the saved answer is older, such as when a
    /// new episode has come out since.
    func load(for media: TMDBMediaResult, region: String, staleBefore: Date? = nil) async {
        let key = Self.key(for: media, region: region)
        if links[key] != nil, (fetchedAt[key] ?? .distantFuture) >= (staleBefore ?? .distantPast) {
            return
        }

        if let cached = cache?.value(for: key, storedAfter: staleBefore) {
            links[key] = cached
            fetchedAt[key] = staleBefore ?? .distantFuture
            return
        }

        // Share one lookup between views asking for the same title.
        let task = inFlight[key] ?? Task { await self.fetch(media, region: region) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        guard let result else { return }
        links[key] = result
        fetchedAt[key] = Date()
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

        // Streaming Availability didn't answer: keep the last full answer,
        // even if it's old, topped up with anything Wikidata found, and try
        // again tomorrow.
        if primary == nil, streamingAvailability != nil, let saved = cache?.fallback(for: key) {
            let combined = saved.merging(fallback ?? .empty)
            cache?.store(combined, for: key, lifetime: .oneDay)
            return combined
        }

        let merged = (primary ?? .empty).merging(fallback ?? .empty)
        let lifetime = Self.lifetime(for: media, fromStreamingAvailability: primary != nil)
        cache?.store(merged, for: key, lifetime: lifetime)
        return merged
    }

    /// Streaming catalogs change, so answers expire: movies rarely move, and
    /// shows are refreshed sooner, and again when a new episode comes out.
    /// Wikidata-only answers are retried the next day in case the
    /// Streaming Availability lookup failed for a passing reason.
    static func lifetime(
        for media: TMDBMediaResult,
        fromStreamingAvailability: Bool
    ) -> TitleLinksCache.Lifetime {
        guard fromStreamingAvailability else { return .oneDay }
        return media.mediaType == .movie ? .oneMonth : .oneWeek
    }
}
