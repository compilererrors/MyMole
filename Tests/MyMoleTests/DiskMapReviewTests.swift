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

    @Test func uncheckingListedFoldersClearsTheirPartsAndPreservesChoicesElsewhere() throws {
        let box = try Box()
        let model = box.model()
        let folder = Marked(path: box.home + "/build", name: "Build", size: 1, isFolder: true)
        let child = Marked(path: folder.path + "/large.bin", name: "File", size: 1, isFolder: false)
        let elsewhere = Marked(path: box.home + "/small.txt", name: "Small", size: 1, isFolder: false)
        model.mark([child, elsewhere])
        model.setListedMarks([folder], checked: false)
        #expect(Set(model.marked.keys) == [elsewhere.path])
        model.setListedMarks([folder, child], checked: true)
        #expect(Set(model.marked.keys) == [folder.path, elsewhere.path])
        model.setListedMarks([child], checked: false)
        #expect(Set(model.marked.keys) == [folder.path, elsewhere.path])
    }

    @Test func aBlockedRefreshIsRetiredWithoutJoiningOrRecollecting() async throws {
        let box = try Box()
        let model = box.model()
        let collections = Mutex(0)
        model.collectFiles = { root, stop in
            collections.withLock { $0 += 1 }
            return StorageModel.collectLargeFiles(root, stop: stop)
        }
        model.scan(path: box.home)
        await model.scanJob?.value
        let before = try #require(model.root)
        let listed = model.largeFiles
        #expect(collections.withLock { $0 } == 1)
        let held = DispatchSemaphore(value: 0)
        let read = Atomic(false)
        model.scanFolder = { path, progress, workers, root, subtree, skip in
            let result = StorageScanner.scan(path: path, progress: progress, workers: workers, onRoot: root, onSubtree: subtree, skip: skip)
            read.store(true, ordering: .relaxed)
            held.wait()
            return result
        }
        defer { held.signal() }
        model.rescan()
        try await wait { read.load(ordering: .relaxed) }
        let item = Marked(path: box.home + "/build", name: "Build", size: 1, isFolder: true)
        model.mark([item])
        let reader = model.scanJob
        model.trashMarked()
        try await wait { !model.trashing }
        #expect(model.root === before && !model.scanning && !box.exists("build/large.bin"))
        #expect(collections.withLock { $0 } == 1)
        #expect(!model.largeFiles.contains { $0.path.hasPrefix(item.path + "/") })
        #expect(model.largeFiles.count < listed.count)
        held.signal()
        await reader?.value
        #expect(model.root === before && model.root?.find(path: item.path) == nil)
        #expect(!model.jobs.isBusy)

    }

    @Test func reviewAndMoveDoNotWaitForARetiredReadAndUndoStillRestoresTheFolder() async throws {
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
        let reader = model.scanJob
        model.trashMarked()
        #expect(model.trashing && model.removalPhase == .preparing)
        try await wait { !model.trashing }
        #expect(!box.exists("build") && box.exists("small.txt"))
        let presentation = model.root
        held.signal()
        await reader?.value
        #expect(model.root === presentation && model.root?.find(path: item.path) == nil)
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

    @Test func emptyingAllContentsUpdatesTheWholePresentationBeforeTheRefreshCanRun() async throws {
        let box = try Box()
        let model = box.model()
        model.scan(path: box.home)
        await model.scanJob?.value
        await model.chooseAllContents()
        model.selection = Set(model.marked.keys)
        model.hovered = model.root?.subfolders.first.map(Segment.folder)
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.yield(()); release.finish() }
        let budget = model.scanBudget
        let hold = Task.detached { await budget.run(background: false) { for await _ in stream { break } } }
        try await wait { budget.running == 1 }
        model.trashMarked()
        await model.trashJob?.value
        #expect(model.refreshing && model.scanning)
        #expect(model.current?.path == box.home && model.currentIsEmpty)
        #expect(model.root?.size == 0 && model.root?.fileCount == 0 && model.root?.smallFileCount == 0)
        #expect(model.selection.isEmpty && model.hovered == nil && model.marked.isEmpty)
        release.yield(()); release.finish()
        await hold.value
        await model.scanJob?.value
        #expect(model.currentIsEmpty)
        model.undoTrash()
        try await wait { !model.trashing }
        await model.scanJob?.value
        #expect(!model.currentIsEmpty && model.root?.fileCount == 3)
        #expect(box.exists("build/large.bin") && box.exists("small.txt") && box.exists(".hidden"))
    }

    @Test(arguments: [false, true]) func incompleteRemovalNeverClearsTheRemainingSmallFiles(kept: Bool) async throws {
        let box = try Box()
        let model = box.model()
        model.scan(path: box.home)
        await model.scanJob?.value
        await model.chooseAllContents()
        let remains = box.home + "/.hidden"
        if kept { try CleanKeepList(paths: [remains]).save(to: model.protections.keepList) }
        else { model.unmark([remains]) }
        model.trashMarked()
        await model.trashJob?.value
        await model.scanJob?.value
        #expect(!model.currentIsEmpty && model.current?.smallFileCount == 1)
        #expect(box.exists(".hidden") && !box.exists("small.txt") && !box.exists("build"))
    }

    @Test func removingAnAncestorReturnsToTheNearestSurvivingFolderAndClearsStaleHighlights() async throws {
        let box = try Box()
        let file = box.root.appending(path: "home/build/nested/deep/file.bin")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000_000).write(to: file)
        let model = box.model()
        model.scan(path: box.home)
        await model.scanJob?.value
        let parent = try #require(model.root?.find(path: box.home + "/build"))
        let nested = try #require(model.root?.find(path: parent.path + "/nested"))
        let deep = try #require(model.root?.find(path: nested.path + "/deep"))
        model.open(deep)
        model.selection = [file.path, box.home + "/small.txt"]
        model.treeExpanded = [parent.path, nested.path, deep.path]
        model.hovered = .folder(deep)
        model.mark([.init(path: nested.path, name: nested.name, size: nested.size, isFolder: true)])
        model.trashMarked()
        await model.trashJob?.value
        #expect(model.current === parent && model.hovered == nil)
        #expect(model.selection == [box.home + "/small.txt"] && model.treeExpanded == [parent.path])
        #expect(model.root?.find(path: nested.path) == nil)
        model.undoTrash()
        try await wait { !model.trashing }
        #expect(model.current === parent && model.root?.find(path: nested.path) != nil)
    }

    @Test func aLateUnpublishedBranchCannotChangeTheMapAfterRemoval() async throws {
        let box = try Box()
        let model = box.model()
        let held = DispatchSemaphore(value: 0)
        let entered = Atomic(false)
        let branches = Mutex<(Folder, Folder)?>(nil)
        model.scanFolder = { path, progress, _, publish, subtree, _ in
            let root = Folder(name: "home", parent: nil, rootPath: path)
            let ready = Folder(name: "build", parent: root)
            ready.listedFiles = [FileItem(name: "large.bin", size: 2_000_000, modified: .distantPast, kind: .other)]
            ready.ownBytes[.other] = 2_000_000
            ready.riskListed = true
            ready.finish()
            let pending = Folder(name: "blocked", parent: root)
            let nested = Folder(name: "nested", parent: pending)
            pending.subfolders = [nested]
            root.subfolders = [ready, pending]
            root.riskListed = true
            branches.withLock { $0 = (pending, nested) }
            publish(root)
            subtree(ready)
            entered.store(true, ordering: .releasing)
            held.wait()
            pending.listedFiles = [FileItem(name: "late.bin", size: 9_000_000, modified: .distantPast, kind: .other)]
            pending.ownBytes[.other] = 9_000_000
            pending.finish()
            subtree(pending)
            return ScanResult(root: root, deniedPaths: [], duration: 0, cancelled: progress.isCancelled)
        }
        defer { held.signal() }
        model.scan(path: box.home)
        try await wait { entered.load(ordering: .acquiring) && model.root?.subfolders.first.map { model.isReady($0) } == true }
        let (pending, nested) = try #require(branches.withLock { $0 })
        #expect(!model.isReady(pending) && !model.isReady(nested))
        let original = try #require(model.root)
        model.show(folder: nested.path)
        #expect(model.current === original)
        model.mark([Marked(path: box.home + "/build", name: "Build", size: 2_000_000, isFolder: true)])
        let reader = model.scanJob
        model.trashMarked()
        try await wait { !model.trashing }
        let presentation = try #require(model.root)
        let placeholder = try #require(presentation.find(path: pending.path))
        #expect(presentation !== original && placeholder !== pending && placeholder.wasNotScanned)
        #expect(!model.isReady(placeholder) && model.incomplete && !box.exists("build"))
        held.signal()
        await reader?.value
        #expect(model.root === presentation && placeholder.listedFiles.isEmpty && placeholder.subfolders.isEmpty)
        #expect(presentation.size == 0 && presentation.find(path: box.home + "/build") == nil)
        #expect(!model.scanning && !model.jobs.isBusy)
    }

    @Test func anAdmittedMetadataReaderMustFinishAndScopedStopPreservesOtherJobs() async throws {
        let box = try Box()
        let model = box.model()
        let held = DispatchSemaphore(value: 0)
        let entered = Atomic(false)
        model.collectFiles = { root, stop in
            entered.store(true, ordering: .releasing)
            held.wait()
            return StorageModel.collectLargeFiles(root, stop: stop)
        }
        defer { held.signal() }
        model.scan(path: box.home)
        try await wait { entered.load(ordering: .acquiring) && model.root?.subfolders.first.map { model.isReady($0) } == true }
        model.mark([Marked(path: box.home + "/build", name: "Build", size: 2_000_000, isFolder: true)])
        let other = await model.jobs.begin(.moveToTrash)
        model.trashMarked()
        await Task.yield()
        #expect(model.trashing && model.canStopRemoval && box.exists("build"))
        model.stopRemoval()
        #expect(model.removalStopping && !model.canStopRemoval && !other.isStopped)
        held.signal()
        await model.trashJob?.value
        #expect(!model.trashing && !model.canUndo && box.exists("build/large.bin"))
        #expect(model.jobs.running === other && !other.isStopped)
        model.jobs.end(other)
        #expect(!model.jobs.isBusy)
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
