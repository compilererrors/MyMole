import Foundation
import Synchronization
import Testing

@testable import PrivilegedKit
import StorageKit

/// A throwaway directory tree, removed on deinit.
final class Box {
    let url = FileManager.default.temporaryDirectory.appending(path: "privileged-\(UUID().uuidString)")
    var path: String { url.path }

    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ rel: String, _ data: Data = Data(repeating: 9, count: 4_000), age: TimeInterval = 0) throws -> String {
        let u = url.appending(path: rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        if age > 0 { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: u.path) }
        return u.path
    }

    func folder(_ rel: String, age: TimeInterval = 0) throws {
        let u = url.appending(path: rel)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        if age > 0 { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: u.path) }
    }

    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path + "/" + rel) }
}

/// Records every command instead of running it.
final class FakeRunner: Sendable {
    let calls = Mutex<[[String]]>([])
    let missing: Set<String>
    let codes: [String: Int32]
    let outputs: [String: String]

    init(missing: Set<String> = [], codes: [String: Int32] = [:], outputs: [String: String] = [:]) {
        self.missing = missing
        self.codes = codes
        self.outputs = outputs
    }

    var runner: CommandRunner {
        CommandRunner(
            run: { exe, args in
                self.calls.withLock { $0.append([exe] + args) }
                let key = ([exe] + args).joined(separator: " ")
                return (self.codes[key] ?? self.codes[exe] ?? 0, self.outputs[key] ?? "")
            },
            exists: { !self.missing.contains($0) })
    }
}

@Suite struct MaintenanceEngineTests {
    @Test func userEngineRefusesRootTasksAndRootEngineUserTasks() {
        let fake = FakeRunner()
        let user = MaintenanceEngine(role: .user, home: "/synthetic", runner: fake.runner)
        let root = MaintenanceEngine(role: .root, home: "/synthetic", runner: fake.runner)
        #expect(user.run(.flushDNS).status == .needsHelper)
        #expect(root.run(.quickLook).status == .needsHelper)
        #expect(fake.calls.withLock { $0 }.isEmpty)
    }

