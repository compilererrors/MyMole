import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing

@testable import MyMole
@testable import StorageKit

@MainActor @Suite struct DiskOutlineTests {
    @MainActor private final class Harness {
        var root: Folder
        var revision = 1
        var selection = Set<String>()
        var expanded = Set<String>()
        var marks: Set<String>? = []
        var chosen: [DiskEntry] = []
        var ready: (Folder) -> Bool = { _ in true }
        var sorter: @Sendable ([FileRow], FileColumn, Bool) -> [FileRow] = { FileTable.sorted($0, by: $1, ascending: $2) }
        let state = DiskOutline.State()
        let outline = DiskOutlineView()
        lazy var coordinator = DiskOutline.Coordinator(view)

        init(_ root: Folder) { self.root = root }

        var view: DiskOutline {
            DiskOutline(root: root, revision: revision, ready: ready, state: state,
                        selection: Binding(get: { self.selection }, set: { self.selection = $0 }),
                        expanded: Binding(get: { self.expanded }, set: { self.expanded = $0 }), marks: marks,
                        row: { FileRow(id: $0.path, name: $0.name, size: $0.pending ? nil : $0.size) },
                        onToggle: { self.chosen = [$0] }, onOpen: { _ in }, onMark: { self.chosen = $0 },
                        onSetMarks: { entries, _ in self.chosen = entries },
                        onHover: { _ in }, menu: { _, _ in [] }, onSmallFiles: { _ in }, sortRows: sorter)
        }

        func start() {
            let name = NSTableColumn(identifier: .init("name"))
            outline.addTableColumn(name)
            outline.outlineTableColumn = name
            outline.addTableColumn(NSTableColumn(identifier: .init("size")))
            outline.allowsMultipleSelection = true
            outline.dataSource = coordinator
            outline.delegate = coordinator
            outline.coordinator = coordinator
            coordinator.outline = outline
            coordinator.rebuild()
        }

        func refresh() {
            coordinator.parent = view
            coordinator.rebuild()
        }

        func stop() { coordinator.stop() }
    }

    private func root(_ name: String = "tree", count: Int = 2) -> Folder {
        let root = Folder(name: name, parent: nil, rootPath: "/synthetic/\(name)")
        for i in 0..<count {
            let folder = Folder(name: "folder\(i)", parent: root)
            let nested = Folder(name: "nested", parent: folder)
            nested.listedFiles = [FileItem(name: "data.bin", size: 2_000_000, modified: .distantPast, kind: .other)]
            nested.ownBytes[.other] = 2_000_000
            folder.subfolders = [nested]
            folder.smallFileCount = 3
            folder.smallFileBytes = 300
            folder.ownBytes[.other] = 300
            root.subfolders.append(folder)
        }
        root.finish()
        return root
    }

    @Test func checkAllCoversListedParentsOnceAndAnOutsideContainingChoiceStaysProtected() async throws {
        let h = Harness(root())
        defer { h.stop() }
        h.start()
        await h.coordinator.job?.value
        let top = try #require(h.coordinator.rootNode?.children?.first)
        h.outline.expandItem(top)
        await h.coordinator.job?.value
        h.coordinator.setListedMarks(true)
        #expect(Set(h.chosen.map(\.path)) == Set(h.root.subfolders.map(\.path)))
        h.chosen = []
        h.marks = [h.root.path]
        h.coordinator.parent = h.view
        h.coordinator.setListedMarks(false)
        #expect(h.chosen.isEmpty && h.marks == [h.root.path])
    }

    @Test func openingBranchesIsLazyAndTheirRowsCanBeSelectedAndChosen() async throws {
        let h = Harness(root())
        defer { h.stop() }
        h.start()
        await h.coordinator.job?.value
        let top = try #require(h.coordinator.rootNode?.children?.first)
        #expect(top.children == nil && h.state.visible.count == 2)
        h.outline.expandItem(top)
        await h.coordinator.job?.value
        let nested = try #require(top.children?.first(where: { $0.folder != nil }))
        #expect(top.children?.contains(where: \.smallFiles) == true)
        #expect(nested.children == nil)
        h.outline.expandItem(nested)
        await h.coordinator.job?.value
        let file = try #require(nested.children?.first?.entry)
        h.selection = [file.path]
        h.coordinator.select(force: true)
        #expect(h.coordinator.previewURLs.map(\.path) == [file.path])
        h.coordinator.mark()
        #expect(h.chosen.map(\.path) == [file.path])
        #expect(h.expanded == [top.path, nested.path])
        #expect(h.coordinator.rootNode?.children?.last?.children == nil)
    }

    @Test func replacingTheTreeReopensItsBranchesAndCollapsingReleasesRows() async throws {
        let h = Harness(root())
        defer { h.stop() }
        h.start()
        await h.coordinator.job?.value
        let old = try #require(h.coordinator.rootNode?.children?.first)
        h.outline.expandItem(old)
        await h.coordinator.job?.value
        let nested = try #require(old.children?.first(where: { $0.folder != nil }))
        h.outline.expandItem(nested)
        await h.coordinator.job?.value
        h.selection = [nested.path + "/data.bin"]
        h.root = root()
        h.revision += 1
        h.refresh()
        await h.coordinator.job?.value
        let fresh = try #require(h.coordinator.rootNode?.children?.first(where: { $0.path == old.path }))
        #expect(fresh !== old && h.outline.isItemExpanded(fresh))
        let child = try #require(fresh.children?.first(where: { $0.folder != nil }))
        #expect(h.outline.isItemExpanded(child))
        #expect(h.coordinator.previewURLs.map(\.path) == [nested.path + "/data.bin"])
        h.outline.collapseItem(fresh)
        #expect(fresh.children == nil)
        #expect(!h.expanded.contains(fresh.path) && h.expanded.contains(child.path))
    }

