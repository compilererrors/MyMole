import Foundation
import StorageKit
import SwiftUI

/// State of the Startup Items pane: the launch agents and daemons found, and
/// the plug-ins in the Library,
/// which of the user's own are chosen for the Trash, and what the last move
/// can undo. Only the user's own agents can go; the ones that need an
/// administrator are shown and left.
@MainActor
@Observable
final class StartupModel {
    static let source = "Startup Items"

    struct Notice: Equatable {
        let text: String
        let canUndo: Bool
    }

    private(set) var items: [StartupItem] = []
    private(set) var unreadable: [String] = []
    /// Job lists that couldn't be read as one.
    private(set) var broken: [String] = []
    private(set) var loading = false
    private(set) var loadedAt: Date?
    private(set) var notice: Notice?
    var chosen = Set<String>()
    var selection = Set<String>()
    /// What the user keeps elsewhere: Deep Clean's keep list and the paths
    /// kept in Projects. Tests use lists of their own.
    var protections: UserProtections = .live { didSet { keep = SharedKeep(protections: protections) } }
    private(set) var keep = SharedKeep(protections: .live)

    private struct Run: UndoableRun {
        let id: UUID
        var records: [TrashRecord]
        var items: [StartupItem]
    }

    private var shelf = UndoShelf<Run>()
    private(set) var trashing = false
    /// The running load, move or Undo, so a caller can wait for it.
    private(set) var job: Task<Void, Never>?

    private let home: String
    private let root: String
    private let logURL: URL
    private let trash: TrashBackend
    /// Hears when a keep list is saved anywhere, to mark what's kept at once.
    @ObservationIgnored private var keepWatch: NSObjectProtocol?
    var jobs: TrashJobs = .shared

