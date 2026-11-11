import CloudKit
import Foundation
import OSLog

/// Keeps one record per profile in the private iCloud database, checked
/// when Stream opens or comes back to the front, and saved after changes.
@MainActor
final class ProfileSettingsCloudSync {
    static let recordType = "ProfileSettings"

    private enum Field {
        static let sites = "sites"
        static let jellyfin = "jellyfin"
        static let modifiedAt = "modifiedAt"
    }

    private static let logger = Logger(subsystem: "Stream", category: "ProfileSettingsCloudSync")

    private let database: CKDatabase
    private let recordID: CKRecord.ID
    private let sites: SiteStore
    private let jellyfin: JellyfinConnection
    private let userDefaults: UserDefaults
    private let modifiedKey: String
    private var saveTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var completedRefreshes = 0

    init?(
        sites: SiteStore,
        jellyfin: JellyfinConnection,
        profile: AppProfile,
        userDefaults: UserDefaults = .standard
    ) {
        guard let identifier = WatchlistCloudSync.containerIdentifier else { return nil }

        database = CKContainer(identifier: identifier).privateCloudDatabase
        recordID = CKRecord.ID(recordName: "settings-\(profile.rawValue)")
        self.sites = sites
        self.jellyfin = jellyfin
        self.userDefaults = userDefaults
        modifiedKey = profile.defaultsKey("settings.modifiedAt")

        sites.changeHandler = { [weak self] in self?.localChanged() }
        jellyfin.accountChangeHandler = { [weak self] in self?.localChanged() }

        Task { await self.refresh() }
    }

    func stop() {
        sites.changeHandler = nil
        jellyfin.accountChangeHandler = nil
        saveTask?.cancel()
        refreshTask?.cancel()
    }

    /// When this device last changed or received the settings. `nil` until
    /// its first sync.
    private var localModifiedAt: Date? {
        get { userDefaults.object(forKey: modifiedKey) as? Date }
        set { userDefaults.set(newValue, forKey: modifiedKey) }
    }

    // MARK: Fetching

    /// Brings in newer settings from iCloud, or saves this device's if it has
    /// the newer ones. Concurrent calls share one check.
    func refresh() async {
        if let refreshTask {
            await refreshTask.value
        } else {
            let task = Task { await performRefresh() }
            refreshTask = task
            await task.value
            refreshTask = nil
        }
        completedRefreshes += 1
    }

    /// Like `refresh()`, but stops waiting after `timeout`, for use before
    /// showing first-run setup. The check itself carries on.
    func refresh(timeout: Duration) async {
        let target = completedRefreshes + 1
        Task { await refresh() }

        let deadline = ContinuousClock.now + timeout
        while completedRefreshes < target, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func performRefresh() async {
        let record: CKRecord?
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = nil
        } catch {
            Self.logger.info("Could not check settings: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let record, let remote = Self.snapshot(from: record) else {
            // Nothing in iCloud yet: share what this device has.
            if !sites.sites.isEmpty || jellyfin.currentSuggestion != nil {
                localModifiedAt = localModifiedAt ?? Date()
                await save()
            }
            return
        }

        if let local = localModifiedAt {
            if remote.modifiedAt > local {
                apply(remote)
            } else if local > remote.modifiedAt {
                await save()
            }
        } else {
            // First sync on this device: combine rather than overwrite.
            let merged = ProfileSettingsSnapshot.merged(local: sites.sites, remote: remote.sites)
            apply(ProfileSettingsSnapshot(sites: merged, jellyfin: remote.jellyfin, modifiedAt: remote.modifiedAt))
            if merged != remote.sites {
                localModifiedAt = Date()
                await save()
            }
        }
    }

    private func apply(_ snapshot: ProfileSettingsSnapshot) {
        sites.replaceSites(snapshot.sites)
        if !jellyfin.isSignedIn {
            jellyfin.applySuggestion(snapshot.jellyfin)
        }
        localModifiedAt = snapshot.modifiedAt
    }

    // MARK: Saving

    private func localChanged() {
        localModifiedAt = Date()
        saveTask?.cancel()
        saveTask = Task {
            // Gather quick successive edits into one save.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        let encoder = JSONEncoder()
        record[Field.sites] = try? encoder.encode(sites.sites)
        record[Field.jellyfin] = jellyfin.currentSuggestion.flatMap { try? encoder.encode($0) }
        record[Field.modifiedAt] = localModifiedAt ?? Date()

        do {
            // Newest edit wins, so skip the server's change check.
            _ = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .allKeys,
                atomically: true
            )
        } catch {
            Self.logger.error("Could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Records

    static func snapshot(from record: CKRecord) -> ProfileSettingsSnapshot? {
        guard let data = record[Field.sites] as? Data,
              let sites = try? JSONDecoder().decode([SavedSite].self, from: data)
        else { return nil }

        let jellyfin = (record[Field.jellyfin] as? Data)
            .flatMap { try? JSONDecoder().decode(JellyfinServerSuggestion.self, from: $0) }
        let modifiedAt = record[Field.modifiedAt] as? Date ?? .distantPast
        return ProfileSettingsSnapshot(sites: sites, jellyfin: jellyfin, modifiedAt: modifiedAt)
    }
}
