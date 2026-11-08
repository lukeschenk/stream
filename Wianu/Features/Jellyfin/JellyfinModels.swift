import Foundation

/// A signed-in Jellyfin account. The access token is kept in the Keychain,
/// not here.
nonisolated struct JellyfinAccount: Codable, Hashable, Sendable {
    var serverURL: URL
    var serverName: String?
    var userID: String
    var userName: String
}

nonisolated enum JellyfinItemKind: Hashable, Sendable {
    case movie
    case series
    case season
    case episode
    case video
    case folder
    case other(String)

    init(rawValue: String?) {
        switch rawValue {
        case "Movie": self = .movie
        case "Series": self = .series
        case "Season": self = .season
        case "Episode": self = .episode
        case "Video", "MusicVideo", "Trailer": self = .video
        case "Folder", "CollectionFolder", "BoxSet", "UserView": self = .folder
        default: self = .other(rawValue ?? "")
        }
    }
}

nonisolated struct JellyfinUserData: Codable, Hashable, Sendable {
    var playbackPositionTicks: Int?
    var played: Bool?
    var playedPercentage: Double?
    var unplayedItemCount: Int?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case played = "Played"
        case playedPercentage = "PlayedPercentage"
        case unplayedItemCount = "UnplayedItemCount"
    }
}

/// The subset of Jellyfin's `BaseItemDto` that Wianu uses.
nonisolated struct JellyfinItem: Identifiable, Codable, Hashable, Sendable {
    static let ticksPerSecond = 10_000_000.0

    let id: String
    let name: String?
    let type: String?
    let collectionType: String?
    let seriesName: String?
    let seriesID: String?
    let seasonID: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let productionYear: Int?
    let runTimeTicks: Int?
    let overview: String?
    let imageTags: [String: String]?
    let seriesPrimaryImageTag: String?
    let backdropImageTags: [String]?
    let userData: JellyfinUserData?
    /// External IDs such as `"Tmdb": "603"`.
    let providerIDs: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case collectionType = "CollectionType"
        case seriesName = "SeriesName"
        case seriesID = "SeriesId"
        case seasonID = "SeasonId"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case productionYear = "ProductionYear"
        case runTimeTicks = "RunTimeTicks"
        case overview = "Overview"
        case imageTags = "ImageTags"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case backdropImageTags = "BackdropImageTags"
        case userData = "UserData"
        case providerIDs = "ProviderIds"
    }

    init(
        id: String,
        name: String?,
        type: String?,
        collectionType: String? = nil,
        seriesName: String? = nil,
        seriesID: String? = nil,
        seasonID: String? = nil,
        indexNumber: Int? = nil,
        parentIndexNumber: Int? = nil,
        productionYear: Int? = nil,
        runTimeTicks: Int? = nil,
        overview: String? = nil,
        imageTags: [String: String]? = nil,
        seriesPrimaryImageTag: String? = nil,
        backdropImageTags: [String]? = nil,
        userData: JellyfinUserData? = nil,
        providerIDs: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.collectionType = collectionType
        self.seriesName = seriesName
        self.seriesID = seriesID
        self.seasonID = seasonID
        self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.productionYear = productionYear
        self.runTimeTicks = runTimeTicks
        self.overview = overview
        self.imageTags = imageTags
        self.seriesPrimaryImageTag = seriesPrimaryImageTag
        self.backdropImageTags = backdropImageTags
        self.userData = userData
        self.providerIDs = providerIDs
    }

    var kind: JellyfinItemKind {
        JellyfinItemKind(rawValue: type)
    }

    var isPlayable: Bool {
        switch kind {
        case .movie, .episode, .video: true
        default: false
        }
    }

    var displayTitle: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// "S2 · E5" for episodes, the release year otherwise.
    var episodeLabel: String? {
        guard kind == .episode else { return nil }

        switch (parentIndexNumber, indexNumber) {
        case let (season?, episode?): return "S\(season) · E\(episode)"
        case let (nil, episode?): return "E\(episode)"
        default: return nil
        }
    }

    var subtitle: String? {
        if kind == .episode {
            return [seriesName, episodeLabel]
                .compactMap { $0 }
                .joined(separator: " — ")
                .nilIfEmpty
        }

        return productionYear.map(String.init)
    }

    var resumePositionSeconds: Double {
        Double(userData?.playbackPositionTicks ?? 0) / Self.ticksPerSecond
    }

    /// Watched fraction from 0 to 1, or `nil` when nothing has been watched.
    var progress: Double? {
        guard let position = userData?.playbackPositionTicks, position > 0,
              let runTime = runTimeTicks, runTime > 0
        else { return nil }

        return min(max(Double(position) / Double(runTime), 0), 1)
    }

    var isPlayed: Bool {
        userData?.played ?? false
    }

    /// Libraries Wianu can show. Music, books and photos are left to other
    /// apps.
    var isVideoLibrary: Bool {
        switch collectionType {
        case nil, "movies", "tvshows", "homevideos", "mixed", "boxsets", "musicvideos":
            true
        default:
            false
        }
    }

    var librarySystemImage: String {
        switch collectionType {
        case "movies": "film"
        case "tvshows": "tv"
        case "homevideos": "video"
        case "boxsets": "square.stack"
        case "musicvideos": "music.note.tv"
        default: "folder"
        }
    }
}

