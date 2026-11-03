import AppKit
import StorageKit
import SwiftUI

/// A file from anywhere in the tree, for the Large Files table.
struct LargeFile: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let folder: String
    let size: Int64
    let modified: Date
    let kind: FileKind
    var id: String { path }
    var marked: Marked { Marked(path: path, name: name, size: size, isFolder: false) }
}

/// The Browse list's filter: name, kind and when things last changed.
struct BrowseFilter: Hashable {
    var query = ""
    var kind: FileKind?
    var date = DateFilter()

    var isActive: Bool { !query.isEmpty || kind != nil || date.isActive }

    func matches(_ e: DiskEntry) -> Bool {
        guard isActive else { return true }
        guard !e.pending else { return false }
        return (query.isEmpty || e.name.localizedCaseInsensitiveContains(query))
            && (kind == nil || e.kind == kind)
            && date.matches(e.modified)
    }
}

/// Something marked for removal.
struct Marked: Hashable {
    let path: String
    let name: String
    let size: Int64
    let isFolder: Bool
}

/// State of the disk map: the scanned tree, where the user is in it, what's
/// marked, and what the last Trash move can undo.
@MainActor
@Observable
final class StorageModel {
    /// The ways the disk map can be drawn, picked from the toolbar menu.
    enum Chart: String, CaseIterable, Identifiable {
        case rings, wheel, pie, boxes, columns, bars
        var id: String { rawValue }

        var title: String {
            switch self {
            case .rings: "Rings"
            case .wheel: "Wheel"
            case .pie: "Pie"
            case .boxes: "Boxes"
            case .columns: "Columns"
            case .bars: "Bars"
            }
        }

        var detail: String {
            switch self {
            case .rings: "Sunburst, four levels deep"
            case .wheel: "One ring, total in the middle"
            case .pie: "Classic pie with labels"
            case .boxes: "Treemap, two levels"
            case .columns: "Icicle, levels left to right"
            case .bars: "Ranked bars"
            }
        }

        var symbol: String {
            switch self {
            case .rings: "circle.circle"
            case .wheel: "circle.dashed.inset.filled"
            case .pie: "chart.pie"
            case .boxes: "square.grid.3x3.square"
            case .columns: "rectangle.split.3x1"
            case .bars: "chart.bar.xaxis"
            }
        }
    }
    enum Tab: Hashable { case browse, largeFiles, changes, skipped }

    private(set) var root: Folder?
    private(set) var current: Folder?
    private(set) var rootPath = Home.path
    private(set) var scanning = false
    private(set) var liveFiles = 0
    private(set) var liveBytes: Int64 = 0
    private(set) var denied: [String] = []
    /// Saved scans of the mapped folder, newest first.
    private(set) var history: [SnapshotRef] = []
    /// The two scans being compared (older → newer).
    private(set) var compareFrom: SnapshotRef?
    private(set) var compareTo: SnapshotRef?
    private(set) var changes: [Change] = []
    /// Net change of the whole folder between the two scans.
    private(set) var overallDelta: Int64 = 0
    private(set) var comparing = false
    private(set) var largeFiles: [LargeFile] = []
    private(set) var lastDuration: TimeInterval?
    /// Bumped whenever the tree's shape changes (streamed subtree, prune,
    /// undo) so charts re-lay out exactly then and not on every hover.
    private(set) var revision = 0
    /// Top-level subtrees finished so far in a running scan.
    private var completed = Set<ObjectIdentifier>()

    var chart: Chart = Chart(rawValue: UserDefaults.standard.string(forKey: "diskMap.chart") ?? "") ?? .rings {
        didSet { UserDefaults.standard.set(chart.rawValue, forKey: "diskMap.chart") }
    }
    var colorByKind = false
    var tab: Tab = .browse
    var hovered: Segment?
    /// Rows selected in the Browse list (paths of the open folder's items);
    /// selected folders light up in the chart too.
    var selection = Set<String>() {
        didSet { selectedFolders = Set((current?.subfolders ?? []).filter { selection.contains($0.path) }.map(\.id)) }
    }
    private(set) var selectedFolders = Set<ObjectIdentifier>()
    var browseFilter = BrowseFilter()
    var marked: [String: Marked] = [:]
    var showReview = false
    private(set) var notice: Notice?

