import AppKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor @Suite struct FileActionsTests {
    @Test func copyFormatsPreserveThePathAndRespectHomeBoundaries() {
        let paths = ["/synthetic/home", "/synthetic/home/Documents/../Example.txt", "/synthetic/home-other/Example.txt"]
        #expect(FileActions.copyText(paths, as: .path, home: "/synthetic/home") == "~\n~/Documents/../Example.txt\n/synthetic/home-other/Example.txt")
        #expect(FileActions.copyText(paths, as: .absolutePath, home: "/synthetic/home") == paths.joined(separator: "\n"))
        #expect(FileActions.copyText(paths, as: .name, home: "/synthetic/home") == "home\nExample.txt\nExample.txt")
    }

    @Test func shellAndURLCopiesEscapeSpecialCharactersWithoutRunningAnything() {
        let path = "/synthetic/O'Brien/$(example); `value`\nnext line.txt"
        #expect(FileActions.copyText([path], as: .shellPath, home: "/synthetic") == "'/synthetic/O'\\''Brien/$(example); `value`\nnext line.txt'")
        #expect(FileActions.copyText(["/synthetic/Example #1%.txt"], as: .fileURL, home: "/synthetic") == "file:///synthetic/Example%20%231%25.txt")
    }

    @Test func groupIDsAndInvalidPathsCannotBecomeFileActions() {
        let values = ["group-id", "", "relative/path", "/synthetic/B", "/synthetic/A", "/synthetic/B", "/synthetic/bad\0path"]
        #expect(FileActions.paths(values) == ["/synthetic/B", "/synthetic/A"])
        #expect(FileActions.inspectionMenu(["group-id", "relative/path"]).isEmpty)
        #expect(FileActions.copyText(["group-id"], as: .absolutePath, home: "/synthetic").isEmpty)
    }

    @Test func inspectionOnlyAndUnmeasuredRowsHaveUsefulNonDestructiveMenus() {
        for size: Int64? in [nil, 1024] {
            let path = "/synthetic/Example folder"
            let row = FileRow(id: path, name: "Example folder", size: size, canChoose: false)
            let parent = FileTable(rows: [row], columns: [.name], autosave: "synthetic.file-menu", selection: .constant([]), marks: [])
            let coordinator = parent.makeCoordinator()
            let table = FileTableView()
            table.dataSource = coordinator
            coordinator.table = table
            coordinator.load([row], marks: [], selection: [])
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let menu = NSMenu()
            coordinator.menuNeedsUpdate(menu)
            let titles = menu.items.map(\.title)
            #expect(titles.contains("Show in Finder") && titles.contains("Quick Look"))
            #expect(titles.contains("Copy Path") && titles.contains("Copy Absolute Path"))
            #expect(menu.items.first { $0.title == "Copy As" }?.submenu?.items.map(\.title) == ["Name", "Shell-Quoted Path", "File URL"])
            #expect(!titles.contains("Choose for Removal") && !titles.contains("Open with Default App"))
        }
    }

    @Test func rightClickTargetsTheClickedRowOrTheExistingMultipleSelection() {
        let rows = (0..<3).map { FileRow(id: "/synthetic/Example\($0)", name: "Example \($0)") }
        let parent = FileTable(rows: rows, columns: [.name], autosave: "synthetic.file-targets", selection: .constant([]))
        let coordinator = parent.makeCoordinator()
        let table = FileTableView()
        table.dataSource = coordinator
        coordinator.table = table
        coordinator.load(rows, marks: nil, selection: [])
        table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        #expect(coordinator.targetIDs(clicked: 1) == [rows[1].id])
        #expect(coordinator.targetIDs(clicked: 0) == [rows[0].id, rows[2].id])
    }
}