// MARK: - Matching TMDB titles to the library

nonisolated enum JellyfinLibraryMatch {
    /// The library item for a TMDB title: by TMDB ID when Jellyfin has one,
    /// otherwise by exact title and year.
    static func item(for media: TMDBMediaResult, in candidates: [JellyfinItem]) -> JellyfinItem? {
        let kind: JellyfinItemKind = media.mediaType == .movie ? .movie : .series
        let sameKind = candidates.filter { $0.kind == kind }

        if let byID = sameKind.first(where: { $0.providerIDs?["Tmdb"] == String(media.id) }) {
            return byID
        }

        let title = normalized(media.title)
        let year = media.year.flatMap(Int.init)
        return sameKind.first { item in
            normalized(item.displayTitle) == title
                && (year == nil || item.productionYear == nil || item.productionYear == year)
        }
    }

    private static func normalized(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}

nonisolated struct JellyfinItemsResponse: Codable, Sendable {
    let items: [JellyfinItem]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

nonisolated struct JellyfinItemPage: Sendable {
    let items: [JellyfinItem]
    let totalCount: Int
}

nonisolated struct JellyfinPublicSystemInfo: Decodable, Sendable {
    let serverName: String?
    let version: String?
    let id: String?

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
        case id = "Id"
    }
}

nonisolated struct JellyfinAuthenticationResult: Decodable, Sendable {
    struct User: Decodable, Sendable {
        let id: String
        let name: String?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
        }
    }

    let user: User
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
    }
}

// MARK: - Playback

nonisolated enum JellyfinPlayMethod: String, Codable, Sendable {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"
}

/// Where to stream an item from, decided by the server from Wianu's device
/// profile.
nonisolated struct JellyfinPlaybackSource: Hashable, Sendable {
    let url: URL
    let mediaSourceID: String
    let playSessionID: String?
    let playMethod: JellyfinPlayMethod
}

nonisolated struct JellyfinMediaSource: Decodable, Sendable {
    let id: String
    let container: String?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    let transcodingURL: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case container = "Container"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case transcodingURL = "TranscodingUrl"
    }
}

nonisolated struct JellyfinPlaybackInfoResponse: Decodable, Sendable {
    let mediaSources: [JellyfinMediaSource]
    let playSessionID: String?
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionID = "PlaySessionId"
        case errorCode = "ErrorCode"
    }
}

nonisolated struct JellyfinPlaybackInfoRequest: Encodable, Sendable {
    let userID: String
    let maxStreamingBitrate: Int
    let deviceProfile: JellyfinDeviceProfile
    let enableDirectPlay = true
    let enableDirectStream = true
    let enableTranscoding = true
    let allowVideoStreamCopy = true
    let allowAudioStreamCopy = true
    let autoOpenLiveStream = true

    enum CodingKeys: String, CodingKey {
        case userID = "UserId"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case deviceProfile = "DeviceProfile"
        case enableDirectPlay = "EnableDirectPlay"
        case enableDirectStream = "EnableDirectStream"
        case enableTranscoding = "EnableTranscoding"
        case allowVideoStreamCopy = "AllowVideoStreamCopy"
        case allowAudioStreamCopy = "AllowAudioStreamCopy"
        case autoOpenLiveStream = "AutoOpenLiveStream"
    }
}

/// Body for the `/Sessions/Playing*` endpoints, which keep Jellyfin's resume
/// position and watched state in sync.
nonisolated struct JellyfinPlaybackReport: Encodable, Sendable {
    let itemID: String
    let mediaSourceID: String
    let playSessionID: String?
    let positionTicks: Int
    var isPaused: Bool?
    var canSeek: Bool?
    var playMethod: JellyfinPlayMethod?

    enum CodingKeys: String, CodingKey {
        case itemID = "ItemId"
        case mediaSourceID = "MediaSourceId"
        case playSessionID = "PlaySessionId"
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case canSeek = "CanSeek"
        case playMethod = "PlayMethod"
    }

    static func ticks(fromSeconds seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds * JellyfinItem.ticksPerSecond)
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
