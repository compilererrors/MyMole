import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing

@testable import StorageKit

/// Looking for identical files in folders of the test's own.
@Suite struct DuplicatesTests {
    /// An independent copy: the bytes written again, never an APFS clone,
    /// which `FileManager.copyItem` would make.
    private func copy(_ box: Sandbox, _ from: String, to: String) throws {
        let target = box.url.appending(path: to)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: box.url.appending(path: from)).write(to: target)
    }

    /// A clone, as Finder's Duplicate makes one.
    private func clone(_ box: Sandbox, _ from: String, to: String) throws {
        let target = box.url.appending(path: to)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(clonefile(box.url.appending(path: from).path, target.path, 0) == 0)
    }

    @Test func clonesOfOneAnotherTakeTheSpaceOfOneCopy() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 300_000)
        try clone(box, "Documents/a.bin", to: "Documents/a clone.bin")
        try copy(box, "Documents/a.bin", to: "Downloads/a.bin")
        let listing = DuplicateFinder.find(in: [box.path], minimum: 100_000, workers: 1)
        let g = try #require(listing.groups.first)
        let a = box.path + "/Documents/a.bin", aClone = box.path + "/Documents/a clone.bin", c = box.path + "/Downloads/a.bin"
        #expect(g.files.count == 3)
        // Two families on disk: the original with its clone, and the copy.
        #expect(g.spare == g.bytes)
        #expect(g.clones(of: a) == 1 && g.clones(of: aClone) == 1 && g.clones(of: c) == 0)
        // Moving the clone alone frees nothing; with the original it frees one copy.
        #expect(g.freed(going: [aClone]) == [aClone: 0])
        #expect(g.freed(going: [a, aClone]).values.reduce(0, +) == g.bytes)
        #expect(g.freed(going: [c]) == [c: g.bytes])
    }

    @Test func aCloneIDOnAnotherVolumeIsIndependentStorage() {
        let a = DuplicateFile(path: "/synthetic/disk-a/model.bin", modified: .distantPast, inode: 1, device: 11, cloneID: 42)
        let sibling = DuplicateFile(path: "/synthetic/disk-a/clone.bin", modified: .distantPast, inode: 2, device: 11, cloneID: 42)
        let other = DuplicateFile(path: "/synthetic/disk-b/model.bin", modified: .distantPast, inode: 1, device: 22, cloneID: 42)
        let group = DuplicateGroup(length: 1_024, bytes: 1_024, digest: "synthetic", files: [a, sibling, other])
        #expect(group.clones(of: a.path) == 1)
        #expect(group.clones(of: other.path) == 0)
        #expect(group.spare == 1_024)
        #expect(group.freed(going: [other.path]) == [other.path: 1_024])
        #expect(group.freed(going: [a.path]) == [a.path: 0])
        #expect(group.freed(going: [a.path, sibling.path]).values.reduce(0, +) == 1_024)
    }

    @Test func theVolumeTellsAClonesFamilyFromAnIndependentCopy() throws {
        let box = try Sandbox()
        try box.file("a.bin", bytes: 300_000)
        try clone(box, "a.bin", to: "a clone.bin")
        try copy(box, "a.bin", to: "a copy.bin")
        let original = try #require(FileSpace.sharing(box.path + "/a.bin"))
        let cloned = try #require(FileSpace.sharing(box.path + "/a clone.bin"))
        let copied = try #require(FileSpace.sharing(box.path + "/a copy.bin"))
        #expect(original.cloneID != nil && cloned.cloneID == original.cloneID && copied.cloneID != original.cloneID)
        #expect(original.cloneCount == 2 && cloned.cloneCount == 2 && copied.cloneCount == 1)
        // Clones hold nothing of their own; the copy says it shares nothing.
        #expect(original.privateBytes == 0 && cloned.privateBytes == 0 && copied.privateBytes == nil)
    }

    @Test func clonesOfAFileOutsideTheSearchFreeNothing() throws {
        let box = try Sandbox()
        // The original lies outside the searched folders, as a simulator
        // runtime or a cache would; its clones and one copy are searched.
        try box.file("Library/model.bin", bytes: 300_000)
        try clone(box, "Library/model.bin", to: "Documents/model.bin")
        try clone(box, "Library/model.bin", to: "Downloads/model.bin")
        try copy(box, "Library/model.bin", to: "Desktop/model.bin")
        let roots = ["Documents", "Downloads", "Desktop"].map { box.path + "/" + $0 }
        let g = try #require(DuplicateFinder.find(in: roots, minimum: 100_000, workers: 1).groups.first)
        let documents = box.path + "/Documents/model.bin", downloads = box.path + "/Downloads/model.bin"
        let desktop = box.path + "/Desktop/model.bin"
        #expect(g.files.count == 3)
        #expect(g.clones(of: documents) == 1)
        // Both clones going leave the original's blocks where they are.
        #expect(g.freed(going: [documents, downloads]).values.reduce(0, +) == 0)
        #expect(g.sharedOutside(documents) == 0 && g.sharedOutside(downloads) == 0 && g.sharedOutside(desktop) == nil)
        // Only the independent copy is spare: a clone staying costs nothing.
        #expect(g.freed(going: [desktop]) == [desktop: g.bytes])
        #expect(g.spare == g.bytes)
    }

    @Test func aCopyThatSharesPartOfItsBlocksFreesOnlyItsOwn() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 1_048_576)
        try clone(box, "Documents/a.bin", to: "Downloads/a.bin")
        // The same bytes written over part of the clone: still identical,
        // but those blocks are now its own while the rest stay shared.
        let path = box.path + "/Downloads/a.bin"
        let region = try Data(contentsOf: box.url.appending(path: "Documents/a.bin"))[0..<131_072]
        let fd = open(path, O_WRONLY)
        #expect(fd >= 0)
        let written = region.withUnsafeBytes { pwrite(fd, $0.baseAddress, region.count, 0) }
        #expect(fsync(fd) == 0 && close(fd) == 0 && written == region.count)
        let g = try #require(DuplicateFinder.find(in: [box.path], minimum: 100_000, workers: 1).groups.first)
        let own = try #require(g.files.first { $0.path == path }?.privateBytes)
        #expect(own >= 131_072 && own < g.bytes / 2)
        #expect(g.clones(of: path) == 0)
        #expect(g.freed(going: [path]) == [path: own])
        #expect(g.sharedOutside(path) == own)
        #expect(g.spare < g.bytes / 2)
    }

    @Test func aFamilyCountedWholeFreesOneCopyOnceAllOfItGoes() {
        func file(_ name: String, clone: UInt64, count: UInt32?, own: Int64?) -> DuplicateFile {
            DuplicateFile(path: "/synthetic/\(name)", modified: .distantPast, inode: UInt64(name.hashValue.magnitude), device: 1,
                          cloneID: clone, cloneCount: count, privateBytes: own)
        }
        let a = file("a", clone: 7, count: 2, own: 0), b = file("b", clone: 7, count: 2, own: 0)
        let elsewhere = file("c", clone: 9, count: 3, own: 0), d = file("d", clone: 9, count: 3, own: 0)
        let copy = file("e", clone: 11, count: 1, own: nil)
        let group = DuplicateGroup(length: 4_096, bytes: 4_096, digest: "synthetic", files: [a, b, elsewhere, d, copy])
        #expect(group.freed(going: [a.path, b.path]).values.reduce(0, +) == 4_096)
        #expect(group.sharedOutside(a.path) == nil)
        // A third file of family 9 isn't here, so c and d moving frees nothing.
        #expect(group.freed(going: [elsewhere.path, d.path]) == [elsewhere.path: 0, d.path: 0])
        #expect(group.sharedOutside(d.path) == 0)
        #expect(group.freed(going: [copy.path]) == [copy.path: 4_096])
        // Family 9 stays, family 7 and the copy go.
        #expect(group.spare == 8_192)
    }

    private func rel(_ box: Sandbox, _ group: DuplicateGroup) -> [String] {
        group.files.map { String($0.path.dropFirst(box.path.count + 1)) }.sorted()
    }

    @Test func findsFilesWithTheSameContentAndNothingElse() throws {
        let box = try Sandbox()
        try box.file("Documents/report.bin", bytes: 300_000)
        try copy(box, "Documents/report.bin", to: "Downloads/report copy.bin")
        try copy(box, "Documents/report.bin", to: "Desktop/old/report.bin")
        try box.file("Documents/photo.raw", bytes: 150_000)
        try copy(box, "Documents/photo.raw", to: "Pictures/photo.raw")
        // The same length as the report, other content; and one that differs only in its middle.
        try box.file("Documents/other.bin", bytes: 300_000)
        var middle = try Data(contentsOf: box.url.appending(path: "Documents/report.bin"))
        middle[150_000] ^= 0xFF
        try middle.write(to: box.url.appending(path: "Documents/almost.bin"))
        // Too small to count.
        try box.file("Documents/tiny.txt", bytes: 2_000)
        try copy(box, "Documents/tiny.txt", to: "Downloads/tiny.txt")

        let steps = Mutex<[DuplicateStep]>([])
        let listing = DuplicateFinder.find(in: [box.path], minimum: 100_000, workers: 2, onStep: { s in steps.withLock { $0.append(s) } })
        #expect(listing.unreadable.isEmpty)
        #expect(listing.groups.count == 2)
        // Most to win back first: three copies of the report, then the photo.
        #expect(rel(box, listing.groups[0]) == ["Desktop/old/report.bin", "Documents/report.bin", "Downloads/report copy.bin"])
        #expect(rel(box, listing.groups[1]) == ["Documents/photo.raw", "Pictures/photo.raw"])
        #expect(listing.groups[0].length == 300_000 && listing.groups[0].spare == 2 * listing.groups[0].bytes)
        let compared = steps.withLock { $0.filter { $0.phase == .comparing } }
        #expect(compared.contains { $0.done == $0.total && $0.total > 0 })
    }

    @Test func differentNamesAndExtensionsOnlyMatchWhenAllTheirBytesMatch() throws {
        let box = try Sandbox()
        try box.file("Downloads/payload.dat", bytes: 300_000)
        try copy(box, "Downloads/payload.dat", to: "Downloads/Setup.dmg")
        var different = try Data(contentsOf: box.url.appending(path: "Downloads/payload.dat"))
        different[150_000] ^= 1
        try different.write(to: box.url.appending(path: "Downloads/Other installer.dmg"))
        let groups = DuplicateFinder.find(in: [box.path], minimum: 1).groups
        #expect(groups.count == 1)
        #expect(Set(groups.first?.files.map(\.name) ?? []) == ["payload.dat", "Setup.dmg"])
    }

    @Test(arguments: [false, true])
    func restoringTheModificationDateCannotHideChangedContents(keeperChanges: Bool) throws {
        let box = try Sandbox()
        try box.file("Documents/original.bin", bytes: 300_000)
        try copy(box, "Documents/original.bin", to: "Downloads/copy.bin")
        let group = try #require(DuplicateFinder.find(in: [box.path], minimum: 1).groups.first)
        let going = box.path + "/Downloads/copy.bin"
        let path = keeperChanges ? box.path + "/Documents/original.bin" : going
        var before = stat()
        try #require(lstat(path, &before) == 0)
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seek(toOffset: 150_000)
        try handle.write(contentsOf: Data([original[150_000] ^ 1]))
        try handle.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        try #require(utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW) == 0)
        #expect(!DuplicateFinder.mayGo(going, of: group, going: [going], home: box.path))
    }

    @Test func anEqualDigestCannotAuthorizeDifferentBytes() throws {
        let box = try Sandbox()
        try box.file("Documents/original.dat", bytes: 300_000)
        try copy(box, "Documents/original.dat", to: "Downloads/setup.dmg")
        var group = try #require(DuplicateFinder.find(in: [box.path], minimum: 1).groups.first)
        let path = box.path + "/Downloads/setup.dmg"
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seek(toOffset: 150_000)
        try handle.write(contentsOf: Data([original[150_000] ^ 1]))
        try handle.close()
        var st = stat()
        try #require(lstat(path, &st) == 0)
        // Model a stale or colliding hash group whose metadata looks current.
        group.files = group.files.map { file in
            file.path == path ? DuplicateFile(path: path, modified: DuplicateFinder.changed(st), inode: UInt64(st.st_ino),
                                             device: st.st_dev, version: DuplicateVersion(st)) : file
        }
        #expect(!DuplicateFinder.mayGo(path, of: group, going: [path], home: box.path))
    }

    @Test func resourceForkContentsAreNeverIgnored() throws {
        let box = try Sandbox()
        try box.file("Documents/original.bin", bytes: 150_000)
        try copy(box, "Documents/original.bin", to: "Downloads/copy.bin")
        let group = try #require(DuplicateFinder.find(in: [box.path], minimum: 1).groups.first)
        let path = box.path + "/Downloads/copy.bin"
        let fork = Data("Synthetic additional contents".utf8)
        try #require(fork.withUnsafeBytes { setxattr(path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) } == 0)
        #expect(!DuplicateFinder.mayGo(path, of: group, going: [path], home: box.path))
        let listing = DuplicateFinder.find(in: [box.path], minimum: 1)
        #expect(listing.groups.isEmpty && listing.uncompared == 1)
    }

    @Test func aCancelledVerificationCannotAuthorizeAMove() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 150_000)
        try copy(box, "Documents/a.bin", to: "Downloads/b.bin")
        let group = try #require(DuplicateFinder.find(in: [box.path], minimum: 1).groups.first)
        let path = box.path + "/Downloads/b.bin"
        #expect(!DuplicateFinder.mayGo(path, of: group, going: [path], home: box.path, stop: { true }))
    }

    @Test func leavesOutWhatIsNotTheUsersToTidy() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 200_000)
        // Hidden, in a package, in a repository, in a dependency folder: none of them counts.
        try copy(box, "Documents/a.bin", to: "Documents/.hidden/a.bin")
        try copy(box, "Documents/a.bin", to: "Documents/Library.photoslibrary/originals/a.bin")
        try copy(box, "Documents/a.bin", to: "Documents/repo/assets/a.bin")
        try box.folder("Documents/repo/.git")
        try copy(box, "Documents/a.bin", to: "Documents/site/node_modules/pkg/a.bin")
        // A link to it, and a second name of the same file.
        try FileManager.default.createSymbolicLink(atPath: box.path + "/Documents/link.bin", withDestinationPath: box.path + "/Documents/a.bin")
        try FileManager.default.linkItem(atPath: box.path + "/Documents/a.bin", toPath: box.path + "/Documents/hardlink.bin")
        #expect(DuplicateFinder.find(in: [box.path], minimum: 100_000, workers: 2).groups.isEmpty)

        // One real copy is found, and only it.
        try copy(box, "Documents/a.bin", to: "Downloads/a.bin")
        let groups = DuplicateFinder.find(in: [box.path], minimum: 100_000, workers: 2).groups
        #expect(groups.count == 1 && groups[0].files.count == 2)
        #expect(groups[0].files.contains { $0.path.hasSuffix("Downloads/a.bin") })
    }

    @Test func aRootInsideAnotherIsWalkedOnceAndAStopReturnsEarly() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 200_000)
        try copy(box, "Documents/a.bin", to: "Documents/sub/a.bin")
        let groups = DuplicateFinder.find(in: [box.path + "/Documents", box.path + "/Documents/sub", box.path], minimum: 100_000).groups
        #expect(groups.count == 1 && groups[0].files.count == 2)

        let stopped = ScanProgress()
        stopped.cancel()
        #expect(DuplicateFinder.find(in: [box.path], minimum: 100_000, progress: stopped).groups.isEmpty)
    }

    @Test func aLinkedSearchRootCannotReadItsDestination() throws {
        let box = try Sandbox()
        try box.file("Outside/a.bin", bytes: 150_000)
        try copy(box, "Outside/a.bin", to: "Outside/b.bin")
        try FileManager.default.createSymbolicLink(atPath: box.path + "/Alias", withDestinationPath: box.path + "/Outside")
        let found = DuplicateFinder.find(in: [box.path + "/Alias"], minimum: 100_000)
        #expect(found.groups.isEmpty)
        #expect(found.unreadable == [box.path + "/Alias"])
    }

    @Test func progressAndVerifiedGroupsAreEmittedEvenForSmallSearches() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 150_000)
        try copy(box, "Documents/a.bin", to: "Downloads/b.bin")
        let steps = Mutex<[DuplicateStep]>([])
        let groups = Mutex<[DuplicateGroup]>([])
        let found = DuplicateFinder.find(in: [box.path], minimum: 100_000, workers: 1,
            onGroup: { g in groups.withLock { $0.append(g) } }, onStep: { s in steps.withLock { $0.append(s) } })
        #expect(groups.withLock { $0 } == found.groups)
        #expect(steps.withLock { $0.first?.phase } == .listing)
        #expect(steps.withLock { $0.contains { $0.phase == .listing && $0.done == 2 } })
        #expect(steps.withLock { $0.last?.done } == 2)
        #expect(steps.withLock { $0.last?.total } == 2)
    }

    @Test func explicitRootsCannotBypassLibraryDependencyAndRepositoryExclusions() throws {
        let box = try Sandbox()
        for path in ["Library.photoslibrary/originals", "site/node_modules/package", "site/PoDs/assets", "repo/assets"] {
            try box.file(path + "/a.bin", bytes: 150_000)
            try copy(box, path + "/a.bin", to: path + "/b.bin")
        }
        try box.folder("repo/.git")
        let found = DuplicateFinder.find(in: [box.path + "/Library.photoslibrary/originals", box.path + "/site/node_modules/package", box.path + "/site/PoDs/assets", box.path + "/repo/assets"], minimum: 100_000)
        #expect(found.groups.isEmpty && found.unreadable.isEmpty)
        #expect(found.excluded.count == 4)
    }

    @Test func aGroupNeverLosesItsLastCopy() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 200_000)
        try copy(box, "Documents/a.bin", to: "Downloads/a.bin")
        try copy(box, "Documents/a.bin", to: "Desktop/a.bin")
        let group = try #require(DuplicateFinder.find(in: [box.path], minimum: 100_000).groups.first)
        let paths = group.files.map(\.path)

        // Two of three may go; all three may not, whichever is asked about.
        #expect(DuplicateFinder.mayGo(paths[0], of: group, going: [paths[0], paths[1]], home: box.path))
        #expect(paths.allSatisfy { !DuplicateFinder.mayGo($0, of: group, going: Set(paths), home: box.path) })
        #expect(!DuplicateFinder.mayGo(box.path + "/Documents/other.bin", of: group, going: [], home: box.path))

        // The copy that was to stay changed since: the other one stays instead.
        try Data(repeating: 1, count: 200_000).write(to: URL(fileURLWithPath: paths[2]))
        #expect(!DuplicateFinder.mayGo(paths[0], of: group, going: [paths[0], paths[1]], home: box.path))
        // A file changed since it was compared doesn't go.
        #expect(!DuplicateFinder.mayGo(paths[2], of: group, going: [paths[2]], home: box.path))
    }

    @Test func aFileRewrittenSinceItWasListedIsNotCountedAsACopy() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 200_000)
        try copy(box, "Documents/a.bin", to: "Downloads/a.bin")
        var seen = Set<DuplicateFinder.FileID>()
        var unreadable: [String] = []
        var listed: [DuplicateFinder.Found] = []
        DuplicateFinder.walk(box.path, minimum: 100_000, progress: ScanProgress(), seen: &seen, unreadable: &unreadable) { listed.append($0) }
        #expect(listed.count == 2)
        #expect(DuplicateFinder.compare(listed, progress: ScanProgress()) {}.count == 1)

        // The same bytes written again: a new last change, so not the file that was listed.
        let later = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: box.path + "/Downloads/a.bin")
        #expect(DuplicateFinder.compare(listed, progress: ScanProgress()) {}.isEmpty)
    }

    @Test func manyFilesOfOneLengthAreToldApartByTheirEnds() throws {
        let box = try Sandbox()
        for i in 0..<40 { try box.file("Documents/f\(i).bin", bytes: 150_000) }
        try copy(box, "Documents/f7.bin", to: "Downloads/f7.bin")
        let found = DuplicateFinder.find(in: [box.path], minimum: 100_000)
        #expect(found.groups.count == 1)
        #expect(found.groups.first?.files.map(\.name) == ["f7.bin", "f7.bin"])
    }

    @Test func theCopyThatStaysMustNotBeReachedThroughALink() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 200_000)
        try copy(box, "Documents/a.bin", to: "Real/a.bin")
        try FileManager.default.createSymbolicLink(atPath: box.path + "/Link", withDestinationPath: box.path + "/Real")
        let found = try #require(DuplicateFinder.find(in: [box.path + "/Documents", box.path + "/Real"], minimum: 100_000).groups.first)
        var group = found
        // The staying copy named by a path through the link.
        group.files = group.files.map { f in
            guard f.path.hasPrefix(box.path + "/Real/") else { return f }
            var g = DuplicateFile(path: box.path + "/Link/a.bin", modified: f.modified, inode: f.inode, device: f.device)
            g.cloneID = f.cloneID
            return g
        }
        let going = box.path + "/Documents/a.bin"
        #expect(DuplicateFinder.mayGo(going, of: found, going: [going], home: box.path))
        #expect(!DuplicateFinder.mayGo(going, of: group, going: [going], home: box.path))
    }

    @Test func comparingCountsEachFileOnceItIsSettled() throws {
        let box = try Sandbox()
        for i in 0..<6 { try box.file("Documents/f\(i).bin", bytes: 150_000) }
        try copy(box, "Documents/f1.bin", to: "Downloads/f1.bin")
        let steps = Mutex<[DuplicateStep]>([])
        _ = DuplicateFinder.find(in: [box.path], minimum: 100_000, workers: 1) { s in steps.withLock { $0.append(s) } }
        let comparing = steps.withLock { $0 }.filter { $0.phase == .comparing }
        #expect(comparing.map(\.done) == Array(0...7))
        #expect(comparing.allSatisfy { $0.total == 7 })
    }

    @Test(arguments: [8_192, 1_048_576 + 37])
    func reusedContentBufferKeepsIndependentHashesAndTheFinalShortChunk(bytes: Int) throws {
        let box = try Sandbox()
        try box.folder("files")
        let first = Data(repeating: 7, count: bytes)
        var second = first
        second[bytes / 2] ^= 1
        for (name, data) in [("a", first), ("b", first), ("c", second), ("d", second)] {
            try data.write(to: box.url.appending(path: "files/\(name).bin"))
        }
        let gold = Set([first, second].map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() })
        let found = DuplicateFinder.find(in: [box.path], minimum: 1, workers: 1)
        #expect(found.groups.count == 2 && found.groups.allSatisfy { $0.files.count == 2 })
        #expect(Set(found.groups.map(\.digest)) == gold)
        #expect(found.unreadable.isEmpty && found.uncompared == 0)
    }

    @Test func aFileThatCantBeReadIsCountedAsNotCompared() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 150_000)
        try copy(box, "Documents/a.bin", to: "Downloads/a.bin")
        try box.file("Documents/closed.bin", bytes: 150_000)
        #expect(chmod(box.path + "/Documents/closed.bin", 0) == 0)
        defer { _ = chmod(box.path + "/Documents/closed.bin", 0o644) }
        let found = DuplicateFinder.find(in: [box.path], minimum: 100_000)
        #expect(found.groups.count == 1 && found.uncompared == 1)
    }
}
