import Foundation

/// Answers from web services kept in the Caches folder, which the system may
/// clear. Expired answers stay around a while as a fallback for when a fresh
/// lookup fails.
@MainActor
final class ExpiringCache<Value: Codable> {
    enum Lifetime: TimeInterval {
        case halfDay = 43200
        case oneDay = 86400
        case oneWeek = 604_800
        case oneMonth = 2_592_000
    }

    struct Entry: Codable {
        let value: Value
        let expiresAt: Date
        /// When the answer was fetched; missing in older caches.
        let storedAt: Date?
    }

    static var maximumEntries: Int {
        300
    }

    /// How long past expiry an answer is kept as a fallback.
    static var fallbackLifetime: TimeInterval {
        Lifetime.oneMonth.rawValue * 2
    }

    private let fileStore: JSONFileStore<[String: Entry]>
    private var entries: [String: Entry]
    private let now: () -> Date

    init(
        fileName: String = "cache.json",
        fileStore: JSONFileStore<[String: Entry]>? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        let store = fileStore ?? JSONFileStore(
            fileName: fileName,
            folderName: "Stream",
            baseDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
        self.fileStore = store
        self.now = now
        entries = (try? store.load(defaultValue: [:])) ?? [:]
    }

    /// A current answer, or `nil` if there is none or it has expired.
    func value(for key: String, storedAfter date: Date? = nil) -> Value? {
        guard let entry = entries[key], entry.expiresAt > now() else { return nil }
        if let date, (entry.storedAt ?? .distantPast) < date {
            return nil
        }
        return entry.value
    }

    /// Any saved answer, expired or not.
    func fallback(for key: String) -> Value? {
        entries[key]?.value
    }

    func store(_ value: Value, for key: String, lifetime: Lifetime) {
        let current = now()
        entries[key] = Entry(value: value, expiresAt: current.addingTimeInterval(lifetime.rawValue), storedAt: current)

        // Drop long-expired answers, then the soonest to expire, to stay small.
        entries = entries.filter { $0.value.expiresAt.addingTimeInterval(Self.fallbackLifetime) > current }
        if entries.count > Self.maximumEntries {
            let overflow = entries.count - Self.maximumEntries
            let oldest = entries.sorted { $0.value.expiresAt < $1.value.expiresAt }.prefix(overflow)
            for key in oldest.map(\.key) {
                entries[key] = nil
            }
        }

        try? fileStore.save(entries)
    }
}

typealias TitleLinksCache = ExpiringCache<TitleLinks>
