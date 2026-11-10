import AppKit
#if SMOKE
import PrivilegedKit
#endif
import StorageKit
import SwiftUI
import SystemKit

enum Pane: String, CaseIterable, Identifiable {
    case dashboard, clean, systemClean, uninstall, optimize, projects, installer
    case diskMap, status, history
    // Added after the panes that have ⌘1 to ⌘9, so those keep their numbers.
    case startup, duplicates
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: String(localized: "Dashboard")
        case .clean: String(localized: "Deep Clean")
        case .systemClean: String(localized: "System Clean")
        case .uninstall: String(localized: "Uninstall")
        case .optimize: String(localized: "Optimize")
        case .projects: String(localized: "Projects")
        case .installer: String(localized: "Installers")
        case .diskMap: String(localized: "Disk Map")
        case .status: String(localized: "Live Status")
        case .history: String(localized: "History")
        case .startup: String(localized: "Startup Items")
        case .duplicates: String(localized: "Duplicates")
        case .settings: String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .clean: "sparkles"
        case .systemClean: "lock.shield"
        case .uninstall: "trash"
        case .optimize: "bolt"
        case .projects: "flame"
        case .installer: "opticaldisc"
        case .diskMap: "chart.pie"
        case .status: "waveform.path.ecg"
        case .history: "clock.arrow.circlepath"
        case .startup: "power"
        case .duplicates: "doc.on.doc"
        case .settings: "gearshape"
        }
    }

    /// Panes that walk the disk. Without Full Disk Access each protected
    /// folder or app container they touch raises its own macOS privacy
    /// prompt, so they stay behind the one-time access step. System Clean
    /// reads system folders, which need no access of their own.
    var needsDiskAccess: Bool {
        switch self {
        case .clean, .uninstall, .optimize, .projects, .installer, .diskMap, .startup, .duplicates: true
        default: false
        }
    }

    /// System Clean is only in the edition that can ask for root.
    static let groups: [(String, [Pane])] = [
        (String(localized: "Cleanup"), [.dashboard, .clean, .systemClean, .uninstall, .startup, .optimize, .projects, .installer, .duplicates]),
        (String(localized: "Insight"), [.diskMap, .status, .history]),
        (String(localized: "More"), [.settings]),
    ].map { ($0.0, $0.1.filter(\.isAvailable)) }

    /// Whether this edition has the pane: the App Store edition has no System Clean.
    var isAvailable: Bool { self != .systemClean || Edition.current.hasSystemTasks }

    /// ⌘1 to ⌘9, the same in both editions; a pane an edition lacks leaves
    /// its number unused rather than moving the others.
    var shortcut: KeyEquivalent? {
        guard let i = Pane.allCases.firstIndex(of: self), i < 9 else { return nil }
        return KeyEquivalent(Character("\(i + 1)"))
    }
}

/// App-wide state: which pane is showing and each module's model (kept here
/// so leaving a pane mid-scan doesn't lose its results).
@MainActor
@Observable
final class AppModel {
    var settingsQuery = ""
    private(set) var leaving = false
    @ObservationIgnored private let selfRemovalAccess = AppBundleAccess()
    @ObservationIgnored lazy var selfRemoval = SelfRemovalModel(apps: apps) { [weak self] in
        guard let self else { return String(localized: "MyMole is closing.") }
        return await self.prepareToRemoveSelf()
    } resume: { [weak self] in
        guard let self else { return }
        self.selfRemovalAccess.release()
        self.apps.selfRemovalURL = nil
        self.leaving = false
        self.startMonitoring()
        self.watch.schedule { [weak self] in await self?.backgroundScan() }
    } quit: { [weak self] in
        self?.selfRemovalAccess.release()
        self?.apps.selfRemovalURL = nil
        NSApp.terminate(nil)
    }
    /// Every way of opening a pane sets this; each change is a visit that
    /// Back returns from, except the moves Back and Forward make themselves.
    var pane: Pane = .dashboard {
        didSet {
            if pane != oldValue && !movingInHistory { history.left(oldValue) }
        }
    }
    private(set) var history = PaneHistory()
    @ObservationIgnored private var movingInHistory = false

