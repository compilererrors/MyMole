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
    /// What the user keeps elsewhere: Deep Clean's keep list and the paths
    /// kept in Projects. Tests use lists of their own.
    var protections: UserProtections = .live { didSet { keep = SharedKeep(protections: protections) } }
    private(set) var keep = SharedKeep(protections: .live)

    private(set) var locations: [InstallerLocation]

    /// Folders the user added to the search, by path.
    static let extraKey = "installers.extraFolders"
    static func extraLocations(in defaults: UserDefaults = .standard) -> [InstallerLocation] {
        (defaults.stringArray(forKey: extraKey) ?? []).filter { $0.hasPrefix("/") }.map { InstallerLocation(path: $0, depth: 2) }
    }
    var addedFolders: Set<String> { Set(Self.extraLocations().map(\.path)) }

    /// Adds a folder of the user's choice to the search and searches again.
    /// In the App Sandbox only folders in the home folder can be read.
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose a folder to look for installers in, two levels deep")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        // Outside the home folder the sandbox needs the folder kept open.
        if !path.hasPrefix(Home.path + "/"), !ChosenFolders.shared.keep(url) {
            problem = String(localized: "MyMole couldn't keep access to that folder.")
            return
        }
        guard !locations.contains(where: { $0.path == path }) else { return }
        UserDefaults.standard.set(Array(addedFolders.union([path])).sorted(), forKey: Self.extraKey)
        locations.append(InstallerLocation(path: path, depth: 2))
        scan()
    }

    func removeFolder(_ path: String) {
        ChosenFolders.shared.release(path)
        UserDefaults.standard.set(Array(addedFolders.subtracting([path])).sorted(), forKey: Self.extraKey)
        locations.removeAll { $0.path == path }
        files.removeAll { $0.path.hasPrefix(path + "/") }
        chosen = chosen.filter { !$0.hasPrefix(path + "/") }
        scan()
    }

    /// Why adding a folder didn't work, until it's dismissed.
    var problem: String?
    private let base: URL
    private let logURL: URL
    /// A move that can still be put back, and the installers it took off the list.
    private struct Run: UndoableRun {
        let id: UUID
        var records: [TrashRecord]
        var files: [InstallerFile]
    }

    private var shelf = UndoShelf<Run>()
    /// The move an Undo works on: one History asked for, or else the latest.
    private var target: UUID?
    private var undone: Run? { target.flatMap(shelf.run) ?? shelf.latest }
    private var undoRecords: [TrashRecord] {
        get { undone?.records ?? [] }
        set { if let id = undone?.id { shelf.update(id) { $0.records = newValue } } }
    }
    private var undoFiles: [InstallerFile] {
        get { undone?.files ?? [] }
        set { if let id = undone?.id { shelf.update(id) { $0.files = newValue } } }
    }
    /// The history record of the move Undo would put back.
    var undoLogID: UUID? { undone?.id }
    /// Something from the last move can still be put back, and nothing else runs.
    var canUndo: Bool { !undoRecords.isEmpty && !trashing }
    /// Whether the move of this history record can still be put back.
    func canUndo(run id: UUID) -> Bool { !(shelf.run(id)?.records.isEmpty ?? true) && !trashing }
    private var progress: ScanProgress?
    private let trash: TrashBackend
    /// Where its moves and Undos wait their turn among every pane's.
    /// Hears when a keep list is saved anywhere, to mark what's kept at once.
    @ObservationIgnored private var keepWatch: NSObjectProtocol?
    var jobs: TrashJobs = .shared
    private var scannedThisLaunch = false

    init(
        locations: [InstallerLocation] = InstallerFinder.defaultLocations() + InstallersModel.extraLocations(), base: URL = InstallerStore.defaultBase,
        logURL: URL = CleanupLog.defaultURL, trash: TrashBackend = .live
    ) {
        self.trash = trash
        self.locations = locations
        self.base = base
        self.logURL = logURL
        restoreJob = Task { [weak self] in
            let saved = await Task.detached(priority: .userInitiated) { InstallerStore.load(for: locations, base: base) }.value
            await self?.restore(saved)
        }
        keepWatch = NotificationCenter.default.addObserver(forName: KeepChanges.name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reloadKept() }
        }
    }

    /// Reading the saved result off the main actor, so a caller can wait for it.
    private(set) var restoreJob: Task<Void, Never>?

    /// Shows the saved result once read, unless a scan has started first:
    /// that scan's result, or its stop, decides what's shown.
    private func restore(_ saved: InstallerStore.Saved?) async {
        guard let saved, !scannedThisLaunch, scannedAt == nil else { return }
        files = saved.files
        scannedAt = saved.date
        isStale = true
        await reloadKept()
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
            let found = await ScanBudget.shared.run(background: background, progress: p) { InstallerFinder.list(in: locations, progress: p) }
            await self?.finished(found, run: p)
        }
    }

    func stop() { progress?.cancel() }

    /// Only a complete scan replaces the list and is saved.
    private func finished(_ found: InstallerListing?, run: ScanProgress) async {
        guard run === progress else { return }
        scanning = false
        progress = nil
        guard !run.isCancelled, let found else { return }
        files = found.files
        scannedAt = .now
        isStale = false
        unreadableFolders = found.unreadable
        chosen.formIntersection(Set(found.files.map(\.path)))
        selection.formIntersection(Set(found.files.map(\.path)))
        await reloadKept()
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

    /// What's kept can't be chosen.
    func toggle(_ path: String) {
        if chosen.contains(path) { chosen.remove(path) } else if !keep.protects(path) { chosen.insert(path) }
    }

    func choose(_ paths: some Sequence<String>) { chosen.formUnion(paths.filter { !keep.protects($0) }) }

    func chooseAll() { chosen = Set(files.map(\.path).filter { !keep.protects($0) }) }

    // MARK: Keep

    /// Reads the keep lists again and lets go of what they now keep.
    func refreshKept() {
        keep.reload()
        chosen = chosen.filter { !keep.protects($0) }
    }

    /// `refreshKept`, with the lists read off the main thread.
    func reloadKept() async {
        keep = await keep.reloaded()
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

    /// Why the chosen installers can't go to the Trash right now, if so.
    var trashBlocker: String? {
        if chosen.isEmpty { return String(localized: "Choose at least one installer.") }
        if let why = keep.blocker { return why }
        if scanning { return String(localized: "Wait for the scan to finish.") }
        if trashing { return String(localized: "Moving to the Trash…") }
        return nil
    }

    private(set) var trashing = false
    /// The running move or Undo, so a caller can wait for it.
    private(set) var trashJob: Task<Void, Never>?

    /// Moves the chosen installers to the Trash off the main thread. Each one
    /// is checked again right before it moves, so a file replaced or moved
    /// since the scan is left alone.
    func trashChosen() {
        // The keep lists as they are now: what they keep stays, and a list
        // that can't be read stops the move.
        refreshKept()
        if let why = keep.blocker { show(Notice(text: why, canUndo: false)) }
        guard trashBlocker == nil else { return }
        let picked = chosenFiles
        let kept = keep.gate
        let locations = locations
        let backend = trash
        let byPath = Dictionary(picked.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        trashing = true
        trashJob = Task {
            let outcome = await jobs.perform(.moveToTrash) { job in
                job.moveToTrash(picked.map(\.path), through: TrashGate(still: { p in
                    byPath[p].map { InstallerFinder.isStillInstaller($0, in: locations) } ?? false
                }, protections: kept), backend: backend)
            }
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
        let record = CleanupRecord(
            source: "Installers", items: gone.count, bytes: gone.reduce(0) { $0 + $1.bytes }, failed: outcome.failed.count)
        if !outcome.moved.isEmpty { shelf.add(Run(id: record.id, records: outcome.moved, files: gone)) }
        CleanupLog.submit(record, to: logURL)
        let skipped = picked.count - gone.count
        var text = gone.isEmpty && !outcome.failed.isEmpty
            ? nothingMoved(outcome.failed)
            : String(localized: "Moved \(gone.count) installer\(gone.count == 1 ? "" : "s") (\(fmt(gone.reduce(0) { $0 + $1.bytes }))) to the Trash")
        if skipped > 0 { text += String(localized: " · \(skipped) left alone") }
        show(Notice(text: text, canUndo: !gone.isEmpty))
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
        trashing = true
        trashJob = Task {
            let failedRecords = await jobs.perform(.putBack) { $0.putBack(records) }
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
            if failed.isEmpty, let id = undone?.id { shelf.remove(id) }
            target = nil
            show(Notice(
                text: failed.isEmpty
                    ? String(localized: "Restored \(back.count) installer\(back.count == 1 ? "" : "s")")
                    : String(localized: "Restored \(back.count); \(failed.count) couldn't be put back. Undo tries those again."),
                canUndo: !failed.isEmpty))
        }
    }

    /// The last move's notice with its Undo, shown again after a passing
    /// notice while there's still something to put back.
    private var undoNotice: Notice?

    /// A notice with Undo stays until it's used, closed or replaced; any
    /// other passes after a few seconds.
    private func show(_ n: Notice) {
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

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
