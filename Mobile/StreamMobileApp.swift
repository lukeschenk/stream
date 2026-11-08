import AVFoundation
import SwiftUI

/// iPhone, iPad and Apple TV app: Jellyfin playback, the iCloud watchlist,
/// and where to watch on your streaming services.
@main
struct StreamMobileApp: App {
    @State private var profiles = MobileProfileController()

    init() {
        // Play sound even with the iPhone's silent switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView(profiles: profiles)
        }
    }
}

/// Owns the active profile and the model built for it.
@MainActor
@Observable
final class MobileProfileController {
    private(set) var current: AppProfile
    private(set) var model: MobileModel

    @ObservationIgnored
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let profile = userDefaults
            .string(forKey: AppProfile.activeProfileKey)
            .flatMap(AppProfile.init(rawValue:)) ?? .main
        current = profile
        model = MobileModel(profile: profile)
    }

    func switchTo(_ profile: AppProfile) {
        guard profile != current else { return }

        current = profile
        model = MobileModel(profile: profile)
        userDefaults.set(profile.rawValue, forKey: AppProfile.activeProfileKey)
    }
}

/// Everything one profile sees on iPhone, iPad and Apple TV. Uses the same
/// stores and file layout as the Mac app.
@MainActor
@Observable
final class MobileModel {
    let profile: AppProfile
    /// The streaming services this profile has, kept as sites so they match
    /// the Mac app's data.
    let services: SiteStore
    let watchlist: WatchlistStore
    let jellyfin: JellyfinConnection
    let tmdbClient: TMDBClient
    let search: TMDBSearchModel
    let availability: ServiceAvailabilityModel
    private(set) var watchlistSync: WatchlistCloudSync?

    @ObservationIgnored
    private let userDefaults: UserDefaults

    init(profile: AppProfile, userDefaults: UserDefaults = .standard) {
        self.profile = profile
        self.userDefaults = userDefaults
        let folder = profile.storageFolderName
        services = SiteStore(fileStore: JSONFileStore(fileName: "sites.json", folderName: folder))
        watchlist = WatchlistStore(
            fileStore: JSONFileStore(fileName: "letterboxd-watchlist.json", folderName: folder)
        )
        jellyfin = JellyfinConnection(profile: profile, userDefaults: userDefaults)
        let client = TMDBClient()
        tmdbClient = client
        search = TMDBSearchModel(client: client, userDefaults: userDefaults)
        availability = ServiceAvailabilityModel(client: client)

        if isICloudSyncPreferred {
            watchlistSync = WatchlistCloudSync(store: watchlist, profile: profile)
        }
    }

    // MARK: Services

    var hasServices: Bool {
        MyServices.hasLinkedServices(services.sites)
    }

    func hasService(_ service: StreamingService) -> Bool {
        guard let host = service.host else { return false }
        return services.sites.contains { $0.url?.host()?.lowercased() == host }
    }

    func setService(_ option: ServiceOption, enabled: Bool) {
        if enabled {
            guard !hasService(option.service) else { return }
            services.addSite(option.siteDraft())
        } else {
            for site in services.sites where site.url?.host()?.lowercased() == option.service.host {
                services.deleteSite(id: site.id)
            }
        }
    }

    /// Your saved services that stream a title, or `nil` while unknown.
    func myServices(streaming media: TMDBMediaResult) -> [SavedSite]? {
        availability
            .streamingProviders(for: media, region: search.selectedRegion)
            .map { MyServices.sites(streaming: $0, from: services.sites) }
    }

    // MARK: Watchlist

    func watchlistItem(for media: TMDBMediaResult) -> WatchlistItem? {
        watchlist.items.first {
            $0.tmdbID == media.id && ($0.tmdbMediaType ?? .movie) == media.mediaType
        }
    }

    func toggleWatchlist(_ media: TMDBMediaResult) {
        if let item = watchlistItem(for: media) {
            watchlist.remove(id: item.id)
        } else {
            let item = watchlist.add(title: media.title, year: media.year.flatMap(Int.init), url: nil)
            watchlist.associate(id: item.id, with: media)
        }
    }

    // MARK: iCloud

    private var iCloudSyncKey: String {
        profile.defaultsKey(WatchlistCloudSync.preferenceKey)
    }

    private var isICloudSyncPreferred: Bool {
        userDefaults.object(forKey: iCloudSyncKey) as? Bool ?? true
    }

    var canSyncWithICloud: Bool {
        WatchlistCloudSync.containerIdentifier != nil
    }

    var isSyncingWithICloud: Bool {
        watchlistSync != nil
    }

    func setICloudSyncEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: iCloudSyncKey)

        if enabled, watchlistSync == nil {
            watchlistSync = WatchlistCloudSync(store: watchlist, profile: profile)
        } else if !enabled {
            watchlistSync?.stop()
            watchlistSync = nil
        }
    }
}
