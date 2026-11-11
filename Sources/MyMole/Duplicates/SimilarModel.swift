import Foundation
import StorageKit
import SwiftUI

/// Pictures that look alike in the user's own folders: which are chosen
/// for the Trash, and what the last move can undo. Nothing is chosen until
/// the user asks, and one picture of every group always stays.
@MainActor
@Observable
final class SimilarModel {
    static let source = "Similar Photos"

    struct Notice: Equatable {
        let text: String
        let canUndo: Bool
    }

    private(set) var groups: [SimilarGroup] = []
    private(set) var unreadable: [String] = []
    private(set) var truncated = false
    private(set) var scanning = false
    private(set) var startedAt: Date?
    private(set) var scannedAt: Date?
    private(set) var step: DuplicateStep?
    private(set) var notice: Notice?
    var chosen = Set<String>()
    var selection = Set<String>()
    var fileSelection = Set<String>()
    /// What the user keeps elsewhere: Deep Clean's keep list and the paths
    /// kept in Projects. Tests use lists of their own.
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

    let roots: [String]
    private let home: String
    private let minimum: Int64
    private let logURL: URL
    private let trash: TrashBackend
    /// Where fingerprints of pictures read before are kept; nil keeps none.
    private let cacheURL: URL?
    /// Hears when a keep list is saved anywhere, to mark what's kept at once.
    @ObservationIgnored private var keepWatch: NSObjectProtocol?
    var jobs: TrashJobs = .shared

