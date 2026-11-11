import SwiftUI

struct MobileSettingsView: View {
    let profiles: MobileProfileController

    private var model: MobileModel {
        profiles.model
    }

    var body: some View {
        Form {
            Section {
                Picker("Profile", selection: profileBinding) {
                    ForEach(AppProfile.allCases) { profile in
                        Label(profile.displayName, systemImage: profile.systemImage)
                            .tag(profile)
                    }
                }
            } footer: {
                Text("Each profile has its own services, watchlist and Jellyfin account.")
            }

            Section {
                NavigationLink {
                    MobileServicesView(model: model)
                } label: {
                    LabeledContent("Streaming Services", value: "\(model.services.sites.count)")
                }

                NavigationLink {
                    JellyfinSettingsView(connection: model.jellyfin, profile: model.profile)
                        .navigationTitle("Jellyfin")
                } label: {
                    LabeledContent(
                        "Jellyfin",
                        value: model.jellyfin.account?.serverName ?? (model.jellyfin.isSignedIn ? "Connected" : "Off")
                    )
                }
            }

            Section {
                Toggle(
                    "Sync with iCloud",
                    isOn: Binding(
                        get: { model.isSyncingWithICloud },
                        set: { model.setICloudSyncEnabled($0) }
                    )
                )
                .disabled(!model.canSyncWithICloud)
            } footer: {
                Text(
                    model.canSyncWithICloud
                        ? "Shares this profile’s watchlist, streaming services and Jellyfin server with your "
                        + "other devices. Each device signs in to Jellyfin once."
                        : "Needs the iCloud capability and the StreamCloudKitContainer setting in this build."
                )
            }
        }
        .navigationTitle("Settings")
    }

    private var profileBinding: Binding<AppProfile> {
        Binding(
            get: { profiles.current },
            set: { profiles.switchTo($0) }
        )
    }
}

/// Pick the services this profile has. Matches the Mac's onboarding.
struct MobileServicesView: View {
    let model: MobileModel

    @State private var providers: [TMDBProvider] = []
    @State private var isLoading = true

    private var search: TMDBSearchModel {
        model.search
    }

    private var options: [ServiceOption] {
        ServiceOption.options(from: providers, region: search.selectedRegion)
    }

    var body: some View {
        Form {
            if !search.regions.isEmpty {
                Picker("Region", selection: regionBinding) {
                    ForEach(search.regions) { region in
                        Text(region.displayName).tag(region.isoCode)
                    }
                }
            }

            Section {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(options) { option in
                        Toggle(isOn: serviceBinding(option)) {
                            HStack(spacing: 14) {
                                AsyncImage(
                                    url: search.imageConfiguration?.logoURL(path: option.provider?.logoPath)
                                ) { phase in
                                    phase.image?.resizable().scaledToFit()
                                }
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                Text(option.service.name)
                            }
                        }
                    }
                }
            } footer: {
                Text("Search can then show only what’s included with your services.")
            }
        }
        .navigationTitle("Streaming Services")
        .task {
            isLoading = true
            providers = (try? await model.tmdbClient.providers()) ?? []
            isLoading = false
        }
    }

    private var regionBinding: Binding<String> {
        Binding(
            get: { search.selectedRegion },
            set: { search.selectRegion($0) }
        )
    }

    private func serviceBinding(_ option: ServiceOption) -> Binding<Bool> {
        Binding(
            get: { model.hasService(option.service) },
            set: { model.setService(option, enabled: $0) }
        )
    }
}
