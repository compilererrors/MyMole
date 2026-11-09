import AppKit
import Foundation
import StorageKit
import Synchronization
import SwiftUI
import Testing

@testable import MyMole
@testable import StorageKit

@MainActor @Suite struct DiskMapReviewTests {
    private final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "disk-review-\(UUID().uuidString)")
        var home: String { root.appending(path: "home").path }
        init() throws {
            try FileManager.default.createDirectory(at: root.appending(path: "home/build"), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 2_000_000).write(to: root.appending(path: "home/build/large.bin"))
            try Data([1]).write(to: root.appending(path: "home/small.txt"))
            try Data([2]).write(to: root.appending(path: "home/.hidden"))
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        @MainActor func model() -> StorageModel {
            let model = StorageModel()
            model.snapshotBase = root.appending(path: "snapshots")
            model.protections = UserProtections(root: root.appending(path: "support"))
            model.logURL = root.appending(path: "history.json")
            model.trashBackend = testBin(root)
            model.jobs = TrashJobs()
            model.scanBudget = ScanBudget(slots: 1)
            return model
        }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home + "/" + path) }
    }

    private func wait(_ check: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "SyntheticReviewTimeout", code: 1)
    }

    @Test func reviewIsImmediateAndAcceptedMoveJoinsTheScanBeforeTouchingFiles() async throws {
        let box = try Box()
        let model = box.model()
        let held = DispatchSemaphore(value: 0)
        let measured = Atomic<Bool>(false)
        model.scanFolder = { path, progress, workers, root, subtree, skip in
            let result = StorageScanner.scan(path: path, progress: progress, workers: workers, onRoot: root, onSubtree: subtree, skip: skip)
            measured.store(true, ordering: .relaxed)
            held.wait()
            return ScanResult(root: result.root, deniedPaths: result.deniedPaths, duration: result.duration, cancelled: progress.isCancelled)
        }
        defer { held.signal() }
        model.scan(path: box.home)
        try await wait { measured.load(ordering: .relaxed) && model.root?.subfolders.first.map { model.isReady($0) } == true }
        let folder = try #require(model.root?.subfolders.first)
        let item = Marked(path: folder.path, name: folder.name, size: folder.size, isFolder: true)
        model.mark([item])
        model.beginTrashReview()
        #expect(model.showReview && model.scanning && model.canTrash)
        #expect(box.exists("build/large.bin"))
        model.showReview = false
        model.trashMarked()
        #expect(model.trashing && model.removalPhase == .preparing)
        await Task.yield()
        #expect(box.exists("build/large.bin"))
        held.signal()
        await model.trashJob?.value
        #expect(!box.exists("build") && box.exists("small.txt"))
        model.undoTrash()
        try await wait { !model.trashing }
        #expect(box.exists("build/large.bin"))
    }

    @Test func allContentsIncludesSmallAndHiddenFilesLeavesParentAndUndoRestoresEverything() async throws {
        let box = try Box()
        let model = box.model()
        model.scan(path: box.home)
        await model.scanJob?.value
        await model.chooseAllContents()
        #expect(Set(model.marked.keys) == [box.home + "/build", box.home + "/small.txt", box.home + "/.hidden"])
        #expect(model.marked[box.home] == nil)
        model.beginTrashReview()
        model.showReview = false
        model.trashMarked()
        try await wait { !model.trashing }
        await model.scanJob?.value
        #expect(!box.exists("build") && !box.exists("small.txt") && !box.exists(".hidden"))
        #expect(FileManager.default.fileExists(atPath: box.home))
        model.undoTrash()
        try await wait { !model.trashing }
        await model.scanJob?.value
        #expect(box.exists("build/large.bin") && box.exists("small.txt") && box.exists(".hidden"))
        #expect(model.root?.fileCount == 3)
    }

    @Test func anAcceptedMoveCanBeStoppedWhileWaitingWithoutTouchingFiles() async throws {
        let box = try Box()
        let model = box.model()
        model.scan(path: box.home)
        await model.scanJob?.value
        await model.chooseAllContents()
        let other = await model.jobs.begin(.moveToTrash)
        model.trashMarked()
        #expect(model.trashing)
        try await wait { model.jobs.waiting == 1 }
        model.jobs.stop()
        model.jobs.end(other)
        await model.trashJob?.value
        #expect(!model.trashing && !model.canUndo && !model.jobs.isBusy)
        #expect(box.exists("build/large.bin") && box.exists("small.txt") && box.exists(".hidden"))
    }

    @Test func missingAdvisoryHintsNeverBypassUnreadableProtectionsInTheWorker() async throws {
        let box = try Box()
        let model = box.model()
        model.scan(path: box.home)
        await model.scanJob?.value
        await model.chooseAllContents()
        try FileManager.default.createDirectory(at: model.protections.keepList.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: model.protections.keepList)
        #expect(model.currentRemovalHints == nil && model.canTrash)
        model.trashMarked()
        await model.trashJob?.value
        #expect(!model.canUndo)
        #expect(box.exists("build/large.bin") && box.exists("small.txt") && box.exists(".hidden"))
    }

    @Test func sortRequestRevealsDateColumnAndSortsWithoutOverridingLaterHeaderActions() {
        let selection = Binding<Set<String>>(get: { [] }, set: { _ in })
        var view = FileTable(rows: [], columns: [.name, .modified], autosave: "synthetic-review-sort", selection: selection)
        let coordinator = FileTable.Coordinator(view)
        let table = FileTableView()
        let name = NSTableColumn(identifier: .init("name"))
        let date = NSTableColumn(identifier: .init("modified"))
        date.isHidden = true
        table.addTableColumn(name)
        table.addTableColumn(date)
        coordinator.table = table
        view.sortRequest = .init(column: .modified, ascending: true)
        coordinator.parent = view
        coordinator.applySortRequest()
        #expect(!date.isHidden && table.sortDescriptors.first?.key == "modified" && table.sortDescriptors.first?.ascending == true)
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        coordinator.applySortRequest()
        #expect(table.sortDescriptors.first?.key == "name")
    }

    @Test func aBulkChoiceDoesNotRemoveAReplacementFileOrAnItemKeptAfterSelection() async throws {
        let box = try Box()
        let model = box.model()
        model.scan(path: box.home)
        await model.scanJob?.value
        await model.chooseAllContents()
        let small = URL(fileURLWithPath: box.home + "/small.txt")
        try FileManager.default.moveItem(at: small, to: box.root.appending(path: "original.txt"))
        try Data([8]).write(to: small)
        try CleanKeepList(paths: [box.home + "/.hidden"]).save(to: model.protections.keepList)
        model.beginTrashReview()
        model.showReview = false
        model.trashMarked()
        try await wait { !model.trashing }
        #expect(!box.exists("build"))
        #expect(try Data(contentsOf: small) == Data([8]))
        #expect(box.exists(".hidden"))
    }

    @Test func aNewMapInvalidatesAReviewWaitingForAnOlderScan() async throws {
        let box = try Box()
        let model = box.model()
        let held = DispatchSemaphore(value: 0)
        let entered = Atomic<Bool>(false)
        let count = Mutex(0)
        model.scanFolder = { path, progress, workers, root, subtree, skip in
            let n = count.withLock { n in defer { n += 1 }; return n }
            let result = StorageScanner.scan(path: path, progress: progress, workers: workers, onRoot: root, onSubtree: subtree, skip: skip)
            if n == 0 {
                entered.store(true, ordering: .relaxed)
                held.wait()
            }
            return ScanResult(root: result.root, deniedPaths: result.deniedPaths, duration: result.duration, cancelled: progress.isCancelled)
        }
        defer { held.signal() }
        model.scan(path: box.home)
        try await wait { entered.load(ordering: .relaxed) && model.root?.subfolders.first.map { model.isReady($0) } == true }
        model.mark([Marked(path: box.home + "/build", name: "build", size: 2_000_000, isFolder: true)])
        model.beginTrashReview()
        await Task.yield()
        model.scan(path: box.home + "/build")
        held.signal()
        await model.scanJob?.value
        #expect(!model.showReview && model.marked.isEmpty && model.root?.path == box.home + "/build")
        #expect(box.exists("build/large.bin"))
    }
}
