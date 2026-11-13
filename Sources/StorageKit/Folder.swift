import Foundation

/// A file big enough to be listed on its own.
public struct FileItem: Sendable, Hashable {
    public let name: String
    public let size: Int64
    public let modified: Date
    public let kind: FileKind
    /// Of `size`, the bytes it shares with clones: removing it alone
    /// doesn't free them.
    public internal(set) var shared: Int64 = 0
    /// Whole clone family membership, so choosing every member frees a copy.
    var clones: Reclaim? = nil

    /// What removing this file frees, with the clone family it may complete.
    public var reclaim: Reclaim { clones ?? Reclaim(bytes: size - shared) }
}

/// One directory in a scanned tree.
///
/// Memory is bounded on purpose: every folder is a node, but only files of
/// at least `Folder.listedFileSize` are kept individually; smaller ones are
/// summed per folder. A home folder with millions of files stays at a few
/// hundred thousand nodes while every large file stays findable.
///
/// Concurrency: during a scan each folder is written only by the worker that
/// enumerates it, and `finish()` runs once its whole subtree is done, before
/// anyone else reads it. A root handed out mid-scan (`onRoot`) is never
/// written by the scanner again: its owner finishes it. Until a top-level
/// subtree is reported done, readers may touch only its immutable fields
/// (`name`, `parent`, `path`, `inheritedKind`, `rebuildable`). After that a
/// tree changes only on the main actor, when trashed items are pruned. That
/// single-writer discipline is why the class can be `@unchecked Sendable`.
/// A retired walk may retain unpublished branches; `partialPresentation`
/// transfers only published branches to the presentation actor's new root.
public final class Folder: Identifiable, @unchecked Sendable {
    public static let listedFileSize: Int64 = 1_048_576

    public let name: String
    public private(set) weak var parent: Folder?
    /// Absolute path; stored on the root only, derived for everyone else.
    private let rootPath: String?
    /// Kind imposed on everything inside (from this folder or an ancestor).
    public let inheritedKind: FileKind?
    public let rebuildable: Rebuildable?
    /// Set when the folder couldn't be read (permissions).
    public internal(set) var unreadable = false
    /// A placeholder retained when a live reader is retired before this branch
    /// was published. Its contents are unknown, rather than an empty directory.
    public internal(set) var wasNotScanned = false

    public internal(set) var subfolders: [Folder] = []
    public internal(set) var listedFiles: [FileItem] = []
    public internal(set) var smallFileCount = 0
    public internal(set) var smallFileBytes: Int64 = 0
    /// Bytes of the files directly in this folder, by kind.
    public internal(set) var ownBytes = KindBytes()
    /// Of `ownBytes`, what those files share with clones, and the clone
    /// families they belong to that aren't whole among them.
    var ownShared: Int64 = 0
    var ownClones: [CloneFamily: CloneMembers] = [:]

