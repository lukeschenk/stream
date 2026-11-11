import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    struct NavigationRequest: Identifiable, Sendable {
        let id = UUID()
        let url: URL
    }

    let profile: AppProfile
    let siteStore: SiteStore
    let continueWatchingStore: ContinueWatchingStore
    let watchlistStore: WatchlistStore
    let mediaIdentification: MediaIdentificationCoordinator
    let jellyfin: JellyfinConnection
    let trakt: TraktConnection
    let serviceAvailability: ServiceAvailabilityModel
    let titleLinks = TitleLinksModel()
    let showSchedules = ShowScheduleModel()
    private(set) var watchlistSync: WatchlistCloudSync?
    private(set) var settingsSync: ProfileSettingsCloudSync?
    private(set) var tmdbClient: TMDBClient
    private(set) var tmdbSearch: TMDBSearchModel
    private(set) var isCommandPalettePresented = false

    private(set) var selection: SidebarSelection?
    private(set) var navigationRequest: NavigationRequest?
    @ObservationIgnored
    private let userDefaults: UserDefaults
    @ObservationIgnored
    private let analytics: any AnalyticsTracking

    private var lastSelectedSiteKey: String {
        profile.defaultsKey("lastSelectedSiteID")
    }

    var destinationURL: URL? {
        navigationRequest?.url
    }

    init(profile: AppProfile = .main) {
        self.profile = profile
        let folder = profile.storageFolderName
        siteStore = SiteStore(
            fileStore: JSONFileStore(fileName: "sites.json", folderName: folder)
        )
        continueWatchingStore = ContinueWatchingStore(
            fileStore: JSONFileStore(fileName: "continue-watching.json", folderName: folder)
        )
        watchlistStore = WatchlistStore(
            fileStore: JSONFileStore(fileName: "letterboxd-watchlist.json", folderName: folder)
        )
        jellyfin = JellyfinConnection(profile: profile)
        trakt = TraktConnection(profile: profile)
        userDefaults = .standard
        let analytics = AnalyticsClient(userDefaults: userDefaults)
        self.analytics = analytics
        let client = TMDBClient()
        mediaIdentification = MediaIdentificationCoordinator(
            watchlist: watchlistStore,
            continueWatching: continueWatchingStore,
            client: client
        )
        tmdbClient = client
        serviceAvailability = ServiceAvailabilityModel(client: client)
        tmdbSearch = TMDBSearchModel(
            client: client,
            userDefaults: userDefaults
        )
        restoreSelection()
        if userDefaults.object(forKey: profile.defaultsKey(WatchlistCloudSync.preferenceKey)) as? Bool ?? true {
            startICloudSync()
        }
        Task { await trakt.syncHistory(into: watchlistStore) }
        analytics.track(.appLaunched)
    }

    init(
        siteStore: SiteStore,
        continueWatchingStore: ContinueWatchingStore,
        watchlistStore: WatchlistStore,
        userDefaults: UserDefaults,
        tmdbClient: TMDBClient,
        analytics: (any AnalyticsTracking)? = nil,
        profile: AppProfile = .main,
        jellyfin: JellyfinConnection? = nil
    ) {
        self.profile = profile
        trakt = TraktConnection(
            profile: profile,
            userDefaults: userDefaults,
            tokenStorage: EphemeralTokenStorage(),
            clientID: nil
        )
        self.jellyfin = jellyfin ?? JellyfinConnection(
            profile: profile,
            userDefaults: userDefaults,
            tokenStorage: EphemeralTokenStorage()
        )
        self.siteStore = siteStore
        self.continueWatchingStore = continueWatchingStore
        self.watchlistStore = watchlistStore
        self.userDefaults = userDefaults
        let analytics = analytics ?? DisabledAnalyticsTracker()
        self.analytics = analytics
        mediaIdentification = MediaIdentificationCoordinator(
            watchlist: watchlistStore,
            continueWatching: continueWatchingStore,
            client: tmdbClient
        )
        self.tmdbClient = tmdbClient
        serviceAvailability = ServiceAvailabilityModel(client: tmdbClient)
        tmdbSearch = TMDBSearchModel(
            client: tmdbClient,
            userDefaults: userDefaults
        )
        restoreSelection()
        analytics.track(.appLaunched)
    }
}

extension AppModel {
    var selectedSite: SavedSite? {
        guard let selectedSiteID else { return nil }
        return siteStore.sites.first { $0.id == selectedSiteID }
    }

    var selectedContinueWatchingItem: ContinueWatchingItem? {
        guard case let .continueWatching(itemID) = selection else { return nil }
        return continueWatchingStore.item(id: itemID)
    }

    func destination(for selection: SidebarSelection?) -> URL? {
        switch selection {
        case let .site(siteID):
            siteStore.sites.first { $0.id == siteID }?.url
        case let .continueWatching(itemID):
            continueWatchingStore.item(id: itemID)?.url
        case let .watchlistItem(itemID):
            watchlistStore.item(id: itemID)?.url
        case .home, .jellyfin, nil:
            nil
        }
    }

