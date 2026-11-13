import CoreGraphics
import Darwin
import Foundation
import Synchronization
import Testing

@testable import StorageKit

/// A throwaway directory tree, removed on deinit.
final class Sandbox {
    let url: URL
    var path: String { url.path }

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "storagekit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ rel: String, bytes: Int) throws -> URL {
        let u = url.appending(path: rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Random bytes so APFS can't compress them away.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: u)
        return u
    }

    func folder(_ rel: String) throws {
        try FileManager.default.createDirectory(at: url.appending(path: rel), withIntermediateDirectories: true)
    }

    /// What the disk says a file costs (allocated blocks), like `du`.
    func allocated(_ rel: String) -> Int64 {
        var st = stat()
        lstat(url.appending(path: rel).path, &st)
        return Int64(st.st_blocks) * 512
    }
}

@Suite struct ScannerTests {
    @Test func sizesMatchAllocatedBlocks() throws {
        let box = try Sandbox()
        try box.file("a.txt", bytes: 10_000)
        try box.file("sub/b.bin", bytes: 2_000_000)
        try box.file("sub/deeper/c.jpg", bytes: 300_000)
        try box.folder("empty")

        let r = StorageScanner.scan(path: box.path)
        let expected = box.allocated("a.txt") + box.allocated("sub/b.bin") + box.allocated("sub/deeper/c.jpg")
        #expect(r.root.size == expected)
        #expect(r.root.fileCount == 3)
        let sub = try #require(r.root.subfolders.first { $0.name == "sub" })
        #expect(sub.size == box.allocated("sub/b.bin") + box.allocated("sub/deeper/c.jpg"))
        // ≥ 1 MB is listed on its own; smaller files are only summed.
        #expect(sub.listedFiles.map(\.name) == ["b.bin"])
        #expect(r.root.listedFiles.isEmpty && r.root.smallFileCount == 1)
        #expect(r.root.find(path: box.path + "/sub/deeper")?.name == "deeper")
    }

    /// A top-level folder with thousands of subfolders: workers finish its
    /// children while the folder that queued them is still being counted,
    /// which once closed the subtree early with most of it unread.
    @Test func wideSubtreesAreFinishedOnlyWhenComplete() throws {
        let box = try Sandbox()
        for i in 0..<3_000 { try box.file("wide/d\(i)/f", bytes: 1) }
        let expected = StorageScanner.scan(path: box.path + "/wide").root.size
        // Several scans at once oversubscribe the cores, as in the app,
        // where the disk map, the projects and the cleaners all scan together.
        let sizes = Mutex([Int64]())
        let path = box.path
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let r = StorageScanner.scan(path: path)
            sizes.withLock { $0.append(r.root.subfolders.first?.size ?? -1) }
        }
        #expect(sizes.withLock { $0 } == Array(repeating: expected, count: 8))
    }

    @Test func fewerWorkersGiveTheSameResult() throws {
        let box = try Sandbox()
        for i in 0..<200 { try box.file("t\(i % 7)/d\(i)/f", bytes: 1_000 + i) }
        let full = StorageScanner.scan(path: box.path)
        for workers in [1, StorageScanner.backgroundWorkers] {
            let r = StorageScanner.scan(path: box.path, workers: workers)
            #expect(r.root.size == full.root.size && r.root.fileCount == 200)
        }
    }

    @Test func hardLinksCountOnceAndSymlinksNever() throws {
        let box = try Sandbox()
        let original = try box.file("one/data.bin", bytes: 1_500_000)
        try box.folder("two")
        try FileManager.default.linkItem(at: original, to: box.url.appending(path: "two/hardlink.bin"))
        try FileManager.default.createSymbolicLink(
            at: box.url.appending(path: "two/symlink.bin"), withDestinationURL: original)

        let r = StorageScanner.scan(path: box.path)
        #expect(r.root.size == box.allocated("one/data.bin"))
        #expect(r.root.fileCount == 1)
    }

    @Test func kindsAndRebuildableFolders() throws {
        let box = try Sandbox()
        try box.file("proj/package.json", bytes: 100)
        try box.file("proj/node_modules/x/index.js", bytes: 5_000)
        try box.file("proj/build/out.o", bytes: 5_000)
        try box.file("notes/build/readme.md", bytes: 100)  // no project file: not rebuildable
        try box.file("Photos/beach.HEIC", bytes: 50_000)

        let r = StorageScanner.scan(path: box.path)
        let proj = try #require(r.root.find(path: box.path + "/proj"))
        #expect(proj.subfolders.first { $0.name == "node_modules" }?.rebuildable != nil)
        #expect(proj.subfolders.first { $0.name == "build" }?.rebuildable != nil)
        #expect(r.root.find(path: box.path + "/notes/build")?.rebuildable == nil)
        #expect(r.root.totalBytes[.media] == box.allocated("Photos/beach.HEIC"))
        #expect(r.root.totalBytes[.developer] >= box.allocated("proj/node_modules/x/index.js"))
    }

    @Test func everyTopLevelSubtreeIsReportedOnce() throws {
        let box = try Sandbox()
        for i in 0..<6 { try box.file("top\(i)/n/f.bin", bytes: 4_000 * (i + 1)) }
        let seen = Mutex([String]())
        let r = StorageScanner.scan(path: box.path, onSubtree: { f in seen.withLock { $0.append(f.name) } })
        #expect(seen.withLock { $0.sorted() } == (0..<6).map { "top\($0)" })
        #expect(r.root.subfolders.allSatisfy { $0.isFinished })
    }

    @Test func unreadableFoldersAreDisclosed() throws {
        let box = try Sandbox()
        try box.file("locked/secret.txt", bytes: 100)
        chmod(box.url.appending(path: "locked").path, 0o000)
        defer { chmod(box.url.appending(path: "locked").path, 0o755) }
        let r = StorageScanner.scan(path: box.path)
        #expect(r.deniedPaths.contains { $0.hasSuffix("/locked") })
        #expect(r.root.find(path: box.path + "/locked")?.unreadable == true)
    }

    @Test func pruningUpdatesAncestors() throws {
        let box = try Sandbox()
        try box.file("a/b/big.bin", bytes: 2_000_000)
        try box.file("a/keep.txt", bytes: 1_000)
        let r = StorageScanner.scan(path: box.path)
        let a = try #require(r.root.find(path: box.path + "/a"))
        let b = try #require(a.subfolders.first)
        let before = r.root.size
        a.remove(b)
        #expect(r.root.size == before - box.allocated("a/b/big.bin"))
        #expect(a.size == box.allocated("a/keep.txt"))
    }
}

