import AppKit
import StorageKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor final class UINativeTableFixture {
    let ui: UIInteractionWindow
    let table = FileTableView()
    let scroll = NSScrollView()
    let coordinator: FileTable.Coordinator
    let state = UITableInteractionState()
    var selection: Set<String> { state.selection }
    var marks: Set<String> { state.marks }
    private var fitting: [NSObjectProtocol] = []

    init(defaults: UserDefaults, count: Int = 2_000) async throws {
        let rows = (0..<count).map { FileRow(id: "synthetic-\($0)", name: String(format: "Synthetic item %05d", $0),
                                          size: Int64($0 + 1) * 1_024, kind: "Generated fixture", location: "/synthetic/generated") }
        let state = self.state
        let parent = FileTable(rows: rows, columns: [.name, .size, .kind, .location], autosave: "",
                               selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
                               onMark: { state.marks.formUnion($0) })
        coordinator = parent.makeCoordinator()
        ui = UIInteractionWindow(Text("Synthetic table"), width: 1_100, height: 640)
        table.coordinator = coordinator
        table.configureRows(height: 40)
        table.allowsMultipleSelection = true
        for field in parent.columns {
            let column = UIMeasuredTableColumn(identifier: .init(field.rawValue))
            column.title = field.title
            column.minWidth = field.width.min
            column.maxWidth = field.width.max
            column.width = field.width.ideal
            column.sortDescriptorPrototype = NSSortDescriptor(key: field.rawValue, ascending: field.ascendingFirst)
            table.addTableColumn(column)
        }
        table.delegate = coordinator
        table.dataSource = coordinator
        coordinator.table = table
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        ui.window.contentView = scroll
        table.configureUserColumns()
        coordinator.bindWindow(nil)
        coordinator.setPresentationActive(true)
        coordinator.load(rows, marks: nil, selection: [])
        await coordinator.sortJob?.value
        fitting = table.keepFitting("name", defaults: defaults)
        scroll.layoutSubtreeIfNeeded()
        ui.window.displayIfNeeded()
        try #require(table.numberOfRows == count)
    }

    func close() {
        coordinator.stopSorting()
        coordinator.stopPresentation()
        NSTableView.stopFitting(&fitting)
        ui.close()
    }

    func invokeMenu(_ title: String, direct: Bool = false) throws {
        let menu = table.columnVisibilityMenu()
        let item = try #require(menu.items.first { $0.title == title })
        try #require(item.isEnabled)
        if direct {
            try #require(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        } else {
            menu.performActionForItem(at: menu.index(of: item))
        }
    }

    func resizeColumn(_ index: Int, by delta: CGFloat) throws {
        let header = try #require(table.headerView)
        let rect = header.headerRect(ofColumn: index)
        try ui.trackMouse(in: header, from: NSPoint(x: rect.maxX, y: rect.midY),
                          through: (1...8).map { NSPoint(x: rect.maxX + delta * CGFloat($0) / 8, y: rect.midY) })
    }

    func reorderColumn(_ index: Int, to destination: Int) throws {
        let header = try #require(table.headerView)
        let source = header.headerRect(ofColumn: index)
        let target = header.headerRect(ofColumn: destination)
        let column = table.tableColumns[index]
        try ui.trackMouse(in: header, from: NSPoint(x: source.midX, y: source.midY),
                          through: (1...8).map {
            NSPoint(x: source.midX + (target.midX - source.midX) * CGFloat($0) / 8, y: source.midY)
        })
        ui.settleTracking()
        try #require(table.tableColumns[destination] === column, "The native header drag must reorder the column")
    }
}

@MainActor final class UITableInteractionState {
    var selection = Set<String>()
    var marks = Set<String>()
}

/// AppKit can coalesce columnDidResize until mouse-up. Observe its actual
/// setter to timestamp every native width update without replacing its logic.
@MainActor final class UIMeasuredTableColumn: NSTableColumn {
    var onResize: ((CGFloat) -> Void)?
    override var width: CGFloat {
        didSet { if width != oldValue { onResize?(width) } }
    }
}
