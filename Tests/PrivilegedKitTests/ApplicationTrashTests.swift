import Darwin
import Foundation
import StorageKit
import Synchronization
import Testing
@testable import PrivilegedKit

/// An owned Applications directory, private staging and fake home Trash.
/// The owner policy is injected; no test requests root or touches real apps.
@Suite(.serialized) struct ApplicationTrashTests {
    private final class Fixture {
        let root: URL
        let home: String
        let applications: String
        let staging: String
        let app: String
        let request: ApplicationTrash.Request
        var context: ApplicationTrash.Context {
            .init(applications: applications, home: home, uid: getuid(), gid: getgid(),
                  appOwner: geteuid(), staging: staging, running: { _ in false })
        }
        init() throws {
            let temp = FileManager.default.temporaryDirectory.appending(path: "app-trash-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let canonical = try #require(realpath(temp.path, nil))
            root = URL(fileURLWithPath: String(cString: canonical))
            free(canonical)
            home = root.path + "/Home"; applications = root.path + "/Applications"; staging = root.path + "/Administrator"
            app = applications + "/Synthetic Editor.app"
            for path in [home, home + "/.Trash", staging, app + "/Contents/MacOS"] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.SyntheticEditor",
                "CFBundlePackageType": "APPL", "CFBundleExecutable": "SyntheticEditor"], format: .binary, options: 0)
            try data.write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
            try Data("synthetic fixture".utf8).write(to: URL(fileURLWithPath: app + "/Contents/MacOS/SyntheticEditor"))
            _ = chmod(app + "/Contents/MacOS/SyntheticEditor", 0o755)
            request = .init(path: app, bundleID: "com.example.SyntheticEditor", identity: try #require(Trasher.identity(of: app)),
                parentIdentity: try #require(Trasher.identity(of: applications)), uid: getuid(), trashName: "Synthetic Editor.app")
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func keep(_ paths: Set<String>) throws {
            try CleanKeepList(paths: paths).save(to: URL(fileURLWithPath: home + "/Library/Application Support/MyMole/DeepClean/keep.json"))
        }
        var exists: Bool { FileManager.default.fileExists(atPath: app) }
        var trash: String { home + "/.Trash/" + request.trashName }

        func agent(label: String = "com.example.SyntheticEditor.agent", program: String? = nil) throws -> BundledAppAgents.Process {
            let folder = app + "/Contents/Library/LaunchAgents"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let relative = program ?? "Contents/Library/LaunchAgents/" + label
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "BundleProgram": relative,
                "KeepAlive": true] as [String: Any], format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: folder + "/" + label + ".plist"))
            let binary = folder + "/" + label
            try Data("synthetic agent".utf8).write(to: URL(fileURLWithPath: binary))
            _ = chmod(binary, 0o755)
            return .init(pid: 1234, uid: getuid(), started: 123, microseconds: 456,
                         relativePath: "Contents/Library/LaunchAgents/" + label)
        }
    }

    @Test func movesOnlyTheAppAndRestoresTheSameObjectWithoutChangingPermissions() throws {
        let f = try Fixture()
        _ = chmod(f.app, 0o555)
        defer { _ = chmod(f.app, 0o700); _ = chmod(f.trash, 0o700) }
        var context = f.context
        // Simulate root's DAC override using ONLY this test's owned directory.
        // Production calls rename directly and never changes app permissions.
        context.rename = { from, name, to, target in
            let fd = openat(from, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { return -1 }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_uid == getuid() else { return -1 }
            guard fchmod(fd, st.st_mode | 0o200) == 0 else { return -1 }
            let result = renameatx_np(from, name, to, target, UInt32(RENAME_EXCL))
            _ = fchmod(fd, st.st_mode & 0o777)
            return result
        }
        let receipt = try ApplicationTrash.move(f.request, context: context)
        #expect(receipt.record.trashed.lastPathComponent == "Synthetic Editor.app")
        #expect(PrivilegedTool.reply(from: PrivilegedTool.output(.applicationTrash(receipt))) == .applicationTrash(receipt))
        #expect(!f.exists && receipt.record.original.path == f.app && receipt.record.trashed.path == f.trash)
        #expect(Trasher.identity(of: f.trash) == f.request.identity)
        var st = stat(); #expect(lstat(f.trash, &st) == 0 && st.st_mode & 0o777 == 0o555)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.staging).isEmpty)
        let restored = try ApplicationTrash.move(f.request, restoring: true, context: context)
        #expect(restored == receipt && f.exists && Trasher.identity(of: f.app) == f.request.identity)
    }

    @Test func requestAndReceiptSurviveTheProtocolAndRequireTheRealHelperToBeRoot() throws {
        let f = try Fixture()
        let request = PrivilegedRequest.applicationTrash(f.request, restoring: false)
        let encoded = PrivilegedTool.argument(for: PrivilegedEnvelope(request: request))
        #expect(try JSONDecoder().decode(PrivilegedEnvelope.self, from: #require(Data(base64Encoded: encoded))).request == request)
        if case .refused = PrivilegedTool.handle(argument: encoded, isRoot: false) {} else { Issue.record("Root must be required") }
        #expect(throws: (any Error).self) { try ApplicationTrash.move(f.request) }
        #expect(f.exists)
    }

    @Test func aMissingTrashIsCreatedPrivatelyWithoutChangingExistingEntries() throws {
        let f = try Fixture()
        try FileManager.default.removeItem(atPath: f.home + "/.Trash")
        _ = try ApplicationTrash.move(f.request, context: f.context)
        var st = stat()
        #expect(lstat(f.home + "/.Trash", &st) == 0 && st.st_uid == getuid() && st.st_mode & 0o777 == 0o700)
        #expect(Trasher.identity(of: f.trash) == f.request.identity)
    }

    @Test(arguments: [false, true]) func aKeepChangeBeforeOrAfterStagingStopsTheMove(_ afterStaging: Bool) throws {
        let f = try Fixture()
        var context = f.context
        var checked = false
        let keep = { checked = true; try! f.keep([f.app + "/Contents/MacOS/SyntheticEditor"]) }
        if afterStaging { context.beforeCommit = keep } else { context.beforeStage = keep }
        #expect(throws: (any Error).self) { try ApplicationTrash.move(f.request, context: context) }
        #expect(checked)
        #expect(f.exists && Trasher.identity(of: f.app) == f.request.identity)
        #expect(!FileManager.default.fileExists(atPath: f.trash))
    }

    @Test func anUnreadableRuleFileStopsTheMove() throws {
        let f = try Fixture()
        let rules = URL(fileURLWithPath: f.home + "/Library/Application Support/MyMole/Projects")
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: rules.appending(path: "rules.json"))
        #expect(throws: (any Error).self) { try ApplicationTrash.move(f.request, context: f.context) }
        #expect(f.exists)
    }

    @Test func aReplacementAppOrParentCannotUseAnEarlierApproval() throws {
        let f = try Fixture()
        try FileManager.default.moveItem(atPath: f.app, toPath: f.app + ".original")
        try FileManager.default.createDirectory(atPath: f.app, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try ApplicationTrash.move(f.request, context: f.context) }
        try FileManager.default.moveItem(atPath: f.applications, toPath: f.applications + ".original")
        try FileManager.default.createDirectory(atPath: f.applications, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try ApplicationTrash.move(f.request, context: f.context) }
        #expect(FileManager.default.fileExists(atPath: f.applications + ".original/Synthetic Editor.app.original/Contents/Info.plist"))
    }

    @Test func linkedAppMetadataAndLinkedTrashAreRefused() throws {
        let f = try Fixture()
        let info = f.app + "/Contents/Info.plist"
        try FileManager.default.moveItem(atPath: info, toPath: f.root.path + "/outside.plist")
        try FileManager.default.createSymbolicLink(atPath: info, withDestinationPath: f.root.path + "/outside.plist")
        #expect(throws: (any Error).self) { try ApplicationTrash.move(f.request, context: f.context) }
        try FileManager.default.removeItem(atPath: info)
        try FileManager.default.moveItem(atPath: f.root.path + "/outside.plist", toPath: info)
        try FileManager.default.moveItem(atPath: f.home + "/.Trash", toPath: f.home + "/other")
        try FileManager.default.createSymbolicLink(atPath: f.home + "/.Trash", withDestinationPath: f.home + "/other")
        #expect(throws: (any Error).self) { try ApplicationTrash.move(f.request, context: f.context) }
        #expect(f.exists)
    }

    @Test func redirectingTheTrashDuringTheOperationRollsBack() throws {
        let f = try Fixture()
        var context = f.context
        context.beforeCommit = {
            try! FileManager.default.moveItem(atPath: f.home + "/.Trash", toPath: f.home + "/earlier-trash")
            try! FileManager.default.createDirectory(atPath: f.home + "/.Trash", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        #expect(throws: (any Error).self) { try ApplicationTrash.move(f.request, context: context) }
        #expect(f.exists && Trasher.identity(of: f.app) == f.request.identity)
        #expect(FileManager.default.fileExists(atPath: f.home + "/earlier-trash"))
    }

    @Test func aLateCollisionIsNeverOverwrittenAndTheAppIsPutBack() throws {
        let f = try Fixture()
        var context = f.context
        context.beforeCommit = { try! Data("kept".utf8).write(to: URL(fileURLWithPath: f.trash)) }
        #expect(throws: (any Error).self) { try ApplicationTrash.move(f.request, context: context) }
        #expect(f.exists && Trasher.identity(of: f.app) == f.request.identity)
        #expect(try String(contentsOfFile: f.trash, encoding: .utf8) == "kept")
    }

    @Test func aFailedRollbackPreservesTheAppAndItsRecoveryRecord() throws {
        let f = try Fixture()
        var context = f.context
        context.beforeCommit = {
            try! FileManager.default.createDirectory(atPath: f.app, withIntermediateDirectories: true)
            try! Data("new app".utf8).write(to: URL(fileURLWithPath: f.app + "/replacement"))
            try! f.keep([f.app])
        }
        #expect(throws: (any Error).self) { try ApplicationTrash.move(f.request, context: context) }
        let stages = try FileManager.default.contentsOfDirectory(atPath: f.staging)
        let stage = f.staging + "/" + (try #require(stages.first))
        #expect(Trasher.identity(of: stage + "/bundle.app") == f.request.identity)
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: stage + "/request.json"))) as? [String: Any]
        #expect(record?["source"] as? String == f.app && record?["restoring"] as? Bool == false)
        #expect(try String(contentsOfFile: f.app + "/replacement", encoding: .utf8) == "new app")
    }

    @Test func earlierRecoveryDataIsNeverCollectedOrRemoved() throws {
        let f = try Fixture()
        let earlier = f.staging + "/earlier-job"
        try FileManager.default.createDirectory(atPath: earlier, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: URL(fileURLWithPath: earlier + "/request.json"))
        _ = try ApplicationTrash.move(f.request, context: f.context)
        #expect(try String(contentsOfFile: earlier + "/request.json", encoding: .utf8) == "kept")
    }

    @Test func anOpenAppOrUnverifiableProcessListStays() throws {
        let f = try Fixture()
        for state: Bool? in [true, nil] {
            var context = f.context; context.running = { _ in state }
            #expect(throws: (any Error).self) { try ApplicationTrash.move(f.request, context: context) }
            #expect(f.exists)
        }
        var context = f.context
        var open = false
        context.running = { _ in open }; context.beforeCommit = { open = true }
        #expect(throws: (any Error).self) { try ApplicationTrash.move(f.request, context: context) }
        #expect(open && f.exists)
    }

    @Test func restoreDoesNotOverwriteANewAppOrAcceptAChangedTrashedApp() throws {
        let f = try Fixture()
        _ = try ApplicationTrash.move(f.request, context: f.context)
        try FileManager.default.createDirectory(atPath: f.app, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try ApplicationTrash.move(f.request, restoring: true, context: f.context) }
        try FileManager.default.removeItem(atPath: f.app)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: f.trash + "/Contents/Info.plist"))
        #expect(throws: (any Error).self) { try ApplicationTrash.move(f.request, restoring: true, context: f.context) }
        #expect(!f.exists && FileManager.default.fileExists(atPath: f.trash))
    }

    @Test func aVerifiedKeepAliveAgentIsStoppedBeforeMovingAndNeverDisabled() throws {
        let f = try Fixture()
        let process = try f.agent()
        let state = Mutex([process])
        let calls = Mutex([[String]]())
        let runner = CommandRunner(run: { exe, args in
            #expect(exe == BundledAppAgents.launchctl)
            calls.withLock { $0.append(args) }
            if args == ["list"] { return (0, "PID\tStatus\tLabel\n1234\t0\tcom.example.SyntheticEditor.agent\n") }
            #expect(args == ["bootout", "gui/\(getuid())/com.example.SyntheticEditor.agent"])
            state.withLock { $0 = [] }
            return (0, "")
        }, exists: { _ in true })
        var context = f.context
        context.running = { _ in state.withLock { !$0.isEmpty } }
        context.stopBackgroundAgents = {
            try BundledAppAgents.stop($0, owner: getuid(), runner: runner,
                readProcesses: { _ in state.withLock { $0 } }, pause: {})
        }
        let receipt = try ApplicationTrash.move(f.request, context: context)
        #expect(!f.exists && receipt.isInTrash(home: f.home))
        #expect(calls.withLock { $0 } == [["list"], ["list"], ["bootout", "gui/\(getuid())/com.example.SyntheticEditor.agent"]])
        #expect(BundledAppAgents.listArguments(uid: 501, caller: 0) == ["asuser", "501", "/bin/launchctl", "list"])
        #expect(try ApplicationTrash.move(f.request, restoring: true, context: context) == receipt)
    }

    @Test func aKeptAppNeverStopsItsAgents() throws {
        let f = try Fixture(); _ = try f.agent()
        try f.keep([f.app])
        var stopped = false
        var context = f.context
        context.running = { _ in true }; context.stopBackgroundAgents = { _ in stopped = true }
        do { _ = try ApplicationTrash.move(f.request, context: context); Issue.record("Kept app must stay") }
        catch let failure as ApplicationTrash.Failure { #expect(failure.reason == .protections) }
        #expect(!stopped && f.exists)
    }

    @Test func anAgentFromAnotherAccountOrAnOpenMainAppIsNeverStopped() throws {
        let f = try Fixture(); let agent = try f.agent()
        let calls = Mutex(0)
        let runner = CommandRunner(run: { _, _ in calls.withLock { $0 += 1 }; return (0, "") }, exists: { _ in true })
        let main = BundledAppAgents.Process(pid: 1234, uid: getuid(), started: 123, microseconds: 456,
                                           relativePath: "Contents/MacOS/SyntheticEditor")
        let other = BundledAppAgents.Process(pid: agent.pid, uid: getuid() + 1, started: agent.started,
                                            microseconds: agent.microseconds, relativePath: agent.relativePath)
        for process in [main, other] {
            do { try BundledAppAgents.stop(f.request, owner: getuid(), runner: runner, readProcesses: { _ in [process] }, pause: {}); Issue.record("Unverified process must stay") }
            catch let failure as ApplicationTrash.Failure { #expect(failure.reason == .backgroundUnverified) }
        }
        #expect(calls.withLock { $0 } == 0 && f.exists)
    }

    @Test func anotherLoadedCopyAndAReusedPIDCannotBeStopped() throws {
        let f = try Fixture(); let agent = try f.agent()
        let calls = Mutex([[String]]())
        let runner = CommandRunner(run: { _, args in
            calls.withLock { $0.append(args) }
            return (0, "PID\tStatus\tLabel\n9999\t0\tcom.example.SyntheticEditor.agent\n")
        }, exists: { _ in true })
        #expect(throws: ApplicationTrash.Failure.self) {
            try BundledAppAgents.stop(f.request, owner: getuid(), runner: runner, readProcesses: { _ in [agent] }, pause: {})
        }
        #expect(calls.withLock { $0 } == [["list"]])
        let reads = Mutex(0)
        let valid = CommandRunner(run: { _, args in
            calls.withLock { $0.append(args) }
            return (0, "PID\tStatus\tLabel\n1234\t0\tcom.example.SyntheticEditor.agent\n")
        }, exists: { _ in true })
        #expect(throws: ApplicationTrash.Failure.self) {
            try BundledAppAgents.stop(f.request, owner: getuid(), runner: valid, readProcesses: { _ in
                let read = reads.withLock { $0 += 1; return $0 }
                return [.init(pid: agent.pid, uid: agent.uid, started: agent.started + (read > 1 ? 1 : 0),
                              microseconds: agent.microseconds, relativePath: agent.relativePath)]
            }, pause: {})
        }
        #expect(calls.withLock { $0.allSatisfy { $0 == ["list"] } } && f.exists)
    }

    @Test(arguments: ["com.apple.fixture", "com.other.Editor.agent", "../outside", "Contents/../outside"])
    func anUnrelatedOrEscapingAgentDefinitionCannotAuthorizeStopping(_ unsafe: String) throws {
        let f = try Fixture()
        let agent = try f.agent(label: unsafe.contains("/") ? "com.example.SyntheticEditor.agent" : unsafe,
                                program: unsafe.contains("/") ? unsafe : nil)
        let calls = Mutex(0)
        let runner = CommandRunner(run: { _, _ in calls.withLock { $0 += 1 }; return (0, "") }, exists: { _ in true })
        #expect(throws: ApplicationTrash.Failure.self) {
            try BundledAppAgents.stop(f.request, owner: getuid(), runner: runner, readProcesses: { _ in [agent] }, pause: {})
        }
        #expect(calls.withLock { $0 } == 0 && f.exists)
    }

    @Test func aLinkedAgentExecutableCannotBeStoppedAndAnUnreadableProcessListStaysUnknown() throws {
        let f = try Fixture(); let agent = try f.agent()
        let binary = f.app + "/" + agent.relativePath
        try FileManager.default.removeItem(atPath: binary)
        try FileManager.default.createSymbolicLink(atPath: binary, withDestinationPath: f.app + "/Contents/MacOS/SyntheticEditor")
        let calls = Mutex(0)
        let runner = CommandRunner(run: { _, _ in calls.withLock { $0 += 1 }; return (0, "") }, exists: { _ in true })
        #expect(throws: ApplicationTrash.Failure.self) {
            try BundledAppAgents.stop(f.request, owner: getuid(), runner: runner, readProcesses: { _ in [agent] }, pause: {})
        }
        do { _ = try BundledAppAgents.plan(f.request, owner: getuid(), runner: runner, readProcesses: { _ in nil }); Issue.record("Unknown process state must stop") }
        catch let failure as ApplicationTrash.Failure { #expect(failure.reason == .processUnknown) }
        #expect(calls.withLock { $0 } == 0 && f.exists)
    }

    @Test(arguments: [true, false]) func aFailedOrUnfinishedAgentStopDoesNotMoveTheApp(_ fail: Bool) throws {
        let f = try Fixture(); let agent = try f.agent()
        let runner = CommandRunner(run: { _, args in
            args == ["list"] ? (0, "PID\tStatus\tLabel\n1234\t0\tcom.example.SyntheticEditor.agent\n") : (fail ? 5 : 0, "")
        }, exists: { _ in true })
        var context = f.context
        context.running = { _ in true }
        context.stopBackgroundAgents = {
            try BundledAppAgents.stop($0, owner: getuid(), runner: runner, readProcesses: { _ in [agent] }, pause: {})
        }
        do { _ = try ApplicationTrash.move(f.request, context: context); Issue.record("Agent must stop before moving") }
        catch let failure as ApplicationTrash.Failure { #expect(failure.reason == (fail ? .backgroundStopFailed : .backgroundStillRunning)) }
        #expect(f.exists && !FileManager.default.fileExists(atPath: f.trash))
    }

    @Test func applicationRefusalsKeepTheirExactReasonAcrossTheWireWithoutPuttingDetailsInTheErrorCode() throws {
        let failure = ApplicationTrash.Failure(.backgroundUnverified, "Synthetic process at /synthetic/private.app")
        #expect(PrivilegedTool.reply(from: PrivilegedTool.output(.applicationTrashRefusal(failure))) == .applicationTrashRefusal(failure))
        #expect(ErrorCode(.uninstall, failure).description == "MM-UNINST-ApplicationTrashFailure2106")
    }

    @Test func aManifestCannotAuthorizeStoppingTheMainExecutableOrAnAppReplacement() throws {
        let f = try Fixture(); _ = try f.agent(program: "Contents/MacOS/SyntheticEditor")
        let main = BundledAppAgents.Process(pid: 1234, uid: getuid(), started: 123, microseconds: 456,
                                           relativePath: "Contents/MacOS/SyntheticEditor")
        let calls = Mutex(0)
        let runner = CommandRunner(run: { _, _ in calls.withLock { $0 += 1 }; return (0, "") }, exists: { _ in true })
        #expect(throws: ApplicationTrash.Failure.self) {
            _ = try BundledAppAgents.plan(f.request, owner: getuid(), runner: runner, readProcesses: { _ in [main] })
        }
        try FileManager.default.moveItem(atPath: f.app, toPath: f.app + ".original")
        try FileManager.default.createDirectory(atPath: f.app, withIntermediateDirectories: true)
        do { _ = try BundledAppAgents.plan(f.request, owner: getuid(), runner: runner, readProcesses: { _ in [main] }); Issue.record("Replaced app must stay") }
        catch let failure as ApplicationTrash.Failure { #expect(failure.reason == .appChanged) }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func aProtectionChangeWhileAnAgentStopsStillPreventsTheMove() throws {
        let f = try Fixture()
        var running = true
        var context = f.context
        context.running = { _ in running }
        context.stopBackgroundAgents = { _ in running = false; try f.keep([f.app]) }
        #expect(throws: ApplicationTrash.Failure.self) { try ApplicationTrash.move(f.request, context: context) }
        #expect(!running && f.exists && !FileManager.default.fileExists(atPath: f.trash))
    }

    @Test func trashNamesStayReadableAndUnknownOrOccupiedDestinationsAreNeverAssumedFree() {
        var checked: [String] = []
        let chosen = ApplicationTrash.Request.availableTrashName(for: "Synthetic Editor.app") { candidate in
            checked.append(candidate)
            return candidate != "Synthetic Editor 3.app"
        }
        #expect(chosen == "Synthetic Editor 3.app")
        #expect(checked == ["Synthetic Editor.app", "Synthetic Editor 2.app", "Synthetic Editor 3.app"])
        #expect(ApplicationTrash.Request.availableTrashName(for: "Synthetic.app", occupied: { _ in nil }) == nil)
        #expect(ApplicationTrash.Request.availableTrashName(for: "Synthetic.app", occupied: { _ in true }) == nil)
        for unsafe in ["../Synthetic.app", "Other.app", "Synthetic Editor 0.app", "Synthetic Editor 02.app", "Synthetic Editor 10000.app"] {
            #expect(!ApplicationTrash.Request.acceptsTrashName(unsafe, original: "Synthetic Editor.app", restoring: false))
        }
    }

    @Test func aNumberedDestinationCanMoveAndRestoreWithoutReplacingAnEarlierCopy() throws {
        let f = try Fixture()
        try Data("previous copy".utf8).write(to: URL(fileURLWithPath: f.trash))
        let request = ApplicationTrash.Request(path: f.request.path, bundleID: f.request.bundleID,
            identity: f.request.identity, parentIdentity: f.request.parentIdentity, uid: f.request.uid, trashName: "Synthetic Editor 2.app")
        let receipt = try ApplicationTrash.move(request, context: f.context)
        #expect(receipt.record.trashed.lastPathComponent == "Synthetic Editor 2.app")
        #expect(try String(contentsOfFile: f.trash, encoding: .utf8) == "previous copy")
        #expect(try ApplicationTrash.move(request, restoring: true, context: f.context) == receipt)
        #expect(f.exists)
    }

    @Test func legacyUUIDNamesRemainRestorableButAreNeverProposedForNewMoves() throws {
        let f = try Fixture()
        let name = UUID().uuidString + "-Synthetic Editor.app"
        #expect(!ApplicationTrash.Request.acceptsTrashName(name, original: "Synthetic Editor.app", restoring: false))
        #expect(ApplicationTrash.Request.acceptsTrashName(name, original: "Synthetic Editor.app", restoring: true))
        try FileManager.default.moveItem(atPath: f.app, toPath: f.home + "/.Trash/" + name)
        let request = ApplicationTrash.Request(path: f.request.path, bundleID: f.request.bundleID,
            identity: f.request.identity, parentIdentity: f.request.parentIdentity, uid: f.request.uid, trashName: name)
        _ = try ApplicationTrash.move(request, restoring: true, context: f.context)
        #expect(f.exists)
    }

    @Test func malformedNamesAppleIDsAndOtherAccountsAreRefused() throws {
        let f = try Fixture()
        for (path, id, uid, name) in [(f.app, "com.apple.SyntheticEditor", getuid(), f.request.trashName),
                (f.app, f.request.bundleID, getuid() + 1, f.request.trashName),
                (f.app, f.request.bundleID, getuid(), "../elsewhere.app"),
                (f.applications + "/../Synthetic.app", f.request.bundleID, getuid(), f.request.trashName)] {
            let request = ApplicationTrash.Request(path: path, bundleID: id, identity: f.request.identity,
                parentIdentity: f.request.parentIdentity, uid: uid, trashName: name)
            #expect(throws: (any Error).self) { try ApplicationTrash.move(request, context: f.context) }
            #expect(f.exists)
        }
    }
}
