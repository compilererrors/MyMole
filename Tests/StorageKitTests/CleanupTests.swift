import Foundation
import Testing

@testable import StorageKit

@Suite struct CleanScannerTests {
    /// A home folder with caches, logs and tool downloads where tools put them.
    private func home() throws -> Sandbox {
        let box = try Sandbox()
        try box.file("Library/Caches/com.vendor.Editor/blob", bytes: 40_000)
        try box.file("Library/Caches/CloudKit/db", bytes: 20_000)
        try box.file("Library/Caches/.DS_Store", bytes: 6_000)
        try box.file("Library/Logs/tool.log", bytes: 3_000)
        try box.file("Library/Logs/DiagnosticReports/crash.ips", bytes: 5_000)
        try box.file(".npm/_cacache/content/x", bytes: 12_000)
        try box.file(".cache/model-hub/weights.bin", bytes: 50_000)
        try box.file("Library/Containers/com.vendor.Notes/Data/Library/Caches/c", bytes: 8_000)
        try box.file("Library/Containers/com.vendor.Notes/Data/Documents/mine.txt", bytes: 9_000)
        try box.file("Library/Containers/com.apple.Maps/Data/Library/Caches/tiles", bytes: 7_000)
        try box.folder("Library/Containers/com.vendor.Empty/Data/Library/Caches")
        try box.file("Documents/notes.txt", bytes: 9_000)
        try FileManager.default.createSymbolicLink(
            atPath: box.path + "/Library/Caches/linked", withDestinationPath: box.path + "/Documents")
        return box
    }

