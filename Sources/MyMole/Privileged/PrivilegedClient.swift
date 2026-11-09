import Foundation
import PrivilegedKit
import StorageKit

/// System tasks: what's safe to do as the user runs here, and what needs
/// root runs in MyMole's privileged tool, which macOS starts once per request
/// after the user enters an administrator's password in its own prompt.
/// Nothing is installed. The App Store edition has none of this.
@MainActor
@Observable
final class PrivilegedClient {
    enum Failure: LocalizedError, Equatable {
        case unavailable
        case cancelled
        case refused(String)
        case failed(String)
        /// Another system task of this app is under way.
        case busy
        /// MyMole stopped waiting, but the tool may still be running as
        /// root, so what it did isn't known.
        case outcomeUnknown

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "System tasks aren't part of this edition of MyMole.")
            case .cancelled: String(localized: "Administrator access was cancelled, so nothing was changed.")
            case .refused(let why): why
            case .failed(let why): why
            case .busy: String(localized: "Another system task is still running. Wait for it to finish.")
            case .outcomeUnknown: Self.unknownText
            }
        }

        static let unknownText = String(localized: "MyMole stopped waiting for the privileged tool, which may still be running. What it changed isn't known yet, so no other system task runs until it has ended.")
    }

    /// A system task is under way: the administrator prompt or the tool.
    /// One at a time, so System Clean, Optimize and uninstall never overlap.
    private(set) var busy = false
    /// Set after MyMole stopped waiting on the tool without knowing it
    /// ended. Cleared only once no copy of the tool is seen running.
    private(set) var outcomeUnknown = false

    /// The tool's path inside this app, set only where system tasks exist.
    let toolPath: String?
    /// Runs the tool as root; injected so tests never ask for a password.
    private let elevate: @Sendable (_ tool: String, _ argument: String, _ prompt: String) -> (code: Int32, output: String)
    /// Whether a copy of the tool is running; nil when that can't be told.
    private let toolRunning: @Sendable () -> Bool?
    /// How often an unknown outcome is looked at again.
    private let recheckEvery: Duration
    private var watch: Task<Void, Never>?

    init(
        toolPath: String? = PrivilegedClient.bundledTool(),
        elevate: @escaping @Sendable (String, String, String) -> (code: Int32, output: String) = PrivilegedClient.adminPrompt,
        toolRunning: @escaping @Sendable () -> Bool? = { RunningTools.anyNamed(PrivilegedTool.name) },
        recheckEvery: Duration = .seconds(5)
    ) {
        self.toolPath = Edition.current.hasSystemTasks ? toolPath : nil
        self.elevate = elevate
        self.toolRunning = toolRunning
        self.recheckEvery = recheckEvery
    }

    var isAvailable: Bool { toolPath != nil }

    /// Why no system task may start now, or nil.
    var blocker: String? {
        if outcomeUnknown { return String(localized: "An earlier system task may still be running.") }
        if busy { return String(localized: "Another system task is running.") }
        return nil
    }

    /// Keeps looking until the tool MyMole stopped waiting on has ended, so
    /// the hold lifts by itself instead of waiting for a run it blocks.
    private func watchOutcome() {
        watch?.cancel()
        let every = recheckEvery
        watch = Task { [weak self] in
            while !Task.isCancelled, self?.outcomeUnknown == true {
                try? await Task.sleep(for: every)
                await self?.recheckOutcome()
            }
        }
    }

    /// Looks again whether the tool from a run MyMole stopped waiting on has
    /// ended. It stays unknown while the tool runs or the process list
    /// can't be read.
    func recheckOutcome() async {
        guard outcomeUnknown else { return }
        let toolRunning = toolRunning
        if await Task.detached(priority: .utility, operation: { toolRunning() }).value == false { outcomeUnknown = false }
    }

    // MARK: As the user

    /// What the root tasks would do. A check only looks for the programs, so
    /// it needs no password.
    func checkMaintenance(_ tasks: [MaintenanceTask]) async -> [TaskReport] {
        guard isAvailable else { return tasks.map { TaskReport($0, .needsHelper, String(localized: "Not part of this edition.")) } }
        return await Task.detached(priority: .userInitiated) {
            let engine = MaintenanceEngine(role: .root, home: "/var/root")
            return tasks.filter(\.needsRoot).map { engine.check($0) }
        }.value
    }

    /// System caches and logs as far as the user can read them; what can't
    /// be read is marked, and measured for real only when removed.
    func scanSystem(progress: ScanProgress = ScanProgress()) async throws -> SystemCleanListing {
        guard isAvailable else { throw Failure.unavailable }
        return await Task.detached(priority: .userInitiated) { SystemCleanRules.list(progress: progress) }.value
    }

    // MARK: As root

    func runMaintenance(_ tasks: [MaintenanceTask]) async throws -> [TaskReport] {
        let reply = try await run(
            .maintenance(tasks: tasks.filter(\.needsRoot).map(\.rawValue), dryRun: false),
            prompt: String(localized: "MyMole needs administrator rights to run system maintenance."))
        guard case .reports(let r) = reply else { throw Failure.failed(String(localized: "The privileged tool gave an unexpected answer.")) }
        return r
    }

    /// Removes `paths`; the tool itself refuses any `keep` protects.
    func removeSystem(_ paths: [String], keep: CleanKeepList = CleanKeepList()) async throws -> RemovalReport {
        let reply = try await run(.removeSystem(paths: paths, keep: keep.paths.sorted()), prompt: String(localized: "MyMole needs administrator rights to delete system caches and logs."))
        guard case .removal(let r) = reply else { throw Failure.failed(String(localized: "The privileged tool gave an unexpected answer.")) }
        return r
    }

    func removeLeftovers(_ paths: [String], appID: String, ids: [String]) async throws -> RemovalReport {
        let reply = try await run(
            .removeLeftovers(paths: paths, appID: appID, ids: ids),
            prompt: String(localized: "MyMole needs administrator rights to delete what the app left outside your Library."))
        guard case .removal(let r) = reply else { throw Failure.failed(String(localized: "The privileged tool gave an unexpected answer.")) }
        return r
    }

    func trashApplication(_ app: AppBundle, source: RemovedApp.Source) async throws -> ApplicationTrash.Receipt? {
        #if !APPSTORE
        guard let request = await Task.detached(priority: .userInitiated, operation: {
            ApplicationTrash.Request.capture(app, source: source)
        }).value else { return nil }
        let reply = try await run(.applicationTrash(request, restoring: false),
            prompt: String(localized: "MyMole needs administrator approval to stop \(app.name)'s bundled background agents and move the app to your Trash."))
        guard case .applicationTrash(let receipt) = reply, receipt.request == request,
              receipt.record.original.path == app.path else {
            throw Failure.failed(String(localized: "The app move could not be verified."))
        }
        return receipt
        #else
        return nil
        #endif
    }

    func restoreApplication(_ receipt: ApplicationTrash.Receipt) async throws -> Bool {
        #if !APPSTORE
        let reply = try await run(.applicationTrash(receipt.request, restoring: true),
            prompt: String(localized: "MyMole needs administrator approval to restore the app from your Trash."))
        guard case .applicationTrash(let restored) = reply, restored == receipt else {
            throw Failure.failed(String(localized: "The app restore could not be verified."))
        }
        return true
        #else
        return false
        #endif
    }

    private func run(_ request: PrivilegedRequest, prompt: String) async throws -> PrivilegedReply {
        guard let tool = toolPath else { throw Failure.unavailable }
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }
        await recheckOutcome()
        guard !outcomeUnknown else { throw Failure.outcomeUnknown }
        let argument = PrivilegedTool.argument(for: PrivilegedEnvelope(request: request))
        let elevate = elevate
        let r = await Task.detached(priority: .userInitiated) { elevate(tool, argument, prompt) }.value
        do {
            return try Self.interpret(code: r.code, output: r.output)
        } catch Failure.outcomeUnknown {
            outcomeUnknown = true
            watchOutcome()
            throw Failure.outcomeUnknown
        }
    }

    /// What a run of the tool came to: its reply, or why there's none.
    nonisolated static func interpret(code: Int32, output: String) throws -> PrivilegedReply {
        // AppleScript's "user canceled" error.
        if output.contains("(-128)") { throw Failure.cancelled }
        // Only the prompt is stopped at the time limit; the tool runs as
        // root apart from it and may still be at work.
        if code == CommandRunner.timedOut || code == CommandRunner.stopUnverified { throw Failure.outcomeUnknown }
        guard code == 0, let reply = PrivilegedTool.reply(from: output) else {
            throw Failure.failed(String(localized: "The privileged tool didn't finish (code \(code))."))
        }
        if case .refused(let why) = reply { throw Failure.refused(why) }
        if case .applicationTrashRefusal(let failure) = reply { throw failure }
        return reply
    }

    // MARK: Live

    /// The tool next to the app's own program: a real file, not a link.
    nonisolated static func bundledTool() -> String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent().path else { return nil }
        let path = dir + "/" + PrivilegedTool.name
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, Darwin.access(path, X_OK) == 0 else { return nil }
        return path
    }

    #if !APPSTORE
    /// Text as an AppleScript string literal.
    nonisolated static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The script that has macOS ask for an administrator's password and run
    /// the tool with one argument, each quoted for the shell.
    nonisolated static func script(tool: String, argument: String, prompt: String) -> String {
        "do shell script (quoted form of \(appleScriptString(tool))) & \" \" & (quoted form of \(appleScriptString(argument)))"
            + " with prompt \(appleScriptString(prompt)) with administrator privileges without altering line endings"
    }

    nonisolated static let adminPrompt: @Sendable (String, String, String) -> (code: Int32, output: String) = { tool, argument, prompt in
        #if SMOKE
        if let answer = smokeAnswer(to: argument) { return answer }
        #endif
        // Removal of a large cache can take a while; a stuck run is stopped.
        return CommandRunner.processes(timeLimit: 30 * 60).run(
            "/usr/bin/osascript", ["-e", script(tool: tool, argument: argument, prompt: prompt)])
    }
    #else
    /// The App Store edition never asks for root: no prompt, no tool.
    nonisolated static let adminPrompt: @Sendable (String, String, String) -> (code: Int32, output: String) = { _, _, _ in (-1, "") }
    #endif
}

