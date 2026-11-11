import Foundation
import Observation

/// When a show's episodes come out, from Trakt.
nonisolated struct ShowSchedule: Codable, Equatable, Sendable {
    struct Episode: Codable, Equatable, Sendable {
        let season: Int
        let number: Int
        let title: String?
        let airsAt: Date

        /// "S2 · E3"
        var label: String {
            "S\(season) · E\(number)"
        }
    }

    /// Trakt's status: "returning series", "ended", "canceled", "in production"…
    var status: String?
    var airsDay: String?
    /// "21:00" in `airsTimeZone`.
    var airsTime: String?
    var airsTimeZone: String?
    var network: String?
    var nextEpisode: Episode?
    var lastEpisode: Episode?

    var hasEnded: Bool {
        status == "ended" || status == "canceled"
    }

    /// The show's regular weekly time, moved into `timeZone`.
    func weeklyAiring(
        after date: Date = Date(),
        in timeZone: TimeZone = .current
    ) -> Date? {
        guard !hasEnded,
              let airsDay,
              let airsTime,
              let showTimeZone = airsTimeZone.flatMap(TimeZone.init(identifier:)),
              let weekday = Self.weekdays.firstIndex(of: airsDay.lowercased())
        else { return nil }

        let parts = airsTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = showTimeZone
        return calendar.nextDate(
            after: date,
            matching: DateComponents(hour: parts[0], minute: parts[1], weekday: weekday + 1),
            matchingPolicy: .nextTime
        )
    }

    /// Once the latest episode has had time to reach the services, title
    /// links saved before then are out of date.
    func linksStaleBefore(now: Date = Date()) -> Date? {
        guard let aired = lastEpisode?.airsAt else { return nil }
        let settled = aired.addingTimeInterval(6 * 3600)
        return settled <= now ? settled : nil
    }

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    // MARK: Describing

    /// "Next episode S2 · E3 · Tue, Nov 10, 9:00 PM", "New episodes Tuesdays
    /// at 9:00 PM" or "Ended".
    func summary(now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        if let next = nextEpisode, next.airsAt > now {
            return "Next episode \(next.label) · \(Self.format(next.airsAt, timeZone: timeZone))"
        }
        if hasEnded {
            return "This show has ended"
        }
        if let weekly = weeklyAiring(after: now, in: timeZone) {
            var style = Date.FormatStyle(date: .omitted, time: .shortened)
            style.timeZone = timeZone
            let day = weekly.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide))
            return "New episodes \(day)s at \(weekly.formatted(style))"
        }
        return nil
    }

    /// "New episode Tue" when one comes out within the week.
    func shortSummary(now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        guard let next = nextEpisode, next.airsAt > now,
              next.airsAt.timeIntervalSince(now) < 7 * 86400
        else { return nil }
        let day = next.airsAt.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated))
        return "New episode \(day)"
    }

    private static func format(_ date: Date, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(timeZone: timeZone)
            .weekday(.abbreviated)
            .month(.abbreviated)
            .day()
            .hour()
            .minute()
        style.timeZone = timeZone
        return date.formatted(style)
    }
}

nonisolated enum TraktError: Error, Equatable {
    case notConfigured
    case server(statusCode: Int)
}

