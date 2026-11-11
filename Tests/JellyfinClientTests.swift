import Foundation
import Testing
@testable import Stream

/// Answers requests by path and records what was sent.
actor JellyfinFixtureSession: JellyfinHTTPSession {
    private let routes: [String: (status: Int, body: String)]
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: (status: Int, body: String)]) {
        self.routes = routes
    }

    // Required to be async by JellyfinHTTPSession.
    // swiftlint:disable:next async_without_await
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        let route = routes[path] ?? (404, "")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: route.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(route.body.utf8), response)
    }

    func request(at index: Int) -> URLRequest? {
        requests.indices.contains(index) ? requests[index] : nil
    }

    func lastRequest() -> URLRequest? {
        requests.last
    }
}

nonisolated enum JellyfinFixtures {
    static let publicInfo = #"{"ServerName":"Home Server","Version":"10.10.7","Id":"abc"}"#
    static let authentication = #"{"User":{"Id":"user-1","Name":"luke"},"AccessToken":"token-123","ServerId":"abc"}"#
    static let views = """
    {"Items":[
      {"Id":"lib-movies","Name":"Movies","Type":"CollectionFolder","CollectionType":"movies"},
      {"Id":"lib-music","Name":"Music","Type":"CollectionFolder","CollectionType":"music"},
      {"Id":"lib-shows","Name":"Shows","Type":"CollectionFolder","CollectionType":"tvshows"}
    ],"TotalRecordCount":3}
    """
    static let episode = """
    {"Id":"ep-1","Name":"Pilot","Type":"Episode","SeriesName":"The Show","SeriesId":"series-1",
     "SeriesPrimaryImageTag":"stag","IndexNumber":1,"ParentIndexNumber":2,"RunTimeTicks":36000000000,
     "UserData":{"PlaybackPositionTicks":9000000000,"Played":false}}
    """
}

@Suite("Jellyfin client")
struct JellyfinClientTests {
    private func client(
        _ session: JellyfinFixtureSession,
        server: String = "http://nas:8096",
        token: String? = "token-123"
    ) -> JellyfinClient {
        JellyfinClient(
            serverURL: URL(string: server)!,
            deviceID: "device-1",
            deviceName: "Luke’s Mac",
            clientVersion: "2.0",
            accessToken: token,
            session: session
        )
    }

    @Test(arguments: [
        ("nas:8096", "http://nas:8096"),
        ("  192.168.1.20:8096  ", "http://192.168.1.20:8096"),
        ("http://192.168.1.20:8096/web/#/home.html", "http://192.168.1.20:8096"),
        ("https://media.example.com/jellyfin/", "https://media.example.com/jellyfin"),
        ("HTTPS://media.example.com/jellyfin/web/", "https://media.example.com/jellyfin"),
        ("https://example.com/website", "https://example.com/website")
    ])
    func `server addresses are normalized`(input: String, expected: String) {
        #expect(JellyfinClient.serverURL(from: input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://nas", "http://"])
    func `unusable server addresses are rejected`(input: String) {
        #expect(JellyfinClient.serverURL(from: input) == nil)
    }

    @Test func `authorization header carries the token and escapes values`() {
        let header = client(JellyfinFixtureSession([:])).authorizationHeader
        #expect(header.hasPrefix("MediaBrowser "))
        #expect(header.contains(#"Client="Stream""#))
        #expect(header.contains(#"DeviceId="device-1""#))
        #expect(header.contains(#"Token="token-123""#))
        #expect(header.contains("Luke%E2%80%99s Mac"))
    }

    @Test func `sign in posts credentials`() async throws {
        let session = JellyfinFixtureSession([
            "/Users/AuthenticateByName": (200, JellyfinFixtures.authentication)
        ])
        let result = try await client(session, token: nil)
            .authenticate(username: "luke", password: "secret")

        #expect(result.accessToken == "token-123")
        #expect(result.user.id == "user-1")

        let request = try #require(await session.lastRequest())
        #expect(request.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
        #expect(body == ["Username": "luke", "Pw": "secret"])
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=") == false)
    }

    @Test func `wrong password is reported as invalid credentials`() async {
        let session = JellyfinFixtureSession(["/Users/AuthenticateByName": (401, "")])
        await #expect(throws: JellyfinError.invalidCredentials) {
            try await client(session, token: nil).authenticate(username: "luke", password: "nope")
        }
    }

