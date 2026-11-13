import Darwin
import Foundation
import Testing

@testable import StorageKit

@Suite struct DirectoryReaderTests {
    @Test func bulkReadSaysHowFilesShareBlocks() throws {
        let box = try Sandbox()
        try box.file("dir/a.bin", bytes: 300_000)
        #expect(clonefile(box.path + "/dir/a.bin", box.path + "/dir/a clone.bin", 0) == 0)
        try box.file("dir/b.bin", bytes: 200_000)
        try box.folder("dir/sub")
        var entries: [String: Entry] = [:]
        #expect(DirectoryReader.read(box.path + "/dir") { entries[$0.name] = $0 } == .ok)
        let a = try #require(entries["a.bin"]), clone = try #require(entries["a clone.bin"]), b = try #require(entries["b.bin"])
        // The reader's view matches one getattrlist per file.
        #expect(a.sharing == FileSpace.sharing(box.path + "/dir/a.bin"))
        #expect(clone.sharing == FileSpace.sharing(box.path + "/dir/a clone.bin"))
        // A file that shares nothing isn't asked about further.
        #expect(b.sharing == nil && FileSpace.sharing(box.path + "/dir/b.bin")?.privateBytes == nil)
        #expect(a.sharing?.sharesAllBlocks == true && a.sharing?.cloneCount == 2 && a.sharing?.privateBytes == 0)
        #expect(clone.sharing?.cloneID == a.sharing?.cloneID)
        #expect(b.reclaim.bytes == b.allocated)
        #expect(entries["sub"]?.sharing == nil && entries["sub"]?.kind == .folder)
        #expect(a.allocated == box.allocated("dir/a.bin") && b.allocated == box.allocated("dir/b.bin"))
        #expect(a.reclaim.bytes == 0 && (a.reclaim + clone.reclaim).bytes == a.allocated)
    }

    @Test func bulkReadStopsWithinOneDirectory() throws {
        let box = try Sandbox()
        for i in 0..<128 { try box.file("wide/f\(i)", bytes: 1) }
        var read = 0
        let outcome = DirectoryReader.read(box.path + "/wide", isCancelled: { read == 3 }) { _ in read += 1 }
        #expect(outcome == .cancelled && read == 3)
    }

    @Test func fallbackStopsWithinOneDirectory() throws {
        let box = try Sandbox()
        for i in 0..<128 { try box.file("wide/f\(i)", bytes: 1) }
        let fd = open(box.path + "/wide", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var read = 0
        let outcome = DirectoryReader.readFallback(fd: fd, isCancelled: { read == 3 }) { _ in read += 1 }
        #expect(outcome == .cancelled && read == 3)
    }

    @Test func stoppedScanDoesNotReadItsRoot() throws {
        let box = try Sandbox()
        try box.file("file", bytes: 1)
        let progress = ScanProgress()
        progress.cancel()
        let result = StorageScanner.scan(path: box.path, progress: progress, workers: 1)
        #expect(result.cancelled && result.root.fileCount == 0)
        #expect(result.deniedPaths.isEmpty && !result.root.unreadable)
    }

    @Test func unreadableEntryMetadataMakesTheDirectoryIncomplete() throws {
        let box = try Sandbox()
        try box.file("opaque/file", bytes: 1)
        let path = box.path + "/opaque"
        #expect(chmod(path, 0o400) == 0)
        defer { chmod(path, 0o700) }
        // Names can be listed, but metadata requires search permission.
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        #expect(DirectoryReader.readFallback(fd: fd) { _ in } == .failed)
        let result = StorageScanner.scan(path: path, workers: 1)
        #expect(result.root.unreadable && result.deniedPaths == [path])
    }

    @Test func fallbackKeepsLinksAsLinksAndDoesNotFollowThem() throws {
        let box = try Sandbox()
        try box.file("folder/file", bytes: 100)
        try FileManager.default.createSymbolicLink(atPath: box.path + "/folder/link", withDestinationPath: box.path + "/folder")
        let fd = open(box.path + "/folder", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var entries: [Entry] = []
        #expect(DirectoryReader.readFallback(fd: fd) { entries.append($0) } == .ok)
        #expect(entries.count == 2)
        #expect(entries.first { $0.name == "file" }?.kind == .file)
        #expect(entries.first { $0.name == "link" }?.kind == .symlink)
    }
}