@Suite struct LayoutTests {
    @Test func squarifyFillsTheRectProportionally() {
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1, 0]
        let rect = CGRect(x: 10, y: 20, width: 600, height: 400)
        let rects = Squarify.layout(values, in: rect)
        let total = values.reduce(0, +)
        for (v, r) in zip(values, rects) {
            #expect(abs(Double(r.width * r.height) - v / total * 600 * 400) < 1)
            if v > 0 { #expect(rect.insetBy(dx: -0.5, dy: -0.5).contains(r)) }
        }
        // No two cells overlap.
        for i in rects.indices {
            for j in rects.indices where i < j {
                #expect(rects[i].intersection(rects[j]).width * rects[i].intersection(rects[j]).height < 0.5)
            }
        }
    }

    @Test func sunburstSpansTheFullCircle() throws {
        let box = try Sandbox()
        try box.file("a/x.bin", bytes: 3_000_000)
        try box.file("b/y.bin", bytes: 1_000_000)
        try box.file("loose.bin", bytes: 1_000_000)
        let r = StorageScanner.scan(path: box.path)
        let arcs = Sunburst.layout(r.root)
        let inner = arcs.filter { $0.depth == 1 }
        #expect(abs(inner.reduce(0) { $0 + ($1.end - $1.start) } - 2 * .pi) < 1e-9)
        #expect(inner.first?.segment.name == "a")  // largest first
        #expect(inner.contains { if case .files = $0.segment { true } else { false } })
        #expect(Sunburst.hit(arcs, ring: 1, angle: 0.01)?.segment.name == "a")
    }

    @Test func sunburstOfAHugeFolderIsQuick() {
        let root = Folder(name: "huge", parent: nil, rootPath: "/huge")
        root.subfolders = (0..<50_000).map { i in
            let f = Folder(name: "d\(i)", parent: root)
            f.ownBytes[.other] = Int64(1_000 + (i * 7919) % 90_000)
            return f
        }
        root.finish()
        let start = ContinuousClock.now
        let arcs = Sunburst.layout(root)
        #expect(ContinuousClock.now - start < .seconds(1))
        // Sub-pixel slivers are dropped, so the chart stays drawable.
        #expect(arcs.count < 2_000)
    }
}