    init(home: String = Home.path, root: String = "", logURL: URL = CleanupLog.defaultURL, trash: TrashBackend = .live) {
        self.home = home
        self.root = root
        self.logURL = logURL
        self.trash = trash
        keepWatch = NotificationCenter.default.addObserver(forName: KeepChanges.name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reloadKept() }
        }
    }

    // MARK: Reading

    /// Reads the launch folders off the main thread. They hold a few dozen
    /// small files, so it's done again whenever the pane opens.
    func load() {
        guard !loading, !trashing else { return }
        liveRevision &+= 1
        loading = true
        let (home, root) = (home, root)
        let p = ScanProgress()
        progress = p
        job = Task {
            let found = await Task.detached(priority: .userInitiated) {
                let jobs = StartupItems.list(home: home, root: root)
                let plugins = Plugins.list(home: home, root: root, progress: p)
                return StartupListing(items: jobs.items + plugins.items, unreadable: jobs.unreadable + plugins.unreadable, broken: jobs.broken)
            }.value
            progress = nil
            // A stopped look keeps what was listed before.
            guard !p.isCancelled else {
                loading = false
                return
            }
            items = found.items
            unreadable = found.unreadable
            broken = found.broken
            loadedAt = .now
            loading = false
            let paths = Set(found.items.map(\.path))
            chosen.formIntersection(paths)
            selection.formIntersection(paths)
            await reloadKept()
            await refreshLive()
        }
    }

    /// What launchd has loaded now, by label; nil when it couldn't be asked
    /// (the App Sandbox can't). Only the user's own session is seen.
    private(set) var live: [String: LaunchdStatus.State]?
    @ObservationIgnored var readLive: @Sendable () -> [String: LaunchdStatus.State]? = {
        Edition.current.isSandboxed ? nil : LaunchdStatus.loaded()
    }
    @ObservationIgnored private var liveRevision: UInt64 = 0

    /// Session status changes independently of the launch files. Never reload choices
    /// or walk plug-in folders just to update a process badge.
    func refreshLive() async {
        guard !loading, !trashing else { return }
        liveRevision &+= 1
        let revision = liveRevision
        let read = readLive
        let current = await Task.detached(priority: .utility) { read() }.value
        guard !Task.isCancelled, revision == liveRevision, !loading, !trashing else { return }
        if current != live { live = current }
    }

    /// The running look, which Stop ends.
    @ObservationIgnored private var progress: ScanProgress?

    func stop() { progress?.cancel() }

    /// Only the user's own agents can be moved; the others need an administrator.
    func isRemovable(_ item: StartupItem) -> Bool { item.scope == .user && !keep.protects(item.path) }

    var leftovers: Int { items.filter(\.programMissing).count }
    var chosenItems: [StartupItem] { items.filter { chosen.contains($0.path) } }

    // MARK: Choosing

    func toggle(_ path: String) {
        guard let item = items.first(where: { $0.path == path }), isRemovable(item) else { return }
        if chosen.contains(path) { chosen.remove(path) } else { chosen.insert(path) }
    }

    func choose(_ paths: some Sequence<String>) {
        let removable = Set(items.filter(isRemovable).map(\.path))
        chosen.formUnion(paths.filter(removable.contains))
    }

    /// The user's own agents whose program is gone: nothing can start them.
    func chooseLeftovers() { choose(items.filter(\.programMissing).map(\.path)) }

    // MARK: Keep

    /// Reads the keep lists again and lets go of what they now keep.
    /// `refreshKept`, with the lists read off the main thread.
    func reloadKept() async {
        keep = await keep.reloaded()
        chosen = chosen.filter { !keep.protects($0) }
    }

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
        if chosen.isEmpty { return String(localized: "Choose at least one of your own login agents.") }
        if let why = keep.blocker { return why }
        if loading { return String(localized: "Wait for the list to load.") }
        if trashing { return String(localized: "Moving to the Trash…") }
        return nil
    }

    var canUndo: Bool { !(shelf.latest?.records.isEmpty ?? true) && !trashing }
    func canUndo(run id: UUID) -> Bool { !(shelf.run(id)?.records.isEmpty ?? true) && !trashing }

    /// Moves the chosen agents' files to the Trash, each checked again
    /// right before it moves. A job that's running keeps running until the
    /// next login; its file in the Trash can be put back.
    func trashChosen() {
        // The keep lists as they are now: what they keep stays, and a list
        // that can't be read stops the move.
        refreshKept()
        if let why = keep.blocker { show(Notice(text: why, canUndo: false)) }
        guard trashBlocker == nil else { return }
        let picked = chosenItems
        let kept = keep.gate
        let (home, backend) = (home, trash)
        trashing = true
        liveRevision &+= 1
        job = Task {
            let outcome = await jobs.perform(.moveToTrash) { job in
                job.moveToTrash(picked.map(\.path), through: TrashGate(still: { StartupItems.isStillRemovable($0, home: home) || Plugins.isStillRemovable($0, home: home) }, protections: kept), backend: backend)
            }
            trashing = false
            let moved = Set(outcome.moved.map(\.original.path))
            let gone = picked.filter { moved.contains($0.path) }
            items.removeAll { moved.contains($0.path) }
            chosen.subtract(picked.map(\.path))
            let record = CleanupRecord(source: Self.source, items: gone.count, bytes: gone.reduce(0) { $0 + $1.bytes }, failed: outcome.failed.count)
            if !outcome.moved.isEmpty { shelf.add(Run(id: record.id, records: outcome.moved, items: gone)) }
            CleanupLog.submit(record, to: logURL)
            var text = gone.isEmpty
                ? String(localized: "Nothing was moved")
                : String(localized: "Moved \(gone.count) startup item\(gone.count == 1 ? "" : "s") to the Trash. It takes effect at the next login")
            if picked.count > gone.count { text += String(localized: " · \(picked.count - gone.count) left alone") }
            show(Notice(text: text, canUndo: !gone.isEmpty))
        }
    }

    /// Puts a move back: the one of history record `id`, or the latest.
    func undoTrash(run id: UUID? = nil) {
        guard !trashing, let run = id.flatMap(shelf.run) ?? shelf.latest, !run.records.isEmpty else { return }
        trashing = true
        liveRevision &+= 1
        job = Task {
            let failedRecords = await jobs.perform(.putBack) { $0.putBack(run.records) }
            trashing = false
            let failed = Set(failedRecords.map(\.original.path))
            let back = run.items.filter { !failed.contains($0.path) }
            CleanupLog.submitRestore(run.id, restored: back.count, bytes: back.reduce(0) { $0 + $1.bytes }, failed: failed.count, in: logURL)
            // What couldn't come back stays ready for another try.
            if failed.isEmpty {
                shelf.remove(run.id)
            } else {
                shelf.update(run.id) {
                    $0.records = failedRecords
                    $0.items = run.items.filter { failed.contains($0.path) }
                }
            }
            show(Notice(
                text: failed.isEmpty
                    ? String(localized: "Restored \(back.count) startup item\(back.count == 1 ? "" : "s")")
                    : String(localized: "Restored \(back.count); \(failed.count) couldn't be put back. Undo tries those again."),
                canUndo: !failed.isEmpty))
            load()
        }
    }

    /// A notice with Undo stays until it's used, closed or replaced; any
    /// other passes after a few seconds.
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
