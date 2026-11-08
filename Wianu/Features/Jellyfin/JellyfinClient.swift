import Foundation

nonisolated enum JellyfinError: LocalizedError, Equatable {
    case invalidServerAddress
    case notSignedIn
    case invalidCredentials
    case unauthorized
    case invalidResponse
    case noPlayableSource
    case server(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            "Enter a server address such as http://192.168.1.20:8096."
        case .notSignedIn:
            "Sign in to Jellyfin in Settings."
        case .invalidCredentials:
            "The username or password is incorrect."
        case .unauthorized:
            "Jellyfin signed this device out. Sign in again in Settings."
        case .invalidResponse:
            "The Jellyfin server returned a response Wianu could not read."
        case .noPlayableSource:
            "Jellyfin could not find a way to stream this item to Wianu."
        case let .server(statusCode):
            "The Jellyfin server could not complete the request (\(statusCode))."
        }
    }
}

nonisolated protocol JellyfinHTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: JellyfinHTTPSession {}

/// A small client for the parts of the Jellyfin 10.9+ API that Wianu uses.
nonisolated struct JellyfinClient: Sendable {
    static let clientName = "Wianu"

    let serverURL: URL
    let deviceID: String
    let deviceName: String
    let clientVersion: String
    let accessToken: String?
    private let session: any JellyfinHTTPSession

    init(
        serverURL: URL,
        deviceID: String,
        deviceName: String = "Mac",
        clientVersion: String = "1.0",
        accessToken: String? = nil,
        session: any JellyfinHTTPSession = URLSession.shared
    ) {
        self.serverURL = serverURL
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.clientVersion = clientVersion
        self.accessToken = accessToken
        self.session = session
    }

    func authenticated(with token: String) -> JellyfinClient {
        JellyfinClient(
            serverURL: serverURL,
            deviceID: deviceID,
            deviceName: deviceName,
            clientVersion: clientVersion,
            accessToken: token,
            session: session
        )
    }

    // MARK: Server address

    /// Turns what people paste into a server base URL: adds `http://` when the
    /// scheme is missing and drops the web client's `/web/#/...` suffix.
    static func serverURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.contains("://") {
            text = "http://" + text
        }

        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        components.scheme = scheme
        components.query = nil
        components.fragment = nil

        var path = components.path
        if let webRange = path.range(of: "/web", options: [.backwards, .caseInsensitive]),
           path[webRange.upperBound...].allSatisfy({ $0 == "/" })
        {
            path = String(path[..<webRange.lowerBound])
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path

        return components.url
    }

    // MARK: Authentication

    func publicSystemInfo() async throws -> JellyfinPublicSystemInfo {
        try await send(path: "System/Info/Public")
    }

    func authenticate(username: String, password: String) async throws -> JellyfinAuthenticationResult {
        struct Body: Encodable {
            let username: String
            let password: String

            enum CodingKeys: String, CodingKey {
                case username = "Username"
                case password = "Pw"
            }
        }

        do {
            return try await send(
                path: "Users/AuthenticateByName",
                method: "POST",
                body: Body(username: username, password: password)
            )
        } catch JellyfinError.unauthorized {
            throw JellyfinError.invalidCredentials
        }
    }

    func signOut() async throws {
        try await sendWithoutResponse(path: "Sessions/Logout", method: "POST")
    }

    // MARK: Browsing

    func libraries(userID: String) async throws -> [JellyfinItem] {
        let response: JellyfinItemsResponse = try await send(
            path: "UserViews",
            query: [URLQueryItem(name: "userId", value: userID)]
        )
        return response.items
    }

    func items(
        userID: String,
        parentID: String,
        collectionType: String?,
        startIndex: Int = 0,
        limit: Int = 100
    ) async throws -> JellyfinItemPage {
        let response: JellyfinItemsResponse = try await send(
            path: "Items",
            query: [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "parentId", value: parentID),
                URLQueryItem(name: "recursive", value: "true"),
                URLQueryItem(
                    name: "includeItemTypes",
                    value: Self.itemTypes(forCollectionType: collectionType)
                ),
                URLQueryItem(name: "sortBy", value: "SortName"),
                URLQueryItem(name: "sortOrder", value: "Ascending"),
                URLQueryItem(name: "startIndex", value: String(startIndex)),
                URLQueryItem(name: "limit", value: String(limit))
            ] + Self.listFields
        )

        return JellyfinItemPage(
            items: response.items,
            totalCount: response.totalRecordCount ?? response.items.count
        )
    }

    func resumeItems(userID: String, limit: Int = 24) async throws -> [JellyfinItem] {
        let response: JellyfinItemsResponse = try await send(
            path: "UserItems/Resume",
            query: [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "mediaTypes", value: "Video"),
                URLQueryItem(name: "limit", value: String(limit))
            ] + Self.listFields
        )
        return response.items
    }

    func nextUp(userID: String, limit: Int = 24) async throws -> [JellyfinItem] {
        let response: JellyfinItemsResponse = try await send(
            path: "Shows/NextUp",
            query: [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "limit", value: String(limit)),
                // In-progress episodes already appear under Continue Watching.
                URLQueryItem(name: "enableResumable", value: "false")
            ] + Self.listFields
        )
        return response.items
    }

    /// Movies and shows in the library whose names match `term`.
    func search(term: String, userID: String, limit: Int = 20) async throws -> [JellyfinItem] {
        let response: JellyfinItemsResponse = try await send(
            path: "Items",
            query: [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "searchTerm", value: term),
                URLQueryItem(name: "recursive", value: "true"),
                URLQueryItem(name: "includeItemTypes", value: "Movie,Series"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "fields", value: "Overview,ProviderIds"),
                URLQueryItem(name: "enableUserData", value: "true"),
                URLQueryItem(name: "imageTypeLimit", value: "1"),
                URLQueryItem(name: "enableImageTypes", value: "Primary,Backdrop,Thumb")
            ]
        )
        return response.items
    }

    func seasons(seriesID: String, userID: String) async throws -> [JellyfinItem] {
        let response: JellyfinItemsResponse = try await send(
            path: "Shows/\(seriesID)/Seasons",
            query: [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "enableUserData", value: "true")
            ]
        )
        return response.items
    }

    func episodes(seriesID: String, seasonID: String, userID: String) async throws -> [JellyfinItem] {
        let response: JellyfinItemsResponse = try await send(
            path: "Shows/\(seriesID)/Episodes",
            query: [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "seasonId", value: seasonID)
            ] + Self.listFields
        )
        return response.items
    }

    /// Image endpoints are public on Jellyfin, so no token is added.
    func imageURL(for item: JellyfinItem, maxWidth: Int) -> URL? {
        let imageItemID: String
        let tag: String

        if let primary = item.imageTags?["Primary"] {
            imageItemID = item.id
            tag = primary
        } else if let seriesID = item.seriesID, let seriesTag = item.seriesPrimaryImageTag {
            imageItemID = seriesID
            tag = seriesTag
        } else {
            return nil
        }

        return url(
            path: "Items/\(imageItemID)/Images/Primary",
            query: [
                URLQueryItem(name: "fillWidth", value: String(maxWidth)),
                URLQueryItem(name: "quality", value: "90"),
                URLQueryItem(name: "tag", value: tag)
            ]
        )
    }

    /// A 16:9 image: the episode still, or a movie's thumb or backdrop, falling
    /// back to the poster.
    func landscapeImageURL(for item: JellyfinItem, maxWidth: Int) -> URL? {
        let query = [
            URLQueryItem(name: "fillWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "90")
        ]

        if item.kind != .episode {
            if let thumb = item.imageTags?["Thumb"] {
                return url(
                    path: "Items/\(item.id)/Images/Thumb",
                    query: query + [URLQueryItem(name: "tag", value: thumb)]
                )
            }
            if let backdrop = item.backdropImageTags?.first {
                return url(
                    path: "Items/\(item.id)/Images/Backdrop/0",
                    query: query + [URLQueryItem(name: "tag", value: backdrop)]
                )
            }
        }

        return imageURL(for: item, maxWidth: maxWidth)
    }

    // MARK: Requests

    /// `MediaBrowser Client="Wianu", Device="Mac", DeviceId="…", Version="…", Token="…"`
    var authorizationHeader: String {
        var parts = [
            ("Client", Self.clientName),
            ("Device", deviceName),
            ("DeviceId", deviceID),
            ("Version", clientVersion)
        ]
        if let accessToken {
            parts.append(("Token", accessToken))
        }

        let fields = parts.map { key, value in
            "\(key)=\"\(Self.headerValue(value))\""
        }
        return "MediaBrowser " + fields.joined(separator: ", ")
    }

    func url(path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(
            url: serverURL.appending(path: path),
            resolvingAgainstBaseURL: false
        ) else { return nil }

        if !query.isEmpty {
            components.queryItems = query
        }
        return components.url
    }

    private func request(
        path: String,
        method: String,
        query: [URLQueryItem],
        body: (some Encodable)?
    ) throws -> URLRequest {
        guard let url = url(path: path, query: query) else {
            throw JellyfinError.invalidServerAddress
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        return request
    }

    private func send<Response: Decodable>(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = []
    ) async throws -> Response {
        try await send(path: path, method: method, query: query, body: Optional<Data>.none)
    }

    private func send<Response: Decodable>(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: (some Encodable)?
    ) async throws -> Response {
        let data = try await perform(request(path: path, method: method, query: query, body: body))

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw JellyfinError.invalidResponse
        }
    }

    private func sendWithoutResponse(path: String, method: String) async throws {
        _ = try await perform(request(path: path, method: method, query: [], body: Optional<Data>.none))
    }

    private func sendWithoutResponse(path: String, method: String, body: some Encodable) async throws {
        _ = try await perform(request(path: path, method: method, query: [], body: body))
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.invalidResponse
        }

        switch http.statusCode {
        case 200 ..< 300:
            return data
        case 401, 403:
            throw JellyfinError.unauthorized
        default:
            throw JellyfinError.server(statusCode: http.statusCode)
        }
    }


}

