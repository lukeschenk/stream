import Foundation
import Observation

/// Which of the person's saved sites can stream a title, judged from TMDB's
/// watch-provider data.
enum MyServices {
    /// Offer types you can watch without paying per title.
    static let includedOffers: [TMDBOfferType] = [.flatrate, .free, .ads]

    static func streamingProviders(in availability: TMDBWatchAvailability?) -> [TMDBProvider] {
        guard let availability else { return [] }

        var seen = Set<Int>()
        return includedOffers
            .flatMap { availability[$0] }
            .filter { seen.insert($0.id).inserted }
    }

    /// Saved sites whose TMDB provider streams the title, in sidebar order.
    static func sites(
        streaming providers: [TMDBProvider],
        from sites: [SavedSite]
    ) -> [SavedSite] {
        sites.filter { site in
            guard let reference = site.tmdbProvider else { return false }
            return providers.contains { reference.matches($0) }
        }
    }

    static func hasLinkedServices(_ sites: [SavedSite]) -> Bool {
        sites.contains { $0.tmdbProvider != nil }
    }
}

/// Looks up streaming availability for search results a few at a time, and
/// remembers the answers for the session.
@MainActor
@Observable
final class ServiceAvailabilityModel {
    private(set) var providers: [String: [TMDBProvider]] = [:]
    private(set) var pendingCount = 0

    @ObservationIgnored
    private let client: TMDBClient
    @ObservationIgnored
    private var queue: [(key: String, media: TMDBMediaResult, region: String)] = []
    @ObservationIgnored
    private var queued = Set<String>()
    @ObservationIgnored
    private var worker: Task<Void, Never>?

    /// The Wianu API allows a short burst, then about five requests a second.
    @ObservationIgnored
    private let spacing: Duration

    init(client: TMDBClient, spacing: Duration = .milliseconds(250)) {
        self.client = client
        self.spacing = spacing
    }

    static func key(for media: TMDBMediaResult, region: String) -> String {
        "\(region.uppercased())/\(media.mediaType.rawValue)/\(media.id)"
    }

    /// Streaming providers for the title, or `nil` while unknown.
    func streamingProviders(for media: TMDBMediaResult, region: String) -> [TMDBProvider]? {
        providers[Self.key(for: media, region: region)]
    }

    func prefetch(_ results: [TMDBMediaResult], region: String) {
        for media in results {
            let key = Self.key(for: media, region: region)
            guard providers[key] == nil, queued.insert(key).inserted else { continue }
            queue.append((key, media, region))
        }

        pendingCount = queue.count
        guard worker == nil, !queue.isEmpty else { return }

        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    /// Stops looking up titles that are no longer on screen.
    func cancelPending() {
        worker?.cancel()
        worker = nil
        for entry in queue {
            queued.remove(entry.key)
        }
        queue.removeAll()
        pendingCount = 0
    }

    private func drain() async {
        while !queue.isEmpty, !Task.isCancelled {
            let entry = queue.removeFirst()

            do {
                let availability = try await lookUp(entry.media, region: entry.region)
                providers[entry.key] = MyServices.streamingProviders(in: availability)
            } catch is CancellationError {
                queued.remove(entry.key)
                break
            } catch {
                // Treat failures as unknown so a later search can try again.
                queued.remove(entry.key)
            }

            pendingCount = queue.count
            try? await Task.sleep(for: spacing)
        }

        worker = nil
        pendingCount = queue.count
    }

    private func lookUp(_ media: TMDBMediaResult, region: String) async throws -> TMDBWatchAvailability? {
        do {
            return try await client.watchProviders(for: media, region: region)
        } catch let TMDBError.rateLimited(retryAfter) {
            try await Task.sleep(for: .seconds(min(max(retryAfter ?? 1, 1), 10)))
            return try await client.watchProviders(for: media, region: region)
        }
    }
}