@Suite struct SnapshotTests {
    @Test func changesReportTheFolderThatMoved() {
        let mb: Int64 = 1_048_576
        let old = Snapshot(rootPath: "/r", date: .distantPast, sizes: [
            "": 1000 * mb, "Library": 600 * mb, "Library/Caches": 100 * mb, "Movies": 300 * mb, "Old": 80 * mb,
        ])
        let new = Snapshot(rootPath: "/r", date: .now, sizes: [
            "": 1500 * mb, "Library": 1100 * mb, "Library/Caches": 600 * mb, "Movies": 300 * mb, "New": 70 * mb,
        ])
        let changes = old.changes(to: new)
        // Library's growth is all Caches, so only Caches is reported.
        #expect(changes.map(\.path) == ["Library/Caches", "Old", "New"])
        #expect(changes.first?.kind == .grew)
        #expect(changes.first { $0.path == "Old" }?.kind == .vanished)
        #expect(changes.first { $0.path == "New" }?.kind == .appeared)
    }

    @Test func whatAnIncompleteScanMissedIsNeverAChange() {
        let mb: Int64 = 1_048_576
        let full = Snapshot(rootPath: "/r", date: .distantPast, sizes: ["": 900 * mb, "Library": 600 * mb, "Movies": 300 * mb])
        // Library couldn't be read this time: it isn't reported as shrunk.
        let partial = Snapshot(
            rootPath: "/r", date: .now, sizes: ["": 500 * mb, "Library": 100 * mb, "Movies": 400 * mb], incomplete: true)
        #expect(full.changes(to: partial).map(\.path) == ["Movies"])
        // And from an incomplete older scan, nothing grew that it missed.
        let later = Snapshot(rootPath: "/r", date: .now, sizes: ["": 800 * mb, "Library": 600 * mb, "Movies": 200 * mb])
        #expect(partial.changes(to: later).map(\.path) == ["Movies"])
    }

    @Test func aBigNewFileIsNamedInsteadOfItsFolder() {
        let mb: Int64 = 1_048_576
        let old = Snapshot(rootPath: "/r", date: .distantPast, sizes: ["": 100 * mb, "Movies": 40 * mb])
        let new = Snapshot(
            rootPath: "/r", date: .now, sizes: ["": 4200 * mb, "Movies": 4140 * mb],
            files: ["Movies/holiday.mov": 4100 * mb])
        let changes = old.changes(to: new)
        #expect(changes.map(\.id) == ["f:Movies/holiday.mov"])
        #expect(changes.first?.kind == .appeared)
    }

    @Test func comparesOnlyWhatBothScansMeasured() {
        let mb: Int64 = 1_048_576
        // An old-format snapshot: 4 levels, no files.
        let old = Snapshot(rootPath: "/r", date: .distantPast, sizes: ["": 100 * mb, "a": 100 * mb],
                           folderDepth: 4, tracksFiles: false)
        let new = Snapshot(rootPath: "/r", date: .now,
                           sizes: ["": 100 * mb, "a": 100 * mb, "a/b/c/d/e": 90 * mb], files: ["a/x.bin": 60 * mb])
        #expect(old.changes(to: new).isEmpty)
    }

    @Test func aDeepExplanationHidesEveryAncestor() {
        let mb: Int64 = 1_048_576
        let old = Snapshot(rootPath: "/r", date: .distantPast, sizes: ["": 0, "vms": 1 * mb, "vms/0": 1 * mb])
        let new = Snapshot(rootPath: "/r", date: .now, sizes: ["": 0, "vms": 2001 * mb, "vms/0": 2001 * mb],
                           files: ["vms/0/data/Docker.raw": 2000 * mb])
        #expect(old.changes(to: new).map(\.id) == ["f:vms/0/data/Docker.raw"])
    }

    @Test func snapshotOfATreeKeepsBigFilesAtAnyDepth() throws {
        let box = try Sandbox()
        try box.file("a/b/c/d/e/f/g/deep.bin", bytes: 60 * 1_048_576)
        let r = StorageScanner.scan(path: box.path)
        let s = Snapshot(of: r.root)
        #expect(s.files["a/b/c/d/e/f/g/deep.bin"] != nil)
        #expect(s.sizes["a/b/c/d/e/f"] != nil)  // depth 6 is kept
        #expect(s.sizes["a/b/c/d/e/f/g"] == nil)  // depth 7 isn't
        #expect(s.totalSize == r.root.size)
    }