// MARK: - Playback

extension JellyfinClient {
    func playbackSource(
        itemID: String,
        userID: String,
        profile: JellyfinDeviceProfile = .avPlayer
    ) async throws -> JellyfinPlaybackSource {
        let response: JellyfinPlaybackInfoResponse = try await send(
            path: "Items/\(itemID)/PlaybackInfo",
            method: "POST",
            query: [URLQueryItem(name: "userId", value: userID)],
            body: JellyfinPlaybackInfoRequest(
                userID: userID,
                maxStreamingBitrate: profile.maxStreamingBitrate,
                deviceProfile: profile
            )
        )

        guard response.errorCode == nil,
              let source = response.mediaSources.first
        else { throw JellyfinError.noPlayableSource }

        return try playbackSource(
            itemID: itemID,
            mediaSource: source,
            playSessionID: response.playSessionID
        )
    }

    func playbackSource(
        itemID: String,
        mediaSource source: JellyfinMediaSource,
        playSessionID: String?
    ) throws -> JellyfinPlaybackSource {
        guard let accessToken else { throw JellyfinError.notSignedIn }

        if source.supportsDirectPlay == true {
            var query = [
                URLQueryItem(name: "static", value: "true"),
                URLQueryItem(name: "mediaSourceId", value: source.id),
                URLQueryItem(name: "deviceId", value: deviceID),
                URLQueryItem(name: "ApiKey", value: accessToken)
            ]
            if let playSessionID {
                query.append(URLQueryItem(name: "playSessionId", value: playSessionID))
            }

            guard let url = url(path: "Videos/\(itemID)/stream", query: query) else {
                throw JellyfinError.invalidResponse
            }

            return JellyfinPlaybackSource(
                url: url,
                mediaSourceID: source.id,
                playSessionID: playSessionID,
                playMethod: .directPlay
            )
        }

        // The server builds this URL, including the API key.
        guard let transcodingPath = source.transcodingURL,
              let url = URL(string: Self.join(serverURL, transcodingPath))
        else { throw JellyfinError.noPlayableSource }

        return JellyfinPlaybackSource(
            url: url,
            mediaSourceID: source.id,
            playSessionID: playSessionID,
            playMethod: .transcode
        )
    }

