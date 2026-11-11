import CryptoKit
import Foundation

/// Tokens for a Trakt account. `expiresAt` comes from each response, since
/// Trakt's docs disagree on how long access tokens last.
nonisolated struct TraktTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    /// Refresh a little early so a request doesn't race the expiry.
    func needsRefresh(now: Date = Date()) -> Bool {
        expiresAt.addingTimeInterval(-300) <= now
    }
}

/// A PKCE verifier and its S256 challenge (RFC 7636). Trakt apps made since
/// October 2026 have no client secret, so every sign-in uses one.
nonisolated struct TraktPKCE: Equatable, Sendable {
    let verifier: String

    var challenge: String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    static func random() -> TraktPKCE {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
        return TraktPKCE(verifier: Data(bytes).base64URLEncoded())
    }
}

/// A browser sign-in in progress.
nonisolated struct TraktWebSignIn: Equatable, Sendable {
    let url: URL
    let state: String
    let pkce: TraktPKCE
}

/// A code to enter at trakt.tv/activate, for Apple TV.
nonisolated struct TraktDeviceCode: Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: TimeInterval
    let pkce: TraktPKCE
}

nonisolated enum TraktAuthError: Error, Equatable {
    case invalidCallback
    case stateMismatch
    case denied
    case expired
    case server(statusCode: Int)
}

/// Trakt's OAuth endpoints, signed in with PKCE and no client secret.
nonisolated struct TraktAuthClient: Sendable {
    static let baseURL = URL(string: "https://auth.trakt.tv")!
    static let callbackScheme = "com.lukeschenk.stream"
    /// Must match the redirect URI in the Trakt app's settings.
    static let redirectURI = "\(callbackScheme)://trakt"

    let clientID: String
    private let session: any TMDBSession

    init(clientID: String, session: any TMDBSession = URLSession.shared) {
        self.clientID = clientID
        self.session = session
    }

    // MARK: Browser sign-in

    func beginWebSignIn(pkce: TraktPKCE = .random(), state: String = UUID().uuidString) -> TraktWebSignIn {
        var components = URLComponents(
            url: Self.baseURL.appending(path: "oauth/authorize"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return TraktWebSignIn(url: components.url!, state: state, pkce: pkce)
    }

    /// The authorization code from the redirect back to Stream.
    static func code(from callback: URL, for signIn: TraktWebSignIn) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if value("error") != nil {
            throw TraktAuthError.denied
        }
        guard value("state") == signIn.state else { throw TraktAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw TraktAuthError.invalidCallback }
        return code
    }

    func exchange(code: String, pkce: TraktPKCE, now: Date = Date()) async throws -> TraktTokens {
        let response: TokenResponse = try await post("oauth/token", body: [
            "code": code,
            "client_id": clientID,
            "redirect_uri": Self.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": pkce.verifier
        ])
        return response.tokens(now: now)
    }

    func refresh(_ tokens: TraktTokens, now: Date = Date()) async throws -> TraktTokens {
        let response: TokenResponse = try await post("oauth/token", body: [
            "refresh_token": tokens.refreshToken,
            "client_id": clientID,
            "redirect_uri": Self.redirectURI,
            "grant_type": "refresh_token"
        ])
        return response.tokens(now: now)
    }

    func revoke(_ tokens: TraktTokens) async {
        _ = try? await send("oauth/revoke", body: [
            "token": tokens.accessToken,
            "client_id": clientID
        ])
    }

    // MARK: Device sign-in

    func beginDeviceSignIn(pkce: TraktPKCE = .random(), now: Date = Date()) async throws -> TraktDeviceCode {
        let response: DeviceCodeResponse = try await post("oauth/device/code", body: [
            "client_id": clientID,
            "code_challenge": pkce.challenge,
            "code_challenge_method": "S256"
        ])
        return TraktDeviceCode(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationURL: URL(string: response.verificationURL) ?? URL(string: "https://trakt.tv/activate")!,
            expiresAt: now.addingTimeInterval(response.expiresIn),
            interval: max(response.interval, 1),
            pkce: pkce
        )
    }

    /// The tokens once the code is approved, or `nil` while it's waiting.
    func pollDeviceSignIn(_ code: TraktDeviceCode, now: Date = Date()) async throws -> TraktTokens? {
        do {
            let response: TokenResponse = try await post("oauth/device/token", body: [
                "code": code.deviceCode,
                "client_id": clientID,
                "code_verifier": code.pkce.verifier
            ])
            return response.tokens(now: now)
        } catch let TraktAuthError.server(statusCode) {
            switch statusCode {
            // Waiting for approval, or polling too fast.
            case 400, 429: return nil
            case 404, 409, 410: throw TraktAuthError.expired
            case 418: throw TraktAuthError.denied
            default: throw TraktAuthError.server(statusCode: statusCode)
            }
        }
    }

    // MARK: Requests

    private func post<Response: Decodable>(_ path: String, body: [String: String]) async throws -> Response {
        try JSONDecoder().decode(Response.self, from: await send(path, body: body))
    }

    private func send(_ path: String, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: Self.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue(WikidataClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw TraktAuthError.server(statusCode: status)
        }
        return data
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: TimeInterval
        let createdAt: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case createdAt = "created_at"
        }

        func tokens(now: Date) -> TraktTokens {
            let issued = createdAt.map(Date.init(timeIntervalSince1970:)) ?? now
            return TraktTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: issued.addingTimeInterval(expiresIn)
            )
        }
    }

    private struct DeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURL: String
        let expiresIn: TimeInterval
        let interval: TimeInterval

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURL = "verification_url"
            case expiresIn = "expires_in"
            case interval
        }
    }
}

private nonisolated extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
