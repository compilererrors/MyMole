import Foundation
import PrivilegedKit
import StorageKit
import Testing

@testable import MyMole

/// No privileged tool here, so root tasks are unavailable: root
/// tasks must say so, and nothing runs a real system program.
@MainActor
@Suite struct MaintenanceModelTests {
    private func model(runner: CommandRunner) -> (MaintenanceModel, UserDefaults, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "maint-\(UUID().uuidString)")
        let defaults = testDefaults(in: dir)
        let engine = MaintenanceEngine(role: .user, home: dir.path, runner: runner, trash: { _, _ in TrashOutcome(moved: [], failed: []) })
        return (MaintenanceModel(privileged: PrivilegedClient(toolPath: nil), engine: engine, defaults: defaults,
                                 logURL: dir.appending(path: "history.json")), defaults, dir)
    }

    private func wait(_ m: MaintenanceModel) async throws {
        while m.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
    }

    #if !APPSTORE
    @Test func rootTasksNeedTheHelperAndOnlyUserTasksRun() async throws {
        let calls = CallLog()
        let runner = CommandRunner(run: { exe, args in calls.add([exe] + args); return (0, "") }, exists: { _ in true })
        let (m, _, dir) = model(runner: runner)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!m.privileged.isAvailable)
        m.check()
        try await wait(m)
        #expect(m.reports[.flushDNS]?.status == .needsHelper)
        #expect(m.reports[.quickLook]?.status == .willRun)
        // A check only reads: the Finder setting, through `defaults read`.
        #expect(calls.all.allSatisfy { $0.starts(with: ["/usr/bin/defaults", "read"]) })
        let checked = calls.all.count

        #expect(m.runnable.allSatisfy { !$0.needsRoot })
        m.run()
        try await wait(m)
        #expect(m.reports[.quickLook]?.status == .done)
        #expect(calls.all.dropFirst(checked).map { $0[0] } == ["/usr/bin/qlmanage", "/usr/bin/qlmanage"])
        // The log is written in the background.
        var log = CleanupLog.load(from: dir.appending(path: "history.json"))
        for _ in 0..<100 where log.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            log = CleanupLog.load(from: dir.appending(path: "history.json"))
        }
        #expect(log.first?.source == "Optimize")
    }
    #else
    /// The sandboxed edition offers only what works on the user's own
    /// files: no root task, and no program of macOS's is ever started.
    @Test func theAppStoreEditionOffersOnlySandboxTasks() async throws {
        let calls = CallLog()
        let runner = CommandRunner(run: { exe, args in calls.add([exe] + args); return (0, "") }, exists: { _ in true })
        let (m, _, dir) = model(runner: runner)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!m.offered.isEmpty && m.offered.allSatisfy { $0.worksInSandbox && !$0.needsRoot })
        m.check()
        try await wait(m)
        #expect(Set(m.reports.keys).isSubset(of: Set(m.offered)))
        m.run()
        try await wait(m)
        #expect(calls.all.allSatisfy { $0.starts(with: ["/usr/bin/defaults", "read"]) })
    }
    #endif

    @Test func choicesPersist() {
        let runner = CommandRunner(run: { _, _ in (0, "") }, exists: { _ in true })
        let (m, defaults, dir) = model(runner: runner)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(m.isOn(.quickLook) && !m.isOn(.spotlight))
        m.setOn(.quickLook, false)
        m.setOn(.spotlight, true)
        let again = MaintenanceModel(privileged: m.privileged, defaults: defaults)
        #expect(!again.isOn(.quickLook) && again.isOn(.spotlight))
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func add(_ c: [String]) { lock.withLock { calls.append(c) } }
    var all: [[String]] { lock.withLock { calls } }
}
