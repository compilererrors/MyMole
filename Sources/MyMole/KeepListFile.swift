import Foundation
import StorageKit

/// A keep list as the user wants it: the file on disk, and a change of the
/// user's that couldn't be saved yet. The unsaved change protects in the
/// app right away, but nothing is removed until it's saved or given up,
/// and nothing is removed while the file can't be read.
struct KeepListFile {
    let url: URL
    /// What applies now: the saved list with the unsaved change.
    private(set) var list = CleanKeepList()
    private(set) var readError: String?
    private(set) var saveError: String?
    private var saved = CleanKeepList()
    private var added = Set<String>()
    private var removed = Set<String>()

    init(url: URL) {
        self.url = url
        reload()
    }

    var hasUnsavedChange: Bool { !added.isEmpty || !removed.isEmpty }

    /// Why nothing may be removed against this list now, or nil.
    var blocker: String? {
        if readError != nil { return "The keep list couldn't be read." }
        if hasUnsavedChange { return "A change to the keep list hasn't been saved." }
        return nil
    }

    /// Reads the file again, then saves the change still waiting, if any.
    mutating func reload() {
        guard hasUnsavedChange else {
            do {
                saved = try CleanKeepList.load(from: url)
                readError = nil
            } catch {
                readError = error.localizedDescription
            }
            saveError = nil
            refresh()
            return
        }
        let (added, removed) = (added, removed)
        do {
            saved = try CleanKeepList.update(at: url) { l in
                l.paths.formUnion(added)
                l.paths.subtract(removed)
            }
            self.added = []
            self.removed = []
            readError = nil
            saveError = nil
        } catch {
            // Told apart so the notice says what really went wrong.
            if (try? CleanKeepList.load(from: url)) == nil {
                readError = error.localizedDescription
            } else {
                readError = nil
                saveError = error.localizedDescription
            }
        }
        refresh()
    }

    /// Keeps `add` and stops keeping `remove`, saved onto the file as it is now.
    mutating func change(keep add: some Sequence<String>, stop remove: some Sequence<String>) {
        let add = Set(add), remove = Set(remove)
        added = added.subtracting(remove).union(add)
        removed = removed.subtracting(add).union(remove)
        reload()
    }

    /// Gives up the change that couldn't be saved; the file is read again.
    mutating func discardChange() {
        added = []
        removed = []
        reload()
    }

    private mutating func refresh() {
        var l = saved
        l.paths.formUnion(added)
        l.paths.subtract(removed)
        list = l
    }
}
