import AppKit
import CoreServices
import Foundation
import StorageKit
import SwiftUI

/// What apps that are no longer on the Mac left in the user's Library, for
/// the sheet Uninstall opens: what's chosen, and what the last move can
/// undo. A fresh metadata-only inventory precedes every search, since an
/// app the list missed would make its own data look left behind.
@MainActor
@Observable
final class OrphansModel {
    static let source = "Removed Apps"

    struct Notice: Equatable {
        let text: String
        let canUndo: Bool
    }

    private(set) var items: [Orphan] = []
    private(set) var loading = false
    private(set) var loadedAt: Date?
    private(set) var searchProblem: String?
    private(set) var stopped = false
    private(set) var notice: Notice?
    var chosen = Set<String>()
    var selection = Set<String>()
    /// Set when something outside Uninstall, such as a notification, asks
    /// for the sheet; Uninstall opens it and clears this.
    var requested = false
    /// What the user keeps elsewhere: Deep Clean's keep list and the paths
    /// kept in Projects. Tests use lists of their own.
    var protections: UserProtections = .live { didSet { keep = SharedKeep(protections: protections) } }
    private(set) var keep = SharedKeep(protections: .live)

    private struct Run: UndoableRun {
        let id: UUID
        var records: [TrashRecord]
        var items: [Orphan]
    }

    private var shelf = UndoShelf<Run>()
    private(set) var trashing = false
    /// The running search, move or Undo, so a caller can wait for it.
    private(set) var job: Task<Void, Never>?
    private var installed: [AppBundle] = []

    private let home: String
    private let logURL: URL
    private let trash: TrashBackend
    private let known: @Sendable (String) -> Bool
    private let running: @MainActor () -> Set<String>
    /// The apps installed right now, or nil when that can't be told.
    private let installedNow: @Sendable () -> [AppBundle]?
    private let scanBudget: ScanBudget
    private let identityReaders: AppIdentity.Readers
    private var progress: ScanProgress?
    /// Searched folders the last search couldn't read.
    private(set) var unreadable: [String] = []
    /// Hears when a keep list is saved anywhere, to mark what's kept at once.
    @ObservationIgnored private var keepWatch: NSObjectProtocol?
    var jobs: TrashJobs = .shared

