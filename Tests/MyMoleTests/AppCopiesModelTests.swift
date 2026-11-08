import Foundation
import StorageKit
import Synchronization
import Testing

@testable import MyMole

@MainActor @Suite struct AppCopiesModelTests {
    private final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "app-copies-\(UUID().uuidString)")
        var home: String { root.path }
        deinit { try? FileManager.default.removeItem(at: root) }

        func app(_ path: String, id: String = "com.example.Editor", version: String = "1") throws -> AppBundle {
            let directory = root.appending(path: path + "/Contents")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (["CFBundleIdentifier": id, "CFBundleName": "Editor", "CFBundleShortVersionString": version, "CFBundleVersion": "100"] as NSDictionary)
                .write(to: directory.appending(path: "Info.plist"))
            return try #require(AppFinder.metadata(home + "/" + path))
        }

        func file(_ path: String) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 3, count: 4000).write(to: url)
        }

        @MainActor func apps(known: KnownAppCopies = .init()) -> AppsModel {
            let model = AppsModel(home: home, folders: [home + "/Applications"], base: root.appending(path: "store"), logURL: root.appending(path: "history.json"),
                                  recycle: { _ in Issue.record("No app is recycled by these tests"); return TrashOutcome(moved: [], failed: []) },
                                  isRunning: { _ in false }, otherCopies: { _ in [] }, trash: testBin(root),
                                  protections: UserProtections(root: root.appending(path: "protections")),
                                  identityReaders: .init(groups: { _ in [] }), knownCopies: known)
            model.jobs = TrashJobs()
            return model
        }
    }

    @Test func aLateOldInventoryCannotReplaceANewerScan() async throws {
        let box = Box()
        _ = try box.app("Applications/Editor.app")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let calls = Mutex(0)
        let runner = CommandRunner(run: { _, _ in
            let count = calls.withLock { $0 += 1; return $0 }
            if count == 1 { _ = gate.wait(timeout: .now() + 5) }
            return (0, "")
        }, exists: { _ in true })
        let model = AppCopiesModel(folders: [box.home + "/Applications"], runner: runner, registered: { _ in [] })
        model.load()
        let old = model.job
        for _ in 0..<200 where calls.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(calls.withLock { $0 } == 1)
        _ = try box.app("Applications/Editor.app", version: "2")
        model.load()
        await model.job?.value
        let date = model.loadedAt
        #expect(model.report.copies.first?.app.version == "2" && date != nil)
        gate.signal()
        await old?.value
        #expect(model.report.copies.first?.app.version == "2" && model.loadedAt == date)
    }

    @Test func onlyTheRequestedCopyIsMeasuredAndOtherUnindexedCopiesProtectItsData() async throws {
        let box = Box()
        let primary = try box.app("Applications/Editor.app")
        let second = try box.app("project/.build/Editor.app", version: "2")
        try box.file("Library/Caches/com.example.Editor/cache")
        let copies = AppCopiesModel(folders: [box.home + "/Applications"], runner: CommandRunner(run: { _, _ in (0, second.path) }, exists: { _ in true }), registered: { _ in [] })
        copies.load()
        await copies.job?.value
        #expect(copies.report.copies.count == 2 && copies.report.copies.allSatisfy { $0.app.sizePending })
        let selected = try #require(copies.report.copies.first { $0.id == primary.path })
        let apps = box.apps()
        let measured = try #require(await copies.prepareReview(selected, apps: apps))
        #expect(measured.bytes > 0 && !measured.sizePending)
        #expect(copies.report.copies.allSatisfy { $0.app.sizePending })
        #expect(await apps.leftovers(for: measured, deep: false)?.isEmpty == true)
        let projected = AppCopiesSheet.project(copies.report.copies, counts: copies.counts, query: ".build", filter: .copies)
        #expect(projected.map(\.id) == [second.path])
        #expect(AppCopiesSheet.project(copies.report.copies, counts: copies.counts, query: "", filter: .builds).map(\.id) == [second.path])
    }

    @Test func aCopyDiscoveredWhileResetWaitsProtectsDataAndTheOrphanSearch() async throws {
        let box = Box()
        let primary = try box.app("Applications/Editor.app")
        let second = try box.app("project/.build/Editor.app")
        try box.file("Library/Caches/com.example.Editor/cache")
        let known = KnownAppCopies()
        let apps = box.apps(known: known)
        let leftovers = try #require(await apps.leftovers(for: primary, deep: false))
        try #require(leftovers.count == 1)
        let blocker = await apps.jobs.begin(.moveToTrash)
        let move = Task { await apps.reset(primary, leftovers: leftovers) }
        for _ in 0..<100 where !apps.uninstalling { try await Task.sleep(for: .milliseconds(5)) }
        apps.rememberOtherCopies([second])
        apps.jobs.end(blocker)
        if case .done = await move.value { Issue.record("Shared cache moved") }
        #expect(FileManager.default.fileExists(atPath: box.home + "/Library/Caches/com.example.Editor/cache"))
        let orphans = OrphansModel(home: box.home, logURL: box.root.appending(path: "orphan-history.json"), trash: testBin(box.root), known: { _ in false },
                                   running: { [] }, installedNow: { [] }, knownCopies: known)
        orphans.protections = UserProtections(root: box.root.appending(path: "orphan-protections"))
        orphans.load()
        await orphans.job?.value
        #expect(orphans.items.isEmpty && orphans.searchProblem == nil)
        try Data("broken".utf8).write(to: URL(fileURLWithPath: second.path + "/Contents/Info.plist"))
        orphans.load()
        await orphans.job?.value
        #expect(orphans.searchProblem != nil && orphans.items.isEmpty)
        #expect(await apps.leftovers(for: primary, deep: false) == nil)
    }

    @Test func replacedCopiesCannotBePreparedForRemoval() async throws {
        let box = Box()
        let app = try box.app("Applications/Editor.app")
        let copies = AppCopiesModel(folders: [box.home + "/Applications"], runner: CommandRunner(run: { _, _ in (0, "") }, exists: { _ in true }), registered: { _ in [] })
        copies.load()
        await copies.job?.value
        let selected = try #require(copies.report.copies.first)
        try FileManager.default.moveItem(atPath: app.path, toPath: box.home + "/Applications/Previous.app")
        _ = try box.app("Applications/Editor.app")
        #expect(await copies.prepareReview(selected, apps: box.apps()) == nil)
        #expect(copies.problem != nil && !copies.measuring)
    }

    @Test func anUnreadableDiscoveredAppRemainsAnUnknownOwnerDuringRemovalReview() async throws {
        let box = Box()
        let primary = try box.app("Applications/Editor.app")
        let second = try box.app("project/.build/Editor.app")
        try Data("incomplete build metadata".utf8).write(to: URL(fileURLWithPath: second.path + "/Contents/Info.plist"))
        try box.file("Library/Caches/com.example.Editor/cache")
        let copies = AppCopiesModel(folders: [box.home + "/Applications"], runner: CommandRunner(run: { _, _ in (0, second.path) }, exists: { _ in true }), registered: { _ in [] })
        copies.load()
        await copies.job?.value
        #expect(copies.report.unreadable.contains(second.path))
        let selected = try #require(copies.report.copies.first)
        let apps = box.apps()
        #expect(await copies.prepareReview(selected, apps: apps) != nil)
        #expect(await apps.leftovers(for: primary, deep: false) == nil)
    }
}
