import Foundation
import Testing
@testable import Wianu

@Suite("Streaming service catalog")
struct StreamingServiceCatalogTests {
    @Test(arguments: [
        ("Netflix", "Netflix"),
        ("Netflix basic with Ads", "Netflix"),
        ("Amazon Prime Video", "Prime Video"),
        ("Disney Plus", "Disney+"),
        ("Apple TV+", "Apple TV"),
        ("Crave", "Crave"),
        ("Paramount Plus Apple TV Channel", "Paramount+"),
        ("Max", "HBO Max"),
        ("Tubi TV", "Tubi"),
        ("CBC Gem", "CBC Gem")
    ])
    func `provider names map to services`(provider: String, service: String) {
        #expect(StreamingServiceCatalog.service(forProviderName: provider)?.name == service)
    }

    @Test(arguments: ["Maxdome", "Google Play Movies", "", "Hu"])
    func `unknown providers are not guessed`(provider: String) {
        #expect(StreamingServiceCatalog.service(forProviderName: provider) == nil)
    }

    @Test func `every catalog entry makes a valid site`() {
        for service in StreamingServiceCatalog.services {
            let option = ServiceOption(service: service, provider: nil, priority: 0)
            #expect(option.siteDraft().validatedValues != nil, "\(service.name)")
        }
    }

    @Test @MainActor func `options follow the region's order and keep the main provider`() {
        let providers = [
            TMDBProvider(id: 1796, name: "Netflix basic with Ads", logoPath: nil, displayPriorities: ["CA": 1]),
            TMDBProvider(id: 8, name: "Netflix", logoPath: nil, displayPriorities: ["CA": 4, "US": 1]),
            TMDBProvider(id: 230, name: "Crave", logoPath: nil, displayPriorities: ["CA": 2]),
            TMDBProvider(id: 15, name: "Hulu", logoPath: nil, displayPriorities: ["US": 2]),
            TMDBProvider(id: 3, name: "Google Play Movies", logoPath: nil, displayPriorities: ["CA": 0])
        ]

        let options = ServiceOption.options(from: providers, region: "ca")

        #expect(options.map(\.service.name) == ["Netflix", "Crave"])
        #expect(options.first?.provider?.id == 8)
        #expect(options.first?.siteDraft().tmdbProvider?.id == 8)
    }

    @Test @MainActor func `without provider data the whole catalog is offered`() {
        let options = ServiceOption.options(from: [], region: "CA")
        #expect(options.count == StreamingServiceCatalog.services.count)
    }
}

@Suite("My services")
@MainActor
struct MyServicesTests {
    private let netflix = TMDBProvider(id: 8, name: "Netflix", logoPath: nil)
    private let crave = TMDBProvider(id: 230, name: "Crave", logoPath: nil)
    private let appleStore = TMDBProvider(id: 2, name: "Apple TV", logoPath: nil)

    @Test func `only included offers count`() {
        let availability = TMDBWatchAvailability(
            link: nil,
            groups: [.flatrate: [netflix], .ads: [netflix, crave], .rent: [appleStore]]
        )
        #expect(MyServices.streamingProviders(in: availability).map(\.id) == [8, 230])
        #expect(MyServices.streamingProviders(in: nil).isEmpty)
    }

    @Test func `titles match saved sites by provider`() {
        let sites = [
            SavedSite(
                name: "Netflix",
                urlString: "https://www.netflix.com",
                tmdbProvider: .init(id: 8, name: "Netflix")
            ),
            SavedSite(name: "Blog", urlString: "https://example.com"),
            SavedSite(name: "Crave", urlString: "https://www.crave.ca", tmdbProvider: .init(id: 230, name: "Crave"))
        ]

        #expect(MyServices.sites(streaming: [crave], from: sites).map(\.name) == ["Crave"])
        #expect(MyServices.sites(streaming: [appleStore], from: sites).isEmpty)
        #expect(MyServices.hasLinkedServices(sites))
        #expect(!MyServices.hasLinkedServices([sites[1]]))
    }
}

