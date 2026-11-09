import Foundation
import PrivilegedKit
import StorageKit
import Synchronization
import Testing

@testable import MyMole

/// The direct edition's way to root: the tool is never really run here,
/// and no password is asked for.
@MainActor
@Suite struct PrivilegedClientTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [(tool: String, argument: String, prompt: String)] = []
        func add(_ c: (String, String, String)) { lock.withLock { all.append(c) } }
        var list: [(tool: String, argument: String, prompt: String)] { lock.withLock { all } }
    }

    #if !APPSTORE
    @Test func runsTheToolOnceWithTheRequestAndReadsItsReply() async throws {
        let calls = Calls()
        let client = PrivilegedClient(toolPath: "/synthetic/MyMole.app/Contents/MacOS/MyMoleHelper", elevate: { tool, arg, prompt in
            calls.add((tool, arg, prompt))
            return (0, PrivilegedTool.output(.removal(RemovalReport())) + "\n")
        })
        _ = try await client.removeSystem(["/Library/Caches/com.vendor.Agent"])
        let call = try #require(calls.list.first)
        #expect(calls.list.count == 1 && call.tool.hasSuffix("/MyMoleHelper") && call.prompt.contains("administrator"))
        let envelope = try JSONDecoder().decode(PrivilegedEnvelope.self, from: try #require(Data(base64Encoded: call.argument)))
        #expect(envelope.request == .removeSystem(paths: ["/Library/Caches/com.vendor.Agent"], keep: []))
    }
    #endif

    @Test func aCancelledPromptOrARefusalIsReportedAsSuch() {
        #expect(throws: PrivilegedClient.Failure.cancelled) {
            try PrivilegedClient.interpret(code: 1, output: "execution error: User canceled. (-128)")
        }
        #expect(throws: PrivilegedClient.Failure.refused("The tool must run as root.")) {
            try PrivilegedClient.interpret(code: 0, output: PrivilegedTool.output(.refused("The tool must run as root.")))
        }
        #expect(throws: PrivilegedClient.Failure.self) { try PrivilegedClient.interpret(code: 0, output: "garbage") }
    }

    @Test func aRunMyMoleStoppedWaitingOnIsNeverCalledStopped() {
        for code in [CommandRunner.timedOut, CommandRunner.stopUnverified] {
            #expect(throws: PrivilegedClient.Failure.outcomeUnknown) { try PrivilegedClient.interpret(code: code, output: "") }
        }
        #expect(!PrivilegedClient.Failure.unknownText.contains("was stopped"))
    }

    @Test func applicationMoveRefusalsPreserveTheirSpecificSupportCode() {
        let failure = ApplicationTrash.Failure(.backgroundStopFailed, "Synthetic launch agent did not stop.")
        #expect(throws: failure) {
            try PrivilegedClient.interpret(code: 0, output: PrivilegedTool.output(.applicationTrashRefusal(failure)))
        }
        #expect(ErrorCode(.uninstall, failure).description == "MM-UNINST-ApplicationTrashFailure2107")
    }

    #if !APPSTORE
    @Test func oneSystemTaskAtATimeFromOneClient() async throws {
        let state = Mutex((active: 0, peak: 0, calls: 0))
        let client = PrivilegedClient(toolPath: "/synthetic/MyMole.app/Contents/MacOS/MyMoleHelper", elevate: { _, _, _ in
            state.withLock { s in s.active += 1; s.calls += 1; s.peak = max(s.active, s.peak) }
            Thread.sleep(forTimeInterval: 0.1)
            state.withLock { $0.active -= 1 }
            return (0, PrivilegedTool.output(.removal(RemovalReport())))
        }, toolRunning: { false })
        async let first = Result { try await client.removeSystem(["/Library/Caches/com.vendor.First"]) }
        async let second = Result { try await client.removeSystem(["/Library/Caches/com.vendor.Second"]) }
        let results = await [first, second]
        #expect(state.withLock { $0.peak } == 1 && state.withLock { $0.calls } == 1)
        #expect(results.filter { if case .failure(PrivilegedClient.Failure.busy) = $0 { true } else { false } }.count == 1)
        #expect(!client.busy && client.blocker == nil)
    }

    @Test func theHoldLiftsByItselfOnceTheToolHasEnded() async throws {
        let toolRuns = Mutex(true)
        let client = PrivilegedClient(toolPath: "/synthetic/MyMole.app/Contents/MacOS/MyMoleHelper", elevate: { _, _, _ in
            (CommandRunner.timedOut, "")
        }, toolRunning: { toolRuns.withLock { $0 } }, recheckEvery: .milliseconds(20))
        _ = try? await client.removeSystem(["/Library/Caches/com.vendor.A"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.outcomeUnknown)
        // No new run is needed: the blocker it shows would never let one start.
        toolRuns.withLock { $0 = false }
        for _ in 0..<100 where client.outcomeUnknown { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!client.outcomeUnknown && client.blocker == nil)
    }

    @Test func anUnknownOutcomeHoldsEveryLaterTaskUntilTheToolHasEnded() async throws {
        let toolRuns = Mutex(true)
        let calls = Calls()
        let client = PrivilegedClient(toolPath: "/synthetic/MyMole.app/Contents/MacOS/MyMoleHelper", elevate: { t, a, p in
            calls.add((t, a, p))
            return calls.list.count == 1 ? (CommandRunner.timedOut, "") : (0, PrivilegedTool.output(.removal(RemovalReport())))
        }, toolRunning: { toolRuns.withLock { $0 } })
        await #expect(throws: PrivilegedClient.Failure.outcomeUnknown) { try await client.removeSystem(["/Library/Caches/com.vendor.A"]) }
        #expect(client.outcomeUnknown && client.blocker != nil)
        // Still running: refused without a prompt.
        await #expect(throws: PrivilegedClient.Failure.outcomeUnknown) { try await client.removeSystem(["/Library/Caches/com.vendor.A"]) }
        #expect(calls.list.count == 1)
        // Can't be told: still held.
        let unreadable = PrivilegedClient(toolPath: "/synthetic/MyMole.app/Contents/MacOS/MyMoleHelper", elevate: { _, _, _ in (CommandRunner.stopUnverified, "") }, toolRunning: { nil })
        _ = try? await unreadable.removeSystem(["/x"])
        await unreadable.recheckOutcome()
        #expect(unreadable.outcomeUnknown)
        // Gone: the next task may ask again.
        toolRuns.withLock { $0 = false }
        _ = try await client.removeSystem(["/Library/Caches/com.vendor.A"])
        #expect(calls.list.count == 2 && !client.outcomeUnknown)
    }
    #endif

    @Test func withoutTheToolNothingIsAttempted() async {
        let calls = Calls()
        let client = PrivilegedClient(toolPath: nil, elevate: { t, a, p in calls.add((t, a, p)); return (0, "") })
        #expect(!client.isAvailable)
        await #expect(throws: PrivilegedClient.Failure.unavailable) { try await client.removeSystem(["/x"]) }
        #expect(calls.list.isEmpty)
    }

    #if !APPSTORE
    @Test func theScriptQuotesEverythingItHandsTheShell() {
        let tool = #"/Apps/My "Mole".app/Contents/MacOS/MyMoleHelper"#
        let script = PrivilegedClient.script(tool: tool, argument: "QUJD", prompt: #"Say "hi" \ now"#)
        // Each value is an AppleScript string, then made shell-safe with quoted form.
        #expect(script.hasPrefix(#"do shell script (quoted form of "/Apps/My \"Mole\".app/Contents/MacOS/MyMoleHelper")"#))
        #expect(script.contains(#"(quoted form of "QUJD")"#))
        #expect(script.contains(#"with prompt "Say \"hi\" \\ now""#))
        #expect(script.hasSuffix("with administrator privileges without altering line endings"))
    }

    @Test func theDirectEditionHasEveryFolder() {
        #expect(Edition.current == .direct)
        let dir = FileManager.default.temporaryDirectory.appending(path: "access-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let access = FolderAccess(defaults: testDefaults(in: dir))
        #expect(FolderAccess.Place.allCases.allSatisfy(access.has) && !access.needsHome)
    }
    #else
    /// The App Store edition never asks for root: no tool, no prompt,
    /// whatever it's handed.
    @Test func theAppStoreEditionNeverElevates() async {
        #expect(Edition.current == .appStore && !Edition.current.hasSystemTasks)
        let calls = Calls()
        let client = PrivilegedClient(toolPath: "/synthetic/MyMole.app/Contents/MacOS/MyMoleHelper", elevate: { t, a, p in
            calls.add((t, a, p))
            return (0, PrivilegedTool.output(.removal(RemovalReport())))
        })
        #expect(!client.isAvailable)
        await #expect(throws: PrivilegedClient.Failure.unavailable) { try await client.removeSystem(["/Library/Caches/com.vendor.Agent"]) }
        await #expect(throws: PrivilegedClient.Failure.unavailable) { try await client.runMaintenance([.flushDNS]) }
        await #expect(throws: PrivilegedClient.Failure.unavailable) {
            try await client.removeLeftovers(["/Library/LaunchDaemons/com.vendor.Agent.plist"], appID: "com.vendor.Agent", ids: [])
        }
        let identity = Trasher.Identity(type: 0, device: 0, inode: 0)
        let request = ApplicationTrash.Request(path: "/synthetic/Editor.app", bundleID: "com.example.Editor",
            identity: identity, parentIdentity: identity, uid: 501, trashName: "synthetic.app")
        let receipt = ApplicationTrash.Receipt(request: request, record: .init(
            original: URL(fileURLWithPath: "/synthetic/Editor.app"), trashed: URL(fileURLWithPath: "/synthetic/Trash/Editor.app")))
        #expect((try? await client.restoreApplication(receipt)) == false)
        #expect(calls.list.isEmpty)
        // The live prompt is a stub that runs nothing.
        #expect(PrivilegedClient.adminPrompt("/bin/echo", "x", "y").code == -1)
        let model = SystemCleanModel(privileged: client, keepURL: FileManager.default.temporaryDirectory.appending(path: "keep-\(UUID().uuidString).json"))
        #expect(model.removeBlocker == "System tasks aren't part of this edition.")
    }
    #endif
}
