import SwiftUI

@main
struct WianuApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var updateService = UpdateService()
    @State private var profiles = ProfileController()

    private var model: AppModel {
        profiles.model
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: profiles.model, switchProfile: profiles.switchTo)
                // A fresh view tree per profile, so the browser picks up that
                // profile's sign-ins.
                .id(profiles.current)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1200, height: 800)
        .commands {
            VideoInformationCommands()

            CommandMenu("Profile") {
                Button("Main Profile") { profiles.switchTo(.main) }
                    .keyboardShortcut("1", modifiers: [.command, .control])
                    .disabled(profiles.current == .main)
                Button("Kids Profile") { profiles.switchTo(.kids) }
                    .keyboardShortcut("2", modifiers: [.command, .control])
                    .disabled(profiles.current == .kids)
            }

            CommandGroup(replacing: .appInfo) {
                Button("About Wianu") {
                    openWindow(id: "about")
                }
            }

            CommandGroup(after: .appInfo) {
                Button {
                    model.updateCheckStarted()
                    updateService.checkForUpdates()
                } label: {
                    Label(
                        "Check for Updates…",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(!updateService.canCheckForUpdates)
            }

            CommandGroup(after: .help) {
                Link(
                    "Send Feedback…",
                    destination: URL(
                        string: "https://github.com/timwehrle/Wianu/issues/new/choose"
                    )!
                )
            }
        }
        Settings {
            SettingsView(model: model)
        }

        Window("About Wianu", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
    }
}

struct ShowVideoInformationKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var showVideoInformation: ShowVideoInformationKey.Value? {
        get { self[ShowVideoInformationKey.self] }
        set { self[ShowVideoInformationKey.self] = newValue }
    }
}

private struct VideoInformationCommands: Commands {
    @FocusedValue(\.showVideoInformation) private var showVideoInformation

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Video Information…") {
                showVideoInformation?()
            }
            .disabled(showVideoInformation == nil)
        }
    }
}
