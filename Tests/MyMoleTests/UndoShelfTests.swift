import Foundation
import StorageKit
import Testing

@testable import MyMole

@Suite struct UndoShelfTests {
    struct Run: UndoableRun {
        let id = UUID()
        var records: [TrashRecord] = []
        var note = ""
    }

    @Test func everyRunOfTheSessionStaysUntilTheLimit() {
        var shelf = UndoShelf<Run>()
        let first = Run(note: "first"), second = Run(note: "second")
        shelf.add(first)
        shelf.add(second)
        #expect(shelf.latest?.id == second.id && shelf.run(first.id)?.note == "first")
        shelf.update(first.id) { $0.note = "partly back" }
        #expect(shelf.run(first.id)?.note == "partly back" && shelf.latest?.id == second.id)
        shelf.remove(second.id)
        #expect(shelf.latest?.id == first.id)
        for _ in 0..<UndoShelf<Run>.limit { shelf.add(Run()) }
        #expect(shelf.runs.count == UndoShelf<Run>.limit && shelf.run(first.id) == nil)
    }
}

@MainActor
@Suite struct HistoryUndoTests {
    @Test func aMoveWithoutUndoPointsToTheTrash() {
        let moved = CleanupRecord(source: "Deep Clean", items: 3, bytes: 10, failed: 0)
        #expect(HistoryView.inTrashWithoutUndo(moved, undoable: false))
        #expect(!HistoryView.inTrashWithoutUndo(moved, undoable: true))
        // Nothing of it in the Trash: deleted for good, a task run, or all put back.
        #expect(!HistoryView.inTrashWithoutUndo(CleanupRecord(source: "System Clean", items: 0, bytes: 10, failed: 0, deleted: 2), undoable: false))
        #expect(!HistoryView.inTrashWithoutUndo(CleanupRecord(source: "Optimize", items: 4, bytes: 0, failed: 0), undoable: false))
        #expect(!HistoryView.inTrashWithoutUndo(CleanupRecord(source: "Installers", items: 2, bytes: 5, failed: 0, restored: 2), undoable: false))
    }

    @Test func aRunWhoseTrashWasEmptiedSinceSaysSo() {
        let moved = CleanupRecord(date: Date(timeIntervalSince1970: 100), source: "Deep Clean", items: 3, bytes: 10, failed: 0)
        let emptied = CleanupRecord(date: Date(timeIntervalSince1970: 200), source: TrashModel.source, items: 0, bytes: 10, failed: 0, deleted: 5)
        let before = CleanupRecord(date: Date(timeIntervalSince1970: 50), source: TrashModel.source, items: 0, bytes: 10, failed: 0, deleted: 5)
        #expect(HistoryView.trashEmptied(after: moved, in: [emptied, moved]))
        #expect(!HistoryView.trashEmptied(after: moved, in: [moved, before]))
    }
}