    @Test func `revoked tokens are reported as unauthorized`() async {
        let session = JellyfinFixtureSession(["/UserViews": (401, "")])
        await #expect(throws: JellyfinError.unauthorized) {
            try await client(session).libraries(userID: "user-1")
        }
    }

    @Test func `library items request a sorted recursive page`() async throws {
        let session = JellyfinFixtureSession([
            "/jellyfin/Items": (200, #"{"Items":[\#(JellyfinFixtures.episode)],"TotalRecordCount":41}"#)
        ])
        let page = try await client(session, server: "https://host/jellyfin")
            .items(userID: "user-1", parentID: "lib-shows", collectionType: "tvshows", startIndex: 20)

        #expect(page.totalCount == 41)
        #expect(page.items.first?.seriesName == "The Show")

        let url = try #require(await session.lastRequest()?.url)
        let query = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }
        )
        #expect(url.path == "/jellyfin/Items")
        #expect(query["parentId"] == "lib-shows")
        #expect(query["includeItemTypes"] == "Series")
        #expect(query["recursive"] == "true")
        #expect(query["startIndex"] == "20")
        #expect(query["sortBy"] == "SortName")
    }

    @Test func `direct play streams the original file`() throws {
        let source = try client(JellyfinFixtureSession([:])).playbackSource(
            itemID: "movie-1",
            mediaSource: JellyfinMediaSource(
                id: "source-1",
                container: "mp4",
                supportsDirectPlay: true,
                supportsDirectStream: true,
                supportsTranscoding: true,
                transcodingURL: nil
            ),
            playSessionID: "session-9"
        )

        #expect(source.playMethod == .directPlay)
        #expect(source.url.path == "/Videos/movie-1/stream")
        let query = URLComponents(url: source.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "static", value: "true")))
        #expect(query.contains(URLQueryItem(name: "mediaSourceId", value: "source-1")))
        #expect(query.contains(URLQueryItem(name: "ApiKey", value: "token-123")))
    }

    @Test func `other files use the server's transcoding URL`() throws {
        let source = try client(JellyfinFixtureSession([:]), server: "https://host/jellyfin/").playbackSource(
            itemID: "movie-1",
            mediaSource: JellyfinMediaSource(
                id: "source-1",
                container: "mkv",
                supportsDirectPlay: false,
                supportsDirectStream: false,
                supportsTranscoding: true,
                transcodingURL: "/videos/movie-1/master.m3u8?MediaSourceId=source-1&ApiKey=token-123"
            ),
            playSessionID: nil
        )

        #expect(source.playMethod == .transcode)
        #expect(
            source.url.absoluteString
                == "https://host/jellyfin/videos/movie-1/master.m3u8?MediaSourceId=source-1&ApiKey=token-123"
        )
    }

    @Test func `playback info sends the AVPlayer device profile`() async throws {
        let session = JellyfinFixtureSession([
            "/Items/movie-1/PlaybackInfo": (
                200,
                #"{"MediaSources":[{"Id":"source-1","Container":"mkv","SupportsDirectPlay":false,"#
                    + #""TranscodingUrl":"/videos/movie-1/master.m3u8?ApiKey=token-123"}],"PlaySessionId":"ps"}"#
            )
        ])
        let source = try await client(session).playbackSource(itemID: "movie-1", userID: "user-1")
        #expect(source.playSessionID == "ps")

        let body = try #require(await session.lastRequest()?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["UserId"] as? String == "user-1")
        let profile = try #require(json["DeviceProfile"] as? [String: Any])
        let transcoding = try #require((profile["TranscodingProfiles"] as? [[String: Any]])?.first)
        #expect(transcoding["Protocol"] as? String == "hls")
        #expect(transcoding["Container"] as? String == "mp4")
    }

    @Test func `a chosen subtitle asks for an HLS stream that carries it`() async throws {
        let session = JellyfinFixtureSession([
            "/Items/movie-1/PlaybackInfo": (
                200,
                #"{"MediaSources":[{"Id":"source-1","SupportsDirectPlay":false,"#
                    + #""TranscodingUrl":"/videos/movie-1/master.m3u8?ApiKey=token-123","MediaStreams":["#
                    + #"{"Index":0,"Type":"Video"},{"Index":2,"Type":"Subtitle","DisplayTitle":"English - SRT"},"#
                    + #"{"Index":3,"Type":"Subtitle","Language":"fra"}]}]}"#
            )
        ])

        let source = try await client(session).playbackSource(
            itemID: "movie-1",
            userID: "user-1",
            subtitleStreamIndex: 2
        )
        #expect(source.subtitles.map(\.index) == [2, 3])
        #expect(source.subtitles.first?.title == "English - SRT")

        let body = try #require(await session.lastRequest()?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["SubtitleStreamIndex"] as? Int == 2)
        #expect(json["EnableDirectPlay"] as? Bool == false)
        #expect(json["EnableDirectStream"] as? Bool == false)
    }

    @Test func `without a subtitle, direct play stays on`() async throws {
        let session = JellyfinFixtureSession([
            "/Items/movie-1/PlaybackInfo": (
                200,
                #"{"MediaSources":[{"Id":"source-1","SupportsDirectPlay":true}]}"#
            )
        ])
        _ = try await client(session).playbackSource(itemID: "movie-1", userID: "user-1")

        let body = try #require(await session.lastRequest()?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["SubtitleStreamIndex"] == nil)
        #expect(json["EnableDirectPlay"] as? Bool == true)
    }

    @Test func `episodes describe themselves`() throws {
        let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(JellyfinFixtures.episode.utf8))
        #expect(item.kind == .episode)
        #expect(item.isPlayable)
        #expect(item.episodeLabel == "S2 · E1")
        #expect(item.subtitle == "The Show — S2 · E1")
        #expect(item.progress == 0.25)
        #expect(item.resumePositionSeconds == 900)
    }

    @Test func `episodes without artwork borrow the series poster`() {
        let item = JellyfinItem(
            id: "ep-1",
            name: "Pilot",
            type: "Episode",
            seriesID: "series-1",
            seriesPrimaryImageTag: "stag"
        )
        let url = client(JellyfinFixtureSession([:])).imageURL(for: item, maxWidth: 300)
        #expect(url?.path == "/Items/series-1/Images/Primary")
        #expect(url?.query?.contains("tag=stag") == true)
    }

    @Test func `library search asks for movies and shows with TMDB IDs`() async throws {
        let session = JellyfinFixtureSession([
            "/Items": (200, #"{"Items":[{"Id":"m1","Name":"Arrival","Type":"Movie","ProviderIds":{"Tmdb":"329865"}}]}"#)
        ])
        let items = try await client(session).search(term: "Arrival", userID: "user-1")
        #expect(items.first?.providerIDs?["Tmdb"] == "329865")

        let url = try #require(await session.lastRequest()?.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "searchTerm", value: "Arrival")))
        #expect(query.contains(URLQueryItem(name: "includeItemTypes", value: "Movie,Series")))
        #expect(query.contains { $0.name == "fields" && $0.value?.contains("ProviderIds") == true })
    }

    @Test func `library matches prefer the TMDB ID`() {
        let media = TMDBMediaResult(
            id: 329_865,
            mediaType: .movie,
            title: "Arrival",
            overview: "",
            posterPath: nil,
            releaseDate: "2016-11-11"
        )
        let wrongYear = JellyfinItem(id: "a", name: "Arrival", type: "Movie", productionYear: 1996)
        let tagged = JellyfinItem(
            id: "b",
            name: "Arrival (Director's Cut)",
            type: "Movie",
            providerIDs: ["Tmdb": "329865"]
        )
        let untagged = JellyfinItem(id: "c", name: "arrival", type: "Movie", productionYear: 2016)
        let show = JellyfinItem(id: "d", name: "Arrival", type: "Series", providerIDs: ["Tmdb": "329865"])

        #expect(JellyfinLibraryMatch.item(for: media, in: [show, wrongYear, untagged, tagged])?.id == "b")
        #expect(JellyfinLibraryMatch.item(for: media, in: [show, wrongYear, untagged])?.id == "c")
        #expect(JellyfinLibraryMatch.item(for: media, in: [show, wrongYear]) == nil)
    }

    @Test func `progress reports convert seconds to ticks`() {
        #expect(JellyfinPlaybackReport.ticks(fromSeconds: 1.5) == 15_000_000)
        #expect(JellyfinPlaybackReport.ticks(fromSeconds: .nan) == 0)
        #expect(JellyfinPlaybackReport.ticks(fromSeconds: -3) == 0)
    }
}