    func goBack() {
        if let p = history.goBack(from: pane) { move(to: p) }
    }

    func goForward() {
        if let p = history.goForward(from: pane) { move(to: p) }
    }

    /// Opens `pane` as Back or Forward does, without a new visit.
    private func move(to pane: Pane) {
        movingInHistory = true
        defer { movingInHistory = false }
        self.pane = pane
    }

    /// Bumped by ⌘F; the pane's search field takes the focus.
    var findRequest = 0
    var showPalette = false
    var status: SystemSnapshot? {
        didSet { if let status, status.date != oldValue?.date { statusHistory.add(status) } }
    }
    /// The last readings, kept in memory only, for small graphs.
    private(set) var statusHistory = StatusHistory()
    private let sampler = SystemSampler()
    /// The one model of the running app, for what AppKit hands to the app
    /// rather than to a view: a click on the Dock icon or on a notification.
    @ObservationIgnored static weak var live: AppModel?
    /// Opens the main window; set by the views that can.
    @ObservationIgnored var openWindow: (() -> Void)?
    /// MyMole was opened at login and waits in the menu bar: no window and
    /// no scans until the user opens it.
    @ObservationIgnored var waitsInMenuBar = false
    @ObservationIgnored private var monitor: Task<Void, Never>?
    /// The apps in the Trash at the last look; nil before the first.
    @ObservationIgnored var trashedAppsSeen: Set<String>?
    /// How often the Mac is read while no pane asks more often.
    static let monitorInterval: Duration = .seconds(60)
    /// Every cleanup MyMole ran.
    var cleanups: [CleanupRecord] = []
    /// Read once the folders are open: in the App Sandbox the probe folders
    /// are only reachable through the home folder's bookmark, so a probe
    /// before it is opened always reads as no access.
    let diskAccess = DiskAccessMonitor()
    var fullDiskAccess: Bool { diskAccess.hasResult && diskAccess.state != .denied && access.has(.home) }
    /// When the user last started a Smart Scan, so a module it didn't get
    /// through shows its result as an earlier one.
    var smartScanStarted: Date?
    private(set) var smartScanWaiting = Set<Pane>()
    private(set) var smartScanning = false
    /// What the probe found: granted, refused, or it couldn't tell.
    var diskAccessState: FullDiskAccess.State { diskAccess.state }

    let storage = StorageModel()
    let projects = ProjectsModel()
    let installers = InstallersModel()
    let deepClean = DeepCleanModel()
    let apps: AppsModel
    let trash = TrashModel()
    #if SMOKE
    let startup = StartupModel(root: Home.path + "/System")
    #else
    let startup = StartupModel()
    #endif
    let duplicates = DuplicatesModel()
    let orphans: OrphansModel
    let similar = SimilarModel()
    let watch = Watch()
    let privileged: PrivilegedClient
    /// The folders the App Store edition may work in; all of them in the direct edition.
    let access = FolderAccess()

    /// Scans may start: the home folder is open to MyMole, and Full Disk
    /// Access keeps macOS from asking about every protected folder.
    var canScan: Bool { !leaving && access.has(.home) && fullDiskAccess }

    /// What a pane is waiting for before it can work, if anything.
    func gate(for pane: Pane) -> FolderAccess.Place? {
        guard pane.needsDiskAccess else { return nil }
        if !access.has(.home) { return .home }
        if pane == .uninstall && !access.has(.applications) { return .applications }
        return nil
    }
    let maintenance: MaintenanceModel
    let systemClean: SystemCleanModel

