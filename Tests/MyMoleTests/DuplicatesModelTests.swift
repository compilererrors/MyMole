import Foundation
import StorageKit
import Synchronization
import Testing

@testable import MyMole

/// The Duplicates pane on folders of the test's own.
@MainActor
@Suite struct DuplicatesModelTests {
    final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "duplicates-\(UUID().uuidString)")
        var home: String { root.appending(path: "home").path }
        var log: URL { root.appending(path: "history.json") }

        deinit { try? FileManager.default.removeItem(at: root) }

        func file(_ rel: String, fill: UInt8, bytes: Int = 40_000) throws {
            let url = URL(fileURLWithPath: home + "/" + rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: fill, count: bytes).write(to: url)
        }

        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: home + "/" + rel) }

        @MainActor func model(standardRoots: Bool = false, budget: ScanBudget = ScanBudget(slots: 1), search: @escaping DuplicatesModel.Search = DuplicatesModel.liveSearch) -> DuplicatesModel {
            let roots = standardRoots ? DuplicateFinder.standardRoots(home: home) : [home + "/Documents", home + "/Downloads"]
            let m = DuplicatesModel(home: home, roots: roots, minimum: 10_000, logURL: log, trash: testBin(root), scanBudget: budget, search: search)
            m.jobs = TrashJobs()
            m.protections = UserProtections(root: root.appending(path: "lists"))
            return m
        }
    }

    private func waitUntil(_ ready: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if ready() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return ready()
    }

    @Test func firstOpeningSearchesFoldersCreatedAfterInitializationAndDoesNotRestart() async throws {
        let box = Box()
        let model = box.model(standardRoots: true)
        try box.file("Documents/example.bin", fill: 2)
        try box.file("Downloads/example.bin", fill: 2)
        model.scanIfNeeded()
        await model.scanJob?.value
        #expect(model.groups.count == 1 && model.attempted && model.chosen.isEmpty)
        let completed = model.scannedAt
        model.scanIfNeeded()
        #expect(!model.scanning && model.scannedAt == completed)
    }

    @Test func stoppedQueuedSearchDoesNotBorrowAnotherScansSlotOrRestartOnOpening() async throws {
        let box = Box()
        let budget = ScanBudget(slots: 1)
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.yield(()); release.finish() }
        let hold = Task.detached {
            await budget.run(background: true) { for await _ in stream { break } }
        }
        try #require(await waitUntil { budget.running == 1 })
        let model = box.model(budget: budget)
        model.scanIfNeeded()
        try #require(await waitUntil { budget.waiting == 1 })
        #expect(model.step?.phase == .waiting)
        model.stop()
        await model.scanJob?.value
        #expect(!model.scanning && budget.waiting == 0 && budget.running == 1)
        model.scanIfNeeded()
        #expect(!model.scanning && model.scannedAt == nil && model.attempted)
        release.yield(()); release.finish()
        await hold.value
    }

    @Test func verifiedGroupsAppearBeforeCompletionButCannotBeChosenAndStopDiscardsThem() async throws {
        let box = Box()
        try box.file("Documents/example.bin", fill: 2)
        try box.file("Downloads/example.bin", fill: 2)
        let model = box.model(search: { roots, minimum, progress, workers, step, group in
            let found = DuplicatesModel.liveSearch(roots, minimum, progress, workers, step, group)
            let end = ContinuousClock.now + .seconds(5)
            while !progress.isCancelled && ContinuousClock.now < end { Thread.sleep(forTimeInterval: 0.01) }
            return found
        })
        model.scan()
        defer { model.stop() }
        try #require(await waitUntil { !model.preview.isEmpty })
        #expect(model.scanning && model.groups.isEmpty && model.displayGroups.count == 1)
        model.toggle(try #require(model.preview.first?.files.first?.path))
        model.chooseAll(keeping: .oldest)
        #expect(model.chosen.isEmpty)
        model.stop()
        await model.scanJob?.value
        #expect(model.preview.isEmpty && model.displayGroups.isEmpty && model.scannedAt == nil)
    }

    @Test func aLateSearchCannotReplaceANewerResult() async throws {
        let box = Box()
        try box.file("Documents/example.bin", fill: 2)
        try box.file("Downloads/example.bin", fill: 2)
        let state = Mutex((calls: 0, release: false))
        let model = box.model(budget: ScanBudget(slots: 2), search: { roots, minimum, progress, workers, step, group in
            let first = state.withLock { s in s.calls += 1; return s.calls == 1 }
            let found = DuplicatesModel.liveSearch(roots, minimum, progress, workers, step, group)
            if first {
                let end = ContinuousClock.now + .seconds(10)
                while !state.withLock({ $0.release }), ContinuousClock.now < end { Thread.sleep(forTimeInterval: 0.01) }
            }
            return found
        })
        defer { state.withLock { $0.release = true }; model.stop() }
        model.scan()
        let old = model.scanJob
        try #require(await waitUntil { !model.preview.isEmpty })
        try box.file("Downloads/example.bin", fill: 9)
        model.scan()
        await model.scanJob?.value
        let completed = try #require(model.scannedAt)
        #expect(model.groups.isEmpty && !model.scanning)
        state.withLock { $0.release = true }
        await old?.value
        #expect(model.groups.isEmpty && model.preview.isEmpty && model.scannedAt == completed)
    }

    @Test func aRescanCannotPreserveChoicesThatWouldSelectEveryMemberOfANewGroup() async throws {
        let box = Box()
        for (name, fill) in [("first", UInt8(1)), ("second", UInt8(2))] {
            try box.file("Documents/\(name).bin", fill: fill)
            try box.file("Downloads/\(name).bin", fill: fill)
        }
        let model = box.model()
        model.scan()
        await model.scanJob?.value
        #expect(model.groups.count == 2)
        model.selection = []
        model.chooseAll(keeping: .oldest)
        let picked = model.chosen
        try #require(picked.count == 2)
        for path in picked { try Data(repeating: 9, count: 40_000).write(to: URL(fileURLWithPath: path)) }
        model.scan()
        await model.scanJob?.value
        let group = try #require(model.groups.first)
        #expect(model.groups.count == 1 && Set(group.files.map(\.path)) == picked)
        #expect(model.chosen.count == 1)
        #expect(group.files.contains { !model.chosen.contains($0.path) })
    }

    private func searched(_ box: Box) async throws -> DuplicatesModel {
        try box.file("Documents/report.bin", fill: 1)
        try box.file("Downloads/report.bin", fill: 1)
        try box.file("Downloads/report copy.bin", fill: 1)
        try box.file("Documents/other.bin", fill: 2)
        let model = box.model()
        model.scan()
        await model.scanJob?.value
        return model
    }

    @Test func oneCopyOfEveryGroupAlwaysStays() async throws {
        let box = Box()
        let model = try await searched(box)
        let group = try #require(model.groups.first)
        #expect(model.groups.count == 1 && group.files.count == 3 && model.spareBytes == 2 * group.bytes)
        #expect(model.selection == [group.id])

        // Two of three can be ticked; the third is refused, and says why.
        let paths = group.files.map(\.path)
        model.toggle(paths[0])
        model.toggle(paths[1])
        model.toggle(paths[2])
        #expect(model.chosen == [paths[0], paths[1]] && model.notice != nil)

        // Choosing all but one in one go keeps exactly one.
        model.chooseAll(keeping: .newest)
        #expect(model.chosen.count == 2 && !model.chosen.contains(group.files.last!.path))
        model.chooseAll(keeping: .oldest)
        #expect(model.chosen.count == 2 && !model.chosen.contains(group.files.first!.path))
    }

    @Test func theChosenCopiesGoToTheTrashAndUndoPutsThemBack() async throws {
        let box = Box()
        let model = try await searched(box)
        let group = try #require(model.groups.first)
        model.chooseAll(keeping: .oldest)
        let going = model.chosen

        model.trashChosen()
        await model.trashJob?.value
        #expect(going.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        #expect(FileManager.default.fileExists(atPath: group.files[0].path) && box.exists("Documents/other.bin"))
        // With one copy left it isn't a duplicate any more.
        #expect(model.groups.isEmpty && model.chosen.isEmpty && model.canUndo)
        let record = try #require(CleanupLog.load(from: box.log).first)
        #expect(record.source == DuplicatesModel.source && record.items == 2 && record.bytes == 2 * group.bytes)

        model.undoTrash(run: record.id)
        await model.trashJob?.value
        await model.scanJob?.value
        #expect(going.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        #expect(model.groups.count == 1 && model.groups[0].files.count == 3 && !model.canUndo)
        #expect(CleanupLog.load(from: box.log).first?.restored == 2)
    }

    @Test func aCopyIsLeftWhenTheOneThatWasToStayChanged() async throws {
        let box = Box()
        let model = try await searched(box)
        let group = try #require(model.groups.first)
        model.chooseAll(keeping: .oldest)
        // The copy that stays is rewritten after the search: the others aren't spare any more.
        try Data(repeating: 9, count: 40_000).write(to: URL(fileURLWithPath: group.files[0].path))

        model.trashChosen()
        await model.trashJob?.value
        #expect(group.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(!model.canUndo && model.notice?.text.hasPrefix("Nothing was moved") == true)
    }

    @Test func theCopyInAChosenFolderStays() async throws {
        let box = Box()
        let model = try await searched(box)
        model.chooseAll(keeping: .inFolder(box.home + "/Documents"))
        #expect(model.chosen == [box.home + "/Downloads/report.bin", box.home + "/Downloads/report copy.bin"])
        // A folder with no copy of the file chooses nothing of it.
        model.chosen = []
        model.chooseAll(keeping: .inFolder(box.home + "/Elsewhere"))
        #expect(model.chosen.isEmpty && model.notice != nil)
    }

    @Test func aKeepSavedElsewhereIsMarkedHereAtOnce() async throws {
        let box = Box()
        let model = try await searched(box)
        let copy = box.home + "/Downloads/report.bin"
        model.choose([copy])
        #expect(model.chosen.contains(copy))
        // Another pane keeps it: no new search is needed for it to stay.
        _ = try CleanKeepList.update(at: model.protections.keepList) { $0.paths.insert(copy) }
        for _ in 0..<200 where model.chosen.contains(copy) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.chosen.contains(copy) && model.keep.protects(copy))
    }
}
