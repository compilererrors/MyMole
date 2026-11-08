import Foundation
import StorageKit

/// A move to the Trash that can still be put back: its history record and
/// what was moved, plus what its pane needs to show it again.
protocol UndoableRun {
    var id: UUID { get }
    var records: [TrashRecord] { get }
}

/// How many moves each pane can put back, for every pane.
enum UndoLimit {
    static let runs = 10
}

/// The moves of this session a pane can still put back, newest last, each
/// by its history record, so History can undo any of them and not only the
/// last. Kept in memory only: what was moved names files, and the history
/// on disk stays free of paths. After a relaunch, Finder's Put Back is the way.
struct UndoShelf<Run: UndoableRun> {
    static var limit: Int { UndoLimit.runs }
    private(set) var runs: [Run] = []

    var latest: Run? { runs.last }
    func run(_ id: UUID) -> Run? { runs.last { $0.id == id } }

    /// Keeps a new move; the oldest beyond the limit can no longer be undone here.
    mutating func add(_ run: Run) {
        runs.removeAll { $0.id == run.id }
        runs.append(run)
        if runs.count > Self.limit { runs.removeFirst(runs.count - Self.limit) }
    }

    /// Changes a kept move in place, as an Undo puts part of it back.
    mutating func update(_ id: UUID, _ change: (inout Run) -> Void) {
        guard let i = runs.lastIndex(where: { $0.id == id }) else { return }
        change(&runs[i])
    }

    mutating func remove(_ id: UUID) { runs.removeAll { $0.id == id } }
}