    @Test func historyKeepsNewestFirstAndPrunes() throws {
        let box = try Sandbox()
        let base = box.url
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<(SnapshotStore.keep + 3) {
            SnapshotStore.save(
                Snapshot(rootPath: "/Users/me", date: start + Double(i) * 60, sizes: ["": Int64(i)]), base: base)
        }
        let h = SnapshotStore.history(for: "/Users/me", base: base)
        #expect(h.count == SnapshotStore.keep)
        #expect(h.first.flatMap(SnapshotStore.load)?.totalSize == Int64(SnapshotStore.keep + 2))
        #expect(zip(h, h.dropFirst()).allSatisfy { $0.date > $1.date })
        #expect(SnapshotStore.history(for: "/Users/other", base: base).isEmpty)
    }

    @Test func legacySingleSnapshotIsMigrated() throws {
        let box = try Sandbox()
        let legacy = Snapshot(rootPath: "/Users/me", date: Date(timeIntervalSince1970: 1_790_000_000), sizes: ["": 5])
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        // The old format: one file named after the path, no "files" key.
        var json = try JSONSerialization.jsonObject(with: e.encode(legacy)) as! [String: Any]
        json["files"] = nil
        try JSONSerialization.data(withJSONObject: json)
            .write(to: box.url.appending(path: SnapshotStore.legacyKey("/Users/me") + ".json"))
        let h = SnapshotStore.history(for: "/Users/me", base: box.url)
        #expect(h.count == 1)
        #expect(h.first.flatMap(SnapshotStore.load)?.totalSize == 5)
    }
}

/// "The Trash" for a test: a folder of its own box.
func testBin(_ box: Sandbox) throws -> TrashBackend {
    try box.folder("Bin")
    return .folder(box.path + "/Bin")
}

@Suite struct TrashTests {
    @Test func movesToTrashAndBack() throws {
        let box = try Sandbox()
        let f = try box.file("victim.txt", bytes: 10)
        let out = Trasher.move([f.path], backend: try testBin(box))
        #expect(out.moved.count == 1 && out.failed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.path))
        #expect(Trasher.restore(out.moved).isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.path))
    }

    /// The real system Trash, run only on request (MYMOLE_REAL_TRASH=1),
    /// outside the guarded run, which keeps tests away from the user's Trash.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYMOLE_REAL_TRASH"] == "1"))
    func systemTrashAndBack() throws {
        let box = try Sandbox()
        let f = try box.file("victim.txt", bytes: 10)
        let out = Trasher.move([f.path])
        #expect(out.moved.count == 1 && out.failed.isEmpty)
        #expect(Trasher.restore(out.moved).isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.path))
    }

    @Test func refusesProtectedLocations() {
        let home = NSHomeDirectory()
        for p in ["/", "/System/Library", home, home + "/Library", home + "/Documents/"] {
            #expect(Trasher.isProtected(p), "\(p)")
        }
        #expect(!Trasher.isProtected(home + "/Library/Caches/com.example"))
        // Refused before any backend is asked; this one would fail the test.
        let out = Trasher.move([home], backend: TrashBackend { _ in
            Issue.record("A protected place reached the backend")
            return (nil, "unreachable")
        })
        #expect(out.moved.isEmpty && out.failed.count == 1)
    }

    @Test func secretsAndBackupsAreProtectedAtAnyDepth() {
        let home = "/Users/synthetic"
        for p in [
            home + "/Library/Keychains", home + "/Library/Keychains/login.keychain-db", home + "/.ssh/id_test",
            home + "/.gnupg", home + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Volumes/Backup/Backups.backupdb/Mac/Latest", "/Volumes/NAS/Mac.backupbundle",
        ] {
            #expect(Trasher.isProtected(p, home: home), "\(p)")
        }
        #expect(!Trasher.isProtected(home + "/.sshfs-cache", home: home))
        #expect(!Trasher.isProtected(home + "/Library/KeychainsBackup", home: home))
    }

    @Test func foldersHoldingSecretsAreProtectedToo() {
        let home = "/Users/synthetic"
        #expect(Trasher.isProtected(home + "/Library/Application Support", home: home))
        #expect(!Trasher.isProtected(home + "/Library/Application Support/com.vendor.App", home: home))
    }