    @Test func commandTasksRunFixedProgramsOnly() {
        let fake = FakeRunner(codes: ["/usr/bin/killall": 1])
        let root = MaintenanceEngine(role: .root, home: "/synthetic", runner: fake.runner)
        #expect(root.run(.flushDNS).status == .done)
        #expect(fake.calls.withLock { $0 } == [
            ["/usr/bin/dscacheutil", "-flushcache"], ["/usr/bin/killall", "-HUP", "mDNSResponder"],
        ])
    }

    @Test func aFailingProgramIsReportedWithItsLastLine() {
        let fake = FakeRunner(codes: ["/usr/sbin/diskutil": 1], outputs: ["/usr/sbin/diskutil verifyVolume /": "Checking\nError: volume damaged\n"])
        let root = MaintenanceEngine(role: .root, home: "/synthetic", runner: fake.runner)
        #expect(root.run(.verifyDisk) == TaskReport(.verifyDisk, .failed, "Error: volume damaged"))
    }

    @Test func missingProgramsAreUnavailable() {
        let fake = FakeRunner(missing: ["/usr/sbin/periodic"])
        let root = MaintenanceEngine(role: .root, home: "/synthetic", runner: fake.runner)
        #expect(root.check(.periodic).status == .unavailable)
        #expect(root.run(.periodic).status == .unavailable)
        #expect(fake.calls.withLock { $0 }.isEmpty)
    }

    @Test func checkNeverRunsAnything() {
        let fake = FakeRunner()
        let user = MaintenanceEngine(role: .user, home: "/synthetic", runner: fake.runner)
        #expect(user.check(.quickLook).status == .willRun)
        #expect(user.check(.launchServices).status == .willRun)
        #expect(fake.calls.withLock { $0 }.isEmpty)
    }

    @Test func dsStoreSettingsAreReadBeforeTheyAreWritten() {
        let read = "/usr/bin/defaults read com.apple.desktopservices "
        let on = FakeRunner(outputs: [read + "DSDontWriteNetworkStores": "1\n", read + "DSDontWriteUSBStores": "true\n"])
        #expect(MaintenanceEngine(role: .user, home: "/synthetic", runner: on.runner).check(.networkDSStore).status == .nothingToDo)

        // Network on, USB off: only the USB setting is written.
        let half = FakeRunner(codes: [read + "DSDontWriteUSBStores": 1], outputs: [read + "DSDontWriteNetworkStores": "1\n"])
        let engine = MaintenanceEngine(role: .user, home: "/synthetic", runner: half.runner)
        #expect(engine.check(.networkDSStore).status == .willRun)
        #expect(engine.run(.networkDSStore).status == .done)
        #expect(half.calls.withLock { $0 }.filter { $0.contains("write") }
            == [["/usr/bin/defaults", "write", "com.apple.desktopservices", "DSDontWriteUSBStores", "-bool", "true"]])

        let off = FakeRunner(codes: ["/usr/bin/defaults": 1])
        _ = MaintenanceEngine(role: .user, home: "/synthetic", runner: off.runner).run(.networkDSStore)
        #expect(off.calls.withLock { $0 }.filter { $0.contains("write") }.count == 1)
    }

    @Test func activeWindowStatesAndFreshSettingsStay() throws {
        let home = try Box()
        // An old folder whose app wrote inside it today.
        try home.folder("Library/Saved Application State/com.vendor.Busy.savedState", age: 40 * 86_400)
        try home.file("Library/Saved Application State/com.vendor.Busy.savedState/windows.plist")
        try home.folder("Library/Saved Application State/com.vendor.Busy.savedState", age: 40 * 86_400)
        // An old one of an app that's running.
        try home.folder("Library/Saved Application State/com.vendor.Open.savedState", age: 40 * 86_400)
        // A settings file being written right now, and one of a running app.
        try home.file("Library/Preferences/com.vendor.Writing.plist", Data())
        try home.file("Library/Preferences/com.vendor.Open.plist", Data("x".utf8), age: 3_600)
        let engine = MaintenanceEngine(role: .user, home: home.path, runner: FakeRunner().runner, running: { ["com.vendor.Open"] })
        #expect(engine.check(.savedState).status == .nothingToDo)
        #expect(engine.check(.brokenPreferences).status == .nothingToDo)
    }

    @Test func oldWindowStatesAndBrokenSettingsGoToTheTrash() throws {
        let home = try Box()
        try home.folder("Library/Saved Application State/com.vendor.Old.savedState", age: 40 * 86_400)
        try home.folder("Library/Saved Application State/com.vendor.New.savedState")
        try home.file("Library/Preferences/com.vendor.Good.plist", try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0))
        try home.file("Library/Preferences/com.vendor.Broken.plist", Data("not a plist".utf8), age: 3_600)
        try home.file("Library/Preferences/com.vendor.Empty.plist", Data(), age: 3_600)
        // "The Trash" is a folder of the box, so the real one is never touched.
        let bin = home.path + "/Bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let engine = MaintenanceEngine(role: .user, home: home.path, runner: FakeRunner().runner, trash: { paths, gate in
            var moved: [TrashRecord] = []
            for p in Trasher.clear(paths, through: gate).allowed {
                let to = URL(fileURLWithPath: bin + "/" + (p as NSString).lastPathComponent)
                if (try? FileManager.default.moveItem(atPath: p, toPath: to.path)) != nil {
                    moved.append(TrashRecord(original: URL(fileURLWithPath: p), trashed: to))
                }
            }
            return TrashOutcome(moved: moved, failed: [])
        })

        #expect(engine.check(.savedState).status == .willRun)
        #expect(engine.check(.brokenPreferences).detail.hasPrefix("2 "))
        let trashed = [engine.run(.savedState), engine.run(.brokenPreferences)]
        #expect(trashed.map(\.status) == [.done, .done])
        #expect(home.exists("Bin/com.vendor.Old.savedState") && home.exists("Bin/com.vendor.Broken.plist"))
        #expect(!home.exists("Library/Saved Application State/com.vendor.Old.savedState"))
        #expect(home.exists("Library/Saved Application State/com.vendor.New.savedState"))
        #expect(home.exists("Library/Preferences/com.vendor.Good.plist"))
        #expect(!home.exists("Library/Preferences/com.vendor.Broken.plist"))
        #expect(engine.check(.brokenPreferences).status == .nothingToDo)
    }
}