@Suite("Service launcher")
@MainActor
struct ServiceLauncherTests {
    private func service(_ name: String) -> StreamingService {
        StreamingServiceCatalog.services.first { $0.name == name }!
    }

    @Test func `known search formats search for the title`() {
        let url = ServiceLauncher.webURL(for: service("Netflix"), title: "The Bear")
        #expect(url?.absoluteString == "https://www.netflix.com/search?q=The%20Bear")
    }

    @Test func `other services open their home page`() {
        let disney = ServiceLauncher.webURL(for: service("Disney+"), title: "Bluey")
        #expect(disney?.absoluteString == "https://www.disneyplus.com")
        let netflix = ServiceLauncher.webURL(for: service("Netflix"), title: nil)
        #expect(netflix?.absoluteString == "https://www.netflix.com/browse")
    }

    @Test func `app links exist only where a scheme is known`() {
        #expect(ServiceLauncher.appURL(for: service("Disney+"))?.scheme == "disneyplus")
        #expect(ServiceLauncher.appURL(for: service("Crave")) == nil)
    }
}

@Suite("Title links")
@MainActor
struct TitleLinksTests {
    private let insideOut2 = TMDBMediaResult(
        id: 1_022_789,
        mediaType: .movie,
        title: "Inside Out 2",
        overview: "",
        posterPath: nil,
        releaseDate: "2024-06-14"
    )

    private let theBoys = TMDBMediaResult(
        id: 76479,
        mediaType: .tv,
        title: "The Boys",
        overview: "",
        posterPath: nil,
        releaseDate: "2019-07-25"
    )

    private func results(_ rows: [(String, String)]) -> Data {
        let bindings = rows.map { property, value in
            """
            {"property":{"type":"uri","value":"http://www.wikidata.org/prop/direct/\(property)"},\
            "value":{"type":"literal","value":"\(value)"}}
            """
        }
        let json = #"{"head":{"vars":["property","value"]},"results":{"bindings":["#
            + bindings.joined(separator: ",")
            + "]}}"
        return Data(json.utf8)
    }

    @Test func `query looks the title up by its TMDB type and ID`() {
        let movieQuery = WikidataTitleLinks.query(for: insideOut2)
        #expect(movieQuery.contains(#"wdt:P4947 "1022789""#))
        #expect(movieQuery.contains("wdt:P13902"))
        #expect(movieQuery.contains("wdt:P9586"))
        #expect(!movieQuery.contains("wdt:P11330"))

        let showQuery = WikidataTitleLinks.query(for: theBoys)
        #expect(showQuery.contains(#"wdt:P4983 "76479""#))
        #expect(showQuery.contains("wdt:P9751"))
        #expect(showQuery.contains("wdt:P7761"))
    }

