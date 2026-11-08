import Foundation
import Testing

@testable import StorageKit

@Suite struct SavedResultsTests {
    /// Clearing takes each pane's last result and the scan history, and
    /// nothing the user made: keep lists and project rules stay.
    @Test func clearingSavedResultsLeavesKeepListsAndRules() throws {
        let box = try Sandbox()
        let bases = ["DeepClean", "Installers", "Apps", "Projects"].map { box.url.appending(path: $0) }
        for b in bases { try box.file(String(b.path.dropFirst(box.path.count + 1)) + "/last.json", bytes: 2_000) }
        try box.file("Projects/history.json", bytes: 1_000)
        try box.file("Projects/rules.json", bytes: 500)
        try box.file("DeepClean/keep.json", bytes: 500)
        try box.file("Snapshots/home/2026.json", bytes: 3_000)
        let files = SavedResults.files(deepClean: bases[0], installers: bases[1], apps: bases[2], projects: bases[3])
        let snapshots = box.url.appending(path: "Snapshots")
        #expect(SavedResults.bytes(files: files, snapshots: snapshots) > 0)

        SavedResults.clear(files: files, snapshots: snapshots)

        #expect(SavedResults.bytes(files: files, snapshots: snapshots) == 0)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: box.path + "/Projects/rules.json"))
        #expect(fm.fileExists(atPath: box.path + "/DeepClean/keep.json"))
        #expect(!fm.fileExists(atPath: box.path + "/Projects/history.json"))
        #expect(!fm.fileExists(atPath: snapshots.path))
    }
}