@Suite struct SystemCleanRulesTests {
    private func roots(_ box: Box) -> [SystemCleanRules.Root] {
        [
            SystemCleanRules.Root(path: box.path + "/Library/Caches", reason: "cache"),
            SystemCleanRules.Root(path: box.path + "/var/log", rotatedLogsOnly: true, reason: "log"),
        ]
    }

    private func setUp() throws -> Box {
        let box = try Box()
        try box.file("Library/Caches/com.vendor.Agent/data")
        try box.file("Library/Caches/com.apple.iconservices/store")
        try box.file("Library/Caches/com.apple.bootstamps/x")
        try box.file("var/log/system.log")
        try box.file("var/log/system.log.0.gz")
        try box.file("var/log/install.log.1")
        try box.file("Other/keep.txt")
        try FileManager.default.createSymbolicLink(atPath: box.path + "/Library/Caches/link", withDestinationPath: box.path + "/Other")
        return box
    }

    @Test func scanOffersOnlyWhatTheRulesAllow() throws {
        let box = try setUp()
        let found = SystemCleanRules.scan(roots: roots(box))
        let rel = Set(found.map { String($0.path.dropFirst(box.path.count + 1)) })
        #expect(rel == ["Library/Caches/com.vendor.Agent", "Library/Caches/com.apple.iconservices", "var/log/system.log.0.gz", "var/log/install.log.1"])
        #expect(found.first { $0.name == "com.apple.iconservices" }?.safety == .review)
        #expect(found.first { $0.name == "com.vendor.Agent" }?.safety == .safe)
    }

    @Test func removalRefusesAnythingOutsideTheRules() throws {
        let box = try setUp()
        let r = roots(box)
        let report = SystemCleanRules.remove([
            box.path + "/Library/Caches/com.vendor.Agent", box.path + "/var/log/system.log.0.gz",
            box.path + "/var/log/system.log", box.path + "/Library/Caches/com.apple.bootstamps",
            box.path + "/Library/Caches/link", box.path + "/Other/keep.txt", box.path + "/Library/Caches",
            box.path + "/Library/Caches/../../Other/keep.txt", box.path + "/Library/Caches/com.vendor.Agent/data",
        ], roots: r)
        #expect(Set(report.removed.map { String($0.dropFirst(box.path.count + 1)) }) == ["Library/Caches/com.vendor.Agent", "var/log/system.log.0.gz"])
        #expect(report.refused.count == 7)
        #expect(report.bytes > 0)
        #expect(box.exists("var/log/system.log"))
        #expect(box.exists("Other/keep.txt"))
        #expect(box.exists("Library/Caches/com.apple.bootstamps/x"))
        #expect(box.exists("Library/Caches/link"))
        #expect(!box.exists("Library/Caches/.mymole-removing"))
    }

    @Test func theToolRefusesWhatTheKeepListProtects() throws {
        let box = try setUp()
        let agent = box.path + "/Library/Caches/com.vendor.Agent"
        // Kept inside the chosen item: the item itself is refused.
        let report = SystemCleanRules.remove(
            [agent, box.path + "/var/log/system.log.0.gz"], keep: CleanKeepList(paths: [agent + "/data"]), roots: roots(box))
        #expect(report.refused == [agent])
        #expect(report.removed == [box.path + "/var/log/system.log.0.gz"])
        #expect(box.exists("Library/Caches/com.vendor.Agent/data"))
    }

