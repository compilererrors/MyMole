import Foundation
import StorageKit
import SwiftUI

/// State of the Installers pane: the installers found, which are chosen for
/// the Trash, and what the last move can undo. Lives on `AppModel`, so
/// leaving the pane mid-scan keeps the scan.
@MainActor
@Observable
final class InstallersModel {
    struct Notice: Equatable {
        let text: String
        let canUndo: Bool
    }

    private(set) var files: [InstallerFile] = []
    private(set) var scanning = false
    private(set) var startedAt: Date?
    /// When the shown result was complete; nil before the first full scan.
    private(set) var scannedAt: Date?
    /// The list is the saved result of an earlier launch.
    private(set) var isStale = false
    private(set) var notice: Notice?
    var chosen = Set<String>()
    var selection = Set<String>()

    let locations: [InstallerLocation]
    private let base: URL
    private let logURL: URL
    /// The history record of the move Undo would put back.
    private(set) var undoLogID: UUID?
    /// Something from the last move can still be put back, and nothing else runs.
    var canUndo: Bool { !undoRecords.isEmpty && !trashing }
    private var progress: ScanProgress?
    private var undoRecords: [TrashRecord] = []
    private var undoFiles: [InstallerFile] = []
    private let trash: TrashBackend
    private var scannedThisLaunch = false

    init(
        locations: [InstallerLocation] = InstallerFinder.defaultLocations(), base: URL = InstallerStore.defaultBase,
        logURL: URL = CleanupLog.defaultURL, trash: TrashBackend = .live
    ) {
        self.trash = trash
        self.locations = locations
        self.base = base
        self.logURL = logURL
        if let saved = InstallerStore.load(for: locations, base: base) {
            files = saved.files
            scannedAt = saved.date
            isStale = true
        }
    }

    // MARK: Scanning

    /// A complete result younger than this isn't scanned again when the
    /// pane opens; Rescan always scans.
    static let freshFor: TimeInterval = 10 * 60

    private(set) var scanJob: Task<Void, Never>?

    func scanIfNeeded() {
        guard !scanning else { return }
        if scannedThisLaunch, let at = scannedAt, Date().timeIntervalSince(at) < Self.freshFor { return }
        scan()
    }

    func scan(background: Bool = false) {
        // The list mustn't change under a move or Undo; it's scanned after.
        guard !trashing else {
            scanAfterTrash = true
            return
        }
        progress?.cancel()
        let p = ScanProgress()
        progress = p
        scannedThisLaunch = true
        scanning = true
        startedAt = .now
        let locations = locations
        scanJob = Task.detached(priority: PerformanceLevel.current().priority(background: background)) { [weak self] in
            let found = InstallerFinder.list(in: locations, progress: p)
            await self?.finished(found, run: p)
        }
    }

    func stop() { progress?.cancel() }

    /// Only a complete scan replaces the list and is saved.
    private func finished(_ found: InstallerListing, run: ScanProgress) {
        guard run === progress else { return }
        scanning = false
        progress = nil
        guard !run.isCancelled else { return }
        files = found.files
        scannedAt = .now
        isStale = false
        unreadableFolders = found.unreadable
        chosen.formIntersection(Set(found.files.map(\.path)))
        selection.formIntersection(Set(found.files.map(\.path)))
        let locations = locations
        let base = base
        // In the order the scans finished, so an older one never lands last.
        StoreWrites.submit { InstallerStore.save(found, locations: locations, base: base) }
    }

    /// Folders the last scan couldn't read: installers there aren't shown.
    private(set) var unreadableFolders: [String] = []

    // MARK: Reading

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var chosenFiles: [InstallerFile] { files.filter { chosen.contains($0.path) } }
    var chosenBytes: Int64 { chosenFiles.reduce(0) { $0 + $1.bytes } }

    // MARK: Choosing

    func toggle(_ path: String) {
        if chosen.contains(path) { chosen.remove(path) } else { chosen.insert(path) }
    }

    func choose(_ paths: some Sequence<String>) { chosen.formUnion(paths) }

