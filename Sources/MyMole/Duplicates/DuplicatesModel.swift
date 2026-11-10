import Foundation
import StorageKit
import SwiftUI
import Synchronization

/// State of the Duplicates pane: the groups of identical files found, which
/// copies are chosen for the Trash, and what the last move can undo. One
/// copy of every group always stays.
@MainActor
@Observable
final class DuplicatesModel {
    static let source = "Duplicates"

    struct Notice: Equatable {
        let text: String
        let canUndo: Bool
    }

    enum Keep: Equatable {
        case newest, oldest
        /// The copy in this folder stays; a group with none there is left as it is.
        case inFolder(String)
    }

    private(set) var groups: [DuplicateGroup] = []
    private(set) var unreadable: [String] = []
    /// Files the last search couldn't read through.
    private(set) var uncompared = 0
    private(set) var excludedRoots: [String] = []
    private(set) var scanning = false
    private(set) var startedAt: Date?
    /// When the shown result was complete; nil before the first full search.
    private(set) var scannedAt: Date?
    private(set) var step: DuplicateStep?
    private(set) var attempted = false
    /// Verified groups arriving during the first search, for read-only preview.
    private(set) var preview: [DuplicateGroup] = []
    var displayGroups: [DuplicateGroup] { groups.isEmpty && scanning ? preview : groups }
    private(set) var notice: Notice?
    /// Paths of the copies chosen for the Trash.
    var chosen = Set<String>()
    /// The groups selected in the list, whose copies show beside it.
    var selection = Set<String>()
    var fileSelection = Set<String>()
    /// What the user keeps elsewhere: Deep Clean's keep list and the paths
    /// kept in Projects. A kept copy is never chosen. Tests use lists of their own.
    var protections: UserProtections = .live { didSet { keep = SharedKeep(protections: protections) } }
    private(set) var keep = SharedKeep(protections: .live)

    private struct Run: UndoableRun {
        let id: UUID
        var records: [TrashRecord]
        var bytes: [String: Int64]
    }

    private var shelf = UndoShelf<Run>()
    private(set) var trashing = false
    private(set) var scanJob: Task<Void, Never>?
    private(set) var trashJob: Task<Void, Never>?
    private var progress: ScanProgress?
    private var scanAfterTrash = false
    private var searchClock: ContinuousClock.Instant?
    private var firstResultClock: ContinuousClock.Instant?

    private(set) var roots: [String]
    private let home: String
    private(set) var minimum: Int64

    /// Folders the user added, and the smallest file they search for; kept
    /// between launches. The model's own roots and minimum come first.
    static let extraRootsKey = "duplicates.extraRoots"
    static let minimumKey = "duplicates.minimum"
    static let minimums: [Int64] = [100_000, DuplicateFinder.standardMinimum, 10 * 1_048_576, 100 * 1_048_576]
    var addedRoots: [String] { (UserDefaults.standard.stringArray(forKey: Self.extraRootsKey) ?? []).filter { $0.hasPrefix("/") } }