    @Test func markingAParentWarnsAboutWhatItHolds() throws {
        let box = try Sandbox()
        try box.file("Application Support/Google/Chrome/Default/History", bytes: 2_000)
        try box.file("Application Support/Tool/data", bytes: 2_000)
        let root = StorageScanner.scan(path: box.path, workers: 2).root
        let support = try #require(root.find(path: box.path + "/Application Support"))
        #expect(PathRisk.inside(support)?.level == .caution)
        #expect(PathRisk.inside(support)?.reason.hasPrefix("Inside: A browser profile") == true)
        let tool = try #require(root.find(path: box.path + "/Application Support/Tool"))
        #expect(PathRisk.inside(tool) == nil)
    }

    @Test func credentialsAndBrowserProfilesWarn() {
        let home = "/Users/synthetic"
        #expect(PathRisk.of(home + "/.aws")?.level == .caution)
        #expect(PathRisk.of(home + "/.kube/config")?.level == .caution)
        #expect(PathRisk.of(home + "/Library/Application Support/Google/Chrome/Default")?.level == .caution)
        #expect(PathRisk.of(home + "/Library/Safari/History.db")?.level == .caution)
        #expect(PathRisk.of(home + "/Library/Caches/com.vendor.Tool") == nil)
    }

    @Test func syncedFoldersAndPhotosLibrariesWarn() {
        let home = "/Users/synthetic"
        let synced = PathRisk.of(home + "/Library/CloudStorage/Dropbox/Taxes")
        #expect(synced?.level == .caution && synced?.reason.contains("in the cloud") == true)
        #expect(PathRisk.of(home + "/Library/Mobile Documents/com~apple~CloudDocs/Notes")?.reason.contains("other devices") == true)
        // Named for what it is, not only as "your own files".
        #expect(PathRisk.of(home + "/Pictures/Photos Library.photoslibrary")?.reason.hasPrefix("A Photos library") == true)
        #expect(PathRisk.of(home + "/Pictures/Photos Library.photoslibrary/originals/0")?.level == .caution)
        // The folder of every synced service is never moved itself.
        #expect(Trasher.isProtected(home + "/Library/CloudStorage", home: home))
        #expect(!Trasher.isProtected(home + "/Library/CloudStorage/Dropbox/Old", home: home))
    }

    @Test func linkOnTheWayCantReachAProtectedLocation() throws {
        let box = try Sandbox()
        try FileManager.default.createSymbolicLink(atPath: box.path + "/sys", withDestinationPath: "/usr")
        #expect(Trasher.isProtectedResolved(box.path + "/sys/bin"))
        try box.file("mine/a", bytes: 1_000)
        #expect(!Trasher.isProtectedResolved(box.path + "/mine/a"))
        #expect(Trasher.isProtectedResolved(box.path + "/missing/a"))
        // The link itself is moved, not what it points to.
        #expect(!Trasher.isProtectedResolved(box.path + "/sys"))
    }

    /// The App Sandbox opens the granted home folder but not /Users, so a
    /// path in the home folder is walked from there; links still stop it.
    @Test func folderWalkStartsAtTheHomeFolder() throws {
        let box = try Sandbox()
        let root = try #require(Trasher.realPath(box.path))
        try box.folder("home/Library/Caches")
        try box.folder("elsewhere")
        let home = root + "/home"
        let open = { (path: String, home: String) -> Bool in
            guard let fd = Trasher.openFolder(path, creating: false, home: home) else { return false }
            close(fd)
            return true
        }
        #expect(open(home + "/Library/Caches", home))
        #expect(open(home, home))
        #expect(open(root + "/elsewhere", home))
        // A link below the home folder, or the home folder itself a link.
        try FileManager.default.createSymbolicLink(atPath: home + "/Linked", withDestinationPath: root + "/elsewhere")
        #expect(!open(home + "/Linked", home))
        try FileManager.default.createSymbolicLink(atPath: root + "/homelink", withDestinationPath: home)
        #expect(!open(root + "/homelink/Library", root + "/homelink"))
        // A folder that only starts with the home folder's name isn't in it.
        try box.folder("home2/x")
        #expect(open(root + "/home2/x", home))
    }
}

