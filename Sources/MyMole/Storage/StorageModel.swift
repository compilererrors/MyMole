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
    /// What moving it frees, where the scan saw it share blocks with clones.
    var reclaim: Reclaim? = nil
    var id: String { path }
    var marked: Marked { Marked(path: path, name: name, size: size, isFolder: false) }
}

/// The Browse list's filter: name, kind and when things last changed.
struct BrowseFilter: Hashable, Codable {
    var query = ""
    var kind: FileKind?
    var date = DateFilter()
    /// Look through the whole scan, not only the open folder.
    var wholeScan = false

    var isActive: Bool { !query.isEmpty || kind != nil || date.isActive }
    var criteriaCount: Int { (query.isEmpty ? 0 : 1) + (kind == nil ? 0 : 1) + (date.isActive ? 1 : 0) }
    mutating func clearCriteria() {
        query = ""
        kind = nil
        date = DateFilter()
    }

    func matches(_ e: DiskEntry) -> Bool {
        guard isActive else { return true }
        guard !e.pending else { return false }
        return (query.isEmpty || DSFilterField.matches(query, e.name))
            && (kind == nil || e.kind == kind)
            && date.matches(e.modified)
    }
}

/// Something marked for removal.
struct Marked: Hashable, Sendable {
    let path: String
    let name: String
    let size: Int64
    let isFolder: Bool
    var needsRefresh = false
    var proof: FolderContents.Item?

    static func parent(of path: String, in paths: Set<String>) -> String? {
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            if paths.contains(parent) { return parent }
            let next = (parent as NSString).deletingLastPathComponent
            if next == parent { break }
            parent = next
        }
        return nil
    }
}

/// State of the disk map: the scanned tree, where the user is in it, what's
/// marked, and what the last Trash move can undo.
@MainActor
@Observable
final class StorageModel {
    typealias Scan = @Sendable (String, ScanProgress, Int, @escaping @Sendable (Folder) -> Void, @Sendable (Folder) -> Void, Set<String>) -> ScanResult
    @ObservationIgnored var scanFolder: Scan = { path, progress, workers, root, subtree, skip in
        StorageScanner.scan(path: path, progress: progress, workers: workers, onRoot: root, onSubtree: subtree, skip: skip)
    }
    @ObservationIgnored var scanBudget = ScanBudget.shared
    @ObservationIgnored private var scanSession: DiskScanSession?
    @ObservationIgnored var scanSubfolder: @Sendable (String, ScanProgress, Int, Set<String>, FileKind?) -> ScanResult = {
        StorageScanner.scan(path: $0, progress: $1, workers: $2, skip: $3, inheritedKind: $4)
    }
    @ObservationIgnored private var mapReader: (owner: UUID, job: Task<Void, Never>)?
    @ObservationIgnored var collectFiles: @Sendable (Folder, @Sendable () -> Bool) -> [LargeFile] = {
        StorageModel.collectLargeFiles($0, limit: .max, stop: $1)
    }
    /// The ways the disk map can be drawn, picked from the toolbar menu.
    enum Chart: String, CaseIterable, Identifiable {
        case rings, wheel, pie, boxes, columns, bars
        var id: String { rawValue }

        var title: String {
            switch self {
            case .rings: String(localized: "Rings")
            case .wheel: String(localized: "Wheel")
            case .pie: String(localized: "Pie")
            case .boxes: String(localized: "Boxes")
            case .columns: String(localized: "Columns")
            case .bars: String(localized: "Bars")
            }
        }

