import AppKit
import PrivilegedKit
import StorageKit
import SwiftUI

/// State of the Uninstall pane: installed apps, and the last uninstall that
/// can be undone. Lives on `AppModel`, so a slow first listing isn't lost
/// when the user switches panes.
@MainActor
@Observable
final class AppsModel {
    struct Notice: Equatable {
        let text: String
        let canUndo: Bool
    }

    /// What an app left system-wide: where it's looked for (empty: the real
    /// system), and the privileged tool that removes it.
    struct SystemSide {
        var base: String
        var isReady: @MainActor () -> Bool
        var remove: @MainActor (_ paths: [String], _ appID: String, _ ids: [String]) async throws -> RemovalReport
        /// Why the tool can't be asked now, such as another system task.
        var blocker: @MainActor () -> String? = { nil }

        static func live(_ privileged: PrivilegedClient) -> SystemSide {
            SystemSide(
                base: "", isReady: { privileged.isAvailable },
                remove: { try await privileged.removeLeftovers($0, appID: $1, ids: $2) },
                blocker: { privileged.blocker })
        }

        /// Looked for in the real system, never removed.
        static let unavailable = SystemSide(base: "", isReady: { false }, remove: { _, _, _ in RemovalReport() })
    }

    private(set) var apps: [AppBundle] = []
    private(set) var loading = false
    private(set) var scannedAt: Date?
    private(set) var isStale = false
    private(set) var uninstalling = false
    private(set) var notice: Notice?
    /// System-wide items the last uninstall couldn't delete, and why.
    private(set) var systemProblems: [SystemProblem] = []

    struct SystemProblem: Hashable {
        let path: String
        let reason: String
    }

    func dismissSystemProblems() { systemProblems = [] }

    let home: String
    let folders: [String]
    private let base: URL
    private let logURL: URL
    /// Moves an app bundle to the Trash; the live one goes through Finder,
    /// which asks for an administrator's password for apps owned by root.
    private let recycle: @MainActor ([String]) async -> TrashOutcome
    private let isRunning: @MainActor (AppBundle) -> Bool
    /// Other copies and editions of the app, wherever they are, so data a
    /// copy outside the Applications folders uses is never offered. Nil when
    /// they couldn't be looked up.
    private let otherCopies: @Sendable (AppBundle) -> [AppBundle]?
    private let system: SystemSide
    private var progress: ScanProgress?
    private var undoRecords: [TrashRecord] = []
    private var undoApp: AppBundle?
    /// The history record of the move Undo would put back.
    private(set) var undoLogID: UUID?
    /// Something from the last move can still be put back, and nothing else runs.
    var canUndo: Bool { !undoRecords.isEmpty && !uninstalling }
    private var undoDeleted = 0
    private let trash: TrashBackend
    /// The running Undo, so a caller can wait for it.
    private(set) var undoJob: Task<Void, Never>?
    private var undoSizes: [String: Int64] = [:]

    init(
        home: String = Home.path, folders: [String]? = nil, base: URL = AppStore.defaultBase,
        logURL: URL = CleanupLog.defaultURL,
        recycle: @escaping @MainActor ([String]) async -> TrashOutcome = AppsModel.finderRecycle,
        isRunning: @escaping @MainActor (AppBundle) -> Bool = AppsModel.liveIsRunning,
        otherCopies: @escaping @Sendable (AppBundle) -> [AppBundle]? = AppsModel.liveOtherCopies,
        system: SystemSide = .unavailable,
        trash: TrashBackend = .live
    ) {
        self.trash = trash
        self.home = home
        self.folders = folders ?? AppFinder.defaultFolders(home: home)
        self.base = base
        self.logURL = logURL
        self.recycle = recycle
        self.isRunning = isRunning
        self.otherCopies = otherCopies
        self.system = system
        if let saved = AppStore.load(folders: self.folders, base: base) {
            apps = saved.apps
            scannedAt = saved.date
            isStale = true
        }
    }

    // MARK: Listing

    private(set) var loadJob: Task<Void, Never>?

    func loadIfNeeded() {
        guard !loading, apps.isEmpty || isStale else { return }
        load()
    }

    func load(background: Bool = false) {
        // The list mustn't change under an uninstall or Undo; it's read after.
        guard !uninstalling else {
            loadAfterUninstall = true
            return
        }
        progress?.cancel()
        let p = ScanProgress()
        progress = p
        loading = true
        let folders = folders
        let level = PerformanceLevel.current()
        let workers = level.appWorkers(background: background)
        loadJob = Task.detached(priority: level.priority(background: background)) { [weak self] in
            let found = AppFinder.list(in: folders, progress: p, workers: workers)
            await self?.loaded(found, run: p)
        }
    }

