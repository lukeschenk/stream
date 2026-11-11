import Foundation
import Testing
@testable import Stream

@Suite("Show schedules")
@MainActor
struct ShowScheduleTests {
    private let eastern = TimeZone(identifier: "America/New_York")!
    private let pacific = TimeZone(identifier: "America/Los_Angeles")!

    // Monday, November 9, 2026, noon in New York.
    private var monday: Date {
        var components = DateComponents(year: 2026, month: 11, day: 9, hour: 12)
        components.timeZone = eastern
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func schedule(next: ShowSchedule.Episode? = nil, status: String = "returning series") -> ShowSchedule {
        ShowSchedule(
            status: status,
            airsDay: "Tuesday",
            airsTime: "21:00",
            airsTimeZone: "America/New_York",
            network: "Apple TV",
            nextEpisode: next,
            lastEpisode: ShowSchedule.Episode(
                season: 2,
                number: 2,
                title: "Previously",
                airsAt: monday.addingTimeInterval(-6 * 86400)
            )
        )
    }

    @Test func `next episode is shown in the viewer's time zone`() {
        let next = ShowSchedule.Episode(
            season: 2,
            number: 3,
            title: "Chip Off the Old Butch",
            airsAt: monday.addingTimeInterval(33 * 3600) // Tuesday 9 PM Eastern
        )
        let summary = schedule(next: next).summary(now: monday, timeZone: pacific)
        #expect(summary?.hasPrefix("Next episode S2 · E3 · ") == true)
        #expect(summary?.contains("6:00") == true)
        #expect(schedule(next: next).shortSummary(now: monday, timeZone: pacific) == "New episode Tue")
    }

    @Test func `weekly slot moves into the viewer's time zone`() throws {
        let airing = try #require(schedule().weeklyAiring(after: monday, in: pacific))
        #expect(airing.timeIntervalSince(monday) == 33 * 3600)
        #expect(schedule().summary(now: monday, timeZone: pacific)?.hasPrefix("New episodes Tuesdays at 6:00") == true)
    }

    @Test func `ended shows say so`() {
        #expect(schedule(status: "ended").summary(now: monday) == "This show has ended")
        #expect(schedule(status: "ended").weeklyAiring(after: monday) == nil)
    }

    @Test func `links go stale a few hours after an episode airs`() throws {
        let stale = try #require(schedule().linksStaleBefore(now: monday))
        #expect(stale == monday.addingTimeInterval(-6 * 86400 + 6 * 3600))

        let justAired = ShowSchedule(lastEpisode: .init(season: 1, number: 1, title: nil, airsAt: monday))
        #expect(justAired.linksStaleBefore(now: monday.addingTimeInterval(3600)) == nil)
    }

    @Test func `Trakt lookups use the client ID and handle missing episodes`() async throws {
        let session = PathSession([
            "/search/tmdb/248830": (200, #"[{"type":"show","show":{"ids":{"trakt":230595,"tmdb":248830}}}]"#),
            "/shows/230595": (
                200,
                #"{"status":"returning series","network":"Apple TV","#
                    + #""airs":{"day":"Tuesday","time":"21:00","timezone":"America/New_York"}}"#
            ),
            "/shows/230595/next_episode": (
                200,
                #"{"season":2,"number":3,"title":"Chip Off the Old Butch","first_aired":"2026-11-11T02:00:00.000Z"}"#
            ),
            "/shows/230595/last_episode": (204, "")
        ])

        let schedule = try #require(
            try await TraktClient(clientID: "client-id", session: session).schedule(forTMDBShow: 248_830)
        )
        #expect(schedule.airsDay == "Tuesday")
        #expect(schedule.network == "Apple TV")
        #expect(schedule.nextEpisode?.label == "S2 · E3")
        #expect(schedule.nextEpisode?.airsAt == Date(timeIntervalSince1970: 1_794_362_400))
        #expect(schedule.lastEpisode == nil)

        let request = try #require(await session.requests.first)
        #expect(request.value(forHTTPHeaderField: "trakt-api-key") == "client-id")
        #expect(request.value(forHTTPHeaderField: "trakt-api-version") == "2")
        #expect(request.url?.query?.contains("type=show") == true)
    }

    @Test func `shows Trakt doesn't know have no schedule`() async throws {
        let session = PathSession(["/search/tmdb/1": (200, "[]")])
        #expect(try await TraktClient(clientID: "id", session: session).schedule(forTMDBShow: 1) == nil)
    }
}

@Suite("Title link refresh")
@MainActor
struct TitleLinkRefreshTests {
    private func cache() -> TitleLinksCache {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Refresh-\(UUID().uuidString)")
        return TitleLinksCache(
            fileStore: JSONFileStore(fileName: "links.json", folderName: "Stream", baseDirectory: directory)
        )
    }