    @Test func findsWhatTheRulesNameAndNothingElse() throws {
        let box = try home()
        let found = CleanScanner.scan(home: box.path, workers: 2)
        let byName = Dictionary(uniqueKeysWithValues: found.map { (String($0.path.dropFirst(box.path.count + 1)), $0) })
        #expect(Set(byName.keys) == [
            "Library/Caches/com.vendor.Editor", "Library/Caches/CloudKit", "Library/Logs/tool.log",
            "Library/Logs/DiagnosticReports", ".npm/_cacache", ".cache/model-hub",
            "Library/Containers/com.vendor.Notes/Data/Library/Caches",
            "Library/Containers/com.apple.Maps/Data/Library/Caches",
        ])
        let editor = try #require(byName["Library/Caches/com.vendor.Editor"])
        #expect(editor.safety == .safe && editor.owner == "com.vendor.Editor" && editor.category == .appCaches)
        #expect(editor.bytes == box.allocated("Library/Caches/com.vendor.Editor/blob"))
        #expect(byName["Library/Caches/CloudKit"]?.safety == .review)
        #expect(byName[".cache/model-hub"]?.safety == .review)
        #expect(byName[".npm/_cacache"]?.contentsOnly == true)
        let notes = try #require(byName["Library/Containers/com.vendor.Notes/Data/Library/Caches"])
        #expect(notes.owner == "com.vendor.Notes" && notes.safety == .safe && notes.contentsOnly)
        #expect(byName["Library/Containers/com.apple.Maps/Data/Library/Caches"]?.safety == .review)
        #expect(found.first?.name == "model-hub")
    }

    @Test func aCancelledScanStops() throws {
        let box = try home()
        let p = ScanProgress()
        p.cancel()
        #expect(CleanScanner.scan(home: box.path, progress: p, workers: 1).isEmpty)
    }

    @Test func isCheckedAgainBeforeTheTrash() throws {
        let box = try home()
        let h = box.path
        #expect(CleanScanner.isStillCandidate(h + "/Library/Caches/com.vendor.Editor", home: h))
        #expect(CleanScanner.isStillCandidate(h + "/.npm/_cacache", home: h))
        #expect(CleanScanner.isStillCandidate(h + "/Library/Containers/com.vendor.Notes/Data/Library/Caches", home: h))
        // Not a rule's place, a link, the target itself, or a sneaky path.
        #expect(!CleanScanner.isStillCandidate(h + "/Library/Containers/com.vendor.Notes/Data/Documents", home: h))
        #expect(!CleanScanner.isStillCandidate(h + "/Library/Caches/linked", home: h))
        #expect(!CleanScanner.isStillCandidate(h + "/Library/Caches", home: h))
        #expect(!CleanScanner.isStillCandidate(h + "/Library/Caches/../../Documents", home: h))
        #expect(!CleanScanner.isStillCandidate(h + "/Library/Caches/.DS_Store", home: h))
        #expect(!CleanScanner.isStillCandidate(h + "/Library/Caches/gone", home: h))
    }

    @Test func readsTheNamesOfRunningPrograms() throws {
        // This test process itself is running, so its own name is listed.
        let names = try #require(RunningTools.names())
        #expect(!names.isEmpty)
        #expect(RunningTools.parts("/opt/tool/lib/npm-cli.js").contains("npm-cli"))
        #expect(RunningTools.parts("org.gradle.launcher.daemon.bootstrap.GradleDaemon").contains("GradleDaemon"))
        #expect(CleanRules.inUse("/h/.yarn/berry/cache", home: "/h", running: ["yarn-4"]))
        #expect(!CleanRules.inUse("/h/.yarn/berry/cache", home: "/h", running: ["yarnish"]))
        #expect(CleanRules.inUse("/h/.cargo/registry/cache", home: "/h", running: nil))
        #expect(!CleanRules.inUse("/h/Library/Caches/com.vendor.App", home: "/h", running: nil))
    }

    @Test func toolCacheHoldingATokenIsNeverOffered() throws {
        let box = try home()
        let h = box.path
        try box.file(".cache/hub-client/token", bytes: 100)
        try box.file(".cache/cli/config/auth/session-credentials.json", bytes: 100)
        try box.file(".cache/deep/a/b/c/d/e/key.pem", bytes: 100)
        // Model caches nest a few levels; nothing secret is still offered.
        try box.file(".cache/models/hub/models--org--name/snapshots/0a1b/weights.bin", bytes: 100)
        // Nested deeper than the search looks: counts as holding a secret.
        try box.file(".cache/abyss/1/2/3/4/5/6/7/8/9/file", bytes: 100)
        let found = Set(CleanScanner.scan(home: h, workers: 2).map(\.path))
        #expect(found.contains(h + "/.cache/model-hub"))
        #expect(found.contains(h + "/.cache/models"))
        #expect(!found.contains(h + "/.cache/hub-client"))
        #expect(!found.contains(h + "/.cache/cli"))
        #expect(!found.contains(h + "/.cache/deep"))
        #expect(!found.contains(h + "/.cache/abyss"))
        #expect(!CleanScanner.isStillCandidate(h + "/.cache/hub-client", home: h))
        #expect(CleanScanner.isStillCandidate(h + "/.cache/model-hub", home: h))
    }

    @Test func toolCacheTooBigToLookThroughIsNotOffered() throws {
        let box = try home()
        for i in 0..<30 { try box.file(".cache/wide/f\(i)", bytes: 1) }
        #expect(!CleanRules.holdsSecrets(box.path + "/.cache/wide"))
        #expect(CleanRules.holdsSecrets(box.path + "/.cache/wide", limit: 20))
    }

    @Test func folderSwappedForALinkIsRefused() throws {
        let box = try home()
        let h = box.path
        try box.file("Documents/models/weights.bin", bytes: 1_000)
        #expect(CleanScanner.isStillCandidate(h + "/.cache/model-hub", home: h))
        try FileManager.default.removeItem(atPath: h + "/.cache")
        try FileManager.default.createSymbolicLink(atPath: h + "/.cache", withDestinationPath: h + "/Documents")
        #expect(!CleanScanner.isStillCandidate(h + "/.cache/models", home: h))
    }

    @Test func keptItemsAreLeftOutEvenInsideAChosenFolder() throws {
        let box = try home()
        let h = box.path
        try box.file(".npm/_cacache/index/y", bytes: 1_000)
        let npm = try #require(CleanScanner.scan(home: h, workers: 1).first { $0.path == h + "/.npm/_cacache" })
        #expect(CleanScanner.trashPaths(for: npm, keep: CleanKeepList()) == [h + "/.npm/_cacache/content", h + "/.npm/_cacache/index"])
        let keep = CleanKeepList(paths: [h + "/.npm/_cacache/index/y"])
        #expect(CleanScanner.trashPaths(for: npm, keep: keep) == [h + "/.npm/_cacache/content"])

        let editor = CleanCandidate(
            path: h + "/Library/Caches/com.vendor.Editor", bytes: 1, modified: Date(), category: .appCaches, safety: .safe,
            owner: nil, reason: "")
        #expect(CleanScanner.trashPaths(for: editor, keep: CleanKeepList(paths: [editor.path + "/blob"])).isEmpty)
        #expect(CleanScanner.trashPaths(for: editor, keep: CleanKeepList(paths: [h + "/Library"])).isEmpty)
        #expect(CleanScanner.trashPaths(for: editor, keep: CleanKeepList(paths: [h + "/Library/Caches/com.vendor"])) == [editor.path])
    }
}

