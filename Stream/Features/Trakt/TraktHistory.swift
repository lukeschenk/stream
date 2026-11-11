import Foundation

/// The latest episode watched of a show, from Trakt.
nonisolated struct TraktWatchedShow: Equatable, Sendable {
    let tmdbID: Int
    let title: String
    let year: Int?
    let season: Int
    let episode: Int
    let watchedAt: Date

    /// Enough of the show to find or add it on the watchlist.
    var media: TMDBMediaResult {
        TMDBMediaResult(
            id: tmdbID,
            mediaType: .tv,
            title: title,
            overview: "",
            posterPath: nil,
            releaseDate: year.map { "\($0)-01-01" }
        )
    }
}

nonisolated extension TraktClient {
    /// The signed-in user's name.
    func username(accessToken: String) async throws -> String? {
        let settings: UserSettings? = try await get("users/settings", query: [:], accessToken: accessToken)
        return settings?.user.username
    }

    /// Every show the user has watched, with its latest episode. Specials
    /// and shows without a TMDB ID are left out.
    func watchedShows(accessToken: String) async throws -> [TraktWatchedShow] {
        let shows: [WatchedShow] = try await get("sync/watched/shows", query: [:], accessToken: accessToken) ?? []
        return shows.compactMap(\.latest)
    }

    private struct UserSettings: Decodable {
        struct User: Decodable {
            let username: String
        }

        let user: User
    }

    private struct WatchedShow: Decodable {
        struct Show: Decodable {
            struct IDs: Decodable {
                let tmdb: Int?
            }

            let title: String
            let year: Int?
            let ids: IDs
        }

        struct Season: Decodable {
            struct Episode: Decodable {
                let number: Int
                let lastWatchedAt: String?

                enum CodingKeys: String, CodingKey {
                    case number
                    case lastWatchedAt = "last_watched_at"
                }
            }

            let number: Int
            let episodes: [Episode]
        }

        let show: Show
        let seasons: [Season]?

        var latest: TraktWatchedShow? {
            guard let tmdbID = show.ids.tmdb else { return nil }

            let watched = (seasons ?? [])
                .filter { $0.number > 0 }
                .flatMap { season in
                    season.episodes.compactMap { episode in
                        episode.lastWatchedAt
                            .flatMap(TraktDate.parse)
                            .map { (season: season.number, episode: episode.number, date: $0) }
                    }
                }
            // Latest by date, then by episode for ones marked watched together.
            guard let last = watched.max(by: { ($0.date, $0.season, $0.episode) < ($1.date, $1.season, $1.episode) })
            else { return nil }

            return TraktWatchedShow(
                tmdbID: tmdbID,
                title: show.title,
                year: show.year,
                season: last.season,
                episode: last.episode,
                watchedAt: last.date
            )
        }
    }
}

nonisolated enum TraktDate {
    static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

extension WatchlistStore {
    /// Brings "pick up" up to date with Trakt. Shows on the watchlist get the
    /// latest episode watched anywhere; other shows are added only if watched
    /// in the last `recentDays`, so years of history don't flood the list.
    /// Returns how many shows changed.
    @discardableResult
    func apply(_ history: [TraktWatchedShow], now: Date = Date(), recentDays: Int = 30) -> Int {
        let recentCutoff = now.addingTimeInterval(-Double(recentDays) * 86400)
        var changed = 0

        for show in history {
            let media = show.media
            let progress = item(for: media)?.progress
            if let progress, progress.updatedAt >= show.watchedAt {
                continue
            }
            if item(for: media) == nil, show.watchedAt < recentCutoff {
                continue
            }

            // Trakt doesn't send episode titles; keep the one already known.
            let sameEpisode = progress?.season == show.season && progress?.episode == show.episode
            recordEpisode(
                season: show.season,
                episode: show.episode,
                title: sameEpisode ? progress?.episodeTitle : nil,
                of: media,
                at: show.watchedAt
            )
            changed += 1
        }
        return changed
    }
}
