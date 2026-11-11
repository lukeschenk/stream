import Foundation
import Testing
@testable import Wianu

/// Answers by host, counting requests.
actor RoutedSession: TMDBSession {
    private let routes: [String: (status: Int, body: Data)]
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: (status: Int, body: Data)]) {
        self.routes = routes
    }

    // swiftlint:disable:next async_without_await
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let route = routes[request.url?.host() ?? ""] ?? (404, Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: route.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (route.body, response)
    }

    func count(host: String) -> Int {
        requests.filter { $0.url?.host() == host }.count
    }
}

nonisolated enum EpisodeFixtures {
    static let bluey = TMDBMediaResult(
        id: 82728,
        mediaType: .tv,
        title: "Bluey",
        overview: "",
        posterPath: nil,
        releaseDate: "2018-10-01"
    )

    static func option(
        _ service: String,
        _ name: String,
        _ type: String,
        _ link: String,
        video: String? = nil
    ) -> String {
        let videoLink = video.map { #","videoLink":"\#($0)""# } ?? ""
        return #"{"service":{"id":"\#(service)","name":"\#(name)"},"type":"\#(type)","link":"\#(link)"\#(videoLink)}"#
    }

    static let show = Data("""
    {"title":"Bluey","streamingOptions":{"ca":[
      \(option("apple", "Apple TV", "buy", "https://tv.apple.com/ca/show/bluey/umc.cmc.3ez"))
      ,\(option("prime", "Prime Video", "addon", "https://www.primevideo.com/detail/addon"))
      ,\(option("disney", "Disney+", "subscription", "https://www.disneyplus.com/browse/entity-fa69",
                video: "https://www.disneyplus.com/play/first"))
    ]},
    "seasons":[
      {"title":"Series 1","episodes":[
        {"title":"The Magic Xylophone","overview":"Freeze Dad.","streamingOptions":{"ca":[
          \(option("disney", "Disney+", "subscription", "https://www.disneyplus.com/play/s1e1",
                   video: "https://www.disneyplus.com/play/s1e1-video"))]}},
        {"title":"Hospital","streamingOptions":{"ca":[
          \(option("apple", "Apple TV", "buy", "https://tv.apple.com/ca/episode/hospital")),
          \(option("disney", "Disney+", "subscription", "https://www.disneyplus.com/play/s1e2"))]}}
      ]},
      {"title":"Series 2","episodes":[
        {"title":"Hammerbarn","streamingOptions":{"ca":[
          \(option("disney", "Disney+", "subscription", "https://www.disneyplus.com/play/s2e1"))]}}
      ]},
      {"title":"Season 4"}
    ]}
    """.utf8)

    static let wikidata = Data("""
    {"results":{"bindings":[
      {"property":{"value":"http://www.wikidata.org/prop/direct/P1874"},"value":{"value":"80117799"}},
      {"property":{"value":"http://www.wikidata.org/prop/direct/P13902"},"value":{"value":"entity-wikidata"}}
    ]}}
    """.utf8)
}

@Suite("Streaming Availability")
@MainActor
struct StreamingAvailabilityTests {
    @Test func `shows become title and episode links`() throws {
        let show = try JSONDecoder().decode(StreamingAvailabilityClient.Show.self, from: EpisodeFixtures.show)
        let links = StreamingAvailabilityClient.links(from: show, country: "ca")

        #expect(links.serviceLinks.keys.sorted() == ["Disney+"])
        #expect(links.serviceLinks["Disney+"]?.absoluteString == "https://www.disneyplus.com/browse/entity-fa69")
        #expect(links.appleTV?.absoluteString == "https://tv.apple.com/ca/show/bluey/umc.cmc.3ez")

        // Seasons without episodes are dropped; numbering follows the order.
        #expect(links.seasons.map(\.title) == ["Series 1", "Series 2"])
        let first = try #require(links.episode(season: 1, number: 1))
        #expect(first.title == "The Magic Xylophone")
        #expect(first.overview == "Freeze Dad.")
        // The link that starts playback wins.
        #expect(first.links["Disney+"]?.absoluteString == "https://www.disneyplus.com/play/s1e1-video")
        // Buying from Apple isn't watching on a service you have.
        #expect(links.episode(season: 1, number: 2)?.links.keys.sorted() == ["Disney+"])
    }

    @Test func `next episode moves into the next season`() throws {
        let show = try JSONDecoder().decode(StreamingAvailabilityClient.Show.self, from: EpisodeFixtures.show)
        let links = StreamingAvailabilityClient.links(from: show, country: "ca")
        let second = try #require(links.episode(season: 1, number: 2))

        #expect(links.episode(after: second)?.id == "S2E1")
        #expect(links.episode(after: try #require(links.episode(season: 2, number: 1))) == nil)
    }

    @Test func `episodes prefer your services`() throws {
        let netflix = try #require(StreamingServiceCatalog.services.first { $0.name == "Netflix" })
        let disney = try #require(StreamingServiceCatalog.services.first { $0.name == "Disney+" })
        let episode = TitleEpisode(
            season: 1,
            number: 1,
            title: "Pilot",
            overview: nil,
            links: [
                "Disney+": URL(string: "https://www.disneyplus.com/play/1")!,
                "Netflix": URL(string: "https://www.netflix.com/watch/1")!
            ]
        )

        #expect(episode.service(preferring: [netflix])?.name == "Netflix")
        #expect(episode.service(preferring: [disney, netflix])?.name == "Disney+")
        #expect(episode.service(preferring: [])?.name == "Netflix")
    }

    @Test func `requests carry the key and ask for episodes`() async throws {
        let session = RoutedSession(["api.movieofthenight.com": (200, EpisodeFixtures.show)])
        _ = try await StreamingAvailabilityClient(apiKey: "test-key", session: session)
            .titleLinks(for: EpisodeFixtures.bluey, region: "CA")

        let request = try #require(await session.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "test-key")
        #expect(request.url?.path == "/v4/shows/tv/82728")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "country", value: "ca")))
        #expect(query.contains(URLQueryItem(name: "series_granularity", value: "episode")))
    }

    @Test func `running out of lookups is reported`() async {
        let session = RoutedSession(["api.movieofthenight.com": (429, Data())])
        await #expect(throws: StreamingAvailabilityError.quotaExceeded) {
            try await StreamingAvailabilityClient(apiKey: "k", session: session)
                .titleLinks(for: EpisodeFixtures.bluey, region: "CA")
        }
    }
}

