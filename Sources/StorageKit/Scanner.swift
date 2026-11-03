import Foundation
import Synchronization

/// Live counters, readable from any thread while a scan runs.
public final class ScanProgress: Sendable {
    let filesCounter = Atomic<Int>(0)
    let foldersCounter = Atomic<Int>(0)
    let bytesCounter = Atomic<Int64>(0)
    let deniedCounter = Atomic<Int>(0)
    let cancelled = Atomic<Bool>(false)
    /// Large files found since the last `drainFound()`.
    let found = Mutex<[FoundFile]>([])

    public init() {}

    /// Takes the large files found since the last call, so a list can fill
    /// in while the scan is still running.
    public func drainFound() -> [FoundFile] {
        found.withLock { f in
            defer { f = [] }
            return f
        }
    }

    public var files: Int { filesCounter.load(ordering: .relaxed) }
    public var folders: Int { foldersCounter.load(ordering: .relaxed) }
    public var bytes: Int64 { bytesCounter.load(ordering: .relaxed) }
    public var denied: Int { deniedCounter.load(ordering: .relaxed) }

    /// Stops the scan at the next folder boundary; the result is partial.
    public func cancel() { cancelled.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }
}

/// A file of at least `Folder.listedFileSize`, reported as soon as it's seen.
public struct FoundFile: Sendable {
    public let name: String
    public let folder: String
    public let size: Int64
    public let modified: Date
    public let kind: FileKind
    public var path: String { folder == "/" ? "/" + name : folder + "/" + name }
}

public struct ScanResult: Sendable {
    public let root: Folder
    /// Folders the scan couldn't open (first 500), so gaps are never silent.
    public let deniedPaths: [String]
    public let duration: TimeInterval
    public let cancelled: Bool
}

/// Parallel directory walk into a `Folder` tree.
///
/// Workers pull folders from one shared LIFO stack, so a single enormous
/// subtree (a `node_modules`, `~/Library`) is shared out instead of pinning
/// one thread. Each top-level subfolder is tracked by a pending counter; the
/// moment its last folder is read, its totals are finalized and it's handed
/// to `onSubtree`, which lets the UI fill in while the walk continues.
public enum StorageScanner {
    /// Walkers for a scan someone is waiting on: twice the cores, as reading
    /// directories mostly waits on the disk. The app picks its own through
    /// `PerformanceLevel`; these are the library's defaults.
    public static let defaultWorkers = min(max(ProcessInfo.processInfo.activeProcessorCount * 2, 4), 24)
    /// Walkers for a scan started ahead of need, so it leaves room for the
    /// app and for other scans running at the same time.
    public static let backgroundWorkers = max(ProcessInfo.processInfo.activeProcessorCount / 2, 2)

    /// Runs on the calling thread until done; call from a background task.
    ///
    /// With `onRoot`, the root is shared from that moment on, so the scanner
    /// leaves its totals to the receiver: call `result.root.finish()` on the
    /// thread that reads the tree. Without it, the result comes back finished.
    public static func scan(
        path: String,
        progress: ScanProgress = ScanProgress(),
        workers: Int = defaultWorkers,
        onRoot: (@Sendable (Folder) -> Void)? = nil,
        onSubtree: @Sendable (Folder) -> Void = { _ in }
    ) -> ScanResult {
        let start = Date()
        let root = Folder(name: (path as NSString).lastPathComponent, parent: nil, rootPath: path)
        let walk = Walk(rootDevice: DirectoryReader.device(of: path) ?? 0, progress: progress)

        // The root goes first, on this thread, so its top-level folders exist
        // (and can be shown as placeholders) before the parallel walk starts.
        let tops = walk.read(root, path: path)
        walk.tracker.start(count: tops.count)
        for (i, t) in tops.enumerated() { walk.topIndex[ObjectIdentifier(t)] = i }
        onRoot?(root)

        walk.queue.push(tops.map { ($0, $0.path, walk.topIndex[ObjectIdentifier($0)]!) })
        DispatchQueue.concurrentPerform(iterations: max(workers, 1)) { _ in
            while let (folder, folderPath, top) = walk.queue.pop(cancelled: progress) {
                let subs = walk.read(folder, path: folderPath)
                // Counted before they're queued: once queued, another worker
                // can finish one and, with them uncounted, see the subtree
                // as done while most of it is still unread.
                let done = walk.tracker.finished(top: top, added: subs.count)
                walk.queue.push(subs.map { ($0, folderPath + "/" + $0.name, top) })
                if done {
                    tops[top].finish()
                    onSubtree(tops[top])
                }
                walk.queue.done()
            }
        }
        // A cancelled walk leaves some subtrees unfinished. Nobody reads
        // their totals until the result is in, so they're finished here.
        for t in tops where !t.isFinished { t.finish() }
        if onRoot == nil { root.finish() }
        return ScanResult(
            root: root, deniedPaths: walk.denied.withLock { $0 }, duration: Date().timeIntervalSince(start),
            cancelled: progress.isCancelled)
    }
}

