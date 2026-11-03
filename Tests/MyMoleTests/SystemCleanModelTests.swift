import Foundation
import PrivilegedKit
import StorageKit
import Testing

@testable import MyMole

/// The helper is replaced: what it would find, and a record of what it
/// would be asked to remove. The keep list lives in the test's own folder.
@MainActor
@Suite struct SystemCleanModelTests {
    final class Asked {
        var removed: [[String]] = []
        var keep: [CleanKeepList] = []
        /// Holds the removal until let go, as the administrator prompt would.
        var gate: CheckedContinuation<Void, Never>?
        var holds = false
    }

    let dir = FileManager.default.temporaryDirectory.appending(path: "sysclean-\(UUID().uuidString)")
    var keepURL: URL { dir.appending(path: "keep.json") }

    static let found = [
        SystemCandidate(path: "/Library/Caches/com.vendor.Tool", bytes: 100, modified: .now, safety: .safe, reason: "cache"),
        SystemCandidate(path: "/Library/Caches/com.vendor.Kept", bytes: 200, modified: .now, safety: .safe, reason: "cache"),
        SystemCandidate(path: "/Library/Logs/Vendor", bytes: 300, modified: .now, safety: .review, reason: "logs"),
    ]

    func model(asked: Asked) -> SystemCleanModel {
        let backend = SystemCleanModel.Backend(
            isReady: { true },
            scan: { Self.found },
            remove: { paths, keep in
                if asked.holds { await withCheckedContinuation { asked.gate = $0 } }
                asked.removed.append(paths)
                asked.keep.append(keep)
                var r = RemovalReport()
                r.removed = paths
                return r
            })
        return SystemCleanModel(
            privileged: PrivilegedClient(toolPath: nil), logURL: dir.appending(path: "history.json"),
            keepURL: keepURL, backend: backend)
    }

    @Test func keptItemsAreNeverChosenOrSentToTheHelper() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try CleanKeepList(paths: ["/Library/Caches/com.vendor.Kept"]).save(to: keepURL)
        let asked = Asked()
        let m = model(asked: asked)
        m.scan()
        await m.scanJob?.value
        #expect(m.chosen == ["/Library/Caches/com.vendor.Tool"])
        m.toggle("/Library/Caches/com.vendor.Kept")
        m.choose(Self.found.map(\.path))
        #expect(!m.chosen.contains("/Library/Caches/com.vendor.Kept"))