@Suite("Title links model")
@MainActor
struct TitleLinksModelTests {
    private func cache() -> TitleLinksCache {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TitleLinks-\(UUID().uuidString)")
        return TitleLinksCache(
            fileStore: JSONFileStore(fileName: "links.json", folderName: "Stream", baseDirectory: directory)
        )
    }

    @Test func `Streaming Availability wins and Wikidata fills gaps`() async throws {
        let session = RoutedSession([
            "api.movieofthenight.com": (200, EpisodeFixtures.show),
            "query.wikidata.org": (200, EpisodeFixtures.wikidata)
        ])
        let model = TitleLinksModel(
            wikidata: WikidataClient(session: session),
            streamingAvailability: StreamingAvailabilityClient(apiKey: "k", session: session),
            cache: cache()
        )

        await model.load(for: EpisodeFixtures.bluey, region: "CA")
        let links = try #require(model.links(for: EpisodeFixtures.bluey, region: "CA"))

        #expect(links.serviceLinks["Disney+"]?.absoluteString == "https://www.disneyplus.com/browse/entity-fa69")
        #expect(links.serviceLinks["Netflix"]?.absoluteString == "https://www.netflix.com/title/80117799")
        #expect(links.episodes.count == 3)
    }

    @Test func `saved answers save lookups`() async {
        let session = RoutedSession([
            "api.movieofthenight.com": (200, EpisodeFixtures.show),
            "query.wikidata.org": (200, EpisodeFixtures.wikidata)
        ])
        let sharedCache = cache()

        let first = TitleLinksModel(
            wikidata: WikidataClient(session: session),
            streamingAvailability: StreamingAvailabilityClient(apiKey: "k", session: session),
            cache: sharedCache
        )
        await first.load(for: EpisodeFixtures.bluey, region: "CA")

        // A new model, as after relaunching, reads the saved answer.
        let second = TitleLinksModel(
            wikidata: WikidataClient(session: session),
            streamingAvailability: StreamingAvailabilityClient(apiKey: "k", session: session),
            cache: sharedCache
        )
        await second.load(for: EpisodeFixtures.bluey, region: "CA")

        #expect(await session.count(host: "api.movieofthenight.com") == 1)
        #expect(second.links(for: EpisodeFixtures.bluey, region: "CA")?.episodes.count == 3)
    }