        var detail: String {
            switch self {
            case .rings: String(localized: "Sunburst, four levels deep")
            case .wheel: String(localized: "One ring, total in the middle")
            case .pie: String(localized: "Classic pie with labels")
            case .boxes: String(localized: "Treemap, two levels")
            case .columns: String(localized: "Icicle, levels left to right")
            case .bars: String(localized: "Ranked bars")
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

    /// Folders inside the mapped one the user had skipped, for this scan.
    private(set) var skipped: [String] = []

    /// A scan opened from a file, only to look at: where it came from and
    /// when it was made. Nothing can be chosen or moved while it's shown.
    private(set) var opened: (file: String, date: Date)?
    private(set) var exportProblem: String?

    /// Writes the finished scan to a file the user picks.
    func exportScan() {
        guard let root, !scanning, opened == nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(root.name) \(Date.now.formatted(date: .numeric, time: .omitted)).mymolescan"
            .replacingOccurrences(of: "/", with: "-")
        panel.message = String(localized: "Save this scan to look at later, on this Mac or another")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let export = ScanExport(of: root)
        Task {
            let failed = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try export.data().write(to: url, options: .atomic)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            exportProblem = failed.map { String(localized: "The scan couldn't be saved: \($0)") }
            showNotice(Notice(text: failed == nil ? String(localized: "Saved the scan to \(url.lastPathComponent)") : exportProblem ?? "", canUndo: false))
        }
    }

    /// Opens a saved scan to look at.
    func openExportedScan() {
        guard !scanning, !trashing else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Open a scan saved from MyMole, to look at")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(exported: url) }
    }

    func open(exported url: URL) async {
        let read = await Task.detached(priority: .userInitiated) { () -> Result<(ScanExport, Folder, ScanIndex, [LargeFile]), ScanExport.Failure> in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= ScanExport.byteLimit,
                let data = try? Data(contentsOf: url)
            else { return .failure(.tooLarge) }
            do {
                let export = try ScanExport.read(data)
                let tree = export.tree()
                return .success((export, tree, ScanIndex(tree, limit: .max), Self.collectLargeFiles(tree, limit: .max)))
            } catch let f as ScanExport.Failure {
                return .failure(f)
            } catch {
                return .failure(.damaged)
            }
        }.value
        switch read {
        case .failure(let f):
            let why: String = switch f {
            case .tooLarge: String(localized: "It's larger than a saved scan can be.")
            case .notAScan: String(localized: "It isn't a scan saved from MyMole.")
            case .newerVersion: String(localized: "It was saved by a newer MyMole.")
            case .damaged: String(localized: "It's damaged.")
            }
            showNotice(Notice(text: String(localized: "\(url.lastPathComponent) couldn't be opened: \(why)"), canUndo: false))
        case .success(let (export, tree, index, large)):
            guard !trashing else { return }
            progress?.cancel()
            epoch += 1
            refreshing = false
            scanning = false
            marked.removeAll()
            allContentsChoice = nil
            denied = []
            skipped = []
            history = []
            compare(from: nil, to: nil)
            diskSpace = nil
            rootPath = export.rootPath
            root = tree
            current = tree
            self.index = index
            installLargeFiles(large, spill: nil)
            liveFiles = tree.fileCount
            liveBytes = tree.size
            opened = (url.lastPathComponent, export.date)
            revision += 1
        }
    }

    /// Leaves `path` out of every scan from now on, and maps again without it.
    func skipFromNowOn(_ path: String) {
        DiskMapSkips.add(path)
        rescan()
    }

    /// Every folder and listed file of the finished scan, for searching it whole.
    private(set) var index: ScanIndex?
    /// Where saved scans are kept; tests use a folder of their own.
    var snapshotBase: URL = SnapshotStore.defaultBase
    private(set) var root: Folder?
    private(set) var current: Folder?
    private(set) var rootPath = Home.path
    private(set) var scanning = false
    /// A scan of the folder already mapped is running: the earlier map
    /// stays on screen, with its folder and selection, until the new one is
    /// complete, and stays if the scan is stopped.
    private(set) var refreshing = false
    /// The tree on screen is the one a running scan is still writing.
    var showingLive: Bool { scanning && !refreshing }
    var currentIsEmpty: Bool {
        guard let current, isReady(current), !current.unreadable, !showingLive || current.isFinished else { return false }
        return current.subfolders.isEmpty && current.listedFiles.isEmpty && current.smallFileCount == 0
    }
    private(set) var liveFiles = 0
    private(set) var liveBytes: Int64 = 0
    private(set) var denied: [String] = []
    /// Saved scans of the mapped folder, newest first.
    private(set) var history: [SnapshotRef] = []
    /// The two scans being compared (older → newer).
    private(set) var compareFrom: SnapshotRef?
    private(set) var compareTo: SnapshotRef?
    private(set) var changes: [Change] = []
    /// Net change of the whole folder between the two scans; nil when a scan
    /// was incomplete or couldn't be read, so the total isn't known.
    private(set) var overallDelta: Int64? = 0
    /// Why the comparison is partial or failed, or nil.
    private(set) var compareProblem: String?
    private(set) var comparing = false
    private(set) var largeFiles: [LargeFile] = []
    /// The large files on disk instead, once they're past the memory budget
    /// of Large results; `largeFiles` is empty then.
    private(set) var largeFilesSpill: SpillTable?
    /// Moved to the Trash since the table was written: hidden from it.
    private(set) var spillRemoved: [String] = []
    /// What a large file list may take in memory; tests set their own.
    @ObservationIgnored var largeResultBudget: @Sendable () -> Int64? = { ResultSize.current().memoryBudget() }
    @ObservationIgnored var spillBase = SpillTable.defaultBase

    /// The spilled rows still in the map.
    var spillKeep: @Sendable (SpillTable.Row) -> Bool {
        let gone = spillRemoved
        return { row in !gone.contains { row.path == $0 || row.path.hasPrefix($0 + "/") } }
    }

    /// Puts a new large file list in place, in memory or on disk, and lets
    /// the previous table go: a spill never outlives the result it holds.
    private func installLargeFiles(_ files: [LargeFile], spill: SpillTable?) {
        let old = largeFilesSpill
        largeFilesSpill = spill
        spillRemoved = []
        largeFiles = spill == nil ? files : []
        if let old, old !== spill { Task.detached(priority: .utility) { old.remove() } }
    }

    /// Writes `files` to disk when they'd take more memory than `budget`;
    /// nil keeps them in memory, also when the write fails or is stopped.
    nonisolated static func spillIfLarge(_ files: [LargeFile], budget: Int64?, base: URL, stop: () -> Bool) -> SpillTable? {
        guard let budget, !files.isEmpty else { return nil }
        let cost = ResultSize.memoryCost(pathBytes: files.reduce(0) { $0 + $1.path.utf8.count }, rows: files.count)
        guard cost > budget else { return nil }
        return try? SpillTable(writing: files.lazy.map { SpillTable.Row(path: $0.path, size: $0.size, modified: $0.modified, kind: $0.kind) },
                               in: base, stop: stop)
    }
    private(set) var lastDuration: TimeInterval?
    private(set) var incomplete = false
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
    /// Rows selected in Browse (including opened descendants in the tree);
    /// selected folders light up in the chart too.
    var selection = Set<String>()
    var browseFilter = BrowseFilter()
    /// Open branches survive pane changes and replacement of a completed map.
    var treeExpanded = Set<String>()
    var marked: [String: Marked] = [:] { didSet { markRevision &+= 1 } }
    private(set) var markRevision: UInt64 = 0
    private var protectionRevision: UInt64 = 0
    let removalHints = RemovalHints()
    var removalHintKey: RemovalHints.Key { .init(selection: markRevision, scope: epoch, protections: protectionRevision, busy: trashing) }
    var currentRemovalHints: RemovalHints.Value? { removalHints.value(for: removalHintKey) }
    func invalidateRemovalHints() { protectionRevision &+= 1 }
    func warmRemovalHints() async {
        guard !marked.isEmpty, !trashing, opened == nil else { return }
        let items = Array(marked.values)
        await removalHints.update(.init(key: removalHintKey, items: items, protections: protections,
                                       inspectOpenFiles: !Edition.current.isSandboxed, known: knownReclaims(items)))
    }

    /// What the scanned tree says moving each item frees, for the items it
    /// has finished reading. Siblings are looked up together, so choosing a
    /// whole folder's contents stays one pass over it.
    func knownReclaims(_ items: [Marked]) -> [String: Reclaim] {
        guard root != nil else { return [:] }
        let ready = isReady
        var out: [String: Reclaim] = [:]
        for (parentPath, children) in Dictionary(grouping: items, by: { ($0.path as NSString).deletingLastPathComponent }) {
            guard let parent = accessibleFolder(parentPath), ready(parent) else { continue }
            let folders = Dictionary(parent.subfolders.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            let files = Dictionary(parent.listedFiles.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            for item in children {
                let name = (item.path as NSString).lastPathComponent
                if item.isFolder {
                    if let f = folders[name], ready(f), f.isFinished, f.size == item.size { out[item.path] = f.reclaim }
                } else if let f = files[name], f.size == item.size {
                    out[item.path] = f.reclaim
                }
            }
        }
        return out
    }

    /// What moving each outermost item frees: from the tree where it was
    /// read, else the file as it is now. A folder the tree doesn't hold
    /// counts its size.
    nonisolated static func reclaims(of items: [Marked], known: [String: Reclaim], stop: () -> Bool = { false }) -> [String: Reclaim] {
        let top = Set(Trasher.outermost(items.map(\.path)))
        var out: [String: Reclaim] = [:]
        for item in items where top.contains(item.path) {
            guard !stop() else { break }
            if let reclaim = known[item.path] {
                out[item.path] = reclaim
            } else if !item.isFolder, let reclaim = Reclaim.file(at: item.path) {
                out[item.path] = reclaim
            } else {
                out[item.path] = Reclaim(bytes: item.size)
            }
        }
        return out
    }

    /// What moving the chosen items frees, once worked out off the main thread.
    var markedFrees: Int64? { currentRemovalHints?.frees }
    var showReview = false {
        didSet { if !showReview { reviewScan = nil } }
    }
    private var reviewScan: Int?
    var browseSort: FileSortRequest?
    private(set) var notice: Notice?

    struct Notice: Equatable {
        let text: String
        let canUndo: Bool
    }

    private enum Pruned {
        case folder(parent: Folder, child: Folder)
        case file(parent: Folder, item: FileItem)
        case smallFiles(parent: Folder, Folder.SmallFiles)
    }

    private var progress: ScanProgress?
    private var poller: Task<Void, Never>?
    private var epoch = 0
    /// The running scan was started ahead of need, not by the user.
    private var scanInBackground = false
    /// Memory pressure stopped a scan started ahead of need; its partial
    /// map goes once the scan has ended.
    private var releaseAfterStop = false
    /// What the pane maps when it opens without a map; only a map of this
    /// is let go under memory pressure, since opening brings it back.
    @ObservationIgnored var mapsOnOpen = Home.path
    /// A move that can still be put back, and where in the tree its
    /// entries were taken from.
    private struct Run: UndoableRun {
        let id: UUID
        var records: [TrashRecord]
        var pruned: [Pruned]
        var refreshAfterUndo = false
        /// What each moved item freed, by its original path, so what comes
        /// back is taken off the history's total in the same measure.
        var reclaims: [String: Reclaim] = [:]
    }

    private var shelf = UndoShelf<Run>()
    /// The move an Undo works on: one History asked for, or else the latest.
    private var target: UUID?
    private var undone: Run? { target.flatMap(shelf.run) ?? shelf.latest }
    private var undoRecords: [TrashRecord] {
        get { undone?.records ?? [] }
        set { if let id = undone?.id { shelf.update(id) { $0.records = newValue } } }
    }
    private var undoPruned: [Pruned] {
        get { undone?.pruned ?? [] }
        set { if let id = undone?.id { shelf.update(id) { $0.pruned = newValue } } }
    }
    /// The history record of the move Undo would put back.
    var undoLogID: UUID? { undone?.id }
    /// Something from the last move can still be put back, and nothing else runs.
    var canUndo: Bool { !undoRecords.isEmpty && !trashing }
    /// Whether the move of this history record can still be put back.
    func canUndo(run id: UUID) -> Bool { !(shelf.run(id)?.records.isEmpty ?? true) && !trashing }

    // MARK: Scanning

    /// A saved scan younger than this makes launch skip the walk; opening
    /// the pane still scans.
    static let freshFor: TimeInterval = 30 * 60
    /// How long a saved scan makes launch skip the walk at this responsiveness; nil never.
    @ObservationIgnored var freshWindow: @MainActor (TimeInterval) -> TimeInterval? = { Responsiveness.current().freshWindow($0) }

    /// At launch: walks `path` with fewer threads and low priority, unless a
    /// recent scan is saved or the map is already loaded.
    func prewarm(path: String) {
        guard root == nil, !scanning else { return }
        // The saved scans are read off the main actor; reading may also
        // migrate an older format.
        let base = snapshotBase
        Task { [weak self] in
            let last = await Task.detached(priority: .utility) { SnapshotStore.history(for: Volumes.historyKey(for: path), base: base).first }.value
            guard let self, root == nil, !scanning else { return }
            if let window = freshWindow(Self.freshFor), let last, Date().timeIntervalSince(last.date) < window { return }
            scan(path: path, background: true)
        }
    }

    func scan(path: String, background: Bool = false) {
        #if SMOKE
        guard let scope = try? SyntheticRun.current(), path == scope.home || path.hasPrefix(scope.home + "/") else { return }
        #endif
        // The tree mustn't be swapped while a move or Undo works on it; the
        // scan starts once that's done.
        guard !trashing else {
            scanAfterTrash = (path, background)
            return
        }
        showReview = false
        allContentsChoice = nil
        scanSession?.retire()
        progress?.cancel()
        epoch += 1
        let run = epoch
        let session = DiskScanSession()
        scanSession = session
        scanInBackground = background
        releaseAfterStop = false
        // Every result is complete: nothing a scan finds is left out of a list or a search.
        let indexLimit = Int.max
        let p = ScanProgress(collectsFound: true, keepsFound: .max)
        progress = p
        // The same folder again, with a complete map in place: that map stays.
        let keepsMap = path == rootPath && root != nil && (!scanning || refreshing)
        refreshing = keepsMap && opened == nil
        opened = nil
        rootPath = path
        if !keepsMap {
            incomplete = false
            index = nil
            root = nil
            current = nil
            hovered = nil
            marked.removeAll()
            denied = []
            installLargeFiles([], spill: nil)
        }
        completed = []
        scanning = true
        scanStarted = .now
        stopAsked = nil
        liveFiles = 0
        liveBytes = 0
        // Earlier scans of this folder can be compared while the new one
        // runs, once they're read off the main actor.
        if !keepsMap {
            history = []
            compare(from: nil, to: nil)
        }
        let base = snapshotBase
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { SnapshotStore.history(for: Volumes.historyKey(for: path), base: base) }.value
            // A scan that already finished has read the newer history itself.
            guard let self, run == epoch, scanning else { return }
            showHistory(found)
        }

        poller?.cancel()
        let interval = Responsiveness.current().publishInterval
        // Large files trickle into their list about twice a second, whatever the counts' pace.
        let foundEvery = max(1, Int((Duration.milliseconds(600) / interval).rounded()))
        poller = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                self?.liveFiles = p.files
                self?.liveBytes = p.bytes
                tick += 1
                if tick % foundEvery == 0 { self?.addFound(p.drainFound(), run: run) }
                try? await Task.sleep(for: interval)
            }
        }

        let level = PerformanceLevel.current()
        let workers = level.workers(background: background)
        let (budget, scanFolder, collectFiles) = (scanBudget, scanFolder, collectFiles)
        let (memoryBudget, spillBase) = (largeResultBudget(), spillBase)
        let skips = DiskMapSkips.under(path)
        skipped = skips.full.sorted()
        scanJob = Task.detached(priority: level.priority(background: background)) { [weak self] in
            defer { session.finish() }
            let result = await budget.run(background: background, progress: p) {
                scanFolder(path, p, workers,
                           { r in Task { @MainActor in self?.installRoot(r, run: run) } },
                           { f in Task { @MainActor in self?.subtreeDone(f, run: run) } }, skips.full)
            }
            guard session.beginFinalization() else { return }
            guard let result else {
                await self?.finish(nil, large: [], snapshot: nil, index: nil, run: run)
                return
            }
            // A cancelled refresh never replaces the visible completed map.
            // Its large-file list, search index and history are also discarded.
            if (result.cancelled || p.isCancelled) && keepsMap {
                await self?.finish(result, large: nil, snapshot: nil, index: nil, run: run, stopped: true)
                return
            }
            // The root was on screen all along, so its totals are summed on
            // the main actor, where it's read; the walk never writes it.
            await MainActor.run { result.root.finish() }
            if result.cancelled || p.isCancelled {
                await self?.addFound(p.drainFound(), run: run)
                await self?.finish(result, large: nil, snapshot: nil, index: nil, run: run, stopped: true)
                return
            }
            let large = collectFiles(result.root, { p.isCancelled })
            let spill = p.isCancelled ? nil : Self.spillIfLarge(large, budget: memoryBudget, base: spillBase, stop: { p.isCancelled })
            // For searching the whole scan; the tree doesn't change until it's handed over.
            let index = p.isCancelled ? nil : ScanIndex(result.root, limit: indexLimit, stop: { p.isCancelled })
            // Kept for comparing even when part couldn't be read, marked so
            // what was missed never shows as having shrunk or vanished.
            let snapshot = p.isCancelled
                ? nil
                : Snapshot(
                    of: result.root, incomplete: !result.deniedPaths.isEmpty || result.root.unreadable, excluded: skips.relative, stop: { p.isCancelled })
            // Read once: a stop between two reads mustn't both install the table and delete it.
            let stopped = p.isCancelled
            if stopped { spill?.remove() }
            await self?.finish(result, large: stopped ? nil : (spill == nil ? large : []), snapshot: stopped ? nil : snapshot,
                               index: stopped ? nil : index, run: run, stopped: stopped, spill: stopped ? nil : spill)
        }
    }

    func rescan() { scan(path: rootPath) }

    var refreshTitle: String {
        tab == .browse ? String(localized: "Refresh Current Folder") : String(localized: "Rescan Entire Map")
    }

    /// Refresh only the open folder. The enclosing map and its history keep
    /// their existing measurements; only an explicit Rescan walks the root.
    func refreshCurrent() {
        guard opened == nil, !scanning, !trashing else { return }
        guard tab == .browse else { rescan(); return }
        guard let root, let current, current !== root else { rescan(); return }
        guard isReady(current) else { return }
        showReview = false
        allContentsChoice = nil
        progress?.cancel()
        scanSession?.retire()
        epoch += 1
        let run = epoch
        let session = DiskScanSession()
        scanSession = session
        let p = ScanProgress()
        progress = p
        refreshing = true
        scanning = true
        scanStarted = .now
        stopAsked = nil
        liveFiles = 0
        liveBytes = 0
        let path = current.path
        let inheritedKind = current.inheritedKind
        let skips = DiskMapSkips.under(path).full
        let level = PerformanceLevel.current()
        let workers = level.workers(background: false)
        let read = scanSubfolder
        let budget = scanBudget
        poller?.cancel()
        let interval = Responsiveness.current().publishInterval
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.liveFiles = p.files
                self?.liveBytes = p.bytes
                try? await Task.sleep(for: interval)
            }
        }
        scanJob = Task.detached(priority: level.priority(background: false)) { [weak self] in
            defer { session.finish() }
            let result = await budget.run(background: false, progress: p) {
                read(path, p, workers, skips, inheritedKind)
            }
            await self?.finishFolderRefresh(result, path: path, map: root, progress: p, session: session, run: run)
        }
    }

