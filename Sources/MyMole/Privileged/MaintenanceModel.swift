import AppKit
import Foundation
import PrivilegedKit
import StorageKit
import SwiftUI

/// State of the Optimize pane: which tasks are on, what a check found and
/// what the last run did. Root tasks go through the privileged tool; the rest run in
/// the app.
@MainActor
@Observable
final class MaintenanceModel {
    enum Phase: Equatable {
        case idle, checking, running
    }

    private(set) var reports: [MaintenanceTask: TaskReport] = [:]
    private(set) var phase = Phase.idle
    private(set) var checkedAt: Date?
    private(set) var lastRun: Date?
    private(set) var current: MaintenanceTask?
    var off: Set<MaintenanceTask> {
        didSet { defaults.set(off.map(\.rawValue).sorted(), forKey: Self.offKey) }
    }

    let privileged: PrivilegedClient
    private let engine: MaintenanceEngine
    private let defaults: UserDefaults
    private let logURL: URL
    private static let offKey = "maintenance.off"

    init(
        privileged: PrivilegedClient, engine: MaintenanceEngine = MaintenanceEngine(
            role: .user, running: { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }), defaults: UserDefaults = .standard,
        logURL: URL = CleanupLog.defaultURL
    ) {
        self.privileged = privileged
        self.engine = engine
        self.defaults = defaults
        self.logURL = logURL
        if let saved = defaults.stringArray(forKey: Self.offKey) {
            off = Set(saved.compactMap(MaintenanceTask.init(rawValue:)))
        } else {
            off = Set(MaintenanceTask.allCases.filter { !$0.onByDefault })
        }
    }

    /// The tasks this edition offers. The App Store edition runs in the
    /// sandbox: no root tasks, and none that drive macOS's own tools, which
    /// the sandbox stops; what's left works on files in the user's Library.
    var offered: [MaintenanceTask] {
        Edition.current.isSandboxed ? MaintenanceTask.allCases.filter(\.worksInSandbox) : MaintenanceTask.allCases
    }

    var enabled: [MaintenanceTask] { offered.filter { !off.contains($0) } }

    func isOn(_ t: MaintenanceTask) -> Bool { !off.contains(t) }

    func setOn(_ t: MaintenanceTask, _ on: Bool) {
        if on { off.remove(t) } else { off.insert(t) }
    }

    /// Tasks that would run now: on, and possible in this edition.
    var runnable: [MaintenanceTask] {
        enabled.filter { !$0.needsRoot || privileged.isAvailable }
    }

    var willChange: Int { enabled.filter { reports[$0]?.status == .willRun }.count }

    // MARK: Check and run

    func check() {
        guard phase == .idle else { return }
        phase = .checking
        Task { await perform(dryRun: true) }
    }

    func run() {
        guard phase == .idle, !runnable.isEmpty else { return }
        phase = .running
        Task { await perform(dryRun: false) }
    }

    private func perform(dryRun: Bool) async {
        let all = dryRun ? offered : runnable
        let user = all.filter { !$0.needsRoot }
        let root = all.filter(\.needsRoot)
        let engine = engine
        for t in user {
            current = t
            let r = await Task.detached(priority: .userInitiated) { dryRun ? engine.check(t) : engine.run(t) }.value
            reports[t] = r
        }
        if !root.isEmpty {
            current = root.first
            if dryRun {
                // A check of a root task only looks for its program: no password.
                for r in await privileged.checkMaintenance(root) { reports[r.task] = r }
            } else {
                // One administrator prompt for all of them.
                do {
                    for r in try await privileged.runMaintenance(root) { reports[r.task] = r }
                } catch {
                    for t in root { reports[t] = TaskReport(t, .failed, error.localizedDescription) }
                }
            }
        }
        current = nil
        if dryRun {
            checkedAt = .now
        } else {
            lastRun = .now
            let done = all.filter { reports[$0]?.status == .done }.count
            let failed = all.filter { reports[$0]?.status == .failed }.count
            let record = CleanupRecord(source: "Optimize", items: done, bytes: 0, failed: failed)
            CleanupLog.submit(record, to: logURL)
        }
        phase = .idle
    }
}