    @Test func `without lookups left, Wikidata still answers`() async {
        let session = RoutedSession([
            "api.movieofthenight.com": (429, Data()),
            "query.wikidata.org": (200, EpisodeFixtures.wikidata)
        ])
        let model = TitleLinksModel(
            wikidata: WikidataClient(session: session),
            streamingAvailability: StreamingAvailabilityClient(apiKey: "k", session: session),
            cache: cache()
        )

        await model.load(for: EpisodeFixtures.bluey, region: "CA")
        let other = TMDBMediaResult(
            id: 1,
            mediaType: .tv,
            title: "Other",
            overview: "",
            posterPath: nil,
            releaseDate: nil
        )
        await model.load(for: other, region: "CA")

        #expect(model.links(for: EpisodeFixtures.bluey, region: "CA")?.serviceLinks["Disney+"] != nil)
        // After the first refusal the quota isn't asked again.
        #expect(await session.count(host: "api.movieofthenight.com") == 1)
    }

    @Test func `expired answers are looked up again`() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let directory = FileManager.default.temporaryDirectory.appending(path: "TitleLinks-\(UUID().uuidString)")
        let cache = TitleLinksCache(
            fileStore: JSONFileStore(fileName: "links.json", folderName: "Stream", baseDirectory: directory),
            now: { now }
        )

        cache.store(TitleLinks(appleTV: URL(string: "https://tv.apple.com")), for: "k", lifetime: .oneDay)
        #expect(cache.links(for: "k") != nil)

        now.addTimeInterval(TitleLinksCache.Lifetime.oneDay.rawValue + 1)
        #expect(cache.links(for: "k") == nil)
    }
}

@Suite("Episode progress")
@MainActor
struct EpisodeProgressTests {
    private func store() -> WatchlistStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Progress-\(UUID().uuidString)")
        return WatchlistStore(
            fileStore: JSONFileStore(fileName: "watchlist.json", folderName: "Wianu", baseDirectory: directory)
        )
    }

    @Test func `opening an episode adds the show and remembers it`() {
        let store = store()
        var changes = 0
        store.changeHandler = { _, _ in changes += 1 }

        store.recordEpisode(season: 2, episode: 5, title: "Featherwand", of: EpisodeFixtures.bluey)

        let item = store.item(for: EpisodeFixtures.bluey)
        #expect(item?.title == "Bluey")
        #expect(item?.progress?.label == "S2 · E5")
        #expect(item?.progress?.episodeTitle == "Featherwand")
        #expect(changes == 1)

        store.recordEpisode(season: 2, episode: 6, title: nil, of: EpisodeFixtures.bluey)
        #expect(store.items.count == 1)
        #expect(store.item(for: EpisodeFixtures.bluey)?.progress?.episode == 6)
        #expect(changes == 2)
    }

    @Test func `shows in progress are newest first`() {
        let store = store()
        let other = TMDBMediaResult(
            id: 1,
            mediaType: .tv,
            title: "Other",
            overview: "",
            posterPath: nil,
            releaseDate: nil
        )
        store.add(title: "A movie", year: nil, url: nil)
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        store.recordEpisode(season: 1, episode: 1, title: nil, of: EpisodeFixtures.bluey, at: earlier)
        store.recordEpisode(season: 1, episode: 1, title: nil, of: other, at: later)

        #expect(store.showsInProgress.map(\.title) == ["Other", "Bluey"])

        store.clearProgress(id: store.showsInProgress[0].id)
        #expect(store.showsInProgress.map(\.title) == ["Bluey"])
    }

    @Test func `progress survives encoding and old items still load`() throws {
        var item = WatchlistItem(title: "Bluey", year: 2018, url: nil, addedAt: nil, sourceOrder: 0, source: .custom)
        item.progress = EpisodeProgress(
            season: 3,
            episode: 12,
            episodeTitle: "Sleepytime",
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        let decoded = try JSONDecoder().decode(WatchlistItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.progress == item.progress)

        let old = #"{"id":"\#(UUID().uuidString)","title":"Old","sourceOrder":0,"source":"custom"}"#
        #expect(try JSONDecoder().decode(WatchlistItem.self, from: Data(old.utf8)).progress == nil)
    }
}
