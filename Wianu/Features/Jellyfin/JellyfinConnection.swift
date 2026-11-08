import Foundation
import Observation
#if canImport(AppKit)
    import AppKit
#endif

/// The Jellyfin account for one profile, and the libraries it can see.
@MainActor
@Observable
final class JellyfinConnection {
    private(set) var account: JellyfinAccount?
    private(set) var libraries: [JellyfinItem] = []
    private(set) var librariesError: String?
    private(set) var isLoadingLibraries = false

    @ObservationIgnored
    private let profile: AppProfile
    @ObservationIgnored
    private let userDefaults: UserDefaults
    @ObservationIgnored
    private let tokenStorage: any JellyfinTokenStorage
    @ObservationIgnored
    private let session: any JellyfinHTTPSession
    @ObservationIgnored
    private var token: String?

    init(
        profile: AppProfile,
        userDefaults: UserDefaults = .standard,
        tokenStorage: any JellyfinTokenStorage = KeychainTokenStorage(),
        session: any JellyfinHTTPSession = URLSession.shared
    ) {
        self.profile = profile
        self.userDefaults = userDefaults
        self.tokenStorage = tokenStorage
        self.session = session

        let storedAccount = userDefaults
            .data(forKey: accountKey)
            .flatMap { try? JSONDecoder().decode(JellyfinAccount.self, from: $0) }
        let storedToken = tokenStorage.token(for: tokenAccount)

        if let storedAccount, let storedToken {
            account = storedAccount
            token = storedToken
        }
    }

    var isSignedIn: Bool {
        account != nil
    }

    var client: JellyfinClient? {
        guard let account, let token else { return nil }
        return makeClient(serverURL: account.serverURL, token: token)
    }

    func library(id: String) -> JellyfinItem? {
        libraries.first { $0.id == id }
    }

    func signIn(serverAddress: String, username: String, password: String) async throws {
        guard let serverURL = JellyfinClient.serverURL(from: serverAddress) else {
            throw JellyfinError.invalidServerAddress
        }

        let client = makeClient(serverURL: serverURL, token: nil)
        let info = try await client.publicSystemInfo()
        let result = try await client.authenticate(
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )

        tokenStorage.setToken(result.accessToken, for: tokenAccount)
        token = result.accessToken
        account = JellyfinAccount(
            serverURL: serverURL,
            serverName: info.serverName,
            userID: result.user.id,
            userName: result.user.name ?? username
        )
        persistAccount()
        await refreshLibraries()
    }

    func signOut() async {
        if let client {
            try? await client.signOut()
        }
        clearAccount()
    }

    func refreshLibraries() async {
        guard let client, let account else {
            libraries = []
            return
        }

        isLoadingLibraries = true
        defer { isLoadingLibraries = false }

        do {
            libraries = try await client
                .libraries(userID: account.userID)
                .filter(\.isVideoLibrary)
            librariesError = nil
        } catch is CancellationError {
            return
        } catch {
            handle(error)
            librariesError = error.localizedDescription
        }
    }

    /// Signs out locally when the server has revoked the token.
    func handle(_ error: any Error) {
        if let error = error as? JellyfinError, error == .unauthorized {
            clearAccount()
        }
    }
}

private extension JellyfinConnection {
    var accountKey: String {
        profile.defaultsKey("jellyfin.account")
    }

    var deviceIDKey: String {
        profile.defaultsKey("jellyfin.deviceID")
    }

    var tokenAccount: String {
        "profile-\(profile.rawValue)"
    }

    /// Jellyfin ties a token to a device ID, so each profile gets its own.
    var deviceID: String {
        if let existing = userDefaults.string(forKey: deviceIDKey) {
            return existing
        }

        let id = UUID().uuidString
        userDefaults.set(id, forKey: deviceIDKey)
        return id
    }

    var deviceName: String {
        #if canImport(AppKit)
            let name = Host.current().localizedName ?? "Mac"
        #else
            let name = "Mac"
        #endif
        return profile == .main ? name : "\(name) (\(profile.displayName))"
    }

    var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    func makeClient(serverURL: URL, token: String?) -> JellyfinClient {
        JellyfinClient(
            serverURL: serverURL,
            deviceID: deviceID,
            deviceName: deviceName,
            clientVersion: clientVersion,
            accessToken: token,
            session: session
        )
    }

    func persistAccount() {
        if let account, let data = try? JSONEncoder().encode(account) {
            userDefaults.set(data, forKey: accountKey)
        } else {
            userDefaults.removeObject(forKey: accountKey)
        }
    }

    func clearAccount() {
        tokenStorage.setToken(nil, for: tokenAccount)
        token = nil
        account = nil
        libraries = []
        persistAccount()
    }
}