    @Test func `a new episode since the last lookup asks again`() async {
        let session = RoutedSession([
            "api.movieofthenight.com": (200, EpisodeFixtures.show),
            "query.wikidata.org": (200, EpisodeFixtures.wikidata)
        ])
        let sharedCache = cache()
        let model = TitleLinksModel(
            wikidata: WikidataClient(session: session),
            streamingAvailability: StreamingAvailabilityClient(apiKey: "k", session: session),
            cache: sharedCache
        )

        await model.load(for: EpisodeFixtures.bluey, region: "CA")
        await model.load(for: EpisodeFixtures.bluey, region: "CA", staleBefore: Date().addingTimeInterval(-3600))
        #expect(await session.count(host: "api.movieofthenight.com") == 1)

        await model.load(for: EpisodeFixtures.bluey, region: "CA", staleBefore: Date().addingTimeInterval(60))
        #expect(await session.count(host: "api.movieofthenight.com") == 2)
    }

    @Test func `a failed refresh keeps the episode list`() async throws {
        var now = Date()
        let directory = FileManager.default.temporaryDirectory.appending(path: "Refresh-\(UUID().uuidString)")
        let sharedCache = TitleLinksCache(
            fileStore: JSONFileStore(fileName: "links.json", folderName: "Stream", baseDirectory: directory),
            now: { now }
        )
        let working = RoutedSession([
            "api.movieofthenight.com": (200, EpisodeFixtures.show),
            "query.wikidata.org": (200, EpisodeFixtures.wikidata)
        ])
        await TitleLinksModel(
            wikidata: WikidataClient(session: working),
            streamingAvailability: StreamingAvailabilityClient(apiKey: "k", session: working),
            cache: sharedCache
        ).load(for: EpisodeFixtures.bluey, region: "CA")

        // A week and a bit later, the lookup fails.
        now.addTimeInterval(8 * 86400)
        let failing = RoutedSession([
            "api.movieofthenight.com": (500, Data()),
            "query.wikidata.org": (200, EpisodeFixtures.wikidata)
        ])
        let model = TitleLinksModel(
            wikidata: WikidataClient(session: failing),
            streamingAvailability: StreamingAvailabilityClient(apiKey: "k", session: failing),
            cache: sharedCache
        )
        await model.load(for: EpisodeFixtures.bluey, region: "CA")

        #expect(await failing.count(host: "api.movieofthenight.com") == 1)
        #expect(model.links(for: EpisodeFixtures.bluey, region: "CA")?.episodes.count == 3)
    }

    @Test func `movies are kept longer than shows`() {
        let movie = TMDBMediaResult(
            id: 1,
            mediaType: .movie,
            title: "M",
            overview: "",
            posterPath: nil,
            releaseDate: nil
        )
        #expect(TitleLinksModel.lifetime(for: movie, fromStreamingAvailability: true) == .oneMonth)
        #expect(TitleLinksModel.lifetime(for: EpisodeFixtures.bluey, fromStreamingAvailability: true) == .oneWeek)
        #expect(TitleLinksModel.lifetime(for: movie, fromStreamingAvailability: false) == .oneDay)
    }
}

@Suite("Settings sync")
@MainActor
struct SettingsSyncTests {
    private func site(_ name: String, _ url: String) -> SavedSite {
        SavedSite(name: name, urlString: url)
    }