    init() {
        // Folders chosen for a pane before, opened again before any pane reads them.
        ChosenFolders.shared.restore()
        #if SMOKE
        let privileged = PrivilegedClient(toolPath: Home.path + "/SyntheticHelper", toolRunning: { false })
        #else
        let privileged = PrivilegedClient()
        #endif
        self.privileged = privileged
        let knownCopies = KnownAppCopies()
        #if SMOKE
        let appSystem = AppsModel.SystemSide(base: Home.path + "/System", isReady: { false }, remove: { _, _, _ in .init() })
        let copies: @Sendable (AppBundle) -> [AppBundle]? = { _ in [] }
        let runtime = [RuntimeLeftovers.Root(path: Home.path + "/Runtime/Caches", kind: .caches), .init(path: Home.path + "/Runtime/Temp", kind: .temporary)]
        #else
        let appSystem: AppsModel.SystemSide = Edition.current.hasSystemTasks ? .live(privileged) : .unavailable
        let copies: @Sendable (AppBundle) -> [AppBundle]? = AppsModel.liveOtherCopies
        let runtime = Edition.current.isSandboxed ? [] : RuntimeLeftovers.systemRoots()
        #endif
        apps = AppsModel(otherCopies: copies, system: appSystem, knownCopies: knownCopies, runtimeRoots: runtime)
        #if SMOKE
        orphans = OrphansModel(known: { _ in false }, running: { RunningAppSnapshot.read().bundleIDs }, knownCopies: knownCopies)
        maintenance = MaintenanceModel(privileged: privileged, engine: MaintenanceEngine(role: .user, running: { [] }, protections: { try UserProtections.live.read() }))
        #else
        orphans = OrphansModel(knownCopies: knownCopies)
        maintenance = MaintenanceModel(privileged: privileged)
        #endif
        #if SMOKE
        let syntheticSystem = Home.path + "/System/Library"
        systemClean = SystemCleanModel(privileged: privileged, backend: .init(
            isReady: { true }, scan: { progress in
                await Task.detached {
                    SystemCleanRules.list(roots: [.init(path: syntheticSystem + "/Caches", reason: "Synthetic system cache"),
                                                 .init(path: syntheticSystem + "/Logs", reason: "Synthetic system log")], progress: progress)
                }.value
            }, remove: { paths, _ in
                var report = RemovalReport()
                for path in paths { report.failed[path] = "System removal is simulated in this test build." }
                return report
            }))
        systemClean.lookForStaging = { [] }
        #else
        systemClean = SystemCleanModel(privileged: privileged)
        #endif
        diskAccess.didChange = { [weak self] in self?.prefetchScans() }
        recheckDiskAccess()
    }