    /// /private/var/log is a real root, written as macOS writes it. Paths are
    /// compared as written, without `standardizingPath`, which drops "/private".
    @Test func rootsUnderPrivateWork() throws {
        let box = try setUp()
        let real = try #require(realpath(box.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        try #require(real.hasPrefix("/private/"))
        let roots = [SystemCleanRules.Root(path: real + "/var/log", rotatedLogsOnly: true, reason: "log")]
        #expect(SystemCleanRules.scan(roots: roots).map(\.name).sorted() == ["install.log.1", "system.log.0.gz"])
        let report = SystemCleanRules.remove([real + "/var/log/system.log.0.gz", real + "/var/log/./system.log"], roots: roots)
        #expect(report.removed == [real + "/var/log/system.log.0.gz"])
        #expect(report.refused == [real + "/var/log/./system.log"])
        #expect(box.exists("var/log/system.log"))
    }

    @Test func aStagingFolderOthersCouldReachStopsRemoval() throws {
        let box = try setUp()
        try FileManager.default.createDirectory(
            atPath: box.path + "/Library/Caches/.mymole-removing", withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o777])
        let report = SystemCleanRules.remove([box.path + "/Library/Caches/com.vendor.Agent"], roots: roots(box))
        #expect(report.removed.isEmpty && report.failed.count == 1)
        #expect(box.exists("Library/Caches/com.vendor.Agent/data"))
        #expect(!SystemCleanRules.scan(roots: roots(box)).contains { $0.name == ".mymole-removing" })
    }
}

/// Randomized paths against what root may remove; nothing is removed.
@Suite struct SystemCleanFuzzTests {
    @Test(arguments: 0..<400)
    func rootOnlyEverRemovesDirectEntriesOfItsRoots(seed: Int) throws {
        var state = UInt64(seed) &+ 60_000
        func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
        let box = try Box()
        try box.file("Library/Caches/com.vendor.Agent/data")
        try box.file("Library/Caches/com.apple.bootstamps/x")
        try box.file("var/log/system.log")
        try box.file("var/log/system.log.0.gz")
        try box.file("Other/keep.txt")
        try FileManager.default.createSymbolicLink(atPath: box.path + "/Library/Caches/link", withDestinationPath: box.path + "/Other")
        let roots = [
            SystemCleanRules.Root(path: box.path + "/Library/Caches", reason: "cache"),
            SystemCleanRules.Root(path: box.path + "/var/log", rotatedLogsOnly: true, reason: "log"),
        ]
        let parts = ["Library", "Caches", "var", "log", "..", ".", "", "link", "Other", "keep.txt", "com.vendor.Agent",
                     "com.apple.bootstamps", "system.log", "system.log.0.gz", "data", ".mymole-removing"]
        let p = box.path + "/" + (0..<(1 + next(6))).map { _ in parts[next(parts.count)] }.joined(separator: "/")
        guard SystemCleanRules.allowed(p, roots: roots) else { return }
        let parent = (p as NSString).deletingLastPathComponent
        let name = (p as NSString).lastPathComponent
        #expect(roots.contains { $0.path == parent }, "seed \(seed): \(p)")
        #expect((p as NSString).standardizingPath == p, "seed \(seed): \(p)")
        #expect(!["link", "com.apple.bootstamps", ".mymole-removing", "system.log"].contains(name), "seed \(seed): \(p)")
    }
}

