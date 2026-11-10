import AppKit
import SwiftUI
import Testing
@testable import MyMole

@MainActor @Suite struct FileChoiceTests {
    @Test func bulkCheckboxChecksTheFilteredListWithoutChangingHighlightsOrHiddenChoices() throws {
        let rows = [
            FileRow(id: "/synthetic/list/a", name: "A", size: 1),
            FileRow(id: "/synthetic/list/b", name: "B", size: 1),
            FileRow(id: "/synthetic/list/required", name: "Required", size: 1, canChoose: false),
            FileRow(id: "/synthetic/list/pending", name: "Measuring", size: nil),
            FileRow(id: "/synthetic/list/review", name: "Needs review", size: 1, reviewBeforeChoosing: true),
        ]
        var marks: Set<String> = ["/synthetic/hidden", rows[2].id]
        var selected: Set<String> = [rows[1].id]
        var requests = 0
        let view = FileTable(rows: rows, columns: [.name, .size], autosave: "synthetic.bulk-choice",
                             selection: Binding(get: { selected }, set: { selected = $0 }), marks: marks,
                             onSetMarks: { ids, checked in
                                 requests += 1
                                 if checked { marks.formUnion(ids) } else { marks.subtract(ids) }
                             })
        let coordinator = view.makeCoordinator()
        let table = FileTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.addTableColumn(NSTableColumn(identifier: .init("size")))
        table.dataSource = coordinator
        coordinator.table = table
        TableChoiceHeader.install(on: table)
        let header = try #require(table.headerView as? TableChoiceHeader)
        coordinator.load(rows, marks: marks, selection: selected)
        #expect(header.check.state == .off && header.check.isEnabled)
        header.check.performClick(nil)
        #expect(marks == ["/synthetic/hidden", rows[0].id, rows[1].id, rows[2].id])
        #expect(selected == [rows[1].id] && requests == 1)
        coordinator.load(rows, marks: marks, selection: selected)
        #expect(header.check.state == .on)
        header.check.performClick(nil)
        coordinator.load(rows, marks: marks, selection: selected)
        #expect(marks == ["/synthetic/hidden", rows[2].id] && requests == 2 && header.check.state == .off)
        marks.insert(rows[0].id)
        coordinator.load(rows, marks: marks, selection: selected)
        #expect(header.check.state == .mixed)
        header.check.performClick(nil)
        #expect(marks.contains(rows[1].id) && requests == 3)
        coordinator.load(rows, marks: nil, selection: selected)
        coordinator.setListedMarks(true)
        #expect(header.check.isHidden && requests == 3)
    }

    @Test func bulkChoiceKeepsTheReservedCopyOutOfCheckAllButCanClearItsManualChoice() {
        let rows = [FileRow(id: "older", name: "Older", size: 1),
                    FileRow(id: "newest", name: "Newest", size: 1, bulkCheckable: false)]
        let choices = ListedChoices(rows)
        #expect(choices.checkable == ["older"] && choices.clearable == ["older", "newest"])
        #expect(choices.state([]) == .off && choices.state(["newest"]) == .mixed)
        #expect(choices.state(["older"]) == .on)
    }

    @Test func headerCheckboxExposesItsActualScreenFrameAfterColumnsMoveAndResize() throws {
        let table = FileTableView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        for name in ["name", "size"] {
            let column = NSTableColumn(identifier: .init(name))
            column.title = name
            column.width = 250
            table.addTableColumn(column)
        }
        TableChoiceHeader.install(on: table)
        let scroll = NSScrollView(frame: NSRect(x: 140, y: 60, width: 400, height: 300))
        scroll.documentView = table
        let window = NSWindow(contentRect: NSRect(x: 30, y: 40, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(scroll)
        let header = try #require(table.headerView as? TableChoiceHeader)
        header.update(state: .mixed, visible: true, enabled: true, help: nil) {}
        for width in [CGFloat(250), 380] {
            table.tableColumns.first { $0.identifier.rawValue == "name" }?.width = width
            table.moveColumn(table.column(withIdentifier: .init("name")), toColumn: width == 250 ? 1 : 0)
            window.contentView?.layoutSubtreeIfNeeded()
            header.layout()
            let screen = window.convertToScreen(header.check.convert(header.check.bounds, to: nil))
            #expect(header.check.accessibilityFrame() == screen)
            let pointer = header.check.convert(NSPoint(x: header.check.bounds.midX, y: header.check.bounds.midY), to: header.superview)
            #expect(header.hitTest(pointer) === header.check)
            #expect((header.accessibilityHitTest(NSPoint(x: screen.midX, y: screen.midY)) as? NSButton) === header.check)
        }
    }

    @Test func requestingReviewDoesNotShowAnUnapprovedCheckboxAsSelected() throws {
        let cell = FileNameCell(identifier: .init("synthetic-review"))
        var calls = 0
        var row = FileRow(id: "/synthetic/review", name: "Uncertain match", size: 100, canChoose: true, reviewBeforeChoosing: true)
        cell.configure(row, marked: false) { calls += 1 }
        let checkbox = try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
        checkbox.performClick(nil)
        #expect(calls == 1 && checkbox.state == .off)
        row.reviewBeforeChoosing = false
        cell.configure(row, marked: true) { calls += 1 }
        #expect(checkbox.state == .on)
        checkbox.performClick(nil)
        #expect(calls == 2 && checkbox.state == .off)
    }
    @Test func protectedAndRequiredChoicesIgnoreClicksAndReuseRemainsEditable() throws {
        let cell = FileNameCell(identifier: .init("synthetic-choice"))
        var calls = 0
        var row = FileRow(id: "/synthetic/item", name: "Example item", size: 1024, canChoose: false, choiceHelp: "Required in this review")
        cell.configure(row, marked: true) { calls += 1 }
        let checkbox = try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
        cell.setChoosingEnabled(true)
        checkbox.performClick(nil)
        #expect(!checkbox.isEnabled && checkbox.state == .on && calls == 0)
        #expect(checkbox.toolTip == "Required in this review")

        row.canChoose = true
        row.size = nil
        cell.configure(row, marked: false, dimUnmeasured: false) { calls += 1 }
        cell.setChoosingEnabled(true)
        checkbox.performClick(nil)
        #expect(!checkbox.isEnabled && calls == 0)

        row.size = 1024
        cell.configure(row, marked: false) { calls += 1 }
        checkbox.performClick(nil)
        #expect(checkbox.isEnabled && checkbox.state == .on && calls == 1)
    }
}
