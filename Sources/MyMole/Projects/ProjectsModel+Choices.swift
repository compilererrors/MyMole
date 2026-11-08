import AppKit
import StorageKit
import SwiftUI

// MARK: - Choosing inside entries

extension ProjectsModel {
    /// Where every removable entry sits, and which items and folders hold
    /// something chosen or left out. Rebuilt only after the footprints or
    /// the choice change.
    struct ChoiceIndex {
        var owners: [String: Chosen] = [:]
        /// Item id → entries chosen whole, and whether anything inside one
        /// is chosen or left out.
        var perItem: [String: (whole: Int, parts: Bool)] = [:]
        /// Folders with something chosen or left out inside them.
        var holding = Set<String>()
        /// Chosen path → bytes left out of it.
        var leftOut: [String: Int64] = [:]
    }

    var index: ChoiceIndex {
        if let choiceIndex { return choiceIndex }
        var ix = ChoiceIndex()
        for f in footprints {
            for item in f.items where item.removable {
                for e in item.entries { ix.owners[e.path] = Chosen(project: f.id, item: item, entry: e) }
            }
        }
        for p in chosen.union(excluded) {
            guard let o = Self.owner(of: p, in: ix.owners) else { continue }
            var counts = ix.perItem[o.item.id] ?? (0, false)
            if p == o.entry.path && chosen.contains(p) { counts.whole += 1 } else { counts.parts = true }
            ix.perItem[o.item.id] = counts
            var up = (p as NSString).deletingLastPathComponent
            while up.count >= o.entry.path.count {
                ix.holding.insert(up)
                up = (up as NSString).deletingLastPathComponent
            }
        }
        for e in excluded {
            guard let o = Self.owner(of: e, in: ix.owners), let m = marker(above: e, top: o.entry.path), m.chosen else { continue }
            ix.leftOut[m.path, default: 0] += partInfo[e]?.bytes ?? 0
        }
        choiceIndex = ix
        return ix
    }

    private static func owner(of path: String, in owners: [String: Chosen]) -> Chosen? {
        var p = path
        while true {
            if let hit = owners[p] { return hit }
            let parent = (p as NSString).deletingLastPathComponent
            if parent == p || parent.isEmpty { return nil }
            p = parent
        }
    }

    /// The removable entry `path` is, or lies inside.
    func owner(of path: String) -> Chosen? { Self.owner(of: path, in: index.owners) }

    /// The nearest folder above `path`, up to its entry, that's chosen or
    /// left out.
    func marker(above path: String, top: String) -> (path: String, chosen: Bool)? {
        var up = path
        while up.count > top.count {
            up = (up as NSString).deletingLastPathComponent
            if chosen.contains(up) { return (up, true) }
            if excluded.contains(up) { return (up, false) }
        }
        return nil
    }

    /// Whether `path` goes: chosen itself or inside something chosen and
    /// not left out; partly when something inside it differs.
    func state(of path: String) -> Check {
        guard let o = owner(of: path) else { return .off }
        let goes = chosen.contains(path) || (!excluded.contains(path) && marker(above: path, top: o.entry.path)?.chosen == true)
        if index.holding.contains(path) { return .mixed }
        return goes ? .on : .off
    }

    /// Chooses or unchooses one entry, folder or file; partly chosen, it's
    /// chosen whole. Inside a chosen folder, unchoosing leaves it out: the
    /// folder still goes, it stays.
    func toggle(path: String) {
        // What Deep Clean keeps is never chosen here.
        guard !isKeptElsewhere(path), let o = owner(of: path) else { return }
        let top = o.entry.path
        let wasOff = state(of: path) != .on
        // Only what's above the path decides; what was inside it starts over.
        let above = marker(above: path, top: top)
        var c = chosen.filter { !$0.hasPrefix(path + "/") }
        var x = excluded.filter { !$0.hasPrefix(path + "/") }
        if wasOff {
            x.remove(path)
            if above?.chosen != true { c.insert(path) }
        } else {
            c.remove(path)
            if above?.chosen == true { x.insert(path) }
        }
        note(path, in: top)
        excluded = x
        chosen = c
    }

    /// Left-out paths only mean something inside a chosen one.
    func tidyExcluded() {
        let kept = excluded.filter { e in
            guard let o = owner(of: e) else { return false }
            var up = e
            while up.count > o.entry.path.count {
                up = (up as NSString).deletingLastPathComponent
                if chosen.contains(up) { return true }
            }
            return false
        }
        if kept.count != excluded.count { excluded = kept }
    }

    /// Remembers the size of a part as it's chosen or left out: from the
    /// measured tree, or from the file or folder itself.
    private func note(_ p: String, in entry: String) {
        guard p != entry, partInfo[p] == nil else { return }
        if let f = contents[entry]?.find(path: p) {
            partInfo[p] = FootprintEntry(path: p, bytes: f.size, modified: f.latestChange)
            return
        }
        var st = stat()
        guard lstat(p, &st) == 0 else { return }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        if st.st_mode & S_IFMT == S_IFDIR {
            // Its entry wasn't opened: measured off the main thread, and the
            // totals catch up when it's done.
            partInfo[p] = FootprintEntry(path: p, bytes: 0, modified: modified)
            Task.detached(priority: .userInitiated) { [weak self] in
                let f = StorageScanner.scan(path: p, workers: 2).root
                await self?.measuredPart(FootprintEntry(path: p, bytes: f.size, modified: f.latestChange))
            }
        } else {
            let name = (p as NSString).lastPathComponent
            let listed = contents[entry]?.find(path: (p as NSString).deletingLastPathComponent)?.listedFiles.first { $0.name == name }
            partInfo[p] = FootprintEntry(path: p, bytes: listed?.size ?? Int64(st.st_blocks) * 512, modified: modified)
        }
    }

    private func measuredPart(_ e: FootprintEntry) {
        partInfo[e.path] = e
        choiceIndex = nil
        partSizes += 1
    }

    /// Measures what's inside an entry, once, for opening it in the list.
    func loadContents(_ path: String) {
        guard contents[path] == nil, !loadingContents.contains(path) else { return }
        loadingContents.insert(path)
        let level = PerformanceLevel.current()
        let workers = level.workers(background: false)
        Task.detached(priority: level.priority(background: false)) { [weak self] in
            let tree = StorageScanner.scan(path: path, workers: workers).root
            await self?.contentsLoaded(path, tree)
        }
    }

    private func contentsLoaded(_ path: String, _ tree: Folder) {
        guard loadingContents.remove(path) != nil else { return }
        contents[path] = tree
        contentsOrder.removeAll { $0 == path }
        contentsOrder.append(path)
        while contentsOrder.count > Self.keptContents {
            contents.removeValue(forKey: contentsOrder.removeFirst())
        }
    }

    /// Opened entries kept measured at once.
    static let keptContents = 12

    /// Forgets measured contents that changed, so they're measured again.
    func dropContents(touching paths: some Collection<String>) {
        let stale = contents.keys.filter { e in paths.contains { $0 == e || $0.hasPrefix(e + "/") || e.hasPrefix($0 + "/") } }
        for e in stale {
            contents.removeValue(forKey: e)
            loadingContents.remove(e)
        }
        contentsOrder.removeAll { stale.contains($0) }
    }
}
