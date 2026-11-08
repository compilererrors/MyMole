import Foundation
import Testing

@testable import MyMole

@MainActor
@Suite struct ChosenFoldersTests {
    /// Bookmarks that hold the path, and a folder that's there or not.
    private func bookmarks() -> FolderAccess.Bookmarks {
        FolderAccess.Bookmarks(
            resolve: { data in
                let path = String(decoding: data, as: UTF8.self)
                return FileManager.default.fileExists(atPath: path) ? (URL(fileURLWithPath: path), false) : nil
            },
            startAccessing: { _ in true }, stopAccessing: { _ in },
            make: { Data($0.standardizedFileURL.path.utf8) }, choose: { _ in nil })
    }

    @Test func aChosenFolderIsKeptAcrossLaunchesUntilReleased() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "chosen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appending(path: "Disk")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = testDefaults(in: dir.appending(path: "prefs"))

        let first = ChosenFolders(defaults: defaults, sandboxed: true, bookmarks: bookmarks())
        #expect(first.keep(folder))
        #expect(first.paths == [folder.standardizedFileURL.path])
        // The next launch opens it again.
        let next = ChosenFolders(defaults: defaults, sandboxed: true, bookmarks: bookmarks())
        next.restore()
        #expect(next.paths == [folder.standardizedFileURL.path])
        next.release(folder.standardizedFileURL.path)
        let after = ChosenFolders(defaults: defaults, sandboxed: true, bookmarks: bookmarks())
        after.restore()
        #expect(after.paths.isEmpty)
    }

    @Test func aFolderThatsGoneIsDropped() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "chosen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appending(path: "Gone")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = testDefaults(in: dir.appending(path: "prefs"))
        #expect(ChosenFolders(defaults: defaults, sandboxed: true, bookmarks: bookmarks()).keep(folder))
        try FileManager.default.removeItem(at: folder)
        let next = ChosenFolders(defaults: defaults, sandboxed: true, bookmarks: bookmarks())
        next.restore()
        #expect(next.paths.isEmpty)
    }
}