    private func finishFolderRefresh(_ result: ScanResult?, path: String, map: Folder,
                                     progress: ScanProgress, session: DiskScanSession, run: Int) async {
        guard run == epoch else { return }
        guard let result, !result.cancelled, !progress.isCancelled, session.beginFinalization() else {
            finish(nil, large: nil, snapshot: nil, index: nil, run: run)
            return
        }
        guard !result.root.unreadable, result.deniedPaths.isEmpty else {
            finish(nil, large: nil, snapshot: nil, index: nil, run: run)
            showNotice(Notice(text: String(localized: "This folder couldn't be fully read. Its previous scan stays."), canUndo: false))
            return
        }
        // A copy briefly reads the presented map. Serialize such readers and
        // let removal join them even if another scan has since superseded us.
        let predecessor = mapReader?.job
        let owner = UUID()
        let collect = collectFiles
        let indexLimit = Int.max
        let (memoryBudget, spillBase) = (largeResultBudget(), spillBase)
        let worker = Task.detached(priority: .userInitiated) {
            await predecessor?.value
            guard !progress.isCancelled,
                  let updated = map.replacingSubtree(at: path, with: result.root, stop: { progress.isCancelled }) else { return nil as (Folder, [LargeFile], ScanIndex, SpillTable?)? }
            let files = collect(updated, { progress.isCancelled })
            guard !progress.isCancelled else { return nil }
            let index = ScanIndex(updated, limit: indexLimit, stop: { progress.isCancelled })
            let spill = progress.isCancelled ? nil : Self.spillIfLarge(files, budget: memoryBudget, base: spillBase, stop: { progress.isCancelled })
            guard !progress.isCancelled else { spill?.remove(); return nil }
            return (updated, files, index, spill)
        }
        let barrier = Task { _ = await worker.value }
        mapReader = (owner, barrier)
        let prepared = await worker.value
        if mapReader?.owner == owner { mapReader = nil }
        guard run == epoch, !progress.isCancelled, let (updated, files, index, spill) = prepared else {
            prepared?.3?.remove()
            if let prepared { RetiredValue(prepared).releaseLater() }
            if run == epoch { finish(nil, large: nil, snapshot: nil, index: nil, run: run) }
            return
        }
        let previous = RetiredValue((root, current, self.index, largeFiles))
        let location = current?.lineage.reversed().map(\.path) ?? []
        root = updated
        current = location.lazy.compactMap { updated.find(path: $0) }.first ?? updated
        self.index = index
        installLargeFiles(files, spill: spill)
        selection = selection.filter { Self.holds(updated, $0) }
        marked = marked.filter { key, _ in key != path && !key.hasPrefix(path + "/") && !path.hasPrefix(key + "/") }
        denied.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        hovered = nil
        lastDuration = nil
        finish(nil, large: nil, snapshot: nil, index: nil, run: run)
        previous.releaseLater()
        readDiskSpace(of: rootPath, run: run)
    }

