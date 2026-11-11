import Foundation

enum SidebarSelection: Hashable {
    case home
    case site(SavedSite.ID)
    case continueWatching(ContinueWatchingItem.ID)
    case watchlistItem(WatchlistItem.ID)
    case jellyfin(JellyfinDestination)

    /// Selections drawn natively rather than in the web browser.
    var showsNativeContent: Bool {
        switch self {
        case .home, .jellyfin: true
        case .site, .continueWatching, .watchlistItem: false
        }
    }
}

enum JellyfinDestination: Hashable {
    /// Continue Watching and Next Up from the server.
    case watching
    case library(id: String)
}
