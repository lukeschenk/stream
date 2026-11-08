import Foundation
import Testing
@testable import Wianu

@Suite("Watchlist sync hooks")
@MainActor
struct WatchlistSyncTests {
    private final class Recorder {
        var saved: [[WatchlistItem.ID]] = []
        var deleted: [[WatchlistItem.ID]] = []
    }

    private func makeStore() -> (WatchlistStore, Recorder) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WatchlistSyncTests-\(UUID().uuidString)")
        let store = WatchlistStore(
            fileStore: JSONFileStore(
                fileName: "watchlist.json",
                folderName: "Wianu",
                baseDirectory: directory
            )
        )
        let recorder = Recorder()
        store.changeHandler = { saved, deleted in
            recorder.saved.append(saved)
            recorder.deleted.append(deleted)
        }
        return (store, recorder)
    }

    @Test func `local additions are reported as saves`() {
        let (store, recorder) = makeStore()
        let item = store.add(title: "Arrival", year: 2016, url: nil)

        #expect(recorder.saved == [[item.id]])
        #expect(recorder.deleted == [[]])
    }

    @Test func `removals report the deletion and renumbered items`() {
        let (store, recorder) = makeStore()
        let first = store.add(title: "Arrival", year: 2016, url: nil)
        let second = store.add(title: "Dune", year: 2021, url: nil)
        recorder.saved = []
        recorder.deleted = []

        store.remove(id: first.id)

        #expect(recorder.deleted == [[first.id]])
        #expect(recorder.saved == [[second.id]])
        #expect(store.items.first?.sourceOrder == 0)
    }

    @Test func `unchanged edits report nothing`() {
        let (store, recorder) = makeStore()
        let item = store.add(title: "Arrival", year: 2016, url: nil)
        recorder.saved = []

        store.update(id: item.id, title: "Arrival", year: 2016, url: nil)

        #expect(recorder.saved.isEmpty)
    }

    @Test func `remote changes apply without echoing back`() {
        let (store, recorder) = makeStore()
        let local = store.add(title: "Arrival", year: 2016, url: nil)
        recorder.saved = []
        recorder.deleted = []

        let remote = WatchlistItem(
            title: "Past Lives",
            year: 2023,
            url: nil,
            addedAt: Date(),
            sourceOrder: 0,
            source: .custom
        )
        store.applyRemoteChanges(upserts: [remote], deletions: [local.id])

        #expect(store.items.map(\.title) == ["Past Lives"])
        #expect(recorder.saved.isEmpty)
        #expect(recorder.deleted.isEmpty)

        // A later local edit only reports what changed since the remote apply.
        let added = store.add(title: "Aftersun", year: 2022, url: nil)
        #expect(recorder.saved == [[added.id]])
    }

    @Test func `remote items numbered alike keep a stable order`() {
        let (store, _) = makeStore()
        let older = WatchlistItem(
            title: "Older",
            year: nil,
            url: nil,
            addedAt: Date(timeIntervalSince1970: 100),
            sourceOrder: 0,
            source: .custom
        )
        let newer = WatchlistItem(
            title: "Newer",
            year: nil,
            url: nil,
            addedAt: Date(timeIntervalSince1970: 200),
            sourceOrder: 0,
            source: .custom
        )

        store.applyRemoteChanges(upserts: [newer, older], deletions: [])

        #expect(store.items.map(\.title) == ["Older", "Newer"])
    }
}