@Suite struct SnapshotStoreTests {
    @Test func pathsThatDifferOnlyInPunctuationKeepSeparateHistories() throws {
        let box = try Sandbox()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        SnapshotStore.save(Snapshot(rootPath: "/fixtures/a-b", date: date, sizes: ["": 1]), base: box.url)
        SnapshotStore.save(Snapshot(rootPath: "/fixtures/a_b", date: date, sizes: ["": 2]), base: box.url)
        #expect(SnapshotStore.key("/fixtures/a-b") != SnapshotStore.key("/fixtures/a_b"))
        let a = SnapshotStore.history(for: "/fixtures/a-b", base: box.url)
        let b = SnapshotStore.history(for: "/fixtures/a_b", base: box.url)
        #expect(a.compactMap(SnapshotStore.load).map(\.totalSize) == [1])
        #expect(b.compactMap(SnapshotStore.load).map(\.totalSize) == [2])
    }

    @Test func unattendedScansAreSavedOnlyEveryFewHours() throws {
        let box = try Sandbox()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        // At Balanced, as before the scale: every six hours.
        let interval = ResultSize.balanced.historyInterval
        #expect(SnapshotStore.isDue(for: "/r", now: date, base: box.url, interval: interval))
        SnapshotStore.save(Snapshot(rootPath: "/r", date: date, sizes: ["": 1]), base: box.url)
        #expect(!SnapshotStore.isDue(for: "/r", now: date.addingTimeInterval(3_600), base: box.url, interval: interval))
        #expect(SnapshotStore.isDue(
            for: "/r", now: date.addingTimeInterval(SnapshotStore.unattendedInterval), base: box.url, interval: interval))
    }

    @Test func twoScansInTheSameSecondAreBothKept() throws {
        let box = try Sandbox()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        SnapshotStore.save(Snapshot(rootPath: "/r", date: date, sizes: ["": 1]), base: box.url)
        SnapshotStore.save(Snapshot(rootPath: "/r", date: date, sizes: ["": 2]), base: box.url)
        let sizes = SnapshotStore.history(for: "/r", base: box.url).compactMap(SnapshotStore.load).map(\.totalSize)
        #expect(sizes.sorted() == [1, 2])
    }

    @Test func mixedLegacyFolderIsSplitByEachScansOwnPath() throws {
        let box = try Sandbox()
        // The old key mapped both paths to one folder.
        #expect(SnapshotStore.legacyKey("/fixtures/a-b") == SnapshotStore.legacyKey("/fixtures/a_b"))
        let old = box.url.appending(path: SnapshotStore.legacyKey("/fixtures/a-b"))
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try e.encode(Snapshot(rootPath: "/fixtures/a-b", date: Date(timeIntervalSince1970: 1_790_000_000), sizes: ["": 1]))
            .write(to: old.appending(path: "20260904-102640.json"))
        try e.encode(Snapshot(rootPath: "/fixtures/a_b", date: Date(timeIntervalSince1970: 1_790_000_060), sizes: ["": 2]))
            .write(to: old.appending(path: "20260904-102740.json"))
        let a = SnapshotStore.history(for: "/fixtures/a-b", base: box.url).compactMap(SnapshotStore.load)
        #expect(a.map(\.totalSize) == [1])
        let b = SnapshotStore.history(for: "/fixtures/a_b", base: box.url).compactMap(SnapshotStore.load)
        #expect(b.map(\.totalSize) == [2])
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }
}

@Suite struct TrashOrderTests {
    @Test func outermostDropsPathsInsideAnotherOne() {
        let picked = ["/x/a", "/x/a/b", "/x/a/b/c.txt", "/x/ab", "/y"]
        #expect(Trasher.outermost(picked) == ["/x/a", "/x/ab", "/y"])
    }

    @Test func undoRestoresInReverseOrder() throws {
        // A child moved before its parent: putting the child back first
        // would recreate the parent's folder and block the parent's return.
        let box = try Sandbox()
        try box.file("p/c/f.txt", bytes: 10)
        let bin = box.url.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let child = box.url.appending(path: "p/c"), parent = box.url.appending(path: "p")
        try FileManager.default.moveItem(at: child, to: bin.appending(path: "c"))
        try FileManager.default.moveItem(at: parent, to: bin.appending(path: "p"))
        let failed = Trasher.restore([
            TrashRecord(original: child, trashed: bin.appending(path: "c")),
            TrashRecord(original: parent, trashed: bin.appending(path: "p")),
        ])
        #expect(failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: box.url.appending(path: "p/c/f.txt").path))
    }
}

