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
    let ownAppPath: String?
    private let ownAppID: String?
    /// Only the app coordinator can prepare removal of this running copy.
    var prepareSelfRemoval: (@MainActor () async -> String?)?
    private(set) var leftoverProblems: [SystemProblem] = []

    static var ownBundlePath: String? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url.standardizedFileURL.path : nil
    }

    func isSelf(_ app: AppBundle) -> Bool { ownAppPath == app.path && ownAppID != nil && ownAppID == app.bundleID }
    func sharesOwnIdentity(_ app: AppBundle) -> Bool { ownAppPath != nil && ownAppID != nil && ownAppID == app.bundleID }
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
    private let scanBudget: ScanBudget
    private let identityReaders: AppIdentity.Readers
    /// App copies discovered outside the usual folders. Paths are evidence to
    /// re-read, never cached ownership approval. Missing copies are ignored;
    /// unreadable or redirected copies stop attribution.
    let knownCopies: KnownAppCopies

    func rememberOtherCopies(_ copies: [AppBundle], unreadable: [String] = []) {
        knownCopies.remember(copies)
        knownCopies.rememberUnreadable(unreadable)
    }
    /// The mounted disk image a path is on, if any.
    private let imageOf: @Sendable (String) -> MountedImage?
    /// Ejects the volume mounted at a path; why it didn't, or nil.
    private let eject: @Sendable (String) -> String?
    private var progress: ScanProgress?
    private var listingStarted: ContinuousClock.Instant?
    private var firstAppsRecorded = false
    private var measuredCount = -1
    /// An uninstall that can still be put back: what moved, the app, how
    /// many system items went for good (no Undo brings them back), and the
    /// size of each moved item, by where it was.
    private struct Run: UndoableRun {
        let id: UUID
        var records: [TrashRecord]
        var app: AppBundle?
        var deleted: Int
        var sizes: [String: Int64]
    }

    private var shelf = UndoShelf<Run>()
    /// The uninstall an Undo works on: one History asked for, or else the latest.
    private var target: UUID?
    private var undone: Run? { target.flatMap(shelf.run) ?? shelf.latest }
    private var undoRecords: [TrashRecord] {
        get { undone?.records ?? [] }
        set { if let id = undone?.id { shelf.update(id) { $0.records = newValue } } }
    }
    private var undoApp: AppBundle? {
        get { undone?.app }
        set { if let id = undone?.id { shelf.update(id) { $0.app = newValue } } }
    }
    private var undoDeleted: Int { undone?.deleted ?? 0 }
    private var undoSizes: [String: Int64] { undone?.sizes ?? [:] }
    /// The history record of the move Undo would put back.
    var undoLogID: UUID? { undone?.id }
    /// Something from the last move can still be put back, and nothing else runs.
    var canUndo: Bool { !undoRecords.isEmpty && !uninstalling }
    /// Whether the uninstall of this history record can still be put back.
    func canUndo(run id: UUID) -> Bool { !(shelf.run(id)?.records.isEmpty ?? true) && !uninstalling }
    private let trash: TrashBackend
    /// What the user keeps in other panes: Deep Clean's keep list and the
    /// paths kept in Projects for what goes to the Trash, System Clean's
    /// list for what's deleted system-wide.
    private let protections: UserProtections
    /// Where its uninstalls and Undos wait their turn among every pane's.
    var jobs: TrashJobs = .shared
    /// The running Undo, so a caller can wait for it.
    private(set) var undoJob: Task<Void, Never>?

    init(
        home: String = Home.path, folders: [String]? = nil, base: URL = AppStore.defaultBase,
        logURL: URL = CleanupLog.defaultURL,
        recycle: @escaping @MainActor ([String]) async -> TrashOutcome = AppsModel.finderRecycle,
        isRunning: @escaping @MainActor (AppBundle) -> Bool = AppsModel.liveIsRunning,
        otherCopies: @escaping @Sendable (AppBundle) -> [AppBundle]? = AppsModel.liveOtherCopies,
        system: SystemSide = .unavailable,
        trash: TrashBackend = .live,
        protections: UserProtections = .live,
        imageOf: @escaping @Sendable (String) -> MountedImage? = { DiskImages.image(holding: $0) },
        eject: @escaping @Sendable (String) -> String? = AppsModel.liveEject,
        scanBudget: ScanBudget = .shared,
        ownAppPath: String? = AppsModel.ownBundlePath,
        ownAppID: String? = Bundle.main.bundleIdentifier,
        identityReaders: AppIdentity.Readers = .live,
        knownCopies: KnownAppCopies = KnownAppCopies()
    ) {
        self.knownCopies = knownCopies
        self.identityReaders = identityReaders
        self.imageOf = imageOf
        self.eject = eject
        self.trash = trash
        self.protections = protections
        self.home = home
        self.folders = folders ?? AppFinder.defaultFolders(home: home)
        self.base = base
        self.logURL = logURL
        self.recycle = recycle
        self.isRunning = isRunning
        self.otherCopies = otherCopies
        self.system = system
        self.scanBudget = scanBudget
        self.ownAppPath = ownAppPath
        self.ownAppID = ownAppID
        let folders = self.folders
        restoreJob = Task { [weak self] in
            let saved = await Task.detached(priority: .userInitiated) { AppStore.load(folders: folders, base: base) }.value
            self?.restore(saved)
        }
    }

    /// Reading the saved result off the main actor, so a caller can wait for it.
    private(set) var restoreJob: Task<Void, Never>?

    /// Shows the saved list once read, unless a listing has started first.
    private func restore(_ saved: AppStore.Saved?) {
        guard let saved, !loading, scannedAt == nil else { return }
        apps = saved.apps
        scannedAt = saved.date
        isStale = true
    }

    // MARK: Listing

    private(set) var loadJob: Task<Void, Never>?

    /// Stops the listing under way; what's listed now stays.
    func stop() { progress?.cancel() }

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
        listingStarted = .now
        firstAppsRecorded = !apps.isEmpty
        measuredCount = -1
        let folders = folders
        let level = PerformanceLevel.current()
        let workers = level.appWorkers(background: background)
        let budget = scanBudget
        let steps = LatestOnly<AppListingStep> { [weak self] step in self?.stepped(step, run: p) }
        loadJob = Task.detached(priority: level.priority(background: background)) { [weak self] in
            let inventory = AppFinder.inventory(in: folders, progress: p)
            steps.send(AppListingStep(apps: inventory.apps, measured: 0))
            guard !p.isCancelled else {
                await self?.loaded(inventory, run: p)
                return
            }
            let found = await budget.run(background: background, progress: p) {
                AppFinder.measure(inventory, progress: p, workers: workers, onStep: { steps.send($0) })
            }
            await self?.loaded(found, run: p)
        }
    }

    private func recordFirstApps() {
        guard !firstAppsRecorded, !apps.isEmpty, let start = listingStarted else { return }
        firstAppsRecorded = true
        Timings.record(.firstApps, since: start)
    }

    private func stepped(_ step: AppListingStep, run: ScanProgress) {
        guard run === progress, !run.isCancelled, loading, !uninstalling, step.measured >= measuredCount else { return }
        measuredCount = step.measured
        // Saved sizes stay usable while refreshed; a first listing fills in.
        guard scannedAt == nil else { return }
        apps = step.apps
        isStale = true
        recordFirstApps()
    }

    private func loaded(_ found: AppListing?, run: ScanProgress) {
        guard run === progress else { return }
        loading = false
        progress = nil
        guard !uninstalling else {
            loadAfterUninstall = true
            return
        }
        guard !run.isCancelled, let found else { return }
        apps = found.apps
        recordFirstApps()
        if let start = listingStarted { Timings.record(.appListing, since: start) }
        listingStarted = nil
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

    /// A listing started before a removal must never bring its old inventory back.
    private func beginUninstall() {
        if loading {
            progress?.cancel()
            progress = nil
            loading = false
            loadAfterUninstall = true
        }
        self.uninstalling = true
    }

    /// Every installed app that counts when deciding what's `app`'s, or nil
    /// when the other copies couldn't be looked up.
    private func installed(besides app: AppBundle) async -> [AppBundle]? {
        let otherCopies = otherCopies
        let folders = folders
        let discovered = knownCopies
        return await Task.detached(priority: .userInitiated) { () -> [AppBundle]? in
            guard let copies = otherCopies(app) else { return nil }
            // Metadata only, never sizes. A cached inventory cannot authorize removal.
            guard let fresh = AppFinder.installedNow(in: folders) else { return nil }
            var listed = fresh
            for copy in copies where !listed.contains(where: { $0.path == copy.path }) {
                guard let metadata = AppFinder.metadata(copy.path), metadata.bundleID != nil else { return nil }
                listed.append(metadata)
            }
            return discovered.adding(to: listed)
        }.value
    }

    private struct Ownership: Sendable {
        let installed: [AppBundle]
        let identity: AppIdentity
        let systemIDs: [String]
    }

    private func ownership(of app: AppBundle) async -> Ownership? {
        guard let installed = await installed(besides: app) else { return nil }
        let readers = identityReaders
        return await Task.detached(priority: .userInitiated) {
            guard Self.isSameApp(app.path, as: app),
                  let identity = AppIdentity.owned(for: app, installed: installed, readers: readers) else { return nil as Ownership? }
            let ids = Self.systemIDs(of: app, installed: installed, identity: identity)
            return Ownership(installed: installed, identity: identity, systemIDs: ids)
        }.value
    }

    /// The uninstaller `app` ships, if any: it should do the uninstalling.
    /// Looked for off the main thread: it lists folders on disk.
    func ownUninstaller(of app: AppBundle) async -> String? {
        let folders = folders
        let support = [home + "/Library/Application Support", system.base + "/Library/Application Support"]
        return await Task.detached(priority: .userInitiated) {
            AppFinder.ownUninstaller(of: app, folders: folders, supportFolders: support)
        }.value
    }

    /// Where the user's shell or tool settings name the app.
    func mentions(of app: AppBundle) async -> [AppMention] {
        let home = home
        return await Task.detached(priority: .userInitiated) { AppMentions.find(for: app, home: home) }.value
    }

    /// What `app` left in the Library, or nil when other copies of it
    /// couldn't be looked up: then nothing is offered.
    func leftovers(for app: AppBundle, deep: Bool = UserDefaults.standard.bool(forKey: AppsModel.deepKey)) async -> [Leftover]? {
        let home = home
        guard let ownership = await ownership(of: app) else { return nil }
        guard !Task.isCancelled else { return nil }
        let progress = ScanProgress()
        let budget = scanBudget
        return await withTaskCancellationHandler {
            let result = await Task.detached(priority: .userInitiated) {
                await budget.run(background: false, progress: progress) {
                    AppLeftovers.find(for: app, home: home, installed: ownership.installed, identity: ownership.identity, deep: deep, progress: progress)
                }
            }.value
            return progress.isCancelled || Task.isCancelled ? nil : result
        } onCancel: { progress.cancel() }
    }

    func leftovers(for removed: RemovedApp, deep: Bool) async -> [Leftover]? {
        let home = home
        guard await Task.detached(operation: { removed.isCurrent(home: home) }).value else { return nil }
        return await leftovers(for: removed.app, deep: deep)
    }

    /// Whether Uninstall searches deeper (`DeepLeftovers`), as last chosen.
    static let deepKey = "uninstall.searchDeeper"

    /// Bounded metadata discovery; these paths never enter a removal request.
    func relatedComponents(for app: AppBundle) async -> RelatedComponents.Report {
        let home = home
        let base = system.base
        return await Task.detached(priority: .userInitiated) {
            RelatedComponents.find(for: app, home: home, systemBase: base)
        }.value
    }

    /// Whether system-wide leftovers can be removed now.
    var canRemoveSystemLeftovers: Bool { system.isReady() }

    /// Which of `paths` the user's keep lists protect: Deep Clean's and the
    /// paths kept in Projects, or System Clean's for system-wide items. Nil
    /// when the lists can't be read: nothing is uninstalled then.
    func kept(among paths: [String], system: Bool = false) async -> Set<String>? {
        let protections = protections
        return await Task.detached(priority: .userInitiated) {
            guard let keeps = try? (system ? protections.readSystem() : protections.read()) else { return nil }
            return Set(paths.filter(keeps))
        }.value
    }

    /// What `app` left outside your Library, or none when other copies
    /// couldn't be looked up.
    func systemLeftovers(for app: AppBundle) async -> [SystemLeftover] {
        // macOS's own parts outside the Library are the system's.
        guard !app.isProtected, let ownership = await ownership(of: app) else { return [] }
        let base = system.base
        return await Task.detached(priority: .userInitiated) {
            let others = ownership.identity.otherOwnerIDs
            // What another installed app's longer ID names is that app's.
            return SystemLeftovers.find(ids: ownership.systemIDs, base: base)
                .filter { l in !others.contains { l.name.lowercased() == $0.lowercased() || l.name.lowercased().hasPrefix($0.lowercased() + ".") } }
        }.value
    }

    /// The app's own ID and its helpers', unless another copy is installed
    /// or a helper's ID is an installed app's own.
    nonisolated private static func systemIDs(of app: AppBundle, installed: [AppBundle], identity: AppIdentity) -> [String] {
        guard let id = app.bundleID, !identity.otherOwnerIDs.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return [] }
        let taken = Set(installed.filter { $0.path != app.path }.compactMap(\.bundleID))
        return [id] + identity.helperIDs.filter { !taken.contains($0) }
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
        guard !uninstalling else { return .refused(String(localized: "Another uninstall is running.")) }
        let itself = isSelf(app)
        if itself, prepareSelfRemoval == nil || !chosenSystem.isEmpty {
            return .refused(String(localized: "Use Uninstall MyMole in Settings to remove this running copy."))
        }
        beginUninstall()
        leftoverProblems = []
        defer {
            uninstalling = false
            startLoadAfterUninstall()
        }
        if app.isProtected { return .refused(String(localized: "\(app.name) is part of macOS.")) }
        if !itself, isRunning(app) { return .refused(String(localized: "\(app.name) is open. Quit it first.")) }
        if await ownUninstaller(of: app) != nil { return .refused(String(localized: "\(app.name) comes with its own uninstaller. Use that instead.")) }
        // A leftover named twice goes once.
        var named = Set<String>()
        let leftovers = leftovers.filter { named.insert($0.path).inserted }
        // The app goes to Finder's Trash, so it's cleared through the gate
        // first: still the same app, and not kept in another pane.
        if let why = await refusal(for: app) { return .refused(why) }
        let needsOwnership = !leftovers.isEmpty || !chosenSystem.isEmpty
        if needsOwnership, await ownership(of: app) == nil {
            return .refused(String(localized: "Ownership of \(app.name)'s leftovers couldn't be verified. Untick them to move only the app."))
        }
        if !chosenSystem.isEmpty && !system.isReady() {
            return .refused(String(localized: "System-wide leftovers can't be removed in this edition. Untick them to go on."))
        }
        if !chosenSystem.isEmpty, let why = system.blocker() {
            return .refused(String(localized: "\(why) Try again once it's done, or untick the system-wide leftovers."))
        }
        // The lookups take a while: it must still be closed.
        if !itself, isRunning(app) { return .refused(String(localized: "\(app.name) is open. Quit it first.")) }
        if itself, let why = await prepareSelfRemoval?() { return .refused(why) }

        // From here on one job: the app, its leftovers and the system part,
        // after any move or Undo of another pane and before the next.
        let jobs = jobs
        let job = await jobs.begin(.moveToTrash)
        defer { jobs.end(job) }
        if job.isStopped { return .refused(String(localized: "Stopped before anything was moved.")) }
        // Its turn may have come much later, after another pane's move or
        // Undo: cleared again right before Finder recycles it.
        if let why = await refusal(for: app) { return .refused(why) }
        if !itself, isRunning(app) { return .refused(String(localized: "\(app.name) is open. Quit it first.")) }
        // Read identities while the app is still present, after the queue wait.
        let approved = needsOwnership ? await ownership(of: app) : nil
        if needsOwnership, approved == nil {
            return .refused(String(localized: "Ownership changed or couldn't be verified while waiting. Nothing was uninstalled."))
        }
        if needsOwnership, let why = await refusal(for: app) { return .refused(why) }
        if job.isStopped { return .refused(String(localized: "Stopped before anything was moved.")) }
        if !itself, isRunning(app) { return .refused(String(localized: "\(app.name) is open. Quit it first.")) }
        // Locked in Finder: unlocked to move, locked again if it stays.
        let appLocked = Locks.isLocked(app.path)
        if appLocked, !Locks.unlock(app.path) {
            return .failed(String(localized: "\(app.name) is locked, and MyMole couldn't unlock it."))
        }
        let appOutcome = await recycle([app.path])
        if appLocked, appOutcome.moved.isEmpty { Locks.lock(app.path) }
        job.record(.moveToTrash, done: appOutcome.moved.map(\.original.path),
                   failed: Dictionary(appOutcome.failed.map { ($0.path, $0.reason) }, uniquingKeysWith: { a, _ in a }), refused: [])
        guard let appRecord = appOutcome.moved.first else {
            return .failed(
                appOutcome.failed.first.map { String(localized: "\(app.name) wasn't moved: \($0.reason)") }
                    ?? String(localized: "\(app.name) wasn't moved."))
        }
        let home = home
        let backend = trash.unlockingLocked()
        let protections = protections
        // What the deeper search found is checked again by its own rules; the rest by the usual ones.
        let loose = Set(leftovers.filter { $0.evidence == .loose }.map(\.path))
        let rest = await Task.detached(priority: .userInitiated) {
            // A leftover kept in Deep Clean or in Projects stays, as it would there.
            job.moveToTrash(leftovers.map(\.path), through: TrashGate(still: { path in
                approved.map {
                    AppLeftovers.isStillLeftover(path, of: app, home: home, installed: $0.installed, identity: $0.identity, deep: loose.contains(path))
                } ?? false
            }, protections: { try protections.read() }), backend: backend)
        }.value

        leftoverProblems = rest.failed.map { SystemProblem(path: $0.path, reason: $0.reason) }

        var systemReport = RemovalReport()
        var systemError: String?
        var systemKept: [String] = []
        if !chosenSystem.isEmpty, let id = app.bundleID {
            // What System Clean's keep list protects is never sent to the
            // tool; a list that can't be read stops the system part whole.
            let keeps = await Task.detached(priority: .userInitiated) { try? protections.readSystem() }.value
            if let keeps {
                let paths = chosenSystem.map(\.path)
                systemKept = paths.filter(keeps)
                let going = paths.filter { !keeps($0) }
                if !going.isEmpty {
                    do {
                        systemReport = try await system.remove(going, id, approved?.systemIDs ?? [])
                        job.record(.deleteForGood, done: systemReport.removed, failed: systemReport.failed, refused: systemReport.refused)
                    } catch {
                        systemError = Problem(.uninstall, error).description
                    }
                }
            } else {
                systemError = String(localized: "System Clean's keep list couldn't be read, so nothing system-wide was removed.")
            }
        }
        let systemFailed = systemError == nil
            ? systemReport.failed.count + systemReport.refused.count + systemKept.count : chosenSystem.count
        // Each one that stayed, with why and, when removal stopped part-way, where what's left is now.
        systemProblems = systemError.map { e in chosenSystem.map { SystemProblem(path: $0.path, reason: e) } }
            ?? (systemReport.failed.sorted { $0.key < $1.key }.map { SystemProblem(path: $0.key, reason: $0.value) }
                + systemReport.refused.map { SystemProblem(path: $0, reason: String(localized: "Refused by the rules.")) }
                + systemKept.map { SystemProblem(path: $0, reason: String(localized: "On System Clean's keep list.")) })

        apps.removeAll { $0.path == app.path }
        let moved = Set(rest.moved.map(\.original.path))
        let bytes = app.bytes + leftovers.filter { moved.contains($0.path) }.reduce(0) { $0 + $1.bytes } + systemReport.bytes
        // System parts are deleted for good and kept apart: no Undo brings them back.
        let record = CleanupRecord(
            source: "Uninstall", items: 1 + rest.moved.count, bytes: bytes,
            failed: rest.failed.count + systemFailed, deleted: systemReport.removed.count)
        // Writing our own history after its folder moved would recreate it.
        if !itself { CleanupLog.submit(record, to: logURL) }
        if itself { loadAfterUninstall = false }
        shelf.add(Run(
            id: record.id, records: [appRecord] + rest.moved, app: app, deleted: systemReport.removed.count,
            sizes: Dictionary(
                [(app.path, app.bytes)] + leftovers.filter { moved.contains($0.path) }.map { ($0.path, $0.bytes) },
                uniquingKeysWith: { a, _ in a })))
        var text = rest.moved.isEmpty
            ? String(localized: "Moved \(app.name) (\(fmt(bytes))) to the Trash")
            : String(localized: "Moved \(app.name) and \(rest.moved.count) leftover\(rest.moved.count == 1 ? "" : "s") (\(fmt(bytes))) to the Trash")
        if !rest.failed.isEmpty { text += String(localized: " · \(rest.failed.count) couldn't be moved") }
        let deleted = systemReport.removed.count
        if deleted > 0 { text += String(localized: " · \(deleted) system item\(deleted == 1 ? "" : "s") deleted for good") }
        if systemFailed > 0 { text += String(localized: " · \(systemFailed) system item\(systemFailed == 1 ? "" : "s") stayed") }
        show(Notice(text: text, canUndo: true))
        return .done
    }

    /// Resets `app`: the chosen leftovers (settings, caches, data) go to the
    /// Trash and the app stays, so it starts over as on its first launch.
    /// Refused while it runs; each leftover is checked again first, as for
    /// an uninstall, and Undo puts them back.
    func reset(_ app: AppBundle, leftovers: [Leftover]) async -> Result {
        await moveLeftovers(of: app, leftovers: leftovers, removed: nil)
    }

    func cleanRemovedApp(_ removed: RemovedApp, leftovers: [Leftover]) async -> Result {
        await moveLeftovers(of: removed.app, leftovers: leftovers, removed: removed)
    }

    private func moveLeftovers(of app: AppBundle, leftovers: [Leftover], removed: RemovedApp?) async -> Result {
        guard !uninstalling else { return .refused(String(localized: "Another uninstall is running.")) }
        beginUninstall()
        defer {
            uninstalling = false
            startLoadAfterUninstall()
        }
        // An app that's part of macOS may be reset too: only its caches,
        // parts and settings are found and allowed (`AppLeftovers.mayOffer`).
        if isRunning(app) { return .refused(String(localized: "\(app.name) is open. Quit it first.")) }
        var named = Set<String>()
        let leftovers = leftovers.filter { named.insert($0.path).inserted }
        guard !leftovers.isEmpty else {
            return .refused(removed == nil ? String(localized: "Choose what to reset.") : String(localized: "Choose at least one leftover."))
        }
        let jobs = jobs
        let job = await jobs.begin(.moveToTrash)
        defer { jobs.end(job) }
        if job.isStopped { return .refused(String(localized: "Stopped before anything was moved.")) }
        // Its turn may have come later: it must still be closed.
        if isRunning(app) { return .refused(String(localized: "\(app.name) is open. Quit it first.")) }
        let home = home
        if let removed {
            let current = await Task.detached(priority: .userInitiated) { removed.isCurrent(home: home) }.value
            guard current else {
                return .refused(String(localized: "The app in the Trash changed or was restored. Choose it again before cleaning its leftovers."))
            }
        }
        guard let approved = await ownership(of: app) else {
            return .refused(removed == nil
                ? String(localized: "Ownership of \(app.name)'s leftovers couldn't be verified, so nothing was reset.")
                : String(localized: "Ownership of \(app.name)'s leftovers couldn't be verified, so nothing was moved."))
        }
        if job.isStopped { return .refused(String(localized: "Stopped before anything was moved.")) }
        guard await Task.detached(priority: .userInitiated, operation: { Self.isSameApp(app.path, as: app) }).value else {
            return .refused(String(localized: "\(app.name) changed since the list was made. Reload and try again."))
        }
        if job.isStopped { return .refused(String(localized: "Stopped before anything was moved.")) }
        if isRunning(app) { return .refused(String(localized: "\(app.name) is open. Quit it first.")) }
        let (backend, protections) = (trash.unlockingLocked(), protections)
        let loose = Set(leftovers.filter { $0.evidence == .loose }.map(\.path))
        let rest = await Task.detached(priority: .userInitiated) {
            job.moveToTrash(leftovers.map(\.path), through: TrashGate(still: { path in
                (removed?.isCurrent(home: home) ?? true)
                    && AppLeftovers.isStillLeftover(path, of: app, home: home, installed: approved.installed, identity: approved.identity, deep: loose.contains(path))
            }, protections: { try protections.read() }), backend: backend)
        }.value
        let moved = Set(rest.moved.map(\.original.path))
        let gone = leftovers.filter { moved.contains($0.path) }
        let bytes = gone.reduce(0) { $0 + $1.bytes }
        let record = CleanupRecord(source: removed == nil ? Self.resetSource : OrphansModel.source, items: gone.count, bytes: bytes, failed: rest.failed.count)
        CleanupLog.submit(record, to: logURL)
        guard !rest.moved.isEmpty else {
            let reason = rest.failed.first?.reason
            return .failed(removed == nil
                ? reason.map { String(localized: "Nothing was reset: \($0)") } ?? String(localized: "Nothing was reset.")
                : reason.map { String(localized: "Nothing was moved: \($0)") } ?? String(localized: "Nothing was moved."))
        }
        shelf.add(Run(
            id: record.id, records: rest.moved, app: nil, deleted: 0,
            sizes: Dictionary(gone.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a })))
        var text = removed == nil
            ? String(localized: "Reset \(app.name): moved \(gone.count) item\(gone.count == 1 ? "" : "s") (\(fmt(bytes))) to the Trash")
            : String(localized: "Moved \(gone.count) leftover\(gone.count == 1 ? "" : "s") of \(app.name) (\(fmt(bytes))) to the Trash")
        if !rest.failed.isEmpty { text += String(localized: " · \(rest.failed.count) couldn't be moved") }
        show(Notice(text: text, canUndo: true))
        return .done
    }

    /// The history's name for a reset.
    static let resetSource = "Reset"

    /// Why `app` can't go to the Trash as it is now, or nil: it must still
    /// be the app that was listed, outside the protected locations, and not
    /// kept in another pane, with the keep lists readable.
    private func refusal(for app: AppBundle) async -> String? {
        let protections = protections
        let cleared = await Task.detached(priority: .userInitiated) {
            Trasher.clear([app.path], through: TrashGate(still: { Self.isSameApp($0, as: app) }, protections: { try protections.read() }))
        }.value
        guard let why = cleared.refused.first?.reason else { return nil }
        switch why {
        case "Protected location": return String(localized: "\(app.name) is in a protected location.")
        case "Kept": return String(localized: "\(app.name) is on one of your keep lists, or holds something that is, so it stays.")
        case Trasher.protectionsUnreadable: return String(localized: "Your keep lists couldn't be read, so nothing was moved.")
        default: return String(localized: "\(app.name) changed since the list was made. Reload and try again.")
        }
    }

    /// Puts an uninstall back, off the main thread: the one of history
    /// record `id`, or the latest.
    func undoUninstall(run id: UUID? = nil) {
        guard !uninstalling else { return }
        target = id ?? shelf.latest?.id
        guard target.flatMap(shelf.run) != nil, !undoRecords.isEmpty else {
            target = nil
            return
        }
        let run = target
        beginUninstall()
        undoJob = Task {
            if let run { _ = await putBack(run, announce: true) }
            uninstalling = false
            startLoadAfterUninstall()
        }
    }

    /// Puts back what's left of run `id`, while `uninstalling` is held;
    /// how many came back and how many didn't.
    private func putBack(_ id: UUID, announce: Bool) async -> (restored: Int, failed: Int) {
        target = id
        defer { target = nil }
        let records = undoRecords
        guard !records.isEmpty else { return (0, 0) }
        let failed = await jobs.perform(.putBack) { $0.putBack(records) }
        return applyUndo(failed, announce: announce)
    }

    /// A listing asked for while an uninstall or Undo ran.
    private var loadAfterUninstall = false

    private func startLoadAfterUninstall() {
        guard loadAfterUninstall else { return }
        loadAfterUninstall = false
        load()
    }

    @discardableResult
    private func applyUndo(_ failed: [TrashRecord], announce: Bool = true) -> (restored: Int, failed: Int) {
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
            ? String(localized: "Restored \(restored) item\(restored == 1 ? "" : "s")")
            : String(localized: "Restored \(restored); \(failed.count) couldn't be put back. Undo tries those again, or use Put Back in the Trash.")
        if undoDeleted > 0 { text += String(localized: " System items deleted for good stay deleted.") }
        // What couldn't come back stays ready for another try.
        undoRecords = failed
        if !failedPaths.contains(undoApp?.path ?? "") { undoApp = nil }
        if failed.isEmpty, let id = undone?.id { shelf.remove(id) }
        if announce { show(Notice(text: text, canUndo: !failed.isEmpty)) }
        return (restored, failed.count)
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
            try? await Task.sleep(for: .seconds(5))
            guard notice == n else { return }
            withAnimation(Motion.snappy) { notice = undoRecords.isEmpty ? nil : undoNotice }
        }
    }

    func dismissNotice() { withAnimation(Motion.snappy) { notice = nil } }

    // MARK: Dropped apps

    /// An app opened from a mounted disk image: it can't be moved off the
    /// image, so the image file goes once ejected. `image` is nil when the
    /// image file couldn't be looked up.
    struct ImageApp: Identifiable, Equatable {
        let app: AppBundle
        let mountPoint: String
        let image: MountedImage?
        var id: String { app.path }
    }

    /// Apps dropped on the pane or on MyMole's icon, for the pane to open.
    var dropped: [AppBundle] = []
    /// A dropped app that runs from a disk image, for the pane to open.
    var droppedImage: ImageApp?
    private(set) var dropJob: Task<Void, Never>?

    /// Reads the apps among `urls`; the listed copy is used when the app is
    /// in the list. Apps on a disk image are offered as their image; other
    /// files are left out with a word why.
    func open(_ urls: [URL]) {
        let paths = urls.filter(\.isFileURL).map { $0.standardizedFileURL.path }
        let apps = paths.filter { $0.lowercased().hasSuffix(".app") }
        guard !apps.isEmpty else {
            show(Notice(text: String(localized: "Drop an app here to uninstall it."), canUndo: false))
            return
        }
        let listed = self.apps
        let imageOf = imageOf
        dropJob = Task {
            let read = await Task.detached(priority: .userInitiated) {
                apps.map { p -> (path: String, app: AppBundle?, image: MountedImage?) in
                    let app = listed.first { $0.path == p } ?? AppFinder.read(p)
                    return (p, app, p.hasPrefix("/Volumes/") ? imageOf(p) : nil)
                }
            }.value
            let unread = read.filter { $0.app == nil }.count
            let onImage = read.compactMap { r in r.app.flatMap { a in r.image.map { ImageApp(app: a, mountPoint: $0.mountPoint, image: $0) } } }
            let plain = read.filter { $0.image == nil }.compactMap(\.app)
            if !plain.isEmpty {
                dropped = plain
            } else if let first = onImage.first {
                droppedImage = first
            }
            if unread > 0 {
                show(Notice(text: String(localized: "\(unread) of the dropped items isn't an app MyMole can read."), canUndo: false))
            }
        }
    }

    /// Ejects the image `item` runs from and moves its file to the Trash,
    /// where Undo can put it back. Within the move's turn, before anything
    /// is ejected, the app must be closed and the image file still one that
    /// may go and isn't kept; the eject runs off the main thread.
    func removeImage(_ item: ImageApp) async -> Result {
        guard !uninstalling else { return .refused(String(localized: "Another uninstall is running.")) }
        guard let image = item.image else { return .refused(String(localized: "The disk image file couldn't be found.")) }
        beginUninstall()
        defer {
            uninstalling = false
            startLoadAfterUninstall()
        }
        let (home, backend, protections, eject, jobs) = (home, trash.unlockingLocked(), protections, eject, jobs)
        let gate = TrashGate(still: { DiskImages.mayGo($0, home: home) }, protections: { try protections.read() })
        let job = await jobs.begin(.moveToTrash)
        defer { jobs.end(job) }
        if job.isStopped { return .refused(String(localized: "Stopped before anything was moved.")) }
        if isRunning(item.app) { return .refused(String(localized: "\(item.app.name) is open. Quit it first.")) }
        let cleared = await Task.detached(priority: .userInitiated) { Trasher.clear([image.image], through: gate) }.value
        if let why = cleared.refused.first?.reason {
            let text: String = switch why {
            case "Kept": String(localized: "\(image.name) is on one of your keep lists, so it stays.")
            case Trasher.protectionsUnreadable: String(localized: "Your keep lists couldn't be read, so nothing was moved.")
            default: String(localized: "\(image.name) isn't a disk image MyMole can move.")
            }
            return .refused(text)
        }
        if let why = await Task.detached(priority: .userInitiated, operation: { eject(item.mountPoint) }).value {
            return .failed(String(localized: "\(image.name) couldn't be ejected: \(why)"))
        }
        let bytes = AppLeftovers.measure(image.image) ?? 0
        let outcome = await Task.detached(priority: .userInitiated) {
            job.moveToTrash([image.image], through: gate, backend: backend)
        }.value
        let record = CleanupRecord(source: "Uninstall", items: outcome.moved.count, bytes: outcome.moved.isEmpty ? 0 : bytes, failed: outcome.failed.count)
        CleanupLog.submit(record, to: logURL)
        guard !outcome.moved.isEmpty else {
            return .failed(outcome.failed.first.map { String(localized: "\(image.name) was ejected but not moved: \($0.reason)") }
                ?? String(localized: "\(image.name) was ejected but not moved."))
        }
        shelf.add(Run(id: record.id, records: outcome.moved, app: nil, deleted: 0, sizes: [image.image: bytes]))
        show(Notice(text: String(localized: "Ejected \(image.name) and moved it (\(fmt(bytes))) to the Trash"), canUndo: true))
        return .done
    }

    nonisolated static func liveEject(_ mountPoint: String) -> String? {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: mountPoint))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Several apps at once

    /// One app of a batch, with the leftovers chosen for it.
    struct BatchItem {
        let app: AppBundle
        let leftovers: [Leftover]
    }

    /// The history records of the last batch, which the notice's Undo puts back together.
    private var lastBatch: [UUID] = []

    /// Uninstalls each app in turn, as one at a time would, each with its
    /// own history record. What one can't (open, its own uninstaller, kept)
    /// stays, and the reasons are returned by app name.
    func uninstall(batch: [BatchItem]) async -> [(name: String, reason: String)] {
        var problems: [(name: String, reason: String)] = []
        var runs: [UUID] = []
        var apps = 0, items = 0
        var bytes: Int64 = 0
        for item in batch {
            if isSelf(item.app) {
                problems.append((item.app.name, String(localized: "Uninstall MyMole on its own from Settings.")))
                continue
            }
            switch await uninstall(item.app, leftovers: item.leftovers) {
            case .done:
                if let run = shelf.latest {
                    runs.append(run.id)
                    apps += 1
                    items += run.records.count - 1
                    bytes += run.sizes.values.reduce(0, +)
                }
            case .refused(let why), .failed(let why):
                problems.append((item.app.name, why))
            }
        }
        lastBatch = runs
        guard !runs.isEmpty else { return problems }
        var text = String(localized: "Moved \(apps) app\(apps == 1 ? "" : "s") and \(items) leftover\(items == 1 ? "" : "s") (\(fmt(bytes))) to the Trash")
        if !problems.isEmpty { text += String(localized: " · \(problems.count) stayed") }
        show(Notice(text: text, canUndo: true))
        return problems
    }

    /// Undo for the notice: the whole last batch when it was one, else the latest move.
    func undoLatest() {
        let batch = lastBatch.filter { shelf.run($0) != nil }
        lastBatch = []
        guard batch.count > 1 else {
            undoUninstall()
            return
        }
        guard !uninstalling else { return }
        beginUninstall()
        undoJob = Task {
            var restored = 0, failed = 0
            for id in batch.reversed() {
                let r = await putBack(id, announce: false)
                restored += r.restored
                failed += r.failed
            }
            uninstalling = false
            show(Notice(
                text: failed == 0
                    ? String(localized: "Restored \(batch.count) apps and their leftovers (\(restored) items)")
                    : String(localized: "Restored \(restored); \(failed) couldn't be put back. Undo tries those again, or use Put Back in the Trash."),
                canUndo: failed > 0))
            startLoadAfterUninstall()
        }
    }

    // MARK: Live system

    /// Still the same app at `path`: a real folder, not a link, with the
    /// bundle ID it was listed with.
    nonisolated static func isSameApp(_ path: String, as app: AppBundle) -> Bool {
        var st = stat()
        guard path == app.path, lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return false }
        guard let id = AppIdentity.bundleInfo(atPath: path)?["CFBundleIdentifier"] as? String else { return false }
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
            let failed = urls.filter { map[$0] == nil }.map { (path: $0.path, reason: String(localized: "Not moved")) }
            return TrashOutcome(moved: moved, failed: failed)
        } catch {
            return TrashOutcome(moved: [], failed: paths.map { (path: $0, reason: error.localizedDescription) })
        }
    }
}

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
