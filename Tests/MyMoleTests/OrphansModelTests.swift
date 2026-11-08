import Foundation
import Synchronization
import StorageKit
import Testing

@testable import MyMole

/// Leftovers of removed apps, in a Library and Trash of the test's own.
@MainActor
@Suite struct OrphansModelTests {
    final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "orphans-\(UUID().uuidString)")
        var home: String { root.appending(path: "home").path }
        var log: URL { root.appending(path: "history.json") }

        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func file(_ rel: String) throws -> String {
            let url = URL(fileURLWithPath: home + "/" + rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 3, count: 8_000).write(to: url)
            return url.deletingLastPathComponent().path
        }

        func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

        @MainActor func model(running: Set<String> = [], installedNow: @escaping @Sendable () -> [AppBundle]? = { [] }) -> OrphansModel {
            let m = OrphansModel(
                home: home, logURL: log, trash: testBin(root), known: { _ in false }, running: { running }, installedNow: installedNow)
            m.jobs = TrashJobs()
            m.protections = UserProtections(root: root.appending(path: "lists"))
            return m
        }
    }

    @Test func cachesStartChosenDataStaysAndUndoPutsThemBack() async throws {
        let box = Box()
        let cache = try box.file("Library/Caches/com.gone.Editor/blob")
        let data = try box.file("Library/Application Support/com.gone.Editor/notes.db")
        let other = try box.file("Library/Caches/com.gone.Player/blob")
        let model = box.model()
        model.load()
        await model.job?.value
        #expect(Set(model.items.map(\.path)) == [cache, data, other])
        #expect(model.chosen == [cache, other])

        // Kept in Deep Clean after the search: it stays when the move runs.
        _ = try CleanKeepList.update(at: model.protections.keepList) { $0.paths.insert(other) }
        model.trashChosen()
        await model.job?.value
        #expect(!box.exists(cache) && box.exists(data) && box.exists(other))
        let record = try #require(CleanupLog.load(from: box.log).first)
        #expect(record.source == OrphansModel.source && record.items == 1)

        model.undoTrash(run: record.id)
        await model.job?.value
        #expect(box.exists(cache) && model.items.contains { $0.path == cache })
    }

    @Test func anAppStartedSinceTheSearchKeepsItsData() async throws {
        let box = Box()
        let cache = try box.file("Library/Caches/com.gone.Editor/blob")
        let running = Mutex<Set<String>>([])
        let model = OrphansModel(
            home: box.home, logURL: box.log, trash: testBin(box.root), known: { _ in false }, running: { running.withLock { $0 } },
            installedNow: { [] })
        model.jobs = TrashJobs()
        model.protections = UserProtections(root: box.root.appending(path: "lists"))
        model.load()
        await model.job?.value
        #expect(model.chosen == [cache])
        running.withLock { $0 = ["com.gone.Editor"] }
        model.trashChosen()
        await model.job?.value
        #expect(box.exists(cache))
    }

    @Test func anAppInstalledWhileTheMoveWaitedKeepsItsData() async throws {
        let box = Box()
        let cache = try box.file("Library/Caches/com.gone.Editor/blob")
        let installed = Mutex<[AppBundle]>([])
        let model = box.model(installedNow: { installed.withLock { $0 } })
        model.load()
        await model.job?.value
        #expect(model.chosen == [cache])
        // Another pane's move holds the queue; the app is installed meanwhile.
        let jobs = TrashJobs()
        model.jobs = jobs
        let other = await jobs.begin(.moveToTrash)
        model.trashChosen()
        installed.withLock {
            $0 = [AppBundle(path: "/synthetic/Applications/Editor.app", name: "Editor", bundleID: "com.gone.Editor", version: nil, bytes: 0, fromAppStore: false)]
        }
        jobs.end(other)
        await model.job?.value
        #expect(box.exists(cache))
    }

    @Test func nothingMovesWhenTheInstalledAppsCantBeRead() async throws {
        let box = Box()
        let cache = try box.file("Library/Caches/com.gone.Editor/blob")
        let owners = Mutex<[AppBundle]?>([])
        let model = box.model(installedNow: { owners.withLock { $0 } })
        model.load()
        await model.job?.value
        owners.withLock { $0 = nil }
        model.trashChosen()
        await model.job?.value
        #expect(box.exists(cache))
        #expect(model.notice?.text == "The installed apps couldn't be read, so nothing was moved.")
    }

    @Test func anUnknownInventoryCannotPublishAnOrphanSearch() async throws {
        let box = Box()
        _ = try box.file("Library/Caches/com.gone.Editor/blob")
        let model = box.model(installedNow: { nil })
        model.load()
        await model.job?.value
        #expect(model.items.isEmpty && model.loadedAt == nil && model.searchProblem != nil)
    }

    @Test func aNewHelperOwnerWithAnotherVendorPrefixProtectsItsCacheAfterTheQueue() async throws {
        let box = Box()
        let cache = try box.file("Library/Caches/org.shared.Worker/blob")
        let installed = Mutex<[AppBundle]>([])
        let model = box.model(installedNow: { installed.withLock { $0 } })
        model.load()
        await model.job?.value
        #expect(model.chosen == [cache])
        let blocker = await model.jobs.begin(.moveToTrash)
        model.trashChosen()
        for (path, id) in [("Applications/Viewer.app", "com.present.Viewer"),
                           ("Applications/Viewer.app/Contents/XPCServices/Worker.xpc", "org.shared.Worker")] {
            _ = try box.file(path + "/Contents/bin")
            try (["CFBundleIdentifier": id] as NSDictionary).write(to: URL(fileURLWithPath: box.home + "/" + path + "/Contents/Info.plist"))
        }
        let app = try #require(AppFinder.metadata(box.home + "/Applications/Viewer.app"))
        installed.withLock { $0 = [app] }
        model.jobs.end(blocker)
        await model.job?.value
        #expect(box.exists(cache))
    }

    @Test func stoppingAQueuedRescanKeepsTheCompleteResultAndAnotherScansSlot() async throws {
        let box = Box()
        let cache = try box.file("Library/Caches/com.gone.Editor/blob")
        let budget = ScanBudget(slots: 1)
        let model = OrphansModel(home: box.home, logURL: box.log, trash: testBin(box.root), known: { _ in false },
                                 running: { [] }, installedNow: { [] }, scanBudget: budget)
        model.protections = UserProtections(root: box.root.appending(path: "lists"))
        model.load()
        await model.job?.value
        let date = model.loadedAt
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.yield(()); release.finish() }
        let hold = Task.detached { await budget.run(background: false) { for await _ in stream { break } } }
        for _ in 0..<100 where budget.running == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(budget.running == 1)
        _ = try box.file("Library/Caches/com.gone.Player/blob")
        model.load()
        for _ in 0..<100 where budget.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(budget.waiting == 1)
        model.stop()
        await model.job?.value
        #expect(model.stopped && !model.loading && model.loadedAt == date)
        #expect(model.items.map(\.path) == [cache] && model.chosen == [cache])
        #expect(budget.running == 1 && budget.waiting == 0)
        release.yield(()); release.finish()
        _ = await hold.value
        model.load()
        await model.job?.value
        #expect(model.items.count == 2 && !model.stopped)
    }
}