    // Subtree totals, valid after `finish()`.
    public internal(set) var size: Int64 = 0
    /// Of `size`, the bytes shared with clones outside the folder, or with
    /// clones inside it that some file outside still holds.
    public internal(set) var sharedBytes: Int64 = 0
    /// Clone families with members inside and the rest elsewhere.
    var openClones: [CloneFamily: CloneMembers] = [:]
    public internal(set) var fileCount = 0
    public internal(set) var totalBytes = KindBytes()
    public internal(set) var latestChange = Date.distantPast
    /// Newest change among the files directly in this folder (not below).
    public internal(set) var ownLatestChange = Date.distantPast
    public internal(set) var isFinished = false
    var ownRiskCode: Int8 = -1
    var riskCode: Int8 = -1
    var riskListed = false
    public private(set) var riskComplete = false
    /// Computed during the existing walk, including names of small files.
    /// Reading this never lists directories or performs another disk walk.
    public var scannedRisk: PathRisk? { PathRisk.decoded(riskCode) }

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, parent: Folder?, rootPath: String? = nil, rebuildable: Rebuildable? = nil, inheritedKind: FileKind? = nil) {
        self.name = name
        self.parent = parent
        self.rootPath = rootPath
        self.rebuildable = rebuildable
        self.inheritedKind = Classifier.kind(ofFolder: name) ?? inheritedKind ?? parent?.inheritedKind
    }

    public var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        let p = parent.path
        return p == "/" ? "/" + name : p + "/" + name
    }

    /// Bytes of files directly inside (listed and small).
    public var looseBytes: Int64 { ownBytes.total }

    /// What moving the whole folder frees: `size` less the blocks clones
    /// elsewhere keep, with the families it would complete. Valid after
    /// `finish()`; after pruning, an estimate until the place is read again.
    public var reclaim: Reclaim { Reclaim(bytes: size - sharedBytes, open: openClones) }

    /// What moving only the files directly inside frees.
    public var looseReclaim: Reclaim { Reclaim(bytes: looseBytes - ownShared, open: ownClones) }

    /// Folders from the root down to this one.
    public var lineage: [Folder] {
        var out: [Folder] = []
        var cur: Folder? = self
        while let c = cur {
            out.append(c)
            cur = c.parent
        }
        return out.reversed()
    }

    /// Computes subtree totals bottom-up and sorts contents largest first.
    /// Iterative, so a pathologically deep tree can't overflow the stack.
    /// Subtrees finished earlier (as they completed mid-scan) are reused,
    /// not walked again. Call it on the root of a scan that published it
    /// through `onRoot`, from the thread that reads it.
    public func finish() {
        var order: [Folder] = []
        var stack = [self]
        while let f = stack.popLast() {
            order.append(f)
            if f === self || !f.isFinished { stack.append(contentsOf: f.subfolders) }
        }
        for f in order.reversed() where f === self || !f.isFinished {
            var total = f.ownBytes
            var reclaim = f.looseReclaim
            var count = f.listedFiles.count + f.smallFileCount
            var latest = f.latestChange
            var risk = f.ownRiskCode
            var complete = f.riskListed && !f.unreadable
            for s in f.subfolders {
                total.add(s.totalBytes)
                reclaim.add(s.reclaim)
                count += s.fileCount
                latest = max(latest, s.latestChange)
                risk = PathRisk.merging(risk, s.riskCode)
                complete = complete && s.riskComplete
            }
            f.totalBytes = total
            f.size = total.total
            f.sharedBytes = reclaim.shared(of: f.size)
            f.openClones = reclaim.open
            f.fileCount = count
            f.latestChange = latest
            f.riskCode = risk
            f.riskComplete = complete
            f.subfolders.sort { $0.size > $1.size }
            f.listedFiles.sort { $0.size > $1.size }
            f.isFinished = true
        }
    }

    /// Transfers only already published, finished branches to a new presentation.
    /// The old walker owns every unfinished branch and never touches a published
    /// branch again. Both roots have the same path, so descendants keep theirs.
    /// Call only from the presentation's owning actor after retiring its reader.
    public func partialPresentation(published: Set<ObjectIdentifier>) -> Folder {
        let copy = Folder(name: name, parent: nil, rootPath: path, rebuildable: rebuildable)
        copy.unreadable = unreadable
        copy.listedFiles = listedFiles
        copy.smallFileCount = smallFileCount
        copy.smallFileBytes = smallFileBytes
        copy.ownBytes = ownBytes
        copy.ownShared = ownShared
        copy.ownClones = ownClones
        copy.ownLatestChange = ownLatestChange
        copy.latestChange = ownLatestChange
        copy.ownRiskCode = ownRiskCode
        copy.riskListed = riskListed
        for child in subfolders {
            if published.contains(child.id) {
                child.parent = copy
                copy.subfolders.append(child)
            } else {
                let unknown = Folder(name: child.name, parent: copy, rebuildable: child.rebuildable)
                unknown.wasNotScanned = true
                unknown.finish()
                copy.subfolders.append(unknown)
            }
        }
        copy.finish()
        return copy
    }

    /// Makes an independent map with one freshly measured branch. No node is
    /// shared with either input, so later pruning cannot race a retired reader.
    /// The caller must keep the inputs immutable until this returns.
    public func replacingSubtree(at target: String, with replacement: Folder, stop: () -> Bool = { false }) -> Folder? {
        guard replacement.path == target, find(path: target) != nil else { return nil }
        var result: Folder?
        var changed: Folder?
        var pending: [(Folder, Folder?)] = [(self, nil)]
        while let (original, parent) = pending.popLast() {
            if stop() { return nil }
            let source = original.path == target ? replacement : original
            let copy = Folder(name: original.name, parent: parent, rootPath: parent == nil ? path : nil,
                              rebuildable: original.rebuildable, inheritedKind: original.inheritedKind)
            copy.unreadable = source.unreadable
            copy.wasNotScanned = source.wasNotScanned
            copy.listedFiles = source.listedFiles
            copy.smallFileCount = source.smallFileCount
            copy.smallFileBytes = source.smallFileBytes
            copy.ownBytes = source.ownBytes
            copy.ownShared = source.ownShared
            copy.ownClones = source.ownClones
            copy.ownLatestChange = source.ownLatestChange
            copy.latestChange = source.latestChange
            copy.ownRiskCode = source.ownRiskCode
            copy.riskListed = source.riskListed
            copy.totalBytes = source.totalBytes
            copy.size = source.size
            copy.sharedBytes = source.sharedBytes
            copy.openClones = source.openClones
            copy.fileCount = source.fileCount
            copy.riskCode = source.riskCode
            copy.riskComplete = source.riskComplete
            copy.isFinished = source.isFinished
            if original.path == target { changed = copy }
            if let parent { parent.subfolders.append(copy) } else { result = copy }
            pending.append(contentsOf: source.subfolders.map { ($0, copy) })
        }
        guard !stop() else { return nil }
        var ancestor = changed?.parent
        while let folder = ancestor {
            folder.isFinished = false
            folder.latestChange = folder.ownLatestChange
            ancestor = folder.parent
        }
        result?.finish()
        return result
    }

    // MARK: Pruning after items are moved to the Trash (main actor)

    /// Removes a subfolder and subtracts it from every ancestor.
    public func remove(_ child: Folder) {
        guard let i = subfolders.firstIndex(where: { $0 === child }) else { return }
        subfolders.remove(at: i)
        propagate(removing: child.totalBytes, shared: child.sharedBytes, clones: child.openClones, files: child.fileCount)
    }

    /// Removes a listed file and subtracts it from every ancestor.
    public func removeFile(named name: String) {
        guard let i = listedFiles.firstIndex(where: { $0.name == name }) else { return }
        let f = listedFiles.remove(at: i)
        var bytes = KindBytes()
        bytes[f.kind] = f.size
        ownBytes.subtract(bytes)
        ownShared = max(0, ownShared - f.shared)
        let clones = f.clones?.open ?? [:]
        Self.count(clones, by: -1, in: &ownClones, shared: &ownShared)
        propagate(removing: bytes, shared: f.shared, clones: clones, files: 1)
    }

    /// The small files `removeSmallFiles()` took out, to put back on Undo.
    public struct SmallFiles: Sendable {
        public let bytes: KindBytes
        public let files: Int
        let shared: Int64
        let ownClones: [CloneFamily: CloneMembers]
        let clones: [CloneFamily: CloneMembers]
    }

    /// Presentation update after every entry in a complete directory choice
    /// has moved. Individual small files have no nodes in the scanned tree.
    public func removeSmallFiles() -> SmallFiles {
        var bytes = ownBytes
        for file in listedFiles { bytes[file.kind] = max(0, bytes[file.kind] - file.size) }
        let listed = listedFiles.reduce(Reclaim()) { $0 + $1.reclaim }
        let left = listed.shared(of: listedFiles.reduce(0) { $0 + $1.size })
        // Members of open families that weren't listed files were small ones.
        var listedCounts: [CloneFamily: Int] = [:]
        for file in listedFiles { for (family, m) in file.clones?.open ?? [:] { listedCounts[family, default: 0] += m.count } }
        var small: [CloneFamily: CloneMembers] = [:]
        for (family, held) in ownClones {
            var m = held
            m.count -= listedCounts[family] ?? 0
            if m.count > 0 { small[family] = m }
        }
        let removed = SmallFiles(bytes: bytes, files: smallFileCount, shared: max(0, ownShared - left), ownClones: ownClones, clones: small)
        smallFileCount = 0
        smallFileBytes = 0
        ownBytes.subtract(bytes)
        ownShared = left
        ownClones = listed.open
        propagate(removing: bytes, shared: removed.shared, clones: small, files: removed.files)
        return removed
    }

    public func restoreSmallFiles(_ removed: SmallFiles) {
        smallFileCount += removed.files
        smallFileBytes += removed.bytes.total
        ownBytes.add(removed.bytes)
        ownShared += removed.shared
        ownClones = removed.ownClones
        propagate(adding: removed.bytes, shared: removed.shared, clones: removed.clones, files: removed.files)
    }

    /// Puts back a subfolder removed with `remove(_:)` (undo).
    public func restore(_ child: Folder) {
        guard !subfolders.contains(where: { $0 === child }) else { return }
        subfolders.append(child)
        subfolders.sort { $0.size > $1.size }
        propagate(adding: child.totalBytes, shared: child.sharedBytes, clones: child.openClones, files: child.fileCount)
    }

    /// Puts back a file removed with `removeFile(named:)` (undo).
    public func restoreFile(_ file: FileItem) {
        guard !listedFiles.contains(where: { $0.name == file.name }) else { return }
        listedFiles.append(file)
        listedFiles.sort { $0.size > $1.size }
        var bytes = KindBytes()
        bytes[file.kind] = file.size
        ownBytes.add(bytes)
        ownShared += file.shared
        let clones = file.clones?.open ?? [:]
        Self.count(clones, by: 1, in: &ownClones, shared: &ownShared)
        propagate(adding: bytes, shared: file.shared, clones: clones, files: 1)
    }

    /// A pruned item still holds its blocks in the Trash, so a clone family
    /// it completed is open again in every folder that held it.
    private func propagate(removing bytes: KindBytes, shared: Int64, clones: [CloneFamily: CloneMembers], files: Int) {
        var cur: Folder? = self
        while let c = cur {
            c.totalBytes.subtract(bytes)
            c.size = c.totalBytes.total
            c.sharedBytes = max(0, c.sharedBytes - shared)
            Self.count(clones, by: -1, in: &c.openClones, shared: &c.sharedBytes)
            c.sharedBytes = min(c.size, c.sharedBytes)
            c.fileCount = max(0, c.fileCount - files)
            cur = c.parent
        }
    }

    private func propagate(adding bytes: KindBytes, shared: Int64, clones: [CloneFamily: CloneMembers], files: Int) {
        var cur: Folder? = self
        while let c = cur {
            c.totalBytes.add(bytes)
            c.size = c.totalBytes.total
            c.sharedBytes += shared
            Self.count(clones, by: 1, in: &c.openClones, shared: &c.sharedBytes)
            c.sharedBytes = min(c.size, c.sharedBytes)
            c.fileCount += files
            cur = c.parent
        }
    }

    /// Takes members of an item's open families out of (`by: -1`) or back
    /// into (`by: 1`) a folder's count. A family missing from `open` was
    /// complete there: losing members reopens it and its copy is shared
    /// again; regaining them all completes it once more.
    private static func count(_ members: [CloneFamily: CloneMembers], by sign: Int, in open: inout [CloneFamily: CloneMembers], shared: inout Int64) {
        for (family, item) in members {
            if var held = open[family] {
                held.count += sign * item.count
                if held.count >= held.total {
                    open[family] = nil
                    shared = max(0, shared - held.bytes)
                } else if held.count <= 0 {
                    open[family] = nil
                } else {
                    open[family] = held
                }
            } else if sign < 0 {
                var rest = item
                rest.count = item.total - item.count
                guard rest.count > 0 else { continue }
                open[family] = rest
                shared += item.bytes
            }
        }
    }

    /// The descendant at `path`, if it's inside this tree.
    public func find(path target: String) -> Folder? {
        let base = path
        guard target == base || target.hasPrefix(base == "/" ? "/" : base + "/") else { return nil }
        if target == base { return self }
        var cur = self
        let rest = target.dropFirst(base == "/" ? 1 : base.count + 1)
        for comp in rest.split(separator: "/") {
            guard let next = cur.subfolders.first(where: { $0.name == comp }) else { return nil }
            cur = next
        }
        return cur
    }
}
