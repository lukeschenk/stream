import Foundation

/// A streaming service Wianu knows how to open, so onboarding can add it as a
/// site without the person typing a URL.
nonisolated struct StreamingService: Identifiable, Hashable, Sendable {
    let name: String
    let homepage: String
    /// Only set where the search URL format is known to work.
    let searchTemplate: String?
    /// Normalized TMDB provider names this service goes by.
    let providerKeys: [String]

    var id: String {
        name
    }

    var host: String? {
        URL(string: homepage)?.host()?.lowercased()
    }
}

nonisolated enum StreamingServiceCatalog {
    static let services: [StreamingService] = [
        StreamingService(
            name: "Netflix",
            homepage: "https://www.netflix.com/browse",
            searchTemplate: "https://www.netflix.com/search?q={query}",
            providerKeys: ["netflix"]
        ),
        StreamingService(
            name: "Prime Video",
            homepage: "https://www.primevideo.com",
            searchTemplate: "https://www.primevideo.com/search/ref=atv_nb_sr?phrase={query}",
            providerKeys: ["amazonprimevideo", "primevideo"]
        ),
        StreamingService(
            name: "Disney+",
            homepage: "https://www.disneyplus.com",
            searchTemplate: nil,
            providerKeys: ["disneyplus"]
        ),
        StreamingService(
            name: "Apple TV",
            homepage: "https://tv.apple.com",
            searchTemplate: "https://tv.apple.com/search?term={query}",
            providerKeys: ["appletvplus", "appletv"]
        ),
        StreamingService(
            name: "Crave",
            homepage: "https://www.crave.ca",
            searchTemplate: nil,
            providerKeys: ["crave"]
        ),
        StreamingService(
            name: "Paramount+",
            homepage: "https://www.paramountplus.com",
            searchTemplate: nil,
            providerKeys: ["paramountplus"]
        ),
        StreamingService(
            name: "HBO Max",
            homepage: "https://play.hbomax.com",
            searchTemplate: nil,
            providerKeys: ["hbomax", "max"]
        ),
        StreamingService(
            name: "Hulu",
            homepage: "https://www.hulu.com",
            searchTemplate: nil,
            providerKeys: ["hulu"]
        ),
        StreamingService(
            name: "Peacock",
            homepage: "https://www.peacocktv.com",
            searchTemplate: nil,
            providerKeys: ["peacock", "peacockpremium"]
        ),
        StreamingService(
            name: "CBC Gem",
            homepage: "https://gem.cbc.ca",
            searchTemplate: nil,
            providerKeys: ["cbcgem"]
        ),
        StreamingService(
            name: "YouTube",
            homepage: "https://www.youtube.com",
            searchTemplate: "https://www.youtube.com/results?search_query={query}",
            providerKeys: ["youtube"]
        ),
        StreamingService(
            name: "Tubi",
            homepage: "https://tubitv.com",
            searchTemplate: "https://tubitv.com/search/{query}",
            providerKeys: ["tubi", "tubitv"]
        ),
        StreamingService(
            name: "Pluto TV",
            homepage: "https://pluto.tv",
            searchTemplate: nil,
            providerKeys: ["plutotv"]
        ),
        StreamingService(
            name: "Crunchyroll",
            homepage: "https://www.crunchyroll.com",
            searchTemplate: nil,
            providerKeys: ["crunchyroll"]
        ),
        StreamingService(
            name: "MUBI",
            homepage: "https://mubi.com",
            searchTemplate: nil,
            providerKeys: ["mubi"]
        ),
        StreamingService(
            name: "Kanopy",
            homepage: "https://www.kanopy.com",
            searchTemplate: nil,
            providerKeys: ["kanopy"]
        ),
        StreamingService(
            name: "hoopla",
            homepage: "https://www.hoopladigital.com",
            searchTemplate: nil,
            providerKeys: ["hoopla"]
        ),
        StreamingService(
            name: "BritBox",
            homepage: "https://www.britbox.com",
            searchTemplate: nil,
            providerKeys: ["britbox"]
        )
    ]

    /// "Disney Plus" → "disneyplus", "Apple TV+" → "appletvplus".
    static func normalized(_ name: String) -> String {
        name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "+", with: "plus")
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Matches whole names, or name prefixes for longer keys so variants such
    /// as "Netflix basic with Ads" still map to Netflix.
    static func service(forProviderName providerName: String) -> StreamingService? {
        match(forProviderName: providerName)?.service
    }

    /// The best match and how closely it fits: an exact name beats a prefix,
    /// and a longer key beats a shorter one.
    static func match(forProviderName providerName: String) -> (service: StreamingService, score: Int)? {
        let name = normalized(providerName)
        guard !name.isEmpty else { return nil }

        var best: (service: StreamingService, score: Int)?
        for service in services {
            for key in service.providerKeys {
                let score: Int
                if name == key {
                    score = 1000 + key.count
                } else if key.count >= 5, name.hasPrefix(key) {
                    score = key.count
                } else {
                    continue
                }

                if score > (best?.score ?? 0) {
                    best = (service, score)
                }
            }
        }
        return best
    }
}

/// One choice on the onboarding services screen.
struct ServiceOption: Identifiable, Hashable {
    let service: StreamingService
    let provider: TMDBProvider?
    let priority: Int

    var id: String {
        service.id
    }

    var providerReference: TMDBProviderReference? {
        provider.map { TMDBProviderReference(id: $0.id, name: $0.name) }
    }

    /// Services offered in the region, one per catalog entry, in TMDB's
    /// display order. Falls back to the whole catalog when the provider list
    /// isn't available.
    static func options(from providers: [TMDBProvider], region: String) -> [ServiceOption] {
        var byService: [String: (option: ServiceOption, score: Int)] = [:]

        for provider in providers {
            guard let priority = provider.displayPriority(in: region),
                  let match = StreamingServiceCatalog.match(forProviderName: provider.name)
            else { continue }

            let option = ServiceOption(service: match.service, provider: provider, priority: priority)

            // Keep the provider whose name fits best ("Netflix" over "Netflix
            // basic with Ads"), since that's the one titles are listed under.
            // The service sorts by its best-placed provider either way.
            if let existing = byService[match.service.id] {
                let keep = existing.score > match.score
                    || (existing.score == match.score && existing.option.priority <= priority)
                let best = keep ? existing.option : option
                byService[match.service.id] = (
                    ServiceOption(
                        service: best.service,
                        provider: best.provider,
                        priority: min(existing.option.priority, priority)
                    ),
                    max(existing.score, match.score)
                )
            } else {
                byService[match.service.id] = (option, match.score)
            }
        }

        if byService.isEmpty {
            return StreamingServiceCatalog.services.enumerated().map {
                ServiceOption(service: $0.element, provider: nil, priority: $0.offset)
            }
        }

        return byService.values.map(\.option).sorted {
            ($0.priority, $0.service.name) < ($1.priority, $1.service.name)
        }
    }

    func siteDraft() -> SiteDraft {
        SiteDraft(
            name: service.name,
            address: service.homepage,
            searchURLTemplate: service.searchTemplate ?? "",
            tmdbProvider: providerReference
        )
    }
}
