import Foundation
import StorageKit
import Synchronization
import Testing

@testable import MyMole

@MainActor @Suite struct RemovedAppTests {
    @Test func finderContinuationRequiresTheOriginalObjectInTrashRatherThanAMatchingNameOrID() throws {
        let box = Box()
        let original = try box.app("Applications/Editor.app", id: "com.example.Editor")
        let source = try #require(RemovedApp.Source.capture(original))
        try box.app(".Trash/Editor.app", id: "com.example.Editor")
        #expect(source.movedToTrash(home: box.home) == nil)
        let moved = box.home + "/.Trash/Editor 2.app"
        try FileManager.default.moveItem(atPath: original.path, toPath: moved)
        #expect(source.movedToTrash(home: box.home)?.app.path == moved)
        try FileManager.default.moveItem(atPath: moved, toPath: box.home + "/Elsewhere.app")
        try FileManager.default.createSymbolicLink(atPath: moved, withDestinationPath: box.home + "/Elsewhere.app")
        #expect(source.movedToTrash(home: box.home) == nil)
    }

    @Test func changedBundleIdentityCannotResumeTheOriginalReview() throws {
        let box = Box()
        let app = try box.app("Applications/Editor.app", id: "com.example.Editor")
        let source = try #require(RemovedApp.Source.capture(app))
        try FileManager.default.createDirectory(atPath: box.home + "/.Trash", withIntermediateDirectories: true)
        let moved = box.home + "/.Trash/Editor.app"
        try FileManager.default.moveItem(atPath: app.path, toPath: moved)
        try (["CFBundleIdentifier": "com.example.Other", "CFBundleName": "Other"] as NSDictionary)
            .write(to: URL(fileURLWithPath: moved + "/Contents/Info.plist"))
        #expect(source.movedToTrash(home: box.home) == nil)
    }

    @Test func restoreProofRequiresTheSameBundleAVacantDestinationAndItsOriginalParent() throws {
        let box = Box()
        let app = try box.app("Applications/Editor.app", id: "com.example.Editor")
        let source = try #require(RemovedApp.Source.capture(app))
        try box.app(".Trash/Older.app", id: "com.example.Other")
        let record = TrashRecord(original: URL(fileURLWithPath: app.path), trashed: box.root.appending(path: ".Trash/Editor 2.app"))
        try FileManager.default.moveItem(atPath: app.path, toPath: record.trashed.path)
        #expect(source.canRestore(record, from: record.trashed.path, home: box.home))
        #expect(!source.canRestore(record, from: box.home + "/.Trash/Older.app", home: box.home))
        try box.file("Applications/Editor.app/new")
        #expect(!source.canRestore(record, from: record.trashed.path, home: box.home))
        #expect(source.restoreLocationIsCurrent(record.trashed.path, record: record, home: box.home))
    }

    @Test func restoreProofCanTrackAnIntermediateNameButNeverAnUnrelatedLocation() throws {
        let box = Box()
        let app = try box.app("Applications/Editor.app", id: "com.example.Editor")
        let source = try #require(RemovedApp.Source.capture(app))
        try box.file(".Trash/placeholder")
        let record = TrashRecord(original: URL(fileURLWithPath: app.path), trashed: box.root.appending(path: ".Trash/Editor 2.app"))
        try FileManager.default.moveItem(atPath: app.path, toPath: record.trashed.path)
        try box.file("Applications/Editor 2.app/collision")
        #expect(!source.canRestore(record, from: record.trashed.path, home: box.home))
        try FileManager.default.moveItem(atPath: box.home + "/Applications/Editor 2.app", toPath: box.home + "/SavedCollision.app")
        let intermediate = box.home + "/Applications/Editor 2.app"
        try FileManager.default.moveItem(atPath: record.trashed.path, toPath: intermediate)
        #expect(source.canRestore(record, from: intermediate, home: box.home))
        try FileManager.default.moveItem(atPath: intermediate, toPath: box.home + "/Elsewhere.app")
        #expect(!source.canRestore(record, from: box.home + "/Elsewhere.app", home: box.home))
        try FileManager.default.moveItem(atPath: box.home + "/Elsewhere.app", toPath: app.path)
        #expect(source.isAtOriginalPath)
    }

    @Test(arguments: [false, true]) func restoreProofRejectsARecreatedOrLinkedOriginalParent(link: Bool) throws {
        let box = Box()
        let app = try box.app("Applications/Editor.app", id: "com.example.Editor")
        let source = try #require(RemovedApp.Source.capture(app))
        try box.file(".Trash/placeholder")
        let record = TrashRecord(original: URL(fileURLWithPath: app.path), trashed: box.root.appending(path: ".Trash/Editor.app"))
        try FileManager.default.moveItem(atPath: app.path, toPath: record.trashed.path)
        try FileManager.default.moveItem(atPath: box.home + "/Applications", toPath: box.home + "/SavedApplications")
        if link {
            try FileManager.default.createSymbolicLink(atPath: box.home + "/Applications", withDestinationPath: box.home + "/SavedApplications")
        } else {
            try FileManager.default.createDirectory(atPath: box.home + "/Applications", withIntermediateDirectories: true)
        }
        #expect(!source.canRestore(record, from: record.trashed.path, home: box.home))
        #expect(!source.isAtOriginalPath)
    }

