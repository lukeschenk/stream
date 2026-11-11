import Foundation

nonisolated enum StreamingAvailabilityError: Error, Equatable {
    case unauthorized
    case quotaExceeded
    case notFound
    case server(statusCode: Int)
}

/// The Streaming Availability API (Movie of the Night): where a title streams
/// in a country, with links that open it, and for shows each episode.
nonisolated struct StreamingAvailabilityClient: Sendable {
    static let baseURL = URL(string: "https://api.movieofthenight.com/v4")!

    /// The key from the build's `STREAMING_AVAILABILITY_API_KEY` setting, which
    /// comes from the git-ignored `Config/Secrets.xcconfig`.
    static var configuredKey: String? {
        let key = (Bundle.main.object(forInfoDictionaryKey: "StreamingAvailabilityAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty, !key.hasPrefix("$(") else { return nil }
        return key
    }

    static var configured: StreamingAvailabilityClient? {
        configuredKey.map { StreamingAvailabilityClient(apiKey: $0) }
    }

    let apiKey: String
    private let session: any TMDBSession

    init(apiKey: String, session: any TMDBSession = URLSession.shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func titleLinks(for media: TMDBMediaResult, region: String) async throws -> TitleLinks {
        let country = region.lowercased()
        var components = URLComponents(
            url: Self.baseURL.appending(path: "shows/\(media.mediaType.rawValue)/\(media.id)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "series_granularity", value: media.mediaType == .tv ? "episode" : "show"),
            URLQueryItem(name: "output_language", value: "en")
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StreamingAvailabilityError.server(statusCode: 0)
        }

        switch http.statusCode {
        case 200 ..< 300:
            break
        case 401, 403:
            throw StreamingAvailabilityError.unauthorized
        case 404:
            throw StreamingAvailabilityError.notFound
        case 429:
            throw StreamingAvailabilityError.quotaExceeded
        default:
            throw StreamingAvailabilityError.server(statusCode: http.statusCode)
        }

        let show = try JSONDecoder().decode(Show.self, from: data)
        return Self.links(from: show, country: country)
    }

    // MARK: Converting the response

    static func links(from show: Show, country: String) -> TitleLinks {
        var links = TitleLinks()

        for option in show.streamingOptions?[country] ?? [] {
            // A buy or rent listing in the TV app is still the title's page
            // there, which hands off to any service that has it.
            if option.service.id == "apple", links.appleTV == nil {
                links.appleTV = URL(string: option.link)
            }

            guard option.isIncluded,
                  let service = service(for: option),
                  links.serviceLinks[service.id] == nil,
                  let url = URL(string: option.link)
            else { continue }

            links.serviceLinks[service.id] = url
        }

        links.seasons = (show.seasons ?? []).enumerated().compactMap { seasonIndex, season in
            let number = seasonIndex + 1
            let episodes = (season.episodes ?? []).enumerated().map { episodeIndex, episode in
                TitleEpisode(
                    season: number,
                    number: episodeIndex + 1,
                    title: episode.title ?? "Episode \(episodeIndex + 1)",
                    overview: episode.overview,
                    links: episodeLinks(episode.streamingOptions?[country] ?? [])
                )
            }
            guard !episodes.isEmpty else { return nil }
            return TitleSeason(number: number, title: season.title ?? "Season \(number)", episodes: episodes)
        }

        return links
    }

    /// Prefers the link that starts playback of the episode.
    private static func episodeLinks(_ options: [Option]) -> [String: URL] {
        var links: [String: URL] = [:]
        for option in options where option.isIncluded {
            guard let service = service(for: option),
                  links[service.id] == nil,
                  let url = URL(string: option.videoLink ?? option.link)
            else { continue }
            links[service.id] = url
        }
        return links
    }

    private static func service(for option: Option) -> StreamingService? {
        StreamingServiceCatalog.service(forProviderName: option.service.name)
            ?? StreamingServiceCatalog.service(forProviderName: option.service.id)
    }

    // MARK: Response

    struct Show: Decodable, Sendable {
        let title: String?
        let streamingOptions: [String: [Option]]?
        let seasons: [Season]?
    }

    struct Season: Decodable, Sendable {
        let title: String?
        let episodes: [Episode]?
    }

    struct Episode: Decodable, Sendable {
        let title: String?
        let overview: String?
        let streamingOptions: [String: [Option]]?
    }

    struct Option: Decodable, Sendable {
        struct Service: Decodable, Sendable {
            let id: String
            let name: String
        }

        let service: Service
        /// `subscription`, `free`, `addon`, `rent` or `buy`.
        let type: String
        let link: String
        let videoLink: String?

        /// Watchable with the service itself, without paying per title or
        /// adding a channel.
        var isIncluded: Bool {
            type == "subscription" || type == "free"
        }
    }
}
