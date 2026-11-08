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
        #expect(comparing.map(\.done) == Array(1...7))
        #expect(comparing.allSatisfy { $0.total == 7 })
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