    private func loaded(_ found: AppListing, run: ScanProgress) {
        guard run === progress else { return }
        loading = false
        progress = nil
        guard !run.isCancelled else { return }
        apps = found.apps
        scannedAt = .now
        isStale = false
        unreadableFolders = found.unreadable
        let folders = folders
        let base = base
        // In the order the listings finished, so an older one never lands last.
        StoreWrites.submit { AppStore.save(found, folders: folders, base: base) }
    }

    /// Folders the last listing couldn't read: apps there aren't shown.
    private(set) var unreadableFolders: [String] = []

    var totalBytes: Int64 { apps.reduce(0) { $0 + $1.bytes } }

    // MARK: Uninstalling

    /// Every installed app that counts when deciding what's `app`'s, or nil
    /// when the other copies couldn't be looked up.
    private func installed(besides app: AppBundle) async -> [AppBundle]? {
        let apps = apps
        let otherCopies = otherCopies
        guard let copies = await Task.detached(priority: .userInitiated, operation: { otherCopies(app) }).value else {
            return nil
        }
        return apps + copies.filter { c in !apps.contains { $0.path == c.path } }
    }

    /// The uninstaller `app` ships, if any: it should do the uninstalling.
    func ownUninstaller(of app: AppBundle) -> String? {
        AppFinder.ownUninstaller(of: app, folders: folders)
    }

    /// Where the user's shell or tool settings name the app.
    func mentions(of app: AppBundle) async -> [AppMention] {
        let home = home
        return await Task.detached(priority: .userInitiated) { AppMentions.find(for: app, home: home) }.value
    }

