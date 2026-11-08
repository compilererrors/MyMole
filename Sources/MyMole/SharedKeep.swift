import AppKit
import Foundation
import StorageKit

/// What the user keeps, for a pane without a keep list of its own: Deep
/// Clean's keep list and the paths kept in Projects (`UserProtections`).
/// It's read when the pane's list loads and again before a move, and the
/// move's gate reads it once more as it runs; a list that can't be read
/// stops the move. Always Keep adds to Deep Clean's list, the one Deep
/// Clean and Settings show.
struct SharedKeep {
    var protections: UserProtections
    private(set) var kept = CleanKeepList()
    /// The paths on Deep Clean's own list, which Stop Keeping can take off.
    /// The rest is kept in Projects and is changed there.
    private(set) var ownPaths = Set<String>()
    private(set) var problem: Problem?

    init(protections: UserProtections) { self.protections = protections }

    /// Kept itself, inside something kept, or holding something kept.
    func protects(_ path: String) -> Bool { kept.protects(path) }
    func isOnOwnList(_ path: String) -> Bool { ownPaths.contains(path) }

    /// Why nothing may move now, or nil.
    var blocker: String? {
        problem.map { String(localized: "The keep lists couldn't be read, so nothing is moved: \($0.description)") }
    }

    mutating func reload() {
        do {
            let own = try CleanKeepList.load(from: protections.keepList)
            let rules = try ProjectStore.loadRules(base: protections.projectBase)
            ownPaths = own.paths
            kept = CleanKeepList(paths: own.paths.union(rules.keepPaths))
            problem = nil
        } catch {
            problem = Problem(.keepList, error)
        }
    }

    /// The lists read again off the main thread, for a pane to take in
    /// place of its own: a slow disk never holds up the window.
    func reloaded() async -> SharedKeep {
        var copy = self
        return await Task.detached(priority: .userInitiated) {
            copy.reload()
            return copy
        }.value
    }

    /// Keeps `add` and stops keeping `remove` on Deep Clean's list, saved
    /// onto the file as it is now. Returns why it couldn't, or nil.
    mutating func change(keep add: [String], stop remove: [String]) -> String? {
        do {
            _ = try CleanKeepList.update(at: protections.keepList) { list in
                list.paths.formUnion(add)
                list.paths.subtract(remove)
            }
            reload()
            return nil
        } catch {
            reload()
            return String(localized: "Couldn't save the keep list: \(Problem(.keepList, error).description)")
        }
    }

    /// What a move's gate reads as it runs.
    var gate: @Sendable () throws -> @Sendable (String) -> Bool {
        let p = protections
        return { try p.read() }
    }
}

extension SharedKeep {
    /// Marks a row that's kept, as Deep Clean does.
    func mark(_ row: inout FileRow) {
        guard protects(row.id) else { return }
        row.badge = String(localized: "Kept")
        row.badgeTint = .secondaryLabelColor
        row.canChoose = false
        row.badgeHelp =
            isOnOwnList(row.id)
            ? String(localized: "On your keep list; never moved from here")
            : String(localized: "Kept in Projects or on your keep list, or holds something that is; never moved from here")
        row.choiceHelp = row.badgeHelp
    }

    /// "Always Keep", or "Stop Keeping" for what's on Deep Clean's list.
    /// What only Projects keeps is changed in Projects.
    func menuEntry(_ paths: [String], keep: @escaping ([String]) -> Void, stop: @escaping ([String]) -> Void) -> TableMenuEntry {
        let own = paths.filter(isOnOwnList)
        return own.isEmpty
            ? .action(String(localized: "Always Keep")) { keep(paths) }
            : .action(String(localized: "Stop Keeping")) { stop(own) }
    }
}