    func chooseAll() { chosen = Set(files.map(\.path)) }

    // MARK: Trash

    /// Why the chosen installers can't go to the Trash right now, if so.
    var trashBlocker: String? {
        if chosen.isEmpty { return "Choose at least one installer." }
        if scanning { return "Wait for the scan to finish." }
        if trashing { return "Moving to the Trash…" }
        return nil
    }

    private(set) var trashing = false
    /// The running move or Undo, so a caller can wait for it.
    private(set) var trashJob: Task<Void, Never>?

    /// Moves the chosen installers to the Trash off the main thread. Each one
    /// is checked again right before it moves, so a file replaced or moved
    /// since the scan is left alone.
    func trashChosen() {
        guard trashBlocker == nil else { return }
        let picked = chosenFiles
        let locations = locations
        let backend = trash
        let byPath = Dictionary(picked.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        trashing = true
        trashJob = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Trasher.moveToTrash(picked.map(\.path), through: TrashGate(still: { p in
                    byPath[p].map { InstallerFinder.isStillInstaller($0, in: locations) } ?? false
                }), backend: backend)
            }.value
            applyTrash(outcome, picked: picked)
        }
    }

    /// A scan asked for while a move or Undo ran.
    private var scanAfterTrash = false

    private func startScanAfterTrash() {
        guard scanAfterTrash else { return }
        scanAfterTrash = false
        scan()
    }

    private func applyTrash(_ outcome: TrashOutcome, picked: [InstallerFile]) {
        trashing = false
        defer { startScanAfterTrash() }
        let moved = Set(outcome.moved.map(\.original.path))
        let gone = picked.filter { moved.contains($0.path) }
        files.removeAll { moved.contains($0.path) }
        chosen.subtract(picked.map(\.path))
        undoRecords = outcome.moved
        undoFiles = gone
        let record = CleanupRecord(
            source: "Installers", items: gone.count, bytes: gone.reduce(0) { $0 + $1.bytes }, failed: outcome.failed.count)
        undoLogID = record.id
        CleanupLog.submit(record, to: logURL)
        let skipped = picked.count - gone.count
        var text = gone.isEmpty && !outcome.failed.isEmpty
            ? nothingMoved(outcome.failed)
            : "Moved \(gone.count) installer\(gone.count == 1 ? "" : "s") (\(fmt(gone.reduce(0) { $0 + $1.bytes }))) to the Trash"
        if skipped > 0 { text += " · \(skipped) left alone" }
        show(Notice(text: text, canUndo: !gone.isEmpty))
    }

    /// Puts the last move back, off the main thread.
    func undoTrash() {
        guard !trashing, !undoRecords.isEmpty else { return }
        let records = undoRecords
        trashing = true
        trashJob = Task {
            let failedRecords = await Task.detached(priority: .userInitiated) { Trasher.restore(records) }.value
            trashing = false
            defer { startScanAfterTrash() }
            let failed = Set(failedRecords.map(\.original.path))
            let back = undoFiles.filter { !failed.contains($0.path) }
            files = (files + back).sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
            if let id = undoLogID {
                CleanupLog.submitRestore(id, restored: back.count, bytes: back.reduce(0) { $0 + $1.bytes }, failed: failed.count, in: logURL)
            }
            // What couldn't come back stays ready for another try.
            undoRecords = failedRecords
            undoFiles = undoFiles.filter { failed.contains($0.path) }
            if failed.isEmpty { undoLogID = nil }
            show(Notice(
                text: failed.isEmpty
                    ? "Restored \(back.count) installer\(back.count == 1 ? "" : "s")"
                    : "Restored \(back.count); \(failed.count) couldn't be put back. Undo tries those again.",
                canUndo: !failed.isEmpty))
        }
    }

    /// The last move's notice with its Undo, shown again after a passing
    /// notice while there's still something to put back.
    private var undoNotice: Notice?

    /// A notice with Undo stays until it's used, closed or replaced; any
    /// other passes after a few seconds.
    private func show(_ n: Notice) {
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

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