        // Kept from another window after the scan: still never sent.
        try CleanKeepList(paths: ["/Library/Caches/com.vendor.Kept", "/Library/Logs"]).save(to: keepURL)
        m.removeChosen()
        await m.removeJob?.value
        #expect(asked.removed == [["/Library/Caches/com.vendor.Tool"]])
        #expect(m.lastResult?.contains("1 kept") == true)
    }

    @Test func anUnreadableKeepListStopsTheRun() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let asked = Asked()
        let m = model(asked: asked)
        m.scan()
        await m.scanJob?.value
        #expect(!m.chosen.isEmpty)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: keepURL)
        m.removeChosen()
        await m.removeJob?.value
        #expect(asked.removed.isEmpty)
        #expect(m.keepError != nil)
        #expect(m.removeBlocker == "The keep list couldn't be read.")
        // Nor is the list changed while it can't be read.
        m.keepAlways(["/Library/Logs/Vendor"])
        #expect(try Data(contentsOf: keepURL) == Data("not json".utf8))
    }

    @Test func aListThatFailsAtLaunchBlocksUntilItLoads() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: keepURL)
        let m = model(asked: Asked())
        #expect(m.keepError != nil)
        try FileManager.default.removeItem(at: keepURL)
        m.reloadKeepList()
        #expect(m.keepError == nil)
        m.keepAlways(["/Library/Logs/Vendor"])
        #expect(try CleanKeepList.load(from: keepURL).paths == ["/Library/Logs/Vendor"])
        m.stopKeeping(["/Library/Logs/Vendor"])
        #expect(try CleanKeepList.load(from: keepURL).paths.isEmpty)
    }

    @Test func theToolGetsTheKeepListAndItCantChangeWhileTheRunWaits() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try CleanKeepList(paths: ["/Library/Caches/com.vendor.Kept"]).save(to: keepURL)
        let asked = Asked()
        asked.holds = true
        let m = model(asked: asked)
        m.scan()
        await m.scanJob?.value
        m.removeChosen()
        while asked.gate == nil { await Task.yield() }
        // While the prompt is up, the list stays as the run was checked against.
        m.stopKeeping(["/Library/Caches/com.vendor.Kept"])
        #expect(m.error != nil && m.keep.paths == ["/Library/Caches/com.vendor.Kept"])
        #expect(try CleanKeepList.load(from: keepURL).paths == ["/Library/Caches/com.vendor.Kept"])
        asked.gate?.resume()
        await m.removeJob?.value
        #expect(asked.keep == [CleanKeepList(paths: ["/Library/Caches/com.vendor.Kept"])])
    }

    @Test func aKeepChangeThatCantBeSavedStopsTheNextRun() async throws {
        let locked = dir.appending(path: "locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = locked.appending(path: "keep.json")
        try CleanKeepList().save(to: url)
        try Data().write(to: URL(fileURLWithPath: url.path + ".lock"))
        let asked = Asked()
        let m = SystemCleanModel(
            privileged: PrivilegedClient(toolPath: nil), logURL: dir.appending(path: "history.json"), keepURL: url,
            backend: .init(isReady: { true }, scan: { Self.found }, remove: { p, _ in asked.removed.append(p); return RemovalReport() }))
        m.scan()
        await m.scanJob?.value
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        m.keepAlways(["/Library/Logs/Vendor"])
        #expect(m.keepSaveError != nil && m.keepError == nil)
        // Protected in the app right away, but nothing is removed.
        #expect(m.keep.protects("/Library/Logs/Vendor"))
        #expect(m.removeBlocker == "A change to the keep list hasn't been saved.")
        m.removeChosen()
        await m.removeJob?.value
        #expect(asked.removed.isEmpty)
        // Saved once the folder can be written again.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        m.reloadKeepList()
        #expect(m.keepSaveError == nil && m.removeBlocker == nil)
        #expect(try CleanKeepList.load(from: url).paths == ["/Library/Logs/Vendor"])
    }

    @Test func anUnsavedChangeCanBeGivenUp() async throws {
        let locked = dir.appending(path: "locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = locked.appending(path: "keep.json")
        try CleanKeepList(paths: ["/Library/Caches/com.vendor.Kept"]).save(to: url)
        try Data().write(to: URL(fileURLWithPath: url.path + ".lock"))
        let m = SystemCleanModel(
            privileged: PrivilegedClient(toolPath: nil), logURL: dir.appending(path: "history.json"), keepURL: url,
            backend: .init(isReady: { true }, scan: { Self.found }, remove: { _, _ in RemovalReport() }))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        m.stopKeeping(["/Library/Caches/com.vendor.Kept"])
        #expect(m.keepSaveError != nil && !m.keep.protects("/Library/Caches/com.vendor.Kept"))
        m.discardKeepChange()
        #expect(m.keepSaveError == nil && m.keep.protects("/Library/Caches/com.vendor.Kept"))
    }

    @Test func whereARemainderWasLeftReachesTheUser() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = "/Library/Caches/.mymole-removing/job/remainder"
        let m = SystemCleanModel(
            privileged: PrivilegedClient(toolPath: nil), logURL: dir.appending(path: "history.json"), keepURL: keepURL,
            backend: .init(isReady: { true }, scan: { Self.found }, remove: { paths, _ in
                var r = RemovalReport()
                r.failed[paths[0]] = "Part of it couldn't be removed; what was left is kept at \(staged)."
                return r
            }))
        m.scan()
        await m.scanJob?.value
        m.removeChosen()
        await m.removeJob?.value
        #expect(m.problems.count == 1 && m.problems[0].reason.contains(staged))
        #expect(m.lastResult?.hasPrefix("Nothing was removed · 1 couldn't be removed") == true)
        #expect(problemText(m.problems).contains(staged))
        m.dismissProblems()
        #expect(m.problems.isEmpty)
    }

    @Test func anotherWindowCantChangeTheListWhileARemovalRuns() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try CleanKeepList(paths: ["/Library/Caches/com.vendor.Kept"]).save(to: keepURL)
        let asked = Asked()
        asked.holds = true
        let running = model(asked: asked)
        let other = model(asked: Asked())
        running.scan()
        await running.scanJob?.value
        running.removeChosen()
        while asked.gate == nil { await Task.yield() }
        // The other window's change isn't saved, and says so; it still
        // protects there, and blocks removal there until it's saved.
        other.stopKeeping(["/Library/Caches/com.vendor.Kept"])
        #expect(other.keepSaveError != nil && other.removeBlocker != nil)
        #expect(try CleanKeepList.load(from: keepURL).paths == ["/Library/Caches/com.vendor.Kept"])
        asked.gate?.resume()
        await running.removeJob?.value
        other.reloadKeepList()
        #expect(other.keepSaveError == nil)
        #expect(try CleanKeepList.load(from: keepURL).paths.isEmpty)
    }
}
