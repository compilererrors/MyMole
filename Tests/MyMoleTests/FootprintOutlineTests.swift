import AppKit
import SwiftUI
import Synchronization
import Testing

@testable import MyMole
@testable import StorageKit

@MainActor @Suite struct FootprintOutlineTests {
    @MainActor private final class Fixture {
        let base = FileManager.default.temporaryDirectory.appending(path: "project-outline-\(UUID().uuidString)")
        let model: ProjectsModel
        var footprint: ProjectFootprint
        let outline = FootprintOutlineView()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 240))
        var sorter: @Sendable ([FileRow], FileColumn, Bool) -> [FileRow] = { FileTable.sorted($0, by: $1, ascending: $2) }
        lazy var coordinator = view.makeCoordinator()
        var view: FootprintOutline {
            FootprintOutline(model: model, footprint: footprint, chosen: [], age: .any,
                             measured: Set(model.contents.keys), contentsRevision: model.contentsRevision, menu: { target in
                                 switch target {
                                 case .item(let item): FileActions.menu(item.entries.map(\.path), canOpen: false)
                                 case .path(_, let path): FileActions.menu([path], canOpen: false)
                                 }
                             }, sortRows: sorter)
        }
        var entry: String { base.appending(path: "Sample/.build").path }

        init() throws {
            let path = base.appending(path: "Sample/.build")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let item = FootprintItem(id: "build", category: .build, title: ".build", location: path.deletingLastPathComponent().path,
                                     attribution: .inside, entries: [FootprintEntry(path: path.path, bytes: 400_000_000, modified: .distantPast)])
            footprint = ProjectFootprint(project: DevProject(path: path.deletingLastPathComponent().path, markers: ["Package.swift"]), items: [item])
            let store = base.appending(path: "store")
            model = ProjectsModel(footprints: [footprint], base: store, defaults: testDefaults(in: store),
                                  logURL: store.appending(path: "history.json"), keepList: store.appending(path: "keep.json"))
            let name = NSTableColumn(identifier: .init("name"))
            name.width = 900
            outline.addTableColumn(name)
            outline.outlineTableColumn = name
            outline.allowsMultipleSelection = true
            scroll.documentView = outline
            scroll.hasHorizontalScroller = true
            outline.configureUserColumns()
            name.width = 900
            outline.updateScrollableWidth()
        }
        deinit { try? FileManager.default.removeItem(at: base) }

        func tree(count: Int = 200, excluding: Int? = nil) -> Folder {
            let root = Folder(name: ".build", parent: nil, rootPath: entry)
            for i in 0..<count where i != excluding {
                let folder = Folder(name: String(format: "folder-%03d", i), parent: root)
                folder.ownBytes[.other] = 2_000_000
                folder.smallFileCount = 1
                folder.smallFileBytes = 2_000_000
                root.subfolders.append(folder)
            }
            root.finish()
            return root
        }

        func start() {
            model.contents[entry] = tree()
            outline.dataSource = coordinator
            outline.delegate = coordinator
            outline.coordinator = coordinator
            coordinator.outline = outline
            coordinator.rebuild()
        }
    }

    @Test func expandingAndSelectingFoldersScopesRefreshToTheirContents() throws {
        let h = try Fixture()
        h.start()
        h.model.selection = [h.footprint.id]
        let entry = try #require(h.outline.item(atRow: 1) as? FootprintOutline.Node)
        h.outline.expandItem(entry)
        #expect(h.model.folderFocus?.path == h.entry)
        let folder = try #require(entry.children?.first)
        h.outline.selectRowIndexes(IndexSet(integer: h.outline.row(forItem: folder)), byExtendingSelection: false)
        #expect(h.model.folderFocus?.entry == h.entry)
        #expect(h.model.folderFocus?.path == folder.path)
        #expect(h.model.refreshTitle == "Refresh Current Folder")
        h.model.selection = []
        #expect(h.model.folderFocus == nil)
        #expect(h.model.refreshTitle == "Scan All Projects")
    }

    @Test func aVisibleBranchCanStillBeRefreshedAfterItsCacheEntryWasEvicted() throws {
        let h = try Fixture()
        h.start()
        h.model.selection = [h.footprint.id]
        let entry = try #require(h.outline.item(atRow: 1) as? FootprintOutline.Node)
        h.outline.expandItem(entry)
        let folder = try #require(entry.children?.first)
        let measured = try #require(h.model.contents[h.entry])
        h.model.contents[h.entry] = nil
        h.model.contentsOrder.removeAll { $0 == h.entry }
        h.outline.selectRowIndexes(IndexSet(integer: h.outline.row(forItem: folder)), byExtendingSelection: false)
        #expect(h.model.folderFocus?.path == folder.path)
        #expect(h.model.contents[h.entry] === measured)
    }

    @Test func deletingASiblingRetainsOpenNodesSelectedRowsAndScrollWithoutReplacingTheTable() throws {
        let h = try Fixture()
        h.start()
        let item = try #require(h.outline.item(atRow: 1) as? FootprintOutline.Node)
        h.outline.expandItem(item)
        let target = try #require(item.children?.first { $0.path?.hasSuffix("folder-080") == true })
        h.outline.expandItem(target)
        h.outline.selectRowIndexes(IndexSet(integer: h.outline.row(forItem: target)), byExtendingSelection: false)
        h.scroll.contentView.scroll(to: NSPoint(x: 100, y: h.outline.rect(ofRow: h.outline.row(forItem: target)).minY + 3))
        let oldOffset = h.outline.rect(ofRow: h.outline.row(forItem: target)).minY - h.scroll.contentView.bounds.minY
        h.model.contents[h.entry] = h.tree(excluding: 0)
        h.model.contentsRevision += 1
        h.coordinator.parent = h.view
        h.coordinator.rebuild()
        #expect(h.outline.item(atRow: 1) as? FootprintOutline.Node === item)
        #expect(item.children?.first { $0.key == target.key } === target)
        #expect(h.outline.isItemExpanded(item) && h.outline.isItemExpanded(target))
        #expect(h.outline.item(atRow: h.outline.selectedRow) as? FootprintOutline.Node === target)
        #expect(abs(h.outline.rect(ofRow: h.outline.row(forItem: target)).minY - h.scroll.contentView.bounds.minY - oldOffset) < 1)
        #expect(h.outline.tableColumns[0].width == 900)
        #expect(h.scroll.contentView.bounds.minX == 100)
        #expect(item.children?.contains { $0.path?.hasSuffix("folder-000") == true } == false)
    }

    @Test(arguments: [Density.compact, .spacious]) func firstPresentationAndExpansionUseCorrectNativeRowAndCellHeights(_ density: Density) throws {
        let previous = Density.current
        defer { Density.current = previous }
        Density.current = density
        let h = try Fixture()
        h.outline.style = DS.Table.style
        h.outline.configureRows(height: DS.Table.compactRow)
        h.outline.intercellSpacing = NSSize(width: DS.Table.columnGap(.grid), height: 0)
        h.start()
        let item = try #require(h.outline.item(atRow: 1) as? FootprintOutline.Node)
        for phase in 0..<2 {
            if phase == 1 { h.outline.expandItem(item) }
            h.outline.layoutSubtreeIfNeeded()
            for row in 0..<min(h.outline.numberOfRows, 12) {
                let node = try #require(h.outline.item(atRow: row))
                let expected = h.coordinator.outlineView(h.outline, heightOfRowByItem: node)
                let rect = h.outline.rect(ofRow: row)
                #expect(abs(rect.height - expected) < 0.5)
                if row > 0 { #expect(abs(rect.minY - h.outline.rect(ofRow: row - 1).maxY) < 0.5) }
                let cell = try #require(h.outline.view(atColumn: 0, row: row, makeIfNecessary: true))
                cell.layoutSubtreeIfNeeded()
                #expect(cell.frame.height <= rect.height + 0.5)
                for label in cell.subviews.compactMap({ $0 as? NSTextField }) where !label.isHidden {
                    #expect(label.frame.minY >= -0.5 && label.frame.maxY <= cell.bounds.height + 0.5)
                }
            }
        }
    }

    @Test func sortingAnAlreadyOpenedBranchReordersChildrenAndKeepsSelectionAndPixelPosition() throws {
        let h = try Fixture()
        h.start()
        let item = try #require(h.outline.item(atRow: 1) as? FootprintOutline.Node)
        h.outline.expandItem(item)
        let selected = try #require(item.children?.first { $0.path?.hasSuffix("folder-080") == true })
        h.outline.selectRowIndexes(IndexSet(integer: h.outline.row(forItem: selected)), byExtendingSelection: false)
        h.scroll.contentView.scroll(to: NSPoint(x: 100, y: h.outline.rect(ofRow: h.outline.row(forItem: selected)).minY + 3))
        let offset = h.outline.rect(ofRow: h.outline.row(forItem: selected)).minY - h.scroll.contentView.bounds.minY
        h.outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        #expect(item.children?.first?.path?.hasSuffix("folder-199") == true)
        #expect(h.outline.item(atRow: h.outline.selectedRow) as? FootprintOutline.Node === selected)
        #expect(abs(h.outline.rect(ofRow: h.outline.row(forItem: selected)).minY - h.scroll.contentView.bounds.minY - offset) < 1)
        #expect(h.scroll.contentView.bounds.minX == 100)
    }

    @Test func largeBranchSortingRunsOneWorkerAndOnlyTheNewestOrderLandsWhileMenusStayUsable() async throws {
        let h = try Fixture()
        defer { h.coordinator.sorting.stop() }
        h.start()
        let tree = h.tree(count: 10_000)
        h.model.contents[h.entry] = tree
        h.model.contentsRevision += 1
        h.coordinator.parent = h.view
        h.coordinator.rebuild()
        let item = try #require(h.outline.item(atRow: 1) as? FootprintOutline.Node)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let calls = Atomic<Int>(0)
        let offMain = Atomic<Bool>(false)
        h.sorter = { rows, column, ascending in
            if rows.count > 512 {
                offMain.store(!Thread.isMainThread, ordering: .relaxed)
                if calls.add(1, ordering: .relaxed).newValue == 1 { gate.wait() }
            }
            return FileTable.sorted(rows, by: column, ascending: ascending)
        }
        h.coordinator.parent = h.view
        h.outline.expandItem(item)
        for _ in 0..<200 where calls.load(ordering: .relaxed) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(calls.load(ordering: .relaxed) == 1)
        let selected = try #require(item.children?.first)
        h.outline.selectRowIndexes(IndexSet(integer: h.outline.row(forItem: selected)), byExtendingSelection: false)
        h.outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        h.outline.sortDescriptors = [NSSortDescriptor(key: "modified", ascending: true)]
        h.outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        for _ in 0..<20 {
            let menu = h.coordinator.keyboardMenu()
            #expect(menu.items.contains { $0.title == "Show in Finder" })
            #expect(menu.items.contains { $0.title == "Columns" })
        }
        #expect(calls.load(ordering: .relaxed) == 1 && offMain.load(ordering: .relaxed))
        gate.signal()
        await h.coordinator.sorting.job?.value
        #expect(calls.load(ordering: .relaxed) == 2)
        #expect(item.children?.first?.path?.hasSuffix("folder-9999") == true)
        #expect(h.outline.item(atRow: h.outline.selectedRow) as? FootprintOutline.Node === selected)
    }

    @Test func anOlderSortCannotReplaceTheRefreshedContentsOfTheSameBranch() async throws {
        let h = try Fixture()
        defer { h.coordinator.sorting.stop() }
        h.start()
        h.model.contents[h.entry] = h.tree(count: 1_000)
        h.model.contentsRevision += 1
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let started = Atomic<Bool>(false)
        h.sorter = { rows, column, ascending in
            if rows.count > 512 {
                started.store(true, ordering: .relaxed)
                gate.wait()
            }
            return FileTable.sorted(rows, by: column, ascending: ascending)
        }
        h.coordinator.parent = h.view
        h.coordinator.rebuild()
        let item = try #require(h.outline.item(atRow: 1) as? FootprintOutline.Node)
        h.outline.expandItem(item)
        for _ in 0..<200 where !started.load(ordering: .relaxed) { try await Task.sleep(for: .milliseconds(5)) }
        let didStart = started.load(ordering: .relaxed)
        try #require(didStart)

        h.model.contents[h.entry] = h.tree(count: 20)
        h.model.contentsRevision += 1
        h.coordinator.parent = h.view
        h.coordinator.rebuild()
        let fresh = try #require(item.children)
        #expect(fresh.count == 20)
        gate.signal()
        await h.coordinator.sorting.job?.value
        #expect(item.children?.map(\.key) == fresh.map(\.key))
        #expect(h.outline.numberOfRows == 22)
    }

    @Test func anInvalidatedReadCannotResurrectContentsOrClearTheNewRead() async throws {
        let h = try Fixture()
        let started = Atomic<Int>(0)
        let old = DispatchSemaphore(value: 0)
        let fresh = DispatchSemaphore(value: 0)
        defer { old.signal(); fresh.signal() }
        let staleTree = h.tree()
        let freshTree = h.tree(excluding: 0)
        h.model.readContents = { _, _ in
            if started.add(1, ordering: .relaxed).newValue == 1 {
                old.wait()
                return staleTree
            }
            fresh.wait()
            return freshTree
        }
        h.model.loadContents(h.entry)
        for _ in 0..<200 where started.load(ordering: .relaxed) < 1 { try await Task.sleep(for: .milliseconds(5)) }
        h.model.dropContents(touching: [h.entry + "/folder-000"])
        h.model.loadContents(h.entry)
        for _ in 0..<200 where started.load(ordering: .relaxed) < 2 { try await Task.sleep(for: .milliseconds(5)) }
        old.signal()
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.model.contents[h.entry] == nil && h.model.loadingContents[h.entry] != nil)
        fresh.signal()
        for _ in 0..<200 where h.model.loadingContents[h.entry] != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(h.model.contents[h.entry] === freshTree)
    }

    @Test func refreshingAnOpenBranchRetainsItsRowsButDisablesOldRemovalChoices() async throws {
        let h = try Fixture()
        h.start()
        let item = try #require(h.outline.item(atRow: 1) as? FootprintOutline.Node)
        h.outline.expandItem(item)
        let target = try #require(item.children?.first)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let replacement = h.tree(excluding: 0)
        h.model.readContents = { _, _ in gate.wait(); return replacement }
        h.model.dropContents(touching: [h.entry + "/folder-000"])
        h.coordinator.parent = h.view
        h.coordinator.rebuild()
        #expect(item.children?.first === target && h.outline.isItemExpanded(item))
        h.coordinator.toggle(target)
        #expect(h.model.chosen.isEmpty)
        let cell = try #require(h.coordinator.outlineView(h.outline, viewFor: h.outline.outlineTableColumn, item: target))
        let check = try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
        #expect(!check.isEnabled && check.toolTip == "Refreshing folder contents…")
        gate.signal()
        for _ in 0..<200 where h.model.loadingContents[h.entry] != nil { try await Task.sleep(for: .milliseconds(5)) }
        h.coordinator.parent = h.view
        h.coordinator.rebuild()
        #expect(item.children?.contains { $0.path?.hasSuffix("folder-000") == true } == false)
    }
}
