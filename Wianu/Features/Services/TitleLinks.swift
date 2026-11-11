import Foundation

/// Direct links to one title inside streaming services, so a service opens
/// on that movie or show instead of its home page.
nonisolated struct TitleLinks: Codable, Equatable, Sendable {
    /// Keyed by `StreamingService.id`.
    var serviceLinks: [String: URL] = [:]
    /// The title's page in Apple's TV app, which lists where to watch and
    /// hands off to the service's app.
    var appleTV: URL?
    /// For shows: each season's episodes with their own links.
    var seasons: [TitleSeason] = []

    static let empty = TitleLinks()

    func url(for service: StreamingService) -> URL? {
        serviceLinks[service.id]
    }

    /// Fills gaps in these links from another source.
    func merging(_ other: TitleLinks) -> TitleLinks {
        var merged = self
        merged.serviceLinks.merge(other.serviceLinks) { mine, _ in mine }
        merged.appleTV = appleTV ?? other.appleTV
        if merged.seasons.isEmpty {
            merged.seasons = other.seasons
        }
        return merged
    }

    var episodes: [TitleEpisode] {
        seasons.flatMap(\.episodes)
    }

    func episode(season: Int, number: Int) -> TitleEpisode? {
        seasons.first { $0.number == season }?.episodes.first { $0.number == number }
    }

    /// The episode after this one, moving into the next season when needed.
    func episode(after episode: TitleEpisode) -> TitleEpisode? {
        let all = episodes
        guard let index = all.firstIndex(where: { $0.id == episode.id }) else { return nil }
        let next = all.index(after: index)
        return next < all.endIndex ? all[next] : nil
    }
}

nonisolated struct TitleSeason: Codable, Equatable, Sendable, Identifiable {
    let number: Int
    let title: String
    let episodes: [TitleEpisode]

    var id: Int {
        number
    }
}

nonisolated struct TitleEpisode: Codable, Equatable, Sendable, Identifiable {
    let season: Int
    let number: Int
    let title: String
    let overview: String?
    /// Links that open this episode, keyed by `StreamingService.id`.
    let links: [String: URL]

    var id: String {
        "S\(season)E\(number)"
    }

    /// "S2 · E5"
    var label: String {
        "S\(season) · E\(number)"
    }

    /// The service to open the episode in: one of `preferred` when possible.
    func service(preferring preferred: [StreamingService]) -> StreamingService? {
        if let mine = preferred.first(where: { links[$0.id] != nil }) {
            return mine
        }
        return StreamingServiceCatalog.services.first { links[$0.id] != nil }
    }
}

