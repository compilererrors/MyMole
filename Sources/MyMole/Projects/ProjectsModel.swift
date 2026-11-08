import AppKit
import StorageKit
import SwiftUI

/// State of the Projects pane: every project's footprint, what grew since
/// the last scan, what's chosen for the Trash, and what the last move can
/// undo. Lives on `AppModel`, so leaving the pane mid-scan keeps the scan.
@MainActor
@Observable
final class ProjectsModel {
    /// Only data last changed before this is chosen.
    enum Age: Int, CaseIterable, Identifiable {
        case any = 0, week = 7, month = 30, quarter = 90, year = 365
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .any: String(localized: "Any Age")
            case .week: String(localized: "Older than 1 Week")
            case .month: String(localized: "Older than 1 Month")
            case .quarter: String(localized: "Older than 3 Months")
            case .year: String(localized: "Older than 1 Year")
            }
        }

        var cutoff: Date? { self == .any ? nil : Date().addingTimeInterval(-Double(rawValue) * 86_400) }
    }

    struct Notice: Equatable {
        let text: String
        let canUndo: Bool
    }

    /// An entry with what it belongs to, for totals and undo. A part is a
    /// folder or file inside an entry, chosen on its own.
    struct Chosen {
        let project: String
        let item: FootprintItem
        let entry: FootprintEntry
        var part = false
    }

    private(set) var footprints: [ProjectFootprint] = [] {
        didSet { choiceIndex = nil }
    }
    private(set) var scanning = false
    private(set) var measuredCount = 0
    /// When the shown result was complete; nil before the first full scan.
    private(set) var scannedAt: Date?
    private(set) var history: [String: [ProjectStore.Sample]] = [:]
    private(set) var notice: Notice?
    /// The user's corrections: folders to clean that MyMole missed, and
    /// things it offers that must never be cleaned.
    private(set) var rules = ProjectRules()
    /// Set when the saved rules couldn't be read: nothing is moved, and the
    /// file isn't saved over, until they can be.
    private(set) var rulesError: Problem?
    private(set) var trashing = false
    /// Projects being measured again after their rules changed.
    private(set) var rescanning = Set<String>()

    var roots: [String] {
        didSet { defaults.set(roots, forKey: "projects.roots") }
    }
    /// Projects selected in the list.
    var selection = Set<String>()
    var age: Age = .any {
        didSet { if age != oldValue { chosen = [] } }
    }
    /// Paths chosen for the Trash: entries, or folders and files inside them.
    var chosen = Set<String>() {
        didSet {
            choiceIndex = nil
            // Nothing chosen: nothing is left out of anything either.
            if chosen.isEmpty && !excluded.isEmpty { excluded = [] }
        }
    }
    // The choice state below is changed only by ProjectsModel+Choices.swift,
    // which is why it isn't private.

    /// Paths left out of a chosen folder: the folder goes, these stay. One
    /// path stands for everything inside it, however many entries surround
    /// it, and something inside it can be chosen again.
    var excluded = Set<String>() {
        didSet { choiceIndex = nil }
    }
    /// Sizes of chosen parts, noted when they were chosen.
    @ObservationIgnored var partInfo: [String: FootprintEntry] = [:]
    /// Counts part sizes measured after they were chosen, so totals redraw.
    var partSizes = 0
    @ObservationIgnored var choiceIndex: ChoiceIndex?
    /// What's inside entries the user opened, measured on demand; the most
    /// recent few are kept.
    var contents: [String: Folder] = [:]
    /// Entries being measured. Not observed: the outline asks for contents
    /// from its data source while SwiftUI updates it, and nothing draws this.
    @ObservationIgnored var loadingContents = Set<String>()
    @ObservationIgnored var contentsOrder: [String] = []

    private var progress: ScanProgress?
    /// A move that can still be put back, the entries it took, and whether
    /// putting it back needs a scan (items kept in part were around it).
    private struct Run: UndoableRun {
        let id: UUID
        var records: [TrashRecord]
        var entries: [Chosen]
        var needsScan: Bool
    }

    private var shelf = UndoShelf<Run>()
    /// The move an Undo works on: one History asked for, or else the latest.
    private var target: UUID?
    private var undone: Run? { target.flatMap(shelf.run) ?? shelf.latest }
    private var undoRecords: [TrashRecord] {
        get { undone?.records ?? [] }
        set { if let id = undone?.id { shelf.update(id) { $0.records = newValue } } }
    }
    private var undoEntries: [Chosen] {
        get { undone?.entries ?? [] }
        set { if let id = undone?.id { shelf.update(id) { $0.entries = newValue } } }
    }
    private var undoNeedsScan: Bool {
        get { undone?.needsScan ?? false }
        set { if let id = undone?.id { shelf.update(id) { $0.needsScan = newValue } } }
    }
    /// The history record of the move Undo would put back.
    var undoLogID: UUID? { undone?.id }
    /// Something from the last move can still be put back, and nothing else runs.
    var canUndo: Bool { !undoRecords.isEmpty && !trashing }
    /// Whether the move of this history record can still be put back.
    func canUndo(run id: UUID) -> Bool { !(shelf.run(id)?.records.isEmpty ?? true) && !trashing }
    private var scannedThisLaunch = false

    /// Where results, history and rules are saved, the searched folders,
    /// and the cleanup history; tests use their own.
    private let base: URL
    private let defaults: UserDefaults
    private let logURL: URL
    /// Deep Clean's keep list: what it keeps stays here too.
    private let keepList: URL
    /// What Deep Clean keeps, as last read: shown locked and never chosen.
    /// The move reads the list again itself.
    private(set) var keptInDeepClean = CleanKeepList()

    /// Kept in Deep Clean, or inside something kept there. A folder that
    /// only holds something kept can still be chosen: it goes around it.
    func isKeptElsewhere(_ path: String) -> Bool {
        keptInDeepClean.paths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// For tests: these footprints and no saved roots or results; rules
    /// are saved in `base`, and Deep Clean's keep list is one of the test's
    /// own there unless given.
    init(footprints: [ProjectFootprint], base: URL, defaults: UserDefaults, logURL: URL, keepList: URL? = nil) {
        self.base = base
        self.defaults = defaults
        self.logURL = logURL
        self.keepList = keepList ?? base.appending(path: "deep-clean-keep.json")
        roots = []
        self.footprints = footprints
        reloadRules()
    }

    init(
        base: URL = ProjectStore.defaultBase, defaults: UserDefaults = .standard, logURL: URL = CleanupLog.defaultURL,
        keepList: URL = CleanKeepList.defaultURL
    ) {
        self.base = base
        self.defaults = defaults
        self.logURL = logURL
        self.keepList = keepList
        roots = defaults.stringArray(forKey: "projects.roots") ?? ProjectFinder.defaultRoots()
        // The rules stay read here: nothing may be moved before it's known
        // whether they could be read. They're small; the results aren't.
        reloadRules()
        restored = false
        let roots = roots
        restoreJob = Task { [weak self] in
            let (history, last) = await Task.detached(priority: .userInitiated) {
                (ProjectStore.loadHistory(base: base), ProjectStore.loadLast(roots: roots, base: base))
            }.value
            self?.restore(history: history, last: last)
        }
    }

    /// Reading the saved results off the main actor, so a caller can wait
    /// for them. Nil for the test initializer, which has nothing to read.
    private(set) var restoreJob: Task<Void, Never>?
    private var restored = true
    /// A launch scan asked for before the saved result was read, which
    /// decides whether it's needed.
    private var scanWhenRestored: Bool?

    /// Shows the saved result once read, unless a scan has started first;
    /// then runs the launch scan that waited for it.
    private func restore(history saved: [String: [ProjectStore.Sample]], last: ProjectStore.Saved?) {
        restored = true
        if history.isEmpty { history = saved }
        if let last, !scannedThisLaunch, scannedAt == nil {
            footprints = last.footprints
            scannedAt = last.date
        }
        if let background = scanWhenRestored {
            scanWhenRestored = nil
            scanIfNeeded(background: background)
        }
    }

    // MARK: Scanning

    /// A complete result younger than this is shown as it is, not measured
    /// again at launch or when the pane opens; Rescan always measures.
    static let freshFor: TimeInterval = 10 * 60

    /// The running scan, so launch work can wait for it before starting the
    /// next heavy job.
    private(set) var scanJob: Task<Void, Never>?

    /// Once per launch, unless the last complete result is still fresh: the
    /// pane opens on the last result and refreshes. `background` is for a
    /// scan nobody is waiting on yet, which uses fewer threads.
    func scanIfNeeded(background: Bool = false) {
        guard restored else {
            scanWhenRestored = background
            return
        }
        guard !scannedThisLaunch, !scanning else { return }
        if let at = scannedAt, Date().timeIntervalSince(at) < Self.freshFor { return }
        scan(background: background)
    }

    func scan(background: Bool = false) {
        // The tree mustn't change under a move or Undo that's using it;
        // the move scans again itself when it ends.
        guard !trashing else {
            scanAfterTrash = true
            return
        }
        progress?.cancel()
        let p = ScanProgress()
        progress = p
        reloadKeptElsewhere()
        rescanJobs = [:]
        rescanning = []
        scannedThisLaunch = true
        scanning = true
        measuredCount = 0
        let roots = roots
        let rules = rules
        let level = PerformanceLevel.current()
        let workers = level.workers(background: background)
        // Projects walks every project folder, so even a scan someone waits
        // on stays a step below the other panes.
        let list = listProjects
        scanJob = Task.detached(priority: level.priority(background: true)) { [weak self] in
            let all = list(
                roots, rules, p, workers,
                { found in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.found(found, run: p) } }
                },
                { done in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.measured(done, run: p) } }
                })
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(all, run: p) } }
        }
    }

    /// Finds and measures every project; tests hold it to keep a scan under
    /// way, on projects of their own.
    @ObservationIgnored var listProjects: @Sendable (
        _ roots: [String], _ rules: ProjectRules, _ progress: ScanProgress, _ workers: Int,
        _ onFound: ([ProjectFootprint]) -> Void, _ onProject: (ProjectFootprint) -> Void
    ) -> ProjectListing = {
        ProjectScanner.list(roots: $0, rules: $1, progress: $2, workers: $3, onFound: $4, onProject: $5)
    }

    func stop() { progress?.cancel() }

    /// The projects are known: keep what the last scan measured inside each
    /// folder until it's measured again, with the outside data fresh.
    private func found(_ found: [ProjectFootprint], run: ScanProgress) {
        guard run === progress else { return }
        let old = Dictionary(footprints.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        footprints = found.map { f in
            guard let o = old[f.id] else { return f }
            return ProjectFootprint(
                project: f.project, items: o.items.filter { $0.attribution == .inside } + f.items, measured: false)
        }
        prune()
    }

    private func measured(_ f: ProjectFootprint, run: ScanProgress) {
        guard run === progress, let i = footprints.firstIndex(where: { $0.id == f.id }) else { return }
        footprints[i] = f
        measuredCount += 1
        prune()
    }

    /// Only a complete scan is saved, and becomes the base for growth.
    private func finished(_ listing: ProjectListing, run: ScanProgress) {
        guard run === progress else { return }
        scanning = false
        progress = nil
        guard !run.isCancelled else { return }
        footprints = listing.footprints
        scannedAt = Date()
        prune()
        // Saved off the main thread; only the newest complete scan lands.
        incomplete = !listing.isComplete
        unreadablePlaces = listing.unreadable
        let roots = roots
        let base = base
        saveGeneration += 1
        let generation = saveGeneration
        Task {
            let history = await withCheckedContinuation { cont in
                Self.saves.async { cont.resume(returning: ProjectStore.save(listing, roots: roots, base: base)) }
            }
            if generation == saveGeneration { self.history = history }
        }
    }

    private var saveGeneration = 0
    /// The last scan couldn't read a searched folder, a place outside the
    /// projects or part of one, so what it shows may be short of projects
    /// or sizes, and it didn't replace the last complete result.
    private(set) var incomplete = false
    /// The folders the last scan couldn't read even though they're there:
    /// what's in them isn't listed.
    private(set) var unreadablePlaces: [String] = []
    /// Saves run one at a time, in the order the scans finished.
    private static let saves = DispatchQueue(label: "mymole.projects-save", qos: .utility)

    /// Chosen paths and selected rows that no longer exist.
    private func prune() {
        let kept = chosen.filter { owner(of: $0) != nil }
        if kept.count != chosen.count { chosen = kept }
        tidyExcluded()
        selection.formIntersection(Set(footprints.map(\.id)))
    }

    // MARK: Reading

    func footprint(_ id: String) -> ProjectFootprint? { footprints.first { $0.id == id } }

    /// Change of the project's total over about the last day, and since when.
    func growth(_ id: String) -> (bytes: Int64, since: Date)? { ProjectStore.growth(history[id] ?? []) }

    var totalBytes: Int64 { footprints.reduce(0) { $0 + $1.bytes } }
    var freeableBytes: Int64 { footprints.reduce(0) { $0 + $1.removableBytes } }
    var outsideBytes: Int64 { footprints.reduce(0) { $0 + $1.outsideBytes } }

    func count(_ heat: Heat) -> Int { footprints.filter { Heat($0.lastActivity) == heat }.count }

    func bytes(_ category: FootprintCategory) -> Int64 { footprints.reduce(0) { $0 + $1.bytes(category) } }

    // MARK: Choosing

    /// Every chosen entry, with the item and project it belongs to.
    /// What goes: each chosen path that isn't already inside another
    /// chosen one, sized without what's left out of it.
    var chosenEntries: [Chosen] {
        guard !chosen.isEmpty else { return [] }
        _ = partSizes
        let ix = index
        return chosen.sorted().compactMap { p in
            guard let o = owner(of: p), marker(above: p, top: o.entry.path)?.chosen != true else { return nil }
            let base = p == o.entry.path ? o.entry : partInfo[p] ?? FootprintEntry(path: p, bytes: 0, modified: .distantPast)
            let left = ix.leftOut[p] ?? 0
            if left == 0 && p == o.entry.path { return o }
            let entry = FootprintEntry(path: p, bytes: max(0, base.bytes - left), modified: base.modified)
            return Chosen(project: o.project, item: o.item, entry: entry, part: true)
        }
    }

    /// Paths left out of `path` when it goes.
    func excluded(inside path: String) -> [String] {
        excluded.filter { $0.hasPrefix(path + "/") }
    }

    var chosenBytes: Int64 { chosenEntries.reduce(0) { $0 + $1.entry.bytes } }

    /// The item's entries that the age filter lets through.
    func eligible(_ item: FootprintItem) -> [FootprintEntry] {
        item.removable ? item.entries(olderThan: age.cutoff).filter { !isKeptElsewhere($0.path) } : []
    }

    enum Check { case off, mixed, on }

    func check(_ item: FootprintItem) -> Check {
        guard let counts = index.perItem[item.id] else { return .off }
        if counts.whole == 0 && !counts.parts { return .off }
        return !counts.parts && counts.whole >= eligible(item).count ? .on : .mixed
    }

    /// Off or partly chosen: everything the age filter allows goes. Fully
    /// chosen: nothing does.
    func toggle(_ item: FootprintItem) {
        if check(item) == .on {
            clear(item)
        } else {
            clear(item)
            choose(eligible(item).map(\.path))
        }
    }

    /// Chooses whole entries; whatever was chosen or left out inside them
    /// is part of them again.
    private func choose(_ entries: [String]) {
        guard !entries.isEmpty else { return }
        let picked = Set(entries)
        let inside = { (p: String) in picked.contains { p.hasPrefix($0 + "/") } }
        var c = chosen.filter { !inside($0) }
        c.formUnion(picked)
        excluded = excluded.filter { !inside($0) && !picked.contains($0) }
        chosen = c
    }

    private func clear(_ item: FootprintItem) {
        let mine = { (p: String) in self.owner(of: p)?.item.id == item.id }
        excluded = excluded.filter { !mine($0) }
        chosen = chosen.filter { !mine($0) }
    }

    /// Chooses the rebuildable data (dependencies, build output, caches) of
    /// the given projects, and the folders the user added for cleaning,
    /// within the age filter.
    /// Anything changed within this long is likely in use and is never
    /// chosen automatically; it can still be ticked by hand.
    static let recentlyActive: TimeInterval = 7 * 86_400

    func chooseRebuildable(in ids: some Collection<String>, now: Date = Date()) {
        var recent = 0
        var byName = 0
        for id in ids {
            guard let f = footprint(id) else { continue }
            for item in f.items where item.category.rebuildable || item.category == .marked {
                // Tied by a name alone, it may be another project's: ticked by hand only.
                guard item.attribution != .nameMatch else {
                    byName += 1
                    continue
                }
                let entries = eligible(item)
                let old = entries.filter { now.timeIntervalSince($0.modified) > Self.recentlyActive }
                recent += entries.count - old.count
                choose(old.map(\.path))
            }
        }
        var left: [String] = []
        if recent > 0 { left.append(String(localized: "\(recent) item\(recent == 1 ? "" : "s") changed in the last week")) }
        if byName > 0 { left.append(String(localized: "\(byName) group\(byName == 1 ? "" : "s") matched by name only")) }
        if !left.isEmpty {
            show(Notice(text: String(localized: "Left unchosen: \(left.joined(separator: " and ")); tick them yourself if they can go"), canUndo: false))
        }
    }

    func clearChoice(in ids: some Collection<String>) {
        for id in ids {
            guard let f = footprint(id) else { continue }
            for item in f.items { clear(item) }
        }
    }

    // MARK: Trash

    /// Why nothing can be moved now, or nil. A running scan replaces the
    /// list when it ends, so a move waits for it, as in the other panes.
    var trashBlocker: String? {
        if rulesError != nil { return String(localized: "Your project rules couldn't be read") }
        if scanning { return String(localized: "Wait for the scan to finish.") }
        if trashing { return String(localized: "Moving to the Trash…") }
        return nil
    }

    /// Moves the chosen entries to the Trash off the main thread. The rules
    /// are read again from disk first, and a list that can't be read stops
    /// the run. Whatever is kept stays, even inside a chosen folder: the
    /// folder stays and everything around the kept items goes.
    func trashChosen() {
        let picked = chosenEntries
        guard !picked.isEmpty, !trashing else { return }
        // A scan that started after the move was asked for would put back
        // in the list what the move takes out of it.
        guard !scanning else {
            show(Notice(text: String(localized: "Nothing was moved: a scan is running. Try again when it's done."), canUndo: false))
            return
        }
        let onDisk: ProjectRules
        let base = base
        do {
            onDisk = try ProjectStore.loadRules(base: base)
            rulesError = nil
        } catch {
            rulesError = Problem(.projectRules, error)
            show(Notice(text: String(localized: "Nothing was moved: your project rules couldn't be read."), canUndo: false))
            return
        }
        // What Deep Clean keeps stays here too; a list that can't be read
        // stops the run, as unreadable rules do.
        let keepList = keepList
        do {
            keptInDeepClean = try CleanKeepList.load(from: keepList)
        } catch {
            show(Notice(text: String(localized: "Nothing was moved: Deep Clean's keep list couldn't be read."), canUndo: false))
            return
        }
        let current = rules
        // A path kept in Deep Clean counts as one kept here: it's left
        // alone, and a chosen folder holding it goes around it.
        var merged = current.merging(onDisk)
        merged.keepPaths.formUnion(keptInDeepClean.paths)
        let guarding = merged
        // What the user left out of a chosen folder stays, like a kept path.
        let picks = picked.map {
            (path: $0.entry.path, project: $0.project, worktree: $0.item.category == .worktrees, leftOut: excluded(inside: $0.entry.path))
        }
        let backend = trashBackend
        trashing = true
        Task {
            let (plan, held, outcome) = await jobs.perform(.moveToTrash) { job in
                // The picks never overlap: one inside another sits in
                // something the outer one leaves out.
                var plan: [String: [String]] = [:]
                var held: [String: String] = [:]
                for p in picks {
                    if let why = ProjectGuard.reason(for: p.path, project: p.project, worktree: p.worktree) {
                        held[p.path] = why
                    } else {
                        var rules = guarding
                        rules.keepPaths.formUnion(p.leftOut)
                        plan[p.path] = rules.trashPaths(for: p.path)
                    }
                }
                // Each planned path goes only while it's still inside its chosen
                // folder with no link on the way, and the rules as they are now keep none of it.
                let owner = Dictionary(plan.flatMap { top, paths in paths.map { ($0, top) } }, uniquingKeysWith: { a, _ in a })
                let gate = TrashGate(
                    still: { p in
                        owner[p].map { top in (p == top || p.hasPrefix(top + "/")) && Trasher.noLinksBetween(top, and: p) } ?? false
                    },
                    protections: {
                        var read = current.merging(try ProjectStore.loadRules(base: base))
                        read.keepPaths.formUnion(try CleanKeepList.load(from: keepList).paths)
                        let now = read
                        return { now.guards($0) }
                    })
                return (plan, held, job.moveToTrash(plan.values.flatMap { $0 }, through: gate, backend: backend))
            }
            applyTrash(outcome, plan: plan, held: held, picked: picked)
        }
    }

    private func applyTrash(_ outcome: TrashOutcome, plan: [String: [String]], held: [String: String], picked: [Chosen]) {
        trashing = false
        let moved = Set(outcome.moved.map(\.original.path))
        // Gone whole: moved itself, not just around something kept.
        let whole = Set(plan.filter { top, paths in paths == [top] && moved.contains(top) }.keys)
        let gone = picked.filter { e in whole.contains { e.entry.path == $0 || e.entry.path.hasPrefix($0 + "/") } }
        let freed = gone.filter { whole.contains($0.entry.path) }.reduce(0) { $0 + $1.entry.bytes }
        let partly = Set(plan.filter { top, paths in paths != [top] }.keys)
        let goneByProject = Dictionary(grouping: gone, by: \.project)
        for i in footprints.indices {
            if let g = goneByProject[footprints[i].id] { footprints[i].remove(paths: Set(g.filter { !$0.part }.map(\.entry.path))) }
        }
        chosen.subtract(gone.map(\.entry.path))
        chosen = chosen.filter { p in !partly.union(held.keys).contains { p == $0 || p.hasPrefix($0 + "/") } }
        tidyExcluded()
        dropContents(touching: moved)
        // Parts went from inside entries, which are measured again; so is a
        // project whose measuring began before the move and would show
        // what went as still there.
        if partly.isEmpty {
            let stale = Set(gone.map(\.project)).intersection(rescanning)
            for project in Set(gone.filter(\.part).map(\.project)).union(stale) { rescan(project) }
        }
        let record = CleanupRecord(source: "Projects", items: outcome.moved.count, bytes: freed, failed: outcome.failed.count)
        if !outcome.moved.isEmpty {
            shelf.add(Run(id: record.id, records: outcome.moved, entries: gone, needsScan: !partly.isEmpty))
        }
        CleanupLog.submit(record, to: logURL)
        var text = outcome.moved.isEmpty && !outcome.failed.isEmpty
            ? nothingMoved(outcome.failed)
            : String(localized: "Moved \(outcome.moved.count) item\(outcome.moved.count == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))) to the Trash")
        if !outcome.moved.isEmpty && !outcome.failed.isEmpty { text += String(localized: " · \(outcome.failed.count) couldn't be moved") }
        if !partly.isEmpty { text += String(localized: " · \(partly.count) kept in part") }
        if let why = held.values.sorted().first {
            text += String(localized: " · \(held.count) protected (\(why.trimmingCharacters(in: CharacterSet(charactersIn: "."))))")
        }
        show(Notice(text: text, canUndo: !outcome.moved.isEmpty))
        // Folders emptied around kept items are measured again.
        if !partly.isEmpty || scanAfterTrash { scanAfterTrash = false; scan() }
    }

    /// Where moved items go; tests use a folder of their own.
    var trashBackend: TrashBackend = .live
    /// Where its moves and Undos wait their turn among every pane's.
    var jobs: TrashJobs = .shared

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
        trashing = true
        Task {
            let failedRecords = await jobs.perform(.putBack) { $0.putBack(records) }
            trashing = false
            applyUndo(failedRecords)
            target = nil
        }
    }

    private func applyUndo(_ failedRecords: [TrashRecord]) {
        let failed = Set(failedRecords.map(\.original.path))
        let back = undoEntries.filter { e in !failed.contains { e.entry.path == $0 || e.entry.path.hasPrefix($0 + "/") } }
        for (project, entries) in Dictionary(grouping: back, by: \.project) {
            guard let i = footprints.firstIndex(where: { $0.id == project }) else { continue }
            footprints[i].restore(entries.filter { !$0.part }.map { ($0.item, $0.entry) })
            if entries.contains(where: \.part) { rescan(project) }
        }
        dropContents(touching: back.map(\.entry.path))
        let restored = undoRecords.count - failed.count
        if let id = undoLogID {
            CleanupLog.submitRestore(id, restored: restored, bytes: back.reduce(0) { $0 + $1.entry.bytes }, failed: failed.count, in: logURL)
        }
        // What couldn't come back stays ready for another try.
        undoRecords = failedRecords
        undoEntries = undoEntries.filter { e in failed.contains { e.entry.path == $0 || e.entry.path.hasPrefix($0 + "/") } }
        let needsScan = undoNeedsScan
        undoNeedsScan = false
        if failed.isEmpty, let id = undone?.id { shelf.remove(id) }
        // A scan under way may have passed these folders before they came
        // back: it starts over, so its result has them.
        if needsScan || scanAfterTrash || scanning { scan() }
        scanAfterTrash = false
        show(Notice(
            text: failed.isEmpty ? String(localized: "Restored \(restored) item\(restored == 1 ? "" : "s")") : String(localized: "Restored \(restored); \(failed.count) couldn't be put back. Undo tries those again."),
            canUndo: !failed.isEmpty))
    }

    /// The last move's notice with its Undo, shown again after a passing
    /// notice while there's still something to put back.
    private var undoNotice: Notice?

    /// A notice with Undo stays until it's used, closed or replaced; any
    /// other passes after a few seconds.
    func show(_ n: Notice) {
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

    /// Changes the rules on disk as they are now, then measures again what
    /// they touch: one project for a path rule, every project for a name
    /// rule (which applies to all). Only a saved change counts: on any
    /// failure the file and the rules in use stay as they were.
    func changeRules(project: String?, _ change: (inout ProjectRules) -> Void) {
        do {
            rules = try ProjectStore.updateRules(base: base, change)
            rulesError = nil
        } catch {
            if (try? ProjectStore.loadRules(base: base)) == nil {
                rulesError = Problem(.projectRules, error)
                show(Notice(text: String(localized: "Not saved: your project rules couldn't be read."), canUndo: false))
            } else {
                show(Notice(text: String(localized: "Couldn't save your project rules: \(Problem(.projectRules, error).description)"), canUndo: false))
            }
            return
        }
        guard let project, !scanning, footprint(project) != nil else {
            scan()
            return
        }
        rescan(project)
    }

    /// Measures one project again: after its rules changed, or after parts
    /// of its entries went.
    func rescan(_ project: String) {
        guard !trashing else {
            scanAfterTrash = true
            return
        }
        guard !scanning, let f = footprint(project) else { return }
        rescanCount += 1
        let job = rescanCount
        rescanJobs[project] = job
        rescanning.insert(project)
        let rules = rules
        let all = footprints.map(\.project)
        let measure = measureProject
        Task.detached(priority: .userInitiated) { [weak self] in
            let fresh = measure(f.project, all, rules)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Only the newest measure of the project lands, and only
                    // it ends the project's measuring; a full scan since
                    // owns every project.
                    guard let self, self.rescanJobs[project] == job else { return }
                    self.rescanJobs[project] = nil
                    self.rescanning.remove(project)
                    guard let i = self.footprints.firstIndex(where: { $0.id == project }) else { return }
                    self.footprints[i] = fresh
                    self.prune()
                }
            }
        }
    }

    /// Measures one project again; tests hold it to finish runs out of order.
    @ObservationIgnored var measureProject: @Sendable (DevProject, [DevProject], ProjectRules) -> ProjectFootprint = {
        ProjectScanner.rescan($0, among: $1, rules: $2)
    }
    private var rescanCount = 0
    /// A scan asked for while a move or Undo ran; it starts when that ends.
    private var scanAfterTrash = false
    /// The rescan that owns each project being measured again.
    private var rescanJobs: [String: Int] = [:]

    /// Reads the saved rules again, at launch or after they failed to load.
    func reloadRules() {
        do {
            rules = try ProjectStore.loadRules(base: base)
            rulesError = nil
        } catch {
            rulesError = Problem(.projectRules, error)
        }
        reloadKeptElsewhere()
    }

    /// Reads what Deep Clean keeps, for showing it locked. A list that
    /// can't be read leaves what was known; a move stops on it by itself.
    private func reloadKeptElsewhere() {
        if let kept = try? CleanKeepList.load(from: keepList) { keptInDeepClean = kept }
    }
}
