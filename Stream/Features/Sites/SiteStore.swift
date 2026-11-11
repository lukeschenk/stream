import Foundation
import Observation

@MainActor
@Observable
final class SiteStore {
    private(set) var sites: [SavedSite] = []
    private(set) var persistenceError: String?

    @ObservationIgnored
    private let fileStore: JSONFileStore<[SavedSite]>

    /// Called after local edits so iCloud can save them. Changes applied
    /// from iCloud don't trigger it.
    @ObservationIgnored
    var changeHandler: (() -> Void)?

    init(
        fileStore: JSONFileStore<[SavedSite]> = JSONFileStore(
            fileName: "sites.json",
            folderName: "Stream"
        )
    ) {
        self.fileStore = fileStore
        load()
    }

    func addSite(_ draft: SiteDraft) {
        guard let values = draft.validatedValues else { return }
        sites.append(
            SavedSite(
                name: values.name,
                urlString: values.url.absoluteString,
                searchURLTemplate: values.searchURLTemplate,
                tmdbProvider: values.tmdbProvider
            )
        )
        persist()
    }

    func updateSite(id: SavedSite.ID, with draft: SiteDraft) {
        guard let index = sites.firstIndex(where: { $0.id == id }),
              let values = draft.validatedValues
        else { return }

        sites[index].name = values.name
        sites[index].urlString = values.url.absoluteString
        sites[index].searchURLTemplate = values.searchURLTemplate
        sites[index].tmdbProvider = values.tmdbProvider
        persist()
    }

    func deleteSite(id: SavedSite.ID) {
        sites.removeAll { $0.id == id }
        persist()
    }

    /// Replaces the list with one from iCloud without echoing it back.
    func replaceSites(_ newSites: [SavedSite]) {
        guard newSites != sites else { return }
        sites = newSites
        write()
    }

    private func load() {
        do {
            sites = try fileStore.load(defaultValue: [])
            persistenceError = nil
        } catch {
            sites = []
            persistenceError = error.localizedDescription
        }
    }

    private func persist() {
        write()
        changeHandler?()
    }

    private func write() {
        do {
            try fileStore.save(sites)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }
}