    func cancelScan() {
        if scanning, stopAsked == nil { stopAsked = .now }
        progress?.cancel()
    }

    /// When the running scan started, and when it was asked to stop.
    @ObservationIgnored private var scanStarted: ContinuousClock.Instant?
    @ObservationIgnored private var stopAsked: ContinuousClock.Instant?

    /// The running walk, so a caller can wait for it to end.
    private(set) var scanJob: Task<Void, Never>?

    /// Maps `path`. In the App Sandbox a place outside the home folder is
    /// opened through the folder panel, which is what gives access to it.
    func map(place path: String) {
        if Edition.current.isSandboxed, !path.hasPrefix(Home.path + "/"), path != Home.path {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.directoryURL = URL(fileURLWithPath: path)
            panel.message = String(localized: "Choose the folder or disk to map, so MyMole may read it")
            if panel.runModal() == .OK, let url = panel.url { scan(path: url.path) }
            return
        }
        scan(path: path)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: rootPath)
        panel.message = String(localized: "Choose a folder or disk to map")
        if panel.runModal() == .OK, let url = panel.url { scan(path: url.path) }
    }

    /// Merges large files found mid-scan into the list, keeping the biggest.
    /// The finished scan replaces the list with the complete one.
    private func addFound(_ found: [FoundFile], run: Int) {
        // While the earlier map stays, so does its list.
        guard run == epoch, scanning, !refreshing, !found.isEmpty else { return }
        var all = largeFiles
        all.reserveCapacity(all.count + found.count)
        for f in found {
            all.append(LargeFile(path: f.path, name: f.name, folder: f.folder, size: f.size, modified: f.modified, kind: f.kind,
                                 reclaim: f.reclaim.flatMap { $0.bytes < f.size ? $0 : nil }))
        }
        largeFiles = all
    }

    /// The largest files listed at the standard result size.
    nonisolated static let standardLargeFiles = 5000

    /// Whether `folder` has a folder or a listed file at `path`.
    nonisolated static func holds(_ folder: Folder, _ path: String) -> Bool {
        if folder.find(path: path) != nil { return true }
        let name = (path as NSString).lastPathComponent
        return folder.find(path: (path as NSString).deletingLastPathComponent)?.listedFiles.contains { $0.name == name } ?? false
    }

    private func installRoot(_ r: Folder, run: Int) {
        guard run == epoch, root == nil, !refreshing else { return }
        if let scanStarted { Timings.record(.firstMap, since: scanStarted) }
        root = r
        current = r
        revision += 1
    }

    private func subtreeDone(_ f: Folder, run: Int) {
        guard run == epoch, scanning, !refreshing else { return }
        completed.insert(f.id)
        revision += 1
    }

    private func finish(_ r: ScanResult?, large: [LargeFile]?, snapshot: Snapshot?, index: ScanIndex?, run: Int, stopped: Bool = false,
                        spill: SpillTable? = nil) {
        // A table that didn't become the list on screen goes at once.
        defer { if let spill, spill !== largeFilesSpill { spill.remove() } }
        guard run == epoch else { return }
        scanSession = nil
        poller?.cancel()
        if let stopAsked, stopped || r?.cancelled != false { Timings.record(.stop, since: stopAsked) }
        stopAsked = nil
        guard let r else {
            refreshing = false
            scanning = false
            liveFiles = root?.fileCount ?? 0
            liveBytes = root?.size ?? 0
            revision += 1
            return
        }
        // A stopped rescan leaves the earlier, complete map as it was.
        if refreshing && (r.cancelled || stopped) {
            refreshing = false
            scanning = false
            liveFiles = root?.fileCount ?? 0
            liveBytes = root?.size ?? 0
            revision += 1
            return
        }
        refreshing = false
        let previous = RetiredValue((root, current, self.index, largeFiles))
        defer { previous.releaseLater() }
        self.index = index
        // Keep the folder the user drilled into, and what's selected there
        // as far as the new map still has it. Marks were made against the
        // earlier sizes, so they start over.
        let keep = current.map(\.path)
        let selected = selection
        root = r.root
        current = keep.flatMap { r.root.find(path: $0) } ?? r.root
        hovered = nil
        if !trashing && (!showReview || reviewScan != run) { marked.removeAll() }
        if let current { selection = selected.filter { Self.holds(current, $0) } }
        denied = r.deniedPaths
        incomplete = stopped || r.cancelled || !r.deniedPaths.isEmpty || r.root.unreadable
        if let large { installLargeFiles(large, spill: spill) }
        lastDuration = r.duration
        liveFiles = r.root.fileCount
        liveBytes = r.root.size
        if let snapshot {
            // A scan started ahead of need adds to the history only every
            // few hours, so relaunches don't push older scans out of it.
            // Saved and read back off the main actor, in order with the
            // other saved results.
            let background = scanInBackground
            let base = snapshotBase
            StoreWrites.submit { [weak self] in
                // On another disk, the history is that disk's own.
                let key = Volumes.historyKey(for: snapshot.rootPath)
                if !background || SnapshotStore.isDue(for: key, base: base) { SnapshotStore.save(snapshot, key: key, base: base) }
                let found = SnapshotStore.history(for: key, base: base)
                Task { @MainActor in
                    guard let self, run == self.epoch else { return }
                    self.showHistory(found)
                }
            }
        }
        scanning = false
        revision += 1
        if releaseAfterStop {
            releaseAfterStop = false
            releaseMap()
            return
        }
        readDiskSpace(of: r.root.path, run: run)
    }

    /// Memory macOS asked back. A scan started ahead of need stops, and the
    /// partial map it leaves goes. Under critical pressure a finished map of
    /// the home folder goes too while the pane isn't on screen; opening the
    /// pane maps again, and saved scans and Changes stay.
    func relieveMemory(critical: Bool, onScreen: Bool) {
        if scanning, scanInBackground, !refreshing {
            releaseAfterStop = !onScreen
            cancelScan()
            return
        }
        if critical, !onScreen { releaseMap() }
    }

    /// A lean setting doesn't keep the map while you're elsewhere; opening
    /// the pane maps again. The same guards as under memory pressure apply.
    func releaseIdleMap() { releaseMap() }

    /// Lets go of the map, unless anything depends on it: marks, a move or
    /// its Undo, a scan, or a map opened from a file.
    private func releaseMap() {
        guard root != nil, !scanning, !trashing, marked.isEmpty, !canUndo, opened == nil, rootPath == mapsOnOpen else { return }
        let previous = RetiredValue((root, current, index, largeFiles))
        defer { previous.releaseLater() }
        ChartLayouts.removeAll()
        root = nil
        current = nil
        hovered = nil
        index = nil
        installLargeFiles([], spill: nil)
        selection = []
        revision += 1
    }

    /// How the disk the map was made of is used beyond the map, read off the
    /// main thread once a scan is in.
    private(set) var diskSpace: DiskSpace?
    @ObservationIgnored var readSpace: @Sendable (String) -> DiskSpace? = { DiskSpace.read(volumeOf: $0) }
    @ObservationIgnored private var pendingDiskRead: (path: String, run: Int)?
    @ObservationIgnored private var diskReadRunning = false
    private static let diskReads = DispatchQueue(label: "mymole.disk-space", qos: .utility)

    private func readDiskSpace(of path: String, run: Int) {
        pendingDiskRead = (path, run)
        startDiskRead()
    }

    private func startDiskRead() {
        guard !diskReadRunning, let request = pendingDiskRead else { return }
        pendingDiskRead = nil
        diskReadRunning = true
        let read = readSpace
        // DiskSpace may wait for tmutil. Keep that blocking wait outside
        // Swift's cooperative executor, with only the latest request pending.
        Self.diskReads.async { [weak self] in
            let space = read(request.path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                diskReadRunning = false
                if request.run == epoch { diskSpace = space }
                startDiskRead()
            }
        }
    }

    /// The saved scans of the folder, newest first, and by default the newest
    /// against the one before it.
    private func showHistory(_ found: [SnapshotRef]) {
        history = found
        compare(from: found.dropFirst().first, to: found.first)
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
            compareProblem = nil
            comparing = false
            return
        }
        // Always diff older → newer, whichever order they were picked in.
        let (a, b) = from.date <= to.date ? (from, to) : (to, from)
        comparing = true
        let threshold = Self.changeThreshold
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = StorageModel.comparison(SnapshotStore.load(a), SnapshotStore.load(b), threshold: threshold)
            await self?.applyComparison(result, run: run)
        }
    }

    struct Comparison: Equatable {
        var changes: [Change]
        var delta: Int64?
        var problem: String?
    }

    /// The changes from `old` to `new`. The total is only known when both
    /// scans were read and complete; the changes listed are only those an
    /// incomplete scan can't fake (see `Snapshot.changes`).
    /// The smallest change Changes lists, as chosen there.
    nonisolated static let thresholdKey = "diskMap.changeThreshold"
    nonisolated static let thresholds: [Int64] = [10 * 1_048_576, 50 * 1_048_576, 200 * 1_048_576]
    nonisolated static var changeThreshold: Int64 {
        let v = Int64(UserDefaults.standard.integer(forKey: thresholdKey))
        return thresholds.contains(v) ? v : 50 * 1_048_576
    }

    nonisolated static func comparison(_ old: Snapshot?, _ new: Snapshot?, threshold: Int64 = 50 * 1_048_576) -> Comparison {
        guard let old, let new else {
            return Comparison(changes: [], delta: nil, problem: String(localized: "One of these scans couldn't be read, so they can't be compared."))
        }
        let diff = old.changes(to: new, threshold: threshold)
        guard !old.incomplete && !new.incomplete else {
            let problem = old.incomplete && new.incomplete
                ? String(localized: "Part of both scans couldn't be read, so the overall change isn't known. Only changes the readable parts show are listed.")
                : old.incomplete
                    ? String(localized: "Part of the older scan couldn't be read, so the overall change isn't known. Only changes the readable parts show are listed.")
                    : String(localized: "Part of the newer scan couldn't be read, so the overall change isn't known. Only changes the readable parts show are listed.")
            return Comparison(changes: diff, delta: nil, problem: problem)
        }
        return Comparison(changes: diff, delta: new.totalSize - old.totalSize, problem: nil)
    }

    private var compareEpoch = 0

    private func applyComparison(_ result: Comparison, run: Int) {
        guard run == compareEpoch else { return }
        changes = result.changes
        overallDelta = result.delta
        compareProblem = result.problem
        comparing = false
    }

    nonisolated static func collectLargeFiles(_ root: Folder, limit: Int = StorageModel.standardLargeFiles, stop: () -> Bool = { false }) -> [LargeFile] {
        guard limit > 0, !stop() else { return [] }
        // Trimmed back to `limit` whenever twice as many are held; without a
        // limit nothing is trimmed and the list grows as needed.
        let batch = limit > Int.max / 2 ? Int.max : limit * 2
        var out: [LargeFile] = []
        out.reserveCapacity(min(batch, 16_384))
        var cutoff = Int64.min
        func largestFirst(_ a: LargeFile, _ b: LargeFile) -> Bool { a.size == b.size ? a.path < b.path : a.size > b.size }
        var stack = [root]
        while let f = stack.popLast() {
            if stop() { return [] }
            var path: String?
            for item in f.listedFiles where item.size >= cutoff {
                if stop() { return [] }
                if path == nil { path = f.path }
                let path = path!
                out.append(
                    LargeFile(
                        path: path + "/" + item.name, name: item.name, folder: path, size: item.size,
                        modified: item.modified, kind: item.kind, reclaim: item.shared > 0 ? item.reclaim : nil))
                if out.count >= batch {
                    out.sort(by: largestFirst)
                    out.removeLast(out.count - limit)
                    cutoff = out.last?.size ?? Int64.min
                }
            }
            stack.append(contentsOf: f.subfolders)
        }
        out.sort(by: largestFirst)
        return Array(out.prefix(limit))
    }

    /// While scanning, only top-level subtrees that have finished are shown;
    /// the rest are still being written by the scanner.
    var isReady: (Folder) -> Bool {
        let live = showingLive
        let done = completed
        let r = root
        return { f in
            guard !f.wasNotScanned else { return false }
            guard live else { return true }
            if f === r { return true }
            var top = f
            while let parent = top.parent {
                if parent === r { return done.contains(top.id) }
                top = parent
            }
            return false
        }
    }

    func isPending(_ f: Folder) -> Bool { !isReady(f) }

    /// A folder's size as far as it's known: its own total once finished,
    /// else the sum of the parts that are (the root, mid-scan).
    func chartedSize(_ f: Folder) -> Int64 {
        guard showingLive, f.parent == nil else { return f.size }
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
        // Asked for every segment on every frame a chart draws.
        if case .folder(let f) = s, !selection.isEmpty { return selection.contains(f.path) }
        return false
    }

    /// Opens the folder at `path` in Browse, selecting `select` inside it.
    func show(folder path: String, select: String? = nil) {
        guard let f = accessibleFolder(path) else { return }
        open(f)
        if let select { selection = [select] }
        tab = .browse
    }

    func back() {
        guard let p = current?.parent else { return }
        open(p)
    }

    var lineage: [Folder] { current?.lineage ?? [] }

    private func accessibleFolder(_ path: String) -> Folder? {
        guard let root else { return nil }
        if showingLive, path != root.path {
            let base = root.path == "/" ? "/" : root.path + "/"
            guard path.hasPrefix(base), let first = path.dropFirst(base.count).split(separator: "/").first,
                  let top = root.subfolders.first(where: { $0.name == first }), completed.contains(top.id) else { return nil }
        }
        return root.find(path: path)
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    // MARK: Marking

    func isMarked(_ path: String) -> Bool { marked[path] != nil }

    func toggle(_ m: Marked) {
        guard opened == nil, !trashing else { return }
        if marked[m.path] != nil { marked[m.path] = nil }
        else { mark([m]) }
    }

    func mark(_ items: [Marked]) {
        guard opened == nil, !trashing else { return }
        var chosen = marked
        for m in items { chosen[m.path] = m }
        let outer = Set(Trasher.outermost(chosen.keys))
        marked = chosen.filter { outer.contains($0.key) }
    }

    func unmark(_ paths: some Sequence<String>) {
        guard !trashing else { return }
        let paths = Set(paths)
        marked = marked.filter { !paths.contains($0.key) }
    }

    /// Clearing a listed folder clears separate choices inside it, while
    /// preserving choices elsewhere and any containing folder outside the list.
    func setListedMarks(_ items: [Marked], checked: Bool) {
        guard opened == nil, !trashing else { return }
        if checked { mark(items); return }
        let paths = Set(items.map(\.path))
        let clear = marked.keys.filter { paths.contains($0) || Marked.parent(of: $0, in: paths) != nil }
        unmark(clear)
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
        guard opened == nil, !trashing else { return }
        mark((current?.subfolders ?? []).filter { $0.rebuildable != nil && isReady($0) }
            .map { Marked(path: $0.path, name: $0.name, size: $0.size, isFolder: true) })
    }

    private(set) var choosingContents = false
    @ObservationIgnored private var contentsChoice: UUID?
    @ObservationIgnored private var allContentsChoice: (folder: String, paths: Set<String>)?

    func chooseAllContents() async {
        guard let current, opened == nil, !trashing, !choosingContents else { return }
        let run = epoch
        let path = current.path
        let id = UUID()
        contentsChoice = id
        choosingContents = true
        defer {
            if contentsChoice == id { choosingContents = false; contentsChoice = nil }
        }
        let base = path == "/" ? "" : path
        let knownFiles = Set(current.listedFiles.map { base + "/" + $0.name })
        let sizes = Dictionary(current.subfolders.filter { !isPending($0) }.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        let progress = ScanProgress()
        let listed = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { FolderContents.read(path, progress: progress, limit: .max) }.value
        } onCancel: { progress.cancel() }
        guard !Task.isCancelled, run == epoch, self.current === current, opened == nil, !trashing else { return }
        guard let listed else {
            showNotice(Notice(text: String(localized: "The complete folder contents couldn't be selected. Nothing was added. Check access or choose smaller groups."), canUndo: false))
            return
        }
        mark(listed.map { item in
            Marked(path: item.path, name: (item.path as NSString).lastPathComponent,
                   size: item.isFolder ? (sizes[item.path] ?? 0) : item.bytes, isFolder: item.isFolder,
                   needsRefresh: !item.isFolder && !knownFiles.contains(item.path), proof: item)
        })
        allContentsChoice = (path, Set(listed.map(\.path)))
    }

    // MARK: Trash

    func beginTrashReview() {
        guard opened == nil, !trashing, !marked.isEmpty else { return }
        reviewScan = epoch
        showReview = true
        confirmationStarted = .now
    }

    @ObservationIgnored private var confirmationStarted: ContinuousClock.Instant?
    func confirmationPresented() {
        if let started = confirmationStarted { Timings.record(.confirmation, since: started) }
        confirmationStarted = nil
    }

    func scannedRisk(for item: Marked) -> PathRisk? {
        if let risk = PathRisk.of(item.path) { return risk }
        guard item.isFolder else { return nil }
        guard let folder = accessibleFolder(item.path), !isPending(folder), !(showingLive && folder === root) else { return .incomplete }
        return folder.scannedRisk ?? (folder.riskComplete ? nil : .incomplete)
    }

    /// Confirmation never waits for a directory reader.
    var canTrash: Bool { !trashing && !marked.isEmpty && opened == nil }
    private(set) var trashing = false
    enum RemovalPhase { case preparing, stoppingScan, waiting, moving, restoring }
    private(set) var removalPhase: RemovalPhase?
    private(set) var trashJob: Task<Void, Never>?
    @ObservationIgnored private var activeRemoval: TrashJob?
    private(set) var removalStopping = false
    var canStopRemoval: Bool { trashing && activeRemoval != nil && !removalStopping && removalPhase != .restoring }

    func stopRemoval() {
        guard canStopRemoval else { return }
        removalStopping = true
        activeRemoval?.stop()
        cancelScan()
    }
    /// Where moved items go; tests use a folder of their own.
    var trashBackend: TrashBackend = .live
    /// Where its moves and Undos wait their turn among every pane's.
    var jobs: TrashJobs = .shared
    /// What the user keeps in other panes: Deep Clean's keep list and the
    /// paths kept in Projects. Tests use lists of their own.
    var protections: UserProtections = .live { didSet { invalidateRemovalHints() } }
    /// Where its moves and Undos are written to the history.
    var logURL: URL = CleanupLog.defaultURL

    /// The checks a move from the disk map passes: each item is still the
    /// kind of item that was marked, and nothing the user keeps in another
    /// pane is it, is inside it or holds it. The lists are read again as the
    /// move runs; one that can't be read stops it.
    nonisolated static func gate(folders: Set<String>, protections: UserProtections, proofs: [String: FolderContents.Item] = [:], requireProof: Bool = false) -> TrashGate {
        TrashGate(
            still: { p in
                guard !requireProof || proofs[p] != nil else { return false }
                guard proofs[p]?.isCurrent != false else { return false }
                var st = stat()
                guard lstat(p, &st) == 0 else { return false }
                return (st.st_mode & S_IFMT == S_IFDIR) == folders.contains(p)
            },
            protections: { try protections.read() })
    }

    /// Moves the marked items to the Trash off the main thread, then prunes
    /// the tree here.
    func trashMarked() {
        // A scan opened from a file names paths it gives no right to.
        guard canTrash, opened == nil else { return }
        trashing = true
        removalPhase = .preparing
        let selected = marked
        let known = knownReclaims(Array(selected.values))
        let wasScanning = scanning
        cancelScan()
        let stoppedAt = ContinuousClock.now
        let scanner = readerToJoinBeforePruning()
        let run = epoch
        let backend = trashBackend
        let protections = protections
        let job = jobs.prepare(.moveToTrash)
        activeRemoval = job
        trashJob = Task {
            defer {
                jobs.end(job)
                if activeRemoval === job { activeRemoval = nil }
                removalStopping = false
                trashing = false
                removalPhase = nil
                startScanAfterTrash()
            }
            let preparing = Task.detached(priority: .userInitiated) {
                let top = Set(Trasher.outermost(selected.keys))
                let items = selected.values.filter { top.contains($0.path) }
                let proofs = Dictionary(items.compactMap { item -> (String, FolderContents.Item)? in
                    guard !job.isStopped, item.proof?.isCurrent != false, let fresh = FolderContents.capture(item.path) else { return nil }
                    return (item.path, fresh)
                }, uniquingKeysWith: { a, _ in a })
                // Read before the move, while the files are where they were chosen.
                return (items, proofs, Self.reclaims(of: items, known: known, stop: { job.isStopped }))
            }
            if wasScanning { removalPhase = .stoppingScan }
            await scanner?.value
            Timings.record(.removalScanWait, since: stoppedAt)
            removalPhase = .preparing
            let prepared = await preparing.value
            guard !Task.isCancelled, !job.isStopped, run == epoch, opened == nil else { return }
            removalPhase = .waiting
            let queuedAt = ContinuousClock.now
            _ = await jobs.begin(job)
            Timings.record(.removalQueue, since: queuedAt)
            guard !Task.isCancelled, !job.isStopped, run == epoch, opened == nil else { return }
            let items = prepared.0
            let gate = Self.gate(folders: Set(items.filter(\.isFolder).map(\.path)), protections: protections, proofs: prepared.1, requireProof: true)
            removalPhase = .moving
            let movedAt = ContinuousClock.now
            let outcome = await Task.detached(priority: .userInitiated) {
                job.moveToTrash(items.map(\.path), through: gate, backend: backend)
            }.value
            Timings.record(.removalMove, since: movedAt)
            trashing = false
            removalPhase = nil
            let reclaims = prepared.2
            Timings.measure(.removalApply, rows: items.count) { applyTrash(outcome, items: items, reclaims: reclaims) }
        }
    }

    /// A blocked directory read writes only unpublished branches. Retire its
    /// epoch and transfer the published ones instead of waiting for kernel I/O.
    /// Finalization readers of the visible tree are cooperative and must join.
    private func readerToJoinBeforePruning() -> Task<Void, Never>? {
        let shared = mapReader?.job
        let active = retireReaderBeforePruning()
        guard let shared else { return active }
        return Task { await shared.value; await active?.value }
    }

    private func retireReaderBeforePruning() -> Task<Void, Never>? {
        guard scanning, let session = scanSession else { return nil }
        let finalizing = session.retire()
        if !refreshing && finalizing { return scanJob }
        let previous = RetiredValue((root, current, index))
        if !refreshing, let old = root {
            let currentPath = current?.path
            let copy = old.partialPresentation(published: completed)
            root = copy
            current = currentPath.flatMap { copy.find(path: $0) } ?? copy
            index = nil
            incomplete = true
        }
        epoch += 1
        poller?.cancel()
        poller = nil
        scanJob = nil
        scanSession = nil
        progress = nil
        refreshing = false
        scanning = false
        liveFiles = root?.fileCount ?? 0
        liveBytes = root?.size ?? 0
        completed = []
        revision += 1
        previous.releaseLater()
        return nil
    }

    /// A scan asked for while a move or Undo ran.
    private var scanAfterTrash: (path: String, background: Bool)?

    private func startScanAfterTrash() {
        guard let next = scanAfterTrash else { return }
        scanAfterTrash = nil
        scan(path: next.path, background: next.background)
    }

    private func applyTrash(_ outcome: TrashOutcome, items: [Marked], reclaims: [String: Reclaim]) {
        let oldLineage = current?.lineage ?? []
        var pruned: [Pruned] = []
        var movedBytes: Int64 = 0
        let movedPaths = Set(outcome.moved.map(\.original.path))
        let movedReclaims = reclaims.filter { movedPaths.contains($0.key) }
        let freed = min(items.filter { movedPaths.contains($0.path) }.reduce(0) { $0 + $1.size },
                        movedReclaims.values.reduce(Reclaim(), +).bytes)
        for item in items where movedPaths.contains(item.path) {
            movedBytes += item.size
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
        if let choice = allContentsChoice, !choice.paths.isEmpty, choice.paths.isSubset(of: movedPaths),
           let folder = root?.find(path: choice.folder), folder.smallFileCount > 0 {
            pruned.append(.smallFiles(parent: folder, folder.removeSmallFiles()))
        }
        allContentsChoice = nil
        // Inner marks went along with their folder.
        let removed = { (path: String) in movedPaths.contains(path) || Marked.parent(of: path, in: movedPaths) != nil }
        marked = marked.filter { !removed($0.key) }
        selection = selection.filter { !removed($0) }
        hovered = nil
        treeExpanded = treeExpanded.filter { !removed($0) }
        let previousFiles = RetiredValue(largeFiles)
        largeFiles = largeFiles.filter { !removed($0.path) }
        previousFiles.releaseLater()
        if largeFilesSpill != nil { spillRemoved += Trasher.outermost(movedPaths) }
        let record = CleanupRecord(source: "Disk Map", items: outcome.moved.count, bytes: freed, failed: outcome.failed.count)
        let needsRefresh = items.contains { $0.needsRefresh && movedPaths.contains($0.path) }
        if !outcome.moved.isEmpty {
            shelf.add(Run(id: record.id, records: outcome.moved, pruned: pruned, refreshAfterUndo: needsRefresh, reclaims: movedReclaims))
        }
        if needsRefresh, scanAfterTrash == nil { scanAfterTrash = (rootPath, false) }
        CleanupLog.submit(record, to: logURL)
        // If the open folder went to the Trash, step out to its parent.
        if let c = current, removed(c.path) {
            current = oldLineage.reversed().first { !removed($0.path) && root?.find(path: $0.path) === $0 } ?? root
        }
        revision += 1
        var text = outcome.moved.isEmpty && !outcome.failed.isEmpty
            ? nothingMoved(outcome.failed)
            : String(localized: "Moved \(outcome.moved.count) item\(outcome.moved.count == 1 ? "" : "s") (\(Freeing.phrase(movedBytes, frees: freed))) to the Trash")
        if !outcome.moved.isEmpty && !outcome.failed.isEmpty { text += String(localized: " · \(outcome.failed.count) skipped") }
        showNotice(Notice(text: text, canUndo: !outcome.moved.isEmpty))
    }

    /// Puts a move back, off the main thread: the one of history record
    /// `id`, or the latest.
    func undoTrash(run id: UUID? = nil) {
        guard !trashing else { return }
        target = id ?? shelf.latest?.id
        guard target.flatMap(shelf.run) != nil, !undoRecords.isEmpty else {
            target = nil
            return
        }
        let records = undoRecords
        let refresh = undone?.refreshAfterUndo == true
        trashing = true
        removalPhase = .restoring
        cancelScan()
        let scanningJob = scanJob
        let sharedReader = mapReader?.job
        Task {
            await sharedReader?.value
            await scanningJob?.value
            let failedRecords = await jobs.perform(.putBack) { $0.putBack(records) }
            trashing = false
            removalPhase = nil
            applyUndo(failedRecords)
            target = nil
            if refresh, scanAfterTrash == nil { scanAfterTrash = (rootPath, false) }
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
            case .smallFiles(let parent, let small) where failed.isEmpty:
                parent.restoreSmallFiles(small)
                bytes += small.bytes.total
            default:
                stillOut.append(p)
            }
        }
        let restored = undoRecords.count - failed.count
        // Counted as the move was: what those items freed.
        let reclaims = undone?.reclaims ?? [:]
        let back = undoRecords.map(\.original.path).filter { !failed.contains($0) }
        if !reclaims.isEmpty { bytes = back.compactMap { reclaims[$0] }.reduce(Reclaim(), +).bytes }
        if let id = undoLogID { CleanupLog.submitRestore(id, restored: restored, bytes: bytes, failed: failed.count, in: logURL) }
        // What couldn't come back stays ready for another try.
        undoRecords = failedRecords
        undoPruned = stillOut
        if failed.isEmpty, let id = undone?.id { shelf.remove(id) }
        revision += 1
        showNotice(Notice(
            text: failed.isEmpty ? String(localized: "Restored \(restored) item\(restored == 1 ? "" : "s")") : String(localized: "Restored \(restored); \(failed.count) couldn't be put back. Undo tries those again."),
            canUndo: !failed.isEmpty))
    }

    /// The last move's notice with its Undo, shown again after a passing
    /// notice while there's still something to put back.
    private var undoNotice: Notice?

    /// A notice with Undo stays until it's used, closed or replaced; any
    /// other passes after a few seconds.
    private func showNotice(_ n: Notice) {
        withAnimation(Motion.snappy) { notice = n }
        if n.canUndo {
            undoNotice = n
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard notice == n else { return }
            withAnimation(Motion.snappy) { notice = undoRecords.isEmpty ? nil : undoNotice }
        }
    }

    func dismissNotice() { withAnimation(Motion.snappy) { notice = nil } }
}