/// Shared state of one scan.
private final class Walk: @unchecked Sendable {
    let rootDevice: Int32
    let progress: ScanProgress
    let queue = WorkQueue()
    let tracker = SubtreeCounter()
    let hardLinks = Mutex(Set<UInt64>())
    let denied = Mutex([String]())
    /// Written once on the starting thread before workers exist; read-only after.
    var topIndex: [ObjectIdentifier: Int] = [:]

    init(rootDevice: Int32, progress: ScanProgress) {
        self.rootDevice = rootDevice
        self.progress = progress
    }

    /// Reads one folder: tallies its files, creates (and returns) its subfolders.
    func read(_ folder: Folder, path: String) -> [Folder] {
        var entries: [Entry] = []
        let outcome = DirectoryReader.read(path) { entries.append($0) }
        if outcome != .ok {
            folder.unreadable = true
            progress.deniedCounter.add(1, ordering: .relaxed)
            denied.withLock { if $0.count < 500 { $0.append(path) } }
            return []
        }

        let siblings = Set(entries.lazy.map(\.name))
        var subs: [Folder] = []
        var found: [FoundFile] = []
        var files = 0
        var bytes: Int64 = 0
        for e in entries {
            switch e.kind {
            case .folder:
                // Stay on one volume: mount points and other disks are skipped.
                guard e.device == rootDevice else { continue }
                subs.append(
                    Folder(
                        name: e.name, parent: folder,
                        rebuildable: Classifier.rebuildable(folder: e.name, siblings: siblings)))
            case .file:
                // A hard-linked file costs its blocks once, like `du`.
                if e.linkCount > 1 && !hardLinks.withLock({ $0.insert(e.fileID).inserted }) { continue }
                let kind = folder.inheritedKind ?? Classifier.kind(ofFile: e.name)
                folder.ownBytes[kind] += e.allocated
                let modified = Date(timeIntervalSince1970: e.modified)
                folder.latestChange = max(folder.latestChange, modified)
                folder.ownLatestChange = folder.latestChange
                if e.allocated >= Folder.listedFileSize {
                    folder.listedFiles.append(FileItem(name: e.name, size: e.allocated, modified: modified, kind: kind))
                    found.append(FoundFile(name: e.name, folder: path, size: e.allocated, modified: modified, kind: kind))
                } else {
                    folder.smallFileCount += 1
                    folder.smallFileBytes += e.allocated
                }
                files += 1
                bytes += e.allocated
            case .symlink, .other:
                continue  // never followed, never counted
            }
        }
        folder.subfolders = subs
        if !found.isEmpty { progress.found.withLock { $0.append(contentsOf: found) } }
        progress.filesCounter.add(files, ordering: .relaxed)
        progress.foldersCounter.add(1, ordering: .relaxed)
        progress.bytesCounter.add(bytes, ordering: .relaxed)
        return subs
    }
}

/// LIFO work stack with a count of folders not yet fully processed, so idle
/// workers can tell "empty for now" from "walk finished".
private final class WorkQueue: @unchecked Sendable {
    typealias Item = (Folder, String, Int)
    // Guarded by `condition`.
    private var stack: [Item] = []
    private var outstanding = 0
    private let condition = NSCondition()

    func push(_ items: [Item]) {
        guard !items.isEmpty else { return }
        condition.lock()
        stack.append(contentsOf: items)
        outstanding += items.count
        condition.broadcast()
        condition.unlock()
    }

    func pop(cancelled: ScanProgress) -> Item? {
        condition.lock()
        defer { condition.unlock() }
        while stack.isEmpty {
            if outstanding == 0 || cancelled.isCancelled { return nil }
            condition.wait(until: Date().addingTimeInterval(0.2))
        }
        if cancelled.isCancelled {
            outstanding -= stack.count
            stack.removeAll()
            return nil
        }
        return stack.removeLast()
    }

    func done() {
        condition.lock()
        outstanding -= 1
        if outstanding == 0 { condition.broadcast() }
        condition.unlock()
    }
}

/// Pending folder count per top-level subtree.
private final class SubtreeCounter: Sendable {
    private let pending = Mutex([Int]())

    func start(count: Int) {
        pending.withLock { $0 = Array(repeating: 1, count: count) }
    }

    /// Records that a folder in `top` finished and queued `added` more.
    /// True exactly once: when that subtree has nothing left.
    func finished(top: Int, added: Int) -> Bool {
        pending.withLock {
            $0[top] += added - 1
            return $0[top] == 0
        }
    }
}
