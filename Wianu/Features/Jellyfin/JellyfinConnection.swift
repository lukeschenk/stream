import Foundation
import Observation
#if os(macOS)
    import SystemConfiguration
#elseif os(iOS) || os(tvOS)
    import UIKit
#endif

/// The Jellyfin account for one profile, and the libraries it can see.
@MainActor
@Observable
final class JellyfinConnection {
    private(set) var account: JellyfinAccount?
    private(set) var libraries: [JellyfinItem] = []
    private(set) var librariesError: String?
    private(set) var isLoadingLibraries = false
    /// The server and user from another device, to fill in sign-in.
    private(set) var suggestion: JellyfinServerSuggestion?

    /// Called when this device signs in, so iCloud can share the server.
    @ObservationIgnored
    var accountChangeHandler: (() -> Void)?

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
    @ObservationIgnored
    private let deviceName: String

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
        deviceName = Self.deviceName(for: profile)

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

        await finishSignIn(result, serverURL: serverURL, serverName: info.serverName, fallbackName: username)
    }

    // MARK: Quick Connect

    /// Asks the server for a code to approve from a signed-in device.
    func beginQuickConnect(serverAddress: String) async throws -> JellyfinQuickConnectRequest {
        guard let serverURL = JellyfinClient.serverURL(from: serverAddress) else {
            throw JellyfinError.invalidServerAddress
        }

        let client = makeClient(serverURL: serverURL, token: nil)
        guard try await client.isQuickConnectEnabled() else {
            throw JellyfinError.quickConnectDisabled
        }

        do {
            let state = try await client.initiateQuickConnect()
            return JellyfinQuickConnectRequest(serverURL: serverURL, code: state.code, secret: state.secret)
        } catch JellyfinError.unauthorized {
            throw JellyfinError.quickConnectDisabled
        }
    }

    /// Waits for the code to be approved, then signs in. Codes last a few
    /// minutes on the server.
    func completeQuickConnect(
        _ request: JellyfinQuickConnectRequest,
        pollInterval: Duration = .seconds(3),
        timeout: Duration = .seconds(600)
    ) async throws {
        let client = makeClient(serverURL: request.serverURL, token: nil)
        let deadline = ContinuousClock.now + timeout

        while true {
            try await Task.sleep(for: pollInterval)

            let state: JellyfinQuickConnectState
            do {
                state = try await client.quickConnectState(secret: request.secret)
            } catch JellyfinError.server(statusCode: 404) {
                throw JellyfinError.quickConnectExpired
            }

            if state.authenticated {
                break
            }
            if ContinuousClock.now > deadline {
                throw JellyfinError.quickConnectExpired
            }
        }

        let info = try? await client.publicSystemInfo()
        let result = try await client.authenticate(quickConnectSecret: request.secret)
        await finishSignIn(result, serverURL: request.serverURL, serverName: info?.serverName, fallbackName: "")
    }

    /// Approves another device's code for this user.
    func approveQuickConnect(code: String) async throws {
        guard let client else { throw JellyfinError.notSignedIn }

        let trimmed = code.filter(\.isNumber)
        do {
            guard try await client.authorizeQuickConnect(code: trimmed) else {
                throw JellyfinError.quickConnectExpired
            }
        } catch JellyfinError.server(statusCode: 404) {
            throw JellyfinError.quickConnectExpired
        }
    }

    // MARK: iCloud

    /// What to share with other devices: this device's account, or what
    /// another device shared before.
    var currentSuggestion: JellyfinServerSuggestion? {
        if let account {
            return JellyfinServerSuggestion(
                serverAddress: account.serverURL.absoluteString,
                serverName: account.serverName,
                userName: account.userName
            )
        }
        return suggestion
    }

    func applySuggestion(_ suggestion: JellyfinServerSuggestion?) {
        self.suggestion = suggestion
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

/// A Quick Connect sign-in waiting for approval.
struct JellyfinQuickConnectRequest: Equatable {
    let serverURL: URL
    let code: String
    let secret: String
}

private extension JellyfinConnection {
    func finishSignIn(
        _ result: JellyfinAuthenticationResult,
        serverURL: URL,
        serverName: String?,
        fallbackName: String
    ) async {
        tokenStorage.setToken(result.accessToken, for: tokenAccount)
        token = result.accessToken
        account = JellyfinAccount(
            serverURL: serverURL,
            serverName: serverName,
            userID: result.user.id,
            userName: result.user.name ?? fallbackName
        )
        persistAccount()
        accountChangeHandler?()
        await refreshLibraries()
    }

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

    /// The device's name as Jellyfin's dashboard shows it. On the Mac this
    /// comes from System Configuration, which, unlike `Host`, never waits on
    /// the network.
    static func deviceName(for profile: AppProfile) -> String {
        #if os(macOS)
            let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        #elseif os(iOS) || os(tvOS)
            let name = UIDevice.current.model
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