    @Test func `first sync keeps this device's sites and adds the rest`() {
        let local = [site("Netflix", "https://www.netflix.com/browse"), site("Blog", "https://example.com")]
        let remote = [site("Netflix (phone)", "https://www.netflix.com"), site("Disney+", "https://www.disneyplus.com")]

        let merged = ProfileSettingsSnapshot.merged(local: local, remote: remote)
        #expect(merged.map(\.name) == ["Netflix", "Blog", "Disney+"])
    }

    @Test func `site edits are reported and iCloud updates are not`() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Sites-\(UUID().uuidString)")
        let store = SiteStore(
            fileStore: JSONFileStore(fileName: "sites.json", folderName: "Stream", baseDirectory: directory)
        )
        var changes = 0
        store.changeHandler = { changes += 1 }

        store.addSite(SiteDraft(name: "Crave", address: "https://www.crave.ca"))
        #expect(changes == 1)

        store.replaceSites([site("Netflix", "https://www.netflix.com")])
        #expect(changes == 1)
        #expect(store.sites.map(\.name) == ["Netflix"])
    }
}

@Suite("Jellyfin Quick Connect")
@MainActor
struct QuickConnectTests {
    private func connection(
        _ routes: [String: (status: Int, body: String)]
    ) -> (JellyfinConnection, EphemeralTokenStorage) {
        let tokens = EphemeralTokenStorage()
        let defaults = UserDefaults(suiteName: "QuickConnectTests.\(UUID().uuidString)")!
        let connection = JellyfinConnection(
            profile: .main,
            userDefaults: defaults,
            tokenStorage: tokens,
            session: JellyfinFixtureSession(routes)
        )
        return (connection, tokens)
    }

    @Test func `a code signs this device in once approved`() async throws {
        let (connection, tokens) = connection([
            "/QuickConnect/Enabled": (200, "true"),
            "/QuickConnect/Initiate": (200, #"{"Authenticated":false,"Secret":"s3cret","Code":"123456"}"#),
            "/QuickConnect/Connect": (200, #"{"Authenticated":true,"Secret":"s3cret","Code":"123456"}"#),
            "/Users/AuthenticateWithQuickConnect": (200, JellyfinFixtures.authentication),
            "/System/Info/Public": (200, JellyfinFixtures.publicInfo),
            "/UserViews": (200, JellyfinFixtures.views)
        ])
        var shared = 0
        connection.accountChangeHandler = { shared += 1 }

        let request = try await connection.beginQuickConnect(serverAddress: "nas:8096")
        #expect(request.code == "123456")

        try await connection.completeQuickConnect(request, pollInterval: .milliseconds(1))
        #expect(connection.account?.userName == "luke")
        #expect(connection.account?.serverName == "Home Server")
        #expect(tokens.token(for: "profile-main") == "token-123")
        #expect(shared == 1)
        #expect(connection.currentSuggestion?.serverAddress == "http://nas:8096")
    }

    @Test func `servers with Quick Connect off say so`() async {
        let (connection, _) = connection(["/QuickConnect/Enabled": (200, "false")])
        await #expect(throws: JellyfinError.quickConnectDisabled) {
            _ = try await connection.beginQuickConnect(serverAddress: "nas:8096")
        }
    }

    @Test func `a shared server fills in sign-in without signing in`() {
        let (connection, _) = connection([:])
        let suggestion = JellyfinServerSuggestion(
            serverAddress: "http://nas:8096",
            serverName: "Home",
            userName: "luke"
        )
        connection.applySuggestion(suggestion)

        #expect(connection.suggestion == suggestion)
        #expect(connection.currentSuggestion == suggestion)
        #expect(!connection.isSignedIn)
    }
}

/// Answers by URL path, recording requests.
actor PathSession: TMDBSession {
    private let routes: [String: (status: Int, body: String)]
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: (status: Int, body: String)]) {
        self.routes = routes
    }

    // swiftlint:disable:next async_without_await
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let route = routes[request.url?.path ?? ""] ?? (404, "")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: route.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(route.body.utf8), response)
    }
}
