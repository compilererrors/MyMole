import Foundation
import Testing

@testable import StorageKit

@Suite struct VolumesTests {
    @Test func aDiskKeepsItsOwnHistoryWhateverItsName() {
        #expect(Volumes.historyKey(for: "/synthetic/home") { _ in (true, "A") } == "/synthetic/home")
        let first = Volumes.historyKey(for: "/Volumes/Backup") { _ in (false, "UUID-1") }
        let other = Volumes.historyKey(for: "/Volumes/Backup") { _ in (false, "UUID-2") }
        #expect(first == "/Volumes/Backup#UUID-1" && first != other)
        // A disk that doesn't say who it is shares with none.
        let a = Volumes.historyKey(for: "/Volumes/Stick") { _ in (false, nil) }
        let b = Volumes.historyKey(for: "/Volumes/Stick") { _ in (false, nil) }
        #expect(a != b && a.hasPrefix("/Volumes/Stick#unknown-"))
    }

    @Test func theStartupDiskIsListedFirst() {
        let all = Volumes.mounted()
        #expect(all.first?.path == "/")
    }

    @Test func aSnapshotSavedUnderAKeyIsFoundUnderIt() throws {
        let box = try Sandbox()
        let base = box.url.appending(path: "snapshots")
        let s = Snapshot(rootPath: "/Volumes/Backup", date: Date(), sizes: ["": 1])
        _ = SnapshotStore.save(s, key: "/Volumes/Backup#UUID-1", base: base)
        #expect(SnapshotStore.history(for: "/Volumes/Backup#UUID-1", base: base).count == 1)
        #expect(SnapshotStore.history(for: "/Volumes/Backup", base: base).isEmpty)
    }
}
