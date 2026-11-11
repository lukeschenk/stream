import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView()
                .frame(width: 560, height: 240)
                .tabItem { Label("General", systemImage: "gearshape") }

            JellyfinSettingsView(connection: model.jellyfin, profile: model.profile)
                .frame(width: 560, height: 360)
                .tabItem { Label("Jellyfin", systemImage: "server.rack") }

            ICloudSettingsView(model: model)
                .frame(width: 560, height: 240)
                .tabItem { Label("iCloud", systemImage: "icloud") }
        }
        .onAppear {
            model.settingsOpened()
        }
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AnalyticsPreference.enabledKey)
    private var analyticsEnabled = true

    var body: some View {
        Form {
            Toggle(
                "Send Anonymous Usage Analytics",
                isOn: $analyticsEnabled
            )

            Text(
                "Share basic feature usage and the Stream version. "
                    + "A random installation ID links repeat visits. "
                    + "Searches, titles, URLs, providers, and personal "
                    + "identifiers are never included."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ICloudSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Toggle(
                "Sync with iCloud",
                isOn: Binding(
                    get: { model.isSyncingWithICloud },
                    set: { model.setICloudSyncEnabled($0) }
                )
            )
            .disabled(!model.canSyncWithICloud)

            Text(
                model.canSyncWithICloud
                    ? "Keeps the \(model.profile.displayName) profile’s watchlist, streaming services and "
                    + "Jellyfin server the same on every device signed in to your iCloud account."
                    : "This build doesn’t have the iCloud capability. Add iCloud with CloudKit under "
                    + "Signing & Capabilities in Xcode to turn on sync."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)

                Text("Stream")
                    .font(.title.weight(.semibold))
                Text("Version \(version) (\(build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Made by Tim Wehrle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Link(destination: URL(string: "https://ko-fi.com/timwehrle")!) {
                Label("Support My Work", systemImage: "heart")
            }
            .buttonStyle(.bordered)

            Divider()

            VStack(spacing: 10) {
                Image("TMDBLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 28)
                Text(
                    "This product uses the TMDB API but is not endorsed or "
                        + "certified by TMDB."
                )

                Text("Watch-provider availability data by JustWatch.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 360)
    }
}
