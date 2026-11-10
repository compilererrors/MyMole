import Foundation

/// Every folder and listed file of a finished scan, flat and compact, for
/// searching the whole scan rather than one folder. Files under
/// `Folder.listedFileSize` aren't kept one by one by the scan, so they
/// aren't in it. Built once the walk is done, while nothing changes the
/// tree; at most `limit` entries, the biggest folders' first.
public struct ScanIndex: Sendable {
    public struct Entry: Sendable {
        public let name: String
        /// The folder it's in, as a position in `entries`; -1 for the root.
        let parent: Int32
        public let size: Int64
        public let modified: Date
        public let kind: FileKind
        public let isFolder: Bool
    }

    public private(set) var entries: [Entry] = []
    public let rootPath: String
    /// More was in the scan than the index holds.
    public private(set) var truncated = false
    public static let standardLimit = 400_000

    public init(_ root: Folder, limit: Int = standardLimit, stop: () -> Bool = { false }) {
        rootPath = root.path
        // Breadth first, so a cut drops the deepest, not a whole branch.
        var queue: [(Folder, Int32)] = [(root, -1)]
        var head = 0
        while head < queue.count {
            if stop() { truncated = true; break }
            let (folder, parent) = queue[head]
            head += 1
            let here = Int32(entries.count)
            guard entries.count < limit else {
                truncated = true
                break
            }
            entries.append(Entry(
                name: folder.name, parent: parent, size: folder.size, modified: folder.latestChange,
                kind: folder.inheritedKind ?? .other, isFolder: true))
            for f in folder.listedFiles {
                if stop() { truncated = true; break }
                guard entries.count < limit else {
                    truncated = true
                    break
                }
                entries.append(Entry(name: f.name, parent: here, size: f.size, modified: f.modified, kind: f.kind, isFolder: false))
            }
            for sub in folder.subfolders.sorted(by: { $0.size > $1.size }) {
                if stop() { truncated = true; break }
                queue.append((sub, here))
            }
        }
    }

    /// The full path of entry `i`.
    public func path(_ i: Int) -> String {
        guard entries[i].parent >= 0 else { return rootPath }
        var names: [String] = []
        var at = i
        while entries[at].parent >= 0 {
            names.append(entries[at].name)
            at = Int(entries[at].parent)
        }
        let rest = names.reversed().joined(separator: "/")
        return rootPath == "/" ? "/" + rest : rootPath + "/" + rest
    }

    /// The entries whose name or path holds every word of `query`, that
    /// pass `keep`, biggest first, at most `limit`; and whether more matched.
    public func search(
        _ query: String, limit: Int = 2_000, keep: (Entry) -> Bool = { _ in true }
    ) -> (found: [Int], more: Bool) {
        let words = query.lowercased().split(separator: " ").map(String.init)
        var found: [Int] = []
        for i in entries.indices where entries[i].parent >= 0 && keep(entries[i]) {
            let e = entries[i]
            // The name first; the path is put together only when the name alone doesn't do.
            // Lower-cased and compared plainly: the quickest case-blind match.
            let name = e.name.lowercased()
            let pending = words.filter { !name.contains($0) }
            if !pending.isEmpty {
                let p = path(i).lowercased()
                guard pending.allSatisfy({ p.contains($0) }) else { continue }
            }
            found.append(i)
        }
        found.sort { entries[$0].size > entries[$1].size }
        return (Array(found.prefix(limit)), found.count > limit)
    }
}