    /// Keeps a slow reading going for as long as the app runs, for the menu
    /// bar item. A reading costs a few milliseconds.
    func startMonitoring() {
        guard monitor == nil, !leaving else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                if let self {
                    // A change of the schedule in Settings is picked up here too.
                    watch.schedule { [weak self] in await self?.backgroundScan() }
                    await watch.check(status?.startupVolume, finds: finds)
                    await checkTrashedApps()
                    await watch.observe(status?.topProcesses ?? [])
                }
                try? await Task.sleep(for: Self.paced(Self.monitorInterval))
            }
        }
    }

    /// Takes a reading off the main thread. The Dashboard, Live Status, the
    /// menu bar panel and the monitor all ask: a request while a reading
    /// runs waits for that one, and one within `maxAge` of the last reading
    /// uses it, so the number of readings doesn't grow with the number of
    /// places showing them. An older reading never replaces a newer one.
    func refreshStatus(maxAge: TimeInterval = AppModel.statusFreshFor) async {
        let fresh = statusReading.count
        let s = await statusReading.value(maxAge: maxAge)
        if s.date > status?.date ?? .distantPast { status = s }
        // The Trash is read along with a new reading, not with a shared one.
        // It's closed to an app without Full Disk Access.
        if statusReading.count > fresh, fullDiskAccess { await trash.refresh() }
    }

    @ObservationIgnored private lazy var statusReading = SharedReading { [sampler] in sampler.sample() }
    /// A reading this recent serves every place that asks.
    nonisolated static let statusFreshFor: TimeInterval = 1

    /// How long a view waits between readings: twice as long in Low Power Mode.
    nonisolated static func paced(_ interval: Duration) -> Duration {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? interval * 2 : interval
    }

    /// Probed off the main thread: the probe reads protected folders, which
    /// can be slow on a busy disk.
    func recheckDiskAccess() {
        diskAccess.request(scope: !leaving && access.has(.home) ? access.generation : nil)
    }

    private var prewarmed = false
    /// Pause between the scans and the disk map walk, so the disk isn't
    /// shared by two walks of the same folders.
    static let diskMapDelay: Duration = .seconds(3)

    /// Gets every pane ready in the background, in stages rather than all at
    /// once, so launch never has every scanner competing for the disk. Saved
    /// results are on screen already; this runs once per launch: Projects
    /// (unless fresh), Installers, Deep Clean, the app list, then the disk
    /// map with fewer threads.
    func prefetchScans() {
        guard canScan, !prewarmed, !waitsInMenuBar, LoadingSettings.prefetch() else { return }
        prewarmed = true
        let access = stepsAllowed()
        // Turned off in Settings meanwhile: no step starts after that; one
        // already running finishes. A step's own threads follow the
        // performance level as it is when that step starts.
        let allowed: @MainActor () -> Bool = { access() && LoadingSettings.prefetch() }
        prefetchChain = Task {
            await Self.run([
                // Reads only, and quickly: Optimize opens with its findings.
                { [self] in maintenance.check() },
                { [self] in
                    // Whether it's needed depends on the saved result.
                    await projects.restoreJob?.value
                    projects.scanIfNeeded(background: true)
                    await projects.scanJob?.value
                },
                { [self] in
                    installers.scan(background: true)
                    await installers.scanJob?.value
                },
                { [self] in
                    deepClean.scan(background: true)
                    await deepClean.scanJob?.value
                },
                { [self] in
                    if apps.apps.isEmpty || apps.isStale {
                        apps.load(background: true)
                        await apps.loadJob?.value
                    }
                },
                { try? await Task.sleep(for: Self.diskMapDelay) },
                { [self] in storage.prewarm(path: Home.path) },
            ], while: allowed, waitingWhile: { [weak self] in self?.anyScanRunning ?? false })
        }
    }

    /// Launch preparation and staged Smart Scan jobs. Taking back folder
    /// access stops a chain before its next step starts.
    private var prefetchChain: Task<Void, Never>?
    private var scanChain: Task<Void, Never>?
    private var scanChainID: UUID?

    /// Whether the next step of a chain started now may still run: not once
    /// folder access has changed, or scanning isn't allowed any more.
    private func stepsAllowed() -> @MainActor () -> Bool {
        let generation = access.generation
        return { [weak self] in
            guard let self, !Task.isCancelled else { return false }
            return access.generation == generation && canScan
        }
    }

    /// Runs `steps` in order, each only while `allowed` still says so, and
    /// each only once `busy` is false: a scan the user started goes first,
    /// and the background never adds a second heavy walk to it.
    static func run(
        _ steps: [@MainActor () async -> Void], while allowed: @MainActor () -> Bool,
        waitingWhile busy: @MainActor () -> Bool = { false }
    ) async {
        for step in steps {
            while busy() && allowed() { try? await Task.sleep(for: .milliseconds(200)) }
            guard allowed() else { return }
            await step()
        }
    }

    /// A walk of the disk is running: a scan, a listing or the disk map.
    var anyScanRunning: Bool {
        deepClean.scanning || installers.scanning || projects.scanning || apps.loading || storage.scanning || duplicates.scanning
            || orphans.loading || similar.scanning
    }

    /// Why a folder can't be taken back now: something is being moved to
    /// the Trash or uninstalled, and must finish with the access it began with.
    var takeBackBlocker: String? {
        deepClean.trashing || installers.trashing || projects.trashing || apps.uninstalling || storage.trashing || startup.trashing
            || duplicates.trashing || orphans.trashing || similar.trashing
            ? String(localized: "Wait for the move to the Trash to finish.") : nil
    }

    /// Takes back access to `place` at a safe point: no step of a background
    /// chain starts after this, running scans are stopped and waited for,
    /// and only then is the folder closed, so nothing reads it, or shows
    /// what it read, afterwards.
    func takeBack(_ place: FolderAccess.Place) async {
        guard takeBackBlocker == nil else { return }
        prefetchChain?.cancel()
        cancelSmartScanChain()
        await Self.settle(
            stop: { [self] in
                deepClean.stop()
                installers.stop()
                projects.stop()
                apps.stop()
                orphans.stop()
                storage.cancelScan()
                duplicates.stop()
                similar.stop()
            },
            wait: { [self] in
                await deepClean.scanJob?.value
                await installers.scanJob?.value
                await projects.scanJob?.value
                await apps.loadJob?.value
                await storage.scanJob?.value
                await duplicates.scanJob?.value
                if orphans.loading { await orphans.job?.value }
                await similar.scanJob?.value
            },
            while: { [self] in anyScanRunning })
        // Nothing waits between the last look at the scans and here, so
        // none can have started since.
        guard takeBackBlocker == nil else { return }
        access.revoke(place)
        // Given back later, the background scans run again.
        prewarmed = false
    }

    /// Stops what's running and waits for it, again for as long as `busy`
    /// says something runs: a scan the user starts during the wait is
    /// stopped too, and one that ended is waited for until it has said so.
    /// Returns right after `busy` was last false, with no wait in between.
    static func settle(
        stop: @MainActor () -> Void, wait: @MainActor () async -> Void, while busy: @MainActor () -> Bool
    ) async {
        repeat {
            stop()
            await wait()
            // A walk that just ended reports on the main thread a moment later.
            if busy() { try? await Task.sleep(for: .milliseconds(20)) }
        } while busy()
    }

    private func prepareToRemoveSelf() async -> String? {
        guard !deepClean.trashing, !installers.trashing, !projects.trashing, !storage.trashing,
              !startup.trashing, !duplicates.trashing, !orphans.trashing, !similar.trashing,
              !systemClean.removing, maintenance.phase == .idle, !trash.emptying else {
            return String(localized: "Wait for the current move or maintenance task to finish.")
        }
        if Edition.current.isSandboxed {
            guard let path = apps.ownAppPath, selfRemovalAccess.acquire(path: path) else {
                return String(localized: "Choose this copy of MyMole to allow uninstalling it. Nothing was moved.")
            }
            apps.selfRemovalURL = selfRemovalAccess.url
        }
        leaving = true
        prefetchChain?.cancel()
        cancelSmartScanChain()
        let monitoring = monitor
        monitor?.cancel()
        monitor = nil
        watch.pause()
        await monitoring?.value
        watch.pause()
        await Self.settle(stop: { [self] in
            deepClean.stop(); installers.stop(); projects.stop(); apps.stop()
            storage.cancelScan(); duplicates.stop(); similar.stop(); orphans.stop()
            systemClean.stopScan(); startup.stop()
        }, wait: { [self] in
            await deepClean.scanJob?.value
            await installers.scanJob?.value
            await projects.scanJob?.value
            await apps.loadJob?.value
            await storage.scanJob?.value
            await duplicates.scanJob?.value
            await orphans.job?.value
            await similar.scanJob?.value
            await systemClean.scanJob?.value
            if startup.loading { await startup.job?.value }
        }, while: { [self] in anyScanRunning || systemClean.scanning || startup.loading })
        await Task.detached(priority: .userInitiated) {
            StoreWrites.flush()
            CleanupLog.flush()
        }.value
        if LoginItem.state == .on || LoginItem.state == .needsApproval { return LoginItem.set(false) }
        return nil
    }

    /// Metadata and quick checks first, cleanup walks next, duplicate
    /// comparison last. Lower performance levels serialize cleanup walks.
    func scanAll(background: Bool = false) {
        // Checked here, not by callers: every module reads protected
        // folders, and a scan without access would report a partial Mac.
        guard canScan else { return }
        guard !smartScanning else { return }
        let requestedAt = Date()
        if !background { smartScanStarted = requestedAt }
        prefetchChain?.cancel()
        let allowed = stepsAllowed()
        let together = PerformanceLevel.current().runsScansTogether
        let id = UUID()
        scanChainID = id
        smartScanning = true
        smartScanWaiting = Set(smartScanModules)
        var jobs: [Pane: SmartScanPipeline.Job] = [
            .optimize: .init(start: { [self] in maintenance.check() }, wait: { [self] in
                while maintenance.phase == .checking && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }),
            .uninstall: .init(start: { [self] in
                if !apps.loading { apps.load(background: background) }
            }, wait: { [self] in await apps.loadJob?.value }),
            .installer: .init(start: { [self] in
                if !installers.scanning { installers.scan(background: background) }
            }, wait: { [self] in await installers.scanJob?.value }),
            .clean: .init(start: { [self] in
                if !deepClean.scanning { deepClean.scan(background: background) }
            }, wait: { [self] in await deepClean.scanJob?.value }),
            .duplicates: .init(start: { [self] in
                if !duplicates.scanning, duplicates.scannedAt.map({ $0 < requestedAt }) ?? true {
                    duplicates.scan(background: background)
                }
            }, wait: { [self] in await duplicates.scanJob?.value }),
        ]
        if smartScanModules.contains(.systemClean) {
            jobs[.systemClean] = .init(start: { [self] in
                if !systemClean.scanning { systemClean.scan() }
            }, wait: { [self] in await systemClean.scanJob?.value })
        }
        let pipeline = SmartScanPipeline(jobs: jobs)
        scanChain = Task { [self] in
            defer {
                if scanChainID == id {
                    smartScanWaiting = []
                    smartScanning = false
                    scanChainID = nil
                }
            }
            await pipeline.run(together: together, allowed: allowed) { [self] pane in
                if scanChainID == id { smartScanWaiting.remove(pane) }
            }
        }
    }

    private func cancelSmartScanChain() {
        scanChain?.cancel()
        scanChainID = nil
        smartScanWaiting = []
        smartScanning = false
    }

    func stopSmartScan() {
        cancelSmartScanChain()
        deepClean.stop(); installers.stop(); apps.stop(); duplicates.stop(); systemClean.stopScan()
    }

    func refreshHistory() async {
        cleanups = await Task.detached(priority: .utility) { CleanupLog.load() }.value
    }

    /// Undo for a run whose items can still be put back, from the pane that
    /// moved them, so a notice that has gone never takes Undo with it.
    /// Returns once the Undo has finished and the history is read again.
    func undo(for record: CleanupRecord) -> (() async -> Void)? {
        // Any move of this session that can still be put back, not only the last.
        let id = record.id
        let run: (() -> Void, () -> Bool)?
        if deepClean.canUndo(run: id) {
            run = ({ self.deepClean.undoTrash(run: id) }, { self.deepClean.trashing })
        } else if installers.canUndo(run: id) {
            run = ({ self.installers.undoTrash(run: id) }, { self.installers.trashing })
        } else if projects.canUndo(run: id) {
            run = ({ self.projects.undoTrash(run: id) }, { self.projects.trashing })
        } else if storage.canUndo(run: id) {
            run = ({ self.storage.undoTrash(run: id) }, { self.storage.trashing })
        } else if apps.canUndo(run: id) {
            run = ({ self.apps.undoUninstall(run: id) }, { self.apps.uninstalling })
        } else if startup.canUndo(run: id) {
            run = ({ self.startup.undoTrash(run: id) }, { self.startup.trashing })
        } else if duplicates.canUndo(run: id) {
            run = ({ self.duplicates.undoTrash(run: id) }, { self.duplicates.trashing })
        } else if orphans.canUndo(run: id) {
            run = ({ self.orphans.undoTrash(run: id) }, { self.orphans.trashing })
        } else if similar.canUndo(run: id) {
            run = ({ self.similar.undoTrash(run: id) }, { self.similar.trashing })
        } else {
            run = nil
        }
        guard let (start, busy) = run else { return nil }
        return {
            start()
            while busy() { try? await Task.sleep(for: .milliseconds(50)) }
            await Task.detached(priority: .utility) { CleanupLog.flush() }.value
            await self.refreshHistory()
        }
    }

    /// The short result shown next to a pane in the sidebar and on the
    /// dashboard: what a scan found.
    func badge(for pane: Pane) -> String? {
        let bytes = found(pane)
        if bytes > 0 { return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        if pane == .optimize, maintenance.willChange > 0 { return "\(maintenance.willChange)" }
        return nil
    }

    /// The most recent cleanup that really removed files, for the dashboard.
    var lastCleanup: CleanupRecord? {
        cleanups.first { $0.freedSomething && $0.freedBytes > 0 }
    }
}