    func search(_ query: String, in site: SavedSite) {
        guard let searchURL = site.searchURL(for: query) else { return }

        dismissCommandPalette()
        select(.site(site.id))
        navigate(to: searchURL)
    }

    func showCommandPalette(query: String? = nil) {
        tmdbSearch.clearSelection()
        if let query {
            tmdbSearch.query = query
        } else {
            tmdbSearch.query = ""
        }
        tmdbSearch.queryChanged()
        isCommandPalettePresented = true
        tmdbSearch.requestFocus()
        analytics.track(.searchOpened)
    }

    func settingsOpened() {
        analytics.track(.settingsOpened)
    }

    func updateCheckStarted() {
        analytics.track(.updateCheckStarted)
    }

    func addSite(_ draft: SiteDraft) {
        guard draft.validatedValues != nil else { return }
        siteStore.addSite(draft)
        analytics.track(.siteAdded)
    }

    func updateSite(_ site: SavedSite, with draft: SiteDraft) {
        guard draft.validatedValues != nil else { return }
        siteStore.updateSite(id: site.id, with: draft)
        analytics.track(.siteEdited)
    }

    func dismissCommandPalette() {
        isCommandPalettePresented = false
    }

    func openWeeklyPick(_ media: TMDBMediaResult) {
        analytics.track(.weeklyPickOpened)
        showCommandPalette(query: media.title)
        tmdbSearch.select(media)
    }

    func openProvider(_ provider: TMDBProvider, for media: TMDBMediaResult) {
        guard let site = site(for: provider) else { return }

        // Go straight to the title when its link is known.
        if let titleURL = titleLink(for: provider, media: media) {
            analytics.track(.providerSelected)
            dismissCommandPalette()
            select(.site(site.id))
            navigate(to: titleURL)
            return
        }

        guard site.isTMDBProviderActionable, site.searchURL(for: media.title) != nil else { return }
        analytics.track(.providerSelected)
        search(media.title, in: site)
    }

    /// A link that opens the title itself in the provider's site.
    func titleLink(for provider: TMDBProvider, media: TMDBMediaResult) -> URL? {
        guard let service = StreamingServiceCatalog.service(forProviderName: provider.name) else {
            return nil
        }

        return titleLinks
            .links(for: media, region: tmdbSearch.selectedRegion)?
            .url(for: service)
    }

    func site(for provider: TMDBProvider) -> SavedSite? {
        siteStore.sites.first {
            $0.tmdbProvider?.matches(provider) == true
        }
    }

    func select(_ newSelection: SidebarSelection?) {
        isCommandPalettePresented = false
        selection = newSelection
        navigate(to: destination(for: newSelection))

        switch newSelection {
        case .home:
            analytics.track(.homeOpened)
        case .site where navigationRequest != nil:
            analytics.track(.siteOpened)
        case .continueWatching where navigationRequest != nil:
            analytics.track(.continueWatchingOpened)
        default:
            break
        }

        if case let .continueWatching(itemID) = newSelection {
            continueWatchingStore.markOpened(id: itemID)
        }

        if let selectedSiteID {
            userDefaults.set(
                selectedSiteID.uuidString,
                forKey: lastSelectedSiteKey
            )
        }
    }

    func deleteSite(_ site: SavedSite) {
        if selectedSiteID == site.id {
            selection = nil
            navigate(to: nil)
        }

        continueWatchingStore.removeItems(forSiteID: site.id)
        siteStore.deleteSite(id: site.id)
        analytics.track(.siteDeleted)

        if userDefaults.string(forKey: lastSelectedSiteKey)
            == site.id.uuidString
        {
            userDefaults.removeObject(forKey: lastSelectedSiteKey)
        }
    }

    func removeContinueWatchingItem(_ item: ContinueWatchingItem) {
        if selection == .continueWatching(item.id) {
            if let siteID = item.siteID {
                select(.site(siteID))
            } else {
                select(nil)
            }
        }

        mediaIdentification.cancel(.continueWatching(item.id))
        continueWatchingStore.remove(id: item.id)
        analytics.track(.continueWatchingItemRemoved)
    }

    func replaceImportedWatchlistItems(
        with items: [WatchlistItem]
    ) {
        let selectedItemID: WatchlistItem.ID? =
            if case let .watchlistItem(itemID) = selection {
                itemID
            } else {
                nil
            }

        watchlistStore.replaceImportedItems(with: items)

        if let selectedItemID,
           watchlistStore.item(id: selectedItemID) == nil
        {
            selection = nil
            navigate(to: nil)
        }
    }

    func letterboxdImportSucceeded() {
        analytics.track(.letterboxdImportSucceeded)
    }

    func addWatchlistItem(title: String, year: Int?, url: URL?) {
        let item = watchlistStore.add(title: title, year: year, url: url)
        mediaIdentification.identifyInBackground(.watchlist(item.id))
        analytics.track(.watchlistItemAdded)
    }

    func updateWatchlistItem(
        _ item: WatchlistItem,
        title: String,
        year: Int?,
        url: URL?
    ) {
        watchlistStore.update(
            id: item.id,
            title: title,
            year: year,
            url: url
        )
        mediaIdentification.identifyInBackground(.watchlist(item.id))
    }