    @Test func `results become service links`() throws {
        let links = try WikidataTitleLinks.links(
            fromSPARQLResults: results([
                ("P13902", "entity-ec9f9fa3-fbae-4a25-b722-12c3b8ab0ef4"),
                ("P1874", "81000000"),
                ("P9586", "umc.cmc.4b17gber8k76h90rzlulvrbcl"),
                ("P2002", "ignored")
            ]),
            media: insideOut2,
            region: "CA"
        )

        #expect(
            links.serviceLinks["Disney+"]?.absoluteString
                == "https://www.disneyplus.com/browse/entity-ec9f9fa3-fbae-4a25-b722-12c3b8ab0ef4"
        )
        #expect(links.serviceLinks["Netflix"]?.absoluteString == "https://www.netflix.com/title/81000000")
        #expect(
            links.appleTV?.absoluteString
                == "https://tv.apple.com/ca/movie/inside-out-2/umc.cmc.4b17gber8k76h90rzlulvrbcl"
        )
        #expect(links.serviceLinks["Apple TV"] == links.appleTV)
        #expect(links.serviceLinks.count == 3)
    }

    @Test func `the best Prime Video ID wins whatever the row order`() throws {
        let links = try WikidataTitleLinks.links(
            fromSPARQLResults: results([
                ("P8055", "B07QQQ52B3"),
                ("P14462", "amzn1.dv.gti.57f4fcc5-1fba-4c4e-83c0-c47f375144eb"),
                ("P9751", "umc.cmc.91mn0jm4nlkzuqoueg22v3b1")
            ]),
            media: theBoys,
            region: "us"
        )

        #expect(
            links.serviceLinks["Prime Video"]?.absoluteString
                == "https://www.primevideo.com/detail/amzn1.dv.gti.57f4fcc5-1fba-4c4e-83c0-c47f375144eb"
        )
        #expect(
            links.appleTV?.absoluteString
                == "https://tv.apple.com/us/show/the-boys/umc.cmc.91mn0jm4nlkzuqoueg22v3b1"
        )
    }

    @Test(arguments: [
        ("Inside Out 2", "inside-out-2"),
        ("Shōgun", "shogun"),
        ("Mission: Impossible – Dead Reckoning", "mission-impossible-dead-reckoning"),
        ("¿Qué?", "que"),
        ("君の名は。", "")
    ])
    func `slugs match the TV app's style`(title: String, slug: String) {
        #expect(WikidataTitleLinks.slug(for: title) == slug)
    }

    @Test func `client sends an identifying user agent`() async throws {
        let session = TitleLinksSession(body: results([("P1874", "1")]))
        let links = try await WikidataClient(session: session)
            .titleLinks(for: insideOut2, region: "CA")
        #expect(links.serviceLinks["Netflix"] != nil)

        let request = try #require(await session.lastRequest)
        #expect(request.url?.host() == "query.wikidata.org")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("github.com/lukeschenk/stream") == true)
    }

    @Test func `Apple TV tries the title, then the TV app, then the app`() throws {
        let disney = try #require(StreamingServiceCatalog.services.first { $0.name == "Disney+" })
        let crave = try #require(StreamingServiceCatalog.services.first { $0.name == "Crave" })
        let netflix = try #require(StreamingServiceCatalog.services.first { $0.name == "Netflix" })
        let titleLink = try #require(URL(string: "https://www.disneyplus.com/browse/entity-1"))
        let tvApp = try #require(URL(string: "https://tv.apple.com/ca/movie/x/umc.cmc.1"))
        let links = TitleLinks(serviceLinks: ["Disney+": titleLink], appleTV: tvApp)

        let disneyURLs = ServiceLauncher.candidates(for: disney, title: "X", links: links, platform: .appleTV)
        #expect(
            disneyURLs.map(\.absoluteString)
                == [titleLink.absoluteString, tvApp.absoluteString, "disneyplus://"]
        )

        // No direct Crave link: the TV app hands off to Crave.
        #expect(ServiceLauncher.candidates(for: crave, title: "X", links: links, platform: .appleTV) == [tvApp])

        // Netflix isn't in the TV app, so go straight to the app.
        let netflixURLs = ServiceLauncher.candidates(for: netflix, title: "X", links: links, platform: .appleTV)
        #expect(netflixURLs.map(\.absoluteString) == ["nflx://"])
    }

    @Test func `iPhone prefers the title link over search`() throws {
        let netflix = try #require(StreamingServiceCatalog.services.first { $0.name == "Netflix" })
        let titleLink = try #require(URL(string: "https://www.netflix.com/title/81000000"))

        let direct = ServiceLauncher.candidates(
            for: netflix,
            title: "The Bear",
            links: TitleLinks(serviceLinks: ["Netflix": titleLink]),
            platform: .touch
        )
        #expect(direct == [titleLink])

        let searched = ServiceLauncher.candidates(for: netflix, title: "The Bear", links: nil, platform: .touch)
        #expect(searched.first?.absoluteString == "https://www.netflix.com/search?q=The%20Bear")
    }
}

private actor TitleLinksSession: TMDBSession {
    let body: Data
    private(set) var lastRequest: URLRequest?

    init(body: Data) {
        self.body = body
    }

    // swiftlint:disable:next async_without_await
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}