/// The privileged tool: what it reads, what it refuses, and its answer.
@Suite struct PrivilegedToolTests {
    @Test func requestsAndRepliesSurviveTheTrip() throws {
        for request in [
            PrivilegedRequest.maintenance(tasks: ["flushDNS"], dryRun: true),
            .removeSystem(paths: ["/synthetic/a", "/synthetic/b c"], keep: ["/synthetic/k"]),
            .removeLeftovers(paths: ["/synthetic/x"], appID: "com.vendor.Editor", ids: ["com.vendor.Editor.Helper"]),
        ] {
            let arg = PrivilegedTool.argument(for: PrivilegedEnvelope(request: request))
            let back = try JSONDecoder().decode(PrivilegedEnvelope.self, from: try #require(Data(base64Encoded: arg)))
            #expect(back.request == request && back.version == PrivilegedTool.version)
        }
        let reply = PrivilegedReply.reports([TaskReport(.flushDNS, .done)])
        #expect(PrivilegedTool.reply(from: PrivilegedTool.output(reply) + "\n") == reply)
        #expect(MaintenanceTask.allCases.filter(\.needsRoot) == [.flushDNS, .periodic, .spotlight, .verifyDisk])
    }

    @Test func nothingRunsUnlessTheRequestReadsMatchesAndRunsAsRoot() {
        let fake = FakeRunner()
        let ok = PrivilegedTool.argument(for: PrivilegedEnvelope(request: .maintenance(tasks: ["flushDNS"], dryRun: false)))
        let old = PrivilegedTool.argument(for: PrivilegedEnvelope(version: "1", request: .maintenance(tasks: ["flushDNS"], dryRun: false)))
        for (arg, root) in [("not base64!", true), (Data("{}".utf8).base64EncodedString(), true), (old, true), (ok, false)] {
            guard case .refused = PrivilegedTool.handle(argument: arg, isRoot: root, runner: fake.runner) else {
                Issue.record("ran: \(arg.prefix(20)) root=\(root)")
                continue
            }
        }
        #expect(fake.calls.withLock { $0 }.isEmpty)
    }

    @Test func asRootItRunsOnlyRootTasksThroughItsRunner() throws {
        let box = try Box()
        let fake = FakeRunner(codes: ["/usr/bin/killall": 1])
        let arg = PrivilegedTool.argument(for: PrivilegedEnvelope(request: .maintenance(tasks: ["flushDNS", "quickLook"], dryRun: false)))
        #expect(PrivilegedTool.handle(argument: arg, isRoot: true, runner: fake.runner, lockPath: box.path + "/tool.lock")
            == .reports([TaskReport(.flushDNS, .done)]))
        #expect(fake.calls.withLock { $0 }.map(\.first) == ["/usr/bin/dscacheutil", "/usr/bin/killall"])
    }

    @Test func aSecondCopyOfTheToolRefusesWhileTheFirstIsAtWork() throws {
        let box = try Box()
        let lockPath = box.path + "/tool.lock"
        let fake = FakeRunner()
        let arg = PrivilegedTool.argument(for: PrivilegedEnvelope(request: .maintenance(tasks: ["flushDNS"], dryRun: false)))
        // A lock is held per open file, so a second open in this process
        // stands in for a second copy of the tool.
        let first = try #require(ToolLock(path: lockPath))
        guard case .refused = PrivilegedTool.handle(argument: arg, isRoot: true, runner: fake.runner, lockPath: lockPath) else {
            Issue.record("a second copy ran")
            return
        }
        #expect(fake.calls.withLock { $0 }.isEmpty)
        first.release()
        #expect(PrivilegedTool.handle(argument: arg, isRoot: true, runner: fake.runner, lockPath: lockPath) == .reports([TaskReport(.flushDNS, .done)]))
    }

    @Test func theLockIsNeverALinkOrAFileOthersMayWrite() throws {
        let box = try Box()
        let target = try box.file("target")
        try FileManager.default.createSymbolicLink(atPath: box.path + "/link.lock", withDestinationPath: target)
        #expect(ToolLock(path: box.path + "/link.lock") == nil)
        let open = try box.file("open.lock")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: open)
        #expect(ToolLock(path: open) == nil)
    }
}

/// Runs only tiny programs of the test's own; no system tool is touched.
@Suite struct CommandRunnerTests {
    @Test func returnsOutputAndExitCode() {
        let r = CommandRunner.processes(timeLimit: 10).run("/bin/echo", ["synthetic"])
        #expect(r.code == 0 && r.output == "synthetic\n")
    }

    @Test func stopsAProgramPastItsTimeLimit() {
        let start = Date()
        let r = CommandRunner.processes(timeLimit: 0.3).run("/bin/sleep", ["30"])
        #expect(r.code == CommandRunner.timedOut)
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
