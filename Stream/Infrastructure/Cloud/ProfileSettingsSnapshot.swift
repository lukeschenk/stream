import Foundation

/// What a profile shares between devices: its streaming services and the
/// Jellyfin server it uses. Sign-ins stay on each device, since Jellyfin
/// ties them to one device.
struct ProfileSettingsSnapshot: Equatable {
    var sites: [SavedSite]
    var jellyfin: JellyfinServerSuggestion?
    var modifiedAt: Date

    /// The first time a device syncs, keep its own sites and add the ones
    /// iCloud has that it doesn't.
    static func merged(local: [SavedSite], remote: [SavedSite]) -> [SavedSite] {
        let localHosts = Set(local.compactMap(host(of:)))
        let localIDs = Set(local.map(\.id))
        return local + remote.filter { site in
            !localIDs.contains(site.id) && !(host(of: site).map(localHosts.contains) ?? false)
        }
    }

    private static func host(of site: SavedSite) -> String? {
        site.url?.host()?.lowercased()
    }
}