@Suite("Jellyfin connection")
@MainActor
struct JellyfinConnectionTests {
    private func defaults() -> UserDefaults {
        let name = "JellyfinConnectionTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func `signing in stores the account and lists video libraries`() async throws {
        let defaults = defaults()
        let tokens = EphemeralTokenStorage()
        let session = JellyfinFixtureSession([
            "/System/Info/Public": (200, JellyfinFixtures.publicInfo),
            "/Users/AuthenticateByName": (200, JellyfinFixtures.authentication),
            "/UserViews": (200, JellyfinFixtures.views)
        ])
        let connection = JellyfinConnection(
            profile: .kids,
            userDefaults: defaults,
            tokenStorage: tokens,
            session: session
        )

        try await connection.signIn(serverAddress: "nas:8096", username: " luke ", password: "secret")

        #expect(connection.account?.serverName == "Home Server")
        #expect(connection.account?.serverURL.absoluteString == "http://nas:8096")
        #expect(connection.libraries.map(\.id) == ["lib-movies", "lib-shows"])
        #expect(tokens.token(for: "profile-kids") == "token-123")
        #expect(defaults.data(forKey: "profile.kids.jellyfin.account") != nil)

        // A new connection for the same profile picks the account back up.
        let restored = JellyfinConnection(
            profile: .kids,
            userDefaults: defaults,
            tokenStorage: tokens,
            session: session
        )
        #expect(restored.account?.userID == "user-1")

        // Other profiles stay signed out.
        let main = JellyfinConnection(profile: .main, userDefaults: defaults, tokenStorage: tokens, session: session)
        #expect(main.account == nil)
    }

    @Test func `a revoked token signs the profile out`() async throws {
        let tokens = EphemeralTokenStorage()
        let session = JellyfinFixtureSession([
            "/System/Info/Public": (200, JellyfinFixtures.publicInfo),
            "/Users/AuthenticateByName": (200, JellyfinFixtures.authentication),
            "/UserViews": (401, "")
        ])
        let connection = JellyfinConnection(
            profile: .main,
            userDefaults: defaults(),
            tokenStorage: tokens,
            session: session
        )

        try await connection.signIn(serverAddress: "nas:8096", username: "luke", password: "secret")

        #expect(connection.account == nil)
        #expect(tokens.token(for: "profile-main") == nil)
        #expect(connection.librariesError != nil)
    }
}