#if SMOKE && !APPSTORE
extension PrivilegedClient {
    /// The UI smoke test's own build can stand in for the tool, so what a
    /// failed or unfinished system task shows can be looked at without a
    /// password or root: "fail" answers that nothing could be removed and
    /// where each remainder was left, "timeout" that MyMole stopped
    /// waiting. Nothing is run and nothing is removed.
    nonisolated static func smokeAnswer(to argument: String) -> (code: Int32, output: String)? {
        guard let mode = ProcessInfo.processInfo.environment["MYMOLE_SMOKE_ELEVATE"] else { return nil }
        if mode == "timeout" { return (CommandRunner.timedOut, "") }
        guard mode == "fail", let data = Data(base64Encoded: argument),
            let envelope = try? JSONDecoder().decode(PrivilegedEnvelope.self, from: data)
        else { return nil }
        let paths: [String]
        switch envelope.request {
        case .applicationTrash: return (0, PrivilegedTool.output(.refused("The synthetic administrator operation was cancelled.")))
        case .removeSystem(let p, _), .removeLeftovers(let p, _, _): paths = p
        case .maintenance(let tasks, _):
            let reports = tasks.compactMap(MaintenanceTask.init(rawValue:)).map { TaskReport($0, .failed, String(localized: "Stood in for by the smoke test.")) }
            return (0, PrivilegedTool.output(.reports(reports)))
        }
        var report = RemovalReport()
        for p in paths {
            let parent = (p as NSString).deletingLastPathComponent
            report.failed[p] = String(localized: "Part of it couldn't be removed; what was left is kept at \(parent)/.mymole-removing/smoke/\((p as NSString).lastPathComponent).")
        }
        return (0, PrivilegedTool.output(.removal(report)))
    }
}
#endif