    init(
        home: String = Home.path, roots: [String]? = nil, minimum: Int64 = SimilarImages.standardMinimum,
        logURL: URL = CleanupLog.defaultURL, trash: TrashBackend = .live, cacheURL: URL? = FingerprintCache.defaultURL
    ) {
        self.cacheURL = cacheURL
        self.home = home
        self.roots = roots ?? SimilarImages.standardRoots(home: home)
        self.minimum = minimum
        self.logURL = logURL
        self.trash = trash
        keepWatch = NotificationCenter.default.addObserver(forName: KeepChanges.name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.keep = await self.keep.reloaded()
                self.chosen = self.chosen.filter { !self.keep.protects($0) }
            }
        }
    }

    // MARK: Searching

    func scan(background: Bool = false) {
        guard !trashing else { return }
        progress?.cancel()
        let p = ScanProgress()
        progress = p
        scanning = true
        startedAt = .now
        step = nil
        let (roots, minimum, cacheURL) = (roots, minimum, cacheURL)
        let level = PerformanceLevel.current()
        let updates = DuplicateScanUpdates()
        scanJob = Task { [self] in
            // Progress arrives from the search's threads; the views get the
            // newest a few times a second. Cancelled once the search ends.
            let publisher = Task { [self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: DuplicatesModel.publishEvery)
                    guard progress === p else { return }
                    step = updates.take().step
                }
            }
            let found = await Task.detached(priority: level.priority(background: background)) {
                await ScanBudget.shared.run(background: background, progress: p) {
                    let cache = cacheURL.map { SharedFingerprints(FingerprintCache.load(from: $0)) }
                    let found = SimilarImages.find(in: roots, minimum: minimum, progress: p, workers: level.workers(background: background), cache: cache) { s in
                        updates.update(s)
                    }
                    // Only a search that ran to its end adds to what's kept.
                    if !p.isCancelled, let cacheURL, let cache { cache.current.save(to: cacheURL) }
                    return found
                }
            }.value
            publisher.cancel()
            await finished(found, run: p)
        }
    }

    func stop() { progress?.cancel() }

    /// Only a complete search replaces the list.
    private func finished(_ found: DuplicateListing.Similar?, run: ScanProgress) async {
        guard run === progress else { return }
        scanning = false
        progress = nil
        step = nil
        guard !run.isCancelled, let found else { return }
        groups = found.groups
        unreadable = found.unreadable
        truncated = found.truncated
        scannedAt = .now
        let paths = Set(found.groups.flatMap { $0.images.map(\.path) })
        chosen.formIntersection(paths)
        fileSelection.formIntersection(paths)
        selection.formIntersection(Set(found.groups.map(\.id)))
        if selection.isEmpty, let first = found.groups.first { selection = [first.id] }
        keep = await keep.reloaded()
        chosen = chosen.filter { !keep.protects($0) }
    }

    // MARK: Reading

    var spareBytes: Int64 { groups.reduce(0) { $0 + $1.spare } }
    var chosenBytes: Int64 { groups.flatMap(\.images).filter { chosen.contains($0.path) }.reduce(0) { $0 + $1.bytes } }
    var shownGroups: [SimilarGroup] { groups.filter { selection.contains($0.id) } }
    private func group(of path: String) -> SimilarGroup? { groups.first { $0.images.contains { $0.path == path } } }

    // MARK: Choosing

    /// The last picture of a group that isn't chosen can't be: one always stays.
    func toggle(_ path: String) {
        if chosen.contains(path) {
            chosen.remove(path)
            return
        }
        guard !keep.protects(path) else {
            show(Notice(text: String(localized: "This picture is kept, so it stays."), canUndo: false))
            return
        }
        guard let g = group(of: path), g.images.contains(where: { $0.path != path && !chosen.contains($0.path) }) else {
            show(Notice(text: String(localized: "One picture always stays. Unchoose another first."), canUndo: false))
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
        for group in groups where group.images.contains(where: { listed.contains($0.path) }) {
            guard let retained = group.best else { continue }
            next.remove(retained.path)
            next.formUnion(group.images.filter { listed.contains($0.path) && $0.path != retained.path && !keep.protects($0.path) }.map(\.path))
        }
        chosen = next
    }

    /// In the selected groups, or in all when none is selected: every picture
    /// but the best one, the one with the most pixels.
    func chooseAllButBest(in groupIDs: Set<String>? = nil) {
        let targets = groupIDs.map { ids in groups.filter { ids.contains($0.id) } } ?? (selection.isEmpty ? groups : shownGroups)
        for g in targets {
            guard let best = g.best else { continue }
            chosen.subtract(g.images.map(\.path))
            chosen.formUnion(g.images.filter { $0.path != best.path && !keep.protects($0.path) }.map(\.path))
        }
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
        if chosen.isEmpty { return String(localized: "Choose at least one picture.") }
        if let why = keep.blocker { return why }
        if scanning { return String(localized: "Wait for the search to finish.") }
        if trashing { return String(localized: "Moving to the Trash…") }
        return nil
    }

    var canUndo: Bool { !(shelf.latest?.records.isEmpty ?? true) && !trashing }
    func canUndo(run id: UUID) -> Bool { !(shelf.run(id)?.records.isEmpty ?? true) && !trashing }

    /// Moves the chosen pictures to the Trash. Each is checked again right
    /// before it moves: unchanged, and with a picture of its group that isn't
    /// going still in place.
    func trashChosen() {
        keep.reload()
        chosen = chosen.filter { !keep.protects($0) }
        if let why = keep.blocker { show(Notice(text: why, canUndo: false)) }
        guard trashBlocker == nil else { return }
        let going = chosen
        let byPath = Dictionary(groups.flatMap { g in g.images.map { ($0.path, g) } }, uniquingKeysWith: { a, _ in a })
        let sizes = Dictionary(groups.flatMap(\.images).map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        let picked = going.filter { byPath[$0] != nil }.sorted()
        let (home, backend, kept) = (home, trash, keep.gate)
        trashing = true
        trashJob = Task {
            let outcome = await jobs.perform(.moveToTrash) { job in
                job.moveToTrash(picked, through: TrashGate(still: { p in
                    byPath[p].map { SimilarImages.mayGo(p, of: $0, going: going, home: home) } ?? false
                }, protections: kept), backend: backend)
            }
            trashing = false
            let moved = Set(outcome.moved.map(\.original.path))
            let bytes = sizes.filter { moved.contains($0.key) }
            groups = groups.compactMap { g in
                var g = g
                g.images.removeAll { moved.contains($0.path) }
                return g.images.count > 1 ? g : nil
            }
            chosen.subtract(picked)
            selection.formIntersection(Set(groups.map(\.id)))
            let total = bytes.values.reduce(0, +)
            let record = CleanupRecord(source: Self.source, items: moved.count, bytes: total, failed: outcome.failed.count)
            if !outcome.moved.isEmpty { shelf.add(Run(id: record.id, records: outcome.moved, bytes: bytes)) }
            CleanupLog.submit(record, to: logURL)
            var text = moved.isEmpty
                ? String(localized: "Nothing was moved")
                : String(localized: "Moved \(moved.count) picture\(moved.count == 1 ? "" : "s") (\(ByteSize.format(total))) to the Trash")
            if picked.count > moved.count { text += String(localized: " · \(picked.count - moved.count) left alone") }
            show(Notice(text: text, canUndo: !moved.isEmpty))
        }
    }

    /// Puts a move back: the one of history record `id`, or the latest. The
    /// folders are searched again after, so the groups are as on disk.
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
                    ? String(localized: "Restored \(back.count) picture\(back.count == 1 ? "" : "s")")
                    : String(localized: "Restored \(back.count); \(failed.count) couldn't be put back. Undo tries those again."),
                canUndo: !failed.isEmpty))
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
