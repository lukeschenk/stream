import SwiftUI

/// First-run setup: pick the streaming services you have, then optionally
/// connect Jellyfin. Can be reopened from the sidebar.
struct OnboardingView: View {
    let model: AppModel
    let onFinish: () -> Void

    private enum Step {
        case services
        case library
    }

    @State private var step: Step = .services
    @State private var providers: [TMDBProvider] = []
    @State private var isLoadingProviders = true
    @State private var selection: Set<StreamingService.ID> = []

    private var search: TMDBSearchModel {
        model.tmdbSearch
    }

    private var options: [ServiceOption] {
        ServiceOption.options(from: providers, region: search.selectedRegion)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .services: servicesStep
                case .library: libraryStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            footer
        }
        .frame(width: 660, height: 580)
        .task { await loadProviders() }
    }

    // MARK: Services

    private var servicesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(
                model.profile == .kids ? "Which services do the kids use?" : "Which services do you have?",
                detail: "They’re added to your sidebar, and search can show what’s included with them."
            )

            if !search.regions.isEmpty {
                Picker("Region", selection: regionBinding) {
                    ForEach(search.regions) { region in
                        Text(region.displayName).tag(region.isoCode)
                    }
                }
                .fixedSize()
            }

            if isLoadingProviders {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 130), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(options) { option in
                            ServiceTile(
                                option: option,
                                logoURL: search.imageConfiguration?.logoURL(path: option.provider?.logoPath),
                                isSelected: selection.contains(option.id),
                                isAlreadyAdded: model.hasSite(for: option.service)
                            ) {
                                toggle(option)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Text("Don’t see one? You can add any website later with Add Site.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
    }

    private var regionBinding: Binding<String> {
        Binding(
            get: { search.selectedRegion },
            set: { search.selectRegion($0) }
        )
    }

    private func toggle(_ option: ServiceOption) {
        if selection.contains(option.id) {
            selection.remove(option.id)
        } else {
            selection.insert(option.id)
        }
    }

    private func loadProviders() async {
        isLoadingProviders = true
        defer { isLoadingProviders = false }
        // On failure the catalog is offered without logos.
        providers = (try? await model.tmdbClient.providers()) ?? []
    }

    // MARK: Library

    private var libraryStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(
                "Have your own media library?",
                detail: "Connect a Jellyfin server to browse and play your movies and shows in Wianu. "
                    + "You can also do this later in Settings."
            )

            JellyfinSettingsView(connection: model.jellyfin, profile: model.profile)
                .frame(maxHeight: 300)

            Label(
                "Use Letterboxd? Import your watchlist from the sidebar with Import Letterboxd CSV.",
                systemImage: "list.star"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(28)
    }

    // MARK: Shared

    private func header(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            switch step {
            case .services:
                Button("Skip") { finish(adding: false) }
                Spacer()
                Button("Continue") {
                    step = .library
                }
                .keyboardShortcut(.defaultAction)
            case .library:
                Button("Back") { step = .services }
                Spacer()
                Button("Done") { finish(adding: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func finish(adding: Bool) {
        if adding {
            model.addServices(options.filter { selection.contains($0.id) })
        }
        model.completeOnboarding()
        onFinish()
    }
}

private struct ServiceTile: View {
    let option: ServiceOption
    let logoURL: URL?
    let isSelected: Bool
    let isAlreadyAdded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AsyncImage(url: logoURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        Text(option.service.name.prefix(1))
                            .font(.title.weight(.bold))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.quaternary)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(option.service.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text(isAlreadyAdded ? "In sidebar" : " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected || isAlreadyAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(isAlreadyAdded ? Color.secondary : Color.accentColor)
                        .padding(8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAlreadyAdded)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
