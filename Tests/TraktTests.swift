import Foundation
@testable import Stream
import Testing

@Suite("Trakt sign-in")
struct TraktAuthTests {
    @Test func `the PKCE challenge is the SHA-256 of the verifier, base64url`() {
        // Expected value from `openssl dgst -sha256 -binary | base64`, made URL-safe.
        let pkce = TraktPKCE(verifier: "dBjftJeZ4CVP-mJ92IXrqQ1nN4fNvLfkmNYhp6Q8U2GgVk")
        #expect(pkce.challenge == "xH6B4NPZip4ELO2ot5AJdTTqIH-R3msAf6ZDVmbLJmY")

        let random = TraktPKCE.random()
        #expect(random.verifier.count == 43)
        #expect(!random.verifier.contains { "+/=".contains($0) })
        #expect(random != TraktPKCE.random())
    }

    @Test func `the browser sign-in asks for an S256 challenge on auth.trakt.tv`() throws {
        let client = TraktAuthClient(clientID: "client-id", session: PathSession([:]))
        let signIn = client.beginWebSignIn(pkce: TraktPKCE(verifier: "verifier"), state: "state-1")

        let components = try #require(URLComponents(url: signIn.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.host == "auth.trakt.tv")
        #expect(components.path == "/oauth/authorize")
        #expect(query["client_id"] == "client-id")
        #expect(query["redirect_uri"] == "com.lukeschenk.stream://trakt")
        #expect(query["code_challenge"] == TraktPKCE(verifier: "verifier").challenge)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "state-1")
    }

    @Test func `the redirect must carry the same state`() throws {
        let client = TraktAuthClient(clientID: "id", session: PathSession([:]))
        let signIn = client.beginWebSignIn(state: "expected")

        let good = try #require(URL(string: "com.lukeschenk.stream://trakt?code=abc&state=expected"))
        #expect(try TraktAuthClient.code(from: good, for: signIn) == "abc")

        let forged = try #require(URL(string: "com.lukeschenk.stream://trakt?code=abc&state=other"))
        #expect(throws: TraktAuthError.stateMismatch) { try TraktAuthClient.code(from: forged, for: signIn) }

        let declined = try #require(URL(string: "com.lukeschenk.stream://trakt?error=access_denied&state=expected"))
        #expect(throws: TraktAuthError.denied) { try TraktAuthClient.code(from: declined, for: signIn) }
    }

    @Test func `the code exchange sends the verifier and no client secret`() async throws {
        let session = PathSession([
            "/oauth/token": (
                200,
                #"{"access_token":"a","refresh_token":"r","expires_in":86400,"created_at":1794400000}"#
            )
        ])
        let client = TraktAuthClient(clientID: "id", session: session)

        let tokens = try await client.exchange(code: "abc", pkce: TraktPKCE(verifier: "v"))
        #expect(tokens == TraktTokens(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date(timeIntervalSince1970: 1_794_486_400)
        ))

        let request = try #require(await session.requests.first)
        let body = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
        #expect(request.httpMethod == "POST")
        #expect(body["code_verifier"] == "v")
        #expect(body["grant_type"] == "authorization_code")
        #expect(body["client_secret"] == nil)
    }

    @Test func `device sign-in waits while pending and reports expired codes`() async throws {
        let code = TraktDeviceCode(
            deviceCode: "d",
            userCode: "ABCD1234",
            verificationURL: URL(string: "https://trakt.tv/activate")!,
            expiresAt: Date().addingTimeInterval(600),
            interval: 5,
            pkce: TraktPKCE(verifier: "v")
        )

        let pending = TraktAuthClient(clientID: "id", session: PathSession(["/oauth/device/token": (400, "")]))
        #expect(try await pending.pollDeviceSignIn(code) == nil)

        let expired = TraktAuthClient(clientID: "id", session: PathSession(["/oauth/device/token": (410, "")]))
        await #expect(throws: TraktAuthError.expired) { try await expired.pollDeviceSignIn(code) }

        let session = PathSession([
            "/oauth/device/token": (200, #"{"access_token":"a","refresh_token":"r","expires_in":60}"#)
        ])
        let approved = TraktAuthClient(clientID: "id", session: session)
        #expect(try await approved.pollDeviceSignIn(code)?.accessToken == "a")
        let body = try await JSONDecoder().decode(
            [String: String].self,
            from: #require(session.requests.first?.httpBody)
        )
        #expect(body["code_verifier"] == "v")
    }
}

@Suite("Trakt history")
@MainActor
struct TraktHistoryTests {
    private static let watched = #"""
    [
      {"show":{"title":"Severance","year":2022,"ids":{"trakt":1,"tmdb":95396}},
       "seasons":[
         {"number":0,"episodes":[{"number":1,"last_watched_at":"2026-11-09T10:00:00.000Z"}]},
         {"number":1,"episodes":[{"number":9,"last_watched_at":"2026-10-01T10:00:00.000Z"}]},
         {"number":2,"episodes":[
           {"number":2,"last_watched_at":"2026-11-08T21:00:00.000Z"},
           {"number":3,"last_watched_at":"2026-11-08T21:00:00.000Z"}
         ]}
       ]},
      {"show":{"title":"No TMDB","year":2020,"ids":{"trakt":2}},
       "seasons":[{"number":1,"episodes":[{"number":1,"last_watched_at":"2026-11-08T21:00:00.000Z"}]}]}
    ]
    """#

    private func watchlist() -> WatchlistStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Trakt-\(UUID().uuidString)")
        return WatchlistStore(
            fileStore: JSONFileStore(fileName: "watchlist.json", folderName: "Stream", baseDirectory: directory)
        )
    }

    @Test func `watched shows keep the latest regular episode with a TMDB ID`() async throws {
        let session = PathSession(["/sync/watched/shows": (200, Self.watched)])
        let shows = try await TraktClient(clientID: "id", session: session).watchedShows(accessToken: "token")

        #expect(shows.count == 1)
        #expect(shows.first?.tmdbID == 95396)
        #expect(shows.first?.season == 2)
        #expect(shows.first?.episode == 3)

        let request = try #require(await session.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @Test func `history moves pick-up forward but never back`() {
        let store = watchlist()
        let now = Date(timeIntervalSince1970: 1_794_400_000)
        let show = TraktWatchedShow(
            tmdbID: 1, title: "Show", year: 2024, season: 2, episode: 3, watchedAt: now.addingTimeInterval(-3600)
        )

        store.recordEpisode(season: 1, episode: 1, title: "Pilot", of: show.media, at: now.addingTimeInterval(-86400))
        #expect(store.apply([show], now: now) == 1)
        #expect(store.item(for: show.media)?.progress?.label == "S2 · E3")

        store.recordEpisode(season: 2, episode: 5, title: nil, of: show.media, at: now)
        #expect(store.apply([show], now: now) == 0)
        #expect(store.item(for: show.media)?.progress?.label == "S2 · E5")
    }

    @Test func `only recently watched shows are added to the watchlist`() {
        let store = watchlist()
        let now = Date(timeIntervalSince1970: 1_794_400_000)
        let recent = TraktWatchedShow(
            tmdbID: 1, title: "Recent", year: nil, season: 1, episode: 2, watchedAt: now.addingTimeInterval(-86400)
        )
        let old = TraktWatchedShow(
            tmdbID: 2, title: "Old", year: nil, season: 4, episode: 1, watchedAt: now.addingTimeInterval(-90 * 86400)
        )

        #expect(store.apply([recent, old], now: now) == 1)
        #expect(store.item(for: recent.media) != nil)
        #expect(store.item(for: old.media) == nil)
    }
}