    func removeWatchlistItem(_ item: WatchlistItem) {
        if selection == .watchlistItem(item.id) {
            select(nil)
        }
        mediaIdentification.cancel(.watchlist(item.id))
        watchlistStore.remove(id: item.id)
        analytics.track(.watchlistItemRemoved)
    }

    func activateSite(matching url: URL?) {
        guard selection?.showsNativeContent != true,
              let url,
              let host = normalizedHost(for: url),
              let site = siteStore.sites.first(where: {
                  normalizedHost(for: $0.url) == host
              }),
              selection != .site(site.id)
        else { return }

        selection = .site(site.id)
        userDefaults.set(
            site.id.uuidString,
            forKey: lastSelectedSiteKey
        )
    }

    func toggleContinueWatching(title: String, url: URL) {
        if let item = continueWatchingStore.item(matching: url) {
            removeContinueWatchingItem(item)
        } else {
            let trimmedTitle = title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let savedTitle: String =
                if let site = selectedSite {
                    PageTitleCleaner.clean(
                        trimmedTitle,
                        siteName: site.name
                    )
                } else {
                    trimmedTitle.isEmpty
                        ? url.host() ?? "Untitled Page"
                        : trimmedTitle
                }

            let item = continueWatchingStore.save(
                siteID: selectedSite?.id,
                title: savedTitle,
                url: url
            )
            mediaIdentification.identifyInBackground(.continueWatching(item.id))
            analytics.track(.continueWatchingItemAdded)
        }
    }

    func toggleWatchlist(title: String, url: URL) {
        if let item = watchlistStore.item(matching: url) {
            removeWatchlistItem(item)
            return
        }

        let trimmedTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let savedTitle: String =
            if let site = selectedSite {
                PageTitleCleaner.clean(
                    trimmedTitle,
                    siteName: site.name
                )
            } else {
                trimmedTitle.isEmpty
                    ? url.host() ?? "Untitled Movie"
                    : trimmedTitle
            }

        let item = watchlistStore.add(
            title: savedTitle,
            year: nil,
            url: url
        )
        mediaIdentification.identifyInBackground(.watchlist(item.id))
        analytics.track(.watchlistItemAdded)
    }

    private var selectedSiteID: SavedSite.ID? {
        switch selection {
        case let .site(siteID):
            siteID
        case let .continueWatching(itemID):
            continueWatchingStore.item(id: itemID)?.siteID
        case .watchlistItem:
            nil
        case .home, .jellyfin, nil:
            nil
        }
    }

    private func restoreSelection() {
        let savedID =
            userDefaults
                .string(forKey: lastSelectedSiteKey)
                .flatMap(UUID.init(uuidString:))

        if let savedID, siteStore.sites.contains(where: { $0.id == savedID }) {
            selection = .site(savedID)
        } else if let firstSite = siteStore.sites.first {
            selection = .site(firstSite.id)
        }

        navigate(to: destination(for: selection))
    }

    func navigate(to url: URL?) {
        navigationRequest = url.map(NavigationRequest.init(url:))
    }

    private func normalizedHost(for url: URL?) -> String? {
        guard var host = url?.host()?.lowercased() else { return nil }

        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }

        return host
    }
}

// MARK: - iCloud and onboarding

extension AppModel {
    // MARK: iCloud

    /// Shares the watchlist, streaming services and Jellyfin server.
    private func startICloudSync() {
        watchlistSync = WatchlistCloudSync(store: watchlistStore, profile: profile)
        settingsSync = ProfileSettingsCloudSync(sites: siteStore, jellyfin: jellyfin, profile: profile)
    }

    /// Whether this build has the iCloud capability at all.
    var canSyncWithICloud: Bool {
        WatchlistCloudSync.containerIdentifier != nil
    }

    var isSyncingWithICloud: Bool {
        watchlistSync != nil
    }

    func setICloudSyncEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: profile.defaultsKey(WatchlistCloudSync.preferenceKey))

        if enabled, watchlistSync == nil {
            startICloudSync()
        } else if !enabled {
            watchlistSync?.stop()
            watchlistSync = nil
            settingsSync?.stop()
            settingsSync = nil
        }
    }

    // MARK: Onboarding

    private var onboardingKey: String {
        profile.defaultsKey("hasCompletedOnboarding")
    }

    /// First launch of a profile that has no sites yet.
    var needsOnboarding: Bool {
        !userDefaults.bool(forKey: onboardingKey) && siteStore.sites.isEmpty
    }

    func completeOnboarding() {
        userDefaults.set(true, forKey: onboardingKey)
    }

    func hasSite(for service: StreamingService) -> Bool {
        guard let host = service.host else { return false }
        return siteStore.sites.contains { $0.url?.host()?.lowercased() == host }
    }

    func addServices(_ options: [ServiceOption]) {
        for option in options where !hasSite(for: option.service) {
            addSite(option.siteDraft())
        }

        if selection == nil, let first = siteStore.sites.first {
            select(.site(first.id))
        }
    }
}