    struct Notice: Equatable {
        let text: String
        let canUndo: Bool
    }

    private enum Pruned {
        case folder(parent: Folder, child: Folder)
        case file(parent: Folder, item: FileItem)
    }

    private var progress: ScanProgress?
    private var poller: Task<Void, Never>?
    private var epoch = 0
    /// The running scan was started ahead of need, not by the user.
    private var scanInBackground = false
    private var undoRecords: [TrashRecord] = []
    /// The history record of the move Undo would put back.
    private(set) var undoLogID: UUID?
    /// Something from the last move can still be put back, and nothing else runs.
    var canUndo: Bool { !undoRecords.isEmpty && !trashing }
    private var undoPruned: [Pruned] = []

    // MARK: Scanning

    /// A saved scan younger than this makes launch skip the walk; opening
    /// the pane still scans.
    static let freshFor: TimeInterval = 30 * 60

    /// At launch: walks `path` with fewer threads and low priority, unless a
    /// recent scan is saved or the map is already loaded.
    func prewarm(path: String) {
        guard root == nil, !scanning else { return }
        if let last = SnapshotStore.history(for: path).first, Date().timeIntervalSince(last.date) < Self.freshFor {
            return
        }
        scan(path: path, background: true)
    }

    func scan(path: String, background: Bool = false) {
        // The tree mustn't be swapped while a move or Undo works on it; the
        // scan starts once that's done.
        guard !trashing else {
            scanAfterTrash = (path, background)
            return
        }
        progress?.cancel()
        epoch += 1
        let run = epoch
        scanInBackground = background
        let p = ScanProgress()
        progress = p
        rootPath = path
        root = nil
        current = nil
        hovered = nil
        marked.removeAll()
        denied = []
        largeFiles = []
        completed = []
        scanning = true
        liveFiles = 0
        liveBytes = 0
        // Earlier scans of this folder can be compared while the new one runs.
        history = SnapshotStore.history(for: path)
        compare(from: history.dropFirst().first, to: history.first)

        poller?.cancel()
        poller = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                self?.liveFiles = p.files
                self?.liveBytes = p.bytes
                // Large files trickle into their list about twice a second.
                tick += 1
                if tick % 3 == 0 { self?.addFound(p.drainFound(), run: run) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        let level = PerformanceLevel.current()
        let workers = level.workers(background: background)
        Task.detached(priority: level.priority(background: background)) { [weak self] in
            let result = StorageScanner.scan(
                path: path, progress: p, workers: workers,
                onRoot: { r in Task { @MainActor in self?.installRoot(r, run: run) } },
                onSubtree: { f in Task { @MainActor in self?.subtreeDone(f, run: run) } })
            // The root was on screen all along, so its totals are summed on
            // the main actor, where it's read; the walk never writes it.
            await MainActor.run { result.root.finish() }
            let large = Self.collectLargeFiles(result.root)
            // Kept for comparing even when part couldn't be read, marked so
            // what was missed never shows as having shrunk or vanished.
            let snapshot = result.cancelled
                ? nil : Snapshot(of: result.root, incomplete: !result.deniedPaths.isEmpty || result.root.unreadable)
            await self?.finish(result, large: large, snapshot: snapshot, run: run)
        }
    }

    func rescan() { scan(path: rootPath) }

    func cancelScan() { progress?.cancel() }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: rootPath)
        panel.message = "Choose a folder or disk to map"
        if panel.runModal() == .OK, let url = panel.url { scan(path: url.path) }
    }

    /// Merges large files found mid-scan into the list, keeping the biggest.
    /// The finished scan replaces the list with the complete one.
    private func addFound(_ found: [FoundFile], run: Int) {
        guard run == epoch, scanning, !found.isEmpty else { return }
        var all = largeFiles
        all.reserveCapacity(all.count + found.count)
        for f in found {
            all.append(LargeFile(path: f.path, name: f.name, folder: f.folder, size: f.size, modified: f.modified, kind: f.kind))
        }
        if all.count > Self.largeFileLimit {
            all.sort { $0.size > $1.size }
            all.removeLast(all.count - Self.largeFileLimit)
        }
        largeFiles = all
    }

    nonisolated static let largeFileLimit = 5000

    private func installRoot(_ r: Folder, run: Int) {
        guard run == epoch, root == nil else { return }
        root = r
        current = r
        revision += 1
    }

    private func subtreeDone(_ f: Folder, run: Int) {
        guard run == epoch, scanning else { return }
        completed.insert(f.id)
        revision += 1
    }

    private func finish(_ r: ScanResult, large: [LargeFile], snapshot: Snapshot?, run: Int) {
        guard run == epoch else { return }
        poller?.cancel()
        // Keep the folder the user drilled into while the scan ran.
        let keep = current.map(\.path)
        root = r.root
        current = keep.flatMap { r.root.find(path: $0) } ?? r.root
        denied = r.deniedPaths
        largeFiles = large
        lastDuration = r.duration
        liveFiles = r.root.fileCount
        liveBytes = r.root.size
        if let snapshot {
            // A scan started ahead of need adds to the history only every
            // few hours, so relaunches don't push older scans out of it.
            if !scanInBackground || SnapshotStore.isDue(for: snapshot.rootPath) { SnapshotStore.save(snapshot) }
            history = SnapshotStore.history(for: r.root.path)
            // Default: this scan against the one before it.
            compare(from: history.dropFirst().first, to: history.first)
        }
        scanning = false
        revision += 1
    }

    /// Compares two saved scans. Loading and diffing run off the main actor;
    /// a newer request supersedes one still in flight.
    func compare(from: SnapshotRef?, to: SnapshotRef?) {
        compareFrom = from
        compareTo = to
        compareEpoch += 1
        let run = compareEpoch
        guard let from, let to, from != to else {
            // A comparison still running is superseded by this one.
            changes = []
            overallDelta = 0
            comparing = false
            return
        }
        // Always diff older → newer, whichever order they were picked in.
        let (a, b) = from.date <= to.date ? (from, to) : (to, from)
        comparing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let old = SnapshotStore.load(a)
            let new = SnapshotStore.load(b)
            let diff = (old != nil && new != nil) ? old!.changes(to: new!) : []
            let delta = (new?.totalSize ?? 0) - (old?.totalSize ?? 0)
            await self?.applyComparison(diff, delta: delta, run: run)
        }
    }

    private var compareEpoch = 0

    private func applyComparison(_ diff: [Change], delta: Int64, run: Int) {
        guard run == compareEpoch else { return }
        changes = diff
        overallDelta = delta
        comparing = false
    }

    nonisolated private static func collectLargeFiles(_ root: Folder, limit: Int = StorageModel.largeFileLimit) -> [LargeFile] {
        var out: [LargeFile] = []
        var stack = [root]
        while let f = stack.popLast() {
            let path = f.path
            for item in f.listedFiles {
                out.append(
                    LargeFile(
                        path: path + "/" + item.name, name: item.name, folder: path, size: item.size,
                        modified: item.modified, kind: item.kind))
            }
            stack.append(contentsOf: f.subfolders)
        }
        out.sort { $0.size > $1.size }
        return Array(out.prefix(limit))
    }

    /// While scanning, only top-level subtrees that have finished are shown;
    /// the rest are still being written by the scanner.
    var isReady: (Folder) -> Bool {
        let live = scanning
        let done = completed
        let r = root
        return { f in !live || f.parent !== r || done.contains(f.id) }
    }

    func isPending(_ f: Folder) -> Bool { !isReady(f) }

    /// A folder's size as far as it's known: its own total once finished,
    /// else the sum of the parts that are (the root, mid-scan).
    func chartedSize(_ f: Folder) -> Int64 {
        guard scanning, f.parent == nil else { return f.size }
        return chartParts(of: f, include: isReady).reduce(0) { $0 + $1.size }
    }

    // MARK: Navigation

    func open(_ f: Folder) {
        guard isReady(f) else { return }
        current = f
        hovered = nil
        selection = []
        revision += 1
    }

    /// Hovered, or selected in the list.
    func isHighlighted(_ s: Segment) -> Bool {
        if hovered == s { return true }
        if !selectedFolders.isEmpty, case .folder(let f) = s { return selectedFolders.contains(f.id) }
        return false
    }

    /// Opens the folder at `path` in Browse, selecting `select` inside it.
    func show(folder path: String, select: String? = nil) {
        guard let f = root?.find(path: path) else { return }
        open(f)
        if let select { selection = [select] }
        tab = .browse
    }

    func back() {
        guard let p = current?.parent else { return }
        open(p)
    }

    var lineage: [Folder] { current?.lineage ?? [] }

    func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    // MARK: Marking

    func isMarked(_ path: String) -> Bool { marked[path] != nil }

    func toggle(_ m: Marked) {
        if marked[m.path] != nil { marked[m.path] = nil } else { marked[m.path] = m }
    }

    func mark(_ items: [Marked]) {
        for m in items { marked[m.path] = m }
    }

    func unmark(_ paths: some Sequence<String>) {
        for p in paths { marked[p] = nil }
    }

    func mark(_ s: Segment) -> Marked? {
        guard case .folder(let f) = s else { return nil }
        return Marked(path: f.path, name: f.name, size: f.size, isFolder: true)
    }

    /// Counted once when a folder and something inside it are both marked.
    var markedBytes: Int64 {
        let top = Set(Trasher.outermost(marked.keys))
        return marked.values.filter { top.contains($0.path) }.reduce(0) { $0 + $1.size }
    }

    /// Marks every rebuildable folder directly inside the current one.
    func markRebuildable() {
        for f in current?.subfolders ?? [] where f.rebuildable != nil {
            marked[f.path] = Marked(path: f.path, name: f.name, size: f.size, isFolder: true)
        }
    }

    // MARK: Trash

    /// Trashing prunes the tree, which a running scan is still reading.
    var canTrash: Bool { !scanning && !trashing && !marked.isEmpty }
    private(set) var trashing = false
    /// Where moved items go; tests use a folder of their own.
    var trashBackend: TrashBackend = .live

    /// Moves the marked items to the Trash off the main thread, then prunes
    /// the tree here.
    func trashMarked() {
        guard canTrash else { return }
        // A folder and something inside it can both be marked; moving only
        // the outer one keeps sizes counted once and undo in a valid order.
        let top = Set(Trasher.outermost(marked.keys))
        let items = marked.values.filter { top.contains($0.path) }
        // Each goes only while it's still the kind of item that was marked.
        let folders = Set(items.filter(\.isFolder).map(\.path))
        let paths = items.map(\.path)
        let backend = trashBackend
        trashing = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Trasher.moveToTrash(paths, through: TrashGate(still: { p in
                    var st = stat()
                    guard lstat(p, &st) == 0 else { return false }
                    return (st.st_mode & S_IFMT == S_IFDIR) == folders.contains(p)
                }), backend: backend)
            }.value
            trashing = false
            applyTrash(outcome, items: items)
            startScanAfterTrash()
        }
    }

    /// A scan asked for while a move or Undo ran.
    private var scanAfterTrash: (path: String, background: Bool)?

    private func startScanAfterTrash() {
        guard let next = scanAfterTrash else { return }
        scanAfterTrash = nil
        scan(path: next.path, background: next.background)
    }

    private func applyTrash(_ outcome: TrashOutcome, items: [Marked]) {
        var pruned: [Pruned] = []
        var freed: Int64 = 0
        let movedPaths = Set(outcome.moved.map(\.original.path))
        for item in items where movedPaths.contains(item.path) {
            freed += item.size
            if item.isFolder, let f = root?.find(path: item.path), let parent = f.parent {
                parent.remove(f)
                pruned.append(.folder(parent: parent, child: f))
            } else if let parent = root?.find(path: (item.path as NSString).deletingLastPathComponent),
                let file = parent.listedFiles.first(where: { $0.name == (item.path as NSString).lastPathComponent })
            {
                parent.removeFile(named: file.name)
                pruned.append(.file(parent: parent, item: file))
            }
        }
        // Inner marks went along with their folder.
        for path in marked.keys where movedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            marked[path] = nil
        }
        largeFiles.removeAll { lf in movedPaths.contains(lf.path) || movedPaths.contains { lf.path.hasPrefix($0 + "/") } }
        undoRecords = outcome.moved
        undoPruned = pruned
        let record = CleanupRecord(source: "Disk Map", items: outcome.moved.count, bytes: freed, failed: outcome.failed.count)
        undoLogID = record.id
        CleanupLog.submit(record)
        // If the open folder went to the Trash, step out to its parent.
        if let c = current, movedPaths.contains(where: { c.path == $0 || c.path.hasPrefix($0 + "/") }) {
            current = root?.find(path: (c.path as NSString).deletingLastPathComponent) ?? root
        }
        revision += 1
        var text = outcome.moved.isEmpty && !outcome.failed.isEmpty
            ? nothingMoved(outcome.failed)
            : "Moved \(outcome.moved.count) item\(outcome.moved.count == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))) to the Trash"
        if !outcome.moved.isEmpty && !outcome.failed.isEmpty { text += " · \(outcome.failed.count) skipped" }
        showNotice(Notice(text: text, canUndo: !outcome.moved.isEmpty))
    }

    /// Puts the last move back, off the main thread.
    func undoTrash() {
        guard !trashing, !undoRecords.isEmpty else { return }
        let records = undoRecords
        trashing = true
        Task {
            let failedRecords = await Task.detached(priority: .userInitiated) { Trasher.restore(records) }.value
            trashing = false
            applyUndo(failedRecords)
            startScanAfterTrash()
        }
    }

    private func applyUndo(_ failedRecords: [TrashRecord]) {
        let failed = Set(failedRecords.map(\.original.path))
        var bytes: Int64 = 0
        var stillOut: [Pruned] = []
        for p in undoPruned {
            switch p {
            case .folder(let parent, let child) where !failed.contains(child.path):
                parent.restore(child)
                bytes += child.size
            case .file(let parent, let item) where !failed.contains(parent.path + "/" + item.name):
                parent.restoreFile(item)
                bytes += item.size
            default:
                stillOut.append(p)
            }
        }
        let restored = undoRecords.count - failed.count
        if let id = undoLogID { CleanupLog.submitRestore(id, restored: restored, bytes: bytes, failed: failed.count) }
        // What couldn't come back stays ready for another try.
        undoRecords = failedRecords
        undoPruned = stillOut
        if failed.isEmpty { undoLogID = nil }
        revision += 1
        showNotice(Notice(
            text: failed.isEmpty ? "Restored \(restored) item\(restored == 1 ? "" : "s")" : "Restored \(restored); \(failed.count) couldn't be put back. Undo tries those again.",
            canUndo: !failed.isEmpty))
    }

    /// The last move's notice with its Undo, shown again after a passing
    /// notice while there's still something to put back.
    private var undoNotice: Notice?

    /// A notice with Undo stays until it's used, closed or replaced; any
    /// other passes after a few seconds.
    private func showNotice(_ n: Notice) {
        withAnimation(.snappy) { notice = n }
        if n.canUndo {
            undoNotice = n
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard notice == n else { return }
            withAnimation(.snappy) { notice = undoRecords.isEmpty ? nil : undoNotice }
        }
    }

    func dismissNotice() { withAnimation(.snappy) { notice = nil } }
}