    func reportPlaybackStarted(_ report: JellyfinPlaybackReport) async throws {
        try await sendWithoutResponse(path: "Sessions/Playing", method: "POST", body: report)
    }

    func reportPlaybackProgress(_ report: JellyfinPlaybackReport) async throws {
        try await sendWithoutResponse(path: "Sessions/Playing/Progress", method: "POST", body: report)
    }

    func reportPlaybackStopped(_ report: JellyfinPlaybackReport) async throws {
        try await sendWithoutResponse(path: "Sessions/Playing/Stopped", method: "POST", body: report)
    }
}

// MARK: - Helpers

extension JellyfinClient {
    private static let listFields = [
        URLQueryItem(name: "fields", value: "Overview,PrimaryImageAspectRatio"),
        URLQueryItem(name: "enableUserData", value: "true"),
        URLQueryItem(name: "imageTypeLimit", value: "1"),
        URLQueryItem(name: "enableImageTypes", value: "Primary,Backdrop,Thumb")
    ]

    static func itemTypes(forCollectionType collectionType: String?) -> String {
        switch collectionType {
        case "movies": "Movie"
        case "tvshows": "Series"
        case "boxsets": "BoxSet"
        case "musicvideos": "MusicVideo"
        default: "Movie,Series,Video"
        }
    }

    /// Jellyfin URL-decodes header values, so encode anything that could break
    /// the quoted format.
    private static func headerValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~ ()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func join(_ base: URL, _ path: String) -> String {
        var baseString = base.absoluteString
        while baseString.hasSuffix("/") {
            baseString.removeLast()
        }
        return baseString + (path.hasPrefix("/") ? path : "/" + path)
    }
}
