import CloudKit
import Foundation
import OSLog
import Security

/// Sync bookkeeping kept next to the watchlist file.
struct WatchlistCloudMetadata: Codable {
    var engineState: CKSyncEngine.State.Serialization?
    /// Archived CloudKit system fields per record name, so edits update the
    /// existing record instead of conflicting with it.
    var systemFields: [String: Data] = [:]
    /// When each item was last changed on this Mac, for resolving conflicts.
    var localModified: [String: Date] = [:]
}

/// Keeps one profile's watchlist in the person's private iCloud database with
/// CKSyncEngine. Each profile uses its own record zone.
@MainActor
final class WatchlistCloudSync {
    static let recordType = "WatchlistItem"

    private enum Field {
        static let payload = "payload"
        static let title = "title"
        static let modifiedAt = "modifiedAt"
    }

    private static let logger = Logger(subsystem: "Wianu", category: "WatchlistCloudSync")

    /// The CloudKit container this build is entitled to, or `nil` when the
    /// iCloud capability hasn't been added in Xcode.
    static var containerIdentifier: String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.icloud-container-identifiers" as CFString,
                  nil
              )
        else { return nil }

        return (value as? [String])?.first
    }

    private let store: WatchlistStore
    private let zoneID: CKRecordZone.ID
    private let metadataStore: JSONFileStore<WatchlistCloudMetadata>
    private var metadata: WatchlistCloudMetadata
    private let delegate = WatchlistSyncDelegate()
    private var engine: CKSyncEngine?

    init?(store: WatchlistStore, profile: AppProfile) {
        guard let identifier = Self.containerIdentifier else { return nil }

        self.store = store
        zoneID = CKRecordZone.ID(
            zoneName: profile == .main ? "Watchlist" : "Watchlist-\(profile.rawValue)",
            ownerName: CKCurrentUserDefaultName
        )
        metadataStore = JSONFileStore(
            fileName: "watchlist-cloud.json",
            folderName: profile.storageFolderName
        )
        metadata = (try? metadataStore.load(defaultValue: WatchlistCloudMetadata())) ?? WatchlistCloudMetadata()

        let isFirstRun = metadata.engineState == nil
        delegate.owner = self

        let container = CKContainer(identifier: identifier)
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: metadata.engineState,
            delegate: delegate
        )
        engine = CKSyncEngine(configuration)

        store.changeHandler = { [weak self] saved, deleted in
            self?.queue(saved: saved, deleted: deleted)
        }

        if isFirstRun {
            saveZone()
        }
        queueItemsNeverUploaded()
    }

    /// Stops syncing. Local data and the iCloud copy are both left alone.
    func stop() {
        store.changeHandler = nil
        delegate.owner = nil
        engine = nil
    }

    // MARK: Local changes

    private func queue(saved: [WatchlistItem.ID], deleted: [WatchlistItem.ID]) {
        guard let engine else { return }

        let now = Date()
        for id in saved {
            metadata.localModified[id.uuidString] = now
        }
        for id in deleted {
            metadata.localModified[id.uuidString] = nil
        }
        saveMetadata()

        engine.state.add(
            pendingRecordZoneChanges: saved.map { .saveRecord(recordID(for: $0)) }
                + deleted.map { .deleteRecord(recordID(for: $0)) }
        )
    }

    private func queueItemsNeverUploaded() {
        let pending = store.items
            .map(\.id)
            .filter { metadata.systemFields[$0.uuidString] == nil }

        guard !pending.isEmpty else { return }
        engine?.state.add(pendingRecordZoneChanges: pending.map { .saveRecord(recordID(for: $0)) })
    }

    private func saveZone() {
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    // MARK: Engine callbacks

    fileprivate func handle(_ event: CKSyncEngine.Event) {
        switch event {
        case let .stateUpdate(update):
            metadata.engineState = update.stateSerialization
            saveMetadata()

        case let .accountChange(change):
            switch change.changeType {
            case .signIn:
                saveZone()
                queueItemsNeverUploaded()
            case .signOut, .switchAccounts:
                // The local watchlist stays; it uploads again to whichever
                // account signs in next.
                metadata.systemFields = [:]
                saveMetadata()
            @unknown default:
                break
            }

        case let .fetchedDatabaseChanges(changes):
            if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                metadata.systemFields = [:]
                saveMetadata()
                saveZone()
                queueItemsNeverUploaded()
            }

        case let .fetchedRecordZoneChanges(changes):
            applyFetched(changes)

        case let .sentRecordZoneChanges(sent):
            applySent(sent)

        default:
            break
        }
    }

    fileprivate func nextBatch(
        _ context: CKSyncEngine.SendChangesContext,
        engine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = engine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        guard !changes.isEmpty else { return nil }

        // Build records here on the main actor; the batch asks for them from
        // another context.
        var records: [CKRecord.ID: CKRecord] = [:]
        var stale: [CKSyncEngine.PendingRecordZoneChange] = []

        for change in changes {
            guard case let .saveRecord(recordID) = change else { continue }

            if let record = record(for: recordID) {
                records[recordID] = record
            } else {
                stale.append(change)
            }
        }

        if !stale.isEmpty {
            engine.state.remove(pendingRecordZoneChanges: stale)
        }

        let ready = records
        let sendable = changes.filter { change in
            !stale.contains { $0 == change }
        }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: sendable) { recordID in
            ready[recordID]
        }
    }

    // MARK: Applying results

    private func applyFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        var upserts: [WatchlistItem] = []
        var deletions: [WatchlistItem.ID] = []

        for modification in changes.modifications where modification.record.recordID.zoneID == zoneID {
            let record = modification.record
            guard let item = Self.item(from: record) else { continue }

            upserts.append(item)
            metadata.systemFields[record.recordID.recordName] = record.systemFieldsData
            metadata.localModified[record.recordID.recordName] = nil
        }

        for deletion in changes.deletions where deletion.recordID.zoneID == zoneID {
            let name = deletion.recordID.recordName
            if let id = UUID(uuidString: name) {
                deletions.append(id)
            }
            metadata.systemFields[name] = nil
            metadata.localModified[name] = nil
        }

        store.applyRemoteChanges(upserts: upserts, deletions: deletions)
        saveMetadata()
    }

    private func applySent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var acceptedFromServer: [WatchlistItem] = []

        for record in sent.savedRecords {
            metadata.systemFields[record.recordID.recordName] = record.systemFieldsData
        }

        for failure in sent.failedRecordSaves {
            let recordID = failure.record.recordID
            let name = recordID.recordName

            switch failure.error.code {
            case .serverRecordChanged:
                guard let serverRecord = failure.error.serverRecord else { break }
                metadata.systemFields[name] = serverRecord.systemFieldsData

                // Newest edit wins.
                let serverDate = serverRecord[Field.modifiedAt] as? Date ?? .distantPast
                let localDate = metadata.localModified[name] ?? .distantPast
                if serverDate > localDate, let item = Self.item(from: serverRecord) {
                    acceptedFromServer.append(item)
                    metadata.localModified[name] = nil
                } else {
                    retry.append(.saveRecord(recordID))
                }

            case .zoneNotFound:
                saveZone()
                metadata.systemFields[name] = nil
                retry.append(.saveRecord(recordID))

            case .unknownItem:
                metadata.systemFields[name] = nil
                retry.append(.saveRecord(recordID))

            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .notAuthenticated, .operationCancelled, .requestRateLimited:
                // CKSyncEngine retries these itself.
                break

            default:
                Self.logger.error("Could not save watchlist item: \(failure.error.localizedDescription, privacy: .public)")
            }
        }

        for recordID in sent.deletedRecordIDs {
            metadata.systemFields[recordID.recordName] = nil
        }

        store.applyRemoteChanges(upserts: acceptedFromServer, deletions: [])
        if !retry.isEmpty {
            engine?.state.add(pendingRecordZoneChanges: retry)
        }
        saveMetadata()
    }

    // MARK: Records

    private func recordID(for id: WatchlistItem.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    private func record(for recordID: CKRecord.ID) -> CKRecord? {
        guard let id = UUID(uuidString: recordID.recordName),
              let item = store.item(id: id),
              let payload = try? Self.encoder.encode(item)
        else { return nil }

        let record = metadata.systemFields[recordID.recordName].flatMap(CKRecord.init(systemFieldsData:))
            ?? CKRecord(recordType: Self.recordType, recordID: recordID)

        record[Field.payload] = payload
        record[Field.title] = item.title
        record[Field.modifiedAt] = metadata.localModified[recordID.recordName] ?? Date()
        return record
    }

    private static func item(from record: CKRecord) -> WatchlistItem? {
        guard let payload = record[Field.payload] as? Data else { return nil }
        return try? decoder.decode(WatchlistItem.self, from: payload)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func saveMetadata() {
        do {
            try metadataStore.save(metadata)
        } catch {
            Self.logger.error("Could not save sync state: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// CKSyncEngine calls its delegate off the main actor; this forwards to the
/// main-actor sync object.
private nonisolated final class WatchlistSyncDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    weak var owner: WatchlistCloudSync?

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine _: CKSyncEngine) async {
        await MainActor.run {
            owner?.handle(event)
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let owner = await MainActor.run(body: { owner }) else { return nil }
        return await owner.nextBatch(context, engine: syncEngine)
    }
}

private extension CKRecord {
    var systemFieldsData: Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    convenience init?(systemFieldsData data: Data) {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        self.init(coder: coder)
        coder.finishDecoding()
    }
}
