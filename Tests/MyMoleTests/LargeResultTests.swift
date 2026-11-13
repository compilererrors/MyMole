import AppKit
import Foundation
import StorageKit
import SwiftUI
import Synchronization
import Testing

@testable import MyMole

@MainActor @Suite struct LargeResultTests {
    private final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "large-results-\(UUID().uuidString)")
        var home: String { root.appending(path: "home").path }
        init(files: Int = 3) throws {
            for i in 0..<files {
                let folder = root.appending(path: "home/f\(i)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(repeating: UInt8(i), count: 1_100_000 + i).write(to: folder.appending(path: "big.bin"))
            }
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
            model.mapsOnOpen = home
            return model
        }
    }

    @Test func collectingWithoutALimitKeepsEveryListedFile() throws {
        let box = try Box(files: 4)
        let root = StorageScanner.scan(path: box.home).root
        let all = StorageModel.collectLargeFiles(root, limit: .max)
        #expect(all.count == 4)
        #expect(all.map(\.size) == all.map(\.size).sorted(by: >))
        #expect(StorageModel.collectLargeFiles(root, limit: 2).count == 2)
    }

    @Test func criticalPressureLetsGoOfAMapThatIsntOnScreen() async throws {
        let box = try Box()
        let model = box.model()
        model.scan(path: box.home)
        await model.scanJob?.value
        #expect(model.root != nil)
        model.relieveMemory(critical: false, onScreen: false)
        #expect(model.root != nil, "A warning keeps a finished map")
        model.relieveMemory(critical: true, onScreen: true)
        #expect(model.root != nil, "The map on screen stays")
        model.relieveMemory(critical: true, onScreen: false)
        #expect(model.root == nil && model.largeFiles.isEmpty && model.index == nil)
    }

    @Test func anIdleMapGoesUnlessSomethingDependsOnIt() async throws {
        let box = try Box()
        let model = box.model()
        model.scan(path: box.home)
        await model.scanJob?.value
        let file = try #require(model.largeFiles.first)
        model.mark([file.marked])
        model.releaseIdleMap()
        #expect(model.root != nil, "A map with choices stays")
        model.unmark([file.path])
        model.releaseIdleMap()
        #expect(model.root == nil && model.largeFiles.isEmpty)
    }

    @Test func reliefDoesNothingUnlessItsSettingIsOn() async throws {
        let box = try Box()
        let model = box.model()
        let projects = ProjectsModel(footprints: [], base: box.root, defaults: testDefaults(in: box.root),
                                     logURL: box.root.appending(path: "projects.json"), keepList: box.root.appending(path: "keep.json"))
        model.scan(path: box.home)
        await model.scanJob?.value
        MemoryRelief.relieve(.critical, enabled: false, storage: model, projects: projects, diskMapOnScreen: false)
        #expect(model.root != nil && !model.largeFiles.isEmpty, "Off: a critical event changes nothing")
        MemoryRelief.relieve(.critical, enabled: true, storage: model, projects: projects, diskMapOnScreen: false)
        #expect(model.root == nil)
    }

    @Test func aListPastTheBudgetIsKeptOnDiskAndGoesWithItsResult() async throws {
        let box = try Box(files: 5)
        let model = box.model()
        model.spillBase = box.root.appending(path: "spill")
        model.largeResultBudget = { 1 }
        model.scan(path: box.home)
        await model.scanJob?.value
        let first = try #require(model.largeFilesSpill)
        #expect(model.largeFiles.isEmpty && first.count == 5)
        #expect((0..<5).compactMap { first.row(at: $0)?.size }.allSatisfy { $0 > 1_000_000 })
        // A new scan replaces the table, and the old one's files go.
        model.scan(path: box.home)
        await model.scanJob?.value
        let second = try #require(model.largeFilesSpill)
        #expect(second !== first)
        for _ in 0..<200 where FileManager.default.fileExists(atPath: first.folder.path) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!FileManager.default.fileExists(atPath: first.folder.path))
        // Without a budget everything stays in memory.
        model.largeResultBudget = { nil }
        model.scan(path: box.home)
        await model.scanJob?.value
        #expect(model.largeFilesSpill == nil && model.largeFiles.count == 5)
    }

    @Test func aMovedFileLeavesTheSpilledList() async throws {
        let box = try Box(files: 3)
        let model = box.model()
        model.spillBase = box.root.appending(path: "spill")
        model.largeResultBudget = { 1 }
        model.scan(path: box.home)
        await model.scanJob?.value
        let spill = try #require(model.largeFilesSpill)
        let gone = try #require(spill.row(at: 0))
        let keep = model.spillKeep
        #expect(keep(gone))
        model.mark([Marked(path: gone.path, name: gone.name, size: gone.size, isFolder: false)])
        model.trashMarked()
        await model.trashJob?.value
        #expect(model.spillRemoved == [gone.path])
        #expect(!model.spillKeep(gone) && model.largeFilesSpill === spill)
    }

    @Test func thePagedTableOrdersFromDiskAndKeepsTheSelection() async throws {
        let box = try Box()
        let rows = (0..<3_000).map { i in
            SpillTable.Row(path: "/synthetic/f\(i % 9)/file-\(i).bin", size: Int64((i * 7_919) % 100_003), modified: .distantPast, kind: .other)
        }
        let table = try SpillTable(writing: rows, in: box.root.appending(path: "spill"))
        var selection: Set<String> = [rows[42].path]
        var ordered: [UInt32] = []
        let paged = PagedFileTable(
            table: table, columns: [.name, .size], autosave: "test.paged.\(UUID().uuidString)", filterKey: AnyHashable(1),
            keep: { $0.path.contains("/f3/") },
            selection: Binding(get: { selection }, set: { selection = $0 }), onOrdered: { ordered = $0 })
        let coordinator = paged.makeCoordinator()
        let view = NSTableView()
        for c in [FileColumn.name, .size] { view.addTableColumn(NSTableColumn(identifier: .init(c.rawValue))) }
        view.allowsMultipleSelection = true
        view.sortDescriptors = [NSSortDescriptor(key: FileColumn.size.rawValue, ascending: false)]
        view.dataSource = coordinator
        view.delegate = coordinator
        coordinator.view = view
        coordinator.reorder()
        for _ in 0..<500 where ordered.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let expected = rows.indices.filter { rows[$0].path.contains("/f3/") }
        #expect(ordered.count == expected.count && view.numberOfRows == expected.count)
        let sizes = (0..<ordered.count).compactMap { coordinator.row($0)?.size }
        #expect(sizes == sizes.sorted(by: >))
        // Row 42 is in folder f6, so it's filtered out: nothing stays selected.
        #expect(view.selectedRowIndexes.isEmpty)
        // A selected row that's listed is found again after a new order.
        selection = [rows[3].path]
        let fresh = PagedFileTable(
            table: table, columns: [.name, .size], autosave: paged.autosave, filterKey: AnyHashable(2), keep: { $0.path.contains("/f3/") },
            selection: Binding(get: { selection }, set: { selection = $0 }), onOrdered: { ordered = $0 })
        coordinator.parent = fresh
        ordered = []
        coordinator.reorder()
        for _ in 0..<500 where ordered.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let selectedRow = try #require(view.selectedRowIndexes.first)
        #expect(coordinator.row(selectedRow)?.path == rows[3].path)
    }

    @Test func aChosenMapIsNeverLetGo() async throws {
        let box = try Box()
        let model = box.model()
        model.scan(path: box.home)
        await model.scanJob?.value
        let file = try #require(model.largeFiles.first)
        model.mark([file.marked])
        model.relieveMemory(critical: true, onScreen: false)
        #expect(model.root != nil && !model.marked.isEmpty)
    }

    @Test func pressureStopsAScanStartedAheadOfNeedAndDropsItsPart() async throws {
        let box = try Box()
        let model = box.model()
        let held = DispatchSemaphore(value: 0)
        let reading = Atomic(false)
        model.scanFolder = { path, progress, workers, root, subtree, skip in
            let result = StorageScanner.scan(path: path, progress: progress, workers: workers, onRoot: root, onSubtree: subtree, skip: skip)
            reading.store(true, ordering: .relaxed)
            held.wait()
            return result
        }
        model.scan(path: box.home, background: true)
        for _ in 0..<500 where !reading.load(ordering: .relaxed) { try await Task.sleep(for: .milliseconds(5)) }
        model.relieveMemory(critical: false, onScreen: false)
        held.signal()
        await model.scanJob?.value
        for _ in 0..<500 where model.scanning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.scanning && model.root == nil)
    }

    @Test func aScanTheUserStartedIsNotStopped() async throws {
        let box = try Box()
        let model = box.model()
        let held = DispatchSemaphore(value: 0)
        let reading = Atomic(false)
        model.scanFolder = { path, progress, workers, root, subtree, skip in
            let result = StorageScanner.scan(path: path, progress: progress, workers: workers, onRoot: root, onSubtree: subtree, skip: skip)
            reading.store(true, ordering: .relaxed)
            held.wait()
            return result
        }
        model.scan(path: box.home)
        for _ in 0..<500 where !reading.load(ordering: .relaxed) { try await Task.sleep(for: .milliseconds(5)) }
        model.relieveMemory(critical: true, onScreen: false)
        held.signal()
        await model.scanJob?.value
        for _ in 0..<500 where model.scanning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.root != nil && !model.incomplete)
    }
}
