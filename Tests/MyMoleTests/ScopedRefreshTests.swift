import Foundation
import StorageKit
import Synchronization
import Testing

@testable import MyMole

@MainActor @Suite(.serialized) struct ScopedRefreshTests {
    private final class Files {
        let root = FileManager.default.temporaryDirectory.appending(path: "scoped-refresh-\(UUID().uuidString)")
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit {
            StoreWrites.flush()
            try? FileManager.default.removeItem(at: root)
        }
        func path(_ relative: String) -> String { root.appending(path: relative).path }
        func add(_ relative: String) throws {
            let file = root.appending(path: relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 2_000_000).write(to: file)
        }
        @MainActor func storage() -> StorageModel {
            let model = StorageModel()
            model.snapshotBase = root.appending(path: "snapshots")
            model.protections = UserProtections(root: root.appending(path: "protection"))
            model.readSpace = { _ in nil }
            return model
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "The synthetic refresh did not finish")
    }

    @Test func diskRefreshReadsOnlyTheOpenFolderAndRetainsTheEnclosingMap() async throws {
        let files = try Files()
        try files.add("Map/Projects/Sample/original.bin")
        try files.add("Map/Music/original.bin")
        let model = files.storage()
        model.scan(path: files.path("Map"))
        await model.scanJob?.value
        let before = try #require(model.root)
        let sibling = try #require(before.find(path: files.path("Map/Music")))
        let folder = try #require(before.find(path: files.path("Map/Projects/Sample")))
        let originalSize = before.size
        let siblingSize = sibling.size
        model.open(folder)
        model.selection = [files.path("Map/Projects/Sample/original.bin")]
        model.treeExpanded = [files.path("Map/Projects")]
        model.marked = [sibling.path: .init(path: sibling.path, name: sibling.name, size: sibling.size, isFolder: true)]
        try files.add("Map/Projects/Sample/added.bin")
        try files.add("Map/Music/not-refreshed.bin")
        let reads = Mutex<[String]>([])
        model.scanSubfolder = { path, progress, workers, skips, kind in
            reads.withLock { $0.append(path) }
            return StorageScanner.scan(path: path, progress: progress, workers: workers, skip: skips, inheritedKind: kind)
        }

        model.refreshCurrent()
        #expect(model.root === before && model.refreshing)
        await model.scanJob?.value
        let updated = try #require(model.root)
        #expect(reads.withLock { $0 } == [folder.path])
        #expect(model.rootPath == files.path("Map"))
        #expect(model.current?.path == folder.path)
        #expect(model.lineage.map(\.path) == [files.path("Map"), files.path("Map/Projects"), folder.path])
        #expect(updated.find(path: sibling.path)?.size == siblingSize)
        #expect(updated.find(path: sibling.path)?.listedFiles.count == 1)
        #expect(updated.size > originalSize)
        #expect(before.size == originalSize)
        #expect(model.selection == [files.path("Map/Projects/Sample/original.bin")])
        #expect(model.marked[sibling.path] != nil)
        #expect(model.treeExpanded.contains(files.path("Map/Projects")))
        #expect(model.largeFiles.contains { $0.path == files.path("Map/Projects/Sample/added.bin") })
        let index = try #require(model.index)
        #expect(index.search("added.bin").found.contains { index.path($0) == files.path("Map/Projects/Sample/added.bin") })
        #expect(!model.scanning && !model.refreshing)

        model.rescan()
        await model.scanJob?.value
        #expect(model.root?.find(path: sibling.path)?.listedFiles.count == 2)
        #expect(model.current?.path == folder.path)
    }

