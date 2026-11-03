import AppKit
import StorageKit
import SwiftUI
import SystemKit

enum Pane: String, CaseIterable, Identifiable {
    case dashboard, clean, systemClean, uninstall, optimize, projects, installer
    case diskMap, status, history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .clean: "Deep Clean"
        case .systemClean: "System Clean"
        case .uninstall: "Uninstall"
        case .optimize: "Optimize"
        case .projects: "Projects"
        case .installer: "Installers"
        case .diskMap: "Disk Map"
        case .status: "Live Status"
        case .history: "History"
        case .settings: "Settings"
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
        case .settings: "gearshape"
        }
    }

    /// Panes that walk the disk. Without Full Disk Access each protected
    /// folder or app container they touch raises its own macOS privacy
    /// prompt, so they stay behind the one-time access step. System Clean
    /// reads system folders, which need no access of their own.
    var needsDiskAccess: Bool {
        switch self {
        case .clean, .uninstall, .optimize, .projects, .installer, .diskMap: true
        default: false
        }
    }

    /// System Clean is only in the edition that can ask for root.
    static let groups: [(String, [Pane])] = [
        ("Cleanup", [.dashboard, .clean] + (Edition.current.hasSystemTasks ? [.systemClean] : []) + [.uninstall, .optimize, .projects, .installer]),
        ("Insight", [.diskMap, .status, .history]),
        ("More", [.settings]),
    ]
}

/// App-wide state: which pane is showing and each module's model (kept here
/// so leaving a pane mid-scan doesn't lose its results).
@MainActor
@Observable
final class AppModel {
    var pane: Pane = .dashboard
    var status: SystemSnapshot?
    /// Size of the Trash, measured at most once a minute.
    var trashBytes: Int64?
    private var trashMeasuredAt: Date?
    private let sampler = SystemSampler()
    /// Every cleanup MyMole ran.
    var cleanups: [CleanupRecord] = []
    var fullDiskAccess = FullDiskAccess.isGranted

    let storage = StorageModel()
    let projects = ProjectsModel()
    let installers = InstallersModel()
    let deepClean = DeepCleanModel()
    let apps: AppsModel
    let privileged: PrivilegedClient
    /// The folders the App Store edition may work in; all of them in the direct edition.
    let access = FolderAccess()

    /// Scans may start: the home folder is open to MyMole, and Full Disk
    /// Access keeps macOS from asking about every protected folder.
    var canScan: Bool { access.has(.home) && fullDiskAccess }

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
        let privileged = PrivilegedClient()
        self.privileged = privileged
        apps = AppsModel(system: Edition.current.hasSystemTasks ? .live(privileged) : .unavailable)
        maintenance = MaintenanceModel(privileged: privileged)
        systemClean = SystemCleanModel(privileged: privileged)
    }

    /// Takes a reading off the main thread. Two panes may ask at once; an
    /// older reading never replaces a newer one.
    func refreshStatus() async {
        let sampler = sampler
        let s = await Task.detached(priority: .utility) { sampler.sample() }.value
        if s.date > status?.date ?? .distantPast { status = s }
        await refreshTrashSize()
    }

    private func refreshTrashSize() async {
        guard fullDiskAccess, Date().timeIntervalSince(trashMeasuredAt ?? .distantPast) >= 60 else { return }
        trashMeasuredAt = Date()
        let path = Home.path + "/.Trash"
        trashBytes = await Task.detached(priority: .utility) { StorageScanner.scan(path: path, workers: 1).root.size }.value
    }

    func recheckDiskAccess() {
        fullDiskAccess = FullDiskAccess.isGranted
        prefetchScans()
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
        guard canScan, !prewarmed else { return }
        prewarmed = true
        Task {
            projects.scanIfNeeded(background: true)
            await projects.scanJob?.value
            installers.scan(background: true)
            await installers.scanJob?.value
            deepClean.scan(background: true)
            await deepClean.scanJob?.value
            if apps.apps.isEmpty || apps.isStale {
                apps.load(background: true)
                await apps.loadJob?.value
            }
            try? await Task.sleep(for: Self.diskMapDelay)
            storage.prewarm(path: Home.path)
        }
    }

    /// Every cleanup scan at once, so the wall time is the slowest, not the
    /// sum; at the lower performance levels one after another instead.
    func scanAll(background: Bool = false) {
        // Checked here, not by callers: every module reads protected
        // folders, and a scan without access would report a partial Mac.
        guard canScan else { return }
        if privileged.isAvailable && !systemClean.scanning { systemClean.scan() }
        maintenance.check()
        guard PerformanceLevel.current().runsScansTogether else {
            Task {
                if !installers.scanning { installers.scan(background: background) }
                await installers.scanJob?.value
                if !deepClean.scanning { deepClean.scan(background: background) }
                await deepClean.scanJob?.value
                if apps.apps.isEmpty && !apps.loading { apps.load(background: background) }
            }
            return
        }
        if !installers.scanning { installers.scan(background: background) }
        if !deepClean.scanning { deepClean.scan(background: background) }
        if apps.apps.isEmpty && !apps.loading { apps.load(background: background) }
    }

    func refreshHistory() async {
        cleanups = await Task.detached(priority: .utility) { CleanupLog.load() }.value
    }

    /// Undo for a run whose items can still be put back, from the pane that
    /// moved them, so a notice that has gone never takes Undo with it.
    /// Returns once the Undo has finished and the history is read again.
    func undo(for record: CleanupRecord) -> (() async -> Void)? {
        let run: (() -> Void, () -> Bool)?
        if deepClean.undoLogID == record.id, deepClean.canUndo {
            run = (deepClean.undoTrash, { self.deepClean.trashing })
        } else if installers.undoLogID == record.id, installers.canUndo {
            run = (installers.undoTrash, { self.installers.trashing })
        } else if projects.undoLogID == record.id, projects.canUndo {
            run = (projects.undoTrash, { self.projects.trashing })
        } else if storage.undoLogID == record.id, storage.canUndo {
            run = (storage.undoTrash, { self.storage.trashing })
        } else if apps.undoLogID == record.id, apps.canUndo {
            run = (apps.undoUninstall, { self.apps.uninstalling })
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
        let bytes: Int64 =
            switch pane {
            case .projects: projects.freeableBytes
            case .installer: installers.totalBytes
            case .clean: deepClean.totalBytes
            case .systemClean: systemClean.totalBytes
            default: 0
            }
        if bytes > 0 { return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        if pane == .optimize, maintenance.willChange > 0 { return "\(maintenance.willChange)" }
        return nil
    }

    /// The most recent cleanup that really removed files, for the dashboard.
    var lastCleanup: CleanupRecord? {
        cleanups.first { $0.freedSomething && $0.freedBytes > 0 }
    }
}
