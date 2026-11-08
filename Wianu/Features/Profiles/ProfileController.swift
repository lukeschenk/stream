import Foundation
import Observation

/// Owns the active profile and the `AppModel` built for it. Switching profiles
/// builds a fresh model so every store reads that profile's data.
@MainActor
@Observable
final class ProfileController {
    private(set) var current: AppProfile
    private(set) var model: AppModel

    @ObservationIgnored
    private let userDefaults: UserDefaults

    static let activeProfileKey = "activeProfile"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let profile = userDefaults
            .string(forKey: Self.activeProfileKey)
            .flatMap(AppProfile.init(rawValue:)) ?? .main
        current = profile
        model = AppModel(profile: profile)
    }

    func switchTo(_ profile: AppProfile) {
        guard profile != current else { return }

        current = profile
        model = AppModel(profile: profile)
        userDefaults.set(profile.rawValue, forKey: Self.activeProfileKey)
    }
}