    private final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "removed-app-\(UUID().uuidString)")
        var home: String { root.path }
        let group = "FAKE123456.com.example.shared"
        deinit { try? FileManager.default.removeItem(at: root) }

        func file(_ path: String) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 4096).write(to: url)
        }

        @discardableResult func app(_ path: String, id: String) throws -> AppBundle {
            try file(path + "/Contents/MacOS/bin")
            try (["CFBundleIdentifier": id, "CFBundleName": "Editor"] as NSDictionary)
                .write(to: root.appending(path: path + "/Contents/Info.plist"))
            return AppFinder.metadata(home + "/" + path)!
        }

        func proof() throws -> RemovedApp {
            try app(".Trash/Editor.app", id: "com.example.Editor")
            try app("Applications/Viewer.app", id: "com.example.Viewer")
            try app(".Trash/Editor.app/Contents/XPCServices/Worker.xpc", id: "com.example.Editor.Worker")
            try file("Library/Caches/com.example.Editor.Worker/cache")
            try file("Library/Containers/com.example.Editor/data")
            try file("Library/Preferences/com.example.Editor.plist")
            try file("Library/Group Containers/" + group + "/data")
            return try #require(RemovedApp.read(path: home + "/.Trash/Editor.app", home: home))
        }

        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home + "/" + path) }

        @MainActor func model(readers: AppIdentity.Readers? = nil, scanBudget: ScanBudget = .shared) -> AppsModel {
            let group = group
            let model = AppsModel(
                home: home, folders: [home + "/Applications"], base: root.appending(path: "store"), logURL: root.appending(path: "history.json"),
                recycle: { _ in Issue.record("The removed bundle must never be recycled"); return TrashOutcome(moved: [], failed: []) },
                isRunning: { _ in false }, otherCopies: { _ in [] }, trash: testBin(root),
                protections: UserProtections(root: root.appending(path: "lists")), scanBudget: scanBudget,
                identityReaders: readers ?? .init(groups: { _ in [group] }))
            model.jobs = TrashJobs()
            return model
        }
    }

    @Test func verifiedSearchFindsAnAppsOwnFilesWhileProtectingItsVendorsSharedGroup() async throws {
        let box = Box()
        let proof = try box.proof()
        let model = box.model()
        // The name-only search deliberately protects every file of this installed vendor.
        let installed = try #require(AppFinder.installedNow(in: [box.home + "/Applications"]))
        #expect(Orphans.find(home: box.home, installed: installed, known: { _ in false }, running: []).isEmpty)
        let found = try #require(await model.leftovers(for: proof, deep: false))
        #expect(Set(found.map(\.place)) == ["Caches", "Containers", "Preferences"])
        #expect(!found.contains { $0.path.contains(box.group) })
        let picked = found.filter(\.chosenByDefault)
        #expect(picked.count == 1 && picked.first?.place == "Caches")
        #expect(await model.cleanRemovedApp(proof, leftovers: picked) == .done)
        #expect(box.exists(".Trash/Editor.app/Contents/Info.plist"))
        #expect(!box.exists("Library/Caches/com.example.Editor.Worker"))
        #expect(box.exists("Library/Containers/com.example.Editor/data") && box.exists("Library/Preferences/com.example.Editor.plist"))
        #expect(box.exists("Library/Group Containers/" + box.group + "/data"))
        model.undoUninstall()
        await model.undoJob?.value
        #expect(box.exists("Library/Caches/com.example.Editor.Worker/cache"))
        #expect(proof.isCurrent(home: box.home))
        #expect(CleanupLog.load(from: box.root.appending(path: "history.json")).contains { $0.source == OrphansModel.source })
    }

    @Test(arguments: [false, true]) func restoringOrReplacingTheTrashedAppInvalidatesItsReview(replace: Bool) async throws {
        let box = Box()
        let proof = try box.proof()
        let model = box.model()
        let found = try #require(await model.leftovers(for: proof, deep: false))
        try FileManager.default.moveItem(atPath: proof.app.path, toPath: box.home + "/Applications/Restored.app")
        if replace { try box.app(".Trash/Editor.app", id: "com.example.Editor") }
        #expect(!proof.isCurrent(home: box.home))
        #expect(await model.leftovers(for: proof, deep: false) == nil)
        if case .done = await model.cleanRemovedApp(proof, leftovers: found) { Issue.record("Invalid proof authorized removal") }
        #expect(box.exists("Library/Caches/com.example.Editor.Worker/cache"))
    }

    @Test func reinstallingWhileTheMoveWaitsProtectsEveryLeftover() async throws {
        let box = Box()
        let proof = try box.proof()
        let model = box.model()
        let found = try #require(await model.leftovers(for: proof, deep: false))
        let blocker = await model.jobs.begin(.moveToTrash)
        let move = Task { await model.cleanRemovedApp(proof, leftovers: found) }
        for _ in 0..<100 where !model.uninstalling { try await Task.sleep(for: .milliseconds(5)) }
        try box.app("Applications/Reinstalled.app", id: "com.example.Editor")
        model.jobs.end(blocker)
        if case .done = await move.value { Issue.record("Reinstalled app lost its data") }
        #expect(box.exists("Library/Caches/com.example.Editor.Worker/cache"))
        #expect(box.exists("Library/Containers/com.example.Editor/data"))
    }

    @Test func aNewGroupOwnerWhileQueuedAndUnreadableOwnershipBothPreventRemoval() async throws {
        let box = Box()
        let proof = try box.proof()
        let claimed = Mutex(false)
        let group = box.group
        let model = box.model(readers: .init(groups: { path in
            path.contains("/.Trash/") || claimed.withLock({ $0 }) ? [group] : []
        }))
        let found = try #require(await model.leftovers(for: proof, deep: false))
        let shared = try #require(found.first { $0.path.contains(group) })
        let blocker = await model.jobs.begin(.moveToTrash)
        let move = Task { await model.cleanRemovedApp(proof, leftovers: [shared]) }
        for _ in 0..<100 where !model.uninstalling { try await Task.sleep(for: .milliseconds(5)) }
        claimed.withLock { $0 = true }
        model.jobs.end(blocker)
        if case .done = await move.value { Issue.record("Shared data moved") }
        #expect(box.exists("Library/Group Containers/" + group + "/data"))
        let unknown = box.model(readers: .init(carried: { _ in nil }, groups: { _ in [] }))
        #expect(await unknown.leftovers(for: proof, deep: false) == nil)
        if case .done = await unknown.cleanRemovedApp(proof, leftovers: found) { Issue.record("Unknown ownership authorized removal") }
        #expect(box.exists("Library/Caches/com.example.Editor.Worker/cache"))
    }

    @Test func linkedBundlesAndAppsOutsideTheTrashArentProof() throws {
        let box = Box()
        let proof = try box.proof()
        try FileManager.default.createSymbolicLink(atPath: box.home + "/.Trash/Linked.app", withDestinationPath: proof.app.path)
        #expect(RemovedApp.read(path: box.home + "/.Trash/Linked.app", home: box.home) == nil)
        #expect(RemovedApp.read(path: box.home + "/Applications/Viewer.app", home: box.home) == nil)
    }

    @Test func temporaryAccessEndsWithItsReviewAndOnlyStartedGrantsAreStopped() {
        let url = URL(fileURLWithPath: "/synthetic/.Trash/Editor.app")
        var starts = 0, stops = 0
        var access: RemovedAppAccess? = RemovedAppAccess(url, start: { _ in starts += 1; return true }, stop: { _ in stops += 1 })
        withExtendedLifetime(access) { #expect(starts == 1 && stops == 0) }
        access = nil
        #expect(stops == 1)
        access = RemovedAppAccess(url, start: { _ in starts += 1; return false }, stop: { _ in stops += 1 })
        withExtendedLifetime(access) { #expect(starts == 2 && stops == 1) }
        access = nil
        #expect(stops == 1)
    }

    @Test func keptDataIsRecheckedBeforeMovingVerifiedLeftovers() async throws {
        let box = Box()
        let proof = try box.proof()
        let model = box.model()
        let found = try #require(await model.leftovers(for: proof, deep: false))
        let cache = try #require(found.first { $0.place == "Caches" })
        let protections = UserProtections(root: box.root.appending(path: "lists"))
        _ = try CleanKeepList.update(at: protections.keepList) { $0.paths.insert(cache.path + "/cache") }
        if case .done = await model.cleanRemovedApp(proof, leftovers: [cache]) { Issue.record("A kept child lost its folder") }
        #expect(box.exists("Library/Caches/com.example.Editor.Worker/cache"))
    }

    @Test func closingAReviewCancelsItsQueuedWalkWithoutBorrowingAnotherScansSlot() async throws {
        let box = Box()
        let proof = try box.proof()
        let budget = ScanBudget(slots: 1)
        let model = box.model(scanBudget: budget)
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.yield(()); release.finish() }
        let hold = Task.detached { await budget.run(background: false) { for await _ in stream { break } } }
        for _ in 0..<100 where budget.running == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(budget.running == 1)
        let search = Task { await model.leftovers(for: proof, deep: true) }
        for _ in 0..<100 where budget.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(budget.waiting == 1)
        search.cancel()
        #expect(await search.value == nil)
        #expect(budget.waiting == 0 && budget.running == 1)
        release.yield(()); release.finish()
        _ = await hold.value
        #expect(box.exists("Library/Caches/com.example.Editor.Worker/cache"))
    }
}