    @Test func pendingBranchesStayClosedAndReadOnlyRowsCannotBeChosen() async throws {
        let h = Harness(root())
        defer { h.stop() }
        h.ready = { $0.parent == nil }
        h.marks = nil
        h.start()
        await h.coordinator.job?.value
        let top = try #require(h.coordinator.rootNode?.children?.first)
        #expect(top.entry?.pending == true)
        #expect(!h.coordinator.outlineView(h.outline, isItemExpandable: top))
        h.selection = [top.path]
        h.coordinator.select(force: true)
        h.coordinator.mark()
        #expect(h.chosen.isEmpty && top.children == nil)
    }

    @Test func aSlowOldSortCannotOverwriteANewerMapOrSpawnMoreSorters() async throws {
        let h = Harness(root("older", count: 1_024))
        defer { h.stop() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = Atomic<Int>(0)
        h.sorter = { rows, col, asc in
            let call = calls.add(1, ordering: .relaxed).newValue
            if call == 1 { _ = release.wait(timeout: .now() + 5) }
            return FileTable.sorted(rows, by: col, ascending: asc)
        }
        h.start()
        try #require(await waitUntil { calls.load(ordering: .relaxed) == 1 })
        h.root = root("newer", count: 1_025)
        h.revision += 1
        h.refresh()
        await Task.yield()
        #expect(calls.load(ordering: .relaxed) == 1)
        release.signal()
        await h.coordinator.job?.value
        #expect(h.state.rootID == h.root.id && h.state.visible.count == 1_025)
        #expect(h.state.visible.allSatisfy { $0.path.hasPrefix("/synthetic/newer/") })
        #expect(calls.load(ordering: .relaxed) == 2)
    }

    @Test func preparingAReplacementKeepsEarlierRowsButBlocksTheirRemoval() async throws {
        let h = Harness(root(count: 1_024))
        defer { h.stop() }
        h.start()
        await h.coordinator.job?.value
        let earlier = try #require(h.coordinator.rootNode)
        let path = try #require(earlier.children?.first?.path)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let sorting = Atomic<Bool>(false)
        h.sorter = { rows, col, asc in
            sorting.store(true, ordering: .relaxed)
            _ = release.wait(timeout: .now() + 5)
            return FileTable.sorted(rows, by: col, ascending: asc)
        }
        h.root = root(count: 1_025)
        h.revision += 1
        h.refresh()
        try #require(await waitUntil { sorting.load(ordering: .relaxed) })
        #expect(h.coordinator.rootNode === earlier && h.outline.numberOfRows == 1_024)
        h.selection = [path]
        h.coordinator.select(force: true)
        h.coordinator.mark()
        #expect(h.chosen.isEmpty)
        release.signal()
        await h.coordinator.job?.value
        #expect(h.coordinator.rootNode !== earlier && h.outline.numberOfRows == 1_025)
        h.coordinator.mark()
        #expect(h.chosen.map(\.path) == [path])
    }

    @Test func aChildIncludedByAChosenFolderShowsACheckedDisabledBox() async throws {
        let h = Harness(root())
        defer { h.stop() }
        h.start()
        await h.coordinator.job?.value
        let folder = try #require(h.coordinator.rootNode?.children?.first)
        h.outline.expandItem(folder)
        await h.coordinator.job?.value
        let child = try #require(folder.children?.first(where: { $0.folder != nil }))
        h.marks = [folder.path]
        h.coordinator.parent = h.view
        let cell = try #require(h.coordinator.outlineView(h.outline, viewFor: h.outline.outlineTableColumn, item: child) as? FileNameCell)
        let check = try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
        #expect(check.state == .on && !check.isEnabled)
        #expect(check.toolTip?.contains("Unchoose") == true)
        h.selection = [child.path]
        h.coordinator.select(force: true)
        h.coordinator.mark()
        #expect(h.chosen.isEmpty)
    }

    @Test func choosingAParentReplacesChildChoicesAndUnchoosingItLeavesNothingChosen() {
        let model = StorageModel()
        let parent = Marked(path: "/synthetic/tree/folder", name: "folder", size: 3_000, isFolder: true)
        let child = Marked(path: parent.path + "/file.bin", name: "file.bin", size: 1_000, isFolder: false)
        model.mark([child])
        model.mark([parent, child])
        #expect(Set(model.marked.keys) == [parent.path] && model.markedBytes == parent.size)
        #expect(Marked.parent(of: child.path, in: Set(model.marked.keys)) == parent.path)
        #expect(Marked.parent(of: "/synthetic/tree/folder-other/file.bin", in: [parent.path]) == nil)
        model.toggle(parent)
        #expect(model.marked.isEmpty)
    }

    private func waitUntil(_ ready: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if ready() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return ready()
    }
}