    @Test func aStoppedLocalScanCannotOverwriteANewerFullScan() async throws {
        let files = try Files()
        try files.add("Map/Folder/original.bin")
        let model = files.storage()
        model.scan(path: files.path("Map"))
        await model.scanJob?.value
        model.open(try #require(model.root?.find(path: files.path("Map/Folder"))))
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        model.scanSubfolder = { path, progress, workers, skips, kind in
            let old = StorageScanner.scan(path: path, progress: progress, workers: workers, skip: skips, inheritedKind: kind)
            entered.withLock { $0 = true }
            release.wait()
            return old
        }
        model.refreshCurrent()
        let oldJob = model.scanJob
        try await wait { entered.withLock { $0 } }
        model.cancelScan()
        try files.add("Map/Folder/newer.bin")
        model.rescan()
        await model.scanJob?.value
        let newest = try #require(model.root)
        release.signal()
        await oldJob?.value
        #expect(model.root === newest)
        #expect(model.current?.listedFiles.count == 2)
        #expect(!model.scanning && !model.refreshing)
    }

    @Test func aFailedLocalReadKeepsThePreviousFolder() async throws {
        let files = try Files()
        try files.add("Map/Folder/original.bin")
        let model = files.storage()
        model.scan(path: files.path("Map"))
        await model.scanJob?.value
        let original = try #require(model.root)
        model.open(try #require(original.find(path: files.path("Map/Folder"))))
        model.scanSubfolder = { path, progress, workers, _, _ in
            StorageScanner.scan(path: path + "/missing", progress: progress, workers: workers)
        }
        model.refreshCurrent()
        await model.scanJob?.value
        #expect(model.root === original)
        #expect(model.current?.listedFiles.count == 1)
        #expect(model.notice != nil)
    }

    @Test func removalRetiresALocalRefreshWithoutPublishingItsPreparedMap() async throws {
        let files = try Files()
        try files.add("Map/Folder/original.bin")
        let model = files.storage()
        model.trashBackend = testBin(files.root)
        model.jobs = TrashJobs()
        model.scan(path: files.path("Map"))
        await model.scanJob?.value
        let original = try #require(model.root)
        model.open(try #require(original.find(path: files.path("Map/Folder"))))
        let entered = Mutex(false)
        model.collectFiles = { _, stopped in
            entered.withLock { $0 = true }
            while !stopped() { Thread.sleep(forTimeInterval: 0.001) }
            return []
        }
        model.refreshCurrent()
        let refresh = model.scanJob
        try await wait { entered.withLock { $0 } }
        let path = files.path("Map/Folder/original.bin")
        model.mark([.init(path: path, name: "original.bin", size: 2_000_000, isFolder: false)])
        model.trashMarked()
        await model.trashJob?.value
        await refresh?.value
        #expect(model.root === original)
        #expect(!model.scanning && !model.trashing)
        #expect(model.current?.listedFiles.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func mapWideSectionsRefreshTheWholeMapEvenAfterBrowsingIntoAFolder() async throws {
        let files = try Files()
        try files.add("Map/Folder/original.bin")
        try files.add("Map/Other/original.bin")
        let model = files.storage()
        model.scan(path: files.path("Map"))
        await model.scanJob?.value
        model.open(try #require(model.root?.find(path: files.path("Map/Folder"))))
        try files.add("Map/Other/added.bin")
        model.tab = .largeFiles
        #expect(model.refreshTitle == "Rescan Entire Map")
        model.refreshCurrent()
        await model.scanJob?.value
        #expect(model.largeFiles.contains { $0.path == files.path("Map/Other/added.bin") })
        #expect(model.current?.path == files.path("Map/Folder"))
    }

    @Test func diskInfoReadsLeaveScanningResponsiveAndKeepOnlyTheNewestPendingRead() async throws {
        let files = try Files()
        for name in ["First", "Middle", "Latest"] { try files.add(name + "/file.bin") }
        let model = files.storage()
        let reads = Mutex<[String]>([])
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        model.readSpace = { path in
            let first = reads.withLock { log in log.append(path); return log.count == 1 }
            if first { release.wait() }
            return DiskSpace(total: 10_000, used: path.hasSuffix("Latest") ? 3_000 : 1_000, purgeable: 0, snapshots: [])
        }
        model.scan(path: files.path("First"))
        await model.scanJob?.value
        try await wait { reads.withLock { !$0.isEmpty } }
        model.scan(path: files.path("Middle"))
        await model.scanJob?.value
        model.scan(path: files.path("Latest"))
        await model.scanJob?.value
        #expect(model.current?.path == files.path("Latest"))
        release.signal()
        try await wait { model.diskSpace?.used == 3_000 }
        #expect(reads.withLock { $0 } == [files.path("First"), files.path("Latest")])
    }

    private func project(_ files: Files, _ name: String) throws -> (ProjectFootprint, Folder) {
        try files.add(name + "/.build/Target/original.bin")
        try files.add(name + "/.build/Other/original.bin")
        let entry = files.path(name + "/.build")
        let tree = StorageScanner.scan(path: entry, workers: 2).root
        let item = FootprintItem(id: entry, category: .build, title: ".build", location: files.path(name), attribution: .inside,
                                 entries: [.init(path: entry, bytes: tree.size, modified: tree.latestChange, isDirectory: true)])
        return (ProjectFootprint(project: .init(path: files.path(name), markers: ["Package.swift"]), items: [item]), tree)
    }

    private func projects(_ files: Files, _ footprints: [ProjectFootprint]) -> ProjectsModel {
        let store = files.root.appending(path: "store")
        return ProjectsModel(footprints: footprints, base: store, defaults: testDefaults(in: store),
                             logURL: store.appending(path: "history.json"), keepList: store.appending(path: "keep.json"))
    }

    @Test func projectFolderRefreshLeavesSiblingsAndOtherProjectsUnmeasured() async throws {
        let files = try Files()
        let (first, tree) = try project(files, "Sample")
        let (second, _) = try project(files, "Another")
        let model = projects(files, [first, second])
        let entry = files.path("Sample/.build")
        let target = entry + "/Target"
        model.contents[entry] = tree
        model.selection = [first.id]
        model.folderFocus = .init(project: first.id, entry: entry, path: target)
        model.chosen = [target, files.path("Another/.build")]
        let oldSiblingSize = try #require(tree.find(path: entry + "/Other")?.size)
        try files.add("Sample/.build/Target/added.bin")
        try files.add("Sample/.build/Other/not-refreshed.bin")
        try files.add("Another/.build/Target/not-refreshed.bin")
        let reads = Mutex<[String]>([])
        model.scanContentsForRefresh = { path, progress, workers, kind in
            reads.withLock { $0.append(path) }
            return StorageScanner.scan(path: path, progress: progress, workers: workers, inheritedKind: kind)
        }
        #expect(model.refreshTitle == "Refresh Current Folder")
        model.refreshCurrent()
        #expect(model.refreshing && model.trashBlocker != nil)
        await model.contentsRefreshJob?.value
        #expect(reads.withLock { $0 } == [target])
        #expect(model.contents[entry]?.find(path: target)?.listedFiles.count == 2)
        #expect(model.contents[entry]?.find(path: entry + "/Other")?.size == oldSiblingSize)
        #expect(model.footprint(first.id)?.bytes ?? 0 > first.bytes)
        #expect(model.footprint(second.id) == second)
        #expect(model.selection == [first.id])
        #expect(model.folderFocus?.path == target)
        #expect(!model.chosen.contains(target) && model.chosen.contains(files.path("Another/.build")))
        #expect(!model.refreshing && model.scannedAt == nil && model.history.isEmpty)
    }

    @Test func projectRefreshMeasuresOneProjectWhileFullScanStillMeasuresAll() async throws {
        let files = try Files()
        let (first, _) = try project(files, "Sample")
        let (second, _) = try project(files, "Another")
        let model = projects(files, [first, second])
        let measured = Mutex<[String]>([])
        model.measureProject = { project, _, _ in
            measured.withLock { $0.append(project.path) }
            return first
        }
        model.selection = [first.id]
        #expect(model.refreshTitle == "Refresh Current Project")
        model.refreshCurrent()
        try await wait { !model.refreshing }
        #expect(measured.withLock { $0 } == [first.id])
        #expect(model.footprint(second.id) == second)

        let listed = Mutex(0)
        model.listProjects = { _, _, _, _, _, _ in
            listed.withLock { $0 += 1 }
            return ProjectListing(footprints: [first, second])
        }
        model.scan()
        await model.scanJob?.value
        try await wait { !model.scanning }
        #expect(listed.withLock { $0 } == 1)
        #expect(model.footprints.count == 2)
        #expect(model.selection == [first.id])
        try await wait { !model.history.isEmpty }
    }

    @Test func cancelledProjectFolderRefreshCannotPublishItsOldRead() async throws {
        let files = try Files()
        let (first, tree) = try project(files, "Sample")
        let model = projects(files, [first])
        let entry = files.path("Sample/.build")
        model.contents[entry] = tree
        model.selection = [first.id]
        model.folderFocus = .init(project: first.id, entry: entry, path: entry + "/Target")
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        model.scanContentsForRefresh = { path, progress, workers, kind in
            let old = StorageScanner.scan(path: path, progress: progress, workers: workers, inheritedKind: kind)
            entered.withLock { $0 = true }
            release.wait()
            return old
        }
        model.refreshCurrent()
        let old = model.contentsRefreshJob
        try await wait { entered.withLock { $0 } }
        model.stop()
        #expect(!model.refreshing)
        release.signal()
        await old?.value
        #expect(model.contents[entry] === tree)
        #expect(model.footprint(first.id) == first)
        #expect(model.loadingContents[entry] == nil)
    }

    @Test func invalidatingAnEntryDuringRefreshDoesNotLeaveThePaneBusy() async throws {
        let files = try Files()
        let (first, tree) = try project(files, "Sample")
        let model = projects(files, [first])
        let entry = files.path("Sample/.build")
        let target = entry + "/Target"
        model.contents[entry] = tree
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        model.scanContentsForRefresh = { path, progress, workers, kind in
            let result = StorageScanner.scan(path: path, progress: progress, workers: workers, inheritedKind: kind)
            entered.withLock { $0 = true }
            release.wait()
            return result
        }
        model.refreshFolder(.init(project: first.id, entry: entry, path: target))
        let job = model.contentsRefreshJob
        try await wait { entered.withLock { $0 } }
        model.scanIfNeeded()
        #expect(!model.scanning && model.refreshingContents != nil)
        model.dropContents(touching: [target])
        release.signal()
        await job?.value
        #expect(!model.refreshing && model.contentsRefreshJob == nil)
        #expect(model.contents[entry] == nil)
        #expect(model.footprint(first.id) == first)
    }
}
