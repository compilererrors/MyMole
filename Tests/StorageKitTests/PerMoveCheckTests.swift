import Darwin
import Foundation
import Testing

@testable import StorageKit

/// Checks made right before every single move, and results that couldn't
/// read everything.
@Suite struct PerMoveCheckTests {
    @Test func anItemSwappedWhileTheBatchRunsStays() throws {
        let box = try Sandbox()
        let a = try box.file("cache/a", bytes: 10).path
        let b = try box.file("cache/b", bytes: 10).path
        // While `a` is being checked, `b` is replaced by another file.
        let gate = TrashGate(still: { p in
            if p == a {
                try? FileManager.default.removeItem(atPath: b)
                FileManager.default.createFile(atPath: b, contents: Data("other".utf8))
            }
            return true
        })
        let out = Trasher.moveToTrash([a, b], through: gate, backend: try testBin(box))
        #expect(out.moved.map(\.original.path) == [a])
        #expect(out.failed.first { $0.path == b }?.reason == "Changed since it was checked")
        #expect(String(decoding: FileManager.default.contents(atPath: b) ?? Data(), as: UTF8.self) == "other")
    }

    @Test func protectionsAreReadAgainRightBeforeMoving() throws {
        let box = try Sandbox()
        let a = try box.file("cache/a", bytes: 10).path
        let reads = Counter()
        // Readable for the batch check, then not when read again before the moves.
        let gate = TrashGate(still: { _ in true }, protections: {
            if reads.next() > 1 { throw CocoaError(.fileReadNoPermission) }
            return { _ in false }
        })
        let out = Trasher.moveToTrash([a], through: gate, backend: try testBin(box))
        #expect(out.moved.isEmpty && out.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: a))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

@Suite struct IncompleteResultTests {
    @Test func aCacheThatCantBeReadIsMarkedAndNotSaved() throws {
        let box = try Sandbox()
        try box.file(".npm/_cacache/content/a", bytes: 4_000)
        try box.folder(".npm/_cacache/locked")
        try box.file(".npm/_cacache/locked/b", bytes: 4_000)
        let locked = box.path + "/.npm/_cacache/locked"
        #expect(chmod(locked, 0) == 0)
        defer { chmod(locked, 0o700) }
        let found = CleanScanner.list(home: box.path, workers: 1)
        let npm = try #require(found.candidates.first { $0.path == box.path + "/.npm/_cacache" })
        #expect(npm.incomplete)
        let base = box.url.appending(path: "store")
        CleanStore.save(found, home: box.path, base: base)
        #expect(CleanStore.load(home: box.path, base: base) == nil)
    }

    @Test func aPackageFolderThatCantBeReadIsMarkedAndNotSaved() throws {
        let box = try Sandbox()
        try box.file("Downloads/Old.pkg/Contents/Archive.pax", bytes: 4_000)
        try box.folder("Downloads/Old.pkg/Contents/Locked")
        let locked = box.path + "/Downloads/Old.pkg/Contents/Locked"
        #expect(chmod(locked, 0) == 0)
        defer { chmod(locked, 0o700) }
        let locations = [InstallerLocation(path: box.path + "/Downloads", depth: 1)]
        let found = InstallerFinder.list(in: locations)
        #expect(found.files.first?.incomplete == true)
        let base = box.url.appending(path: "store")
        InstallerStore.save(found, locations: locations, base: base)
        #expect(InstallerStore.load(for: locations, base: base) == nil)
    }
}
