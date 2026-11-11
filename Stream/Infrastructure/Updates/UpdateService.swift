import Combine
import Sparkle

@MainActor
final class UpdateService: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        // This fork has no update feed of its own. Without one, Sparkle stays
        // off rather than offering upstream builds that would replace it.
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = SPUStandardUpdaterController(
            startingUpdater: hasFeed,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        controller.updater.publisher(for: \.canCheckForUpdates).assign(
            to: &$canCheckForUpdates
        )
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
