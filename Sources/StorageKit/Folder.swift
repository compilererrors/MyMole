import Foundation

/// A file big enough to be listed on its own.
public struct FileItem: Sendable, Hashable {
    public let name: String
    public let size: Int64
    public let modified: Date
    public let kind: FileKind
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

    public internal(set) var subfolders: [Folder] = []
    public internal(set) var listedFiles: [FileItem] = []
    public internal(set) var smallFileCount = 0
    public internal(set) var smallFileBytes: Int64 = 0
    /// Bytes of the files directly in this folder, by kind.
    public internal(set) var ownBytes = KindBytes()

    // Subtree totals, valid after `finish()`.
    public internal(set) var size: Int64 = 0
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

    init(name: String, parent: Folder?, rootPath: String? = nil, rebuildable: Rebuildable? = nil) {
        self.name = name
        self.parent = parent
        self.rootPath = rootPath
        self.rebuildable = rebuildable
        inheritedKind = Classifier.kind(ofFolder: name) ?? parent?.inheritedKind
    }

    public var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        let p = parent.path
        return p == "/" ? "/" + name : p + "/" + name
    }

    /// Bytes of files directly inside (listed and small).
    public var looseBytes: Int64 { ownBytes.total }

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
            var count = f.listedFiles.count + f.smallFileCount
            var latest = f.latestChange
            var risk = f.ownRiskCode
            var complete = f.riskListed && !f.unreadable
            for s in f.subfolders {
                total.add(s.totalBytes)
                count += s.fileCount
                latest = max(latest, s.latestChange)
                risk = PathRisk.merging(risk, s.riskCode)
                complete = complete && s.riskComplete
            }
            f.totalBytes = total
            f.size = total.total
            f.fileCount = count
            f.latestChange = latest
            f.riskCode = risk
            f.riskComplete = complete
            f.subfolders.sort { $0.size > $1.size }
            f.listedFiles.sort { $0.size > $1.size }
            f.isFinished = true
        }
    }

    // MARK: Pruning after items are moved to the Trash (main actor)

    /// Removes a subfolder and subtracts it from every ancestor.
    public func remove(_ child: Folder) {
        guard let i = subfolders.firstIndex(where: { $0 === child }) else { return }
        subfolders.remove(at: i)
        propagate(removing: child.totalBytes, files: child.fileCount)
    }

    /// Removes a listed file and subtracts it from every ancestor.
    public func removeFile(named name: String) {
        guard let i = listedFiles.firstIndex(where: { $0.name == name }) else { return }
        let f = listedFiles.remove(at: i)
        var bytes = KindBytes()
        bytes[f.kind] = f.size
        ownBytes.subtract(bytes)
        propagate(removing: bytes, files: 1)
    }

    /// Puts back a subfolder removed with `remove(_:)` (undo).
    public func restore(_ child: Folder) {
        guard !subfolders.contains(where: { $0 === child }) else { return }
        subfolders.append(child)
        subfolders.sort { $0.size > $1.size }
        propagate(adding: child.totalBytes, files: child.fileCount)
    }

    /// Puts back a file removed with `removeFile(named:)` (undo).
    public func restoreFile(_ file: FileItem) {
        guard !listedFiles.contains(where: { $0.name == file.name }) else { return }
        listedFiles.append(file)
        listedFiles.sort { $0.size > $1.size }
        var bytes = KindBytes()
        bytes[file.kind] = file.size
        ownBytes.add(bytes)
        propagate(adding: bytes, files: 1)
    }

    private func propagate(removing bytes: KindBytes, files: Int) {
        var cur: Folder? = self
        while let c = cur {
            c.totalBytes.subtract(bytes)
            c.size = c.totalBytes.total
            c.fileCount = max(0, c.fileCount - files)
            cur = c.parent
        }
    }

    private func propagate(adding bytes: KindBytes, files: Int) {
        var cur: Folder? = self
        while let c = cur {
            c.totalBytes.add(bytes)
            c.size = c.totalBytes.total
            c.fileCount += files
            cur = c.parent
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