@Suite struct SharedRootTests {
    @Test func aPublishedRootIsLeftForItsOwnerToFinish() throws {
        let box = try Sandbox()
        try box.file("a/one.bin", bytes: 2_000_000)
        try box.file("b/two.bin", bytes: 2_000_000)
        let r = StorageScanner.scan(path: box.path, onRoot: { _ in })
        #expect(!r.root.isFinished)
        #expect(r.root.subfolders.allSatisfy { $0.isFinished })
        r.root.finish()
        #expect(r.root.size == box.allocated("a/one.bin") + box.allocated("b/two.bin"))
    }
}

/// The one way to the Trash: every flow's move passes these checks.
@Suite struct TrashGateTests {
    struct Unreadable: Error {}

    @Test func movesOnlyWhatPassesEveryCheck() throws {
        let box = try Sandbox()
        let ok = try box.file("cache/ok", bytes: 10).path
        let kept = try box.file("cache/kept/inner", bytes: 10).path
        let changed = try box.file("cache/changed", bytes: 10).path
        let keptFolder = box.path + "/cache/kept"
        let gate = TrashGate(
            still: { $0 != changed },
            protections: { { $0.hasPrefix(keptFolder) } })
        let crooked = box.path + "/cache/../cache/ok"
        let out = Trasher.moveToTrash([ok, kept, changed, crooked, "relative/path"], through: gate, backend: try testBin(box))
        #expect(out.moved.map(\.original.path) == [ok])
        let reasons = Dictionary(out.failed.map { ($0.path, $0.reason) }, uniquingKeysWith: { a, _ in a })
        #expect(reasons[kept] == "Kept")
        #expect(reasons[changed] == "Changed since it was checked")
        #expect(reasons[crooked] == "Not a plain full path")
        #expect(reasons["relative/path"] == "Not a plain full path")
        #expect(FileManager.default.fileExists(atPath: kept) && FileManager.default.fileExists(atPath: changed))
    }

    @Test func unreadableProtectionsStopEverything() throws {
        let box = try Sandbox()
        let f = try box.file("cache/f", bytes: 10).path
        let out = Trasher.moveToTrash([f], through: TrashGate(still: { _ in true }, protections: { throw Unreadable() }), backend: try testBin(box))
        #expect(out.moved.isEmpty && out.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: f))
    }

    @Test func protectedPlacesStayEvenWhenTheFlowAllowsThem() {
        let home = NSHomeDirectory()
        let cleared = Trasher.clear([home + "/.ssh", home + "/Library/Keychains", "/System"], through: TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing))
        #expect(cleared.allowed.isEmpty)
        #expect(cleared.refused.allSatisfy { $0.reason == "Protected location" })
    }
}

@Suite struct PlainPathTests {
    @Test func plainPathsAreWrittenExactlyAsChecked() {
        for p in ["/", "/private/var/log/system.log.0.gz", "/Users/synthetic/Library/Caches/x", "/a b/c"] {
            #expect(Trasher.isPlainPath(p), "\(p)")
        }
        for p in ["", "relative", "/a//b", "/a/./b", "/a/../b", "/a/", "/..", "/a/..", "/a\0", "/a\0/b", "/\0a"] {
            #expect(!Trasher.isPlainPath(p), "\(p)")
        }
    }

    @Test func nulCannotHideTheItemPassedToTheBackend() throws {
        let box = try Sandbox()
        let path = try box.file("cache/keep", bytes: 10).path
        // A C API would read just `path`, while a string-based keep rule
        // sees the suffix. The common gate must refuse it before either.
        let disguised = path + "\0.cache"
        let calls = Mutex<[String]>([])
        let backend = TrashBackend { p in
            calls.withLock { $0.append(p) }
            return (nil, "Synthetic backend")
        }
        let gate = TrashGate(still: { _ in true }, protections: { { $0 == path } })
        let result = Trasher.moveToTrash([disguised], through: gate, backend: backend)
        #expect(result.moved.isEmpty && result.failed.map(\.reason) == ["Not a plain full path"])
        #expect(calls.withLock { $0.isEmpty })
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func lexicalNeverDropsPrivateOrFollowsLinks() {
        #expect(Trasher.lexical("/private/var/log/./x") == "/private/var/log/x")
        #expect(Trasher.lexical("/a//b/../c/") == "/a/c")
        #expect(Trasher.lexical("/..") == "/")
        let home = "/Users/synthetic"
        #expect(Trasher.isProtected(home + "/.ssh/sub/..", home: home))
        #expect(Trasher.isProtected("/private", home: home))
    }
}

@Suite struct PerformanceLevelTests {
    @Test func higherLevelsNeverDoLess() {
        for cores in [1, 4, 8, 12, 24] {
            for background in [false, true] {
                let workers = PerformanceLevel.allCases.map { $0.workers(background: background, cores: cores) }
                #expect(workers == workers.sorted(), "cores \(cores), background \(background): \(workers)")
                // Up to Maximum the walkers have a ceiling; Hyperspeed has none.
                #expect(workers.dropLast().allSatisfy { $0 >= 1 && $0 <= 48 })
            }
            // Work started ahead of need never gets more than work someone waits on.
            for level in PerformanceLevel.allCases {
                #expect(level.workers(background: true, cores: cores) <= level.workers(background: false, cores: cores))
            }
        }
    }

