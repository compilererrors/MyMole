import AppKit
import Observation
import StorageKit

@MainActor @Observable
final class AppCopiesModel {
    private(set) var report = AppCopies.Report()
    private(set) var revision = 0
    private(set) var loading = false
    private(set) var measuring = false
    private(set) var stopped = false
    private(set) var loadedAt: Date?
    private(set) var problem: String?
    private(set) var extraFolders: [String] = []
    private(set) var counts: [String: Int] = [:]
    private(set) var job: Task<Void, Never>?
    private var progress: ScanProgress?
    private var measurement: ScanProgress?
    private let folders: [String]
    private let runner: CommandRunner
    private let registered: @Sendable (String) -> [String]?
    private let budget: ScanBudget

    init(folders: [String], runner: CommandRunner = .processes(timeLimit: 5, grace: 0.2, outputLimit: 2 << 20, drain: 0.2),
         registered: @escaping @Sendable (String) -> [String]? = { id in
             NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).map(\.path)
         }, budget: ScanBudget = .shared) {
        self.folders = folders
        #if SMOKE
        self.runner = CommandRunner(run: { _, _ in (0, "") }, exists: { _ in false })
        self.registered = { _ in [] }
        #else
        self.runner = runner
        self.registered = registered
        #endif
        self.budget = budget
    }

    func load() {
        guard !measuring else { return }
        progress?.cancel()
        let p = ScanProgress()
        progress = p
        loading = true
        stopped = false
        problem = nil
        let (folders, extra, runner, registered, budget) = (folders, extraFolders, runner, registered, budget)
        let level = PerformanceLevel.current()
        let updates = LatestOnly<AppCopies.Report> { [weak self] value in
            guard let self, self.progress === p, !p.isCancelled, self.loadedAt == nil else { return }
            self.publish(value)
        }
        job = Task.detached(priority: level.priority(background: false)) { [weak self] in
            let inventory = AppCopies.inventory(in: folders, runner: runner, registered: registered, progress: p, onStep: { updates.send($0) })
            updates.send(inventory)
            let result: AppCopies.Report?
            if extra.isEmpty { result = inventory }
            else {
                result = await budget.run(background: false, progress: p) {
                    AppCopies.addingFolders(extra, to: inventory, progress: p)
                }
            }
            await self?.finished(result, run: p)
        }
    }

    private func publish(_ report: AppCopies.Report) {
        self.report = report
        counts = AppCopies.counts(report.copies)
        revision += 1
    }

    private func finished(_ report: AppCopies.Report?, run: ScanProgress) {
        guard progress === run else { return }
        loading = false
        progress = nil
        guard let report, !report.cancelled, !run.isCancelled else { stopped = true; return }
        publish(report)
        loadedAt = .now
    }

    func stop() { progress?.cancel(); measurement?.cancel() }

    func addFolder(_ path: String) {
        guard !extraFolders.contains(path) else { return }
        extraFolders.append(path)
        load()
    }

    func removeFolder(_ path: String) {
        extraFolders.removeAll { $0 == path }
        load()
    }

    /// Only the requested copy is measured. Discovery never walks every app's contents.
    func prepareReview(_ copy: AppCopy, apps: AppsModel) async -> AppBundle? {
        guard !loading, !measuring else { return nil }
        apps.rememberOtherCopies(report.copies.map(\.app), unreadable: report.unreadable)
        let p = ScanProgress()
        measurement = p
        measuring = true
        problem = nil
        defer { if measurement === p { measurement = nil; measuring = false } }
        let budget = budget
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                await budget.run(background: false, progress: p) {
                    guard copy.isCurrent() else { return nil as AppBundle? }
                    let app = AppFinder.read(copy.app.path, progress: p)
                    return copy.isCurrent() && !p.isCancelled && app?.incomplete == false ? app : nil
                }
            }.value
        } onCancel: { p.cancel() }
        guard !Task.isCancelled, !p.isCancelled else { return nil }
        guard let app = result ?? nil else {
            problem = String(localized: "This app changed or couldn't be fully read. Scan again before reviewing its removal.")
            return nil
        }
        return app
    }
}
