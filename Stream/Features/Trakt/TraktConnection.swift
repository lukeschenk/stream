import Foundation
import Observation

/// The Trakt account for one profile. Tokens stay in this device's Keychain;
/// the "pick up" episodes it brings in sync through the watchlist.
@MainActor
@Observable
final class TraktConnection {
    private(set) var username: String?
    private(set) var isSignedIn = false
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var syncError: String?

    @ObservationIgnored
    private let profile: AppProfile
    @ObservationIgnored
    private let userDefaults: UserDefaults
    @ObservationIgnored
    private let tokenStorage: any JellyfinTokenStorage
    @ObservationIgnored
    private let auth: TraktAuthClient?
    @ObservationIgnored
    private let api: TraktClient?
    @ObservationIgnored
    private var tokens: TraktTokens?

    /// How long to wait between automatic syncs.
    static let syncInterval: TimeInterval = 30 * 60

    init(
        profile: AppProfile,
        userDefaults: UserDefaults = .standard,
        tokenStorage: any JellyfinTokenStorage = KeychainTokenStorage(
            service: (Bundle.main.bundleIdentifier ?? "Stream") + ".trakt"
        ),
        session: any TMDBSession = URLSession.shared,
        clientID: String? = TraktClient.configuredClientID
    ) {
        self.profile = profile
        self.userDefaults = userDefaults
        self.tokenStorage = tokenStorage
        auth = clientID.map { TraktAuthClient(clientID: $0, session: session) }
        api = clientID.map { TraktClient(clientID: $0, session: session) }

        tokens = tokenStorage
            .token(for: tokenAccount)
            .flatMap { try? JSONDecoder().decode(TraktTokens.self, from: Data($0.utf8)) }
        isSignedIn = tokens != nil
        username = userDefaults.string(forKey: profile.defaultsKey("traktUsername"))
        lastSyncedAt = userDefaults.object(forKey: profile.defaultsKey("traktLastSync")) as? Date
    }

    /// Whether this build has a Trakt Client ID.
    var isAvailable: Bool {
        auth != nil
    }

    private var tokenAccount: String {
        "trakt-\(profile.rawValue)"
    }

    // MARK: Signing in

    func beginWebSignIn() -> TraktWebSignIn? {
        auth?.beginWebSignIn()
    }

    func completeWebSignIn(_ signIn: TraktWebSignIn, callback: URL) async throws {
        guard let auth else { return }
        let code = try TraktAuthClient.code(from: callback, for: signIn)
        try await signedIn(with: auth.exchange(code: code, pkce: signIn.pkce))
    }

    func beginDeviceSignIn() async throws -> TraktDeviceCode? {
        try await auth?.beginDeviceSignIn()
    }

    /// Waits until the code is approved, expires or the task is cancelled.
    func completeDeviceSignIn(_ code: TraktDeviceCode) async throws {
        guard let auth else { return }
        while Date() < code.expiresAt {
            try await Task.sleep(for: .seconds(code.interval))
            if let tokens = try await auth.pollDeviceSignIn(code) {
                try await signedIn(with: tokens)
                return
            }
        }
        throw TraktAuthError.expired
    }

    func signOut() async {
        if let tokens {
            await auth?.revoke(tokens)
        }
        clearAccount()
    }

    private func signedIn(with tokens: TraktTokens) async throws {
        store(tokens)
        isSignedIn = true
        username = try? await api?.username(accessToken: tokens.accessToken)
        userDefaults.set(username, forKey: profile.defaultsKey("traktUsername"))
    }

    private func store(_ tokens: TraktTokens) {
        self.tokens = tokens
        let json = (try? JSONEncoder().encode(tokens)).flatMap { String(data: $0, encoding: .utf8) }
        tokenStorage.setToken(json, for: tokenAccount)
    }

    private func clearAccount() {
        tokens = nil
        tokenStorage.setToken(nil, for: tokenAccount)
        isSignedIn = false
        username = nil
        lastSyncedAt = nil
        for key in ["traktUsername", "traktLastSync"] {
            userDefaults.removeObject(forKey: profile.defaultsKey(key))
        }
    }

    /// A current access token, refreshed when it's about to expire. A
    /// refresh Trakt rejects means the sign-in is gone, so it signs out.
    private func accessToken() async throws -> String? {
        guard let auth, let current = tokens else { return nil }
        guard current.needsRefresh() else { return current.accessToken }

        do {
            let refreshed = try await auth.refresh(current)
            store(refreshed)
            return refreshed.accessToken
        } catch let TraktAuthError.server(statusCode) where (400 ..< 500).contains(statusCode) {
            clearAccount()
            return nil
        }
    }

    // MARK: History

    /// Updates "pick up" from Trakt's watch history, at most every
    /// `syncInterval` unless `force` is set.
    func syncHistory(into watchlist: WatchlistStore, force: Bool = false, now: Date = Date()) async {
        guard isSignedIn, !isSyncing, let api else { return }
        if !force, let lastSyncedAt, now.timeIntervalSince(lastSyncedAt) < Self.syncInterval {
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            guard let token = try await accessToken() else { return }
            let history = try await api.watchedShows(accessToken: token)
            watchlist.apply(history, now: now)
            lastSyncedAt = now
            userDefaults.set(now, forKey: profile.defaultsKey("traktLastSync"))
            syncError = nil
        } catch TraktError.server(statusCode: 401) {
            clearAccount()
            syncError = "Trakt signed you out. Sign in again to keep syncing."
        } catch {
            syncError = "Couldn’t sync with Trakt. \(error.localizedDescription)"
        }
    }
}