/// Public show data from Trakt, which needs only the app's Client ID.
nonisolated struct TraktClient: Sendable {
    static let baseURL = URL(string: "https://api.trakt.tv")!

    /// From the build's `TRAKT_CLIENT_ID` setting in `Config/Secrets.xcconfig`.
    static var configuredClientID: String? {
        let id = (Bundle.main.object(forInfoDictionaryKey: "TraktClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id, !id.isEmpty, !id.hasPrefix("$(") else { return nil }
        return id
    }

    static var configured: TraktClient? {
        configuredClientID.map { TraktClient(clientID: $0) }
    }

    let clientID: String
    private let session: any TMDBSession

    init(clientID: String, session: any TMDBSession = URLSession.shared) {
        self.clientID = clientID
        self.session = session
    }

    /// The schedule for a show by its TMDB ID, or `nil` if Trakt doesn't
    /// know it.
    func schedule(forTMDBShow tmdbID: Int) async throws -> ShowSchedule? {
        let matches: [SearchResult] = try await get("search/tmdb/\(tmdbID)", query: ["type": "show"]) ?? []
        guard let traktID = matches.first?.show?.ids.trakt else { return nil }

        async let summary: Show? = get("shows/\(traktID)", query: ["extended": "full"])
        async let next: EpisodeResponse? = get("shows/\(traktID)/next_episode", query: ["extended": "full"])
        async let last: EpisodeResponse? = get("shows/\(traktID)/last_episode", query: ["extended": "full"])

        let show = try await summary
        return try await ShowSchedule(
            status: show?.status,
            airsDay: show?.airs?.day,
            airsTime: show?.airs?.time,
            airsTimeZone: show?.airs?.timezone,
            network: show?.network,
            nextEpisode: next?.episode,
            lastEpisode: last?.episode
        )
    }

    /// `nil` for Trakt's "204 No Content", which means there's nothing to show.
    private func get<Response: Decodable>(_ path: String, query: [String: String]) async throws -> Response? {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue(WikidataClient.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TraktError.server(statusCode: 0)
        }

        switch http.statusCode {
        case 204, 404:
            return nil
        case 200 ..< 300:
            return try JSONDecoder().decode(Response.self, from: data)
        default:
            throw TraktError.server(statusCode: http.statusCode)
        }
    }

    // MARK: Responses

    private struct SearchResult: Decodable {
        struct Show: Decodable {
            struct IDs: Decodable {
                let trakt: Int
            }

            let ids: IDs
        }

        let show: Show?
    }

    private struct Show: Decodable {
        struct Airs: Decodable {
            let day: String?
            let time: String?
            let timezone: String?
        }

        let status: String?
        let network: String?
        let airs: Airs?
    }

    private struct EpisodeResponse: Decodable {
        let season: Int
        let number: Int
        let title: String?
        let firstAired: String?

        enum CodingKeys: String, CodingKey {
            case season, number, title
            case firstAired = "first_aired"
        }

        var episode: ShowSchedule.Episode? {
            guard let firstAired, let date = Self.date(from: firstAired) else { return nil }
            return ShowSchedule.Episode(season: season, number: number, title: title, airsAt: date)
        }

        static func date(from string: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }
    }
}

/// Show schedules for the session, saved on the device for half a day.
@MainActor
@Observable
final class ShowScheduleModel {
    private(set) var schedules: [Int: ShowSchedule] = [:]

    @ObservationIgnored
    private let client: TraktClient?
    @ObservationIgnored
    private let cache: ExpiringCache<ShowSchedule>?
    @ObservationIgnored
    private var loading = Set<Int>()

    init(client: TraktClient? = .configured, cache: ExpiringCache<ShowSchedule>?) {
        self.client = client
        self.cache = cache
    }

    convenience init() {
        self.init(cache: ExpiringCache(fileName: "show-schedules.json"))
    }

    var isAvailable: Bool {
        client != nil
    }

    func schedule(for media: TMDBMediaResult) -> ShowSchedule? {
        guard media.mediaType == .tv else { return nil }
        return schedules[media.id] ?? cache?.value(for: String(media.id))
    }

    func load(for media: TMDBMediaResult) async {
        guard media.mediaType == .tv, let client, schedules[media.id] == nil, !loading.contains(media.id) else {
            return
        }

        let key = String(media.id)
        if let cached = cache?.value(for: key), !Self.hasPassed(cached.nextEpisode) {
            schedules[media.id] = cached
            return
        }

        loading.insert(media.id)
        defer { loading.remove(media.id) }

        do {
            guard let schedule = try await client.schedule(forTMDBShow: media.id) else { return }
            schedules[media.id] = schedule
            cache?.store(schedule, for: key, lifetime: .halfDay)
        } catch {
            if let saved = cache?.fallback(for: key) {
                schedules[media.id] = saved
            }
        }
    }

    /// A saved schedule is out of date once its next episode has aired.
    private static func hasPassed(_ episode: ShowSchedule.Episode?) -> Bool {
        guard let episode else { return false }
        return episode.airsAt < Date()
    }
}