/// Looks titles up in Wikidata, which records many services' title IDs
/// alongside TMDB IDs. Data is CC0.
nonisolated enum WikidataTitleLinks {
    struct LinkProperty: Sendable {
        let property: String
        let service: String
        let mediaType: TMDBMediaType?
        let urlPrefix: String
    }

    /// Only services whose stored IDs match their current link format.
    static let linkProperties = [
        LinkProperty(
            property: "P13902",
            service: "Disney+",
            mediaType: nil,
            urlPrefix: "https://www.disneyplus.com/browse/"
        ),
        LinkProperty(
            property: "P1874",
            service: "Netflix",
            mediaType: nil,
            urlPrefix: "https://www.netflix.com/title/"
        ),
        // Prime Video IDs, best first: current ID, title ID (GTI), then the
        // Amazon store ID, which Prime Video's detail pages also accept.
        LinkProperty(
            property: "P14440",
            service: "Prime Video",
            mediaType: nil,
            urlPrefix: "https://www.primevideo.com/detail/"
        ),
        LinkProperty(
            property: "P14462",
            service: "Prime Video",
            mediaType: nil,
            urlPrefix: "https://www.primevideo.com/detail/"
        ),
        LinkProperty(
            property: "P8055",
            service: "Prime Video",
            mediaType: nil,
            urlPrefix: "https://www.primevideo.com/detail/"
        ),
        LinkProperty(
            property: "P7760",
            service: "Tubi",
            mediaType: .movie,
            urlPrefix: "https://tubitv.com/movies/"
        ),
        LinkProperty(
            property: "P7761",
            service: "Tubi",
            mediaType: .tv,
            urlPrefix: "https://tubitv.com/series/"
        ),
        LinkProperty(
            property: "P11330",
            service: "Crunchyroll",
            mediaType: .tv,
            urlPrefix: "https://www.crunchyroll.com/series/"
        )
    ]

    static let appleTVMovieProperty = "P9586"
    static let appleTVShowProperty = "P9751"

    static func tmdbProperty(for mediaType: TMDBMediaType) -> String {
        mediaType == .movie ? "P4947" : "P4983"
    }

    static func query(for media: TMDBMediaResult) -> String {
        let properties = linkProperties
            .filter { $0.mediaType == nil || $0.mediaType == media.mediaType }
            .map(\.property)
            + [media.mediaType == .movie ? appleTVMovieProperty : appleTVShowProperty]

        let values = properties.map { "wdt:\($0)" }.joined(separator: " ")
        return """
        SELECT ?property ?value WHERE { \
        ?item wdt:\(tmdbProperty(for: media.mediaType)) "\(media.id)" . \
        VALUES ?property { \(values) } \
        ?item ?property ?value . }
        """
    }

    static func links(
        fromSPARQLResults data: Data,
        media: TMDBMediaResult,
        region: String
    ) throws -> TitleLinks {
        let response = try JSONDecoder().decode(SPARQLResponse.self, from: data)
        var links = TitleLinks()
        var ranks: [String: Int] = [:]

        for row in response.results.bindings {
            guard let property = row.property?.value.split(separator: "/").last.map(String.init),
                  let value = row.value?.value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { continue }

            if property == appleTVMovieProperty || property == appleTVShowProperty {
                links.appleTV = links.appleTV ?? appleTVURL(id: value, media: media, region: region)
                continue
            }

            guard let rank = linkProperties.firstIndex(where: { $0.property == property }),
                  let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: linkProperties[rank].urlPrefix + encoded)
            else { continue }

            // Rows arrive in no particular order; keep each service's
            // best-ranked ID.
            let service = linkProperties[rank].service
            if let existing = ranks[service], existing <= rank {
                continue
            }
            ranks[service] = rank
            links.serviceLinks[service] = url
        }

        if let appleTV = links.appleTV {
            links.serviceLinks["Apple TV"] = appleTV
        }
        return links
    }

    /// `https://tv.apple.com/ca/movie/inside-out-2/umc.cmc.…`, the form the TV
    /// app's Share button produces.
    static func appleTVURL(id: String, media: TMDBMediaResult, region: String) -> URL? {
        guard id.hasPrefix("umc.") else { return nil }

        let country = region.lowercased().filter(\.isLetter)
        let kind = media.mediaType == .movie ? "movie" : "show"
        let slug = slug(for: media.title)
        let path = [country.isEmpty ? "us" : country, kind, slug.isEmpty ? nil : slug, id]
            .compactMap { $0 }
            .joined(separator: "/")
        return URL(string: "https://tv.apple.com/" + path)
    }

    static func slug(for title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var slug = ""
        for character in folded {
            if character.isLetter || character.isNumber, character.isASCII {
                slug.append(character)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        return slug
    }

    private struct SPARQLResponse: Decodable {
        struct Results: Decodable {
            let bindings: [Row]
        }

        struct Row: Decodable {
            let property: Value?
            let value: Value?
        }

        struct Value: Decodable {
            let value: String
        }

        let results: Results
    }
}

nonisolated struct WikidataClient: Sendable {
    static let endpoint = URL(string: "https://query.wikidata.org/sparql")!

    /// Wikimedia asks automated clients to identify themselves.
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Stream/\(version) (https://github.com/lukeschenk/stream)"
    }

    private let session: any TMDBSession

    init(session: any TMDBSession = URLSession.shared) {
        self.session = session
    }

    func titleLinks(for media: TMDBMediaResult, region: String) async throws -> TitleLinks {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query", value: WikidataTitleLinks.query(for: media)),
            URLQueryItem(name: "format", value: "json")
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try WikidataTitleLinks.links(fromSPARQLResults: data, media: media, region: region)
    }
}