    @Test func fastKeepsTheEarlierThreadCounts() {
        #expect(PerformanceLevel.fast.workers(background: false) == StorageScanner.defaultWorkers)
        #expect(PerformanceLevel.fast.workers(background: true) == StorageScanner.backgroundWorkers)
    }

    @Test func lowLevelsRunQuietAndOneAtATime() {
        #expect(PerformanceLevel.gentle.priority(background: true) == .background)
        #expect(PerformanceLevel.light.priority(background: false) == .utility)
        #expect(PerformanceLevel.full.priority(background: true) == .userInitiated)
        #expect(!PerformanceLevel.light.runsScansTogether && PerformanceLevel.balanced.runsScansTogether)
    }

    @Test func savedLevelIsReadAndUnknownValuesFallBackToMaximum() {
        #expect(PerformanceLevel.standard == .full && PerformanceLevel.full.title == "Maximum")
        #expect(PerformanceLevel(saved: 0) == .full)
        #expect(PerformanceLevel(saved: 1) == .gentle)
        #expect(PerformanceLevel(saved: 3) == .balanced)
        #expect(PerformanceLevel(saved: 6) == .hyperspeed)
        #expect(PerformanceLevel(saved: 9) == .full)
        #expect(PerformanceLevel(saved: -1) == .full)
    }

    @Test func maximumKeepsItsLimitsAndHyperspeedHasNone() {
        for cores in [1, 8, 24] {
            #expect(PerformanceLevel.full.workers(background: false, cores: cores) == min(max(cores * 3, 4), 48))
            #expect(PerformanceLevel.full.workers(background: true, cores: cores) == max(cores, 4))
            let unlimited = PerformanceLevel.hyperspeed
            #expect(unlimited.workers(background: true, cores: cores) == unlimited.workers(background: false, cores: cores))
        }
        // Balanced keeps the three walks of before; Maximum six or half the cores.
        #expect(PerformanceLevel.allCases.map { $0.scanSlots(cores: 8) } == [1, 2, 3, 4, 6, .max])
        #expect(PerformanceLevel.full.scanSlots(cores: 20) == 10)
    }
}

@Suite struct SizeOnDiskTests {
    @Test func aFileIsMeasuredByItsBlocksAndAFolderByItsTree() throws {
        let box = try Sandbox()
        try box.file("cache/a.zip", bytes: 65_536)
        try box.file("cache/deeper/b.zip", bytes: 20_000)
        #expect(StorageScanner.sizeOnDisk(box.path + "/cache/a.zip") == box.allocated("cache/a.zip"))
        #expect(StorageScanner.sizeOnDisk(box.path + "/cache") == box.allocated("cache/a.zip") + box.allocated("cache/deeper/b.zip"))
        #expect(StorageScanner.sizeOnDisk(box.path + "/cache/gone") == nil)
        // The walk alone reports nothing for a file, which is why the helper exists.
        #expect(StorageScanner.scan(path: box.path + "/cache/a.zip", workers: 1).root.size == 0)
    }
}

@Suite struct PathRiskWalkTests {
    @Test func theWalkEndsAtTheNextFolderOnceAskedTo() throws {
        let box = try Sandbox()
        for i in 0..<12 { try box.file("app/d\(i)/x", bytes: 100) }
        try box.file("app/d11/.aws/credentials", bytes: 100)
        let app = try #require(StorageScanner.scan(path: box.path, workers: 1).root.subfolders.first { $0.name == "app" })
        #expect(PathRisk.inside(app)?.level == .caution)
        var asked = 0
        let early = PathRisk.inside(app, stop: { asked += 1; return asked > 3 })
        // Three folders looked at, then the walk ends with what it had.
        #expect(asked == 4 && (early == nil || early?.level == .caution))
    }
}