    init(
        home: String = Home.path, logURL: URL = CleanupLog.defaultURL, trash: TrashBackend = .live,
        known: @escaping @Sendable (String) -> Bool = OrphansModel.knownToLaunchServices,
        running: @escaping @MainActor () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        },
        installedNow: (@Sendable () -> [AppBundle]?)? = nil,
        scanBudget: ScanBudget = .shared,
        identityReaders: AppIdentity.Readers = .live,
        knownCopies: KnownAppCopies? = nil
    ) {
        let folders = AppFinder.defaultFolders(home: home)
        let inventory = installedNow ?? { AppFinder.installedNow(in: folders) }
        self.installedNow = {
            guard let current = inventory() else { return nil }
            guard let knownCopies else { return current }
            return knownCopies.adding(to: current)
        }
        self.home = home
        self.logURL = logURL
        self.trash = trash
        self.known = known
        self.running = running
        self.scanBudget = scanBudget
        self.identityReaders = identityReaders
        keepWatch = NotificationCenter.default.addObserver(forName: KeepChanges.name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.keep = await self.keep.reloaded()
                self.chosen = self.chosen.filter { !self.keep.protects($0) }
            }
        }
    }

    /// Whether LaunchServices knows an app by `id` anywhere on the Mac,
    /// such as one on another disk or inside another app.
    /// An app in a Trash doesn't count: it's on its way out.
    nonisolated static func knownToLaunchServices(_ id: String) -> Bool {
        var error: Unmanaged<CFError>?
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(id as CFString, &error)?.takeRetainedValue() as? [URL] else {
            // Unknown registration is protection, not evidence of an uninstall.
            guard let error = error?.takeRetainedValue() else { return true }
            return CFErrorGetDomain(error) as String != NSOSStatusErrorDomain || CFErrorGetCode(error) != Int(kLSApplicationNotFoundErr)
        }
        return urls.contains { !$0.path.contains("/.Trash/") && !$0.path.contains("/.Trashes/") }
    }

    // MARK: Searching

    /// Inventory needs identities, not the app sizes still being measured
    /// in Uninstall. A stale visible list must neither authorize removal
    /// nor hide an app just deleted in Finder.
    func load() {
        guard !loading, !trashing else { return }
        loading = true
        searchProblem = nil
        stopped = false
        let p = ScanProgress()
        progress = p
        let (home, known, running, installedNow, budget, readers) = (home, known, running(), installedNow, scanBudget, identityReaders)
        job = Task {
            let current = await Task.detached(priority: .userInitiated) { installedNow() }.value
            guard progress === p else { return }
            guard let current else {
                loading = false
                progress = nil
                searchProblem = String(localized: "The installed apps couldn't be read, so no leftovers were offered. Reload Apps and try again.")
                return
            }
            let owners = current
            let listing = await Task.detached(priority: .userInitiated) {
                await budget.run(background: false, progress: p) {
                    Orphans.list(home: home, installed: owners, known: known, running: running, progress: p, readers: readers)
                }
            }.value
            guard progress === p else { return }
            guard !p.isCancelled, let listing, !listing.cancelled else {
                loading = false
                progress = nil
                stopped = true
                return
            }
            guard !listing.unknownOwners else {
                loading = false
                progress = nil
                searchProblem = String(localized: "Installed apps' helper identities couldn't be read, so no leftovers were offered. Try Scan Again after checking app access.")
                return
            }
            let refreshedKeep = await keep.reloaded()
            guard progress === p, !p.isCancelled else {
                loading = false
                progress = nil
                stopped = true
                return
            }
            let found = listing.orphans
            unreadable = listing.unreadable
            keep = refreshedKeep
            self.installed = owners
            let firstResult = loadedAt == nil
            items = found
            loadedAt = .now
            loading = false
            progress = nil
            let paths = Set(found.map(\.path))
            chosen = firstResult ? Set(found.filter { $0.kind.chosenByDefault && !keep.protects($0.path) }.map(\.path)) : chosen.intersection(paths)
            selection.formIntersection(paths)
        }
    }

    func stop() { progress?.cancel() }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var chosenItems: [Orphan] { items.filter { chosen.contains($0.path) } }
    var chosenBytes: Int64 { chosenItems.reduce(0) { $0 + $1.bytes } }

    // MARK: Choosing

    func toggle(_ path: String) {
        if chosen.contains(path) { chosen.remove(path) } else if !keep.protects(path) { chosen.insert(path) }
    }

    func choose(_ paths: some Sequence<String>) { chosen.formUnion(paths.filter { !keep.protects($0) }) }

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
        if chosen.isEmpty { return String(localized: "Choose at least one leftover.") }
        if let why = keep.blocker { return why }
        if let why = searchProblem { return why }
        if loading { return String(localized: "Wait for the search to finish.") }
        if trashing { return String(localized: "Moving to the Trash…") }
        return nil
    }

    var canUndo: Bool { !(shelf.latest?.records.isEmpty ?? true) && !trashing }
    func canUndo(run id: UUID) -> Bool { !(shelf.run(id)?.records.isEmpty ?? true) && !trashing }

    private struct Owners: Sendable {
        let apps: [AppBundle]
        let ids: Set<String>
    }

    /// Moves the chosen leftovers to the Trash. Each is checked again right
    /// before it moves: still named after an ID nothing on the Mac answers
    /// to, and not kept. Who's installed and running is read again once the
    /// move's turn has come, since apps may have been installed or opened
    /// while it waited; when the apps can't be read, nothing moves.
    func trashChosen() {
        keep.reload()
        chosen = chosen.filter { !keep.protects($0) }
        if let why = keep.blocker { show(Notice(text: why, canUndo: false)) }
        guard trashBlocker == nil else { return }
        let picked = chosenItems
        let (home, backend, listed, known, kept, installedNow, readers) = (home, trash, installed, known, keep.gate, installedNow, identityReaders)
        trashing = true
        job = Task {
            let job = await jobs.begin(.moveToTrash)
            let current = await Task.detached(priority: .userInitiated) { () -> Owners? in
                guard let apps = installedNow(), let ids = Orphans.claimedIDs(of: apps, readers: readers) else { return nil }
                return Owners(apps: apps, ids: ids)
            }.value
            let runningNow = running()
            guard !job.isStopped, let current else {
                jobs.end(job)
                trashing = false
                show(Notice(
                    text: job.isStopped
                        ? String(localized: "Stopped before anything was moved.")
                        : String(localized: "The installed apps couldn't be read, so nothing was moved."),
                    canUndo: false))
                return
            }
            let installed = listed + current.apps
            let outcome = await Task.detached(priority: .userInitiated) {
                job.moveToTrash(picked.map(\.path), through: TrashGate(still: { p in
                    Orphans.isStillOrphan(p, home: home, installed: installed, known: known, running: runningNow, claimedIDs: current.ids)
                }, protections: kept), backend: backend)
            }.value
            jobs.end(job)
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
                : String(localized: "Moved \(gone.count) leftover\(gone.count == 1 ? "" : "s") (\(ByteSize.format(gone.reduce(0) { $0 + $1.bytes }))) to the Trash")
            if picked.count > gone.count { text += String(localized: " · \(picked.count - gone.count) left alone") }
            show(Notice(text: text, canUndo: !gone.isEmpty))
        }
    }

    /// Puts a move back: the one of history record `id`, or the latest.
    func undoTrash(run id: UUID? = nil) {
        guard !trashing, let run = id.flatMap(shelf.run) ?? shelf.latest, !run.records.isEmpty else { return }
        trashing = true
        job = Task {
            let failedRecords = await jobs.perform(.putBack) { $0.putBack(run.records) }
            trashing = false
            let failed = Set(failedRecords.map(\.original.path))
            let back = run.items.filter { !failed.contains($0.path) }
            CleanupLog.submitRestore(run.id, restored: back.count, bytes: back.reduce(0) { $0 + $1.bytes }, failed: failed.count, in: logURL)
            if failed.isEmpty {
                shelf.remove(run.id)
            } else {
                shelf.update(run.id) {
                    $0.records = failedRecords
                    $0.items = run.items.filter { failed.contains($0.path) }
                }
            }
            items = (items + back).sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
            show(Notice(
                text: failed.isEmpty
                    ? String(localized: "Restored \(back.count) leftover\(back.count == 1 ? "" : "s")")
                    : String(localized: "Restored \(back.count); \(failed.count) couldn't be put back. Undo tries those again."),
                canUndo: !failed.isEmpty))
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