    /// Searches one more folder of the user's choice. In the App Sandbox
    /// only folders in the home folder can be read; a library (Photos, Music)
    /// is passed over by the search however it's reached.
    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose a folder to search for duplicates in")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        // Outside the home folder the sandbox needs the folder kept open.
        if !path.hasPrefix(home + "/"), !ChosenFolders.shared.keep(url) {
            show(Notice(text: String(localized: "MyMole couldn't keep access to that folder."), canUndo: false))
            return
        }
        guard !roots.contains(path) else { return }
        UserDefaults.standard.set(Array(Set(addedRoots + [path])).sorted(), forKey: Self.extraRootsKey)
        roots.append(path)
        scan()
    }

    func removeRoot(_ path: String) {
        ChosenFolders.shared.release(path)
        UserDefaults.standard.set(addedRoots.filter { $0 != path }, forKey: Self.extraRootsKey)
        roots.removeAll { $0 == path }
        scan()
    }

    func setMinimum(_ bytes: Int64) {
        guard bytes != minimum else { return }
        UserDefaults.standard.set(Int(bytes), forKey: Self.minimumKey)
        minimum = bytes
        scan()
    }

    /// Chooses every copy outside a folder of the user's choice, so the copy there stays.
    func chooseKeepingCopiesIn() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose the folder whose copies stay")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chooseAll(keeping: .inFolder(url.standardizedFileURL.path))
    }
    private let logURL: URL
    private let trash: TrashBackend
    private let scanBudget: ScanBudget
    typealias Search = @Sendable ([String], Int64, ScanProgress, Int, @escaping @Sendable (DuplicateStep) -> Void, @escaping @Sendable (DuplicateGroup) -> Void) -> DuplicateListing
    private let search: Search
    nonisolated static let liveSearch: Search = { roots, minimum, progress, workers, step, group in
        DuplicateFinder.find(in: roots, minimum: minimum, progress: progress, workers: workers, onGroup: group, onStep: step)
    }
    /// Hears when a keep list is saved anywhere, to mark what's kept at once.
    @ObservationIgnored private var keepWatch: NSObjectProtocol?
    var jobs: TrashJobs = .shared

    init(
        home: String = Home.path, roots: [String]? = nil, minimum: Int64 = DuplicateFinder.standardMinimum,
        logURL: URL = CleanupLog.defaultURL, trash: TrashBackend = .live,
        scanBudget: ScanBudget = .shared, search: @escaping Search = DuplicatesModel.liveSearch
    ) {
        self.home = home
        // The user's own folders and minimum, unless a caller gave its own.
        let stored = Int64(UserDefaults.standard.integer(forKey: Self.minimumKey))
        self.roots = roots ?? (DuplicateFinder.standardRoots(home: home)
            + (UserDefaults.standard.stringArray(forKey: Self.extraRootsKey) ?? []).filter { $0.hasPrefix("/") })
        self.minimum = roots == nil && Self.minimums.contains(stored) ? stored : minimum
        self.logURL = logURL
        self.trash = trash
        self.scanBudget = scanBudget
        self.search = search
        keepWatch = NotificationCenter.default.addObserver(forName: KeepChanges.name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reloadKept() }
        }
    }

    // MARK: Searching

    /// How often a running search's progress reaches the views.
    static let publishEvery: Duration = .milliseconds(200)

    /// First opening joins a search already requested by Smart Scan. A Stop
    /// is remembered; merely opening the pane again mustn't restart it.
    func scanIfNeeded() {
        guard !attempted, !scanning, !trashing else { return }
        scan()
    }

    func scan(background: Bool = false) {
        // The list mustn't change under a move or Undo; it's searched after.
        guard !trashing else {
            scanAfterTrash = true
            return
        }
        progress?.cancel()
        let p = ScanProgress()
        progress = p
        scanning = true
        attempted = true
        startedAt = .now
        step = DuplicateStep(phase: .waiting, done: 0, total: 0)
        preview = []
        let requestedAt = ContinuousClock.now
        searchClock = requestedAt
        firstResultClock = groups.isEmpty ? requestedAt : nil
        let (roots, minimum) = (roots, minimum)
        let level = PerformanceLevel.current()
        let latest = Mutex<DuplicateStep?>(nil)
        let incoming = Mutex<[DuplicateGroup]>([])
        let (budget, search) = (scanBudget, search)
        scanJob = Task { [self] in
            // Progress arrives from the search's threads; the views get the
            // newest a few times a second. Cancelled once the search ends.
            let publisher = Task { [self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.publishEvery)
                    guard progress === p, !Task.isCancelled, !p.isCancelled else { return }
                    if let value = latest.withLock({ $0 }) { step = value }
                    let added = incoming.withLock { value in let added = value; value = []; return added }
                    if !added.isEmpty, groups.isEmpty {
                        preview.append(contentsOf: added)
                        if let clock = firstResultClock { Timings.record(.firstDuplicates, since: clock); firstResultClock = nil }
                        if selection.isEmpty, let first = preview.first { selection = [first.id] }
                    }
                }
            }
            let found = await Task.detached(priority: level.priority(background: background)) {
                await budget.run(background: background, progress: p) {
                    Timings.record(.duplicateQueue, since: requestedAt)
                    let listedAt = ContinuousClock.now
                    let listingDone = Mutex(false)
                    return search(roots, minimum, p, level.workers(background: background), { s in
                        if s.phase == .comparing, listingDone.withLock({ done in
                            guard !done else { return false }; done = true; return true
                        }) { Timings.record(.duplicateListing, since: listedAt) }
                        latest.withLock { $0 = s }
                    }, { g in incoming.withLock { $0.append(g) } })
                }
            }.value
            publisher.cancel()
            await finished(found, run: p)
        }
    }

    func stop() { progress?.cancel() }

    /// Only a complete search replaces the list.
    private func finished(_ found: DuplicateListing?, run: ScanProgress) async {
        guard run === progress else { return }
        let completedClock = searchClock
        searchClock = nil
        scanning = false
        progress = nil
        step = nil
        preview = []
        guard !run.isCancelled, let found else {
            firstResultClock = nil
            selection.formIntersection(Set(groups.map(\.id)))
            fileSelection.formIntersection(Set(groups.flatMap { $0.files.map(\.path) }))
            return
        }
        if let clock = completedClock { Timings.record(.duplicateSearch, since: clock) }
        groups = found.groups
        if !groups.isEmpty, let clock = firstResultClock { Timings.record(.firstDuplicates, since: clock) }
        firstResultClock = nil
        unreadable = found.unreadable
        uncompared = found.uncompared
        excludedRoots = found.excluded
        scannedAt = .now
        let paths = Set(found.groups.flatMap { $0.files.map(\.path) })
        chosen.formIntersection(paths)
        for group in groups where group.files.allSatisfy({ chosen.contains($0.path) }) {
            if let stays = group.files.first { chosen.remove(stays.path) }
        }
        fileSelection.formIntersection(paths)
        selection.formIntersection(Set(found.groups.map(\.id)))
        if selection.isEmpty, let first = found.groups.first { selection = [first.id] }
        await reloadKept()
    }

    /// `refreshKept`, with the lists read off the main thread.
    func reloadKept() async {
        keep = await keep.reloaded()
        chosen = chosen.filter { !keep.protects($0) }
    }

    // MARK: Reading

    /// What goes when every group keeps one copy.
    var spareBytes: Int64 { displayGroups.reduce(0) { $0 + $1.spare } }
    /// What moving the chosen copies frees: clones count once all of their family goes.
    var chosenBytes: Int64 { groups.reduce(0) { $0 + $1.freed(going: chosen).values.reduce(0, +) } }
    /// The groups whose copies show: the selected ones, in the list's order.
    var shownGroups: [DuplicateGroup] { displayGroups.filter { selection.contains($0.id) } }

    private func group(of path: String) -> DuplicateGroup? { groups.first { $0.files.contains { $0.path == path } } }

    // MARK: Choosing

    /// Chooses or unchooses a copy. The last copy of a group that isn't
    /// chosen can't be: one always stays.
    func toggle(_ path: String) {
        guard !scanning else { return }
        if chosen.contains(path) {
            chosen.remove(path)
            return
        }
        guard !keep.protects(path) else {
            show(Notice(text: String(localized: "This copy is kept, so it stays."), canUndo: false))
            return
        }
        guard let g = group(of: path) else { return }
        guard g.files.contains(where: { $0.path != path && !chosen.contains($0.path) }) else {
            show(Notice(text: String(localized: "One copy always stays. Unchoose another copy first."), canUndo: false))
            return
        }
        chosen.insert(path)
    }

    func choose(_ paths: some Sequence<String>) { for p in paths where !chosen.contains(p) { toggle(p) } }

    func setListedCopies(_ paths: [String], checked: Bool) {
        guard !scanning, !trashing else { return }
        let listed = Set(paths)
        if !checked { chosen.subtract(listed); return }
        var next = chosen
        for group in groups where group.files.contains(where: { listed.contains($0.path) }) {
            guard let retained = group.files.last else { continue }
            next.remove(retained.path)
            next.formUnion(group.files.filter { listed.contains($0.path) && $0.path != retained.path && !keep.protects($0.path) }.map(\.path))
        }
        chosen = next
    }

    /// In the selected groups, or in all when none is selected: every copy but the newest or the oldest.
    func chooseAll(keeping keep: Keep) {
        guard !scanning else { return }
        var without = 0
        for g in selection.isEmpty ? groups : shownGroups {
            // Files are oldest first.
            let stays: DuplicateFile?
            switch keep {
            case .oldest: stays = g.files.first
            case .newest: stays = g.files.last
            case .inFolder(let folder):
                stays = g.files.first { $0.path.hasPrefix(folder + "/") }
                if stays == nil { without += 1 }
            }
            guard let kept = stays else { continue }
            chosen.subtract(g.files.map(\.path))
            chosen.formUnion(g.files.filter { $0.path != kept.path && !self.keep.protects($0.path) }.map(\.path))
        }
        if without > 0 {
            show(Notice(text: String(localized: "\(without) file\(without == 1 ? " has" : "s have") no copy in that folder, so nothing of \(without == 1 ? "it" : "them") is chosen."), canUndo: false))
        }
    }

    // MARK: Keep

    /// Reads the keep lists again and lets go of what they now keep.
    func refreshKept() {
        keep.reload()
        chosen = chosen.filter { !keep.protects($0) }
    }

    func keepAlways(_ paths: [String]) { changeKeep(keep: paths, stop: []) }
    func stopKeeping(_ paths: [String]) { changeKeep(keep: [], stop: paths) }

    private func changeKeep(keep add: [String], stop remove: [String]) {
        guard !trashing else {
            show(Notice(text: String(localized: "Wait for the move to finish before changing the keep list."), canUndo: false))
            return
        }
        if let why = keep.change(keep: add, stop: remove) { show(Notice(text: why, canUndo: false)) }
        chosen = chosen.filter { !keep.protects($0) }
    }

    // MARK: Trash

    var trashBlocker: String? {
        if chosen.isEmpty { return String(localized: "Choose at least one copy.") }
        if let why = keep.blocker { return why }
        if scanning { return String(localized: "Wait for the search to finish.") }
        if trashing { return String(localized: "Moving to the Trash…") }
        return nil
    }

    var canUndo: Bool { !(shelf.latest?.records.isEmpty ?? true) && !trashing }
    func canUndo(run id: UUID) -> Bool { !(shelf.run(id)?.records.isEmpty ?? true) && !trashing }

    /// Moves the chosen copies to the Trash. Each is checked again right
    /// before it moves: unchanged since it was compared, and with a copy
    /// that isn't going still in place.
    func trashChosen() {
        // The keep lists as they are now: what they keep stays, and a list
        // that can't be read stops the move.
        refreshKept()
        if let why = keep.blocker { show(Notice(text: why, canUndo: false)) }
        guard trashBlocker == nil else { return }
        let going = chosen
        let kept = keep.gate
        let byPath = Dictionary(groups.flatMap { g in g.files.map { ($0.path, g) } }, uniquingKeysWith: { a, _ in a })
        let picked = going.filter { byPath[$0] != nil }.sorted()
        let (home, backend) = (home, trash)
        trashing = true
        trashJob = Task {
            let outcome = await jobs.perform(.moveToTrash) { job in
                job.moveToTrash(picked, through: TrashGate(still: { p in
                    byPath[p].map { DuplicateFinder.mayGo(p, of: $0, going: going, home: home) } ?? false
                }, protections: kept), backend: backend)
            }
            trashing = false
            let moved = Set(outcome.moved.map(\.original.path))
            // What really went: clones whose family partly stays freed nothing.
            var bytes: [String: Int64] = [:]
            for g in Set(moved.compactMap { byPath[$0] }) { bytes.merge(g.freed(going: moved)) { a, _ in a } }
            // A group left with one copy isn't one any more.
            groups = groups.compactMap { g in
                var g = g
                g.files.removeAll { moved.contains($0.path) }
                return g.files.count > 1 ? g : nil
            }
            chosen.subtract(picked)
            selection.formIntersection(Set(groups.map(\.id)))
            let total = bytes.values.reduce(0, +)
            let record = CleanupRecord(source: Self.source, items: moved.count, bytes: total, failed: outcome.failed.count)
            if !outcome.moved.isEmpty { shelf.add(Run(id: record.id, records: outcome.moved, bytes: bytes)) }
            CleanupLog.submit(record, to: logURL)
            var text = moved.isEmpty
                ? String(localized: "Nothing was moved")
                : String(localized: "Moved \(moved.count) cop\(moved.count == 1 ? "y" : "ies") (\(ByteSize.format(total))) to the Trash")
            if picked.count > moved.count { text += String(localized: " · \(picked.count - moved.count) left alone") }
            show(Notice(text: text, canUndo: !moved.isEmpty))
            startScanAfterTrash()
        }
    }

    private func startScanAfterTrash() {
        guard scanAfterTrash else { return }
        scanAfterTrash = false
        scan()
    }

    /// Puts a move back: the one of history record `id`, or the latest.
    /// The folders are searched again after, so the groups are as on disk.
    func undoTrash(run id: UUID? = nil) {
        guard !trashing, let run = id.flatMap(shelf.run) ?? shelf.latest, !run.records.isEmpty else { return }
        trashing = true
        trashJob = Task {
            let failedRecords = await jobs.perform(.putBack) { $0.putBack(run.records) }
            trashing = false
            let failed = Set(failedRecords.map(\.original.path))
            let back = run.records.map(\.original.path).filter { !failed.contains($0) }
            CleanupLog.submitRestore(run.id, restored: back.count, bytes: back.reduce(0) { $0 + (run.bytes[$1] ?? 0) }, failed: failed.count, in: logURL)
            if failed.isEmpty {
                shelf.remove(run.id)
            } else {
                shelf.update(run.id) { $0.records = failedRecords }
            }
            show(Notice(
                text: failed.isEmpty
                    ? String(localized: "Restored \(back.count) cop\(back.count == 1 ? "y" : "ies")")
                    : String(localized: "Restored \(back.count); \(failed.count) couldn't be put back. Undo tries those again."),
                canUndo: !failed.isEmpty))
            scanAfterTrash = false
            scan()
        }
    }

    private func show(_ n: Notice) {
        withAnimation(Motion.snappy) { notice = n }
        guard !n.canUndo else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard notice == n else { return }
            withAnimation(Motion.snappy) { notice = nil }
        }
    }

    func dismissNotice() { withAnimation(Motion.snappy) { notice = nil } }
}