    /// What `app` left in the Library, or nil when other copies of it
    /// couldn't be looked up: then nothing is offered.
    func leftovers(for app: AppBundle) async -> [Leftover]? {
        let home = home
        guard let installed = await installed(besides: app) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let identity = AppIdentity.owned(AppIdentity.of(app), of: app, installed: installed)
            return AppLeftovers.find(for: app, home: home, installed: installed, identity: identity)
        }.value
    }

    /// Whether system-wide leftovers can be removed now.
    var canRemoveSystemLeftovers: Bool { system.isReady() }

    /// What `app` left outside your Library, or none when other copies
    /// couldn't be looked up.
    func systemLeftovers(for app: AppBundle) async -> [SystemLeftover] {
        guard let installed = await installed(besides: app) else { return [] }
        let base = system.base
        return await Task.detached(priority: .userInitiated) {
            let others = installed.filter { $0.path != app.path }.compactMap(\.bundleID)
            // What another installed app's longer ID names is that app's.
            return SystemLeftovers.find(ids: Self.systemIDs(of: app, installed: installed), base: base)
                .filter { l in !others.contains { l.name == $0 || l.name.hasPrefix($0 + ".") } }
        }.value
    }

    /// The app's own ID and its helpers', unless another copy is installed
    /// or a helper's ID is an installed app's own.
    nonisolated static func systemIDs(of app: AppBundle, installed: [AppBundle]) -> [String] {
        guard let id = app.bundleID, !installed.contains(where: { $0.path != app.path && $0.bundleID == id }) else { return [] }
        let taken = Set(installed.filter { $0.path != app.path }.compactMap(\.bundleID))
        return [id] + AppIdentity.owned(AppIdentity.of(app), of: app, installed: installed).helperIDs.filter { !taken.contains($0) }
    }

    func running(_ app: AppBundle) -> Bool { isRunning(app) }

    func quit(_ app: AppBundle) {
        guard let id = app.bundleID else { return }
        for r in NSRunningApplication.runningApplications(withBundleIdentifier: id) { r.terminate() }
    }

    enum Result: Equatable {
        case done
        case refused(String)
        case failed(String)
    }

    /// Moves the app, then the chosen leftovers, to the Trash, and has the
    /// privileged tool delete the chosen system-wide ones. A running app is refused;
    /// leftovers only go once the app itself has, and each is checked again
    /// first, the system-wide ones by the tool itself.
    func uninstall(_ app: AppBundle, leftovers: [Leftover], system chosenSystem: [SystemLeftover] = []) async -> Result {
        // Taken before the first wait, so a second request can't slip in
        // while this one looks things up, and released however it ends.
        guard !uninstalling else { return .refused("Another uninstall is running.") }
        uninstalling = true
        defer {
            uninstalling = false
            startLoadAfterUninstall()
        }
        if app.isProtected { return .refused("\(app.name) is part of macOS.") }
        if isRunning(app) { return .refused("\(app.name) is open. Quit it first.") }
        if ownUninstaller(of: app) != nil { return .refused("\(app.name) comes with its own uninstaller. Use that instead.") }
        // The app goes to Finder's Trash, so it's cleared through the gate first.
        let cleared = await Task.detached(priority: .userInitiated) {
            Trasher.clear([app.path], through: TrashGate(still: { Self.isSameApp($0, as: app) }))
        }.value
        if let why = cleared.refused.first?.reason {
            return .refused(why == "Protected location"
                ? "\(app.name) is in a protected location."
                : "\(app.name) changed since the list was made. Reload and try again.")
        }
        let installed = await installed(besides: app)
        // Read from the bundle while it's still here.
        let identity = await Task.detached(priority: .userInitiated) {
            installed.map { AppIdentity.owned(AppIdentity.of(app), of: app, installed: $0) } ?? AppIdentity()
        }.value
        if installed == nil && !(leftovers.isEmpty && chosenSystem.isEmpty) {
            return .refused("Other copies of \(app.name) couldn't be looked up, so its leftovers stay. Untick them to move only the app.")
        }
        if !chosenSystem.isEmpty && !system.isReady() {
            return .refused("System-wide leftovers can't be removed in this edition. Untick them to go on.")
        }
        if !chosenSystem.isEmpty, let why = system.blocker() {
            return .refused("\(why) Try again once it's done, or untick the system-wide leftovers.")
        }
        let systemIDs = await Task.detached(priority: .userInitiated) {
            installed.map { Self.systemIDs(of: app, installed: $0) } ?? []
        }.value
        // The lookups take a while: it must still be closed and still the same app.
        if isRunning(app) { return .refused("\(app.name) is open. Quit it first.") }
        let same = await Task.detached(priority: .userInitiated) { Self.isSameApp(app.path, as: app) }.value
        if !same { return .refused("\(app.name) changed since the list was made. Reload and try again.") }

        let appOutcome = await recycle([app.path])
        guard let appRecord = appOutcome.moved.first else {
            return .failed(appOutcome.failed.first.map { "\(app.name) wasn't moved: \($0.reason)" } ?? "\(app.name) wasn't moved.")
        }
        let home = home
        let backend = trash
        let rest = await Task.detached(priority: .userInitiated) {
            Trasher.moveToTrash(leftovers.map(\.path), through: TrashGate(still: { path in
                installed.map { AppLeftovers.isStillLeftover(path, of: app, home: home, installed: $0, identity: identity) } ?? false
            }), backend: backend)
        }.value

        var systemReport = RemovalReport()
        var systemError: String?
        if !chosenSystem.isEmpty, let id = app.bundleID {
            do {
                systemReport = try await system.remove(chosenSystem.map(\.path), id, systemIDs)
            } catch {
                systemError = error.localizedDescription
            }
        }
        let systemFailed = systemError == nil ? systemReport.failed.count + systemReport.refused.count : chosenSystem.count
        // Each one that stayed, with why and, when removal stopped part-way, where what's left is now.
        systemProblems = systemError.map { e in chosenSystem.map { SystemProblem(path: $0.path, reason: e) } }
            ?? (systemReport.failed.sorted { $0.key < $1.key }.map { SystemProblem(path: $0.key, reason: $0.value) }
                + systemReport.refused.map { SystemProblem(path: $0, reason: "Refused by the rules.") })

        apps.removeAll { $0.path == app.path }
        let moved = Set(rest.moved.map(\.original.path))
        let bytes = app.bytes + leftovers.filter { moved.contains($0.path) }.reduce(0) { $0 + $1.bytes } + systemReport.bytes
        // System parts are deleted for good and kept apart: no Undo brings them back.
        let record = CleanupRecord(
            source: "Uninstall", items: 1 + rest.moved.count, bytes: bytes,
            failed: rest.failed.count + systemFailed, deleted: systemReport.removed.count)
        CleanupLog.submit(record, to: logURL)
        undoRecords = [appRecord] + rest.moved
        undoApp = app
        undoLogID = record.id
        undoDeleted = systemReport.removed.count
        undoSizes = Dictionary(uniqueKeysWithValues: [(app.path, app.bytes)] + leftovers.filter { moved.contains($0.path) }.map { ($0.path, $0.bytes) })
        var text = "Moved \(app.name)"
        if !rest.moved.isEmpty { text += " and \(rest.moved.count) leftover\(rest.moved.count == 1 ? "" : "s")" }
        text += " (\(fmt(bytes))) to the Trash"
        if !rest.failed.isEmpty { text += " · \(rest.failed.count) couldn't be moved" }
        let deleted = systemReport.removed.count
        if deleted > 0 { text += " · \(deleted) system item\(deleted == 1 ? "" : "s") deleted for good" }
        if systemFailed > 0 { text += " · \(systemFailed) system item\(systemFailed == 1 ? "" : "s") stayed" }
        show(Notice(text: text, canUndo: true))
        return .done
    }

    /// Puts the last uninstall back, off the main thread.
    func undoUninstall() {
        guard !uninstalling, !undoRecords.isEmpty else { return }
        let records = undoRecords
        uninstalling = true
        undoJob = Task {
            let failed = await Task.detached(priority: .userInitiated) { Trasher.restore(records) }.value
            uninstalling = false
            applyUndo(failed)
            startLoadAfterUninstall()
        }
    }

    /// A listing asked for while an uninstall or Undo ran.
    private var loadAfterUninstall = false

    private func startLoadAfterUninstall() {
        guard loadAfterUninstall else { return }
        loadAfterUninstall = false
        load()
    }

    private func applyUndo(_ failed: [TrashRecord]) {
        let failedPaths = Set(failed.map(\.original.path))
        if let app = undoApp, !failedPaths.contains(app.path) {
            apps = (apps + [app]).sorted { $0.bytes > $1.bytes }
        }
        let back = undoRecords.map(\.original.path).filter { !failedPaths.contains($0) }
        let restored = back.count
        if let id = undoLogID {
            CleanupLog.submitRestore(id, restored: restored, bytes: back.reduce(0) { $0 + (undoSizes[$1] ?? 0) }, failed: failed.count, in: logURL)
        }
        var text = failed.isEmpty
            ? "Restored \(restored) item\(restored == 1 ? "" : "s")"
            : "Restored \(restored); \(failed.count) couldn't be put back. Undo tries those again, or use Put Back in the Trash."
        if undoDeleted > 0 { text += " System items deleted for good stay deleted." }
        // What couldn't come back stays ready for another try.
        undoRecords = failed
        if !failedPaths.contains(undoApp?.path ?? "") { undoApp = nil }
        if failed.isEmpty {
            undoLogID = nil
            undoDeleted = 0
        }
        show(Notice(text: text, canUndo: !failed.isEmpty))
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
            try? await Task.sleep(for: .seconds(5))
            guard notice == n else { return }
            withAnimation(.snappy) { notice = undoRecords.isEmpty ? nil : undoNotice }
        }
    }

    func dismissNotice() { withAnimation(.snappy) { notice = nil } }

    // MARK: Live system

    /// Still the same app at `path`: a real folder, not a link, with the
    /// bundle ID it was listed with.
    nonisolated static func isSameApp(_ path: String, as app: AppBundle) -> Bool {
        var st = stat()
        guard path == app.path, lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return false }
        let id = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String
        return id == app.bundleID
    }

    static func liveIsRunning(_ app: AppBundle) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL.path == app.path || (app.bundleID != nil && $0.bundleIdentifier == app.bundleID)
        }
    }

    /// Copies Launch Services knows by the exact ID, and copies and
    /// editions Spotlight finds by its start.
    nonisolated static func liveOtherCopies(_ app: AppBundle) -> [AppBundle]? {
        guard let id = app.bundleID else { return [] }
        let known = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
            .map { $0.standardizedFileURL.path }
            .filter { $0 != app.path && !$0.contains("/.Trash/") }
            .map { AppBundle(path: $0, name: app.name, bundleID: id, version: nil, bytes: 0, fromAppStore: false) }
        guard let found = AppSiblings.find(for: app, runner: .processes(timeLimit: 10)) else { return nil }
        return known + found.filter { f in !known.contains { $0.path == f.path } }
    }

    static func finderRecycle(_ paths: [String]) async -> TrashOutcome {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        do {
            let map = try await NSWorkspace.shared.recycle(urls)
            let moved = urls.compactMap { u in map[u].map { TrashRecord(original: u, trashed: $0) } }
            let failed = urls.filter { map[$0] == nil }.map { (path: $0.path, reason: "Not moved") }
            return TrashOutcome(moved: moved, failed: failed)
        } catch {
            return TrashOutcome(moved: [], failed: paths.map { (path: $0, reason: error.localizedDescription) })
        }
    }
}

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
