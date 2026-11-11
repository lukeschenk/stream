import Foundation

/// Jellyfin's Quick Connect: a device that can't easily type a password
/// shows a code, and a signed-in device approves it.
nonisolated extension JellyfinClient {
    func isQuickConnectEnabled() async throws -> Bool {
        try await send(path: "QuickConnect/Enabled")
    }

    /// Starts a request that a signed-in device approves by its code.
    func initiateQuickConnect() async throws -> JellyfinQuickConnectState {
        try await send(path: "QuickConnect/Initiate", method: "POST")
    }

    func quickConnectState(secret: String) async throws -> JellyfinQuickConnectState {
        try await send(path: "QuickConnect/Connect", query: [URLQueryItem(name: "secret", value: secret)])
    }

    func authenticate(quickConnectSecret secret: String) async throws -> JellyfinAuthenticationResult {
        struct Body: Encodable {
            let secret: String

            enum CodingKeys: String, CodingKey {
                case secret = "Secret"
            }
        }

        return try await send(
            path: "Users/AuthenticateWithQuickConnect",
            method: "POST",
            body: Body(secret: secret)
        )
    }

    /// Approves another device's Quick Connect code for this user.
    func authorizeQuickConnect(code: String) async throws -> Bool {
        try await send(
            path: "QuickConnect/Authorize",
            method: "POST",
            query: [URLQueryItem(name: "code", value: code)]
        )
    }
}
