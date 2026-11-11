import Foundation

/// A household profile. Each profile keeps its own sites, Continue Watching,
/// watchlist, Jellyfin account and website sign-ins.
nonisolated enum AppProfile: String, CaseIterable, Identifiable, Sendable {
    case main
    case kids

    /// UserDefaults key for the profile in use.
    static let activeProfileKey = "activeProfile"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .main: "Main"
        case .kids: "Kids"
        }
    }

    var systemImage: String {
        switch self {
        case .main: "person.crop.circle"
        case .kids: "figure.and.child.holdinghands"
        }
    }

    /// Folder under Application Support. The main profile keeps the original
    /// location so existing data is untouched.
    var storageFolderName: String {
        switch self {
        case .main: "Stream"
        case .kids: "Stream/Profiles/kids"
        }
    }

    /// Prefix for profile-specific UserDefaults keys.
    var defaultsKeyPrefix: String {
        switch self {
        case .main: ""
        case .kids: "profile.kids."
        }
    }

    func defaultsKey(_ key: String) -> String {
        defaultsKeyPrefix + key
    }

    /// Identifier for a separate WebKit data store, so cookies and sign-ins
    /// are kept apart. `nil` uses the default store the app has always used.
    var websiteDataStoreIdentifier: UUID? {
        switch self {
        case .main: nil
        case .kids: UUID(uuidString: "6B1D2E0C-4F2A-4C6B-9E57-0A6F1D7C2B11")
        }
    }
}