@Suite struct CleanStorageTests {
    @Test func keepListThatCantBeReadThrows() throws {
        let box = try Sandbox()
        let url = box.url.appending(path: "keep.json")
        #expect(try CleanKeepList.load(from: url) == CleanKeepList())
        try CleanKeepList(paths: ["/synthetic/a"]).save(to: url)
        #expect(try CleanKeepList.load(from: url).paths == ["/synthetic/a"])
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try CleanKeepList.load(from: url) }
    }

    @Test func keepListBehindFolderThatCantBeSearchedThrows() throws {
        let box = try Sandbox()
        let dir = box.url.appending(path: "locked")
        let url = dir.appending(path: "keep.json")
        try CleanKeepList(paths: ["/synthetic/a"]).save(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        #expect(throws: (any Error).self) { try CleanKeepList.load(from: url) }
    }

    @Test func savedScanIsTiedToItsHome() throws {
        let box = try Sandbox()
        let c = CleanCandidate(
            path: "/synthetic/home/Library/Caches/x", bytes: 10, modified: Date(timeIntervalSince1970: 1_790_000_000),
            category: .appCaches, safety: .safe, owner: nil, reason: "r")
        CleanStore.save(CleanListing(candidates: [c]), home: "/synthetic/home", base: box.url)
        #expect(CleanStore.load(home: "/synthetic/home", base: box.url)?.candidates == [c])
        #expect(CleanStore.load(home: "/synthetic/other", base: box.url) == nil)
    }

    @Test func cleanupLogKeepsCountsAndUndo() throws {
        let box = try Sandbox()
        let url = box.url.appending(path: "history.json")
        CleanupLog.submit(CleanupRecord(source: "Deep Clean", items: 0, bytes: 0, failed: 0), to: url)
        #expect(CleanupLog.load(from: url).isEmpty)
        let a = CleanupRecord(date: Date(timeIntervalSince1970: 1), source: "Installers", items: 2, bytes: 100, failed: 0)
        let b = CleanupRecord(date: Date(timeIntervalSince1970: 2), source: "Deep Clean", items: 5, bytes: 900, failed: 1)
        CleanupLog.submit(a, to: url)
        CleanupLog.submit(b, to: url)
        // Submitted right after its run: the Undo lands after the run, never before.
        CleanupLog.submitRestore(a.id, restored: 2, bytes: 100, failed: 0, in: url)
        let after = CleanupLog.load(from: url)
        #expect(after.map(\.id) == [b.id, a.id])
        #expect(after.first { $0.id == a.id }?.undone == true)
        #expect(after.filter(\.freedSomething).map(\.id) == [b.id])
    }

    @Test func partialUndoAndPermanentDeletionStayVisible() throws {
        let box = try Sandbox()
        let url = box.url.appending(path: "history.json")
        let r = CleanupRecord(source: "Uninstall", items: 3, bytes: 900, failed: 0, deleted: 2)
        CleanupLog.submit(r, to: url)
        CleanupLog.submitRestore(r.id, restored: 3, bytes: 900, failed: 0, in: url)
        let all = CleanupLog.load(from: url)
        let back = try #require(all.first)
        // Everything moved came back, but what was deleted didn't.
        #expect(!back.undone && back.partlyUndone && back.freedSomething && back.deleted == 2)

        let s = CleanupRecord(source: "Deep Clean", items: 4, bytes: 400, failed: 0)
        CleanupLog.submit(s, to: url)
        CleanupLog.submitRestore(s.id, restored: 1, bytes: 100, failed: 3, in: url)
        let partly = try #require(CleanupLog.load(from: url).first { $0.id == s.id })
        #expect(partly.partlyUndone && partly.restoreFailed == 3 && partly.freedBytes == 300)
    }

    @Test func oldRecordsStillRead() throws {
        let box = try Sandbox()
        let url = box.url.appending(path: "history.json")
        let old = #"[{"id":"00000000-0000-0000-0000-000000000001","date":0,"source":"Installers","items":2,"bytes":10,"failed":0,"undone":true}]"#
        try Data(old.utf8).write(to: url)
        let r = try #require(CleanupLog.load(from: url).first)
        #expect(r.undone && r.restored == 2 && r.deleted == 0)
    }
}
